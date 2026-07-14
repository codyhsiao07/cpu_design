`timescale 1ns/1ps

module uart_bootloader_tb;
  localparam integer TB_CLK_HZ = 1_000_000;
  localparam integer TB_BAUD = 10_000;
  localparam integer CLKS_PER_BIT = (TB_CLK_HZ / TB_BAUD);

  reg clk = 1'b0;
  reg uart_rx_i = 1'b1;
  reg init_calib_complete = 1'b0;
  reg rearm_i = 1'b0;

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
  wire debug_edge_seen_o;
  wire debug_rx_seen_o;
  wire debug_sync_seen_o;
  wire debug_rst_released_o;
  wire [2:0] debug_state_o;
  wire debug_verify0_ok_o;
  wire debug_verify1_ok_o;
  wire debug_verify2_ok_o;

  reg app_cmd_seen = 1'b0;
  reg app_wdf_seen = 1'b0;
  reg [127:0] last_wdf_data = 128'd0;
  reg [15:0] last_wdf_mask = 16'hFFFF;
  reg [127:0] mem0 = 128'd0;
  reg [127:0] mem1 = 128'd0;
  reg [127:0] mem2 = 128'd0;
  reg rd_pending = 1'b0;
  reg [1:0] rd_addr_q = 2'd0;

  uart_bootloader #(
    .CLK_HZ(TB_CLK_HZ),
    .BAUD(TB_BAUD),
    .DDR_BASE(32'h8000_0000),
    .BOOT_ADDR(32'h8000_0000)
  ) dut (
    .clk(clk),
    .uart_rx_i(uart_rx_i),
    .init_calib_complete(init_calib_complete),
    .rearm_i(rearm_i),
    .app_addr(app_addr),
    .app_cmd(app_cmd),
    .app_en(app_en),
    .app_wdf_data(app_wdf_data),
    .app_wdf_end(app_wdf_end),
    .app_wdf_mask(app_wdf_mask),
    .app_wdf_wren(app_wdf_wren),
    .app_rdy(1'b1),
    .app_wdf_rdy(1'b1),
    .app_rd_data(app_rd_data),
    .app_rd_data_end(app_rd_data_end),
    .app_rd_data_valid(app_rd_data_valid),
    .boot_done_o(boot_done_o),
    .debug_edge_seen_o(debug_edge_seen_o),
    .debug_rx_seen_o(debug_rx_seen_o),
    .debug_sync_seen_o(debug_sync_seen_o),
    .debug_rst_released_o(debug_rst_released_o),
    .debug_state_o(debug_state_o),
    .debug_word0_ok_o(),
    .debug_word1_ok_o(),
    .debug_header_ok_o(),
    .debug_verify0_ok_o(debug_verify0_ok_o),
    .debug_verify1_ok_o(debug_verify1_ok_o),
    .debug_verify2_ok_o(debug_verify2_ok_o)
  );

  always #500 clk = ~clk;

  always @(posedge clk) begin
    app_rd_data_valid <= 1'b0;
    app_rd_data_end <= 1'b0;
    if (app_en)
      app_cmd_seen <= 1'b1;
    if (app_wdf_wren) begin
      app_wdf_seen <= 1'b1;
      last_wdf_data <= app_wdf_data;
      last_wdf_mask <= app_wdf_mask;
      case (app_addr[5:4])
        2'd0: mem0 <= app_wdf_data;
        2'd1: mem1 <= app_wdf_data;
        default: mem2 <= app_wdf_data;
      endcase
    end
    if (app_en && (app_cmd == 3'b001)) begin
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

  task automatic fail;
    input [8*96-1:0] msg;
    begin
      $display("[TB] FAIL: %0s", msg);
      $finish(1);
    end
  endtask

  task automatic send_bit;
    input bit_value;
    integer i;
    begin
      uart_rx_i = bit_value;
      for (i = 0; i < CLKS_PER_BIT; i = i + 1)
        @(posedge clk);
    end
  endtask

  task automatic send_byte;
    input [7:0] data;
    integer i;
    begin
      send_bit(1'b0);
      for (i = 0; i < 8; i = i + 1)
        send_bit(data[i]);
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

  initial begin
    repeat (8) @(posedge clk);
    init_calib_complete = 1'b1;
    repeat (CLKS_PER_BIT * 2) @(posedge clk);

    send_word_le(32'hC0DE5A5A);
    send_word_le(32'd4);
    send_byte(8'h11);
    send_byte(8'h22);
    send_byte(8'h33);
    send_byte(8'h44);

    repeat (CLKS_PER_BIT * 12) @(posedge clk);

    if (!debug_rst_released_o)
      fail("bootloader reset never released");
    if (!debug_edge_seen_o)
      fail("bootloader never observed RX edges");
    if (!debug_rx_seen_o)
      fail("bootloader never decoded a UART byte");
    if (!debug_sync_seen_o)
      fail("bootloader never detected the sync word");
    if (!app_cmd_seen || !app_wdf_seen)
      fail("bootloader never issued a MIG write");
    if (last_wdf_data[31:0] !== 32'h44332211)
      fail("unexpected MIG write payload");
    if (last_wdf_mask !== 16'hFFF0)
      fail("unexpected MIG write mask");
    if (!boot_done_o)
      fail("bootloader never reached done");
    if (debug_state_o !== 3'd5)
      fail("bootloader did not finish in S_DONE");
    if (!debug_verify0_ok_o || !debug_verify1_ok_o || !debug_verify2_ok_o)
      fail("bootloader readback verification did not pass");

    // A launcher-requested rearm must return the loader to sync search so a
    // second image can replace the first one without power-cycling the FPGA.
    rearm_i = 1'b1;
    repeat (3) @(posedge clk);
    rearm_i = 1'b0;
    repeat (3) @(posedge clk);
    if (boot_done_o)
      fail("bootloader remained done after rearm");

    send_word_le(32'hC0DE5A5A);
    send_word_le(32'd4);
    send_byte(8'hA5);
    send_byte(8'h5A);
    send_byte(8'hC3);
    send_byte(8'h3C);

    repeat (CLKS_PER_BIT * 12) @(posedge clk);
    if (!boot_done_o)
      fail("bootloader never completed the second image");
    if (last_wdf_data[31:0] !== 32'h3CC35AA5)
      fail("second image did not replace the first image");
    if (!debug_verify0_ok_o || !debug_verify1_ok_o || !debug_verify2_ok_o)
      fail("second image readback verification did not pass");

    // A fresh protocol SYNC must also recover directly from S_DONE. This is
    // the host-side escape hatch when the running CPU is wedged and therefore
    // cannot request a software rearm.
    send_word_le(32'hC0DE5A5A);
    send_word_le(32'd4);
    send_byte(8'hDE);
    send_byte(8'hAD);
    send_byte(8'hBE);
    send_byte(8'hEF);

    repeat (CLKS_PER_BIT * 12) @(posedge clk);
    if (!boot_done_o)
      fail("bootloader never completed host-sync recovery image");
    if (last_wdf_data[31:0] !== 32'hEFBEADDE)
      fail("host-sync recovery did not replace the previous image");
    if (!debug_verify0_ok_o || !debug_verify1_ok_o || !debug_verify2_ok_o)
      fail("host-sync recovery readback verification did not pass");

    $display("[TB] PASS: rearm and host-sync recovery images passed readback verification.");
    $finish(0);
  end
endmodule
