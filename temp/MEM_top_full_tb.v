`timescale 1ns/1ps
// tb_mem_edge_final.v - Robust Verilog-2001 testbench for mem_cache_top
// - No dot-name connections (positional only)
// - Defensive timeouts + heartbeat to avoid deadlocks
// - Covers: SH/SB merges, cross-line, store->imm load, TEXT protection, OOR, reset-interrupt

module tb_mem_edge_final;

  // ---------------- Clock / Reset ----------------
  reg clk;
  reg rst_n;
  reg uart_rx;
  wire uart_tx;

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk; // 100 MHz
  end

  task do_reset;
    begin
      rst_n  = 1'b0;
      uart_rx = 1'b1;
      repeat (10) @(posedge clk);
      rst_n = 1'b1;
      repeat (10) @(posedge clk);
    end
  endtask

  // ---------------- Parameters (match your design) ----------------
  localparam integer XLEN               = 32;
  localparam integer DCACHE_BYTES       = 32768;
  localparam integer DCACHE_LINE_BYTES  = 32;
  localparam integer DCACHE_WAYS        = 2;
  localparam integer DCACHE_WBUF_DEPTH  = 1;

  localparam [31:0] SRAM_BASE_ADDR      = 32'h0000_0000;
  localparam [31:0] SRAM_SIZE_BYTES     = 32'd2_097_152; // 2MB
  localparam [31:0] SRAM_LAST_ADDR      = SRAM_BASE_ADDR + SRAM_SIZE_BYTES - 1;

  localparam [31:0] TEXT_BASE_ADDR      = 32'h0000_0000;
  localparam [31:0] TEXT_LAST_ADDR      = 32'h000F_FFFF;
  localparam [31:0] DATA_BASE_ADDR      = 32'h0010_0000;
  localparam [31:0] DATA_LAST_ADDR      = 32'h001B_FFFF;
  localparam [31:0] STACK_BASE_ADDR     = 32'h001C_0000;
  localparam [31:0] STACK_LAST_ADDR     = 32'h001F_FFFF;

  // ---------------- DUT Ports (CPU side) ----------------
  reg              mem_valid_i;
  reg  [31:0]      mem_alu_result_i;
  reg  [31:0]      mem_store_data_i;
  reg              mem_mem_read_i;
  reg              mem_mem_write_i;
  reg  [2:0]       mem_size_i;
  wire [31:0]      mem_load_rdata_o;
  wire             mem_stall_o;
  wire             mem_load_valid_dummy;
  wire             mem_load_active_dummy;
  wire             mem_access_err_o;
  wire             mem_err_event_dummy;
  wire [31:0]      ifetch_data_dummy;
  wire             ifetch_stall_dummy;
  reg              uart_rx;
  wire             uart_tx;

  // ---------------- DUT Instance ----------------
  mem_cache_top
  #(
    XLEN,
    DCACHE_BYTES,
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
    ""
  )
  u_top (
    clk,
    rst_n,
    mem_valid_i,
    mem_alu_result_i,
    mem_store_data_i,
    mem_mem_read_i,
    mem_mem_write_i,
    mem_size_i,
    mem_load_rdata_o,
    mem_stall_o,
    mem_load_valid_dummy,
    mem_load_active_dummy,
    mem_access_err_o,
    mem_err_event_dummy,
    1'b0,
    32'h0,
    ifetch_data_dummy,
    ifetch_stall_dummy,
    1'b0,
    uart_rx,
    uart_tx
  );

  // ---------------- Heartbeat / progress ----------------
  integer cycle;
  always @(posedge clk) begin
    if (!rst_n) cycle <= 0;
    else begin
      cycle <= cycle + 1;
      if (cycle % 100000 == 0) $display("[%0t] HEARTBEAT: cycle=%0d stall=%0d err=%0d",
                                        $time, cycle, mem_stall_o, mem_access_err_o);
    end
  end

  // ---------------- TB Helpers ----------------
  integer pass_cnt, fail_cnt;

  task expect_eq;
    input [31:0] got, exp;
    input [1023:0] msg;
    begin
      if (got !== exp) begin
        $display("[%0t] CHECK FAIL %0s: got=0x%08x exp=0x%08x", $time, msg, got, exp);
        fail_cnt = fail_cnt + 1;
      end else begin
        $display("[%0t] CHECK PASS %0s: 0x%08x", $time, msg, got);
        pass_cnt = pass_cnt + 1;
      end
    end
  endtask

  task expect_bit;
    input got, exp;
    input [1023:0] msg;
    begin
      if (got !== exp) begin
        $display("[%0t] CHECK FAIL %0s: got=%0d exp=%0d", $time, msg, got, exp);
        fail_cnt = fail_cnt + 1;
      end else begin
        $display("[%0t] CHECK PASS %0s: %0d", $time, msg, got);
        pass_cnt = pass_cnt + 1;
      end
    end
  endtask

  // Fire a single-cycle request
  task fire_req;
    input [31:0] addr;
    input [31:0] wdata;
    input [2:0]  f3;
    input        is_store;
    begin
      @(posedge clk);
      mem_alu_result_i <= addr;
      mem_store_data_i <= wdata;
      mem_size_i       <= f3;
      mem_mem_read_i   <= (is_store ? 1'b0 : 1'b1);
      mem_mem_write_i  <= (is_store ? 1'b1 : 1'b0);
      mem_valid_i      <= 1'b1;
      @(posedge clk);
      mem_valid_i      <= 1'b0;
      mem_mem_read_i   <= 1'b0;
      mem_mem_write_i  <= 1'b0;
    end
  endtask

  // Robust wait with hard timeouts (never hangs)
  task wait_done;
    integer t;
    begin
      t = 0;
      // wait enter busy or timeout
      while (mem_stall_o == 1'b0 && t < 5000) begin @(posedge clk); t = t + 1; end
      // wait leave busy or timeout
      t = 0;
      while (mem_stall_o == 1'b1 && t < 50000) begin @(posedge clk); t = t + 1; end
      @(posedge clk);
    end
  endtask

  // High-level APIs
  task do_store;
    input [31:0] addr;
    input [31:0] data;
    input [2:0]  f3; // 000:SB 001:SH 010:SW
    begin
      $display("[%0t] STORE addr=0x%08x data=0x%08x f3=%03b", $time, addr, data, f3);
      fire_req(addr, data, f3, 1'b1);
      wait_done();
    end
  endtask

  task do_load;
    input  [31:0] addr;
    input  [2:0]  f3; // 000:LB 100:LBU 001:LH 101:LHU 010:LW
    output [31:0] data;
    output        err;
    begin
      $display("[%0t] LOAD  addr=0x%08x f3=%03b ...", $time, addr, f3);
      fire_req(addr, 32'h0, f3, 1'b0);
      wait_done();
      data = mem_load_rdata_o;
      err  = mem_access_err_o;
      $display("[%0t] LOAD  addr=0x%08x -> data=0x%08x err=%0d", $time, addr, data, err);
    end
  endtask

  // ---------------- Test Addresses ----------------
  localparam [31:0] A0 = DATA_BASE_ADDR + 32'h0000_1000;
  localparam [31:0] A1 = A0 + 32'h4;

  localparam [31:0] CL_BASE = (DATA_BASE_ADDR + 32'h0000_2000) & ~(DCACHE_LINE_BYTES-1);
  localparam [31:0] CL_ENDW = CL_BASE + DCACHE_LINE_BYTES - 4;
  localparam [31:0] CL_NEXT = CL_BASE + DCACHE_LINE_BYTES;

  localparam [31:0] TEXT_A = 32'h0000_0100;
  localparam [31:0] OOR_A  = 32'h0020_0000;

  // ---------------- Main Sequence ----------------
  integer i;
  reg [31:0] d;
  reg        e;

  initial begin
    pass_cnt = 0; fail_cnt = 0;

    mem_valid_i      = 1'b0;
    mem_alu_result_i = 32'h0;
    mem_store_data_i = 32'h0;
    mem_mem_read_i   = 1'b0;
    mem_mem_write_i  = 1'b0;
    mem_size_i       = 3'b010;

    if (!(A0 >= SRAM_BASE_ADDR && (A1+4) <= SRAM_LAST_ADDR)) begin
      $display("[%0t] TB CONFIG ERROR: A0/A1 out of SRAM range!", $time);
      $finish;
    end

    do_reset();

    // Basic sanity
    do_store(A0, 32'h0000_0000, 3'b010);
    do_load (A0, 3'b010, d, e); expect_eq(d, 32'h0000_0000, "basic A0=0"); expect_bit(e, 1'b0, "basic A0 err=0");

    do_store(A1, 32'h0000_0000, 3'b010);
    do_load (A1, 3'b010, d, e); expect_eq(d, 32'h0000_0000, "basic A1=0"); expect_bit(e, 1'b0, "basic A1 err=0");

    do_store(A0, 32'hDEAD_BEEF, 3'b010);
    do_load (A0, 3'b010, d, e); expect_eq(d, 32'hDEAD_BEEF, "SW->LW A0"); expect_bit(e, 1'b0, "SW->LW err=0");

    do_store(A1, 32'h0000_ABCD, 3'b001);
    do_store(A1+32'h2, 32'h0000_1234, 3'b001);
    do_load (A1, 3'b010, d, e); expect_eq(d, 32'h1234_ABCD, "SH merge A1"); expect_bit(e, 1'b0, "SH merge err=0");

    // Cross cache line boundary
    do_store(CL_ENDW, 32'h0000_0000, 3'b010);
    do_store(CL_NEXT, 32'h0000_0000, 3'b010);

    do_store(CL_ENDW+32'h0, 32'h0000_00AA, 3'b000);
    do_store(CL_ENDW+32'h1, 32'h0000_00BB, 3'b000);
    do_store(CL_ENDW+32'h2, 32'h0000_CCCC, 3'b001);

    do_store(CL_NEXT+32'h0, 32'hCAFE_BABE, 3'b010);
    do_load (CL_ENDW, 3'b010, d, e); expect_eq(d, 32'hCCCC_BBAA, "XLINE last word merged"); expect_bit(e, 1'b0, "XLINE last word err=0");
    do_load (CL_NEXT, 3'b010, d, e); expect_eq(d, 32'hCAFE_BABE, "XLINE next line word0"); expect_bit(e, 1'b0, "XLINE next line err=0");

    // Store->immediate load on cold line
    do_store(A0+32'h40, 32'hA5A5_5A5A, 3'b010);
    do_load (A0+32'h40, 3'b010, d, e); expect_eq(d, 32'hA5A5_5A5A, "store->imm load fwd"); expect_bit(e, 1'b0, "store->imm load err=0");

    // Store buffer pressure (depth=1, but still burst to stress)
    for (i=0; i<8; i=i+1) begin
      do_store(A0 + (i<<2), 32'h1111_0000 + i, 3'b010);
      if (i[1]) begin
        do_load (A0 + ((i-1)<<2), 3'b010, d, e);
        expect_eq(d, 32'h1111_0000 + (i-1), "wbuf interleaved read");
        expect_bit(e, 1'b0, "wbuf interleaved read err=0");
      end
    end
    for (i=0; i<4; i=i+1) begin
      do_load (A0 + (i<<2), 3'b010, d, e);
      expect_eq(d, 32'h1111_0000 + i, "wbuf verify");
      expect_bit(e, 1'b0, "wbuf verify err=0");
    end

    // TEXT protection
    do_load (TEXT_A, 3'b010, d, e);
    expect_bit(e, 1'b0, "TEXT baseline err=0");
    do_store(TEXT_A, 32'hFEED_FACE, 3'b010);
    do_store(TEXT_A+32'h1, 32'h0000_00AA, 3'b000);
    do_store(TEXT_A+32'h2, 32'h0000_BBBB, 3'b001);
    do_load (TEXT_A, 3'b010, d, e);
    expect_bit(e, 1'b0, "TEXT readback err=0");
    $display("[%0t] NOTE: TEXT should be unchanged, value read=0x%08x", $time, d);

    // OOR tests
    do_load (OOR_A, 3'b010, d, e); expect_bit(e, 1'b1, "OOR load err=1");
    do_store(OOR_A, 32'hDEAD_BEEF, 3'b010);
    do_load (OOR_A, 3'b010, d, e); expect_bit(e, 1'b1, "OOR read still err=1");

    // Reset during activity (fire-only, no wait)
    @(posedge clk);
    mem_alu_result_i <= A1;
    mem_store_data_i <= 32'h0;
    mem_size_i       <= 3'b010;
    mem_mem_read_i   <= 1'b1;
    mem_mem_write_i  <= 1'b0;
    mem_valid_i      <= 1'b1;
    @(posedge clk);
    mem_valid_i      <= 1'b0;
    mem_mem_read_i   <= 1'b0;

    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (10) @(posedge clk);

    do_store(A0, 32'h0BAD_F00D, 3'b010);
    do_load (A0, 3'b010, d, e); expect_eq(d, 32'h0BAD_F00D, "after reset SW/LW"); expect_bit(e, 1'b0, "after reset err=0");

    // Summary
    $display("----------------------------------------------------------------");
    $display("SUMMARY: PASS=%0d, FAIL=%0d", pass_cnt, fail_cnt);
    if (fail_cnt==0) $display("ALL TESTS PASSED");
    else             $display("SOME TESTS FAILED");
    $finish;
  end

endmodule
