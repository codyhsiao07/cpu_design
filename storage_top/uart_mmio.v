`timescale 1ns/1ps
// uart_mmio.v - Minimal memory-mapped UART (TX focus, RX stub)
module uart_mmio
#(
  parameter integer CLK_FREQ_HZ = 100_000_000,
  parameter integer BAUD_RATE   = 115200
)(
  input             clk,
  input             rst_n,
  input             req_valid_i,
  input             req_we_i,
  input      [31:0] req_addr_i,
  input      [31:0] req_wdata_i,
  input      [3:0]  req_wstrb_i,
  output            req_ready_o,
  output            resp_valid_o,
  output     [31:0] resp_rdata_o,
  output            resp_err_o,
  output            store_done_o,
  output            store_err_o,
  input             uart_rx_i,   // currently unused (RX stub)
  output            uart_tx_o
);

  function integer clog2;
    input integer value;
    integer result;
    begin
      result = 0;
      value  = value - 1;
      while (value > 0) begin
        value  = value >> 1;
        result = result + 1;
      end
      clog2 = (result == 0) ? 1 : result;
    end
  endfunction

  localparam integer BAUD_DIV = (BAUD_RATE == 0) ? 1 :
                                ((CLK_FREQ_HZ + (BAUD_RATE/2)) / BAUD_RATE);
  localparam integer BAUD_CNT_BITS = clog2(BAUD_DIV);

  // Decode registers (word offsets)
  wire [1:0] addr_word = req_addr_i[3:2];
  wire       sel_data   = (addr_word == 2'd0);
  wire       sel_status = (addr_word == 2'd1);
  wire       addr_valid = sel_data | sel_status;

  wire tx_target_write = req_valid_i & req_we_i & sel_data;

  wire tx_ready;
  wire tx_accept = tx_target_write & req_wstrb_i[0] & tx_ready;

  assign req_ready_o =
      (~req_valid_i) ? 1'b1 :
      (tx_target_write ? (tx_ready & req_wstrb_i[0]) : 1'b1);

  wire req_fire = req_valid_i & req_ready_o;

  assign store_done_o = req_fire & req_we_i;
  assign store_err_o  = req_fire & req_we_i & ~addr_valid;

  reg resp_valid_q;
  reg resp_err_q;
  reg [31:0] resp_data_q;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      resp_valid_q <= 1'b0;
      resp_err_q   <= 1'b0;
      resp_data_q  <= 32'h0;
    end else begin
      resp_valid_q <= req_fire & (~req_we_i);
      resp_err_q   <= (req_fire & (~req_we_i) & ~addr_valid);
      if (req_fire && ~req_we_i) begin
        if (sel_status) begin
          resp_data_q <= {30'h0, 1'b0 /* rx valid stub */, tx_ready};
        end else if (sel_data) begin
          resp_data_q <= 32'h0000_0000;
        end else begin
          resp_data_q <= 32'h0;
        end
      end else if (!resp_valid_q) begin
        resp_data_q <= 32'h0;
      end
    end
  end

  assign resp_valid_o = resp_valid_q;
  assign resp_err_o   = resp_err_q;
  assign resp_rdata_o = resp_data_q;

  // ---------------- UART TX ----------------
  reg [9:0]  tx_shift_q;
  reg [3:0]  tx_bit_cnt_q;
  reg [BAUD_CNT_BITS-1:0] baud_cnt_q;
  reg        tx_busy_q;

  wire baud_tick = (baud_cnt_q == (BAUD_DIV-1));

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_shift_q   <= 10'h3FF;
      tx_bit_cnt_q <= 4'd0;
      baud_cnt_q   <= {BAUD_CNT_BITS{1'b0}};
      tx_busy_q    <= 1'b0;
    end else begin
      if (tx_busy_q) begin
        if (baud_tick) begin
          baud_cnt_q <= {BAUD_CNT_BITS{1'b0}};
          tx_shift_q <= {1'b1, tx_shift_q[9:1]};
          if (tx_bit_cnt_q == 4'd9) begin
            tx_bit_cnt_q <= 4'd0;
            tx_busy_q    <= 1'b0;
          end else begin
            tx_bit_cnt_q <= tx_bit_cnt_q + 4'd1;
          end
        end else begin
          baud_cnt_q <= baud_cnt_q + {{(BAUD_CNT_BITS-1){1'b0}},1'b1};
        end
      end else begin
        baud_cnt_q   <= {BAUD_CNT_BITS{1'b0}};
        tx_bit_cnt_q <= 4'd0;
        tx_shift_q   <= 10'h3FF;
        if (tx_accept) begin
          tx_busy_q  <= 1'b1;
          tx_shift_q <= {1'b1, req_wdata_i[7:0], 1'b0};
        end else begin
          tx_busy_q <= 1'b0;
        end
      end
    end
  end

  assign tx_ready  = ~tx_busy_q;
  assign uart_tx_o = tx_shift_q[0];

  // RX stub (avoid unused signal warnings)
  wire unused_rx;
  assign unused_rx = uart_rx_i;

endmodule
