`timescale 1ns/1ps

module uart_bootloader_split_ready_tb;
  localparam integer TB_CLK_HZ = 1_000_000;
  localparam integer TB_BAUD = 10_000;
  localparam integer CLKS_PER_BIT = (TB_CLK_HZ / TB_BAUD);

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

  reg [2:0] ready_phase_q = 3'd0;
  wire app_rdy = (ready_phase_q == 3'd0);
  wire app_wdf_rdy = (ready_phase_q == 3'd3);

  reg cmd_pending_q = 1'b0;
  reg wdf_pending_q = 1'b0;
  reg [26:0] cmd_addr_q = 27'd0;
  reg [127:0] wdf_data_q = 128'd0;
  reg [15:0] wdf_mask_q = 16'hFFFF;
  reg [127:0] mem0 = 128'd0;
  reg [127:0] mem1 = 128'd0;
  reg [127:0] mem2 = 128'd0;
  reg rd_pending_q = 1'b0;
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
    .rearm_i(1'b0),
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
    .debug_verify0_w0_ok_o(),
    .debug_verify0_w1_ok_o(),
    .debug_verify0_w2_ok_o(),
    .debug_verify0_w3_ok_o(),
    .debug_verify0_wordrev_ok_o(),
    .debug_verify0_byterev32_ok_o(),
    .debug_verify0_byterev128_ok_o(),
    .debug_verify0_memtest0_ok_o(),
    .debug_verify_req_seen_o(),
    .debug_verify_rsp_seen_o()
  );

  always #500 clk = ~clk;

  task automatic fail;
    input [8*96-1:0] msg;
    begin
      $display("[SPLIT_READY_TB] FAIL: %0s", msg);
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

  task automatic commit_write;
    begin
      case (cmd_addr_q[5:4])
        2'd0: wr_tmp = mem0;
        2'd1: wr_tmp = mem1;
        default: wr_tmp = mem2;
      endcase
      for (i = 0; i < 16; i = i + 1)
        if (!wdf_mask_q[i])
          wr_tmp[i*8 +: 8] = wdf_data_q[i*8 +: 8];
      case (cmd_addr_q[5:4])
        2'd0: mem0 <= wr_tmp;
        2'd1: mem1 <= wr_tmp;
        default: mem2 <= wr_tmp;
      endcase
      cmd_pending_q <= 1'b0;
      wdf_pending_q <= 1'b0;
    end
  endtask

  always @(posedge clk) begin
    app_rd_data_valid <= 1'b0;
    app_rd_data_end <= 1'b0;
    ready_phase_q <= ready_phase_q + 1'b1;

    if (app_en && app_rdy) begin
      if (app_cmd == 3'b001) begin
        rd_pending_q <= 1'b1;
        rd_addr_q <= app_addr[5:4];
      end else begin
        cmd_pending_q <= 1'b1;
        cmd_addr_q <= app_addr;
      end
    end else begin
      rd_pending_q <= 1'b0;
    end

    if (app_wdf_wren && app_wdf_rdy) begin
      wdf_pending_q <= 1'b1;
      wdf_data_q <= app_wdf_data;
      wdf_mask_q <= app_wdf_mask;
    end

    if (cmd_pending_q && wdf_pending_q) begin
      commit_write();
    end

    if (rd_pending_q) begin
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

    repeat (CLKS_PER_BIT * 100) @(posedge clk);

    if (!boot_done_o)
      fail("bootloader did not complete with split command/data ready");
    if (!debug_verify0_ok_o || !debug_verify1_ok_o || !debug_verify2_ok_o)
      fail("readback verification failed with split command/data ready");

    $display("[SPLIT_READY_TB] PASS: split app_rdy/app_wdf_rdy write acceptance works.");
    $finish(0);
  end
endmodule
