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

// id_stage.v -- RV32I/RV32M ID stage (decode + immgen + control)
// Verilog-2001; no compressed ISA. Includes base CSR/system decode.
module id_stage (
  input         clk,
  input         rst_n,

  // From IF/ID pipeline register
  input  [31:0] id_pc_i,
  input  [31:0] id_instr_i,
  input         id_valid_i,
  input         id_stall_i,
  input  [1:0]  current_priv_i,

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
  output [3:0]  alu_op_o,       // Coarse ALU op, detailed by EX
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
  output [2:0]  id_mem_funct3_o,
  output        id_csr_en_o,
  output [2:0]  id_csr_cmd_o,
  output [11:0] id_csr_addr_o,
  output        id_ecall_o,
  output        id_ebreak_o,
  output        id_mret_o,
  output        id_illegal_o
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
  reg       csr_en;
  reg [2:0] csr_cmd;
  reg       csr_use_zimm;
  reg       is_ecall;
  reg       is_ebreak;
  reg       is_mret;
  reg       illegal_instr;

  assign id_mem_funct3_o = mem_f3;
  assign id_shift_right_o  = shift_right;
  assign id_shift_arith_o  = shift_arith;
  assign id_is_auipc_o     = is_auipc;
  assign id_is_lui_o       = is_lui;
  assign id_csr_en_o       = csr_en;
  assign id_csr_cmd_o      = csr_cmd;
  assign id_csr_addr_o     = id_instr_i[31:20];
  assign id_ecall_o        = is_ecall;
  assign id_ebreak_o       = is_ebreak;
  assign id_mret_o         = is_mret;
  assign id_illegal_o      = illegal_instr;
  assign rs1_o = csr_use_zimm ? 5'd0 : rs1;
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
  localparam [6:0] OP_MISC_MEM = 7'b0001111; // FENCE/FENCE.I
  localparam [6:0] OP_SYSTEM = 7'b1110011; // (ecall/ebreak/csrr*)

  // -------- ALU op encoding (4-bit) --------
  localparam [3:0] ALU_ADD = 4'b0000;
  localparam [3:0] ALU_SUB = 4'b0001;
  localparam [3:0] ALU_SLT = 4'b0010;
  localparam [3:0] ALU_SLTU= 4'b0011;
  localparam [3:0] ALU_XOR = 4'b0100;
  localparam [3:0] ALU_OR  = 4'b0101;
  localparam [3:0] ALU_AND = 4'b0110;
  localparam [3:0] ALU_SLL = 4'b0111; // SHIFT group (SLL/SRL/SRA decided by flags)
  localparam [3:0] ALU_MUL   = 4'b1000;
  localparam [3:0] ALU_MULH  = 4'b1001;
  localparam [3:0] ALU_MULHSU= 4'b1010;
  localparam [3:0] ALU_MULHU = 4'b1011;
  localparam [3:0] ALU_DIV   = 4'b1100;
  localparam [3:0] ALU_DIVU  = 4'b1101;
  localparam [3:0] ALU_REM   = 4'b1110;
  localparam [3:0] ALU_REMU  = 4'b1111;
    
  // -------- WB mux encoding --------
  localparam [1:0] WB_ALU = 2'b00; // ALU result
  localparam [1:0] WB_MEM = 2'b01; // Memory read data
  localparam [1:0] WB_PC4 = 2'b10; // PC+4 (JAL/JALR)

  // -------- CSR command encoding --------
  localparam [2:0] CSR_CMD_NONE = 3'b000;
  localparam [2:0] CSR_CMD_W    = 3'b001;
  localparam [2:0] CSR_CMD_S    = 3'b010;
  localparam [2:0] CSR_CMD_C    = 3'b011;
  localparam [1:0] PRIV_U       = 2'b00;
  localparam [1:0] PRIV_M       = 2'b11;

  // Minimal supported machine CSRs
  wire csr_addr_supported = (id_instr_i[31:20] == 12'h300) || // mstatus
                            (id_instr_i[31:20] == 12'h304) || // mie
                            (id_instr_i[31:20] == 12'h305) || // mtvec
                            (id_instr_i[31:20] == 12'h340) || // mscratch
                            (id_instr_i[31:20] == 12'h341) || // mepc
                            (id_instr_i[31:20] == 12'h342) || // mcause
                            (id_instr_i[31:20] == 12'h344) || // mip
                            (id_instr_i[31:20] == 12'hF14);   // mhartid, read-only, hart 0
  wire [1:0] csr_required_priv = id_instr_i[29:28];
  wire csr_priv_ok = (current_priv_i >= csr_required_priv);
  wire csr_is_read_only = (id_instr_i[31:30] == 2'b11);
  wire csr_imm_form = funct3[2];
  wire csr_w_op = (funct3 == 3'b001) || (funct3 == 3'b101);
  wire csr_s_op = (funct3 == 3'b010) || (funct3 == 3'b110);
  wire csr_c_op = (funct3 == 3'b011) || (funct3 == 3'b111);
  wire [4:0] csr_zimm = id_instr_i[19:15];
  wire [4:0] csr_write_operand = csr_imm_form ? csr_zimm : rs1;
  wire csr_would_write = csr_w_op ||
                         ((csr_s_op || csr_c_op) && (csr_write_operand != 5'd0));

  // -------- Immediate generation --------
  reg [31:0] imm;
  wire [31:0] imm_i = {{20{id_instr_i[31]}}, id_instr_i[31:20]};
  wire [31:0] imm_s = {{20{id_instr_i[31]}}, id_instr_i[31:25], id_instr_i[11:7]};
  wire [31:0] imm_b = {{19{id_instr_i[31]}}, id_instr_i[31], id_instr_i[7], id_instr_i[30:25], id_instr_i[11:8], 1'b0};
  wire [31:0] imm_u = {id_instr_i[31:12], 12'b0};
  wire [31:0] imm_j = {{11{id_instr_i[31]}}, id_instr_i[31], id_instr_i[19:12], id_instr_i[20], id_instr_i[30:21], 1'b0};

  // -------- Control defaults --------
  reg [3:0] alu_op;
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
    csr_en      = 1'b0;
    csr_cmd     = CSR_CMD_NONE;
    csr_use_zimm= 1'b0;
    is_ecall    = 1'b0;
    is_ebreak   = 1'b0;
    is_mret     = 1'b0;
    illegal_instr = 1'b0;

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
        if (funct3 == 3'b000) begin
          jalr        = 1'b1;
          wb_sel      = WB_PC4;
          reg_write   = 1'b1;
        end else begin
          illegal_instr = 1'b1;
        end
      end
      OP_BRANCH: begin
        imm         = imm_b;
        case (funct3)
          3'b000, 3'b001, 3'b100, 3'b101, 3'b110, 3'b111: begin
            branch = 1'b1;        // EX compares via funct3
          end
          default: begin
            illegal_instr = 1'b1;
          end
        endcase
      end
      OP_LOAD: begin
        imm         = imm_i;
        case (funct3)
          3'b000, 3'b001, 3'b010, 3'b100, 3'b101: begin
            alu_op      = ALU_ADD;     // addr = rs1 + imm
            alu_src_imm = 1'b1;
            mem_read    = 1'b1;
            wb_sel      = WB_MEM;      // rd <= mem_rdata
            reg_write   = 1'b1;
            mem_f3      = funct3;
          end
          default: begin
            illegal_instr = 1'b1;
          end
        endcase
      end
      OP_STORE: begin
        imm         = imm_s;
        case (funct3)
          3'b000, 3'b001, 3'b010: begin
            alu_op      = ALU_ADD;     // addr = rs1 + imm
            alu_src_imm = 1'b1;
            mem_write   = 1'b1;
            mem_f3      = funct3;
          end
          default: begin
            illegal_instr = 1'b1;
          end
        endcase
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
            if (funct7 == 7'b0000000) begin
              alu_op      = ALU_SLL;    // use SHIFT group in EX
              shift_right = 1'b0;       // left shift
            end else begin
              illegal_instr = 1'b1;
            end
          end
          3'b101: begin               // SRLI / SRAI
            if ((funct7 == 7'b0000000) || (funct7 == 7'b0100000)) begin
              alu_op      = ALU_SLL;
              shift_right = 1'b1;       // right shift
              shift_arith = id_instr_i[30]; // 0=SRLI, 1=SRAI
            end else begin
              illegal_instr = 1'b1;
            end
          end
          default: begin
            illegal_instr = 1'b1;
          end
        endcase
      end
      OP_OP: begin
        reg_write   = 1'b1;
        alu_src_imm = 1'b0;
        
        // RV32M extension
        if (funct7 == 7'b0000001) begin
          case (funct3)
            3'b000: alu_op = ALU_MUL;   // MUL
            3'b001: alu_op = ALU_MULH;  // MULH
            3'b010: alu_op = ALU_MULHSU;// MULHSU
            3'b011: alu_op = ALU_MULHU; // MULHU
            3'b100: alu_op = ALU_DIV;   // DIV
            3'b101: alu_op = ALU_DIVU;  // DIVU
            3'b110: alu_op = ALU_REM;   // REM
            3'b111: alu_op = ALU_REMU;  // REMU
          endcase
        end
        // RV32I normal ALU
        else begin
          case (funct3)
      // ADD / SUB
            3'b000: begin
              if (funct7 == 7'b0000000) begin
                alu_op = ALU_ADD;
              end else if (funct7 == 7'b0100000) begin
                alu_op = ALU_SUB;
              end else begin
                illegal_instr = 1'b1;
              end
            end
      // SLL
            3'b001: begin
              if (funct7 == 7'b0000000) begin
                alu_op      = ALU_SLL;
                shift_right = 1'b0;
              end else begin
                illegal_instr = 1'b1;
              end
            end
      // SLT
            3'b010: begin
              if (funct7 == 7'b0000000) begin
                alu_op = ALU_SLT;
              end else begin
                illegal_instr = 1'b1;
              end
            end
      // SLTU
            3'b011: begin
              if (funct7 == 7'b0000000) begin
                alu_op = ALU_SLTU;
              end else begin
                illegal_instr = 1'b1;
              end
            end
      // XOR
            3'b100: begin
              if (funct7 == 7'b0000000) begin
                alu_op = ALU_XOR;
              end else begin
                illegal_instr = 1'b1;
              end
            end
      // SRL / SRA
            3'b101: begin
              if ((funct7 == 7'b0000000) || (funct7 == 7'b0100000)) begin
                alu_op      = ALU_SLL;
                shift_right = 1'b1;
                shift_arith = funct7[5]; // 0 = SRL, 1 = SRA
              end else begin
                illegal_instr = 1'b1;
              end
            end
      // OR
            3'b110: begin
              if (funct7 == 7'b0000000) begin
                alu_op = ALU_OR;
              end else begin
                illegal_instr = 1'b1;
              end
            end
      // AND
            3'b111: begin
              if (funct7 == 7'b0000000) begin
                alu_op = ALU_AND;
              end else begin
                illegal_instr = 1'b1;
              end
            end
          endcase
        end
        
      end
      OP_MISC_MEM: begin
        case (funct3)
          3'b000, 3'b001: begin
            // FENCE/FENCE.I are ordering operations. This in-order core has no
            // separate architectural action here, so decode them as legal NOPs.
          end
          default: begin
            illegal_instr = 1'b1;
          end
        endcase
      end
      OP_SYSTEM: begin
        case (funct3)
          3'b001, 3'b101: begin
            if (csr_addr_supported && csr_priv_ok && !(csr_is_read_only && csr_would_write)) begin
              csr_en      = 1'b1;      // CSRRW/CSRRWI
              csr_use_zimm= csr_imm_form;
              csr_cmd   = CSR_CMD_W;
              reg_write = 1'b1;
            end else begin
              illegal_instr = 1'b1;
            end
          end
          3'b010, 3'b110: begin
            if (csr_addr_supported && csr_priv_ok && !(csr_is_read_only && csr_would_write)) begin
              csr_en      = 1'b1;      // CSRRS/CSRRSI
              csr_use_zimm= csr_imm_form;
              csr_cmd   = CSR_CMD_S;
              reg_write = 1'b1;
            end else begin
              illegal_instr = 1'b1;
            end
          end
          3'b011, 3'b111: begin
            if (csr_addr_supported && csr_priv_ok && !(csr_is_read_only && csr_would_write)) begin
              csr_en      = 1'b1;      // CSRRC/CSRRCI
              csr_use_zimm= csr_imm_form;
              csr_cmd   = CSR_CMD_C;
              reg_write = 1'b1;
            end else begin
              illegal_instr = 1'b1;
            end
          end
          default: begin
            if ((id_instr_i[31:20] == 12'h000) && (rs1 == 5'd0) && (rd == 5'd0)) begin
              is_ecall = 1'b1;
            end else if ((id_instr_i[31:20] == 12'h001) && (rs1 == 5'd0) && (rd == 5'd0)) begin
              is_ebreak = 1'b1;
            end else if ((id_instr_i[31:20] == 12'h302) && (rs1 == 5'd0) && (rd == 5'd0) && (current_priv_i == PRIV_M)) begin
              is_mret = 1'b1;
            end else begin
              illegal_instr = 1'b1;
            end
          end
        endcase
      end
      default: begin
        illegal_instr = 1'b1;
      end
    endcase

    if (illegal_instr) begin
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
      mem_f3      = 3'b010;
      csr_en      = 1'b0;
      csr_cmd     = CSR_CMD_NONE;
      csr_use_zimm= 1'b0;
      is_ecall    = 1'b0;
      is_ebreak   = 1'b0;
      is_mret     = 1'b0;
    end
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
  wire [31:0] rs1_bypass = wb_match_rs1 ? wb_wd_i : rs1_raw;
  assign rs1_val_o = csr_use_zimm ? {27'b0, csr_zimm} : rs1_bypass;
  assign rs2_val_o = wb_match_rs2 ? wb_wd_i : rs2_raw;

endmodule
