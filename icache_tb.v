`timescale 1ns/1ps

module icache_tb;
  localparam ADDR_WIDTH = 32;
  localparam L2_DATA_W  = 64;

  reg                   clk;
  reg                   rst_n;

  // CPU fetch interface
  reg                   if_req_valid;
  reg  [ADDR_WIDTH-1:0] if_req_addr;
  wire                  if_req_ready;
  reg                   if_req_kill;

  wire                  if_resp_valid;
  reg                   if_resp_ready;
  wire [31:0]           if_resp_inst;
  wire [ADDR_WIDTH-1:0] if_resp_pc;
  wire                  if_resp_err;

  // Control / management
  reg                   ic_flush_req;
  wire                  ic_flush_ack;

  reg                   ic_inv_valid;
  reg                   ic_inv_all;
  reg  [8:0]            ic_inv_index;
  reg                   ic_inv_way;
  wire                  ic_inv_ack;

  // L2 interface
  wire                  l2_req_valid;
  reg                   l2_req_ready;
  wire [ADDR_WIDTH-1:0] l2_req_addr;
  wire [1:0]            l2_req_cmd;
  wire [2:0]            l2_req_size;
  wire [7:0]            l2_req_len;

  reg                   l2_rsp_valid;
  wire                  l2_rsp_ready;
  reg  [L2_DATA_W-1:0]  l2_rsp_data;
  reg                   l2_rsp_last;
  reg                   l2_rsp_err;
  reg                   l2_err_once;
  reg                   pending_err;

  // DUT
  i_cache #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .L2_DATA_W(L2_DATA_W),
    .UNC_BASE(32'h8000_0000),
    .UNC_MASK(32'hFFFF_0000)
  ) dut (
    .clk(clk),
    .rst_n(rst_n),
    .if_req_valid(if_req_valid),
    .if_req_addr(if_req_addr),
    .if_req_ready(if_req_ready),
    .if_req_kill(if_req_kill),
    .if_resp_valid(if_resp_valid),
    .if_resp_ready(if_resp_ready),
    .if_resp_inst(if_resp_inst),
    .if_resp_pc(if_resp_pc),
    .if_resp_err(if_resp_err),
    .ic_flush_req(ic_flush_req),
    .ic_flush_ack(ic_flush_ack),
    .ic_inv_valid(ic_inv_valid),
    .ic_inv_all(ic_inv_all),
    .ic_inv_index(ic_inv_index),
    .ic_inv_way(ic_inv_way),
    .ic_inv_ack(ic_inv_ack),
    .l2_req_valid(l2_req_valid),
    .l2_req_ready(l2_req_ready),
    .l2_req_addr(l2_req_addr),
    .l2_req_cmd(l2_req_cmd),
    .l2_req_size(l2_req_size),
    .l2_req_len(l2_req_len),
    .l2_rsp_valid(l2_rsp_valid),
    .l2_rsp_ready(l2_rsp_ready),
    .l2_rsp_data(l2_rsp_data),
    .l2_rsp_last(l2_rsp_last),
    .l2_rsp_err(l2_rsp_err)
  );

  // Clock
  always #5 clk = ~clk;

  // -----------------------------
  // Simple L2 model
  // -----------------------------
  reg        pending;
  reg        pending_uc;
  reg [31:0] pending_addr;
  reg [3:0]  pending_beat;
  integer    pending_delay;

  integer    req_stall_cnt;
  integer    req_accept_cnt;
  integer    linefill_cnt;
  integer    uc_cnt;

  function [31:0] mem_word;
    input [31:0] addr;
    begin
      mem_word = addr ^ 32'h1234_5678;
    end
  endfunction

  function [63:0] make_beat;
    input [31:0] base;
    input [3:0]  beat;
    reg [31:0] w0;
    reg [31:0] w1;
    begin
      w0 = mem_word(base + (beat * 8));
      w1 = mem_word(base + (beat * 8) + 4);
      make_beat = {w1, w0};
    end
  endfunction

  function [8:0] addr_index;
    input [31:0] addr;
    begin
      addr_index = addr[14:6];
    end
  endfunction

  // L2 ready generation (stall before accept)
  always @(*) begin
    if (req_stall_cnt > 0)
      l2_req_ready = 1'b0;
    else
      l2_req_ready = 1'b1;
  end

  // L2 response pipeline
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pending <= 1'b0;
      pending_uc <= 1'b0;
      pending_addr <= 32'b0;
      pending_beat <= 4'd0;
      pending_delay <= 0;
      l2_rsp_valid <= 1'b0;
      l2_rsp_data <= 64'b0;
      l2_rsp_last <= 1'b0;
      l2_rsp_err <= 1'b0;
      l2_err_once <= 1'b0;
      pending_err <= 1'b0;
      req_stall_cnt <= 0;
      req_accept_cnt <= 0;
      linefill_cnt <= 0;
      uc_cnt <= 0;
    end else begin
      if (req_stall_cnt > 0)
        req_stall_cnt <= req_stall_cnt - 1;

      // capture request
      if (l2_req_valid && l2_req_ready) begin
        req_accept_cnt <= req_accept_cnt + 1;
        pending <= 1'b1;
        pending_uc <= (l2_req_cmd == 2'b01);
        pending_addr <= l2_req_addr;
        pending_beat <= 4'd0;
        pending_delay <= pending_delay; // keep current delay
        pending_err <= l2_err_once;
        l2_err_once <= 1'b0;
        if (l2_req_cmd == 2'b01)
          uc_cnt <= uc_cnt + 1;
        else
          linefill_cnt <= linefill_cnt + 1;
      end

      // default keep valid unless handshake happens
      if (l2_rsp_valid && l2_rsp_ready) begin
        l2_rsp_valid <= 1'b0;
      end

      if (pending) begin
        if (pending_delay > 0) begin
          pending_delay <= pending_delay - 1;
        end else begin
          // drive response
          if (!l2_rsp_valid || (l2_rsp_valid && l2_rsp_ready)) begin
            l2_rsp_valid <= 1'b1;
            l2_rsp_err <= pending_err;
            if (pending_uc) begin
              l2_rsp_data <= {32'h0, mem_word(pending_addr)};
              l2_rsp_last <= 1'b1;
              if (l2_rsp_ready) begin
                pending <= 1'b0;
                pending_err <= 1'b0;
              end
            end else begin
              l2_rsp_data <= make_beat(pending_addr, pending_beat);
              l2_rsp_last <= (pending_beat == 4'd7);
              if (l2_rsp_ready) begin
                if (pending_beat == 4'd7) begin
                  pending <= 1'b0;
                  pending_err <= 1'b0;
                end else begin
                  pending_beat <= pending_beat + 1'b1;
                end
              end
            end
          end
        end
      end
    end
  end

  // Helpers
  task wait_cycles;
    input integer n;
    integer k;
    begin
      for (k = 0; k < n; k = k + 1) begin
        @(posedge clk);
      end
    end
  endtask

  task do_fetch;
    input [31:0] addr;
    input [31:0] exp_data;
    input        expect_resp;
    input        expect_err;
    integer      timeout;
    begin
      if_req_addr  <= addr;
      if_req_valid <= 1'b1;
      // wait accept
      timeout = 0;
      while (!(if_req_valid && if_req_ready)) begin
        @(posedge clk);
        timeout = timeout + 1;
        if (timeout > 200) begin
          $fatal(1, "Timeout waiting for if_req_ready");
        end
      end
      @(posedge clk);
      if_req_valid <= 1'b0;

      if (expect_resp) begin
        timeout = 0;
        while (!if_resp_valid) begin
          @(posedge clk);
          timeout = timeout + 1;
          if (timeout > 400) begin
            $fatal(1, "Timeout waiting for if_resp_valid");
          end
        end
        // Instruction data is not architecturally valid on an error response.
        if (!expect_err && (if_resp_inst !== exp_data)) begin
          $fatal(1, "Data mismatch: addr=%h exp=%h got=%h", addr, exp_data, if_resp_inst);
        end
        if (if_resp_err !== expect_err) begin
          $fatal(1, "Err mismatch: addr=%h exp_err=%b got_err=%b", addr, expect_err, if_resp_err);
        end
        // allow one cycle for valid to drop when ready is high
        if (if_resp_ready) begin
          @(posedge clk);
        end
      end else begin
        // ensure no response for some cycles
        wait_cycles(10);
        if (if_resp_valid) begin
          $fatal(1, "Unexpected response after kill");
        end
      end
    end
  endtask

  task do_fetch_ok;
    input [31:0] addr;
    begin
      do_fetch(addr, mem_word(addr), 1'b1, 1'b0);
    end
  endtask

  task do_fetch_expect_err;
    input [31:0] addr;
    begin
      do_fetch(addr, mem_word(addr), 1'b1, 1'b1);
    end
  endtask

  task pulse_kill;
    begin
      if_req_kill <= 1'b1;
      @(posedge clk);
      if_req_kill <= 1'b0;
    end
  endtask

  task do_flush_all;
    integer timeout;
    begin
      ic_flush_req <= 1'b1;
      @(posedge clk);
      ic_flush_req <= 1'b0;
      timeout = 0;
      while (!ic_flush_ack) begin
        @(posedge clk);
        timeout = timeout + 1;
        if (timeout > 600) begin
          $fatal(1, "Timeout waiting for ic_flush_ack");
        end
      end
    end
  endtask

  task do_inv_single;
    input [8:0] index;
    input       way;
    integer     timeout;
    begin
      ic_inv_index <= index;
      ic_inv_way   <= way;
      ic_inv_all   <= 1'b0;
      ic_inv_valid <= 1'b1;
      @(posedge clk);
      ic_inv_valid <= 1'b0;
      timeout = 0;
      while (!ic_inv_ack) begin
        @(posedge clk);
        timeout = timeout + 1;
        if (timeout > 50) begin
          $fatal(1, "Timeout waiting for ic_inv_ack");
        end
      end
    end
  endtask

  task wait_resp_clear;
    integer timeout;
    begin
      timeout = 0;
      while (if_resp_valid) begin
        @(posedge clk);
        timeout = timeout + 1;
        if (timeout > 200) begin
          $fatal(1, "Timeout waiting for if_resp_valid to clear");
        end
      end
    end
  endtask

  initial begin
    // init
    clk = 1'b0;
    rst_n = 1'b0;
    if_req_valid = 1'b0;
    if_req_addr  = 32'b0;
    if_req_kill  = 1'b0;
    if_resp_ready = 1'b1;
    ic_flush_req = 1'b0;
    ic_inv_valid = 1'b0;
    ic_inv_all = 1'b0;
    ic_inv_index = 9'b0;
    ic_inv_way = 1'b0;
    l2_rsp_err = 1'b0;
    pending_delay = 0;
    req_stall_cnt = 0;

    wait_cycles(4);
    rst_n = 1'b1;
    wait_cycles(2);

    // Test 1: cold miss -> refill -> response
    req_stall_cnt = 2;
    pending_delay = 3;
    do_fetch_ok(32'h0000_1000);
    // Test 2: same line hit (different word)
    do_fetch_ok(32'h0000_1004);

    // Test 3: response backpressure
    wait_resp_clear();
    if_resp_ready = 1'b0;
    do_fetch_ok(32'h0000_2000);
    // hold for a few cycles, then release
    wait_cycles(3);
    if_resp_ready = 1'b1;
    wait_cycles(2);

    // Test 4: kill in-flight (hit path)
    fork
      begin
        do_fetch(32'h0000_1008, mem_word(32'h0000_1008), 1'b0, 1'b0);
      end
      begin
        wait_cycles(1);
        pulse_kill();
      end
    join

    // Test 5: uncached UC_READ (no fill)
    pending_delay = 2;
    do_fetch_ok(32'h8000_1234);

    // Test 6: flush and re-miss
    do_fetch_ok(32'h0000_3000);
    do_flush_all();
    // after flush, same address should miss again (new linefill)
    linefill_cnt = 0;
    do_fetch_ok(32'h0000_3000);
    if (linefill_cnt == 0) begin
      $fatal(1, "Expected linefill after flush");
    end

    // Test 7: consecutive misses to different lines
    req_stall_cnt = 1;
    pending_delay = 2;
    do_fetch_ok(32'h0000_4000);
    do_fetch_ok(32'h0000_5000);
    do_fetch_ok(32'h0000_6000);

    // Test 8: single-way invalidate triggers re-miss
    do_fetch_ok(32'h0000_7000); // fill line
    do_inv_single(addr_index(32'h0000_7000), 1'b0);
    linefill_cnt = 0;
    do_fetch_ok(32'h0000_7000);
    if (linefill_cnt == 0) begin
      $fatal(1, "Expected linefill after inv single way");
    end

    // Test 9: L2 response error propagates on UC_READ
    l2_err_once = 1'b1;
    do_fetch_expect_err(32'h8000_8000);

    // Test 10: L2 response error propagates on cached miss
    do_flush_all();
    l2_err_once = 1'b1;
    do_fetch_expect_err(32'h0000_A000);

    // Test 11: rsp backpressure during line fill
    if_resp_ready = 1'b1;
    req_stall_cnt = 0;
    pending_delay = 1;
    fork
      begin
        do_fetch_ok(32'h0000_9000);
      end
      begin
        // stall response path for a few cycles mid-refill
        wait_cycles(2);
        if_resp_ready <= 1'b0;
        wait_cycles(4);
        if_resp_ready <= 1'b1;
      end
    join

    $display("All tests passed.");
    $finish;
  end

endmodule
