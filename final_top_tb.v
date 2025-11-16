`timescale 1ns/1ps
// final_top_tb_v2001_fixed.v  (Verilog-2001; no named ports; Vivado/xsim compatible)
// Purpose: keep original PASS condition but make the testbench time-robust.
// Changes:
//   - Use realtime clock period to avoid integer-division truncation.
//   - Default timeout is defined in ABSOLUTE TIME (1 s) and auto-converted to cycles.
//   - Keep positional-only instantiation and original PASS/FAIL rules.
//
// Usage examples:
//   - Default (timeout ~= 1s at 100 MHz):           xsim ...
//   - Override timeout by cycles:                   xsim ... --testplusarg "timeout=50000000"
//   - Hint diverse program (ensure min cycles):     xsim ... --testplusarg "diverse"
//   - Hold reset longer:                            xsim ... --testplusarg "rst_hold=20"
//
// PASS rule (unchanged): when DUT writes back x4 = 0x00000011 (17).
// FAIL rule: mem_access_err asserted, or timeout.

module tb_top_rv32i_inline;

  // ---------------------------------------------------------------------------
  // Clock & Reset
  // ---------------------------------------------------------------------------
  reg         clk;
  reg         rst_n;

  // ---------------------------------------------------------------------------
  // Minimal writeback taps (as in your original TB)
  // ---------------------------------------------------------------------------
  reg         uart_rx;
  wire        uart_tx;
  wire        wb_we;
  wire [4:0]  wb_rd;
  wire [31:0] wb_wdata;
  wire        mem_access_err;
  wire        uart_req_fire = dut.u_core.u_mem_top.u_cb.u_uart.req_valid_i &
                              dut.u_core.u_mem_top.u_cb.u_uart.req_we_i &
                              dut.u_core.u_mem_top.u_cb.u_uart.req_ready_o;
  wire [7:0]  uart_tx_byte  = dut.u_core.u_mem_top.u_cb.u_uart.req_wdata_i[7:0];

  // ---------------------------------------------------------------------------
  // Instantiate DUT (positional only; no named ports)
  // top_rv32i port order must match:
  // (clk, rst_n, uart_rx_i, uart_tx_o, wb_we, wb_rd, wb_wdata, mem_access_err)
  // ---------------------------------------------------------------------------
  top_rv32i #(
    .UART_BAUD(5_000_000)
  ) dut (
    clk,
    rst_n,
    uart_rx,
    uart_tx,
    wb_we,
    wb_rd,
    wb_wdata,
    mem_access_err
  );

  // ---------------------------------------------------------------------------
  // Parameters / Plusargs
  // ---------------------------------------------------------------------------
  // Clock: 100 MHz (10 ns period) using realtime to avoid truncation
  localparam realtime CLK_PERIOD_NS            = 10.0;      // 100 MHz => 10 ns
  // Default timeout target in ABSOLUTE TIME (nanoseconds). 1 second here.
  localparam integer  TIMEOUT_NS_DEFAULT       = 1000000000; // 1 s in ns
  localparam integer  RST_HOLD_CYCLES_DEFAULT  = 8;          // default reset length

  integer timeout_cycles;     // effective timeout (in cycles)
  integer rst_hold_cycles;    // effective reset hold (in cycles)
  real    _tmp_real;          // helper for real->int conversion

  // Clock generation (exact 100 MHz)
  initial clk = 1'b0;
  always #(CLK_PERIOD_NS/2.0) clk = ~clk;
  initial uart_rx = 1'b1; // idle high

  // Optional VCD (guarded)
`ifdef DUMP_VCD
  initial begin
    $dumpfile("tb.vcd");
    $dumpvars(0, tb_top_rv32i_inline);
  end
`endif

  // Configure plusargs, auto-convert timeout from absolute ns to cycles, and handle reset
  initial begin
    // Convert absolute ns to cycles by default
    _tmp_real      = TIMEOUT_NS_DEFAULT / CLK_PERIOD_NS; // real calc
    timeout_cycles = _tmp_real;                          // truncate to integer cycles
    rst_hold_cycles = RST_HOLD_CYCLES_DEFAULT;

    // Allow overriding by plusargs (timeout in cycles)
    if ($value$plusargs("timeout=%d", timeout_cycles)) begin
      $display("%0t TB: timeout set by plusarg to %0d cycles", $time, timeout_cycles);
    end
    if ($value$plusargs("rst_hold=%d", rst_hold_cycles)) begin
      $display("%0t TB: rst_hold set by plusarg to %0d cycles", $time, rst_hold_cycles);
    end
    if ($test$plusargs("diverse")) begin
      if (timeout_cycles < 20000) timeout_cycles = 20000;
      $display("%0t TB: +diverse detected, timeout bumped to %0d cycles", $time, timeout_cycles);
    end

    // Reset sequence (active-low)
    rst_n = 1'b0;
    repeat (2) @(negedge clk);               // small settle
    repeat (rst_hold_cycles) @(negedge clk);
    rst_n = 1'b1;
  end

  // ---------------------------------------------------------------------------
  // Cycle counter & progress
  // ---------------------------------------------------------------------------
  integer cyc;
  always @(posedge clk) begin
    if (!rst_n) cyc <= 0;
    else        cyc <= cyc + 1;
  end

  // Progress heartbeat every 1000 cycles
  always @(posedge clk) begin
    if (rst_n) begin
      if ((cyc % 1000) == 0 && cyc != 0) begin
        $display("%0t  TB: cycle %0d ...", $time, cyc);
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Monitors: writeback + PASS/FAIL
  // ---------------------------------------------------------------------------
  // Show all register writebacks
  always @(posedge clk) begin
    if (rst_n && wb_we) begin
      $display("%0t  WB: x%0d <= 0x%08h", $time, wb_rd, wb_wdata);
    end
  end

  // PASS: when x4 gets 0x00000011 (17)
  always @(posedge clk) begin
    if (rst_n && wb_we && (wb_rd == 5'd4) && (wb_wdata == 32'h00000011)) begin
      $display("%0t  PROGRAM PASS (rd4=0x00000011)", $time);
      #20 $finish;
    end
  end

  // UART MMIO write monitor
  always @(posedge clk) begin
    if (rst_n && uart_req_fire) begin
      $display("%0t  UART TX BYTE = 0x%02h", $time, uart_tx_byte);
    end
  end

  // FAIL on memory access error
  always @(posedge clk) begin
    if (rst_n && mem_access_err) begin
      $display("%0t  MEM_ACCESS_ERR asserted -> FAIL", $time);
      #20 $finish;
    end
  end

  // Timeout guard (in cycles)
  always @(posedge clk) begin
    if (rst_n && (cyc > timeout_cycles)) begin
      $display("%0t  TIMEOUT after %0d cycles -> FAIL", $time, timeout_cycles);
      #20 $finish;
    end
  end

endmodule
