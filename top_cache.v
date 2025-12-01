// top_cache_sram.v - Connect icache/dcache to unified 2MB SRAM using a single parametric guard
// Verilog-2001 only
`timescale 1ns/1ps

module top_cache_sram #(
  // Core data width
  parameter integer XLEN               = 32,

  // D$ parameters
  parameter integer DCACHE_CACHE_BYTES = 32768,
  parameter integer DCACHE_LINE_BYTES  = 32,
  parameter integer DCACHE_WAYS        = 2,
  parameter integer DCACHE_WBUF_DEPTH  = 1,

  // SRAM window & partitions (default FPGA-friendly size = 64 KiB)
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
  parameter        USE_FPGA_SRAM       = 1'b1  // 1: use sram_fpga (synth), 0: use sram_2mb
)(
  input                      clk,
  input                      rstn,   // active-low

  // ---- I$ core-side interface ----
  input                      fetch_valid_i,
  input      [31:0]          fetch_addr_i,
  output     [31:0]          fetch_data_o,
  output                     fetch_stall_o,

  // ---- D$ core-side interface (CPU/top side) ----
  input                      d_req_valid,
  output                     d_req_ready,
  input                      d_req_rw,        // 0=load, 1=store
  input      [XLEN-1:0]      d_req_addr,
  input      [XLEN-1:0]      d_req_wdata,
  input      [XLEN/8-1:0]    d_req_wstrb,
  output                     d_resp_valid,
  output     [XLEN-1:0]      d_resp_rdata,
  output                     d_resp_err,
  output                     d_stall_ld_miss,
  output                     d_stall_st_buf,
  output                     d_store_done
);

  // -------------------------
  // I$ <-> SRAM (imem combinational read)
  // -------------------------
  wire [31:0] i_mem_addr;
  wire [31:0] i_mem_rdata;

  icache u_icache (
    .clk           (clk),
    .rst_n         (rstn),

    // core side
    .fetch_valid_i (fetch_valid_i),
    .fetch_addr_i  (fetch_addr_i),
    .fetch_data_o  (fetch_data_o),
    .fetch_stall_o (fetch_stall_o),

    // memory side
    .mem_addr_o    (i_mem_addr),
    .mem_rdata_i   (i_mem_rdata)
  );

  // -------------------------
  // CPU-side guard (single unified mem_guard) + glue for ready/valid
  // - Blocks TEXT writes before reaching D$
  // - Out-of-range (OOR) read error is left to SRAM to signal (consistent with tests)
  // -------------------------
  wire                g_allow;
  wire [XLEN/8-1:0]   g_wstrb_mask;
  wire                g_err_unused;
  wire                guard_block_wr;
  wire                guard_block_fire;
  reg                 guard_err_pulse_q;

  mem_guard
  #(
    TEXT_BASE_ADDR, TEXT_LAST_ADDR,
    DATA_BASE_ADDR, DATA_LAST_ADDR, SRAM_BASE_ADDR, SRAM_LAST_ADDR,
    0,  // P_ALLOW_TEXT_WR   = 0 (TEXT write-protect)
    0,  // P_TEXT_WR_ERR     = 0 (don't raise err on TEXT write attempt at this layer)
    1,  // P_OOR_READ_ERR    = 1 (informational; we don't block read at this layer)
    0,  // P_OOR_WRITE_ERR   = 0
    0   // P_BLOCK_OOR_READ  = 0 (don't block reads here)
  ) u_cpu_guard (
    d_req_addr,            // addr
    d_req_rw,              // is_write
    d_req_wstrb[3:0],      // wstrb_in (word granularity on CPU side)
    g_allow,               // allow
    g_wstrb_mask[3:0],     // wstrb_out
    g_err_unused           // err (unused here)
  );

  // Glue to D$ CPU-side: if blocked, we accept immediately (ready=1) and drop the op.
  wire                    g_req_valid;
  wire                    g_req_ready;
  wire                    g_req_rw;
  wire      [XLEN-1:0]    g_req_addr;
  wire      [XLEN-1:0]    g_req_wdata;
  wire      [XLEN/8-1:0]  g_req_wstrb;
  wire                    g_resp_valid;
  wire      [XLEN-1:0]    g_resp_rdata;
  wire                    g_resp_err;

  assign g_req_valid = d_req_valid & g_allow;
  assign d_req_ready = g_allow ? g_req_ready : 1'b1;  // blocked TEXT/OOR store: handshake consumed here

  assign g_req_rw    = d_req_rw;
  assign g_req_addr  = d_req_addr;
  assign g_req_wdata = d_req_wdata;
  assign g_req_wstrb = g_wstrb_mask;

  // -------------------------
  // D$ instance (CPU side <-> mem line interface)
  // -------------------------
  wire                    m_req_valid;
  wire                    m_req_ready;
  wire                    m_req_write;
  wire      [XLEN-1:0]    m_req_addr;
  wire      [DCACHE_LINE_BYTES*8-1:0] m_req_wdata;
  wire      [DCACHE_LINE_BYTES-1:0]   m_req_wstrb;
  wire                    m_resp_valid;
  wire      [DCACHE_LINE_BYTES*8-1:0] m_resp_rdata;
  wire                    m_resp_err;

  wire                    d_store_done_core;

  dcache #(
    .XLEN           (XLEN),
    .CACHE_BYTES    (DCACHE_CACHE_BYTES),
    .LINE_BYTES     (DCACHE_LINE_BYTES),
    .WAYS           (DCACHE_WAYS),
    .WRITEBUF_DEPTH (DCACHE_WBUF_DEPTH)
  ) u_dcache (
    .clk                 (clk),
    .rstn                (rstn),

    // CPU/core side (after guard)
    .cpu_req_valid       (g_req_valid),
    .cpu_req_ready       (g_req_ready),
    .cpu_req_rw          (g_req_rw),
    .cpu_req_addr        (g_req_addr),
    .cpu_req_wdata       (g_req_wdata),
    .cpu_req_wstrb       (g_req_wstrb),
    .cpu_resp_valid      (g_resp_valid),
    .cpu_resp_rdata      (g_resp_rdata),
    .cpu_resp_err        (g_resp_err),
    .cpu_stall_ld_miss   (d_stall_ld_miss),
    .cpu_stall_st_buf    (d_stall_st_buf),
    .cpu_store_done_o    (d_store_done_core),

    // Memory line interface (to SRAM)
    .mem_req_valid       (m_req_valid),
    .mem_req_ready       (m_req_ready),
    .mem_req_write       (m_req_write),
    .mem_req_addr        (m_req_addr),
    .mem_req_wdata       (m_req_wdata),
    .mem_req_wstrb       (m_req_wstrb),
    .mem_resp_valid      (m_resp_valid),
    .mem_resp_rdata      (m_resp_rdata),
    .mem_resp_err        (m_resp_err)
  );

  // Forward dcache responses to top outputs
  // Guard a blocked store by fabricating a one-cycle completion + error pulse so MEM stage can recover.
  assign guard_block_wr   = d_req_valid & d_req_rw & ~g_allow;
  assign guard_block_fire = guard_block_wr & d_req_ready;

  always @(posedge clk or negedge rstn) begin
    if (!rstn)
      guard_err_pulse_q <= 1'b0;
    else
      guard_err_pulse_q <= guard_block_fire;
  end

  assign d_store_done = d_store_done_core | guard_err_pulse_q;
  assign d_resp_valid = g_resp_valid;
  assign d_resp_rdata = g_resp_rdata;
  assign d_resp_err   = g_resp_err | guard_err_pulse_q;

  // -------------------------
  // Unified on-chip SRAM (dual-port)
  // - Use FPGA-friendly synchronous version in synthesis
  // -------------------------
  generate
    if (USE_FPGA_SRAM) begin : gen_fpga_sram
  sram_fpga #(
    .SRAM_BASE_ADDR   (SRAM_BASE_ADDR),
    .SRAM_SIZE_BYTES  (SRAM_SIZE_BYTES),
    .SRAM_LAST_ADDR   (SRAM_LAST_ADDR),
    .LINE_BYTES       (DCACHE_LINE_BYTES),
    .INIT_FILE        (INIT_FILE)
  ) u_sram (
    .clk                  (clk),
    .rst_n                (rstn),
    .imem_addr_i          (i_mem_addr),
    .imem_rdata_o         (i_mem_rdata),
    .dmem_req_i           (m_req_valid),
    .dmem_ready_o         (m_req_ready),
    .dmem_we_i            (m_req_write),
    .dmem_addr_i          (m_req_addr),
    .dmem_wdata_i         (m_req_wdata),
    .dmem_wstrb_i         (m_req_wstrb),
    .dmem_resp_valid_o    (m_resp_valid),
    .dmem_resp_rdata_o    (m_resp_rdata),
    .dmem_resp_err_o      (m_resp_err)
  );
    end else begin : gen_model_sram
  sram_2mb #(
    .SRAM_BASE_ADDR   (SRAM_BASE_ADDR),
    .SRAM_SIZE_BYTES  (SRAM_SIZE_BYTES),
    .SRAM_LAST_ADDR   (SRAM_LAST_ADDR),
    .TEXT_BASE_ADDR   (TEXT_BASE_ADDR),
    .TEXT_LAST_ADDR   (TEXT_LAST_ADDR),
    .DATA_BASE_ADDR   (DATA_BASE_ADDR),
    .DATA_LAST_ADDR   (DATA_LAST_ADDR),
    .STACK_BASE_ADDR  (STACK_BASE_ADDR),
    .STACK_LAST_ADDR  (STACK_LAST_ADDR),
    .LINE_BYTES       (DCACHE_LINE_BYTES),
    .INIT_FILE        (INIT_FILE)
  ) u_sram (
    .clk                  (clk),
    .rst_n                (rstn),
    .imem_addr_i          (i_mem_addr),
    .imem_rdata_o         (i_mem_rdata),
    .dmem_req_i           (m_req_valid),
    .dmem_ready_o         (m_req_ready),
    .dmem_we_i            (m_req_write),
    .dmem_addr_i          (m_req_addr),
    .dmem_wdata_i         (m_req_wdata),
    .dmem_wstrb_i         (m_req_wstrb),
    .dmem_resp_valid_o    (m_resp_valid),
    .dmem_resp_rdata_o    (m_resp_rdata),
    .dmem_resp_err_o      (m_resp_err)
  );
    end
  endgenerate

endmodule
