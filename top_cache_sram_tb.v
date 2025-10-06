// tb_top_cache_sram.v - Storage integration test for icache/dcache + sram_2mb
// Verilog-2001 only
`timescale 1ns/1ps

module tb_top_cache_sram;

  // Clock and reset
  reg clk;
  reg rstn;

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk; // 100 MHz
  end

  initial begin
    rstn = 1'b0;
    #50;
    rstn = 1'b1;
  end

  // Core-side signals (drive UUT)
  // I$
  reg         fetch_valid;
  reg  [31:0] fetch_addr;
  wire [31:0] fetch_data;
  wire        fetch_stall;

  // D$
  reg         d_req_valid;
  wire        d_req_ready;
  reg         d_req_rw;
  reg  [31:0] d_req_addr;
  reg  [31:0] d_req_wdata;
  reg  [3:0]  d_req_wstrb;
  wire        d_resp_valid;
  wire [31:0] d_resp_rdata;
  wire        d_resp_err;
  wire        d_stall_ld_miss;
  wire        d_stall_st_buf;

  // Instantiate Top with SRAM window at 0x0000_0000..0x001F_FFFF (2MiB)
  top_cache_sram UUT (
    .clk            (clk),
    .rstn           (rstn),

    .fetch_valid_i  (fetch_valid),
    .fetch_addr_i   (fetch_addr),
    .fetch_data_o   (fetch_data),
    .fetch_stall_o  (fetch_stall),

    .d_req_valid    (d_req_valid),
    .d_req_ready    (d_req_ready),
    .d_req_rw       (d_req_rw),
    .d_req_addr     (d_req_addr),
    .d_req_wdata    (d_req_wdata),
    .d_req_wstrb    (d_req_wstrb),
    .d_resp_valid   (d_resp_valid),
    .d_resp_rdata   (d_resp_rdata),
    .d_resp_err     (d_resp_err),
    .d_stall_ld_miss(d_stall_ld_miss),
    .d_stall_st_buf (d_stall_st_buf)
  );

  // ---------------------------
  // Simple instruction fetch driver
  // ---------------------------
  reg [31:0] pc;

  initial begin
    fetch_valid = 1'b0;
    fetch_addr  = 32'h0000_0000; // In TEXT region by default
    pc          = 32'h0000_0000;
    @(posedge rstn);
    @(posedge clk);
    fetch_valid = 1'b1;
  end

  always @(posedge clk) begin
    if (rstn) begin
      if (!fetch_stall) begin
        fetch_addr <= pc;
        pc <= pc + 4;
      end
    end
  end

  // ---------------------------
  // Convenience checkers (pure Verilog-2001)
  integer error_cnt;
`define CHECK_EQ(tag, got, exp) \
  if ((got) !== (exp)) begin \
    $display("[%0t] CHECK FAIL %s: got=0x%08x exp=0x%08x", $time, tag, got, exp); \
    error_cnt = error_cnt + 1; \
  end else begin \
    $display("[%0t] CHECK PASS %s: 0x%08x", $time, tag, got); \
  end

  // ---------------------------
  // D$ request tasks
  // ---------------------------
  task automatic d_load(input [31:0] addr, output [31:0] data);
    begin
      @(posedge clk);
      d_req_rw    <= 1'b0;
      d_req_addr  <= addr;
      d_req_wdata <= 32'h0000_0000;
      d_req_wstrb <= 4'b0000;
      while (!d_req_ready) @(posedge clk);
      d_req_valid <= 1'b1;
      @(posedge clk);
      d_req_valid <= 1'b0;
      while (!d_resp_valid) @(posedge clk);
      data = d_resp_rdata;
      $display("[%0t] LOAD  addr=0x%08x -> data=0x%08x err=%0d", $time, addr, data, d_resp_err);
    end
  endtask

  task automatic d_store(input [31:0] addr, input [31:0] data, input [3:0] wstrb);
    begin
      @(posedge clk);
      d_req_rw    <= 1'b1;
      d_req_addr  <= addr;
      d_req_wdata <= data;
      d_req_wstrb <= wstrb;
      while (!d_req_ready) @(posedge clk);
      d_req_valid <= 1'b1;
      @(posedge clk);
      d_req_valid <= 1'b0;
      // Store has no dedicated response; wait a couple cycles for internal updates
      repeat (3) @(posedge clk);
      $display("[%0t] STORE addr=0x%08x data=0x%08x wstrb=%b", $time, addr, data, wstrb);
    end
  endtask

  // ---------------------------
  // Address constants (match sram_2mb default partitions in this top)
  // ---------------------------
  localparam [31:0] TEXT_ADDR = 32'h0000_1000;
  localparam [31:0] DATA_ADDR = 32'h0010_1000;

  // ---------------------------
  // Test sequence
  // ---------------------------
  reg [31:0] tmp;
  initial begin : TEST_SEQ
    error_cnt   = 0;

    // init D$ interface
    d_req_valid = 1'b0;
    d_req_rw    = 1'b0;
    d_req_addr  = 32'h0;
    d_req_wdata = 32'h0;
    d_req_wstrb = 4'b0000;

    @(posedge rstn);
    @(posedge clk);

    // 1) Cold load from DATA region -> should be 0 (SRAM default init)
    d_load(DATA_ADDR, tmp);
    `CHECK_EQ("init load DATA", tmp, 32'h0000_0000)

    // 2) Full-word store into DATA, then load-back
    d_store(DATA_ADDR, 32'hDEAD_BEEF, 4'b1111);
    d_load(DATA_ADDR, tmp);
    `CHECK_EQ("after full store", tmp, 32'hDEAD_BEEF)

    // 3) Partial store (low halfword) at DATA+4, then load-back
    d_load(DATA_ADDR + 32'd4, tmp);
    `CHECK_EQ("init load DATA+4", tmp, 32'h0000_0000)
    d_store(DATA_ADDR + 32'd4, 32'h0000_ABCD, 4'b0011);
    d_load(DATA_ADDR + 32'd4, tmp);
    `CHECK_EQ("after partial store", tmp, 32'h0000_ABCD)

    // 4) Try to store into TEXT region (read-only) -> sram_2mb ignores write
    d_store(TEXT_ADDR, 32'hCAFE_FEED, 4'b1111);
    d_load(TEXT_ADDR, tmp);
    `CHECK_EQ("store TEXT ignored", tmp, 32'h0000_0000)

    // 5) A second read from DATA (should hit in D$)
    d_load(DATA_ADDR, tmp);
    `CHECK_EQ("hit after prior write", tmp, 32'hDEAD_BEEF)

    // Wrap up
    if (error_cnt == 0) $display("ALL TESTS PASS ");
    else $display("TESTS FAIL , error_cnt=%0d", error_cnt);
    #50 $finish;
  end

endmodule
