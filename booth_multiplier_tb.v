module booth_multiplier_tb;
  reg clk;
  reg rst_n;
  reg start_i;
  reg [31:0] a_i;
  reg [31:0] b_i;
  reg signed_a_i;
  reg signed_b_i;
  reg high_half_i;

  wire busy_o;
  wire done_o;
  wire [31:0] result_o;

  integer failures;
  integer seed;
  integer random_iters;

  booth_multiplier dut (
    .clk(clk),
    .rst_n(rst_n),
    .start_i(start_i),
    .a_i(a_i),
    .b_i(b_i),
    .signed_a_i(signed_a_i),
    .signed_b_i(signed_b_i),
    .high_half_i(high_half_i),
    .busy_o(busy_o),
    .done_o(done_o),
    .result_o(result_o)
  );

  always #5 clk = ~clk;

  function [63:0] ref_mul_full;
    input [31:0] a;
    input [31:0] b;
    input sign_a;
    input sign_b;
    reg negate;
    reg [31:0] abs_a;
    reg [31:0] abs_b;
    reg [63:0] abs_product;
    begin
      abs_a = (sign_a && a[31]) ? (~a + 32'd1) : a;
      abs_b = (sign_b && b[31]) ? (~b + 32'd1) : b;
      abs_product = {32'b0, abs_a} * {32'b0, abs_b};
      negate = (sign_a && a[31]) ^ (sign_b && b[31]);
      if (negate) begin
        ref_mul_full = (~abs_product) + 64'd1;
      end else begin
        ref_mul_full = abs_product;
      end
    end
  endfunction

  function [31:0] ref_result;
    input [31:0] a;
    input [31:0] b;
    input sign_a;
    input sign_b;
    input high_half;
    reg [63:0] product;
    begin
      product = ref_mul_full(a, b, sign_a, sign_b);
      ref_result = high_half ? product[63:32] : product[31:0];
    end
  endfunction

  task clear_inputs;
    begin
      start_i = 1'b0;
      a_i = 32'b0;
      b_i = 32'b0;
      signed_a_i = 1'b0;
      signed_b_i = 1'b0;
      high_half_i = 1'b0;
    end
  endtask

  task run_case;
    input [31:0] a;
    input [31:0] b;
    input sign_a;
    input sign_b;
    input high_half;
    input integer case_id;
    reg [31:0] expected;
    integer cycles;
    integer saw_busy;
    integer done_seen;
    begin
      expected = ref_result(a, b, sign_a, sign_b, high_half);

      @(negedge clk);
      start_i = 1'b1;
      a_i = a;
      b_i = b;
      signed_a_i = sign_a;
      signed_b_i = sign_b;
      high_half_i = high_half;

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
        $display("FAIL case=%0d a=%h b=%h sa=%0d sb=%0d hh=%0d: busy never asserted",
                 case_id, a, b, sign_a, sign_b, high_half);
        failures = failures + 1;
      end
      if (!done_seen) begin
        $display("FAIL case=%0d a=%h b=%h sa=%0d sb=%0d hh=%0d: operation did not complete",
                 case_id, a, b, sign_a, sign_b, high_half);
        failures = failures + 1;
      end
      if (result_o !== expected) begin
        $display("FAIL case=%0d a=%h b=%h sa=%0d sb=%0d hh=%0d: got=%h exp=%h",
                 case_id, a, b, sign_a, sign_b, high_half, result_o, expected);
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
    input first_sign_a;
    input first_sign_b;
    input first_high_half;
    input [31:0] second_a;
    input [31:0] second_b;
    input integer case_id;
    reg [31:0] expected;
    integer cycles;
    integer done_seen;
    begin
      expected = ref_result(first_a, first_b, first_sign_a, first_sign_b, first_high_half);

      @(negedge clk);
      start_i = 1'b1;
      a_i = first_a;
      b_i = first_b;
      signed_a_i = first_sign_a;
      signed_b_i = first_sign_b;
      high_half_i = first_high_half;

      @(negedge clk);
      start_i = 1'b0;

      repeat (5) @(posedge clk);

      @(negedge clk);
      start_i = 1'b1;
      a_i = second_a;
      b_i = second_b;
      signed_a_i = 1'b0;
      signed_b_i = 1'b0;
      high_half_i = 1'b0;

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
      end else if (result_o !== expected) begin
        $display("FAIL case=%0d: busy restart changed result got=%h exp=%h",
                 case_id, result_o, expected);
        failures = failures + 1;
      end

      @(posedge clk);
    end
  endtask

  task run_random_group;
    input sign_a;
    input sign_b;
    input high_half;
    input integer base_id;
    integer i;
    reg [31:0] a;
    reg [31:0] b;
    begin
      for (i = 0; i < random_iters; i = i + 1) begin
        a = $random(seed);
        b = $random(seed);
        run_case(a, b, sign_a, sign_b, high_half, base_id + i);
      end
    end
  endtask

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    failures = 0;
    seed = 32'h51A2B3C4;
    random_iters = 80;
    clear_inputs();

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    run_case(32'h0000_0000, 32'h0000_0000, 1'b1, 1'b1, 1'b0, 1);
    run_case(32'h0000_0001, 32'h8000_0000, 1'b1, 1'b1, 1'b0, 2);
    run_case(32'hFFFF_FFFF, 32'h0000_0002, 1'b1, 1'b1, 1'b0, 3);
    run_case(32'hFFFF_FFFF, 32'hFFFF_FFFE, 1'b1, 1'b1, 1'b1, 4);
    run_case(32'h8000_0000, 32'h0000_0002, 1'b1, 1'b1, 1'b1, 5);
    run_case(32'hFFFF_FFF0, 32'h0001_0001, 1'b1, 1'b0, 1'b1, 6);
    run_case(32'h8000_0000, 32'hFFFF_FFFF, 1'b1, 1'b0, 1'b1, 7);
    run_case(32'hFFFF_FFFF, 32'hFFFF_FFFF, 1'b0, 1'b0, 1'b1, 8);
    run_case(32'hFEDC_BA98, 32'h7654_3210, 1'b0, 1'b0, 1'b0, 9);
    run_restart_ignored_case(32'h1234_5678, 32'hFEDC_BA98, 1'b1, 1'b1, 1'b1,
                             32'hDEAD_BEEF, 32'h0000_1111, 10);

    run_random_group(1'b1, 1'b1, 1'b0, 1000);
    run_random_group(1'b1, 1'b1, 1'b1, 2000);
    run_random_group(1'b1, 1'b0, 1'b1, 3000);
    run_random_group(1'b0, 1'b0, 1'b1, 4000);

    if (failures != 0) begin
      $display("FAIL: booth_multiplier_tb failures=%0d", failures);
      $finish(1);
    end

    $display("PASS: booth_multiplier_tb");
    $finish;
  end
endmodule
