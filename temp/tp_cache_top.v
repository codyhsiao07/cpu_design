`timescale 1ns/1ps

module tb_top_cache_sram_final;

  // Clock / Reset
  reg clk;
  reg rstn;
  initial clk = 1'b0;
  always #5 clk = ~clk;

  initial begin
    rstn = 1'b0;
    repeat (10) @(posedge clk);
    rstn = 1'b1;
  end

  // Core-side IFs
  // I$ fetch
  reg         fetch_valid_i;
  reg  [31:0] fetch_addr_i;
  wire [31:0] fetch_data_o;
  wire        fetch_stall_o;

  // D$ request/response
  reg         d_req_valid;
  wire        d_req_ready;
  reg         d_req_rw;          // 0=load, 1=store
  reg  [31:0] d_req_addr;
  reg  [31:0] d_req_wdata;
  reg  [3:0]  d_req_wstrb;
  wire        d_resp_valid;
  wire [31:0] d_resp_rdata;
  wire        d_resp_err;
  wire        d_stall_ld_miss;
  wire        d_stall_st_buf;

  // DUT (positional, no dot connections)
  top_cache_sram dut (
    clk,
    rstn,
    fetch_valid_i,
    fetch_addr_i,
    fetch_data_o,
    fetch_stall_o,
    d_req_valid,
    d_req_ready,
    d_req_rw,
    d_req_addr,
    d_req_wdata,
    d_req_wstrb,
    d_resp_valid,
    d_resp_rdata,
    d_resp_err,
    d_stall_ld_miss,
    d_stall_st_buf
  );

  // ===== Helpers / tasks (same as previous CL6_final) =====
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

  task idle_cycles;
    input integer n;
    integer k;
    begin
      for (k = 0; k < n; k = k + 1) @(posedge clk);
    end
  endtask

  task do_store;
    input [31:0] addr;
    input [31:0] data;
    input [3:0]  wstrb;
    begin
      @(posedge clk);
      d_req_addr  <= addr;
      d_req_wdata <= data;
      d_req_wstrb <= wstrb;
      d_req_rw    <= 1'b1;
      d_req_valid <= 1'b1;
      $display("[%0t] STORE addr=0x%08x data=0x%08x wstrb=%04b", $time, addr, data, wstrb);
      while (d_req_ready == 1'b0) @(posedge clk);
      @(posedge clk);
      d_req_valid <= 1'b0;
      d_req_rw    <= 1'b0;
      d_req_wstrb <= 4'b0000;
    end
  endtask

  task do_load;
    input  [31:0] addr;
    output [31:0] data;
    output        err;
    begin
      @(posedge clk);
      d_req_addr  <= addr;
      d_req_wdata <= 32'h0;
      d_req_wstrb <= 4'b0000;
      d_req_rw    <= 1'b0;
      d_req_valid <= 1'b1;
      $display("[%0t] LOAD  addr=0x%08x ...", $time, addr);
      while (d_req_ready == 1'b0) @(posedge clk);
      @(posedge clk);
      d_req_valid <= 1'b0;
      while (d_resp_valid == 1'b0) @(posedge clk);
      data = d_resp_rdata;
      err  = d_resp_err;
      $display("[%0t] LOAD  addr=0x%08x -> data=0x%08x err=%0d", $time, addr, data, err);
    end
  endtask

  task do_fetch;
    input  [31:0] addr;
    output [31:0] data;
    begin
      @(posedge clk);
      fetch_addr_i  <= {addr[31:2], 2'b00};
      fetch_valid_i <= 1'b1;
      $display("[%0t] FETCH addr=0x%08x ...", $time, {addr[31:2],2'b00});
      while (fetch_stall_o == 1'b1) @(posedge clk);
      @(posedge clk);
      data = fetch_data_o;
      $display("[%0t] FETCH addr=0x%08x -> data=0x%08x", $time, {addr[31:2],2'b00}, data);
      fetch_valid_i <= 1'b0;
    end
  endtask

  task do_fetch_warm_read;
    input  [31:0] addr;
    output [31:0] data;
    begin
      @(posedge clk);
      fetch_addr_i  <= {addr[31:2], 2'b00};
      fetch_valid_i <= 1'b1;
      while (fetch_stall_o == 1'b1) @(posedge clk);
      @(posedge clk);
      fetch_valid_i <= 1'b0;

      @(posedge clk);
      fetch_addr_i  <= {addr[31:2], 2'b00};
      fetch_valid_i <= 1'b1;
      while (fetch_stall_o == 1'b1) @(posedge clk);
      @(posedge clk);
      data = fetch_data_o;
      fetch_valid_i <= 1'b0;
      $display("[%0t] FETCH(warm) addr=0x%08x -> data=0x%08x", $time, {addr[31:2],2'b00}, data);
    end
  endtask

  // Address map
  localparam [31:0] TEXT_BASE  = 32'h0000_0000;
  localparam [31:0] TEXT_LAST  = 32'h000F_FFFF;
  localparam [31:0] DATA_BASE  = 32'h0010_0000;
  localparam [31:0] DATA_LAST  = 32'h001B_FFFF;
  localparam [31:0] SRAM_LAST  = 32'h001F_FFFF;

  localparam [31:0] ADDR0      = 32'h0010_1000;
  localparam [31:0] ADDR1      = 32'h0010_1004;
  localparam [31:0] TEXT_A0    = 32'h0000_0100;
  localparam [31:0] OOR_ADDR   = 32'h0020_0000;
  localparam [31:0] XLINE_BASE = 32'h0010_3000;

  integer ld_miss_cycles, st_buf_cycles;
  initial begin ld_miss_cycles = 0; st_buf_cycles = 0; end
  always @(posedge clk) if (rstn) begin
    if (d_stall_ld_miss) ld_miss_cycles = ld_miss_cycles + 1;
    if (d_stall_st_buf)  st_buf_cycles  = st_buf_cycles  + 1;
  end

  reg [31:0] text_ifetch_before, text_ifetch_after;

  integer seed;
  integer i, j;
  reg [31:0] rdata, rdata2;
  reg        rerr;
  reg [31:0] a, d;

  initial begin
    seed = 32'h6C16_C1F6;

    fetch_valid_i = 1'b0;
    fetch_addr_i  = 32'h0;

    d_req_valid = 1'b0;
    d_req_rw    = 1'b0;
    d_req_addr  = 32'h0;
    d_req_wdata = 32'h0;
    d_req_wstrb = 4'b0000;

    @(posedge rstn);
    repeat (5) @(posedge clk);

    // === A 基礎 ===
    do_store(ADDR0, 32'h0000_0000, 4'b1111);
    do_load(ADDR0, rdata, rerr); check_eq32(rdata, 32'h0000_0000, "init load ADDR0"); check_err(rerr, 1'b0, "init load ADDR0 err=0");

    do_store(ADDR1, 32'h0000_0000, 4'b1111);
    do_load(ADDR1, rdata, rerr); check_eq32(rdata, 32'h0000_0000, "init load ADDR1"); check_err(rerr, 1'b0, "init load ADDR1 err=0");

    do_store(ADDR0, 32'hDEAD_BEEF, 4'b1111);
    do_load(ADDR0, rdata, rerr); check_eq32(rdata, 32'hDEAD_BEEF, "after full store ADDR0"); check_err(rerr, 1'b0, "after full store ADDR0 err=0");

    do_store(ADDR1, 32'h0000_ABCD, 4'b0011);
    do_load(ADDR1, rdata, rerr); check_eq32(rdata, 32'h0000_ABCD, "after partial low16 ADDR1"); check_err(rerr, 1'b0, "after partial low16 ADDR1 err=0");

    do_store(ADDR1, 32'h1234_0000, 4'b1100);
    do_load(ADDR1, rdata, rerr); check_eq32(rdata, 32'h1234_ABCD, "after partial high16 ADDR1"); check_err(rerr, 1'b0, "after partial high16 ADDR1 err=0");

    do_store(ADDR0, 32'hA5A5_5A5A, 4'b1111);
    do_load(ADDR0, rdata, rerr); check_eq32(rdata, 32'hA5A5_5A5A, "store->immediate load ADDR0"); check_err(rerr, 1'b0, "store->immediate load ADDR0 err=0");

    do_load(OOR_ADDR, rdata, rerr); check_err(rerr, 1'b1, "out-of-range load err=1");

    // === B TEXT 保護（D$ + I$）===
    do_load(TEXT_A0, rdata, rerr); check_err(rerr, 1'b0, "TEXT base load err=0");
    do_store(TEXT_A0, 32'hFEED_FACE, 4'b1111);
    do_load(TEXT_A0, rdata2, rerr); check_eq32(rdata2, rdata, "TEXT write-protect unchanged (D$)"); check_err(rerr, 1'b0, "TEXT write-protect read err=0");

    do_fetch_warm_read(TEXT_A0, text_ifetch_before);
    do_store(TEXT_A0, 32'hCAFEBABE, 4'b1111);
    do_fetch_warm_read(TEXT_A0, text_ifetch_after);
    check_eq32(text_ifetch_after, text_ifetch_before, "I$ fetch unchanged after TEXT store attempt (warm)");
    check_eq32(text_ifetch_before, rdata, "I$ matches backing TEXT (before)");
    check_eq32(text_ifetch_after,  rdata, "I$ matches backing TEXT (after)");

    // === C 隨機壓力（含 idle）===
    begin : rand_pingpong
      for (i = 0; i < 32; i = i + 1) begin
        a = DATA_BASE + (({$random(seed)} & 32'h0000_FFFC) % (DATA_LAST - DATA_BASE - 4));
        d = $random(seed);
        idle_cycles(($random(seed) & 3));
        do_store(a, d, 4'b1111);
        idle_cycles(($random(seed) & 3));
        do_load(a, rdata, rerr);
        check_eq32(rdata, d, "rand store->load match (seeded+idle)");
        check_err(rerr, 1'b0, "rand store->load err=0 (seeded+idle)");
      end
    end

    // === D 強逐出 ===
    begin : evict_hard
      integer EVICT_DEPTH;
      reg [31:0] base_e, a0, v0;
      integer miss_pre, miss_post;

      EVICT_DEPTH = 32;
      base_e      = DATA_BASE + 32'h0000_6000;
      a0          = base_e;
      v0          = 32'hE1E1_A0A0;

      do_store(a0, v0, 4'b1111);
      for (i = 1; i <= EVICT_DEPTH; i = i + 1) begin
        a = base_e + (i << 12);
        d = 32'hDADA_0000 | i;
        idle_cycles(($random(seed) & 1));
        do_store(a, d, 4'b1111);
      end

      miss_pre = ld_miss_cycles;
      idle_cycles(1);
      do_load(a0, rdata, rerr);
      miss_post = ld_miss_cycles;

      check_eq32(rdata, v0, "evict-hard A0 value preserved");
      check_err(rerr, 1'b0, "evict-hard A0 err=0");
    end

    // === E 跨 cache line（64B/32B） ===
    begin : xline64
      reg [31:0] base64, lastw64, firstw64n;
      base64   = (XLINE_BASE + 32'h100) & 32'hFFFF_FFC0;
      lastw64  = base64 + 32'd60;
      firstw64n= base64 + 32'd64;
      do_store(lastw64,   32'h0000_0000, 4'b1111);
      do_store(firstw64n, 32'h0000_0000, 4'b1111);
      do_store(lastw64,   32'hBEEF_0000, 4'b1100);
      do_store(firstw64n, 32'h0000_CAFE, 4'b0011);
      do_load(lastw64,    rdata, rerr);  check_eq32(rdata,  32'hBEEF_0000, "xline64 tail word");
      check_err(rerr, 1'b0, "xline64 tail err=0");
      do_load(firstw64n,  rdata, rerr);  check_eq32(rdata,  32'h0000_CAFE, "xline64 head word");
      check_err(rerr, 1'b0, "xline64 head err=0");
    end

    begin : xline32
      reg [31:0] base32, lastw32, firstw32n;
      base32   = (XLINE_BASE + 32'h300) & 32'hFFFF_FFE0;
      lastw32  = base32 + 32'd28;
      firstw32n= base32 + 32'd32;
      do_store(lastw32,   32'h0000_0000, 4'b1111);
      do_store(firstw32n, 32'h0000_0000, 4'b1111);
      do_store(lastw32,   32'hABCD_0000, 4'b1100);
      do_store(firstw32n, 32'h0000_5678, 4'b0011);
      do_load(lastw32,    rdata, rerr);  check_eq32(rdata,  32'hABCD_0000, "xline32 tail word");
      check_err(rerr, 1'b0, "xline32 tail err=0");
      do_load(firstw32n,  rdata, rerr);  check_eq32(rdata,  32'h0000_5678, "xline32 head word");
      check_err(rerr, 1'b0, "xline32 head err=0");
    end

    // === F wstrb 矩陣 ===
    begin : wstrb_matrix
      reg [31:0] base;
      base = DATA_BASE + 32'h0000_2000;
      do_store(base, 32'h0000_0000, 4'b1111);
      do_store(base, 32'h3300_0000, 4'b1000);
      do_store(base, 32'h0000_0055, 4'b0001);
      do_store(base, 32'h0000_7700, 4'b0010);
      do_store(base, 32'h0066_0000, 4'b0100);
      do_load(base, rdata, rerr); check_eq32(rdata, 32'h3366_7755, "wstrb interleaved bytes"); check_err(rerr, 1'b0, "wstrb interleaved bytes err=0");
      do_store(base, 32'h0055_6600, 4'b0110);
      do_load(base, rdata, rerr); check_eq32(rdata, 32'h3355_6655, "wstrb halfword @byte1..2"); check_err(rerr, 1'b0, "wstrb halfword err=0");
      do_store(base,   32'hA100_0000, 4'b1000);
      do_store(base+4, 32'h0000_00B2, 4'b0001);
      do_load(base,   rdata, rerr); check_eq32(rdata, 32'hA155_6655, "wstrb xword hi byte3"); check_err(rerr, 1'b0, "wstrb xword hi err=0");
      do_load(base+4, rdata, rerr); check_eq32(rdata, 32'h0000_00B2, "wstrb xword lo byte0"); check_err(rerr, 1'b0, "wstrb xword lo err=0");
    end

    // === G 洗牌（固定修正版） ===
    begin : wstrb_shuffle
      reg [31:0] base, target;
      reg [7:0]  b0, b1, b2, b3;
      reg [1:0]  order [0:3];
      reg [1:0]  tmp2;
      integer    j_local;

      base   = DATA_BASE + 32'h0000_2800;
      target = 32'hDE_C0_AD_BE; b0=8'hBE; b1=8'hAD; b2=8'hC0; b3=8'hDE;

      do_store(base, 32'h0000_0000, 4'b1111);
      order[0]=2'd0; order[1]=2'd1; order[2]=2'd2; order[3]=2'd3;
      for (i=3; i>0; i=i-1) begin
        j_local = ( ($random(seed) & 32'h7fffffff) % (i+1) );
        tmp2 = order[i]; order[i] = order[j_local]; order[j_local] = tmp2;
      end
      if ((order[0]==order[1])||(order[0]==order[2])||(order[0]==order[3])||
          (order[1]==order[2])||(order[1]==order[3])||(order[2]==order[3])) begin
        order[0]=2'd0; order[1]=2'd1; order[2]=2'd2; order[3]=2'd3;
      end

      for (i=0; i<4; i=i+1) begin
        case (order[i])
          2'd0: do_store(base, {24'h0, b0}, 4'b0001);
          2'd1: do_store(base, {16'h0, b1, 8'h00}, 4'b0010);
          2'd2: do_store(base, {8'h00, b2, 16'h0}, 4'b0100);
          default: do_store(base, {b3, 24'h0}, 4'b1000);
        endcase
        idle_cycles(($random(seed)&1));
      end
      do_load(base, rdata, rerr); check_eq32(rdata, target, "wstrb shuffle -> target (fixed)"); check_err(rerr, 1'b0, "wstrb shuffle err=0 (fixed)");
    end

    // === H RMW ===
    begin : rmw_patterns
      reg [31:0] base, exp;
      base = DATA_BASE + 32'h0000_2C00;
      do_store(base, 32'h1122_3344, 4'b1111);
      do_load(base, rdata, rerr); check_eq32(rdata, 32'h1122_3344, "RMW init"); check_err(rerr, 1'b0, "RMW init err=0");
      exp = 32'h1122_33AA; do_store(base, 32'h0000_00AA, 4'b0001); do_load(base, rdata, rerr); check_eq32(rdata, exp, "RMW b0=AA"); check_err(rerr, 1'b0, "RMW b0 err=0");
      exp = 32'h1122_BBAA; do_store(base, 32'h0000_BB00, 4'b0010); do_load(base, rdata, rerr); check_eq32(rdata, exp, "RMW b1=BB"); check_err(rerr, 1'b0, "RMW b1 err=0");
      exp = 32'hEEFF_BBAA; do_store(base, 32'hEEFF_0000, 4'b1100); do_load(base, rdata, rerr); check_eq32(rdata, exp, "RMW hi16=EEFF"); check_err(rerr, 1'b0, "RMW hi16 err=0");
      exp = 32'hCAFE_D00D; do_store(base, exp, 4'b1111); do_load(base, rdata, rerr); check_eq32(rdata, exp, "RMW full CAFED00D"); check_err(rerr, 1'b0, "RMW full err=0");
    end

    // === I I$ 串流 ===
    begin : ifetch_stream
      reg [31:0] base;
      base = TEXT_BASE + 32'h0000_0100;
      for (i=0; i<8; i=i+1) begin
        do_fetch_warm_read(base + (i<<2), rdata);
        do_load(base + (i<<2), rdata2, rerr);
        check_eq32(rdata, rdata2, "I$ stream matches D$");
        check_err(rerr, 1'b0, "I$ stream D$ err=0");
      end
    end

    // === J 邊界掃描 ===
    begin : boundary_scan
      reg [31:0] text_end, data_first, data_lastw, sram_lastw;
      reg [31:0] base_val, after_val;
      text_end   = (TEXT_LAST & 32'hFFFF_FFFC);
      data_first = DATA_BASE;
      data_lastw = (DATA_LAST & 32'hFFFF_FFFC);
      sram_lastw = (SRAM_LAST & 32'hFFFF_FFFC);

      do_load(text_end, base_val, rerr); check_err(rerr, 1'b0, "TEXT end baseline err=0");
      do_store(text_end, 32'hFACE_CAFE, 4'b1111);
      do_load(text_end, after_val, rerr); check_eq32(after_val, base_val, "TEXT end write-protect"); check_err(rerr, 1'b0, "TEXT end err=0");

      do_store(data_first, 32'h1357_9BDF, 4'b1111);
      do_load(data_first, rdata, rerr); check_eq32(rdata, 32'h1357_9BDF, "DATA first write/read"); check_err(rerr, 1'b0, "DATA first err=0");

      do_store(data_lastw, 32'h0BAD_F00D, 4'b1111);
      do_load(data_lastw, rdata, rerr); check_eq32(rdata, 32'h0BAD_F00D, "DATA last word write/read"); check_err(rerr, 1'b0, "DATA last word err=0");

      do_store(sram_lastw, 32'h5EED_C0DE, 4'b1111);
      do_load(sram_lastw, rdata, rerr); check_eq32(rdata, 32'h5EED_C0DE, "SRAM last word write/read"); check_err(rerr, 1'b0, "SRAM last word err=0");

      do_load(OOR_ADDR, rdata, rerr); check_err(rerr, 1'b1, "OOR read err=1 (boundary confirm)");
    end

    $display("----------------------------------------------------------------");
    $display("STALL: ld_miss_cycles=%0d, st_buf_cycles=%0d", ld_miss_cycles, st_buf_cycles);
    $display("SUMMARY: PASS=%0d, FAIL=%0d", pass_cnt, fail_cnt);
    if (fail_cnt == 0) $display("ALL TESTS PASSED");
    else               $display("SOME TESTS FAILED");
    $finish;
  end

endmodule
