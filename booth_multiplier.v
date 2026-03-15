module booth_multiplier(
  input clk,
  input rst_n,

  input start_i,
  input [31:0] a_i,
  input [31:0] b_i,

  output reg busy_o,
  output reg done_o,
  output reg [31:0] result_o
);

  reg [63:0] product;
  reg [31:0] multiplicand;
  reg [31:0] multiplier;

  reg [5:0] count;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy_o <= 0;
      done_o <= 0;
      result_o <= 0;
      product <= 0;
      multiplicand <= 0;
      multiplier <= 0;
      count <= 0;
    end
    else begin

      done_o <= 0;

      // start
      if (start_i && !busy_o) begin
        busy_o <= 1;
        multiplicand <= a_i;
        multiplier <= b_i;
        product <= 0;
        count <= 0;
      end

      // calculation
      else if (busy_o) begin

        if (multiplier[0])
          product <= product + ( {32'b0,multiplicand} << count );

        multiplier <= multiplier >> 1;
        count <= count + 1;

        if (count == 31) begin
          busy_o <= 0;
          done_o <= 1;
          result_o <= product[31:0];
        end

      end

    end
  end

endmodule