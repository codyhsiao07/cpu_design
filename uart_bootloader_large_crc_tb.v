`timescale 1ns/1ps

// Accelerated full-image CRC regression. UART decoder outputs are driven
// directly so the real Lua image can be checked without simulating billions
// of serial bit clocks.
module uart_bootloader_large_crc_tb #(
  parameter integer IMAGE_BYTES = 213580,
  parameter [31:0] IMAGE_CRC32 = 32'hD360D14F
);
  localparam integer IMAGE_WORDS = (IMAGE_BYTES + 3) / 4;
  reg [4095:0] memfile;
  integer memfile_fd;

  reg clk = 1'b0;
  reg init_calib_complete = 1'b0;
  reg [31:0] payload_words [0:IMAGE_WORDS-1];
  reg [127:0] ddr_mem [0:(IMAGE_BYTES+15)/16-1];
  reg [127:0] app_rd_data = 128'd0;
  reg app_rd_data_end = 1'b0;
  reg app_rd_data_valid = 1'b0;
  reg rd_pending = 1'b0;
  reg crc_reported = 1'b0;
  reg data_mismatch_reported = 1'b0;
  reg boot_ack_seen = 1'b0;
  reg [14:0] rd_index_q = 15'd0;
  integer i;
  integer byte_lane;
  reg [31:0] reference_crc;

  wire [26:0] app_addr;
  wire [2:0] app_cmd;
  wire app_en;
  wire [127:0] app_wdf_data;
  wire [15:0] app_wdf_mask;
  wire app_wdf_wren;
  wire boot_done_o;
  wire [2:0] debug_state_o;

  uart_bootloader #(
    .CLK_HZ(1_000_000),
    .BAUD(10_000),
    .DDR_BASE(32'h8000_0000),
    .BOOT_ADDR(32'h8000_0000)
  ) dut (
    .clk(clk),
    .uart_rx_i(1'b1),
    .init_calib_complete(init_calib_complete),
    .rearm_i(1'b0),
    .app_addr(app_addr),
    .app_cmd(app_cmd),
    .app_en(app_en),
    .app_wdf_data(app_wdf_data),
    .app_wdf_end(),
    .app_wdf_mask(app_wdf_mask),
    .app_wdf_wren(app_wdf_wren),
    .app_rdy(1'b1),
    .app_wdf_rdy(1'b1),
    .app_rd_data(app_rd_data),
    .app_rd_data_end(app_rd_data_end),
    .app_rd_data_valid(app_rd_data_valid),
    .boot_done_o(boot_done_o),
    .debug_edge_seen_o(),
    .debug_rx_seen_o(),
    .debug_sync_seen_o(),
    .debug_rst_released_o(),
    .debug_state_o(debug_state_o),
    .debug_rx_sel_o(),
    .debug_word0_ok_o(),
    .debug_word1_ok_o(),
    .debug_word2_ok_o(),
    .debug_word3_ok_o(),
    .debug_header_ok_o(),
    .debug_verify0_ok_o(),
    .debug_verify1_ok_o(),
    .debug_verify2_ok_o(),
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

  always #5 clk = ~clk;

  always @(posedge clk) begin
    app_rd_data_valid <= 1'b0;
    app_rd_data_end <= 1'b0;
    if (app_wdf_wren) begin
      for (byte_lane = 0; byte_lane < 16; byte_lane = byte_lane + 1)
        if (!app_wdf_mask[byte_lane])
          ddr_mem[app_addr[18:4]][byte_lane*8 +: 8] <=
            app_wdf_data[byte_lane*8 +: 8];
    end
    if (app_en && (app_cmd == 3'b001)) begin
      rd_pending <= 1'b1;
      rd_index_q <= app_addr[18:4];
    end else begin
      rd_pending <= 1'b0;
    end
    if (rd_pending) begin
      app_rd_data <= ddr_mem[rd_index_q];
      app_rd_data_valid <= 1'b1;
      app_rd_data_end <= 1'b1;
    end
    if (!crc_reported && (dut.state == 3'd4) && dut.data_done) begin
      crc_reported <= 1'b1;
      $display("[LARGE_CRC_TB] FINAL expected=%08x computed=%08x",
               dut.expected_crc_q, dut.payload_crc_q ^ 32'hFFFF_FFFF);
    end
    if (!data_mismatch_reported && (dut.state == 3'd3) &&
        !dut.rx_fifo_empty &&
        (dut.rx_fifo_rdata !==
         payload_words[dut.byte_cnt >> 2][8 * (dut.byte_cnt & 3) +: 8])) begin
      data_mismatch_reported <= 1'b1;
      $display("[LARGE_CRC_TB] DATA_MISMATCH index=%0d expected=%02x actual=%02x fifo_count=%0d",
               dut.byte_cnt,
               payload_words[dut.byte_cnt >> 2][8 * (dut.byte_cnt & 3) +: 8],
               dut.rx_fifo_rdata, dut.rx_fifo_count_q);
    end
    if (dut.report_tx_en_q && (dut.report_tx_data_q == 8'h06))
      boot_ack_seen <= 1'b1;
  end

  task inject_byte;
    input [7:0] value;
    begin
      while (dut.rx_fifo_full)
        @(posedge clk);
      force dut.rx_data_nom = value;
      force dut.rx_valid_nom = 1'b1;
      @(posedge clk);
      #1;
      release dut.rx_valid_nom;
      release dut.rx_data_nom;
    end
  endtask

  task inject_word_le;
    input [31:0] value;
    begin
      inject_byte(value[7:0]);
      inject_byte(value[15:8]);
      inject_byte(value[23:16]);
      inject_byte(value[31:24]);
    end
  endtask

  initial begin
    if (IMAGE_BYTES < 1 || IMAGE_BYTES > 524288)
      $fatal(1, "IMAGE_BYTES must be 1..524288 for this TB memory model");
    memfile = "build_rtos_apps/lua/rtos_lua.mem";
    if ($value$plusargs("MEMFILE=%s", memfile)) begin end
    memfile_fd = $fopen(memfile, "r");
    if (memfile_fd == 0) $fatal(1, "cannot open MEMFILE");
    $fclose(memfile_fd);
    $readmemh(memfile, payload_words);
    for (i = 0; i < IMAGE_WORDS; i = i + 1)
      if ((^payload_words[i]) === 1'bx) $fatal(1, "missing/unknown image word %0d", i);
    reference_crc = 32'hFFFF_FFFF;
    for (i = 0; i < IMAGE_BYTES; i = i + 1)
      reference_crc = dut.crc32_byte(
        reference_crc, payload_words[i >> 2] >> (8 * (i & 3)));
    $display("[LARGE_CRC_TB] REFERENCE crc=%08x", reference_crc ^ 32'hFFFF_FFFF);
    for (i = 0; i < (IMAGE_BYTES+15)/16; i = i + 1)
      ddr_mem[i] = 128'd0;

    repeat (4) @(posedge clk);
    init_calib_complete = 1'b1;
    repeat (4) @(posedge clk);

    inject_word_le(32'hC0DE5A5B);
    inject_word_le(IMAGE_BYTES);
    inject_word_le(IMAGE_CRC32);
    for (i = 0; i < IMAGE_BYTES; i = i + 1)
      inject_byte(payload_words[i >> 2] >> (8 * (i & 3)));

    repeat (300000) @(posedge clk);
    if (!boot_done_o) begin
      $display("[LARGE_CRC_TB] FAIL state=%0d bytes=%0d expected=%08x computed=%08x",
               debug_state_o, dut.byte_cnt, dut.expected_crc_q,
               dut.payload_crc_q ^ 32'hFFFF_FFFF);
      $fatal(1, "boot image did not complete");
    end
    if (!boot_ack_seen) begin
      $display("[LARGE_CRC_TB] FAIL missing loader ACK");
      $fatal(1, "boot image was not acknowledged");
    end
    $display("[LARGE_CRC_TB] PASS bytes=%0d crc=%08x",
             dut.byte_cnt, dut.payload_crc_q ^ 32'hFFFF_FFFF);
    $finish(0);
  end
endmodule
