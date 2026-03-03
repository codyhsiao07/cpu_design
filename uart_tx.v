// uart_tx.v
// Minimal 8N1 UART transmitter (LSB first).
// Internal baud divider, aligned with uart_rx style (CLK_HZ / BAUD).

module uart_tx #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer BAUD   = 115_200
) (
    input  wire [7:0] data_in,
    input  wire       Tx_en,     // Active-high send request
    input  wire       clk_50m,
    input  wire       rst_n,
    output reg        Tx,
    output wire       Tx_busy
);

    localparam [1:0] TX_STATE_IDLE  = 2'b00;
    localparam [1:0] TX_STATE_START = 2'b01;
    localparam [1:0] TX_STATE_DATA  = 2'b10;
    localparam [1:0] TX_STATE_STOP  = 2'b11;

    localparam integer CLKS_PER_BIT = (CLK_HZ / BAUD); //代表每送 1 個 bit，要撐 434 個 FPGA的 clock 才換下一個 bit
    localparam integer CNT_W        = $clog2(CLKS_PER_BIT + 1); //CNT_W 就是「計數器要幾位」才能數到 434

    reg [7:0] data_buf;
    reg [2:0] bit_pos;
    reg [1:0] state;
    reg [CNT_W-1:0] clk_cnt;

    // Edge-detect Tx_en so a level-high request does not retransmit repeatedly.
    reg tx_en_d;
    wire tx_start = Tx_en & ~tx_en_d;

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            Tx      <= 1'b1;
            tx_en_d <= 1'b0;
            data_buf<= 8'h00;
            bit_pos <= 3'd0;
            state   <= TX_STATE_IDLE;
            clk_cnt <= {CNT_W{1'b0}};
        end else begin
            tx_en_d <= Tx_en;

            case (state)
                TX_STATE_IDLE: begin
                    Tx <= 1'b1; // Idle line is high
                    clk_cnt <= {CNT_W{1'b0}};
                    if (tx_start) begin
                        data_buf <= data_in;
                        bit_pos  <= 3'd0;
                        Tx       <= 1'b0; // Start bit
                        clk_cnt  <= (CLKS_PER_BIT - 1);
                        state    <= TX_STATE_START;
                    end
                end

                TX_STATE_START: begin
                    if (clk_cnt != 0) begin
                        clk_cnt <= clk_cnt - 1'b1;
                    end else begin
                        Tx      <= data_buf[0];
                        clk_cnt <= (CLKS_PER_BIT - 1);
                        state   <= TX_STATE_DATA;
                    end
                end

                TX_STATE_DATA: begin
                    if (clk_cnt != 0) begin
                        clk_cnt <= clk_cnt - 1'b1;
                    end else begin
                        if (bit_pos == 3'd7) begin
                            Tx      <= 1'b1; // Stop bit
                            clk_cnt <= (CLKS_PER_BIT - 1);
                            state   <= TX_STATE_STOP;
                        end else begin
                            bit_pos <= bit_pos + 3'd1;
                            Tx      <= data_buf[bit_pos + 3'd1];
                            clk_cnt <= (CLKS_PER_BIT - 1);
                        end
                    end
                end

                TX_STATE_STOP: begin
                    if (clk_cnt != 0) begin
                        clk_cnt <= clk_cnt - 1'b1;
                    end else begin
                        state <= TX_STATE_IDLE;
                    end
                end

                default: begin
                    Tx    <= 1'b1;
                    state <= TX_STATE_IDLE;
                    clk_cnt <= {CNT_W{1'b0}};
                end
            endcase
        end
    end

    assign Tx_busy = (state != TX_STATE_IDLE);

endmodule
