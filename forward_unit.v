// forward_unit.v — EX operand forwarding (bypass) unit
// Provides values for EX stage rs1/rs2 by selecting from:
// - Original register values coming from ID/EX
// - MEM stage result (EX/MEM) when the producer writes back this cycle or next
//   * For ALU ops: use mem_alu_result
//   * For JAL/JALR (PC+4): use mem_pc4
//   * For LOADs: forward once mem_load_valid_i indicates data availability
// - WB stage writeback data (MEM/WB)
// Priority: MEM-stage forward > WB-stage forward > original
module forward_unit (
  // EX stage operand indexes and original values
  input  [4:0]  ex_rs1_idx_i,//EX 這條指令的 rs1 編號
  input  [4:0]  ex_rs2_idx_i,//EX 這條指令的 rs2 編號
  input  [31:0] ex_rs1_val_i,//EX 原始 rs1 值
  input  [31:0] ex_rs2_val_i,//EX 原始 rs2 值

  // MEM stage producer (EX/MEM register outputs)
  input         mem_valid_i,//MEM stage 目前有沒有有效指令
  input         mem_reg_write_i,//MEM 這條指令最後會不會寫回 RF
  input  [1:0]  mem_wb_sel_i,     // MEM 這條指令「寫回資料的來源」是哪一個
  //00:ALU, 01:MEM(load), 10:PC+4
  input  [4:0]  mem_rd_i,//MEM 這條指令要寫回的目的暫存器 rd
  input  [31:0] mem_alu_result_i,//MEM producer 的 ALU 結果
  input  [31:0] mem_pc4_i,//MEM producer 的 PC+4
  input         mem_load_valid_i,//MEM producer 如果是 load：資料現在「可用」嗎
  //1：load data 這拍已經回來（hit 或 miss 回來的那拍）
  //0：load 還在等（例如 D$ miss refill 中、或下游 ready=0）
  input  [31:0] mem_load_data_i,//MEM producer 的 load data（只有 load 時用）

  // WB stage producer (after MEM/WB mux)
  input         wb_we_i,//WB 階段這拍是否真的要寫回暫存器
  input  [4:0]  wb_rd_i,//WB 這拍要寫回的目的寄存器 rd
  input  [31:0] wb_wdata_i,//WB 這拍真正寫回 RF 的資料

  // Forwarded operands to EX stage
  output [31:0] ex_rs1_val_o,//給 EX 的最終 operand（已套用 bypass）
  output [31:0] ex_rs2_val_o
);

  // Determine candidate value from MEM stage
  // Only forward when producer is valid, will write, rd!=0, and value is available.
  wire mem_is_load     = (mem_wb_sel_i == 2'b01);
  wire mem_can_write   = mem_valid_i & mem_reg_write_i & (mem_rd_i != 5'd0);
  wire mem_can_write_load = mem_can_write & mem_is_load & mem_load_valid_i;
  wire mem_can_write_alu  = mem_can_write & ~mem_is_load;
  wire mem_can_forward_load = mem_can_write_load;
  wire mem_can_forward_alu  = mem_can_write_alu;
  wire [31:0] mem_fwd_data =
      mem_is_load ? mem_load_data_i :
      (mem_wb_sel_i == 2'b10) ? mem_pc4_i :
                                mem_alu_result_i;
  wire mem_can_forward = mem_can_forward_load | mem_can_forward_alu;

  // Match checks
  wire match_mem_rs1 = mem_can_forward & (ex_rs1_idx_i == mem_rd_i) & (ex_rs1_idx_i != 5'd0);
  wire match_mem_rs2 = mem_can_forward & (ex_rs2_idx_i == mem_rd_i) & (ex_rs2_idx_i != 5'd0);

  wire match_wb_rs1  = wb_we_i & (wb_rd_i == ex_rs1_idx_i) & (wb_rd_i != 5'd0);
  wire match_wb_rs2  = wb_we_i & (wb_rd_i == ex_rs2_idx_i) & (wb_rd_i != 5'd0);

  // Priority: MEM > WB > original
  assign ex_rs1_val_o = match_mem_rs1 ? mem_fwd_data :
                        match_wb_rs1  ? wb_wdata_i   :
                                        ex_rs1_val_i;

  assign ex_rs2_val_o = match_mem_rs2 ? mem_fwd_data :
                        match_wb_rs2  ? wb_wdata_i   :
                                        ex_rs2_val_i;

endmodule
