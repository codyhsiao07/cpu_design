`timescale 1ns/1ps

module performance_counters_tb;
  reg clk;
  reg rst_n;
  reg [23:0] events;
  reg req_fire;
  reg we;
  reg [5:0] word_addr;
  reg [31:0] wdata;
  reg [3:0] wstrb;
  wire req_ready;
  wire rsp_valid;
  wire rsp_err;
  wire [31:0] rdata;
  reg [31:0] snapshot_cycles;
  reg [31:0] snapshot_retired;
  reg [31:0] low_word;
  reg [31:0] high_word;
  reg rsp_err_check;

  mmio_performance_counters #(
    .COUNTER_COUNT (24),
    .VERSION       (16'h0001)
  ) dut (
    .clk             (clk),
    .rst_n           (rst_n),
    .event_i         (events),
    .req_fire_i      (req_fire),
    .we_i            (we),
    .word_addr_i     (word_addr),
    .wdata_i         (wdata),
    .wstrb_i         (wstrb),
    .req_ready_o     (req_ready),
    .rsp_valid_o     (rsp_valid),
    .rsp_err_o       (rsp_err),
    .rdata_o         (rdata)
  );

  always #5 clk = ~clk;

  task automatic fail;
    input [8*96-1:0] message;
    begin
      $display("[TB] FAIL: %0s", message);
      $finish;
    end
  endtask

  task automatic request;
    input request_we;
    input [5:0] request_word;
    input [31:0] request_data;
    input [3:0] request_strb;
    output [31:0] response_data;
    output response_err;
    begin
      @(negedge clk);
      while (!req_ready)
        @(negedge clk);
      word_addr = request_word;
      wdata = request_data;
      wstrb = request_strb;
      we = request_we;
      req_fire = 1'b1;
      @(posedge clk);
      #1;
      if (!rsp_valid)
        fail("Registered response did not arrive");
      response_data = rdata;
      response_err = rsp_err;
      req_fire = 1'b0;
      we = 1'b0;
      wstrb = 4'b0000;
      @(posedge clk);
      #1;
    end
  endtask

  task automatic control_write;
    input [31:0] value;
    reg [31:0] ignored_data;
    reg ignored_err;
    begin
      request(1'b1, 6'd2, value, 4'b0001, ignored_data, ignored_err);
      if (ignored_err)
        fail("Valid CONTROL write returned an error");
    end
  endtask

  task automatic read_low;
    input [5:0] counter_index;
    output [31:0] value;
    reg read_err;
    begin
      request(1'b0, 6'd4 + (counter_index << 1), 32'd0, 4'd0,
              value, read_err);
      if (read_err)
        fail("Counter read returned an error");
    end
  endtask

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    events = 24'd0;
    req_fire = 1'b0;
    we = 1'b0;
    word_addr = 6'd0;
    wdata = 32'd0;
    wstrb = 4'd0;

    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    request(1'b0, 6'd0, 32'd0, 4'd0, wdata, rsp_err_check);
    if (rsp_err_check || wdata != 32'h5045_5246)
      fail("ID register mismatch");
    request(1'b0, 6'd1, 32'd0, 4'd0, wdata, rsp_err_check);
    if (rsp_err_check || wdata != 32'h0001_0018)
      fail("INFO register mismatch");
    request(1'b1, 6'd2, 32'd1, 4'b0010, wdata, rsp_err_check);
    if (!rsp_err_check)
      fail("CONTROL accepted a write without byte lane zero");

    control_write(32'h0000_0003); // clear + enable
    events[0] = 1'b1;
    events[1] = 1'b1;
    repeat (9) @(posedge clk);
    control_write(32'h0000_0005); // snapshot + keep running
    read_low(6'd0, snapshot_cycles);
    read_low(6'd1, snapshot_retired);
    if ((snapshot_cycles < 32'd9) || (snapshot_cycles != snapshot_retired))
      fail("Live events were not counted equally");

    repeat (7) @(posedge clk);
    read_low(6'd0, wdata);
    if (wdata != snapshot_cycles)
      fail("Snapshot changed while live counters continued");

    control_write(32'h0000_0009); // release snapshot + keep running
    read_low(6'd0, wdata);
    if (wdata <= snapshot_cycles)
      fail("Live counter did not continue behind snapshot");

    control_write(32'h0000_0002); // clear + stop
    read_low(6'd0, wdata);
    if (wdata != 32'd0)
      fail("Clear did not zero counter bank");
    repeat (5) @(posedge clk);
    read_low(6'd0, wdata);
    if (wdata != 32'd0)
      fail("Disabled counter advanced");

    // Validate both halves of a stable 64-bit snapshot explicitly.
    events = 24'd0;
    @(negedge clk);
    dut.live_count_q[0] = 64'h1234_5678_9ABC_DEF0;
    control_write(32'h0000_0004);
    request(1'b0, 6'd4, 32'd0, 4'd0, low_word, rsp_err_check);
    request(1'b0, 6'd5, 32'd0, 4'd0, high_word, rsp_err_check);
    if ((low_word != 32'h9ABC_DEF0) || (high_word != 32'h1234_5678))
      fail("64-bit low/high snapshot read mismatch");

    // Force the practical wrap boundary and verify the sticky overflow status.
    control_write(32'h0000_0002);
    @(negedge clk);
    dut.live_count_q[0] = 64'hFFFF_FFFF_FFFF_FFFF;
    events[0] = 1'b1;
    control_write(32'h0000_0001);
    control_write(32'h0000_0000);
    request(1'b0, 6'd3, 32'd0, 4'd0, wdata, rsp_err_check);
    if (rsp_err_check || !wdata[2])
      fail("64-bit overflow status was not sticky");
    events = 24'd0;

    request(1'b0, 6'd52, 32'd0, 4'd0, wdata, rsp_err_check);
    if (!rsp_err_check)
      fail("Out-of-range counter address was accepted");

    $display("[TB] PASS: 64-bit counter control/snapshot checks completed");
    $finish;
  end
endmodule
