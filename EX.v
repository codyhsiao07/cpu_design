// ex_stage.v -- RV32I/RV32M EX stage
// Verilog-2001; matches the ID/EX register control bundle (a few control bits).
// ALU op is 3-bit as defined by id_stage:
// 000 ADD, 001 SUB, 010 SLT, 011 SLTU, 100 XOR, 101 OR, 110 AND, 111 SHIFT
// SHIFT covers SLL/SRL/SRA as selected by shift flags.

module ex_stage (

  input clk,
  input rst_n,
  input ex_valid_i,
  input ex_pipe_hold_i,
  // From ID/EX register
  input  [31:0] ex_pc_i,
  input  [31:0] ex_rs1_val_i,
  input  [31:0] ex_rs2_val_i,
  input  [31:0] ex_imm_i,
  input  [3:0]  ex_alu_op_i,
  input         ex_alu_src_imm_i,    // 1: srcB=imm, 0: srcB=rs2
  input         ex_branch_i,
  input         ex_jal_i,
  input         ex_jalr_i,
  input  [2:0]  ex_br_funct3_i,      // BEQ/BNE/BLT/BGE/...
  // Shift and special op qualifiers
  input         ex_shift_right_i,    // 1: right shift, 0: left shift
  input         ex_shift_arith_i,    // 1: arithmetic right shift (SRA/SRAI)
  input         ex_is_auipc_i,       // 1: AUIPC
  input         ex_is_lui_i,         // 1: LUI
  input         ex_csr_en_i,
  input  [31:0] ex_csr_rdata_i,

  // Outputs
  output ex_stall_o,
  output [31:0] ex_alu_result_o,     // To EX/MEM
  output [31:0] ex_store_data_o,     // For stores: pass rs2
  output [31:0] ex_pc4_o,            // PC+4 (for JAL/JALR writeback)
  output        ex_br_taken_o,       // Branch taken flag
  output [31:0] ex_br_target_o,      // Branch/jump target (PC+imm)
  output        redirect_valid_o,    // Request to redirect PC
  output [31:0] redirect_pc_o        // Redirect PC value
);

  // ====== Operand selection ======
  // AUIPC: srcA=PC; LUI: srcA=0; otherwise srcA=rs1
  wire [31:0] srcA =
      ex_is_auipc_i ? ex_pc_i :
      ex_is_lui_i   ? 32'b0   :
                      ex_rs1_val_i;

  wire [31:0] srcB = ex_alu_src_imm_i ? ex_imm_i : ex_rs2_val_i;

  // Shift amount
  wire [4:0] shamt = ex_alu_src_imm_i ? ex_imm_i[4:0] : ex_rs2_val_i[4:0];

  // ====== ALU ======
  localparam [3:0] ALU_ADD   = 4'b0000,
                   ALU_SUB   = 4'b0001,
                   ALU_SLT   = 4'b0010,
                   ALU_SLTU  = 4'b0011,
                   ALU_XOR   = 4'b0100,
                   ALU_OR    = 4'b0101,
                   ALU_AND   = 4'b0110,
                   ALU_SLL   = 4'b0111,
                   ALU_MUL   = 4'b1000,
                   ALU_MULH  = 4'b1001,
                   ALU_MULHSU= 4'b1010,
                   ALU_MULHU = 4'b1011,
                   ALU_DIV   = 4'b1100,
                   ALU_DIVU  = 4'b1101,
                   ALU_REM   = 4'b1110,
                   ALU_REMU  = 4'b1111; // SHIFT: SLL/SRL/SRA depends on flags
  
  wire is_mul   = (ex_alu_op_i == ALU_MUL)   ||
                  (ex_alu_op_i == ALU_MULH)  ||
                  (ex_alu_op_i == ALU_MULHSU)||
                  (ex_alu_op_i == ALU_MULHU);
  wire is_div   = (ex_alu_op_i == ALU_DIV)   ||
                  (ex_alu_op_i == ALU_DIVU);
  wire is_rem   = (ex_alu_op_i == ALU_REM)   ||
                  (ex_alu_op_i == ALU_REMU);
  wire mul_high = (ex_alu_op_i != ALU_MUL);
  wire mul_signed_a = (ex_alu_op_i == ALU_MUL)   ||
                      (ex_alu_op_i == ALU_MULH)  ||
                      (ex_alu_op_i == ALU_MULHSU);
  wire mul_signed_b = (ex_alu_op_i == ALU_MUL) ||
                      (ex_alu_op_i == ALU_MULH);
  wire div_signed = (ex_alu_op_i == ALU_DIV) ||
                    (ex_alu_op_i == ALU_REM);
  
  wire        mul_start;
  wire        mul_busy;
  wire        mul_done;
  wire [31:0] mul_result;
  reg mul_started;
  reg mul_completed;

  booth_multiplier u_mul (
    .clk      (clk),
    .rst_n    (rst_n),
    .start_i  (mul_start),
    .a_i      (srcA),
    .b_i      (srcB),
    .signed_a_i(mul_signed_a),
    .signed_b_i(mul_signed_b),
    .high_half_i(mul_high),
    .busy_o   (mul_busy),
    .done_o   (mul_done),
    .result_o (mul_result)
  );
  
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      mul_started <= 1'b0;
      mul_completed <= 1'b0;
    end else if(!ex_valid_i || !is_mul) begin
      mul_started <= 1'b0;
      mul_completed <= 1'b0;
    end else if(mul_done) begin
      mul_started <= 1'b0;
      // Remember completion only while the downstream pipeline holds
      // this instruction. Otherwise it advances on this edge.
      mul_completed <= ex_pipe_hold_i;
    end else if(mul_start) begin
      mul_started <= 1'b1;
      mul_completed <= 1'b0;
    end else if(mul_completed && !ex_pipe_hold_i) begin
      mul_completed <= 1'b0;
    end
  end
  
  wire        div_start;
  wire        div_busy;
  wire        div_done;
  wire [31:0] div_quotient;
  wire [31:0] div_remainder;
  reg div_started;
  reg div_completed;
  
  restoring_divider u_div (
    .clk         (clk),
    .rst_n       (rst_n),
    .start_i     (div_start),
    .dividend_i  (srcA),
    .divisor_i   (srcB),
    .signed_mode_i(div_signed),
    .busy_o      (div_busy),
    .done_o      (div_done),
    .quotient_o  (div_quotient),
    .remainder_o (div_remainder)
  );
  
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      div_started <= 1'b0;
      div_completed <= 1'b0;
    end else if(!ex_valid_i || !(is_div || is_rem)) begin
      div_started <= 1'b0;
      div_completed <= 1'b0;
    end else if(div_done) begin
      div_started <= 1'b0;
      div_completed <= ex_pipe_hold_i;
    end else if(div_start) begin
      div_started <= 1'b1;
      div_completed <= 1'b0;
    end else if(div_completed && !ex_pipe_hold_i) begin
      div_completed <= 1'b0;
    end
  end
  
  assign mul_start = ex_valid_i && is_mul && !mul_started && !mul_completed && !mul_busy;
  assign div_start = ex_valid_i && (is_div || is_rem) && !div_started && !div_completed && !div_busy;
  assign ex_stall_o = ex_valid_i &&
                      ((is_mul && !(mul_done || mul_completed)) ||
                       ((is_div || is_rem) && !(div_done || div_completed)));
  
  reg [31:0] alu_res;
  reg [31:0] ex_result_r;
  
  always @(*) begin
    case (ex_alu_op_i)
      ALU_ADD:  alu_res = srcA + srcB;
      ALU_SUB:  alu_res = srcA - srcB;
      ALU_AND:  alu_res = srcA & srcB;
      ALU_OR :  alu_res = srcA | srcB;
      ALU_XOR:  alu_res = srcA ^ srcB;
      ALU_SLT:  alu_res = ($signed(srcA) < $signed(srcB)) ? 32'd1 : 32'd0;
      ALU_SLTU: alu_res = (srcA < srcB) ? 32'd1 : 32'd0;
      ALU_SLL: begin
        if (!ex_shift_right_i) begin
          // SLL / SLLI
          alu_res = srcA << shamt;
        end else begin
          // SRL / SRLI / SRA / SRAI
          if (ex_shift_arith_i)
            alu_res = $signed(srcA) >>> shamt;  // SRA
          else
            alu_res = srcA >> shamt;            // SRL
        end
      end
      default:  alu_res = 32'b0;
    endcase
  end

  always @(*) begin
    if (ex_csr_en_i) begin
      ex_result_r = ex_csr_rdata_i;
    end else if (is_mul) begin
      ex_result_r = mul_result;
    end else if (is_div) begin
      ex_result_r = div_quotient;
    end else if (is_rem) begin
      ex_result_r = div_remainder;
    end else begin
      ex_result_r = alu_res;
    end
  end

  assign ex_alu_result_o = ex_result_r;
  assign ex_store_data_o = ex_rs2_val_i;
  assign ex_pc4_o        = ex_pc_i + 32'd4;

  // ====== Branch / Jump ======
  // Branch comparisons (rs1/rs2)
  wire beq  = (ex_rs1_val_i == ex_rs2_val_i);
  wire bne  = ~beq;
  wire blt  = ($signed(ex_rs1_val_i) <  $signed(ex_rs2_val_i));
  wire bge  = ~blt;
  wire bltu = (ex_rs1_val_i <  ex_rs2_val_i);
  wire bgeu = ~bltu;

  reg br_take;
  always @(*) begin
    case (ex_br_funct3_i)
      3'b000: br_take = beq;
      3'b001: br_take = bne;
      3'b100: br_take = blt;
      3'b101: br_take = bge;
      3'b110: br_take = bltu;
      3'b111: br_take = bgeu;
      default: br_take = 1'b0;
    endcase
  end

  assign ex_br_taken_o  = ex_branch_i & br_take;
  assign ex_br_target_o = ex_pc_i + ex_imm_i;

  // JAL/JALR targets
  wire [31:0] jal_target  = ex_pc_i + ex_imm_i;                        // JAL
  wire [31:0] jalr_target = (ex_rs1_val_i + ex_imm_i) & 32'hFFFF_FFFE; // bit0=0

  // Redirect priority: JALR > JAL > branch-taken
  assign redirect_valid_o = ex_jalr_i | ex_jal_i | (ex_branch_i & br_take);
  assign redirect_pc_o    = ex_jalr_i ? jalr_target :
                            ex_jal_i  ? jal_target  :
                                         ex_br_target_o;

endmodule
