// ex_stage.v — RV32I EX stage (no MUL/DIV)
// 純 Verilog-2001；組合邏輯；與你現有 id_ex_reg 對接（多 4 個控制位）
//
// 依賴的 ALU 操作碼（3-bit；和你 id_stage 的定義一致）:
// 000 ADD, 001 SUB, 010 SLT, 011 SLTU, 100 XOR, 101 OR, 110 AND, 111 SLL/SHR(由旗號判定)

module ex_stage (
  // from ID/EX register
  input  [31:0] ex_pc_i,
  input  [31:0] ex_rs1_val_i,
  input  [31:0] ex_rs2_val_i,
  input  [31:0] ex_imm_i,
  input  [2:0]  ex_alu_op_i,
  input         ex_alu_src_imm_i,    // 1: srcB=imm, 0: srcB=rs2
  input         ex_branch_i,
  input         ex_jal_i,
  input         ex_jalr_i,
  input  [2:0]  ex_br_funct3_i,      // BEQ/BNE/BLT/BGE/...
  // 這四個是為了把 SLL/SRL/SRA 與 AUIPC/LUI 正確處理
  input         ex_shift_right_i,    // 1: 右移, 0: 左移
  input         ex_shift_arith_i,    // 1: 算術右移(SRA/SRAI)
  input         ex_is_auipc_i,       // 1: AUIPC
  input         ex_is_lui_i,         // 1: LUI

  // outputs
  output [31:0] ex_alu_result_o,     // 給後續 EX/MEM
  output [31:0] ex_store_data_o,     // SW 用（直接轉送 rs2）
  output [31:0] ex_pc4_o,            // PC+4（JAL/JALR 回寫用）
  output        ex_br_taken_o,       // 分支是否成立
  output [31:0] ex_br_target_o,      // 分支/跳躍目標 (PC+imm)
  output        redirect_valid_o,    // 要求修改 PC
  output [31:0] redirect_pc_o        // 新 PC
);

  // ====== 來源選擇 ======
  // AUIPC: srcA=PC；LUI: srcA=0；其餘 srcA=rs1
  wire [31:0] srcA =
      ex_is_auipc_i ? ex_pc_i :
      ex_is_lui_i   ? 32'b0   :
                      ex_rs1_val_i;

  wire [31:0] srcB = ex_alu_src_imm_i ? ex_imm_i : ex_rs2_val_i;

  // 移位量
  wire [4:0] shamt = ex_alu_src_imm_i ? ex_imm_i[4:0] : ex_rs2_val_i[4:0];

  // ====== ALU ======
  localparam [2:0] ALU_ADD = 3'b000,
                   ALU_SUB = 3'b001,
                   ALU_SLT = 3'b010,
                   ALU_SLTU= 3'b011,
                   ALU_XOR = 3'b100,
                   ALU_OR  = 3'b101,
                   ALU_AND = 3'b110,
                   ALU_SLL = 3'b111; // SLL 或 SRL/SRA 視旗號

  reg [31:0] alu_res;

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

  assign ex_alu_result_o = alu_res;
  assign ex_store_data_o = ex_rs2_val_i;
  assign ex_pc4_o        = ex_pc_i + 32'd4;

  // ====== Branch / Jump ======
  // 分支比較（以 rs1/rs2）
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

  // JAL/JALR 目標
  wire [31:0] jal_target  = ex_pc_i + ex_imm_i;                    // JAL
  wire [31:0] jalr_target = (ex_rs1_val_i + ex_imm_i) & 32'hFFFF_FFFE; // bit0=0

  // 產生 redirect（優先度：JALR > JAL > Branch-taken）
  assign redirect_valid_o = ex_jalr_i | ex_jal_i | (ex_branch_i & br_take);
  assign redirect_pc_o    = ex_jalr_i ? jalr_target :
                            ex_jal_i  ? jal_target  :
                                         ex_br_target_o;

endmodule
