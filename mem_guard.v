`timescale 1ns/1ps
// mem_guard.v  -- Verilog-2001, positional ports only

module mem_guard
#(
  parameter [31:0] P_TEXT_BASE = 32'h0000_0000,
  parameter [31:0] P_TEXT_LAST = 32'h000F_FFFF,
  parameter [31:0] P_DATA_BASE = 32'h0010_0000,
  parameter [31:0] P_DATA_LAST = 32'h001B_FFFF,
  parameter [31:0] P_SRAM_LAST = 32'h001F_FFFF,
  parameter        P_ALLOW_TEXT_WR   = 0, // 1: TEXT can be written; 0: block
  parameter        P_TEXT_WR_ERR     = 0, // 1: raise err on TEXT write attempt
  parameter        P_OOR_READ_ERR    = 1, // 1: raise err on out-of-range read
  parameter        P_OOR_WRITE_ERR   = 0, // 1: raise err on out-of-range write
  parameter        P_BLOCK_OOR_READ  = 0  // 1: block OOR read at guard
)
(
  input  [31:0] addr,
  input         is_write,
  input  [3:0]  wstrb_in,
  output        allow,
  output [3:0]  wstrb_out,
  output        err
);

  wire in_text = (addr >= P_TEXT_BASE) && (addr <= P_TEXT_LAST);
  wire in_data = (addr >= P_DATA_BASE) && (addr <= P_DATA_LAST);
  wire in_sram = (addr <= P_SRAM_LAST);
  wire oor     = ~in_sram;

  wire deny_text_wr = is_write & in_text & (P_ALLOW_TEXT_WR == 0);
  wire deny_oor_wr  = is_write & oor;
  wire deny_oor_rd  = (~is_write) & oor & (P_BLOCK_OOR_READ != 0);

  wire allow_wr = ~(deny_text_wr | deny_oor_wr);
  wire allow_rd = ~(deny_oor_rd);

  assign allow    = is_write ? allow_wr : allow_rd;
  assign wstrb_out= (is_write && allow_wr) ? wstrb_in : 4'b0000;

  wire err_text_wr = is_write  & in_text & (P_ALLOW_TEXT_WR == 0) & (P_TEXT_WR_ERR   != 0);
  wire err_oor_rd  = (~is_write) & oor    & (P_OOR_READ_ERR  != 0);
  wire err_oor_wr  = is_write  & oor      & (P_OOR_WRITE_ERR != 0);

  assign err = err_text_wr | err_oor_rd | err_oor_wr;

endmodule
