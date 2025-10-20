`timescale 1ns/1ps
// top_rv32i.v  -- Verilog-2001, positional port connections only
module top_rv32i (
  input         clk,
  input         rst_n,
  output        wb_we_o,
  output [4:0]  wb_rd_o,
  output [31:0] wb_wdata_o,
  output        mem_access_err_o
);

  // rv32i_core_mem_top port order:
  // (clk, rst_n, wb_we_o, wb_rd_o, wb_wdata_o, mem_access_err_o)
  rv32i_core_mem_top u_core (
    clk,
    rst_n,
    wb_we_o,
    wb_rd_o,
    wb_wdata_o,
    mem_access_err_o
  );

endmodule
