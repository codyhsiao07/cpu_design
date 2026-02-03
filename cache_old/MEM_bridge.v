`timescale 1ns/1ps
// cache_bridge_mem.v - pass-through bridge with UART MMIO (Verilog-2001)
module cache_bridge_mem
#(
  parameter integer XLEN               = 32,
  parameter integer DCACHE_CACHE_BYTES = 32768,
  parameter integer DCACHE_LINE_BYTES  = 32,
  parameter integer DCACHE_WAYS        = 2,
  parameter integer DCACHE_WBUF_DEPTH  = 1,
  parameter [31:0] SRAM_BASE_ADDR      = 32'h0000_0000,
  parameter [31:0] SRAM_SIZE_BYTES     = 32'd65536,
  parameter [31:0] SRAM_LAST_ADDR      = 32'h0000_FFFF,
  parameter [31:0] TEXT_BASE_ADDR      = 32'h0000_0000,
  parameter [31:0] TEXT_LAST_ADDR      = 32'h0000_3FFF,
  parameter [31:0] DATA_BASE_ADDR      = 32'h0000_4000,
  parameter [31:0] DATA_LAST_ADDR      = 32'h0000_BFFF,
  parameter [31:0] STACK_BASE_ADDR     = 32'h0000_C000,
  parameter [31:0] STACK_LAST_ADDR     = 32'h0000_FFFF,
  parameter        INIT_FILE           = "",
  parameter        USE_FPGA_SRAM       = 1'b1,
  parameter integer CLK_FREQ_HZ        = 100_000_000,
  parameter integer UART_BAUD          = 115200,
  parameter [31:0] UART_BASE_ADDR      = 32'h1000_0000,
  parameter [31:0] UART_LAST_ADDR      = 32'h1000_00FF
)(
  input                      clk,
  input                      rstn,
  input                      uart_rx_i,
  output                     uart_tx_o,

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

  // ---------------- Cache request wires ----------------
  wire cache_req_valid;
  wire cache_req_ready;
  wire cache_resp_valid;
  wire cache_resp_err;
  wire [XLEN-1:0] cache_req_addr;
  wire [XLEN-1:0] cache_req_wdata;
  wire [XLEN/8-1:0] cache_req_wstrb;
  wire [XLEN-1:0] cache_resp_rdata;
  wire cache_store_done;
  wire d_stall_ld_miss;
  wire d_stall_st_buf;

  wire addr_is_uart = (dmem_addr_o >= UART_BASE_ADDR) && (dmem_addr_o <= UART_LAST_ADDR);
  wire uart_req     = dmem_req_o & addr_is_uart;
  wire cache_req    = dmem_req_o & ~addr_is_uart;

  assign cache_req_valid = cache_req;
  assign cache_req_addr  = {dmem_addr_o[31:2], 2'b00};
  assign cache_req_wdata = dmem_wdata_o;
  assign cache_req_wstrb = dmem_wstrb_o;

  // ---------------- UART MMIO ----------------
  wire        uart_req_ready;
  wire        uart_resp_valid;
  wire [31:0] uart_resp_rdata;
  wire        uart_resp_err;
  wire        uart_store_done;
  wire        uart_store_err;

  uart_mmio
  #(
    CLK_FREQ_HZ,
    UART_BAUD
  )
  u_uart (
    clk,
    rstn,
    uart_req,
    dmem_we_o,
    dmem_addr_o,
    dmem_wdata_o,
    dmem_wstrb_o,
    uart_req_ready,
    uart_resp_valid,
    uart_resp_rdata,
    uart_resp_err,
    uart_store_done,
    uart_store_err,
    uart_rx_i,
    uart_tx_o
  );

  wire uart_req_load  = uart_req & ~dmem_we_o;
  wire uart_req_store = uart_req &  dmem_we_o;
  wire uart_req_fire  = uart_req & uart_req_ready;

  reg uart_load_pending_q;
  always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      uart_load_pending_q <= 1'b0;
    end else begin
      if (uart_resp_valid) begin
        uart_load_pending_q <= 1'b0;
      end else if (uart_req_fire && ~dmem_we_o) begin
        uart_load_pending_q <= 1'b1;
      end
    end
  end

  wire uart_resp_path = uart_load_pending_q |
                        (uart_req_load && uart_req_ready);

  // ---------------- OOR detect (cache path only) ----------------
  wire in_sram_range = (dmem_addr_o >= SRAM_BASE_ADDR) && (dmem_addr_o <= SRAM_LAST_ADDR);
  wire oor_now       = (cache_req_valid && cache_req_ready) && (~dmem_we_o) && (~in_sram_range);

  reg oor_hold_q;
  always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      oor_hold_q <= 1'b0;
    end else begin
      if (oor_now) begin
        oor_hold_q <= 1'b1;
      end else if (cache_resp_valid) begin
        oor_hold_q <= 1'b0;
      end
    end
  end

  // ---------------- Handshake back to MEM stage ----------------
  wire cache_path_ready  = cache_req_ready;
  wire cache_path_rvalid = cache_resp_valid;
  wire cache_path_err    = cache_resp_err | oor_now | oor_hold_q;

  wire uart_store_fire = uart_req_store && uart_req_ready;
  wire uart_err_value  = (uart_resp_path ? uart_resp_err : 1'b0) |
                         (uart_store_fire ? uart_store_err : 1'b0);
  wire uart_err_sel    = uart_resp_path | uart_store_fire;

  assign dmem_ready_i       = uart_req ? uart_req_ready : cache_path_ready;
  assign dmem_rvalid_i      = uart_resp_path ? uart_resp_valid : cache_path_rvalid;
  assign dmem_rdata_i       = uart_resp_path ? uart_resp_rdata : cache_resp_rdata;
  assign dmem_store_done_o  = cache_store_done | uart_store_done;
  assign dmem_err_i         = uart_err_sel ? uart_err_value : cache_path_err;

`ifndef SYNTHESIS
  always @(posedge clk) begin
    if (cache_req_valid && cache_req_ready) begin
      $display("[%0t] BRIDGE TXN we=%0d addr=0x%08x wstrb=%b wdata=0x%08x",
               $time, dmem_we_o, cache_req_addr, cache_req_wstrb, cache_req_wdata);
    end
    if (uart_req && uart_req_ready) begin
      $display("[%0t] UART MMIO TXN we=%0d addr=0x%08x data=0x%08x",
               $time, dmem_we_o, dmem_addr_o, dmem_wdata_o);
    end
    if (cache_resp_valid) begin
      $display("[%0t] BRIDGE RSP err_raw=%0d oor_now=%0d oor_hold=%0d dmem_err=%0d",
               $time, cache_resp_err, oor_now, oor_hold_q, cache_path_err);
    end
    if (uart_resp_valid) begin
      $display("[%0t] UART RSP data=0x%08x err=%0d", $time, uart_resp_rdata, uart_resp_err);
    end
  end
`endif

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
    STACK_LAST_ADDR,
    INIT_FILE,
    USE_FPGA_SRAM
  )
  u_sys (
    clk,
    rstn,
    fetch_valid_i,
    fetch_addr_i,
    fetch_data_o,
    fetch_stall_o,
    cache_req_valid,
    cache_req_ready,
    dmem_we_o,
    cache_req_addr,
    cache_req_wdata,
    cache_req_wstrb,
    cache_resp_valid,
    cache_resp_rdata,
    cache_resp_err,
    d_stall_ld_miss,
    d_stall_st_buf,
    cache_store_done
  );

endmodule
