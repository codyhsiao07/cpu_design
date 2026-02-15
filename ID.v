// regfile.v -- RV32I 32x32 Register File (x0 hardwired to 0)
module regfile (
  input         clk,
  input         rst_n,

  // Read ports
  input  [4:0]  rs1_i,
  input  [4:0]  rs2_i,
  output [31:0] rs1_o,
  output [31:0] rs2_o,

  // Write port
  input         we_i,
  input  [4:0]  rd_i,
  input  [31:0] wd_i
);

  reg [31:0] rf[31:0];
  integer i;

  // Asynchronous read (simple, adequate for this core)
  assign rs1_o = (rs1_i == 5'd0) ? 32'b0 : rf[rs1_i];
  assign rs2_o = (rs2_i == 5'd0) ? 32'b0 : rf[rs2_i];

  // Synchronous write, async reset low
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (i = 0; i < 32; i = i + 1) rf[i] <= 32'b0;
    end else if (we_i && (rd_i != 5'd0)) begin
      rf[rd_i] <= wd_i;
    end
  end

endmodule

// id_stage.v -- RV32I ID stage (decode + immgen + control)
// Verilog-2001; no compressed ISA, no CSR control path here.
module id_stage (
  input         clk,
  input         rst_n,

  // From IF/ID pipeline register
  input  [31:0] id_pc_i,
  input  [31:0] id_instr_i,
  input         id_valid_i,
  input         id_stall_i,

  // From WB stage (writeback to regfile)
  input         wb_we_i,
  input  [4:0]  wb_rd_i,
  input  [31:0] wb_wd_i,

  // To EX stage / ID-EX pipeline register
  output [31:0] rs1_val_o,
  output [31:0] rs2_val_o,
  output [31:0] imm_o,
  output [4:0]  rs1_o,
  output [4:0]  rs2_o,
  output [4:0]  rd_o,
  output [2:0]  alu_op_o,       // Coarse ALU op, detailed by EX
  output        alu_src_imm_o,  // 1: srcB=imm, 0: srcB=rs2
  output        branch_o,       // B-type
  output        jal_o,          // JAL
  output        jalr_o,         // JALR
  output        mem_read_o,     // LOAD
  output        mem_write_o,    // STORE
  output [1:0]  wb_sel_o,       // 00:ALU, 01:MEM, 10:PC+4
  output        reg_write_o,    // Write rd in WB
  output [2:0]  br_funct3_o,    // Branch type to EX comparator
  output [31:0] pc_o,           // Pass-through PC (for AUIPC/JAL targets)
  output        id_ready_o,     // Backpressure passthrough for pipeline reg
  output        id_shift_right_o,
  output        id_shift_arith_o,
  output        id_is_auipc_o,
  output        id_is_lui_o,
  output [2:0]  id_mem_funct3_o
);

  // -------- Instruction fields --------
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

  // -------- Opcodes --------
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

  // -------- ALU op encoding (3-bit) --------
  localparam [2:0] ALU_ADD = 3'b000;
  localparam [2:0] ALU_SUB = 3'b001;
  localparam [2:0] ALU_SLT = 3'b010;
  localparam [2:0] ALU_SLTU= 3'b011;
  localparam [2:0] ALU_XOR = 3'b100;
  localparam [2:0] ALU_OR  = 3'b101;
  localparam [2:0] ALU_AND = 3'b110;
  localparam [2:0] ALU_SLL = 3'b111; // SHIFT group (SLL/SRL/SRA decided by flags)

  // -------- WB mux encoding --------
  localparam [1:0] WB_ALU = 2'b00; // ALU result
  localparam [1:0] WB_MEM = 2'b01; // Memory read data
  localparam [1:0] WB_PC4 = 2'b10; // PC+4 (JAL/JALR)

  // -------- Immediate generation --------
  reg [31:0] imm;
  wire [31:0] imm_i = {{20{id_instr_i[31]}}, id_instr_i[31:20]};
  wire [31:0] imm_s = {{20{id_instr_i[31]}}, id_instr_i[31:25], id_instr_i[11:7]};
  wire [31:0] imm_b = {{19{id_instr_i[31]}}, id_instr_i[31], id_instr_i[7], id_instr_i[30:25], id_instr_i[11:8], 1'b0};
  wire [31:0] imm_u = {id_instr_i[31:12], 12'b0};
  wire [31:0] imm_j = {{11{id_instr_i[31]}}, id_instr_i[31], id_instr_i[19:12], id_instr_i[20], id_instr_i[30:21], 1'b0};

  // -------- Control defaults --------
  reg [2:0] alu_op;
  reg       alu_src_imm;
  reg       branch, jal, jalr;
  reg       mem_read, mem_write;
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

  // -------- Main decode --------
  always @(*) begin
    // Safe defaults (bubble)
    imm         = 32'b0;
    alu_op      = ALU_ADD;
    alu_src_imm = 1'b0;
    branch      = 1'b0;
    jal         = 1'b0;
    jalr        = 1'b0;
    mem_read    = 1'b0;
    mem_write   = 1'b0;
    wb_sel      = WB_ALU;
    reg_write   = 1'b0;
    shift_right = 1'b0;
    shift_arith = 1'b0;
    is_auipc    = 1'b0;
    is_lui      = 1'b0;
    mem_f3      = 3'b010; // default LW

    case (opcode)
      OP_LUI: begin
        imm         = imm_u;
        alu_op      = ALU_ADD;     // EX implements as 0 + U-imm
        alu_src_imm = 1'b1;
        wb_sel      = WB_ALU;
        reg_write   = 1'b1;
        is_lui      = 1'b1;        // srcA = 0
      end
      OP_AUIPC: begin
        imm         = imm_u;
        alu_op      = ALU_ADD;     // EX: PC + U-imm
        alu_src_imm = 1'b1;
        wb_sel      = WB_ALU;
        reg_write   = 1'b1;
        is_auipc    = 1'b1;        // srcA = PC
      end
      OP_JAL: begin
        imm         = imm_j;
        jal         = 1'b1;
        wb_sel      = WB_PC4;      // rd <= PC+4
        reg_write   = 1'b1;
      end
      OP_JALR: begin
        imm         = imm_i;
        jalr        = 1'b1;
        wb_sel      = WB_PC4;
        reg_write   = 1'b1;
      end
      OP_BRANCH: begin
        imm         = imm_b;
        branch      = 1'b1;        // EX compares via funct3
      end
      OP_LOAD: begin
        imm         = imm_i;
        alu_op      = ALU_ADD;     // addr = rs1 + imm
        alu_src_imm = 1'b1;
        mem_read    = 1'b1;
        wb_sel      = WB_MEM;      // rd <= mem_rdata
        reg_write   = 1'b1;
        mem_f3      = funct3;
      end
      OP_STORE: begin
        imm         = imm_s;
        alu_op      = ALU_ADD;     // addr = rs1 + imm
        alu_src_imm = 1'b1;
        mem_write   = 1'b1;
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
            alu_op      = ALU_SLL;    // use SHIFT group in EX
            shift_right = 1'b0;       // left shift
          end
          3'b101: begin               // SRLI / SRAI
            alu_op      = ALU_SLL;
            shift_right = 1'b1;       // right shift
            shift_arith = id_instr_i[30]; // 0=SRLI, 1=SRAI
          end
        endcase
      end
      OP_OP: begin
        reg_write   = 1'b1;
        alu_src_imm = 1'b0;
        case (funct3)
          3'b000: alu_op = (funct7[5] ? ALU_SUB : ALU_ADD);
          3'b001: begin // SLL
            alu_op      = ALU_SLL;
            shift_right = 1'b0;
          end
          3'b101: begin // SRL / SRA via funct7[5]
            alu_op      = ALU_SLL;
            shift_right = 1'b1;
            shift_arith = funct7[5];  // 0=SRL, 1=SRA
          end
          3'b010: alu_op = ALU_SLT;
          3'b011: alu_op = ALU_SLTU;
          3'b100: alu_op = ALU_XOR;
          3'b110: alu_op = ALU_OR;
          3'b111: alu_op = ALU_AND;
        endcase
      end
      default: begin
        // keep defaults
      end
    endcase
  end

  // Pass-through ready (simple pipeline)
  assign id_ready_o = id_valid_i & ~id_stall_i;

  // Immediate output
  assign imm_o = imm;

  // Register file instance with simple WB bypass (no forwarding network elsewhere)
  wire [31:0] rs1_raw, rs2_raw;
  regfile u_rf (
    .clk   (clk),
    .rst_n (rst_n),
    .rs1_i (rs1),
    .rs2_i (rs2),
    .rs1_o (rs1_raw),
    .rs2_o (rs2_raw),
    .we_i  (wb_we_i),
    .rd_i  (wb_rd_i),
    .wd_i  (wb_wd_i)
  );

  wire wb_match_rs1 = wb_we_i && (wb_rd_i != 5'd0) && (wb_rd_i == rs1);
  wire wb_match_rs2 = wb_we_i && (wb_rd_i != 5'd0) && (wb_rd_i == rs2);
  assign rs1_val_o = wb_match_rs1 ? wb_wd_i : rs1_raw;
  assign rs2_val_o = wb_match_rs2 ? wb_wd_i : rs2_raw;

endmodule
