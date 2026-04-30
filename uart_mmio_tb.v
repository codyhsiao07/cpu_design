`timescale 1ns/1ps

module uart_mmio_tb;
  localparam integer TB_UART_CLK_HZ = 100;
  localparam integer TB_UART_BAUD   = 10;
  localparam integer CLKS_PER_BIT   = (TB_UART_CLK_HZ / TB_UART_BAUD);
  localparam integer HALF_CLKS      = (CLKS_PER_BIT / 2);

  localparam [31:0] UART_TX_DATA_ADDR   = 32'h4000_0000;
  localparam [31:0] UART_TX_STATUS_ADDR = 32'h4000_0004;
  localparam [31:0] UART_RX_DATA_ADDR   = 32'h4000_0008;
  localparam [31:0] UART_RX_STATUS_ADDR = 32'h4000_000C;
  localparam [31:0] UART_BAD_ADDR       = 32'h4000_0030;

  reg clk;
  reg rst_n;
  reg uart_rx_i;

  wire uart_tx_o;

  wire [15:0] ddr2_dq;
  wire [1:0]  ddr2_dqs_n;
  wire [1:0]  ddr2_dqs_p;
  wire [12:0] ddr2_addr;
  wire [2:0]  ddr2_ba;
  wire        ddr2_ras_n;
  wire        ddr2_cas_n;
  wire        ddr2_we_n;
  wire [0:0]  ddr2_ck_p;
  wire [0:0]  ddr2_ck_n;
  wire [0:0]  ddr2_cke;
  wire [0:0]  ddr2_cs_n;
  wire [1:0]  ddr2_dm;
  wire [0:0]  ddr2_odt;
  wire        init_calib_complete;

  wire        l2_req_valid;
  reg         l2_req_ready;
  wire [31:0] l2_req_addr;
  wire [1:0]  l2_req_cmd;
  wire [2:0]  l2_req_size;
  wire [7:0]  l2_req_len;
  reg         l2_rsp_valid;
  wire        l2_rsp_ready;
  reg  [63:0] l2_rsp_data;
  reg         l2_rsp_last;
  reg         l2_rsp_err;

  wire        d_l2_req_valid;
  reg         d_l2_req_ready;
  wire [31:0] d_l2_req_addr;
  wire [1:0]  d_l2_req_cmd;
  wire [2:0]  d_l2_req_size;
  wire [7:0]  d_l2_req_len;
  wire [63:0] d_l2_req_wdata;
  wire [7:0]  d_l2_req_wstrb;
  reg         d_l2_rsp_valid;
  wire        d_l2_rsp_ready;
  reg  [63:0] d_l2_rsp_rdata;
  reg         d_l2_rsp_last;
  reg         d_l2_rsp_err;

  wire        wb_we_o;
  wire [4:0]  wb_rd_o;
  wire [31:0] wb_wdata_o;
  wire        ifetch_err_o;
  wire        boot_done_o;

  reg [31:0] mmio_rdata;
  reg        mmio_err;

  icache_pipeline_top #(
    .USE_MIG      (0),
    .UART_BOOT_EN (0),
    .UART_CLK_HZ  (TB_UART_CLK_HZ),
    .UART_BAUD    (TB_UART_BAUD)
  ) dut (
    .clk                 (clk),
    .rst_n               (rst_n),
    .launcher_reset_req_i(1'b0),
    .uart_rx_i           (uart_rx_i),
    .uart_tx_o           (uart_tx_o),
    .ddr2_dq             (ddr2_dq),
    .ddr2_dqs_n          (ddr2_dqs_n),
    .ddr2_dqs_p          (ddr2_dqs_p),
    .ddr2_addr           (ddr2_addr),
    .ddr2_ba             (ddr2_ba),
    .ddr2_ras_n          (ddr2_ras_n),
    .ddr2_cas_n          (ddr2_cas_n),
    .ddr2_we_n           (ddr2_we_n),
    .ddr2_ck_p           (ddr2_ck_p),
    .ddr2_ck_n           (ddr2_ck_n),
    .ddr2_cke            (ddr2_cke),
    .ddr2_cs_n           (ddr2_cs_n),
    .ddr2_dm             (ddr2_dm),
    .ddr2_odt            (ddr2_odt),
    .sys_clk_i           (1'b0),
    .clk_ref_i           (1'b0),
    .init_calib_complete (init_calib_complete),
    .l2_req_valid        (l2_req_valid),
    .l2_req_ready        (l2_req_ready),
    .l2_req_addr         (l2_req_addr),
    .l2_req_cmd          (l2_req_cmd),
    .l2_req_size         (l2_req_size),
    .l2_req_len          (l2_req_len),
    .l2_rsp_valid        (l2_rsp_valid),
    .l2_rsp_ready        (l2_rsp_ready),
    .l2_rsp_data         (l2_rsp_data),
    .l2_rsp_last         (l2_rsp_last),
    .l2_rsp_err          (l2_rsp_err),
    .d_l2_req_valid      (d_l2_req_valid),
    .d_l2_req_ready      (d_l2_req_ready),
    .d_l2_req_addr       (d_l2_req_addr),
    .d_l2_req_cmd        (d_l2_req_cmd),
    .d_l2_req_size       (d_l2_req_size),
    .d_l2_req_len        (d_l2_req_len),
    .d_l2_req_wdata      (d_l2_req_wdata),
    .d_l2_req_wstrb      (d_l2_req_wstrb),
    .d_l2_rsp_valid      (d_l2_rsp_valid),
    .d_l2_rsp_ready      (d_l2_rsp_ready),
    .d_l2_rsp_rdata      (d_l2_rsp_rdata),
    .d_l2_rsp_last       (d_l2_rsp_last),
    .d_l2_rsp_err        (d_l2_rsp_err),
    .wb_we_o             (wb_we_o),
    .wb_rd_o             (wb_rd_o),
    .wb_wdata_o          (wb_wdata_o),
    .ifetch_err_o        (ifetch_err_o),
    .boot_done_o         (boot_done_o)
  );

  always #5 clk = ~clk;

  task automatic fail;
    input [8*96-1:0] msg;
    begin
      $display("[TB] FAIL: %0s", msg);
      $finish;
    end
  endtask

  task mmio_idle;
    begin
      force dut.dmem_req_o   = 1'b0;
      force dut.dmem_addr_o  = 32'd0;
      force dut.dmem_we_o    = 1'b0;
      force dut.dmem_wdata_o = 32'd0;
      force dut.dmem_wstrb_o = 4'd0;
    end
  endtask

  task mmio_write;
    input [31:0] addr;
    input [31:0] data;
    input [3:0]  wstrb;
    begin
      @(negedge clk);
      force dut.dmem_req_o   = 1'b1;
      force dut.dmem_addr_o  = addr;
      force dut.dmem_we_o    = 1'b1;
      force dut.dmem_wdata_o = data;
      force dut.dmem_wstrb_o = wstrb;
      #1;
      while (dut.dmem_ready_i !== 1'b1) begin
        @(posedge clk);
        @(negedge clk);
        #1;
      end
      if (dut.dmem_rvalid_i !== 1'b1) begin
        fail("MMIO write did not generate a response");
      end
      @(posedge clk);
      #1;
      mmio_idle();
    end
  endtask

  task mmio_read;
    input  [31:0] addr;
    output [31:0] data;
    output        err;
    begin
      @(negedge clk);
      force dut.dmem_req_o   = 1'b1;
      force dut.dmem_addr_o  = addr;
      force dut.dmem_we_o    = 1'b0;
      force dut.dmem_wdata_o = 32'd0;
      force dut.dmem_wstrb_o = 4'd0;
      #1;
      while (dut.dmem_ready_i !== 1'b1) begin
        @(posedge clk);
        @(negedge clk);
        #1;
      end
      if (dut.dmem_rvalid_i !== 1'b1) begin
        fail("MMIO read did not generate a response");
      end
      data = dut.dmem_rdata_i;
      err  = dut.dmem_rsp_err_i;
      @(posedge clk);
      #1;
      mmio_idle();
    end
  endtask

  task automatic send_uart_byte;
    input [7:0] data;
    integer i;
    begin
      @(negedge clk);
      uart_rx_i = 1'b0;
      repeat (CLKS_PER_BIT) @(posedge clk);
      for (i = 0; i < 8; i = i + 1) begin
        @(negedge clk);
        uart_rx_i = data[i];
        repeat (CLKS_PER_BIT) @(posedge clk);
      end
      @(negedge clk);
      uart_rx_i = 1'b1;
      repeat (CLKS_PER_BIT) @(posedge clk);
      repeat (CLKS_PER_BIT) @(posedge clk);
    end
  endtask

  task automatic wait_for_rx_valid;
    integer timeout_cycles;
    begin
      timeout_cycles = 0;
      while ((dut.uart_rx_valid_q !== 1'b1) && (timeout_cycles < (CLKS_PER_BIT * 32))) begin
        @(posedge clk);
        timeout_cycles = timeout_cycles + 1;
      end
      if (dut.uart_rx_valid_q !== 1'b1) begin
        fail("Timed out waiting for RX data");
      end
    end
  endtask

  task automatic wait_for_tx_busy;
    integer timeout_cycles;
    begin
      timeout_cycles = 0;
      while ((dut.uart_tx_busy !== 1'b1) && (timeout_cycles < (CLKS_PER_BIT * 4))) begin
        @(posedge clk);
        timeout_cycles = timeout_cycles + 1;
      end
      if (dut.uart_tx_busy !== 1'b1) begin
        fail("Timed out waiting for TX busy");
      end
    end
  endtask

  task automatic expect_uart_tx_byte;
    input [7:0] expected;
    reg [7:0] observed;
    integer i;
    begin
      observed = 8'h00;
      while (uart_tx_o !== 1'b0) begin
        @(posedge clk);
      end
      repeat (CLKS_PER_BIT + HALF_CLKS) @(posedge clk);
      for (i = 0; i < 8; i = i + 1) begin
        observed[i] = uart_tx_o;
        repeat (CLKS_PER_BIT) @(posedge clk);
      end
      if (uart_tx_o !== 1'b1) begin
        fail("UART TX stop bit was not high");
      end
      if (observed !== expected) begin
        $display("[TB] FAIL: UART TX byte mismatch. expected=0x%02x observed=0x%02x",
                 expected, observed);
        $finish;
      end
      repeat (CLKS_PER_BIT) @(posedge clk);
    end
  endtask

  initial begin
    clk           = 1'b0;
    rst_n         = 1'b0;
    uart_rx_i     = 1'b1;
    l2_req_ready  = 1'b1;
    l2_rsp_valid  = 1'b0;
    l2_rsp_data   = 64'd0;
    l2_rsp_last   = 1'b0;
    l2_rsp_err    = 1'b0;
    d_l2_req_ready = 1'b1;
    d_l2_rsp_valid = 1'b0;
    d_l2_rsp_rdata = 64'd0;
    d_l2_rsp_last  = 1'b0;
    d_l2_rsp_err   = 1'b0;

    $display("[TB] uart_mmio_tb start");

    mmio_idle();
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (4) @(posedge clk);

    if (boot_done_o !== 1'b1 || init_calib_complete !== 1'b1) begin
      fail("USE_MIG=0 setup did not reach ready state");
    end

    mmio_read(UART_TX_STATUS_ADDR, mmio_rdata, mmio_err);
    if (mmio_err !== 1'b0 || mmio_rdata !== 32'h0000_0001) begin
      $display("[TB] FAIL: unexpected initial TX status rdata=0x%08x err=%0b",
               mmio_rdata, mmio_err);
      $finish;
    end

    mmio_write(UART_TX_DATA_ADDR, 32'h0000_00A5, 4'b0001);
    wait_for_tx_busy();
    mmio_read(UART_TX_STATUS_ADDR, mmio_rdata, mmio_err);
    if (mmio_err !== 1'b0 || mmio_rdata !== 32'h0000_0000) begin
      $display("[TB] FAIL: TX status while busy mismatch rdata=0x%08x err=%0b",
               mmio_rdata, mmio_err);
      $finish;
    end
    expect_uart_tx_byte(8'hA5);
    mmio_read(UART_TX_STATUS_ADDR, mmio_rdata, mmio_err);
    if (mmio_err !== 1'b0 || mmio_rdata !== 32'h0000_0001) begin
      $display("[TB] FAIL: TX status after byte mismatch rdata=0x%08x err=%0b",
               mmio_rdata, mmio_err);
      $finish;
    end

    mmio_read(UART_RX_STATUS_ADDR, mmio_rdata, mmio_err);
    if (mmio_err !== 1'b0 || mmio_rdata !== 32'h0000_0000) begin
      $display("[TB] FAIL: initial RX status mismatch rdata=0x%08x err=%0b",
               mmio_rdata, mmio_err);
      $finish;
    end

    send_uart_byte(8'h33);
    wait_for_rx_valid();
    mmio_read(UART_RX_STATUS_ADDR, mmio_rdata, mmio_err);
    if (mmio_err !== 1'b0 || mmio_rdata !== 32'h0000_0001) begin
      $display("[TB] FAIL: RX status after first byte mismatch rdata=0x%08x err=%0b",
               mmio_rdata, mmio_err);
      $finish;
    end
    mmio_read(UART_RX_DATA_ADDR, mmio_rdata, mmio_err);
    if (mmio_err !== 1'b0 || mmio_rdata[7:0] !== 8'h33) begin
      $display("[TB] FAIL: RX data mismatch rdata=0x%08x err=%0b",
               mmio_rdata, mmio_err);
      $finish;
    end
    mmio_read(UART_RX_STATUS_ADDR, mmio_rdata, mmio_err);
    if (mmio_err !== 1'b0 || mmio_rdata !== 32'h0000_0000) begin
      $display("[TB] FAIL: RX status after pop mismatch rdata=0x%08x err=%0b",
               mmio_rdata, mmio_err);
      $finish;
    end

    send_uart_byte(8'h44);
    wait_for_rx_valid();
    send_uart_byte(8'h55);
    repeat (CLKS_PER_BIT * 3) @(posedge clk);
    if (dut.uart_rx_overrun_q !== 1'b1) begin
      fail("RX overrun was not asserted");
    end

    mmio_read(UART_RX_STATUS_ADDR, mmio_rdata, mmio_err);
    if (mmio_err !== 1'b0 || mmio_rdata !== 32'h0000_0003) begin
      $display("[TB] FAIL: RX status overrun mismatch rdata=0x%08x err=%0b",
               mmio_rdata, mmio_err);
      $finish;
    end
    mmio_read(UART_RX_STATUS_ADDR, mmio_rdata, mmio_err);
    if (mmio_err !== 1'b0 || mmio_rdata !== 32'h0000_0001) begin
      $display("[TB] FAIL: RX status clear-overrun mismatch rdata=0x%08x err=%0b",
               mmio_rdata, mmio_err);
      $finish;
    end
    mmio_read(UART_RX_DATA_ADDR, mmio_rdata, mmio_err);
    if (mmio_err !== 1'b0 || mmio_rdata[7:0] !== 8'h44) begin
      $display("[TB] FAIL: RX buffered byte mismatch rdata=0x%08x err=%0b",
               mmio_rdata, mmio_err);
      $finish;
    end
    mmio_read(UART_RX_STATUS_ADDR, mmio_rdata, mmio_err);
    if (mmio_err !== 1'b0 || mmio_rdata !== 32'h0000_0000) begin
      $display("[TB] FAIL: RX status after overrun pop mismatch rdata=0x%08x err=%0b",
               mmio_rdata, mmio_err);
      $finish;
    end

    mmio_read(UART_BAD_ADDR, mmio_rdata, mmio_err);
    if (mmio_err !== 1'b1) begin
      fail("Invalid MMIO read did not report an error");
    end

    $display("[TB] PASS: UART MMIO TX/RX checks completed");
    $finish;
  end
endmodule
