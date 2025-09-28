// wb_stage.v
// Write-Back stage (Verilog-2001)
// - Consumes MEM/WB payload: destination register index, write-enable, write data
// - Drives register file write port and optional WB forwarding taps
module wb_stage (
  input               clk,
  input               rst_n,

  // From MEM/WB pipeline register
  input               i_valid,      // This cycle has a valid WB payload
  input        [4:0]  i_rd,         // Destination register index
  input               i_rd_wen,     // Write enable for destination
  input        [31:0] i_wb_wdata,   // Data selected by MEM/WB mux

  // To Register File (write port)
  output              rf_we_o,      // Regfile write enable
  output       [4:0]  rf_waddr_o,   // Regfile write address
  output       [31:0] rf_wdata_o,   // Regfile write data

  // Optional WB forwarding/bypass outputs (for observability or simple bypass)
  output              wb_fwd_valid_o,
  output       [4:0]  wb_fwd_rd_o,
  output       [31:0] wb_fwd_data_o
);
  parameter XLEN = 32;

  // Never write x0 on RISC-V
  wire rd_is_x0 = (i_rd == 5'd0);
  wire do_write = i_valid & i_rd_wen & ~rd_is_x0;

  // Register file write port
  assign rf_we_o     = do_write;
  assign rf_waddr_o  = i_rd;
  assign rf_wdata_o  = i_wb_wdata;

  // WB forwarding
  assign wb_fwd_valid_o = do_write;
  assign wb_fwd_rd_o    = i_rd;
  assign wb_fwd_data_o  = i_wb_wdata;

endmodule

