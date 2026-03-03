`timescale 1ns/1ps
// l2_arb_tb.v
// Simple TB to verify L2 + arbitration behavior.

module l2_arb_tb;
  localparam DDR_BASE = 32'h8000_0000;
  localparam MIG_CMD_READ  = 3'b001;
  localparam MIG_CMD_WRITE = 3'b000;

  localparam CMD_LINE_RD = 2'b00;
  localparam CMD_UC_RD   = 2'b01;
  localparam CMD_UC_WR   = 2'b10;
  localparam CMD_WB_LINE = 2'b11;

  reg clk;
  reg rst;
  reg init_calib_complete;

  // I$ upstream
  reg         i_req_valid;
  wire        i_req_ready;
  reg  [1:0]  i_req_cmd;
  reg  [31:0] i_req_addr;
  reg  [2:0]  i_req_size;
  reg  [7:0]  i_req_len;
  reg  [63:0] i_req_wdata;
  reg  [7:0]  i_req_wstrb;
  reg         i_req_uncached;

  wire        i_rsp_valid;
  reg         i_rsp_ready;
  wire [63:0] i_rsp_rdata;
  wire        i_rsp_err;
  wire        i_rsp_last;

  // D$ upstream
  reg         d_req_valid;
  wire        d_req_ready;
  reg  [1:0]  d_req_cmd;
  reg  [31:0] d_req_addr;
  reg  [2:0]  d_req_size;
  reg  [7:0]  d_req_len;
  reg  [63:0] d_req_wdata;
  reg  [7:0]  d_req_wstrb;
  reg         d_req_uncached;

  wire        d_rsp_valid;
  reg         d_rsp_ready;
  wire [63:0] d_rsp_rdata;
  wire        d_rsp_err;
  wire        d_rsp_last;

  // capture last D response beat (to avoid missing 1-beat pulses)
  reg         d_rsp_seen;
  reg         d_rsp_err_seen;
  reg         d_rsp_last_seen;

  // MIG app interface (from DUT)
  wire [26:0]  app_addr;
  wire [2:0]   app_cmd;
  wire         app_en;
  wire [127:0] app_wdf_data;
  wire         app_wdf_end;
  wire [15:0]  app_wdf_mask;
  wire         app_wdf_wren;
  reg  [127:0] app_rd_data;
  reg          app_rd_data_end;
  reg          app_rd_data_valid;
  reg          app_rdy;
  reg          app_wdf_rdy;

  integer errors;
  integer cycle;
  integer stage;

  // DUT
  l2_cache_top dut (
    .clk                (clk),
    .rst                (rst),
    .init_calib_complete(init_calib_complete),

    .i_req_valid        (i_req_valid),
    .i_req_ready        (i_req_ready),
    .i_req_cmd          (i_req_cmd),
    .i_req_addr         (i_req_addr),
    .i_req_size         (i_req_size),
    .i_req_len          (i_req_len),
    .i_req_wdata        (i_req_wdata),
    .i_req_wstrb        (i_req_wstrb),
    .i_req_uncached     (i_req_uncached),

    .i_rsp_valid        (i_rsp_valid),
    .i_rsp_ready        (i_rsp_ready),
    .i_rsp_rdata        (i_rsp_rdata),
    .i_rsp_err          (i_rsp_err),
    .i_rsp_last         (i_rsp_last),

    .d_req_valid        (d_req_valid),
    .d_req_ready        (d_req_ready),
    .d_req_cmd          (d_req_cmd),
    .d_req_addr         (d_req_addr),
    .d_req_size         (d_req_size),
    .d_req_len          (d_req_len),
    .d_req_wdata        (d_req_wdata),
    .d_req_wstrb        (d_req_wstrb),
    .d_req_uncached     (d_req_uncached),

    .d_rsp_valid        (d_rsp_valid),
    .d_rsp_ready        (d_rsp_ready),
    .d_rsp_rdata        (d_rsp_rdata),
    .d_rsp_err          (d_rsp_err),
    .d_rsp_last         (d_rsp_last),

    .app_addr           (app_addr),
    .app_cmd            (app_cmd),
    .app_en             (app_en),
    .app_wdf_data       (app_wdf_data),
    .app_wdf_end        (app_wdf_end),
    .app_wdf_mask       (app_wdf_mask),
    .app_wdf_wren       (app_wdf_wren),
    .app_rd_data        (app_rd_data),
    .app_rd_data_end    (app_rd_data_end),
    .app_rd_data_valid  (app_rd_data_valid),
    .app_rdy            (app_rdy),
    .app_wdf_rdy        (app_wdf_rdy)
  );

  // clock
  always #5 clk = ~clk;

  // simple watchdog
  always @(posedge clk) begin
    cycle <= cycle + 1;
    if (cycle > 20000) begin
      $display("ERROR: watchdog timeout at stage=%0d", stage);
      errors = errors + 1;
      $finish;
    end
  end

  // MIG read data generator
  function [127:0] gen_rd_data;
    input [26:0] a;
    reg [31:0] base_word;
    begin
      base_word = {4'b0, a} << 2; // app_addr * 4 words
      gen_rd_data = {base_word + 32'd3, base_word + 32'd2, base_word + 32'd1, base_word};
    end
  endfunction

  function [63:0] exp_line_rd_beat;
    input [31:0] line_addr;
    input [2:0] beat;
    reg [31:0] app_addr_base;
    reg [31:0] base_word;
    reg [31:0] beat2;
    begin
      app_addr_base = (line_addr - DDR_BASE) >> 4;
      base_word = app_addr_base << 2;
      beat2 = {29'd0, beat, 1'b0}; // beat * 2
      exp_line_rd_beat = {base_word + beat2 + 32'd1, base_word + beat2};
    end
  endfunction

  function [63:0] exp_uc_rd_data;
    input [31:0] addr;
    reg [31:0] app_addr_base;
    reg [31:0] base_word;
    begin
      app_addr_base = ((addr & 32'hFFFF_FFF0) - DDR_BASE) >> 4;
      base_word = app_addr_base << 2;
      if (addr[3]) exp_uc_rd_data = {base_word + 32'd3, base_word + 32'd2};
      else         exp_uc_rd_data = {base_word + 32'd1, base_word + 32'd0};
    end
  endfunction

  // MIG model: 1-cycle read latency, single outstanding
  reg rd_pending;
  reg [127:0] rd_data_reg;
  always @(posedge clk) begin
    if (rst) begin
      rd_pending <= 1'b0;
      rd_data_reg <= 128'd0;
      app_rd_data <= 128'd0;
      app_rd_data_valid <= 1'b0;
      app_rd_data_end <= 1'b0;
    end else begin
      app_rd_data_valid <= rd_pending;
      app_rd_data_end   <= rd_pending;
      if (rd_pending) rd_pending <= 1'b0;

      if (app_en && (app_cmd == MIG_CMD_READ)) begin
        if (rd_pending) begin
          $display("ERROR: overlapping MIG read");
          errors = errors + 1;
        end
        rd_data_reg <= gen_rd_data(app_addr);
        rd_pending <= 1'b1;
      end

      if (rd_pending) begin
        app_rd_data <= rd_data_reg;
      end
    end
  end

  // capture last D response beat (to avoid missing 1-beat pulses)
  always @(posedge clk) begin
    if (d_rsp_valid) begin
      d_rsp_seen <= 1'b1;
      d_rsp_err_seen <= d_rsp_err;
      d_rsp_last_seen <= d_rsp_last;
    end
  end

  // helpers
  task reset_dut;
    begin
      rst = 1'b1;
      init_calib_complete = 1'b0;
      i_req_valid = 1'b0;
      d_req_valid = 1'b0;
      i_req_cmd = 2'b0;
      d_req_cmd = 2'b0;
      i_req_addr = 32'd0;
      d_req_addr = 32'd0;
      i_req_size = 3'd0;
      d_req_size = 3'd0;
      i_req_len  = 8'd0;
      d_req_len  = 8'd0;
      i_req_wdata = 64'd0;
      d_req_wdata = 64'd0;
      i_req_wstrb = 8'h00;
      d_req_wstrb = 8'h00;
      i_req_uncached = 1'b0;
      d_req_uncached = 1'b0;
      i_rsp_ready = 1'b1;
      d_rsp_ready = 1'b1;
      app_rdy = 1'b1;
      app_wdf_rdy = 1'b1;
      cycle = 0;
      stage = 0;

      repeat (5) @(posedge clk);
      rst = 1'b0;
      init_calib_complete = 1'b1;
      repeat (2) @(posedge clk);
    end
  endtask

  task wait_rsp_beats;
    input is_d;
    input integer beats;
    integer b;
    integer timeout;
    integer found;
    reg [63:0] rdata;
    reg rlast;
    reg rerr;
    begin
      for (b = 0; b < beats; b = b + 1) begin
        timeout = 0;
        found = 0;
        while (!found) begin
          @(posedge clk);
          if (is_d) begin
            if (d_rsp_valid) begin
              rdata = d_rsp_rdata;
              rlast = d_rsp_last;
              rerr  = d_rsp_err;
              found = 1;
            end
          end else begin
            if (i_rsp_valid) begin
              rdata = i_rsp_rdata;
              rlast = i_rsp_last;
              rerr  = i_rsp_err;
              found = 1;
            end
          end
          timeout = timeout + 1;
          if (timeout > 200) begin
            $display("ERROR: response timeout");
            errors = errors + 1;
            found = 1;
          end
        end
        if ((b != (beats-1)) && rlast) begin
          $display("ERROR: rsp_last early");
          errors = errors + 1;
        end
        if ((b == (beats-1)) && !rlast) begin
          $display("ERROR: rsp_last missing");
          errors = errors + 1;
        end
      end
    end
  endtask

  task wait_line_rsp_and_check;
    input is_d;
    input [31:0] addr;
    integer b;
    integer timeout;
    integer found;
    reg [63:0] rdata;
    reg rlast;
    reg rerr;
    reg [31:0] line_addr;
    reg [63:0] exp;
    begin
      line_addr = {addr[31:6], 6'b0};
      for (b = 0; b < 8; b = b + 1) begin
        timeout = 0;
        found = 0;
        while (!found) begin
          @(posedge clk);
          if (is_d) begin
            if (d_rsp_valid) begin
              rdata = d_rsp_rdata;
              rlast = d_rsp_last;
              rerr  = d_rsp_err;
              found = 1;
            end
          end else begin
            if (i_rsp_valid) begin
              rdata = i_rsp_rdata;
              rlast = i_rsp_last;
              rerr  = i_rsp_err;
              found = 1;
            end
          end
          timeout = timeout + 1;
          if (timeout > 200) begin
            $display("ERROR: line response timeout");
            errors = errors + 1;
            found = 1;
          end
        end
        exp = exp_line_rd_beat(line_addr, b[2:0]);
        if (rdata !== exp) begin
          $display("ERROR: line beat mismatch b=%0d got=%h exp=%h", b, rdata, exp);
          errors = errors + 1;
        end
        if (rerr) begin
          $display("ERROR: line rsp err");
          errors = errors + 1;
        end
        if ((b != 7) && rlast) begin
          $display("ERROR: rsp_last early");
          errors = errors + 1;
        end
        if ((b == 7) && !rlast) begin
          $display("ERROR: rsp_last missing");
          errors = errors + 1;
        end
      end
    end
  endtask

  task send_req_single;
    input is_d;
    input [1:0] cmd;
    input [31:0] addr;
    input [2:0] size;
    input [7:0] len;
    input [63:0] wdata;
    input [7:0] wstrb;
    input unc;
    begin
      if (is_d) begin
        d_req_cmd = cmd;
        d_req_addr = addr;
        d_req_size = size;
        d_req_len  = len;
        d_req_wdata = wdata;
        d_req_wstrb = wstrb;
        d_req_uncached = unc;
        d_req_valid = 1'b1;
        begin : d_req_handshake
          integer tmo;
          tmo = 0;
          while (!d_req_ready && tmo < 200) begin
            @(posedge clk);
            tmo = tmo + 1;
          end
          if (tmo >= 200) begin
            $display("ERROR: D req handshake timeout in send_req_single");
            errors = errors + 1;
          end
        end
        d_req_valid = 1'b0;
      end else begin
        i_req_cmd = cmd;
        i_req_addr = addr;
        i_req_size = size;
        i_req_len  = len;
        i_req_wdata = wdata;
        i_req_wstrb = wstrb;
        i_req_uncached = unc;
        i_req_valid = 1'b1;
        begin : i_req_handshake
          integer tmo;
          tmo = 0;
          while (!i_req_ready && tmo < 200) begin
            @(posedge clk);
            tmo = tmo + 1;
          end
          if (tmo >= 200) begin
            $display("ERROR: I req handshake timeout in send_req_single");
            errors = errors + 1;
          end
        end
        i_req_valid = 1'b0;
      end
    end
  endtask

  task wait_accept;
    input is_d;
    integer tmo;
    begin
      tmo = 0;
      if (is_d) begin
        while (!(d_req_valid && d_req_ready) && tmo < 200) begin
          @(posedge clk);
          tmo = tmo + 1;
        end
        if (tmo >= 200) begin
          $display("ERROR: D req accept timeout (valid=%b ready=%b)", d_req_valid, d_req_ready);
          errors = errors + 1;
        end
      end else begin
        while (!(i_req_valid && i_req_ready) && tmo < 200) begin
          @(posedge clk);
          tmo = tmo + 1;
        end
        if (tmo >= 200) begin
          $display("ERROR: I req accept timeout (valid=%b ready=%b)", i_req_valid, i_req_ready);
          errors = errors + 1;
        end
      end
    end
  endtask

  task wait_core_idle;
    integer tmo;
    begin
      tmo = 0;
      while (!((dut.u_core.state == 0) && (d_rsp_valid == 1'b0) && (i_rsp_valid == 1'b0)) && tmo < 500) begin
        @(posedge clk);
        tmo = tmo + 1;
      end
      if (tmo >= 500) begin
        $display("ERROR: core idle timeout (state=%0d d_rsp_valid=%b i_rsp_valid=%b)", dut.u_core.state, d_rsp_valid, i_rsp_valid);
        errors = errors + 1;
      end
    end
  endtask

  task send_wb_line;
    input is_d;
    input [31:0] addr;
    input [63:0] base;
    integer b;
    integer tmo;
    begin
      if (!is_d) begin
        $display("ERROR: WB_LINE only tested on D port");
        errors = errors + 1;
      end
      d_req_cmd = CMD_WB_LINE;
      d_req_addr = addr;
      d_req_size = 3'b011;
      d_req_len  = 8'd7;
      d_req_uncached = 1'b0;
      d_req_valid = 1'b1;
      d_req_wstrb = 8'hFF;
      b = 0;
      tmo = 0;
      while (b < 8 && tmo < 500) begin
        if (d_req_ready) begin
          d_req_wdata = base + b;
          b = b + 1;
        end
        @(posedge clk);
        tmo = tmo + 1;
      end
      if (tmo >= 500) begin
        $display("ERROR: WB_LINE streaming timeout (b=%0d)", b);
        errors = errors + 1;
      end
      d_req_valid = 1'b0;
    end
  endtask

  // Tests
  initial begin
    clk = 1'b0;
    errors = 0;
    cycle = 0;
    stage = 0;
    reset_dut();

    // Test 1: D > I when both cached
    stage = 1;
    i_req_cmd = CMD_LINE_RD;
    d_req_cmd = CMD_LINE_RD;
    i_req_addr = DDR_BASE + 32'h0000_0040;
    d_req_addr = DDR_BASE + 32'h0000_0080;
    i_req_size = 3'b011;
    d_req_size = 3'b011;
    i_req_len  = 8'd7;
    d_req_len  = 8'd7;
    i_req_uncached = 1'b0;
    d_req_uncached = 1'b0;
    i_req_valid = 1'b1;
    d_req_valid = 1'b1;
    @(posedge clk);
    if (!(d_req_ready && !i_req_ready)) begin
      $display("ERROR: arbitration priority D > I failed");
      errors = errors + 1;
    end
    // complete D handshake, then wait for D response
    wait_accept(1'b1);
    d_req_valid = 1'b0;
    wait_line_rsp_and_check(1'b1, d_req_addr);
    // now accept I and wait its response
    wait_accept(1'b0);
    i_req_valid = 1'b0;
    wait_line_rsp_and_check(1'b0, i_req_addr);

    // Test 2: uncached has priority (I uncached over D cached)
    stage = 2;
    i_req_cmd = CMD_UC_RD;
    d_req_cmd = CMD_LINE_RD;
    i_req_addr = DDR_BASE + 32'h0000_0100;
    d_req_addr = DDR_BASE + 32'h0000_0140;
    i_req_size = 3'b011;
    d_req_size = 3'b011;
    i_req_len  = 8'd0;
    d_req_len  = 8'd7;
    i_req_uncached = 1'b1;
    d_req_uncached = 1'b0;
    i_req_valid = 1'b1;
    d_req_valid = 1'b1;
    @(posedge clk);
    if (!(i_req_ready && !d_req_ready)) begin
      $display("ERROR: arbitration priority uncached failed");
      errors = errors + 1;
    end
    wait_accept(1'b0);
    i_req_valid = 1'b0;

    // UC response check
    begin : uc_rd_check
      integer tmo;
      integer found;
      reg [63:0] exp_uc;
      tmo = 0;
      found = 0;
      exp_uc = exp_uc_rd_data(i_req_addr);
      while (!found) begin
        @(posedge clk);
        if (i_rsp_valid) begin
          if (i_rsp_rdata !== exp_uc) begin
            $display("ERROR: UC_RD data mismatch got=%h exp=%h", i_rsp_rdata, exp_uc);
            errors = errors + 1;
          end
          if (!i_rsp_last) begin
            $display("ERROR: UC_RD rsp_last missing");
            errors = errors + 1;
          end
          if (i_rsp_err) begin
            $display("ERROR: UC_RD rsp_err unexpected");
            errors = errors + 1;
          end
          found = 1;
        end
        tmo = tmo + 1;
        if (tmo > 200) begin
          $display("ERROR: UC_RD timeout");
          errors = errors + 1;
          found = 1;
        end
      end
    end
    // now accept D and wait its response
    wait_accept(1'b1);
    d_req_valid = 1'b0;
    wait_line_rsp_and_check(1'b1, d_req_addr);

    // Test 3: UC_WR ack
    stage = 3;
    send_req_single(1'b1, CMD_UC_WR, DDR_BASE + 32'h0000_0200, 3'b011, 8'd0, 64'hA5A5_0000_0000_0001, 8'hFF, 1'b1);
    begin : uc_wr_check
      integer tmo;
      integer found;
      tmo = 0;
      found = 0;
      while (!found) begin
        @(posedge clk);
        if (d_rsp_valid) begin
          if (!d_rsp_last) begin
            $display("ERROR: UC_WR rsp_last missing");
            errors = errors + 1;
          end
          if (d_rsp_err) begin
            $display("ERROR: UC_WR rsp_err unexpected");
            errors = errors + 1;
          end
          found = 1;
        end
        tmo = tmo + 1;
        if (tmo > 200) begin
          $display("ERROR: UC_WR timeout");
          errors = errors + 1;
          found = 1;
        end
      end
    end

    // Test 4: WB_LINE streaming + ack
    stage = 4;
    d_rsp_seen = 1'b0;
    send_wb_line(1'b1, DDR_BASE + 32'h0000_0300, 64'h1000_0000_0000_0000);
    begin : wb_ack_check
      integer tmo;
      integer found;
      tmo = 0;
      found = 0;
      while (!found) begin
        @(posedge clk);
        if (d_rsp_seen) begin
          if (!d_rsp_last_seen) begin
            $display("ERROR: WB ack rsp_last missing");
            errors = errors + 1;
          end
          if (d_rsp_err_seen) begin
            $display("ERROR: WB ack rsp_err unexpected");
            errors = errors + 1;
          end
          found = 1;
        end
        tmo = tmo + 1;
        if (tmo > 200) begin
          $display("ERROR: WB ack timeout");
          errors = errors + 1;
          found = 1;
        end
      end
    end

    // Test 5: bad len -> error response
    stage = 5;
    wait_core_idle();
    d_rsp_seen = 1'b0;
    send_req_single(1'b1, CMD_LINE_RD, DDR_BASE + 32'h0000_0400, 3'b011, 8'd0, 64'd0, 8'h00, 1'b0);
    begin : bad_len_check
      integer tmo;
      integer found;
      tmo = 0;
      found = 0;
      while (!found) begin
        @(posedge clk);
        if (d_rsp_seen) begin
          if (!d_rsp_last_seen) begin
            $display("ERROR: bad-len rsp_last missing");
            errors = errors + 1;
          end
          if (!d_rsp_err_seen) begin
            $display("ERROR: bad-len rsp_err missing");
            errors = errors + 1;
          end
          found = 1;
        end
        tmo = tmo + 1;
        if (tmo > 200) begin
          $display("ERROR: bad-len timeout");
          errors = errors + 1;
          found = 1;
        end
      end
    end

    if (errors == 0) $display("L2/ARB TB: PASS");
    else $display("L2/ARB TB: FAIL errors=%0d", errors);
    $finish;
  end

endmodule
