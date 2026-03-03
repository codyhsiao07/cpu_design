// uart_bootloader.v
// Minimal UART-based DDR loader using MIG app interface.
// Protocol:
//   1) Host sends 4-byte little-endian length N
//   2) Host sends N data bytes (written to DDR starting at BOOT_ADDR)
// After all bytes are written, boot_done_o is asserted.

module uart_bootloader #(
  parameter integer CLK_HZ    = 100_000_000,
  parameter integer BAUD      = 115_200,
  parameter [31:0] DDR_BASE   = 32'h8000_0000,
  parameter [31:0] BOOT_ADDR  = 32'h8000_0000
) (
  input               clk,
  input               rst_n,
  input               uart_rx_i,
  input               init_calib_complete,

  // MIG app write interface
  output reg [26:0]   app_addr,
  output reg [2:0]    app_cmd,
  output reg          app_en,
  output reg [127:0]  app_wdf_data,
  output reg          app_wdf_end,
  output reg [15:0]   app_wdf_mask,
  output reg          app_wdf_wren,
  input               app_rdy,
  input               app_wdf_rdy,

  output reg          boot_done_o
);
  localparam [2:0] MIG_CMD_WRITE = 3'b000;

  // UART RX (sync)
  reg rx_ff1;
  reg rx_ff2;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_ff1 <= 1'b1;
      rx_ff2 <= 1'b1;
    end else begin
      rx_ff1 <= uart_rx_i;
      rx_ff2 <= rx_ff1;
    end
  end

  wire [7:0] rx_data;
  wire       rx_valid;
  uart_rx #(
    .CLK_HZ (CLK_HZ),
    .BAUD   (BAUD)
  ) u_rx (
    .clk     (clk),
    .rst_n   (rst_n),
    .rx_i    (rx_ff2),
    .data_o  (rx_data),
    .valid_o (rx_valid)
  );

  // Loader FSM
  localparam [2:0] S_WAIT = 3'd0;
  localparam [2:0] S_LEN  = 3'd1;
  localparam [2:0] S_DATA = 3'd2;
  localparam [2:0] S_SEND = 3'd3;
  localparam [2:0] S_DONE = 3'd4;

  reg [2:0]  state;
  reg [1:0]  len_cnt;
  reg [31:0] bytes_total;
  reg [31:0] byte_cnt;
  reg [3:0]  buf_idx;
  reg [127:0] buf_data;
  reg [15:0]  buf_mask;
  reg [31:0]  curr_addr;
  reg         data_done;

  wire fire_write = (state == S_SEND) && app_rdy && app_wdf_rdy;

  // Default MIG outputs
  always @(*) begin
    app_addr     = 27'd0;
    app_cmd      = MIG_CMD_WRITE;
    app_en       = 1'b0;
    app_wdf_data = buf_data;
    app_wdf_end  = 1'b0;
    app_wdf_mask = buf_mask;
    app_wdf_wren = 1'b0;
    if (state == S_SEND) begin
      app_addr     = (curr_addr - DDR_BASE) >> 4;
      app_cmd      = MIG_CMD_WRITE;
      app_en       = app_rdy && app_wdf_rdy;
      app_wdf_wren = app_rdy && app_wdf_rdy;
      app_wdf_end  = app_rdy && app_wdf_rdy;
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= S_WAIT;
      len_cnt     <= 2'd0;
      bytes_total <= 32'd0;
      byte_cnt    <= 32'd0;
      buf_idx     <= 4'd0;
      buf_data    <= 128'd0;
      buf_mask    <= 16'hFFFF;
      curr_addr   <= BOOT_ADDR;
      data_done   <= 1'b0;
      boot_done_o <= 1'b0;
    end else begin
      case (state)
        S_WAIT: begin
          boot_done_o <= 1'b0;
          if (init_calib_complete) begin
            len_cnt  <= 2'd0;
            state    <= S_LEN;
          end
        end
        S_LEN: begin
          if (rx_valid) begin
            bytes_total[8*len_cnt +: 8] <= rx_data;
            if (len_cnt == 2'd3) begin
              len_cnt   <= 2'd0;
              byte_cnt  <= 32'd0;
              buf_idx   <= 4'd0;
              buf_data  <= 128'd0;
              buf_mask  <= 16'hFFFF;
              curr_addr <= BOOT_ADDR;
              data_done <= 1'b0;
              if ({rx_data, bytes_total[23:0]} == 32'd0) begin
                boot_done_o <= 1'b1;
                state <= S_DONE;
              end else begin
                state <= S_DATA;
              end
            end else begin
              len_cnt <= len_cnt + 1'b1;
            end
          end
        end
        S_DATA: begin
          if (rx_valid) begin
            buf_data[buf_idx*8 +: 8] <= rx_data;
            buf_mask[buf_idx] <= 1'b0;
            if (byte_cnt == (bytes_total - 1)) begin
              data_done <= 1'b1;
            end
            byte_cnt <= byte_cnt + 1'b1;

            if ((buf_idx == 4'd15) || (byte_cnt == (bytes_total - 1))) begin
              state <= S_SEND;
            end
            buf_idx <= buf_idx + 1'b1;
          end
        end
        S_SEND: begin
          if (fire_write) begin
            if (data_done) begin
              boot_done_o <= 1'b1;
              state <= S_DONE;
            end else begin
              curr_addr <= curr_addr + 32'd16;
              buf_idx  <= 4'd0;
              buf_data <= 128'd0;
              buf_mask <= 16'hFFFF;
              state <= S_DATA;
            end
          end
        end
        S_DONE: begin
          boot_done_o <= 1'b1;
        end
        default: begin
          state <= S_WAIT;
        end
      endcase
    end
  end

endmodule
