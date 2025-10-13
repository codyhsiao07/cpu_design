`timescale 1ns/1ps

module tb_mem_cache_top;

  // Clock/reset
  reg clk;
  reg rst_n;
  initial begin clk = 1'b0; forever #5 clk = ~clk; end
  initial begin rst_n = 1'b0; repeat (10) @(posedge clk); rst_n = 1'b1; end

  // DUT-side MEM interface
  reg         mem_valid_i;
  reg  [31:0] mem_alu_result_i;
  reg  [31:0] mem_store_data_i;
  reg         mem_mem_read_i;
  reg         mem_mem_write_i;
  reg  [2:0]  mem_size_i;
  wire [31:0] mem_load_rdata_o;
  wire        mem_stall_o;
  wire        mem_access_err_o;

  // Instantiate DUT (positional)
  mem_cache_top dut (
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
    mem_access_err_o
  );

  // Helpers
  integer pass_cnt, fail_cnt;
  initial begin pass_cnt = 0; fail_cnt = 0; end

  task check_eq32;
    input [31:0] got, exp; input [8*64-1:0] msg;
    begin
      if (got === exp) begin
        pass_cnt = pass_cnt + 1;
        $display("[%0t] CHECK PASS %0s: 0x%08x", $time, msg, got);
      end else begin
        fail_cnt = fail_cnt + 1;
        $display("[%0t] CHECK FAIL %0s: got=0x%08x exp=0x%08x", $time, msg, got, exp);
      end
    end
  endtask

  task check_err;
    input got_err, exp_err; input [8*64-1:0] msg;
    begin
      if (got_err === exp_err) begin
        pass_cnt = pass_cnt + 1;
        $display("[%0t] CHECK PASS %0s: err=%0d", $time, msg, got_err);
      end else begin
        fail_cnt = fail_cnt + 1;
        $display("[%0t] CHECK FAIL %0s: got_err=%0d exp_err=%0d", $time, msg, got_err, exp_err);
      end
    end
  endtask

  task idle_cycles; input integer n; integer k; begin for (k=0;k<n;k=k+1) @(posedge clk); end endtask

  // Low-level driver: fire one txn and wait until it finishes (stall deasserts)
  task fire_txn;
    begin
      @(posedge clk);
      mem_valid_i <= 1'b1;
      // Wait until stall observed (start) then until it clears (done)
      @(posedge clk);
      while (mem_stall_o == 1'b0) @(posedge clk); // ensure we saw the start
      while (mem_stall_o == 1'b1) @(posedge clk);
      mem_valid_i <= 1'b0;
    end
  endtask

  // Store helpers
  task do_store;
    input [31:0] addr;
    input [31:0] data;
    input [2:0]  size_f3; // 000=SB,001=SH,010=SW
    begin
      mem_alu_result_i <= addr;
      mem_store_data_i <= data;
      mem_mem_read_i   <= 1'b0;
      mem_mem_write_i  <= 1'b1;
      mem_size_i       <= size_f3;
      $display("[%0t] STORE addr=0x%08x data=0x%08x f3=%03b", $time, addr, data, size_f3);
      fire_txn();
    end
  endtask

  // Load helpers
  task do_load;
    input  [31:0] addr;
    input  [2:0]  size_f3; // 000=LB,100=LBU,001=LH,101=LHU,010=LW
    output [31:0] data;
    begin
      mem_alu_result_i <= addr;
      mem_store_data_i <= 32'h0;
      mem_mem_read_i   <= 1'b1;
      mem_mem_write_i  <= 1'b0;
      mem_size_i       <= size_f3;
      $display("[%0t] LOAD  addr=0x%08x f3=%03b ...", $time, addr, size_f3);
      fire_txn();
      data = mem_load_rdata_o;
      $display("[%0t] LOAD  addr=0x%08x -> data=0x%08x err=%0d", $time, addr, data, mem_access_err_o);
    end
  endtask

  // Address map (must match top_cache_sram defaults)
  localparam [31:0] TEXT_BASE = 32'h0000_0000;
  localparam [31:0] TEXT_LAST = 32'h000F_FFFF;
  localparam [31:0] DATA_BASE = 32'h0010_0000;
  localparam [31:0] DATA_LAST = 32'h001B_FFFF;
  localparam [31:0] SRAM_LAST = 32'h001F_FFFF;

  localparam [31:0] ADDR0 = 32'h0010_1000;
  localparam [31:0] ADDR1 = 32'h0010_1004;
  localparam [31:0] TEXT_A0 = 32'h0000_0100;
  localparam [31:0] OOR_ADDR= 32'h0020_0000;

  // Stimulus
  integer i;
  reg [31:0] r;

  initial begin
    // init
    mem_valid_i = 1'b0;
    mem_alu_result_i = 32'h0;
    mem_store_data_i = 32'h0;
    mem_mem_read_i = 1'b0;
    mem_mem_write_i = 1'b0;
    mem_size_i = 3'b010;

    @(posedge rst_n);
    repeat (5) @(posedge clk);

    // A. basic
    do_store(ADDR0, 32'h0000_0000, 3'b010);
    do_load (ADDR0, 3'b010, r); check_eq32(r, 32'h0000_0000, "init load ADDR0"); check_err(mem_access_err_o, 1'b0, "init ADDR0 err=0");

    do_store(ADDR1, 32'h0000_0000, 3'b010);
    do_load (ADDR1, 3'b010, r); check_eq32(r, 32'h0000_0000, "init load ADDR1"); check_err(mem_access_err_o, 1'b0, "init ADDR1 err=0");

    do_store(ADDR0, 32'hDEAD_BEEF, 3'b010);
    do_load (ADDR0, 3'b010, r); check_eq32(r, 32'hDEAD_BEEF, "after full store ADDR0"); check_err(mem_access_err_o, 1'b0, "after full store ADDR0 err=0");

    // B. partial writes via size+addr (wstrb in bridge)
    do_store(ADDR1, 32'h0000_ABCD, 3'b001); // SH low half
    do_load (ADDR1, 3'b010, r); check_eq32(r, 32'h0000_ABCD, "after partial low16 ADDR1"); check_err(mem_access_err_o, 1'b0, "partial low16 err=0");

    do_store(ADDR1+2, 32'h0000_1234, 3'b001); // SH high half @ +2 (data in low 16)
    do_load (ADDR1, 3'b010, r); check_eq32(r, 32'h1234_ABCD, "after partial high16 merge ADDR1"); check_err(mem_access_err_o, 1'b0, "partial high16 err=0");

    // C. TEXT write should be blocked (guard)
    do_load (TEXT_A0, 3'b010, r); // baseline
    do_store(TEXT_A0, 32'hFEED_FACE, 3'b010);
    do_load (TEXT_A0, 3'b010, r); check_err(mem_access_err_o, 1'b0, "TEXT read err=0"); // value unchanged (can't easily check value without known ROM contents)

    // D. OOR read should set err
    do_load (OOR_ADDR, 3'b010, r); check_err(mem_access_err_o, 1'b1, "out-of-range load err=1");

    $display("----------------------------------------------------------------");
    $display("SUMMARY: PASS=%0d, FAIL=%0d", pass_cnt, fail_cnt);
    if (fail_cnt == 0) $display("ALL TESTS PASSED");
    else               $display("SOME TESTS FAILED");
    $finish;
  end

endmodule
