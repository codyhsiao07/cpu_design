module restoring_divider_tb;
  reg clk;
  reg rst_n;
  reg start_i;
  reg [31:0] dividend_i;
  reg [31:0] divisor_i;
  reg signed_mode_i;

  wire busy_o;
  wire done_o;
  wire [31:0] quotient_o;
  wire [31:0] remainder_o;

  integer failures;
  integer seed;
  integer random_iters;

  restoring_divider dut (
    .clk(clk),
    .rst_n(rst_n),
    .start_i(start_i),
    .dividend_i(dividend_i),
    .divisor_i(divisor_i),
    .signed_mode_i(signed_mode_i),
    .busy_o(busy_o),
    .done_o(done_o),
    .quotient_o(quotient_o),
    .remainder_o(remainder_o)
  );

  always #5 clk = ~clk;

  function [31:0] ref_quotient;
    input [31:0] a;
    input [31:0] b;
    input signed_mode;
    reg dividend_neg;
    reg divisor_neg;
    reg quotient_neg;
    reg [31:0] dividend_abs;
    reg [31:0] divisor_abs;
    reg [31:0] quotient_abs;
    begin
      if (b == 32'b0) begin
        ref_quotient = 32'hFFFF_FFFF;
      end else if (signed_mode && (a == 32'h8000_0000) && (b == 32'hFFFF_FFFF)) begin
        ref_quotient = 32'h8000_0000;
      end else begin
        dividend_neg = signed_mode && a[31];
        divisor_neg = signed_mode && b[31];
        quotient_neg = dividend_neg ^ divisor_neg;
        dividend_abs = dividend_neg ? (~a + 32'd1) : a;
        divisor_abs = divisor_neg ? (~b + 32'd1) : b;
        quotient_abs = dividend_abs / divisor_abs;
        if (quotient_neg && (quotient_abs != 32'b0)) begin
          ref_quotient = ~quotient_abs + 32'd1;
        end else begin
          ref_quotient = quotient_abs;
        end
      end
    end
  endfunction

  function [31:0] ref_remainder;
    input [31:0] a;
    input [31:0] b;
    input signed_mode;
    reg dividend_neg;
    reg divisor_neg;
    reg [31:0] dividend_abs;
    reg [31:0] divisor_abs;
    reg [31:0] remainder_abs;
    begin
      if (b == 32'b0) begin
        ref_remainder = a;
      end else if (signed_mode && (a == 32'h8000_0000) && (b == 32'hFFFF_FFFF)) begin
        ref_remainder = 32'b0;
      end else begin
        dividend_neg = signed_mode && a[31];
        divisor_neg = signed_mode && b[31];
        dividend_abs = dividend_neg ? (~a + 32'd1) : a;
        divisor_abs = divisor_neg ? (~b + 32'd1) : b;
        remainder_abs = dividend_abs % divisor_abs;
        if (dividend_neg && (remainder_abs != 32'b0)) begin
          ref_remainder = ~remainder_abs + 32'd1;
        end else begin
          ref_remainder = remainder_abs;
        end
      end
    end
  endfunction

  task clear_inputs;
    begin
      start_i = 1'b0;
      dividend_i = 32'b0;
      divisor_i = 32'b0;
      signed_mode_i = 1'b0;
    end
  endtask

  task run_case;
    input [31:0] a;
    input [31:0] b;
    input signed_mode;
    input integer case_id;
    reg [31:0] expected_q;
    reg [31:0] expected_r;
    integer cycles;
    integer saw_busy;
    integer done_seen;
    begin
      expected_q = ref_quotient(a, b, signed_mode);
      expected_r = ref_remainder(a, b, signed_mode);

      @(negedge clk);
      start_i = 1'b1;
      dividend_i = a;
      divisor_i = b;
      signed_mode_i = signed_mode;

      @(negedge clk);
      start_i = 1'b0;

      cycles = 0;
      saw_busy = 0;
      done_seen = 0;
      while ((cycles < 40) && !done_seen) begin
        @(posedge clk);
        cycles = cycles + 1;
        if (busy_o) begin
          saw_busy = 1;
        end
        if (done_o) begin
          done_seen = 1;
        end
      end

      if (!saw_busy) begin
        $display("FAIL case=%0d a=%h b=%h signed=%0d: busy never asserted",
                 case_id, a, b, signed_mode);
        failures = failures + 1;
      end
      if (!done_seen) begin
        $display("FAIL case=%0d a=%h b=%h signed=%0d: operation did not complete",
                 case_id, a, b, signed_mode);
        failures = failures + 1;
      end
      if (quotient_o !== expected_q) begin
        $display("FAIL case=%0d a=%h b=%h signed=%0d: quotient got=%h exp=%h",
                 case_id, a, b, signed_mode, quotient_o, expected_q);
        failures = failures + 1;
      end
      if (remainder_o !== expected_r) begin
        $display("FAIL case=%0d a=%h b=%h signed=%0d: remainder got=%h exp=%h",
                 case_id, a, b, signed_mode, remainder_o, expected_r);
        failures = failures + 1;
      end

      @(posedge clk);
      if (done_o) begin
        $display("FAIL case=%0d: done_o must pulse for one cycle", case_id);
        failures = failures + 1;
      end
      if (busy_o) begin
        $display("FAIL case=%0d: busy_o stayed high after completion", case_id);
        failures = failures + 1;
      end
    end
  endtask

  task run_restart_ignored_case;
    input [31:0] first_a;
    input [31:0] first_b;
    input first_signed_mode;
    input [31:0] second_a;
    input [31:0] second_b;
    input integer case_id;
    reg [31:0] expected_q;
    reg [31:0] expected_r;
    integer cycles;
    integer done_seen;
    begin
      expected_q = ref_quotient(first_a, first_b, first_signed_mode);
      expected_r = ref_remainder(first_a, first_b, first_signed_mode);

      @(negedge clk);
      start_i = 1'b1;
      dividend_i = first_a;
      divisor_i = first_b;
      signed_mode_i = first_signed_mode;

      @(negedge clk);
      start_i = 1'b0;

      repeat (5) @(posedge clk);

      @(negedge clk);
      start_i = 1'b1;
      dividend_i = second_a;
      divisor_i = second_b;
      signed_mode_i = 1'b0;

      @(negedge clk);
      start_i = 1'b0;

      cycles = 0;
      done_seen = 0;
      while ((cycles < 40) && !done_seen) begin
        @(posedge clk);
        cycles = cycles + 1;
        if (done_o) begin
          done_seen = 1;
        end
      end

      if (!done_seen) begin
        $display("FAIL case=%0d: restart-ignore operation did not complete", case_id);
        failures = failures + 1;
      end else begin
        if (quotient_o !== expected_q) begin
          $display("FAIL case=%0d: busy restart changed quotient got=%h exp=%h",
                   case_id, quotient_o, expected_q);
          failures = failures + 1;
        end
        if (remainder_o !== expected_r) begin
          $display("FAIL case=%0d: busy restart changed remainder got=%h exp=%h",
                   case_id, remainder_o, expected_r);
          failures = failures + 1;
        end
      end

      @(posedge clk);
    end
  endtask

  task run_random_group;
    input signed_mode;
    input integer base_id;
    integer i;
    reg [31:0] a;
    reg [31:0] b;
    begin
      for (i = 0; i < random_iters; i = i + 1) begin
        a = $random(seed);
        b = $random(seed);
        if (b == 32'b0) begin
          b = 32'h0001_0001 ^ i;
        end
        run_case(a, b, signed_mode, base_id + i);
      end
    end
  endtask

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    failures = 0;
    seed = 32'h6B7C8D9E;
    random_iters = 100;
    clear_inputs();

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    run_case(32'h0000_0000, 32'h0000_0001, 1'b0, 1);
    run_case(32'h1234_5678, 32'h0000_0000, 1'b0, 2);
    run_case(32'hFFFF_FFF8, 32'h0000_0002, 1'b1, 3);
    run_case(32'hFFFF_FFF8, 32'h0000_0003, 1'b1, 4);
    run_case(32'h8000_0000, 32'hFFFF_FFFF, 1'b1, 5);
    run_case(32'h8000_0000, 32'h0000_0001, 1'b1, 6);
    run_case(32'h7FFF_FFFF, 32'h0000_0007, 1'b1, 7);
    run_case(32'hFEDC_BA98, 32'h0000_1234, 1'b0, 8);
    run_case(32'hFFFF_FFFF, 32'hFFFF_FFFF, 1'b0, 9);
    run_restart_ignored_case(32'h1234_5678, 32'h0000_1234, 1'b0,
                             32'hDEAD_BEEF, 32'h0000_1111, 10);

    run_random_group(1'b0, 1000);
    run_random_group(1'b1, 2000);

    if (failures != 0) begin
      $display("FAIL: restoring_divider_tb failures=%0d", failures);
      $finish(1);
    end

    $display("PASS: restoring_divider_tb");
    $finish;
  end
endmodule
