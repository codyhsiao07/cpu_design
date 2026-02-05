// uart_rx.v
// Minimal 8N1 UART receiver (LSB first).
// Generates a 1-cycle valid pulse with received byte.

module uart_rx #(
  parameter integer CLK_HZ = 100_000_000,
  parameter integer BAUD   = 115_200
) (
  input        clk,
  input        rst_n,
  input        rx_i,
  output reg [7:0] data_o,
  output reg       valid_o
);
  localparam integer CLKS_PER_BIT = (CLK_HZ / BAUD);
  localparam integer HALF_CLKS    = (CLKS_PER_BIT / 2);
  localparam integer CNT_W        = $clog2(CLKS_PER_BIT + 1);

  localparam [1:0] S_IDLE  = 2'd0;
  localparam [1:0] S_START = 2'd1;
  localparam [1:0] S_DATA  = 2'd2;
  localparam [1:0] S_STOP  = 2'd3;

  reg [1:0] state;
  reg [CNT_W-1:0] clk_cnt;
  reg [2:0] bit_idx;
  reg [7:0] shift;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state   <= S_IDLE;
      clk_cnt <= {CNT_W{1'b0}};
      bit_idx <= 3'd0;
      shift   <= 8'd0;
      data_o  <= 8'd0;
      valid_o <= 1'b0;
    end else begin
      valid_o <= 1'b0;
      case (state)
        S_IDLE: begin
          if (!rx_i) begin
            // Detected start bit
            clk_cnt <= HALF_CLKS;
            state   <= S_START;
          end
        end
        S_START: begin
          if (clk_cnt != 0) begin
            clk_cnt <= clk_cnt - 1'b1;
          end else begin
            // Sample start bit (should still be 0)
            if (!rx_i) begin
              clk_cnt <= (CLKS_PER_BIT-1);
              bit_idx <= 3'd0;
              state   <= S_DATA;
            end else begin
              state <= S_IDLE; // false start
            end
          end
        end
        S_DATA: begin
          if (clk_cnt != 0) begin
            clk_cnt <= clk_cnt - 1'b1;
          end else begin
            shift[bit_idx] <= rx_i;
            if (bit_idx == 3'd7) begin
              clk_cnt <= (CLKS_PER_BIT-1);
              state   <= S_STOP;
            end else begin
              bit_idx <= bit_idx + 1'b1;
              clk_cnt <= (CLKS_PER_BIT-1);
            end
          end
        end
        S_STOP: begin
          if (clk_cnt != 0) begin
            clk_cnt <= clk_cnt - 1'b1;
          end else begin
            if (rx_i) begin
              data_o  <= shift;
              valid_o <= 1'b1;
            end
            state <= S_IDLE;
          end
        end
        default: begin
          state <= S_IDLE;
        end
      endcase
    end
  end

endmodule
