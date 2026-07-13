module ex_muldiv_tb;
  localparam [3:0] ALU_ADD    = 4'b0000;
  localparam [3:0] ALU_MUL    = 4'b1000;
  localparam [3:0] ALU_MULH   = 4'b1001;
  localparam [3:0] ALU_MULHSU = 4'b1010;
  localparam [3:0] ALU_MULHU  = 4'b1011;
  localparam [3:0] ALU_DIV    = 4'b1100;
  localparam [3:0] ALU_DIVU   = 4'b1101;
  localparam [3:0] ALU_REM    = 4'b1110;
  localparam [3:0] ALU_REMU   = 4'b1111;

  reg clk;
  reg rst_n;
  reg ex_valid_i;
  reg [31:0] ex_pc_i;
  reg [31:0] ex_rs1_val_i;
  reg [31:0] ex_rs2_val_i;
  reg [31:0] ex_imm_i;
  reg [3:0] ex_alu_op_i;
  reg ex_alu_src_imm_i;
  reg ex_branch_i;
  reg ex_jal_i;
  reg ex_jalr_i;
  reg [2:0] ex_br_funct3_i;
  reg ex_shift_right_i;
  reg ex_shift_arith_i;
  reg ex_is_auipc_i;
  reg ex_is_lui_i;
  reg ex_csr_en_i;
  reg [31:0] ex_csr_rdata_i;

  wire ex_stall_o;
  wire [31:0] ex_alu_result_o;
  wire [31:0] ex_store_data_o;
  wire [31:0] ex_pc4_o;
  wire ex_br_taken_o;
  wire [31:0] ex_br_target_o;
  wire redirect_valid_o;
  wire [31:0] redirect_pc_o;

  integer failures;
  integer seed;

  ex_stage dut (
    .clk(clk),
    .rst_n(rst_n),
    .ex_valid_i(ex_valid_i),
    .ex_pipe_hold_i(1'b0),
    .ex_pc_i(ex_pc_i),
    .ex_rs1_val_i(ex_rs1_val_i),
    .ex_rs2_val_i(ex_rs2_val_i),
    .ex_imm_i(ex_imm_i),
    .ex_alu_op_i(ex_alu_op_i),
    .ex_alu_src_imm_i(ex_alu_src_imm_i),
    .ex_branch_i(ex_branch_i),
    .ex_jal_i(ex_jal_i),
    .ex_jalr_i(ex_jalr_i),
    .ex_br_funct3_i(ex_br_funct3_i),
    .ex_shift_right_i(ex_shift_right_i),
    .ex_shift_arith_i(ex_shift_arith_i),
    .ex_is_auipc_i(ex_is_auipc_i),
    .ex_is_lui_i(ex_is_lui_i),
    .ex_csr_en_i(ex_csr_en_i),
    .ex_csr_rdata_i(ex_csr_rdata_i),
    .ex_stall_o(ex_stall_o),
    .ex_alu_result_o(ex_alu_result_o),
    .ex_store_data_o(ex_store_data_o),
    .ex_pc4_o(ex_pc4_o),
    .ex_br_taken_o(ex_br_taken_o),
    .ex_br_target_o(ex_br_target_o),
    .redirect_valid_o(redirect_valid_o),
    .redirect_pc_o(redirect_pc_o)
  );

  always #5 clk = ~clk;

  function [63:0] ref_mul_full;
    input [3:0] op;
    input [31:0] a;
    input [31:0] b;
    reg sign_a;
    reg sign_b;
    reg negate;
    reg [31:0] abs_a;
    reg [31:0] abs_b;
    reg [63:0] abs_product;
    begin
      sign_a = (op == ALU_MUL) || (op == ALU_MULH) || (op == ALU_MULHSU);
      sign_b = (op == ALU_MUL) || (op == ALU_MULH);
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

  function [31:0] ref_divrem_result;
    input [3:0] op;
    input [31:0] a;
    input [31:0] b;
    reg signed_mode;
    reg quotient_mode;
    reg dividend_neg;
    reg divisor_neg;
    reg quotient_neg;
    reg remainder_neg;
    reg [31:0] dividend_abs;
    reg [31:0] divisor_abs;
    reg [31:0] quotient_abs;
    reg [31:0] remainder_abs;
    begin
      signed_mode = (op == ALU_DIV) || (op == ALU_REM);
      quotient_mode = (op == ALU_DIV) || (op == ALU_DIVU);

      if (b == 32'b0) begin
        ref_divrem_result = quotient_mode ? 32'hFFFF_FFFF : a;
      end else if (signed_mode && (a == 32'h8000_0000) && (b == 32'hFFFF_FFFF)) begin
        ref_divrem_result = quotient_mode ? 32'h8000_0000 : 32'b0;
      end else begin
        dividend_neg = signed_mode && a[31];
        divisor_neg = signed_mode && b[31];
        quotient_neg = dividend_neg ^ divisor_neg;
        remainder_neg = dividend_neg;

        dividend_abs = dividend_neg ? (~a + 32'd1) : a;
        divisor_abs = divisor_neg ? (~b + 32'd1) : b;
        quotient_abs = dividend_abs / divisor_abs;
        remainder_abs = dividend_abs % divisor_abs;

        if (quotient_mode) begin
          if (quotient_neg && (quotient_abs != 32'b0)) begin
            ref_divrem_result = ~quotient_abs + 32'd1;
          end else begin
            ref_divrem_result = quotient_abs;
          end
        end else begin
          if (remainder_neg && (remainder_abs != 32'b0)) begin
            ref_divrem_result = ~remainder_abs + 32'd1;
          end else begin
            ref_divrem_result = remainder_abs;
          end
        end
      end
    end
  endfunction

  function [31:0] ref_result;
    input [3:0] op;
    input [31:0] a;
    input [31:0] b;
    reg [63:0] product;
    begin
      case (op)
        ALU_ADD: begin
          ref_result = a + b;
        end
        ALU_MUL: begin
          product = ref_mul_full(op, a, b);
          ref_result = product[31:0];
        end
        ALU_MULH,
        ALU_MULHSU,
        ALU_MULHU: begin
          product = ref_mul_full(op, a, b);
          ref_result = product[63:32];
        end
        ALU_DIV,
        ALU_DIVU,
        ALU_REM,
        ALU_REMU: begin
          ref_result = ref_divrem_result(op, a, b);
        end
        default: begin
          ref_result = 32'b0;
        end
      endcase
    end
  endfunction

  task clear_inputs;
    begin
      ex_valid_i = 1'b0;
      ex_pc_i = 32'h8000_0000;
      ex_rs1_val_i = 32'b0;
      ex_rs2_val_i = 32'b0;
      ex_imm_i = 32'b0;
      ex_alu_op_i = ALU_ADD;
      ex_alu_src_imm_i = 1'b0;
      ex_branch_i = 1'b0;
      ex_jal_i = 1'b0;
      ex_jalr_i = 1'b0;
      ex_br_funct3_i = 3'b0;
      ex_shift_right_i = 1'b0;
      ex_shift_arith_i = 1'b0;
      ex_is_auipc_i = 1'b0;
      ex_is_lui_i = 1'b0;
      ex_csr_en_i = 1'b0;
      ex_csr_rdata_i = 32'b0;
    end
  endtask

  task run_case;
    input [3:0] op;
    input [31:0] a;
    input [31:0] b;
    input integer case_id;
    reg [31:0] expected;
    integer cycles;
    integer saw_stall;
    integer done_seen;
    begin
      expected = ref_result(op, a, b);

      clear_inputs();
      @(negedge clk);
      ex_valid_i = 1'b1;
      ex_alu_op_i = op;
      ex_rs1_val_i = a;
      ex_rs2_val_i = b;

      cycles = 0;
      saw_stall = 0;
      done_seen = 0;
      while ((cycles < 80) && !done_seen) begin
        @(posedge clk);
        cycles = cycles + 1;
        if (ex_stall_o) begin
          saw_stall = 1;
        end else if (cycles > 1) begin
          done_seen = 1;
        end
      end

      if ((op != ALU_ADD) && !saw_stall) begin
        $display("FAIL case=%0d op=%0h a=%h b=%h: no stall observed", case_id, op, a, b);
        failures = failures + 1;
      end
      if (!done_seen) begin
        $display("FAIL case=%0d op=%0h a=%h b=%h: operation did not complete", case_id, op, a, b);
        failures = failures + 1;
      end
      if (ex_alu_result_o !== expected) begin
        $display("FAIL case=%0d op=%0h a=%h b=%h: got=%h exp=%h", case_id, op, a, b, ex_alu_result_o, expected);
        failures = failures + 1;
      end

      @(negedge clk);
      ex_valid_i = 1'b0;
      repeat (2) @(posedge clk);
    end
  endtask

  task run_random_group;
    input [3:0] op;
    input integer base_id;
    integer i;
    reg [31:0] a;
    reg [31:0] b;
    begin
      for (i = 0; i < 48; i = i + 1) begin
        a = $random(seed);
        b = $random(seed);
        if (((op == ALU_DIV) || (op == ALU_DIVU) || (op == ALU_REM) || (op == ALU_REMU)) &&
            (b == 32'b0)) begin
          b = 32'h0001_0001 ^ i;
        end
        run_case(op, a, b, base_id + i);
      end
    end
  endtask

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    failures = 0;
    seed = 32'h31415926;
    clear_inputs();

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    run_case(ALU_ADD, 32'h1234_5678, 32'h0102_0304, 1);

    run_case(ALU_MUL,    32'h0000_0001, 32'h8000_0000, 100);
    run_case(ALU_MUL,    32'hFFFF_FFFF, 32'h0000_0002, 101);
    run_case(ALU_MULH,   32'hFFFF_FFFF, 32'hFFFF_FFFE, 102);
    run_case(ALU_MULHSU, 32'hFFFF_FFF0, 32'h0001_0001, 103);
    run_case(ALU_MULHU,  32'hFFFF_FFFF, 32'hFFFF_FFFF, 104);
    run_case(ALU_DIV,    32'hFFFF_FFF8, 32'h0000_0002, 105);
    run_case(ALU_DIV,    32'h8000_0000, 32'hFFFF_FFFF, 106);
    run_case(ALU_DIVU,   32'hFFFF_FFFF, 32'h0000_000F, 107);
    run_case(ALU_DIVU,   32'h1234_5678, 32'h0000_0000, 108);
    run_case(ALU_REM,    32'hFFFF_FFF8, 32'h0000_0003, 109);
    run_case(ALU_REM,    32'h8000_0000, 32'hFFFF_FFFF, 110);
    run_case(ALU_REMU,   32'h1234_5678, 32'h0000_0011, 111);
    run_case(ALU_REMU,   32'h1234_5678, 32'h0000_0000, 112);

    run_random_group(ALU_MUL, 200);
    run_random_group(ALU_MULH, 300);
    run_random_group(ALU_MULHSU, 400);
    run_random_group(ALU_MULHU, 500);
    run_random_group(ALU_DIV, 600);
    run_random_group(ALU_DIVU, 700);
    run_random_group(ALU_REM, 800);
    run_random_group(ALU_REMU, 900);

    if (failures != 0) begin
      $display("FAIL: ex_muldiv_tb failures=%0d", failures);
      $finish(1);
    end

    $display("PASS: ex_muldiv_tb");
    $finish;
  end

endmodule
