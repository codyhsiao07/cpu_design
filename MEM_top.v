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

  // Latched memory access error
  output             mem_access_err_o
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

  // ------------------ mem_stage ------------------
  mem_stage u_mem (
    clk,
    rst_n,
    mem_valid_i,
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
    mem_load_rdata_o,
    mem_stall_o
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
    STACK_LAST_ADDR
  )
  u_cb (
    clk,
    rst_n,
    1'b0,               // fetch_valid_i
    32'b0,              // fetch_addr_i
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
    dmem_err_i
  );

  // Latch err alongside rvalid so TB can sample it safely
  reg err_q;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) err_q <= 1'b0;
    else if (dmem_rvalid_i) err_q <= dmem_err_i;
    else if (mem_valid_i && ~mem_mem_read_i && dmem_ready_i) err_q <= 1'b0; // clear after store
  end

  assign mem_access_err_o = err_q;

endmodule
