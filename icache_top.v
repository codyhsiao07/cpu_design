`timescale 1ns/1ps
// icache_top.v - Thin wrapper around i_cache with a simple fetch interface.
// - Ties off flush/invalidate for now.
// - Exposes the L2 refill interface to the outside world.

module icache_top #(
  parameter ADDR_WIDTH  = 32,
  parameter L2_DATA_W   = 64,
  parameter CACHE_BYTES = 65536,
  parameter LINE_BYTES  = 64,
  parameter NUM_WAYS    = 2,
  parameter OFFSET_BITS = 6,
  parameter INDEX_BITS  = 9,
  parameter TAG_BITS    = (ADDR_WIDTH - OFFSET_BITS - INDEX_BITS),
  parameter UNC_BASE    = 32'h0000_0000,
  parameter UNC_MASK    = 32'h0000_0000
) (
  input                   clk,
  input                   rst_n,

  // Fetch request/response
  input                   fetch_req_valid_i,
  input  [ADDR_WIDTH-1:0] fetch_req_addr_i,
  input                   fetch_req_kill_i,
  output                  fetch_req_ready_o,

  output                  fetch_resp_valid_o,
  input                   fetch_resp_ready_i,
  output [31:0]           fetch_resp_inst_o,
  output [ADDR_WIDTH-1:0] fetch_resp_pc_o,
  output                  fetch_resp_err_o,

  // L2 interface
  output                  l2_req_valid,
  input                   l2_req_ready,
  output [ADDR_WIDTH-1:0] l2_req_addr,
  output [1:0]            l2_req_cmd,
  output [2:0]            l2_req_size,
  output [7:0]            l2_req_len,

  input                   l2_rsp_valid,
  output                  l2_rsp_ready,
  input  [L2_DATA_W-1:0]  l2_rsp_data,
  input                   l2_rsp_last,
  input                   l2_rsp_err
);

  wire ic_flush_ack;
  wire ic_inv_ack;

  i_cache #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .CACHE_BYTES(CACHE_BYTES),
    .LINE_BYTES (LINE_BYTES),
    .NUM_WAYS   (NUM_WAYS),
    .OFFSET_BITS(OFFSET_BITS),
    .INDEX_BITS (INDEX_BITS),
    .TAG_BITS   (TAG_BITS),
    .L2_DATA_W  (L2_DATA_W),
    .UNC_BASE   (UNC_BASE),
    .UNC_MASK   (UNC_MASK)
  ) u_icache (
    .clk           (clk),
    .rst_n         (rst_n),

    .if_req_valid  (fetch_req_valid_i),
    .if_req_addr   (fetch_req_addr_i),
    .if_req_ready  (fetch_req_ready_o),
    .if_req_kill   (fetch_req_kill_i),

    .if_resp_valid (fetch_resp_valid_o),
    .if_resp_ready (fetch_resp_ready_i),
    .if_resp_inst  (fetch_resp_inst_o),
    .if_resp_pc    (fetch_resp_pc_o),
    .if_resp_err   (fetch_resp_err_o),

    .ic_flush_req  (1'b0),
    .ic_flush_ack  (ic_flush_ack),
    .ic_inv_valid  (1'b0),
    .ic_inv_all    (1'b0),
    .ic_inv_index  ({INDEX_BITS{1'b0}}),
    .ic_inv_way    (1'b0),
    .ic_inv_ack    (ic_inv_ack),

    .l2_req_valid  (l2_req_valid),
    .l2_req_ready  (l2_req_ready),
    .l2_req_addr   (l2_req_addr),
    .l2_req_cmd    (l2_req_cmd),
    .l2_req_size   (l2_req_size),
    .l2_req_len    (l2_req_len),

    .l2_rsp_valid  (l2_rsp_valid),
    .l2_rsp_ready  (l2_rsp_ready),
    .l2_rsp_data   (l2_rsp_data),
    .l2_rsp_last   (l2_rsp_last),
    .l2_rsp_err    (l2_rsp_err)
  );

endmodule
