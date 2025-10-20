`timescale 1ns/1ps
// cache_bridge_mem.v - pass-through bridge (Verilog-2001, positional instantiation)
// MEM.v must output already-aligned wdata/wstrb.

module cache_bridge_mem
#(
  parameter integer XLEN               = 32,
  parameter integer DCACHE_CACHE_BYTES = 32768,
  parameter integer DCACHE_LINE_BYTES  = 32,
  parameter integer DCACHE_WAYS        = 2,
  parameter integer DCACHE_WBUF_DEPTH  = 1,
  parameter [31:0] SRAM_BASE_ADDR      = 32'h0000_0000,
  parameter [31:0] SRAM_SIZE_BYTES     = 32'd2097152,
  parameter [31:0] SRAM_LAST_ADDR      = 32'h001F_FFFF,
  parameter [31:0] TEXT_BASE_ADDR      = 32'h0000_0000,
  parameter [31:0] TEXT_LAST_ADDR      = 32'h000F_FFFF,
  parameter [31:0] DATA_BASE_ADDR      = 32'h0010_0000,
  parameter [31:0] DATA_LAST_ADDR      = 32'h001B_FFFF,
  parameter [31:0] STACK_BASE_ADDR     = 32'h001C_0000,
  parameter [31:0] STACK_LAST_ADDR     = 32'h001F_FFFF
)
(
  input                      clk,
  input                      rstn,

  // IF fetch (optional; tie low if unused)
  input                      fetch_valid_i,
  input      [31:0]          fetch_addr_i,
  output     [31:0]          fetch_data_o,
  output                     fetch_stall_o,

  // MEM bus (from mem_stage)
  input                      dmem_req_o,
  input                      dmem_we_o,
  input      [31:0]          dmem_addr_o,
  input      [31:0]          dmem_wdata_o,   // already aligned by MEM.v
  input      [3:0]           dmem_wstrb_o,   // already aligned by MEM.v
  output                     dmem_ready_i,
  output                     dmem_rvalid_i,
  output     [31:0]          dmem_rdata_i,
  output                     dmem_err_i,
  output                     dmem_store_done_o
);

  // Wires to top_cache_sram
  wire d_req_valid, d_req_ready, d_req_rw, d_resp_valid, d_resp_err;
  wire [XLEN-1:0] d_req_addr, d_req_wdata, d_resp_rdata;
  wire [XLEN/8-1:0] d_req_wstrb;
  wire d_stall_ld_miss, d_stall_st_buf;
  wire d_store_done;

  assign d_req_valid = dmem_req_o;
  assign d_req_rw    = dmem_we_o;
  assign d_req_addr  = {dmem_addr_o[31:2], 2'b00}; // word-align
  assign d_req_wdata = dmem_wdata_o;               // pass-through
  assign d_req_wstrb = dmem_wstrb_o;               // pass-through

  // ---------------- OOR detect (handles zero-latency and >0-latency) ----------------
  wire in_sram_range = (dmem_addr_o >= SRAM_BASE_ADDR) && (dmem_addr_o <= SRAM_LAST_ADDR);

  // "當拍"接收的越界讀事件（與 handshake 同拍成立）
  wire oor_now = (d_req_valid && d_req_ready) && (~dmem_we_o) && (~in_sram_range);

  // 撐到回覆拍的 sticky（若不是零延遲）
  reg oor_hold_q;
  always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      oor_hold_q <= 1'b0;
    end else begin
      if (oor_now)          oor_hold_q <= 1'b1; // 記下已接收的越界讀
      else if (d_resp_valid) oor_hold_q <= 1'b0; // 回覆拍清掉
    end
  end

  // 回覆/握手
  assign dmem_ready_i  = d_req_ready;
  assign dmem_rvalid_i = d_resp_valid;
  assign dmem_rdata_i  = d_resp_rdata;
  assign dmem_store_done_o = d_store_done;

  // 只要是(1)底層回覆錯誤、(2)當拍越界、或(3)之前接收過越界但回覆未到，都算錯
  assign dmem_err_i    = d_resp_err | oor_now | oor_hold_q;

  // ---------------- Debug prints ----------------
  always @(posedge clk) begin
    if (d_req_valid && d_req_ready) begin
      $display("[%0t] BRIDGE TXN we=%0d addr=0x%08x wstrb=%b wdata=0x%08x",
               $time, d_req_rw, d_req_addr, d_req_wstrb, d_req_wdata);
    end
  end

  always @(posedge clk) begin
    if (d_resp_valid) begin
      $display("[%0t] BRIDGE RSP err_raw=%0d oor_now=%0d oor_hold=%0d dmem_err=%0d",
               $time, d_resp_err, oor_now, oor_hold_q, (d_resp_err | oor_now | oor_hold_q));
    end
  end

  // ---------------- top_cache_sram ----------------
  top_cache_sram
  #(
    XLEN,
    DCACHE_CACHE_BYTES,
    DCACHE_LINE_BYTES,
    DCACHE_WAYS,
    DCACHE_WBUF_DEPTH,
    SRAM_BASE_ADDR,
    SRAM_SIZE_BYTES,
    SRAM_LAST_ADDR,
    TEXT_BASE_ADDR,
    TEXT_LAST_ADDR,
    DATA_BASE_ADDR,
    DATA_LAST_ADDR,
    STACK_BASE_ADDR,
    STACK_LAST_ADDR
  )
  u_sys (
    clk,
    rstn,
    fetch_valid_i,
    fetch_addr_i,
    fetch_data_o,
    fetch_stall_o,
    d_req_valid,
    d_req_ready,
    d_req_rw,
    d_req_addr,
    d_req_wdata,
    d_req_wstrb,
    d_resp_valid,
    d_resp_rdata,
    d_resp_err,
    d_stall_ld_miss,
    d_stall_st_buf,
    d_store_done
  );

endmodule
