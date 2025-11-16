`timescale 1ns/1ps
// mem_cache_top.v - Verilog-2001, positional instantiation
// Wraps mem_stage with cache_bridge_mem -> top_cache_sram (D$/I$/SRAM).

module mem_cache_top
#(
  parameter integer XLEN               = 32,
  parameter integer DCACHE_CACHE_BYTES = 32768,
  parameter integer DCACHE_LINE_BYTES  = 32,
  parameter integer DCACHE_WAYS        = 2,
  parameter integer DCACHE_WBUF_DEPTH  = 1,
  parameter [31:0] SRAM_BASE_ADDR      = 32'h0000_0000,
  parameter [31:0] SRAM_SIZE_BYTES     = 32'd230400,
  parameter [31:0] SRAM_LAST_ADDR      = 32'h0003_83FF,
  parameter [31:0] TEXT_BASE_ADDR      = 32'h0000_0000,
  parameter [31:0] TEXT_LAST_ADDR      = 32'h0000_7FFF,
  parameter [31:0] DATA_BASE_ADDR      = 32'h0000_8000,
  parameter [31:0] DATA_LAST_ADDR      = 32'h0002_7FFF,
  parameter [31:0] STACK_BASE_ADDR     = 32'h0002_8000,
  parameter [31:0] STACK_LAST_ADDR     = 32'h0003_83FF,
  parameter        SRAM_INIT_FILE      = "",
  parameter integer CLK_FREQ_HZ        = 100_000_000,
  parameter integer UART_BAUD          = 115200,
  parameter [31:0] UART_BASE_ADDR      = 32'h1000_0000,
  parameter [31:0] UART_LAST_ADDR      = 32'h1000_00FF
)
(
  input              clk,
  input              rst_n,

  // MEM stage "CPU-side" interface
  input              mem_valid_i,
  input  [31:0]      mem_alu_result_i,
  input  [31:0]      mem_store_data_i,
  input              mem_mem_read_i,
  input              mem_mem_write_i,
  input  [2:0]       mem_size_i,
  output [31:0]      mem_load_rdata_o,
  output             mem_stall_o,
  output             mem_load_valid_o,
  output             mem_load_active_o,

  // Latched memory access error
  output             mem_access_err_o,
  // One-cycle error pulse (alignment or downstream response)
  output             mem_err_event_o,

  // Instruction fetch interface (optional when integrating with a core)
  input              ifetch_valid_i,
  input  [31:0]      ifetch_addr_i,
  output [31:0]      ifetch_data_o,
  output             ifetch_stall_o,

  // Alignment fault detected before MEM stage issues a request
  input              mem_align_err_i,

  // UART pins
  input              uart_rx_i,
  output             uart_tx_o
);

  // Wires between MEM and bridge
  wire        dmem_req_o;
  wire        dmem_we_o;
  wire [31:0] dmem_addr_o;
  wire [31:0] dmem_wdata_o;
  wire [3:0]  dmem_wstrb_o;
  wire        dmem_ready_i;
  wire        dmem_rvalid_i;
  wire [31:0] dmem_rdata_i;
  wire        dmem_err_i;

  // Suppress mem_stage request when an alignment fault is detected upstream
  wire        align_err_active = mem_align_err_i & mem_valid_i;
  wire        mem_stage_valid  = mem_valid_i & ~mem_align_err_i;
  wire [31:0] mem_stage_rdata;
  wire        mem_stage_stall;
  wire        mem_stage_load_valid;
  wire        mem_stage_load_active;
  wire        store_done;

  // ------------------ mem_stage ------------------
  mem_stage u_mem (
    clk,
    rst_n,
    mem_stage_valid,
    mem_alu_result_i,
    mem_store_data_i,
    mem_mem_read_i,
    mem_mem_write_i,
    mem_size_i,
    dmem_req_o,
    dmem_we_o,
    dmem_addr_o,
    dmem_wdata_o,
    dmem_wstrb_o,
    dmem_ready_i,
    dmem_rvalid_i,
    dmem_rdata_i,
    store_done,
    mem_stage_rdata,
    mem_stage_stall,
    mem_stage_load_valid,
    mem_stage_load_active
  );

  // ---------------- cache_bridge_mem ----------------
  // Tie-off IF fetch (not used in this MEM-only top)
  wire [31:0] ifetch_data;
  wire        ifetch_stall;
  cache_bridge_mem
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
    SRAM_INIT_FILE,
    CLK_FREQ_HZ,
    UART_BAUD,
    UART_BASE_ADDR,
    UART_LAST_ADDR
  )
  u_cb (
    clk,
    rst_n,
    uart_rx_i,
    uart_tx_o,
    ifetch_valid_i,
    ifetch_addr_i,
    ifetch_data,        // fetch_data_o (unused)
    ifetch_stall,       // fetch_stall_o (unused)
    dmem_req_o,
    dmem_we_o,
    dmem_addr_o,
    dmem_wdata_o,
    dmem_wstrb_o,
    dmem_ready_i,
    dmem_rvalid_i,
    dmem_rdata_i,
    dmem_err_i,
    store_done
  );

  // Latch err alongside rvalid so TB can sample it safely
  reg err_q;
  reg align_err_seen_q;
  wire align_err_fire = align_err_active & ~align_err_seen_q;
  wire mem_err_event  = align_err_fire |
                        (dmem_rvalid_i & dmem_err_i) |
                        (store_done & dmem_err_i);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) align_err_seen_q <= 1'b0;
    else if (!mem_valid_i) align_err_seen_q <= 1'b0;
    else if (align_err_fire) align_err_seen_q <= 1'b1;
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) err_q <= 1'b0;
    else if (align_err_fire) err_q <= 1'b1;
    else if (dmem_rvalid_i) err_q <= dmem_err_i;
    else if (mem_stage_valid && mem_mem_write_i && dmem_ready_i) err_q <= dmem_err_i;
  end

  assign mem_access_err_o = err_q;
  assign mem_err_event_o  = mem_err_event;
  assign mem_load_rdata_o = align_err_active ? 32'h0 : mem_stage_rdata;
  assign mem_load_valid_o = align_err_active ? 1'b0 : mem_stage_load_valid;
  assign mem_load_active_o = align_err_active ? 1'b0 : mem_stage_load_active;
  assign mem_stall_o      = align_err_active ? 1'b1 : mem_stage_stall;
  assign ifetch_data_o    = ifetch_data;
  assign ifetch_stall_o   = ifetch_stall;

endmodule
