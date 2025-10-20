`timescale 1ns/1ps
// Verilog-2001 only. No dot-name connections.

module tb_mem_full;

  // -------- Clock / Reset --------
  reg clk;
  reg rst_n;
  initial begin
    clk = 0;
    forever #5 clk = ~clk; // 100MHz
  end

  task do_reset;
    begin
      rst_n = 0;
      repeat (10) @(posedge clk);
      rst_n = 1;
      repeat (10) @(posedge clk);
    end
  endtask

  // -------- DUT: mem_cache_top --------
  // Keep parameters consistent with your system
  localparam XLEN               = 32;
  localparam DCACHE_BYTES       = 32768;
  localparam DCACHE_LINE_BYTES  = 32;
  localparam DCACHE_WAYS        = 2;
  localparam DCACHE_WBUF_DEPTH  = 1;

  localparam [31:0] SRAM_BASE_ADDR  = 32'h0000_0000;
  localparam [31:0] SRAM_SIZE_BYTES = 32'd2_097_152; // 2MB
  localparam [31:0] SRAM_LAST_ADDR  = SRAM_BASE_ADDR + SRAM_SIZE_BYTES - 1;

  localparam [31:0] TEXT_BASE_ADDR  = 32'h0000_0000;
  localparam [31:0] TEXT_LAST_ADDR  = 32'h000F_FFFF;
  localparam [31:0] DATA_BASE_ADDR  = 32'h0010_0000;
  localparam [31:0] DATA_LAST_ADDR  = 32'h001B_FFFF;
  localparam [31:0] STACK_BASE_ADDR = 32'h001C_0000;
  localparam [31:0] STACK_LAST_ADDR = 32'h001F_FFFF;

  // CPU-side ports
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

  // Positional instantiation (no dot)
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
    STACK_LAST_ADDR
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
    1'b0
  );

  // -------- TB helpers --------
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

  // Fire a single-cycle request; MEM will latch and assert stall during txn
  task fire_req;
    input [31:0] addr;
    input [31:0] wdata;
    input [2:0]  f3;      // size/funct3
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

  // Wait until MEM not busy
  task wait_done;
    begin
      // wait enter busy
      while (mem_stall_o == 1'b0) @(posedge clk);
      // wait leave busy
      while (mem_stall_o == 1'b1) @(posedge clk);
      // one more to settle
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
    input [31:0] addr;
    input [2:0]  f3; // 000:LB 100:LBU 001:LH 101:LHU 010:LW
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

  // -------- Test space / golden model for random --------
  localparam [31:0] A0 = DATA_BASE_ADDR + 32'h0000_1000;
  localparam [31:0] A1 = A0 + 32'h4;
  localparam [31:0] TEXT_A = 32'h0000_0100;
  localparam [31:0] OOR_A  = 32'h0020_0000;
  
  
  initial begin
    if (!(A0 >= SRAM_BASE_ADDR && (A1+4) <= SRAM_LAST_ADDR)) begin
      $display("[%0t] TB CONFIG ERROR: A0/A1 out of SRAM range!", $time);
      $stop;
    end
  end
  // Small scoreboard region (256 words)
  reg [31:0] model [0:255];
  integer i;

  function [31:0] model_read_word;
    input [31:0] addr;
    reg [31:0] base;
    begin
      base = {addr[31:2], 2'b00};
      model_read_word = model[(base - A0)>>2];
    end
  endfunction

  task model_write_masked;
    input [31:0] addr;
    input [31:0] data;
    input [3:0]  wstrb; // byte mask
    integer idx;
    reg [31:0] oldv, newv;
    begin
      idx = (({addr[31:2],2'b00} - A0)>>2);
      oldv = model[idx];
      newv = oldv;
      if (wstrb[0]) newv[7:0]   = data[7:0];
      if (wstrb[1]) newv[15:8]  = data[15:8];
      if (wstrb[2]) newv[23:16] = data[23:16];
      if (wstrb[3]) newv[31:24] = data[31:24];
      model[idx] = newv;
    end
  endtask

  // Helper to build wstrb like DUT (SB/SH/SW)
  function [3:0] mk_wstrb_tb;
    input [2:0] f3;
    input [1:0] a_lo;
    begin
      case (f3[1:0])
        2'b00: mk_wstrb_tb = (4'b0001 << a_lo);           // SB
        2'b01: mk_wstrb_tb = a_lo[1] ? 4'b1100 : 4'b0011; // SH
        default: mk_wstrb_tb = 4'b1111;                   // SW
      endcase
    end
  endfunction

  // -------- Main sequence --------
  reg [31:0] d;
  reg        e;
  integer n, idx, off, op;
  reg [31:0] base, a, w, got;

  initial begin
    pass_cnt = 0; fail_cnt = 0;
    mem_valid_i = 0;
    mem_alu_result_i = 0;
    mem_store_data_i = 0;
    mem_mem_read_i = 0;
    mem_mem_write_i = 0;
    mem_size_i = 3'b010;

    // init model space
    for (i=0; i<256; i=i+1) model[i] = 32'h0;

    do_reset();

    // 1) 初始讀（DATA 區兩個 word）
    do_store(A0, 32'h0000_0000, 3'b010);
    do_load (A0, 3'b010, d, e); expect_eq(d, 32'h0000_0000, "init load A0"); expect_bit(e, 1'b0, "init A0 err=0");

    do_store(A1, 32'h0000_0000, 3'b010);
    do_load (A1, 3'b010, d, e); expect_eq(d, 32'h0000_0000, "init load A1"); expect_bit(e, 1'b0, "init A1 err=0");

    // 2) SW → 立即 LW
    do_store(A0, 32'hDEAD_BEEF, 3'b010);
    do_load (A0, 3'b010, d, e); expect_eq(d, 32'hDEAD_BEEF, "after SW A0"); expect_bit(e, 1'b0, "after SW A0 err=0");

    // 3) SH 低半 → 讀 word
    do_store(A1, 32'h0000_ABCD, 3'b001); // SH@+0 取低16
    do_load (A1, 3'b010, d, e); expect_eq(d, 32'h0000_ABCD, "SH low16 A1"); expect_bit(e, 1'b0, "SH low16 err=0");

    // 4) SH 高半（關鍵案）→ 合併應成 0x1234ABCD
    do_store(A1+32'h2, 32'h0000_1234, 3'b001); // SH@+2 仍用低16；MEM 對齊到高半
    do_load (A1, 3'b010, d, e); expect_eq(d, 32'h1234_ABCD, "SH high16 merge A1"); expect_bit(e, 1'b0, "SH high16 err=0");

    // 5) SB 矩陣（四個 byte lane）
    do_store(A0, 32'h0000_0000, 3'b010); // clear
    do_store(A0+32'h0, 32'h0000_00_11, 3'b000); // byte0 = 0x11
    do_store(A0+32'h1, 32'h0000_00_22, 3'b000); // byte1 = 0x22
    do_store(A0+32'h2, 32'h0000_00_33, 3'b000); // byte2 = 0x33
    do_store(A0+32'h3, 32'h0000_00_44, 3'b000); // byte3 = 0x44
    do_load (A0, 3'b010, d, e); expect_eq(d, 32'h4433_2211, "SB matrix merge A0"); expect_bit(e, 1'b0, "SB matrix err=0");

    // 6) 符號/零擴展（基於上面的 44 33 22 11）
    do_load (A0+32'h0, 3'b000, d, e); expect_eq(d, {{24{1'b0}},8'h11}, "L B  @+0"); expect_bit(e, 1'b0, "LB @+0 err");
    do_load (A0+32'h0, 3'b100, d, e); expect_eq(d, {24'h0,8'h11},      "L BU @+0"); expect_bit(e, 1'b0, "LBU @+0 err");
    do_load (A0+32'h1, 3'b000, d, e); expect_eq(d, {{24{1'b0}},8'h22}, "L B  @+1"); expect_bit(e, 1'b0, "LB @+1 err");
    do_load (A0+32'h1, 3'b100, d, e); expect_eq(d, {24'h0,8'h22},      "L BU @+1"); expect_bit(e, 1'b0, "LBU @+1 err");

    do_load (A0+32'h0, 3'b001, d, e); expect_eq(d, {{16{1'b0}},16'h2211}, "L H  @+0"); expect_bit(e, 1'b0, "LH  @+0 err");
    do_load (A0+32'h0, 3'b101, d, e); expect_eq(d, {16'h0,16'h2211},      "L HU @+0"); expect_bit(e, 1'b0, "LHU @+0 err");
    do_load (A0+32'h2, 3'b001, d, e); expect_eq(d, {{16{1'b0}},16'h4433}, "L H  @+2"); expect_bit(e, 1'b0, "LH  @+2 err");
    do_load (A0+32'h2, 3'b101, d, e); expect_eq(d, {16'h0,16'h4433},      "L HU @+2"); expect_bit(e, 1'b0, "LHU @+2 err");

    // 7) TEXT 區不可寫（寫了也讀不回）
    do_load (TEXT_A, 3'b010, d, e); // baseline
    do_store(TEXT_A, 32'hFEED_FACE, 3'b010);
    do_load (TEXT_A, 3'b010, d, e);
    expect_bit(e, 1'b0, "TEXT read err=0");
    // 讀值不變（不可寫）；若你有已知 baseline 值，這裡也能比對相等
    $display("[%0t] CHECK TEXT is unchanged (manual check: value should be unchanged): 0x%08x", $time, d);

    // 8) OOR：越界讀 err=1
    do_load (OOR_A, 3'b010, d, e);
    expect_bit(e, 1'b1, "OOR load err=1");

    // 9) 小型隨機壓力（只做 In-Range 且對齊 word 起點附近）
    base = A0; // scoreboard covers從 A0 開始
    for (n=0; n<200; n=n+1) begin
      off = ($random % 8); // 0..7，讓它在 A0..A0+28 間（跨兩個 word 也測到）
      a   = base + (off<<2);
      op  = $random;
      if (op[0]) begin
        // write: 隨機 SB/SH/SW
        case (op[2:1])
          2'b00: begin // SB
            w = $random;
            do_store(a + (op[4:3]%4), {24'h0, w[7:0]}, 3'b000);
            model_write_masked(a + (op[4:3]%4), {4{w[7:0]}}, mk_wstrb_tb(3'b000,(a[1:0]+(op[4:3]%4))&2'b11));
          end
          2'b01: begin // SH
            w = $random;
            // 隨機半字位移 0/2；資料值在低16，由 MEM 對齊
            if (op[4]) begin
              do_store({a[31:2],2'b10}, {16'h0, w[15:0]}, 3'b001); // @+2
              model_write_masked({a[31:2],2'b00}, {w[15:0],16'h0}, 4'b1100);
            end else begin
              do_store({a[31:2],2'b00}, {16'h0, w[15:0]}, 3'b001); // @+0
              model_write_masked({a[31:2],2'b00}, {16'h0, w[15:0]}, 4'b0011);
            end
          end
          default: begin // SW
            w = $random;
            do_store({a[31:2],2'b00}, w, 3'b010);
            model_write_masked({a[31:2],2'b00}, w, 4'b1111);
          end
        endcase
      end else begin
        // read: 隨機 LB/LBU/LH/LHU/LW
        case (op[2:1])
          2'b00: begin // LB/LBU
            do_load(a + (op[4:3]%4), 3'b000, got, e);
            expect_bit(e, 1'b0, "RAND LB err=0");
            do_load(a + (op[4:3]%4), 3'b100, got, e);
            expect_bit(e, 1'b0, "RAND LBU err=0");
          end
          2'b01: begin // LH/LHU
            do_load({a[31:2], op[4]?2'b10:2'b00}, 3'b001, got, e);
            expect_bit(e, 1'b0, "RAND LH err=0");
            do_load({a[31:2], op[4]?2'b10:2'b00}, 3'b101, got, e);
            expect_bit(e, 1'b0, "RAND LHU err=0");
          end
          default: begin // LW
            do_load({a[31:2],2'b00}, 3'b010, got, e);
            expect_bit(e, 1'b0, "RAND LW err=0");
          end
        endcase
      end
    end

    // 收尾
    $display("----------------------------------------------------------------");
    $display("SUMMARY: PASS=%0d, FAIL=%0d", pass_cnt, fail_cnt);
    if (fail_cnt==0) $display("ALL TESTS PASSED");
    else             $display("SOME TESTS FAILED");
    $finish;
  end

endmodule
