module restoring_divider(
  input clk,
  input rst_n,

  input start_i,
  input [31:0] dividend_i,
  input [31:0] divisor_i,

  output reg busy_o,
  output reg done_o,

  output reg [31:0] quotient_o,
  output reg [31:0] remainder_o
);

reg [31:0] remainder;
reg [31:0] quotient;
reg [31:0] divisor;
reg [5:0]  count;

reg [31:0] remainder_next;
reg [31:0] quotient_next;

always @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    busy_o <= 0;
    done_o <= 0;
    remainder <= 0;
    quotient <= 0;
    divisor <= 0;
    quotient_o <= 0;
    remainder_o <= 0;
    count <= 0;
  end
  else begin

    done_o <= 0;

    if (start_i && !busy_o) begin
      busy_o <= 1;
      remainder <= 0;
      quotient <= dividend_i;
      divisor <= divisor_i;
      count <= 0;
    end

    else if (busy_o) begin

      // shift
      remainder_next = {remainder[30:0], quotient[31]};
      quotient_next  = quotient << 1;

      // subtract
      if (remainder_next >= divisor) begin
        remainder_next = remainder_next - divisor;
        quotient_next[0] = 1'b1;
      end

      remainder <= remainder_next;
      quotient  <= quotient_next;

      if (count == 31) begin
        busy_o <= 0;
        done_o <= 1;
        quotient_o <= quotient_next;
        remainder_o <= remainder_next;
      end
      else begin
        count <= count + 1;
      end

    end

  end
end

endmodule