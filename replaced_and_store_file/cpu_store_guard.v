// cpu_store_guard.v - CPU-side guard to block stores into TEXT region before reaching D$
// Verilog-2001 only.
`timescale 1ns/1ps

module cpu_store_guard #(
  parameter [31:0] TEXT_BASE_ADDR = 32'h0000_0000,
  parameter [31:0] TEXT_LAST_ADDR = 32'h000F_FFFF
)(
  input         clk,
  input         rstn,

  // CPU/top side
  input               cpu_req_valid,
  output              cpu_req_ready,
  input               cpu_req_rw,        // 0=load, 1=store
  input  [31:0]       cpu_req_addr,
  input  [31:0]       cpu_req_wdata,
  input  [3:0]        cpu_req_wstrb,

  output              cpu_resp_valid,
  output [31:0]       cpu_resp_rdata,
  output              cpu_resp_err,

  // To D$ side
  output              dc_req_valid,
  input               dc_req_ready,
  output              dc_req_rw,
  output [31:0]       dc_req_addr,
  output [31:0]       dc_req_wdata,
  output [3:0]        dc_req_wstrb,

  input               dc_resp_valid,
  input  [31:0]       dc_resp_rdata,
  input               dc_resp_err
);

  // Detect write to TEXT
  wire is_text_write = cpu_req_valid & cpu_req_rw & (cpu_req_addr >= TEXT_BASE_ADDR) & (cpu_req_addr <= TEXT_LAST_ADDR);

  // Forward path to D$: block disallowed stores
  assign dc_req_valid = is_text_write ? 1'b0 : cpu_req_valid;
  assign dc_req_rw    = cpu_req_rw;
  assign dc_req_addr  = cpu_req_addr;
  assign dc_req_wdata = cpu_req_wdata;
  assign dc_req_wstrb = cpu_req_wstrb;

  // Ready back to CPU: accept immediately if blocking, else mirror D$ ready
  assign cpu_req_ready = is_text_write ? 1'b1 : dc_req_ready;

  // Responses: loads pass through; stores have no response. For blocked store, also no response.
  assign cpu_resp_valid = dc_resp_valid;
  assign cpu_resp_rdata = dc_resp_rdata;
  assign cpu_resp_err   = dc_resp_err;

  // Optional: print a message when we block a store
  always @(posedge clk) begin
    if (!rstn) begin
    end else if (is_text_write) begin
      // $display("[%0t] cpu_store_guard: blocked store to TEXT at addr=0x%08x", $time, cpu_req_addr);
    end
  end

endmodule
