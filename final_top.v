`timescale 1ns/1ps
// top_rv32i.v  -- Verilog-2001, positional port connections only
module top_rv32i #(
  parameter        SRAM_INIT_FILE = "",
  parameter integer CLK_FREQ_HZ   = 100_000_000,
  parameter integer UART_BAUD     = 115200,
  parameter [31:0] UART_BASE_ADDR = 32'h1000_0000,
  parameter [31:0] UART_LAST_ADDR = 32'h1000_00FF
)(
  input         clk,
  input         rst_n,
  input         uart_rx_i,
  output        uart_tx_o,
  output        wb_we_o,
  output [4:0]  wb_rd_o,
  output [31:0] wb_wdata_o,
  output        mem_access_err_o
);

  // rv32i_core_mem_top port order:
  // (clk, rst_n, uart_rx_i, uart_tx_o, wb_we_o, wb_rd_o, wb_wdata_o, mem_access_err_o)
  rv32i_core_mem_top #(
    .SRAM_INIT_FILE (SRAM_INIT_FILE),
    .CLK_FREQ_HZ    (CLK_FREQ_HZ),
    .UART_BAUD      (UART_BAUD),
    .UART_BASE_ADDR (UART_BASE_ADDR),
    .UART_LAST_ADDR (UART_LAST_ADDR)
  ) u_core (
    clk,
    rst_n,
    uart_rx_i,
    uart_tx_o,
    wb_we_o,
    wb_rd_o,
    wb_wdata_o,
    mem_access_err_o
  );

endmodule
