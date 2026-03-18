module restoring_divider(
  input clk,
  input rst_n,

  input start_i,
  input [31:0] dividend_i,
  input [31:0] divisor_i,
  input signed_mode_i,

  output reg busy_o,
  output reg done_o,

  output reg [31:0] quotient_o,
  output reg [31:0] remainder_o
);

  reg [31:0] remainder_q;
  reg [31:0] quotient_q;
  reg [31:0] divisor_q;
  reg        quotient_neg_q;
  reg        remainder_neg_q;
  reg        div_zero_q;
  reg        overflow_q;
  reg [31:0] dividend_hold_q;
  reg [5:0]  count_q;

  reg [31:0] remainder_next;
  reg [31:0] quotient_next;
  reg [31:0] quotient_fix;
  reg [31:0] remainder_fix;

  wire dividend_neg = signed_mode_i && dividend_i[31];
  wire divisor_neg  = signed_mode_i && divisor_i[31];
  wire [31:0] dividend_abs = dividend_neg ? (~dividend_i + 32'd1) : dividend_i;
  wire [31:0] divisor_abs  = divisor_neg ? (~divisor_i + 32'd1) : divisor_i;
  wire start_div_zero = (divisor_i == 32'b0);
  wire start_overflow = signed_mode_i &&
                        (dividend_i == 32'h8000_0000) &&
                        (divisor_i == 32'hFFFF_FFFF);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy_o          <= 1'b0;
      done_o          <= 1'b0;
      quotient_o      <= 32'b0;
      remainder_o     <= 32'b0;
      remainder_q     <= 32'b0;
      quotient_q      <= 32'b0;
      divisor_q       <= 32'b0;
      quotient_neg_q  <= 1'b0;
      remainder_neg_q <= 1'b0;
      div_zero_q      <= 1'b0;
      overflow_q      <= 1'b0;
      dividend_hold_q <= 32'b0;
      count_q         <= 6'd0;
    end else begin
      done_o <= 1'b0;

      if (start_i && !busy_o) begin
        busy_o          <= 1'b1;
        remainder_q     <= 32'b0;
        quotient_q      <= dividend_abs;
        divisor_q       <= divisor_abs;
        quotient_neg_q  <= dividend_neg ^ divisor_neg;
        remainder_neg_q <= dividend_neg;
        div_zero_q      <= start_div_zero;
        overflow_q      <= start_overflow;
        dividend_hold_q <= dividend_i;
        count_q         <= 6'd0;
      end else if (busy_o) begin
        if (div_zero_q) begin
          busy_o      <= 1'b0;
          done_o      <= 1'b1;
          quotient_o  <= 32'hFFFF_FFFF;
          remainder_o <= dividend_hold_q;
        end else if (overflow_q) begin
          busy_o      <= 1'b0;
          done_o      <= 1'b1;
          quotient_o  <= 32'h8000_0000;
          remainder_o <= 32'b0;
        end else begin
          remainder_next = {remainder_q[30:0], quotient_q[31]};
          quotient_next  = quotient_q << 1;

          if (remainder_next >= divisor_q) begin
            remainder_next = remainder_next - divisor_q;
            quotient_next[0] = 1'b1;
          end

          if (count_q == 6'd31) begin
            quotient_fix = quotient_next;
            remainder_fix = remainder_next;

            if (quotient_neg_q && (quotient_fix != 32'b0)) begin
              quotient_fix = ~quotient_fix + 32'd1;
            end
            if (remainder_neg_q && (remainder_fix != 32'b0)) begin
              remainder_fix = ~remainder_fix + 32'd1;
            end

            busy_o      <= 1'b0;
            done_o      <= 1'b1;
            quotient_o  <= quotient_fix;
            remainder_o <= remainder_fix;
          end else begin
            remainder_q <= remainder_next;
            quotient_q  <= quotient_next;
            count_q     <= count_q + 6'd1;
          end
        end
      end
    end
  end
endmodule
