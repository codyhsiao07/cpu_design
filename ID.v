// regfile.v — RV32I 32x32 Register File (x0 hardwired to 0)
module regfile (
  input         clk,
  input         rst_n,

  // read ports
  input  [4:0]  rs1_i,
  input  [4:0]  rs2_i,
  output [31:0] rs1_o,
  output [31:0] rs2_o,

  // write port
  input         we_i,
  input  [4:0]  rd_i,
  input  [31:0] wd_i
);

  reg [31:0] rf[31:0];
  integer i;

  // async read (常見簡化；若你想避免X/推導多驅動，可改成同步讀)
  assign rs1_o = (rs1_i == 5'd0) ? 32'b0 : rf[rs1_i];
  assign rs2_o = (rs2_i == 5'd0) ? 32'b0 : rf[rs2_i];

  // write on posedge（rst_n 為低態有效）
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (i = 0; i < 32; i = i + 1) rf[i] <= 32'b0;
    end else if (we_i && (rd_i != 5'd0)) begin
      rf[rd_i] <= wd_i;
    end
  end

endmodule

// id_stage.v — RV32I ID stage (decode + immgen + control)
// 純 Verilog-2001、無壓縮C、無旁路/阻塞（hazard後續再加）
module id_stage (
  input         clk,
  input         rst_n,

  // 來自 IF/ID 暫存器
  input  [31:0] id_pc_i,
  input  [31:0] id_instr_i,
  input         id_valid_i,

  // 從 WB 階段回寫到暫存器檔（寫回路徑）
  input         wb_we_i,
  input  [4:0]  wb_rd_i,
  input  [31:0] wb_wd_i,

  // 輸出到 EX 階段/ID-EX 暫存器
  output [31:0] rs1_val_o,
  output [31:0] rs2_val_o,
  output [31:0] imm_o,
  output [4:0]  rs1_o,
  output [4:0]  rs2_o,
  output [4:0]  rd_o,
  output [2:0]  alu_op_o,     // 粗略 ALU 操作碼（自定）
  output        alu_src_imm_o,// 1: 來源B用imm, 0: 用rs2
  output        branch_o,     // B-type
  output        jal_o,        // J-type
  output        jalr_o,       // I(JALR)
  output        mem_read_o,   // LW
  output        mem_write_o,  // SW
  output [1:0]  wb_sel_o,     // 00:ALU, 01:MEM, 10:PC+4
  output        reg_write_o,  // 是否寫回暫存器
  output [2:0]  br_funct3_o,  // 分支型別（傳給 EX 做比較）
  output [31:0] pc_o,         // 傳遞下去（常用於 PC+4、分支計算）
  output        id_ready_o,   // 這拍ID是否產生有效控制（給pipe reg用）
  output        id_shift_right_o,
  output        id_shift_arith_o,
  output        id_is_auipc_o,
  output        id_is_lui_o,
  output [2:0] id_mem_funct3_o
);

  // === 取欄位 ===
  wire [6:0] opcode  = id_instr_i[6:0];
  wire [4:0] rd      = id_instr_i[11:7];
  wire [2:0] funct3  = id_instr_i[14:12];
  wire [4:0] rs1     = id_instr_i[19:15];
  wire [4:0] rs2     = id_instr_i[24:20];
  wire [6:0] funct7  = id_instr_i[31:25];
  reg shift_right, shift_arith, is_auipc, is_lui;
  reg [2:0] mem_f3;
  
  assign id_mem_funct3_o = mem_f3;
  assign id_shift_right_o  = shift_right;
  assign id_shift_arith_o  = shift_arith;
  assign id_is_auipc_o     = is_auipc;
  assign id_is_lui_o       = is_lui;
  assign rs1_o = rs1;
  assign rs2_o = rs2;
  assign rd_o  = rd;
  assign br_funct3_o = funct3;
  assign pc_o  = id_pc_i;

  // === 常數（opcode） ===
  localparam [6:0] OP_LUI    = 7'b0110111;
  localparam [6:0] OP_AUIPC  = 7'b0010111;
  localparam [6:0] OP_JAL    = 7'b1101111;
  localparam [6:0] OP_JALR   = 7'b1100111;
  localparam [6:0] OP_BRANCH = 7'b1100011;
  localparam [6:0] OP_LOAD   = 7'b0000011;
  localparam [6:0] OP_STORE  = 7'b0100011;
  localparam [6:0] OP_OPIMM  = 7'b0010011;
  localparam [6:0] OP_OP     = 7'b0110011;
  localparam [6:0] OP_SYSTEM = 7'b1110011; // (ecall/ebreak/csrr*)

  // === ALU 操作碼（自定：3bit 範例）===
  localparam [2:0] ALU_ADD = 3'b000;
  localparam [2:0] ALU_SUB = 3'b001;
  localparam [2:0] ALU_SLT = 3'b010;
  localparam [2:0] ALU_SLTU= 3'b011;
  localparam [2:0] ALU_XOR = 3'b100;
  localparam [2:0] ALU_OR  = 3'b101;
  localparam [2:0] ALU_AND = 3'b110;
  localparam [2:0] ALU_SLL = 3'b111; // 這裡先塞SLL，SRL/SRA 由EX用funct7再細分

  // === WB Mux 選擇 ===
  // 00: ALU 結果
  // 01: Memory 讀回
  // 10: PC+4（JAL/JALR）
  // 11: 保留
  localparam [1:0] WB_ALU = 2'b00;
  localparam [1:0] WB_MEM = 2'b01;
  localparam [1:0] WB_PC4 = 2'b10;

  // === 立即數產生 ===
  reg [31:0] imm;
  // I-type
  wire [31:0] imm_i = {{20{id_instr_i[31]}}, id_instr_i[31:20]};
  // S-type
  wire [31:0] imm_s = {{20{id_instr_i[31]}}, id_instr_i[31:25], id_instr_i[11:7]};
  // B-type
  wire [31:0] imm_b = {{19{id_instr_i[31]}}, id_instr_i[31], id_instr_i[7],
                       id_instr_i[30:25], id_instr_i[11:8], 1'b0};
  // U-type
  wire [31:0] imm_u = {id_instr_i[31:12], 12'b0};
  // J-type
  wire [31:0] imm_j = {{11{id_instr_i[31]}}, id_instr_i[31], id_instr_i[19:12],
                       id_instr_i[20], id_instr_i[30:21], 1'b0};

  // === 暫存器檔 ===
  wire [31:0] rs1_val, rs2_val;
  assign rs1_val_o = rs1_val;
  assign rs2_val_o = rs2_val;

  regfile u_regfile (
    .clk   (clk),
    .rst_n (rst_n),
    .rs1_i (rs1),
    .rs2_i (rs2),
    .rs1_o (rs1_val),
    .rs2_o (rs2_val),
    .we_i  (wb_we_i),
    .rd_i  (wb_rd_i),
    .wd_i  (wb_wd_i)
  );

  // === 控制訊號 ===
  reg [2:0] alu_op;
  reg       alu_src_imm;
  reg       branch;
  reg       jal;
  reg       jalr;
  reg       mem_read;
  reg       mem_write;
  reg [1:0] wb_sel;
  reg       reg_write;

  assign alu_op_o      = alu_op;
  assign alu_src_imm_o = alu_src_imm;
  assign branch_o      = branch;
  assign jal_o         = jal;
  assign jalr_o        = jalr;
  assign mem_read_o    = mem_read;
  assign mem_write_o   = mem_write;
  assign wb_sel_o      = wb_sel;
  assign reg_write_o   = reg_write;

  // === 主解碼 ===
  always @(*) begin
    // 預設（安全）值
    imm        = 32'b0;
    alu_op     = ALU_ADD;
    alu_src_imm= 1'b0;
    branch     = 1'b0;
    jal        = 1'b0;
    jalr       = 1'b0;
    mem_read   = 1'b0;
    mem_write  = 1'b0;
    wb_sel     = WB_ALU;
    reg_write  = 1'b0;
    shift_right = 1'b0;
    shift_arith = 1'b0;
    is_auipc    = 1'b0;
    is_lui      = 1'b0;
    mem_f3     = 3'b010;

    case (opcode)
      OP_LUI: begin
        imm        = imm_u;
        alu_op     = ALU_ADD;     // EX可實作為 0 + U-imm
        alu_src_imm= 1'b1;
        wb_sel     = WB_ALU;
        reg_write  = 1'b1;
        is_lui = 1'b1;    // 讓 srcA = 0
      end
      OP_AUIPC: begin
        imm        = imm_u;
        alu_op     = ALU_ADD;     // EX: PC + U-imm
        alu_src_imm= 1'b1;
        wb_sel     = WB_ALU;
        reg_write  = 1'b1;
        is_auipc = 1'b1;  // 讓 srcA = PC
      end
      OP_JAL: begin
        imm        = imm_j;
        jal        = 1'b1;
        wb_sel     = WB_PC4;      // rd ← PC+4
        reg_write  = 1'b1;
      end
      OP_JALR: begin
        imm        = imm_i;
        jalr       = 1'b1;
        wb_sel     = WB_PC4;
        reg_write  = 1'b1;
      end
      OP_BRANCH: begin
        imm        = imm_b;
        branch     = 1'b1;        // 由 EX 依 funct3 比較決定是否 taken
        // 不寫回
      end
      OP_LOAD: begin
        imm        = imm_i;
        alu_op     = ALU_ADD;     // addr = rs1 + imm
        alu_src_imm= 1'b1;
        mem_read   = 1'b1;
        wb_sel     = WB_MEM;      // rd ← mem_rdata
        reg_write  = 1'b1;
        mem_f3      = funct3;
      end
      OP_STORE: begin
        imm        = imm_s;
        alu_op     = ALU_ADD;     // addr = rs1 + imm
        alu_src_imm= 1'b1;
        mem_write  = 1'b1;
        mem_f3      = funct3;
      end
      OP_OPIMM: begin
      imm         = imm_i;
      alu_src_imm = 1'b1;
      reg_write   = 1'b1;
      case (funct3)
        3'b000: alu_op = ALU_ADD;   // ADDI
        3'b010: alu_op = ALU_SLT;   // SLTI
        3'b011: alu_op = ALU_SLTU;  // SLTIU
        3'b100: alu_op = ALU_XOR;   // XORI
        3'b110: alu_op = ALU_OR;    // ORI
        3'b111: alu_op = ALU_AND;   // ANDI
        3'b001: begin               // SLLI
          alu_op      = ALU_SLL;    // 交給 EX 的「移位類」
          shift_right = 1'b0;       // 左移
          // shift_arith 無所謂，保持 0
        end

        3'b101: begin               // SRLI / SRAI
          alu_op      = ALU_SLL;    // 同樣走移位類
          shift_right = 1'b1;       // 右移
          // I-type 的算術/邏輯右移由 instr[30] 區分：0=SRLI, 1=SRAI
          shift_arith = id_instr_i[30];
        end
      endcase
      end
      OP_OP: begin
      reg_write   = 1'b1;
      alu_src_imm = 1'b0;
      case (funct3)
        3'b000: alu_op = (funct7[5] ? ALU_SUB : ALU_ADD);
        3'b001: begin                 // SLL
          alu_op      = ALU_SLL;
          shift_right = 1'b0;
        end
        3'b101: begin                 // SRL / SRA 由 funct7[5] 區分
          alu_op      = ALU_SLL;
          shift_right = 1'b1;
          shift_arith = funct7[5];    // 0=SRL, 1=SRA
        end
        3'b010: alu_op = ALU_SLT;
        3'b011: alu_op = ALU_SLTU;
        3'b100: alu_op = ALU_XOR;
        3'b110: alu_op = ALU_OR;
        3'b111: alu_op = ALU_AND;
      endcase
      end

    endcase
  end

  // 這拍ID是否有效（最簡做法：沿用 id_valid_i）
  assign id_ready_o = id_valid_i;

  // 輸出立即數
  assign imm_o = imm;

endmodule
