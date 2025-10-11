// top_cache_sram.v - Connect icache/dcache to unified 2MB SRAM (TEXT write-protect at CPU and memory)
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

  // SRAM window & partitions (default = 0x0000_0000 .. 0x001F_FFFF, 2 MiB)
  parameter [31:0] SRAM_BASE_ADDR      = 32'h0000_0000,
  parameter [31:0] SRAM_SIZE_BYTES     = 32'd2097152,
  parameter [31:0] SRAM_LAST_ADDR      = 32'h001F_FFFF,

  parameter [31:0] TEXT_BASE_ADDR      = 32'h0000_0000,
  parameter [31:0] TEXT_LAST_ADDR      = 32'h000F_FFFF,
  parameter [31:0] DATA_BASE_ADDR      = 32'h0010_0000,
  parameter [31:0] DATA_LAST_ADDR      = 32'h001B_FFFF,
  parameter [31:0] STACK_BASE_ADDR     = 32'h001C_0000,
  parameter [31:0] STACK_LAST_ADDR     = 32'h001F_FFFF,

  // Optional memory image
  parameter        INIT_FILE           = ""
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
  output                     d_stall_st_buf
);

  // -------------------------
  // Width helpers
  localparam integer LINE_BYTES = DCACHE_LINE_BYTES;
  localparam integer LINE_BITS  = LINE_BYTES * 8;

  // -------------------------
  // Interconnect wires (I$ backing IMEM)
  wire [31:0] i_mem_addr;
  wire [31:0] i_mem_rdata;

  // -------------------------
  // CPU->Guard->D$ interface wires
  wire                 g_req_valid;
  wire                 g_req_ready;
  wire                 g_req_rw;
  wire [XLEN-1:0]      g_req_addr;
  wire [XLEN-1:0]      g_req_wdata;
  wire [XLEN/8-1:0]    g_req_wstrb;
  wire                 g_resp_valid;
  wire [XLEN-1:0]      g_resp_rdata;
  wire                 g_resp_err;

  // -------------------------
  // D$ <-> SRAM line interface
  wire                 m_req_valid;
  wire                 m_req_ready;
  wire                 m_req_write;
  wire [XLEN-1:0]      m_req_addr;
  wire [LINE_BITS-1:0] m_req_wdata;
  wire [LINE_BYTES-1:0] m_req_wstrb;
  wire                 m_resp_valid;
  wire [LINE_BITS-1:0] m_resp_rdata;
  wire                 m_resp_err;

  // -------------------------
  // I$ instance
  icache u_icache (
    .clk           (clk),
    .rst_n         (rstn),

    .fetch_valid_i (fetch_valid_i),
    .fetch_addr_i  (fetch_addr_i),
    .fetch_data_o  (fetch_data_o),
    .fetch_stall_o (fetch_stall_o),

    .mem_addr_o    (i_mem_addr),
    .mem_rdata_i   (i_mem_rdata)
  );

  // -------------------------
  // CPU-side store guard for TEXT region
  cpu_store_guard #(
    .TEXT_BASE_ADDR (TEXT_BASE_ADDR),
    .TEXT_LAST_ADDR (TEXT_LAST_ADDR)
  ) u_cpu_guard (
    .clk            (clk),
    .rstn           (rstn),

    .cpu_req_valid  (d_req_valid),
    .cpu_req_ready  (d_req_ready),
    .cpu_req_rw     (d_req_rw),
    .cpu_req_addr   (d_req_addr),
    .cpu_req_wdata  (d_req_wdata),
    .cpu_req_wstrb  (d_req_wstrb),

    .cpu_resp_valid (d_resp_valid),
    .cpu_resp_rdata (d_resp_rdata),
    .cpu_resp_err   (d_resp_err),

    .dc_req_valid   (g_req_valid),
    .dc_req_ready   (g_req_ready),
    .dc_req_rw      (g_req_rw),
    .dc_req_addr    (g_req_addr),
    .dc_req_wdata   (g_req_wdata),
    .dc_req_wstrb   (g_req_wstrb),

    .dc_resp_valid  (g_resp_valid),
    .dc_resp_rdata  (g_resp_rdata),
    .dc_resp_err    (g_resp_err)
  );

  // -------------------------
  // D$ instance (hooked to guard on CPU side)
  dcache #(
    .XLEN           (XLEN),
    .CACHE_BYTES    (DCACHE_CACHE_BYTES),
    .LINE_BYTES     (DCACHE_LINE_BYTES),
    .WAYS           (DCACHE_WAYS),
    .WRITEBUF_DEPTH (DCACHE_WBUF_DEPTH)
  ) u_dcache (
    .clk               (clk),
    .rstn              (rstn),

    .cpu_req_valid     (g_req_valid),
    .cpu_req_ready     (g_req_ready),
    .cpu_req_rw        (g_req_rw),
    .cpu_req_addr      (g_req_addr),
    .cpu_req_wdata     (g_req_wdata),
    .cpu_req_wstrb     (g_req_wstrb),
    .cpu_resp_valid    (g_resp_valid),
    .cpu_resp_rdata    (g_resp_rdata),
    .cpu_resp_err      (g_resp_err),
    .cpu_stall_ld_miss (d_stall_ld_miss),
    .cpu_stall_st_buf  (d_stall_st_buf),

    .mem_req_valid     (m_req_valid),
    .mem_req_ready     (m_req_ready),
    .mem_req_write     (m_req_write),
    .mem_req_addr      (m_req_addr),
    .mem_req_wdata     (m_req_wdata),
    .mem_req_wstrb     (m_req_wstrb),
    .mem_resp_valid    (m_resp_valid),
    .mem_resp_rdata    (m_resp_rdata),
    .mem_resp_err      (m_resp_err)
  );

  // -------------------------
  // Backing SRAM with memory-side guard as well
  sram_2mb_guard #(
    .SRAM_BASE_ADDR  (SRAM_BASE_ADDR),
    .SRAM_SIZE_BYTES (SRAM_SIZE_BYTES),
    .SRAM_LAST_ADDR  (SRAM_LAST_ADDR),

    .TEXT_BASE_ADDR  (TEXT_BASE_ADDR),
    .TEXT_LAST_ADDR  (TEXT_LAST_ADDR),
    .DATA_BASE_ADDR  (DATA_BASE_ADDR),
    .DATA_LAST_ADDR  (DATA_LAST_ADDR),
    .STACK_BASE_ADDR (STACK_BASE_ADDR),
    .STACK_LAST_ADDR (STACK_LAST_ADDR),

    .LINE_BYTES      (DCACHE_LINE_BYTES),
    .INIT_FILE       (INIT_FILE)
  ) u_sram_guard (
    .clk                 (clk),
    .rst_n               (rstn),

    // I$ port
    .imem_addr_i         (i_mem_addr),
    .imem_rdata_o        (i_mem_rdata),

    // D$ port
    .dmem_req_i          (m_req_valid),
    .dmem_ready_o        (m_req_ready),
    .dmem_we_i           (m_req_write),
    .dmem_addr_i         (m_req_addr),
    .dmem_wdata_i        (m_req_wdata),
    .dmem_wstrb_i        (m_req_wstrb),
    .dmem_resp_valid_o   (m_resp_valid),
    .dmem_resp_rdata_o   (m_resp_rdata),
    .dmem_resp_err_o     (m_resp_err)
  );

endmodule
