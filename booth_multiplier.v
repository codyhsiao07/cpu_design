module booth_multiplier(
  input clk,
  input rst_n,

  input start_i,
  input [31:0] a_i,
  input [31:0] b_i,
  input signed_a_i,
  input signed_b_i,
  input high_half_i,

  output reg busy_o,
  output reg done_o,
  output reg [31:0] result_o
);

  reg [63:0] accum_q;
  reg [63:0] multiplicand_q;
  reg [31:0] multiplier_q;
  reg        negate_q;
  reg        high_half_q;
  reg [5:0]  count_q;

  reg [63:0] accum_next;
  reg [63:0] product_next;
  reg [63:0] signed_product_next;

  wire [31:0] abs_a = (signed_a_i && a_i[31]) ? (~a_i + 32'd1) : a_i;
  wire [31:0] abs_b = (signed_b_i && b_i[31]) ? (~b_i + 32'd1) : b_i;
  wire        negate_start = (signed_a_i && a_i[31]) ^ (signed_b_i && b_i[31]);

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy_o         <= 1'b0;
      done_o         <= 1'b0;
      result_o       <= 32'b0;
      accum_q        <= 64'b0;
      multiplicand_q <= 64'b0;
      multiplier_q   <= 32'b0;
      negate_q       <= 1'b0;
      high_half_q    <= 1'b0;
      count_q        <= 6'd0;
    end else begin
      done_o <= 0;

      if (start_i && !busy_o) begin
        busy_o         <= 1'b1;
        accum_q        <= 64'b0;
        multiplicand_q <= {32'b0, abs_a};
        multiplier_q   <= abs_b;
        negate_q       <= negate_start;
        high_half_q    <= high_half_i;
        count_q        <= 6'd0;
      end else if (busy_o) begin
        accum_next = accum_q;
        if (multiplier_q[0]) begin
          accum_next = accum_q + multiplicand_q;
        end
        product_next = accum_next;
        if (negate_q) begin
          signed_product_next = (~product_next) + 64'd1;
        end else begin
          signed_product_next = product_next;
        end

        if (count_q == 6'd31) begin
          busy_o   <= 1'b0;
          done_o   <= 1'b1;
          result_o <= high_half_q ? signed_product_next[63:32] : signed_product_next[31:0];
        end else begin
          accum_q        <= accum_next;
          multiplicand_q <= multiplicand_q << 1;
          multiplier_q   <= multiplier_q >> 1;
          count_q        <= count_q + 6'd1;
        end
      end
    end
  end

endmodule
