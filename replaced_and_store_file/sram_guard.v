// sram_2mb_guard.v - Write-protection wrapper for sram_2mb (strict)
// Blocks writes into TEXT region (read-only) or outside SRAM window.
// Ensures the underlying SRAM never sees a write on disallowed addresses.
// Verilog-2001 only.
`timescale 1ns/1ps

module sram_2mb_guard #(
  parameter [31:0] SRAM_BASE_ADDR      = 32'h0000_0000,
  parameter [31:0] SRAM_SIZE_BYTES     = 32'd2097152, // 2 MiB
  parameter [31:0] SRAM_LAST_ADDR      = 32'h001F_FFFF,

  parameter [31:0] TEXT_BASE_ADDR      = 32'h0000_0000,
  parameter [31:0] TEXT_LAST_ADDR      = 32'h000F_FFFF,
  parameter [31:0] DATA_BASE_ADDR      = 32'h0010_0000,
  parameter [31:0] DATA_LAST_ADDR      = 32'h001B_FFFF,
  parameter [31:0] STACK_BASE_ADDR     = 32'h001C_0000,
  parameter [31:0] STACK_LAST_ADDR     = 32'h001F_FFFF,

  parameter integer LINE_BYTES         = 32,
  parameter        INIT_FILE           = ""
)(
  input         clk,
  input         rst_n,

  // Instruction-side (combinational read port)
  input  [31:0] imem_addr_i,
  output [31:0] imem_rdata_o,

  // Data-side (cache-line request/response)
  input               dmem_req_i,
  output              dmem_ready_o,
  input               dmem_we_i,
  input  [31:0]       dmem_addr_i,
  input  [LINE_BYTES*8-1:0] dmem_wdata_i,
  input  [LINE_BYTES-1:0]   dmem_wstrb_i,
  output              dmem_resp_valid_o,
  output [LINE_BYTES*8-1:0] dmem_resp_rdata_o,
  output              dmem_resp_err_o
);

  // Region detects
  wire in_sram  = (dmem_addr_i >= SRAM_BASE_ADDR)  && (dmem_addr_i <= SRAM_LAST_ADDR);
  wire in_text  = (dmem_addr_i >= TEXT_BASE_ADDR)  && (dmem_addr_i <= TEXT_LAST_ADDR);

  // Disallowed if write to TEXT or outside SRAM window
  wire disallowed_write = dmem_req_i & dmem_we_i & (~in_sram | in_text);

  // Requests we actually forward to the underlying SRAM.
  wire pass_req = dmem_req_i & ~disallowed_write;

  // Gate WE/WSTRB so the underlying never sees a WRITE on disallowed addresses.
  wire fwd_we           = dmem_we_i     & ~disallowed_write;
  wire [LINE_BYTES-1:0] fwd_wstrb       = disallowed_write ? {LINE_BYTES{1'b0}} : dmem_wstrb_i;
  wire [LINE_BYTES*8-1:0] fwd_wdata     = dmem_wdata_i; // data doesn't matter when wstrb=0

  // Ready: if we're swallowing a disallowed write, we can claim ready immediately.
  wire mem_ready;
  assign dmem_ready_o = disallowed_write ? 1'b1 : mem_ready;

  // Responses: For swallowed writes, there is no response (writes have none anyway).
  wire                mem_resp_valid;
  wire [LINE_BYTES*8-1:0] mem_resp_rdata;
  wire                mem_resp_err;

  assign dmem_resp_valid_o = mem_resp_valid; // reads unaffected; writes don't produce resp
  assign dmem_resp_rdata_o = mem_resp_rdata;
  assign dmem_resp_err_o   = mem_resp_err;   // keep underlying error semantics

  // Underlying SRAM instance
  sram_2mb #(
    .SRAM_BASE_ADDR  (SRAM_BASE_ADDR),
    .SRAM_SIZE_BYTES (SRAM_SIZE_BYTES),
    .SRAM_LAST_ADDR  (SRAM_LAST_ADDR),

    .TEXT_BASE_ADDR  (TEXT_BASE_ADDR),
    .TEXT_LAST_ADDR  (TEXT_LAST_ADDR),
    .DATA_BASE_ADDR  (DATA_BASE_ADDR),
    .DATA_LAST_ADDR  (DATA_LAST_ADDR),
    .STACK_BASE_ADDR (STACK_BASE_ADDR),
    .STACK_LAST_ADDR (STACK_LAST_ADDR),

    .LINE_BYTES      (LINE_BYTES),
    .INIT_FILE       (INIT_FILE)
  ) u_mem (
    .clk                 (clk),
    .rst_n               (rst_n),

    .imem_addr_i         (imem_addr_i),
    .imem_rdata_o        (imem_rdata_o),

    .dmem_req_i          (pass_req),
    .dmem_ready_o        (mem_ready),
    .dmem_we_i           (fwd_we),
    .dmem_addr_i         (dmem_addr_i),
    .dmem_wdata_i        (fwd_wdata),
    .dmem_wstrb_i        (fwd_wstrb),
    .dmem_resp_valid_o   (mem_resp_valid),
    .dmem_resp_rdata_o   (mem_resp_rdata),
    .dmem_resp_err_o     (mem_resp_err)
  );

endmodule
