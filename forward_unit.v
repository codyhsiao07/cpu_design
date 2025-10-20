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
  input  [4:0]  ex_rs1_idx_i,
  input  [4:0]  ex_rs2_idx_i,
  input  [31:0] ex_rs1_val_i,
  input  [31:0] ex_rs2_val_i,

  // MEM stage producer (EX/MEM register outputs)
  input         mem_valid_i,
  input         mem_reg_write_i,
  input  [1:0]  mem_wb_sel_i,     // 00:ALU, 01:MEM(load), 10:PC+4
  input  [4:0]  mem_rd_i,
  input  [31:0] mem_alu_result_i,
  input  [31:0] mem_pc4_i,
  input         mem_load_valid_i,
  input  [31:0] mem_load_data_i,

  // WB stage producer (after MEM/WB mux)
  input         wb_we_i,
  input  [4:0]  wb_rd_i,
  input  [31:0] wb_wdata_i,

  // Forwarded operands to EX stage
  output [31:0] ex_rs1_val_o,
  output [31:0] ex_rs2_val_o
);

  // Determine candidate value from MEM stage
  // Only valid to forward when producer is valid, will write, rd!=0, and the
  // value is actually available in MEM stage this cycle (i.e., not a LOAD data yet).
  wire mem_can_write_base = mem_valid_i & mem_reg_write_i & (mem_rd_i != 5'd0);
  wire mem_can_write_load = mem_load_valid_i & mem_reg_write_i & (mem_rd_i != 5'd0);
  wire mem_can_write   = mem_can_write_base | mem_can_write_load;
  wire mem_is_load     = (mem_wb_sel_i == 2'b01);
  wire mem_can_forward_load = mem_is_load && mem_load_valid_i;
  wire mem_can_forward_alu  = ~mem_is_load;
  wire [31:0] mem_fwd_data =
      mem_is_load ? mem_load_data_i :
      (mem_wb_sel_i == 2'b10) ? mem_pc4_i :
                                mem_alu_result_i;
  wire mem_can_forward = mem_can_write & (mem_can_forward_load | mem_can_forward_alu);

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
