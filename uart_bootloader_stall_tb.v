`timescale 1ns/1ps

module uart_bootloader_stall_tb;
  localparam integer TB_CLK_HZ = 1_000_000;
  localparam integer TB_BAUD = 10_000;
  localparam integer CLKS_PER_BIT = (TB_CLK_HZ / TB_BAUD);
  localparam integer STALL_CYCLES = 2500;

  reg clk = 1'b0;
  reg uart_rx_i = 1'b1;
  reg init_calib_complete = 1'b0;

  wire [26:0] app_addr;
  wire [2:0] app_cmd;
  wire app_en;
  wire [127:0] app_wdf_data;
  wire app_wdf_end;
  wire [15:0] app_wdf_mask;
  wire app_wdf_wren;
  reg [127:0] app_rd_data = 128'd0;
  reg app_rd_data_end = 1'b0;
  reg app_rd_data_valid = 1'b0;
  wire boot_done_o;
  wire debug_verify0_ok_o;
  wire debug_verify1_ok_o;
  wire debug_verify2_ok_o;

  reg [11:0] stall_cnt_q = 12'd0;
  wire app_rdy = (stall_cnt_q == 12'd0);
  wire app_wdf_rdy = (stall_cnt_q == 12'd0);
  wire write_fire = app_en && app_wdf_wren && app_rdy && app_wdf_rdy;

  reg [127:0] mem0 = 128'd0;
  reg [127:0] mem1 = 128'd0;
  reg [127:0] mem2 = 128'd0;
  reg rd_pending = 1'b0;
  reg [1:0] rd_addr_q = 2'd0;

  integer i;
  reg [127:0] wr_tmp;

  uart_bootloader #(
    .CLK_HZ(TB_CLK_HZ),
    .BAUD(TB_BAUD),
    .DDR_BASE(32'h8000_0000),
    .BOOT_ADDR(32'h8000_0000)
  ) dut (
    .clk(clk),
    .uart_rx_i(uart_rx_i),
    .init_calib_complete(init_calib_complete),
    .app_addr(app_addr),
    .app_cmd(app_cmd),
    .app_en(app_en),
    .app_wdf_data(app_wdf_data),
    .app_wdf_end(app_wdf_end),
    .app_wdf_mask(app_wdf_mask),
    .app_wdf_wren(app_wdf_wren),
    .app_rdy(app_rdy),
    .app_wdf_rdy(app_wdf_rdy),
    .app_rd_data(app_rd_data),
    .app_rd_data_end(app_rd_data_end),
    .app_rd_data_valid(app_rd_data_valid),
    .boot_done_o(boot_done_o),
    .debug_edge_seen_o(),
    .debug_rx_seen_o(),
    .debug_sync_seen_o(),
    .debug_rst_released_o(),
    .debug_state_o(),
    .debug_rx_sel_o(),
    .debug_word0_ok_o(),
    .debug_word1_ok_o(),
    .debug_word2_ok_o(),
    .debug_word3_ok_o(),
    .debug_header_ok_o(),
    .debug_verify0_ok_o(debug_verify0_ok_o),
    .debug_verify1_ok_o(debug_verify1_ok_o),
    .debug_verify2_ok_o(debug_verify2_ok_o),
    .debug_verify_req_seen_o(),
    .debug_verify_rsp_seen_o()
  );

  always #500 clk = ~clk;

  task automatic fail;
    input [8*96-1:0] msg;
    begin
      $display("[STALL_TB] FAIL: %0s", msg);
      $finish(1);
    end
  endtask

  task automatic send_bit;
    input bit_value;
    integer j;
    begin
      uart_rx_i = bit_value;
      for (j = 0; j < CLKS_PER_BIT; j = j + 1)
        @(posedge clk);
    end
  endtask

  task automatic send_byte;
    input [7:0] data;
    integer j;
    begin
      send_bit(1'b0);
      for (j = 0; j < 8; j = j + 1)
        send_bit(data[j]);
      send_bit(1'b1);
    end
  endtask

  task automatic send_word_le;
    input [31:0] word_value;
    begin
      send_byte(word_value[7:0]);
      send_byte(word_value[15:8]);
      send_byte(word_value[23:16]);
      send_byte(word_value[31:24]);
    end
  endtask

  always @(posedge clk) begin
    app_rd_data_valid <= 1'b0;
    app_rd_data_end <= 1'b0;

    if (stall_cnt_q != 12'd0)
      stall_cnt_q <= stall_cnt_q - 1'b1;

    if (write_fire) begin
      case (app_addr[5:4])
        2'd0: wr_tmp = mem0;
        2'd1: wr_tmp = mem1;
        default: wr_tmp = mem2;
      endcase
      for (i = 0; i < 16; i = i + 1)
        if (!app_wdf_mask[i])
          wr_tmp[i*8 +: 8] = app_wdf_data[i*8 +: 8];
      case (app_addr[5:4])
        2'd0: mem0 <= wr_tmp;
        2'd1: mem1 <= wr_tmp;
        default: mem2 <= wr_tmp;
      endcase
      stall_cnt_q <= STALL_CYCLES[11:0];
    end

    if (app_en && (app_cmd == 3'b001) && app_rdy) begin
      rd_pending <= 1'b1;
      rd_addr_q <= app_addr[5:4];
    end else begin
      rd_pending <= 1'b0;
    end

    if (rd_pending) begin
      app_rd_data_valid <= 1'b1;
      app_rd_data_end <= 1'b1;
      case (rd_addr_q)
        2'd0: app_rd_data <= mem0;
        2'd1: app_rd_data <= mem1;
        default: app_rd_data <= mem2;
      endcase
    end
  end

  initial begin
    repeat (8) @(posedge clk);
    init_calib_complete = 1'b1;
    repeat (CLKS_PER_BIT * 2) @(posedge clk);

    send_word_le(32'hC0DE5A5A);
    send_word_le(32'd48);
    for (i = 0; i < 48; i = i + 1)
      send_byte(i[7:0]);

    repeat (CLKS_PER_BIT * 80) @(posedge clk);

    if (!boot_done_o)
      fail("bootloader did not complete under MIG backpressure");
    if (!debug_verify0_ok_o || !debug_verify1_ok_o || !debug_verify2_ok_o)
      fail("verify bits were not all asserted under backpressure");

    $display("[STALL_TB] PASS: bootloader tolerates stalled app_rdy/app_wdf_rdy.");
    $finish(0);
  end
endmodule
