// id_ex_reg.v — ID/EX pipeline register (RV32I, no C)
// 功能：把 ID 階段產生的操作數/立即數/控制訊號寄存，送往 EX。
// 特性：stall_i=1 保持；flush_i=1 清成安全值（不寫回、不存取、不中斷）。

module id_ex_reg (
  input         clk,
  input         rst_n,

  // 控制
  input         stall_i,   // 停住：保持上一拍
  input         flush_i,   // 清空：控制訊號→安全值、資料→0
  input         id_valid_i, // 這拍ID是否有效（通常 from if_id_reg）

  // ====== 來自 ID 階段 ======
  input  [31:0] id_pc_i,
  input  [31:0] id_rs1_val_i,
  input  [31:0] id_rs2_val_i,
  input  [31:0] id_imm_i,
  input  [4:0]  id_rs1_i,
  input  [4:0]  id_rs2_i,
  input  [4:0]  id_rd_i,

  input  [2:0]  id_alu_op_i,
  input         id_alu_src_imm_i,
  input         id_branch_i,
  input         id_jal_i,
  input         id_jalr_i,
  input         id_mem_read_i,
  input         id_mem_write_i,
  input  [1:0]  id_wb_sel_i,     // 00:ALU, 01:MEM, 10:PC+4
  input         id_reg_write_i,
  input  [2:0]  id_br_funct3_i,
  // 新增介面
  input         id_shift_right_i,
  input         id_shift_arith_i,
  input         id_is_auipc_i,
  input         id_is_lui_i,
  input  [2:0]  id_mem_funct3_i,
  output [2:0]  ex_mem_funct3_o,
  output        ex_shift_right_o,
  output        ex_shift_arith_o,
  output        ex_is_auipc_o,
  output        ex_is_lui_o,


  // ====== 輸出到 EX 階段 ======
  output [31:0] ex_pc_o,
  output [31:0] ex_rs1_val_o,
  output [31:0] ex_rs2_val_o,
  output [31:0] ex_imm_o,
  output [4:0]  ex_rs1_o,
  output [4:0]  ex_rs2_o,
  output [4:0]  ex_rd_o,

  output [2:0]  ex_alu_op_o,
  output        ex_alu_src_imm_o,
  output        ex_branch_o,
  output        ex_jal_o,
  output        ex_jalr_o,
  output        ex_mem_read_o,
  output        ex_mem_write_o,
  output [1:0]  ex_wb_sel_o,
  output        ex_reg_write_o,
  output [2:0]  ex_br_funct3_o,

  output        ex_valid_o
);

  // 安全預設：flush 時不要對狀態造成影響
  localparam [1:0] WB_ALU = 2'b00; // flush 時 WB 選 ALU（但 reg_write=0，無寫回）

  // 寄存器
  reg [31:0] pc_q, rs1_q, rs2_q, imm_q;
  reg [4:0]  rs1r_q, rs2r_q, rdr_q;

  reg [2:0]  alu_op_q, br_funct3_q;
  reg        alu_src_imm_q, branch_q, jal_q, jalr_q;
  reg        mem_read_q, mem_write_q, reg_write_q;
  reg [1:0]  wb_sel_q;

  reg        valid_q;
  reg [2:0] mem_f3_q;
  reg shift_right_q, shift_arith_q, is_auipc_q, is_lui_q;

  // 下一拍值（含 stall/flush 邏輯）
  wire [31:0] pc_d        = flush_i ? 32'b0       : (stall_i ? pc_q       : id_pc_i);
  wire [31:0] rs1_d       = flush_i ? 32'b0       : (stall_i ? rs1_q      : id_rs1_val_i);
  wire [31:0] rs2_d       = flush_i ? 32'b0       : (stall_i ? rs2_q      : id_rs2_val_i);
  wire [31:0] imm_d       = flush_i ? 32'b0       : (stall_i ? imm_q      : id_imm_i);
  wire [2:0] mem_f3_d = flush_i ? 3'b010 : (stall_i ? mem_f3_q : id_mem_funct3_i);

  wire [4:0]  rs1r_d      = flush_i ? 5'b0        : (stall_i ? rs1r_q     : id_rs1_i);
  wire [4:0]  rs2r_d      = flush_i ? 5'b0        : (stall_i ? rs2r_q     : id_rs2_i);
  wire [4:0]  rdr_d       = flush_i ? 5'b0        : (stall_i ? rdr_q      : id_rd_i);

  wire [2:0]  alu_op_d    = flush_i ? 3'b000      : (stall_i ? alu_op_q   : id_alu_op_i);
  wire        alu_src_d   = flush_i ? 1'b0        : (stall_i ? alu_src_imm_q : id_alu_src_imm_i);
  wire        branch_d    = flush_i ? 1'b0        : (stall_i ? branch_q    : id_branch_i);
  wire        jal_d       = flush_i ? 1'b0        : (stall_i ? jal_q       : id_jal_i);
  wire        jalr_d      = flush_i ? 1'b0        : (stall_i ? jalr_q      : id_jalr_i);
  wire        mem_rd_d    = flush_i ? 1'b0        : (stall_i ? mem_read_q  : id_mem_read_i);
  wire        mem_wr_d    = flush_i ? 1'b0        : (stall_i ? mem_write_q : id_mem_write_i);
  wire [1:0]  wb_sel_d    = flush_i ? WB_ALU      : (stall_i ? wb_sel_q    : id_wb_sel_i);
  wire        reg_wr_d    = flush_i ? 1'b0        : (stall_i ? reg_write_q : id_reg_write_i);
  wire [2:0]  br_f3_d     = flush_i ? 3'b000      : (stall_i ? br_funct3_q : id_br_funct3_i);

  wire        valid_d     = flush_i ? 1'b0        : (stall_i ? valid_q     : id_valid_i);
  wire shift_right_d = flush_i ? 1'b0 : (stall_i ? shift_right_q : id_shift_right_i);
  wire shift_arith_d = flush_i ? 1'b0 : (stall_i ? shift_arith_q : id_shift_arith_i);
  wire is_auipc_d    = flush_i ? 1'b0 : (stall_i ? is_auipc_q    : id_is_auipc_i);
  wire is_lui_d      = flush_i ? 1'b0 : (stall_i ? is_lui_q      : id_is_lui_i);

  // 寄存器本體（rst_n 為低態有效）
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc_q        <= 32'b0;
      rs1_q       <= 32'b0;
      rs2_q       <= 32'b0;
      imm_q       <= 32'b0;
      rs1r_q      <= 5'b0;
      rs2r_q      <= 5'b0;
      rdr_q       <= 5'b0;
      alu_op_q    <= 3'b000;
      alu_src_imm_q <= 1'b0;
      branch_q    <= 1'b0;
      jal_q       <= 1'b0;
      jalr_q      <= 1'b0;
      mem_read_q  <= 1'b0;
      mem_write_q <= 1'b0;
      wb_sel_q    <= WB_ALU;
      reg_write_q <= 1'b0;
      br_funct3_q <= 3'b000;
      valid_q     <= 1'b0;
      shift_right_q <= 1'b0;
      shift_arith_q <= 1'b0;
      is_auipc_q    <= 1'b0;
      is_lui_q      <= 1'b0;
      mem_f3_q    <= 3'b010;
    end else begin
      pc_q        <= pc_d;
      rs1_q       <= rs1_d;
      rs2_q       <= rs2_d;
      imm_q       <= imm_d;
      rs1r_q      <= rs1r_d;
      rs2r_q      <= rs2r_d;
      rdr_q       <= rdr_d;
      alu_op_q    <= alu_op_d;
      alu_src_imm_q <= alu_src_d;
      branch_q    <= branch_d;
      jal_q       <= jal_d;
      jalr_q      <= jalr_d;
      mem_read_q  <= mem_rd_d;
      mem_write_q <= mem_wr_d;
      wb_sel_q    <= wb_sel_d;
      reg_write_q <= reg_wr_d;
      br_funct3_q <= br_f3_d;
      valid_q     <= valid_d;
      shift_right_q <= shift_right_d;
      shift_arith_q <= shift_arith_d;
      is_auipc_q    <= is_auipc_d;
      is_lui_q      <= is_lui_d;
      mem_f3_q <= mem_f3_d;
    end
  end

  // 對外輸出
  assign ex_pc_o         = pc_q;
  assign ex_rs1_val_o    = rs1_q;
  assign ex_rs2_val_o    = rs2_q;
  assign ex_imm_o        = imm_q;
  assign ex_rs1_o        = rs1r_q;
  assign ex_rs2_o        = rs2r_q;
  assign ex_rd_o         = rdr_q;

  assign ex_alu_op_o     = alu_op_q;
  assign ex_alu_src_imm_o= alu_src_imm_q;
  assign ex_branch_o     = branch_q;
  assign ex_jal_o        = jal_q;
  assign ex_jalr_o       = jalr_q;
  assign ex_mem_read_o   = mem_read_q;
  assign ex_mem_write_o  = mem_write_q;
  assign ex_wb_sel_o     = wb_sel_q;
  assign ex_reg_write_o  = reg_write_q;
  assign ex_br_funct3_o  = br_funct3_q;

  assign ex_valid_o      = valid_q;
  assign ex_shift_right_o = shift_right_q;
  assign ex_shift_arith_o = shift_arith_q;
  assign ex_is_auipc_o    = is_auipc_q;
  assign ex_is_lui_o      = is_lui_q;

  assign ex_mem_funct3_o = mem_f3_q;

endmodule
