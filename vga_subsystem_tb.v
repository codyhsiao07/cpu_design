`timescale 1ns/1ps

module vga_subsystem_tb;
  reg         cpu_clk = 1'b0;
  reg         vga_clk = 1'b0;
  reg         rst_n = 1'b0;
  reg         cpu_req_valid = 1'b0;
  reg         cpu_req_we = 1'b0;
  reg  [31:0] cpu_req_addr = 32'd0;
  reg  [31:0] cpu_req_wdata = 32'd0;
  reg  [3:0]  cpu_req_wstrb = 4'd0;
  wire        cpu_req_ready;
  wire        cpu_rsp_valid;
  wire [31:0] cpu_rsp_rdata;
  wire        cpu_rsp_err;
  wire        hsync_o;
  wire        vsync_o;
  wire [3:0]  red_o;
  wire [3:0]  green_o;
  wire [3:0]  blue_o;

  vga_subsystem dut (
    .cpu_clk      (cpu_clk),
    .rst_n        (rst_n),
    .vga_mclk     (vga_clk),
    .cpu_req_valid(cpu_req_valid),
    .cpu_req_we   (cpu_req_we),
    .cpu_req_addr (cpu_req_addr),
    .cpu_req_wdata(cpu_req_wdata),
    .cpu_req_wstrb(cpu_req_wstrb),
    .cpu_req_ready(cpu_req_ready),
    .cpu_rsp_valid(cpu_rsp_valid),
    .cpu_rsp_rdata(cpu_rsp_rdata),
    .cpu_rsp_err  (cpu_rsp_err),
    .hsync_o      (hsync_o),
    .vsync_o      (vsync_o),
    .red_o        (red_o),
    .green_o      (green_o),
    .blue_o       (blue_o)
  );

  always #5 cpu_clk = ~cpu_clk;
  always #5 vga_clk = ~vga_clk;

  task cpu_write32;
    input [31:0] addr;
    input [31:0] data;
    begin
      @(posedge cpu_clk);
      cpu_req_addr  <= addr;
      cpu_req_wdata <= data;
      cpu_req_wstrb <= 4'hF;
      cpu_req_we    <= 1'b1;
      cpu_req_valid <= 1'b1;
      @(posedge cpu_clk);
      cpu_req_valid <= 1'b0;
      cpu_req_we    <= 1'b0;
      cpu_req_wstrb <= 4'h0;
      wait (cpu_rsp_valid === 1'b1);
      @(posedge cpu_clk);
    end
  endtask

  task cpu_read32;
    input [31:0] addr;
    input [31:0] exp;
    begin
      @(posedge cpu_clk);
      cpu_req_addr  <= addr;
      cpu_req_wdata <= 32'd0;
      cpu_req_wstrb <= 4'h0;
      cpu_req_we    <= 1'b0;
      cpu_req_valid <= 1'b1;
      @(posedge cpu_clk);
      cpu_req_valid <= 1'b0;
      wait (cpu_rsp_valid === 1'b1);
      if (cpu_rsp_err !== 1'b0) begin
        $display("VGA TB FAIL: unexpected rsp_err on read");
        $finish;
      end
      if (cpu_rsp_rdata !== exp) begin
        $display("VGA TB FAIL: readback mismatch exp=%08x got=%08x", exp, cpu_rsp_rdata);
        $display("  dbg req=%0d seen_meta=%0d seen=%0d vga_meta=%0d vga_req=%0d vga=%0d hc=%0d vc=%0d vsync=%0d q=%0d",
                 dut.front_buf_sel_cpu_q,
                 dut.front_buf_sel_seen_meta_q,
                 dut.front_buf_sel_seen_q,
                 dut.front_buf_sel_vga_meta_q,
                 dut.front_buf_sel_vga_req_q,
                 dut.front_buf_sel_vga_q,
                 dut.hc,
                 dut.vc,
                 dut.vsync_o,
                 dut.u_clkdiv.q);
        $finish;
      end
      @(posedge cpu_clk);
    end
  endtask

  initial begin
    repeat (10) @(posedge cpu_clk);
    rst_n = 1'b1;

    cpu_write32(32'h5000_0000, 32'h1234_5678);
    cpu_read32(32'h5000_0000, 32'h1234_5678);
    cpu_write32(32'h5000_4000, 32'h89ab_cdef);
    cpu_read32(32'h5000_4000, 32'h89ab_cdef);
    cpu_write32(32'h5000_7FFC, 32'h0000_0001);
    cpu_read32(32'h5000_7FFC, 32'h0000_0002);

    repeat (4200000) @(posedge vga_clk);
    cpu_read32(32'h5000_7FFC, 32'h0000_0003);
    if (dut.u_clkdiv.q == 24'd0) begin
      $display("VGA TB FAIL: clkdiv counter did not advance");
      $finish;
    end
    if (dut.u_vga_timing.hc == 10'd0) begin
      $display("VGA TB FAIL: VGA horizontal counter did not advance");
      $finish;
    end

    $display("VGA TB PASS");
    $finish;
  end
endmodule
