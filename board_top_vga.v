// board_top.v
// Final top-level wrapper for FPGA board integration.
// Exposes only board-facing IO (clocks, reset, DDR2, UART, status).

module board_top_vga #(
  parameter integer ADDR_WIDTH    = 32,
  parameter integer L2_DATA_W     = 64,
  parameter integer USE_MIG       = 1,
  parameter integer UART_BOOT_EN  = 1,
  parameter integer UART_BAUD     = 115_200,
  // In USE_MIG=1 path, UART logic runs on MIG ui_clk.
  // Board bring-up shows the active UART receiver locks at MUL2 when this is
  // set to 100 MHz, which indicates the effective ui_clk is 50 MHz here.
  parameter integer UART_CLK_HZ   = 50_000_000,
  parameter [31:0]  UART_BOOT_BASE= 32'h8000_0000,
  parameter [31:0]  RESET_PC      = 32'h8000_0000
) (
  input                   rst_n,
  input                   launcher_btn_i,
  input                   uart_rx_i,
  output                  uart_tx_o,

  // DDR2 MIG interface
  inout  [15:0]           ddr2_dq,
  inout  [1:0]            ddr2_dqs_n,
  inout  [1:0]            ddr2_dqs_p,
  output [12:0]           ddr2_addr,
  output [2:0]            ddr2_ba,
  output                  ddr2_ras_n,
  output                  ddr2_cas_n,
  output                  ddr2_we_n,
  output [0:0]            ddr2_ck_p,
  output [0:0]            ddr2_ck_n,
  output [0:0]            ddr2_cke,
  output [0:0]            ddr2_cs_n,
  output [1:0]            ddr2_dm,
  output [0:0]            ddr2_odt,
  input                   sys_clk_i,

  // VGA outputs
  output                  vga_hsync_o,
  output                  vga_vsync_o,
  output [3:0]            vga_red_o,
  output [3:0]            vga_green_o,
  output [3:0]            vga_blue_o,

  // Status outputs
  output [14:0]           status_o,
  output                  ifetch_err_o
);

  // Unused external L2 ports (internal only when USE_MIG=1)
  wire                  l2_req_valid;
  wire                  l2_req_ready_tie = 1'b0;
  wire [ADDR_WIDTH-1:0] l2_req_addr;
  wire [1:0]            l2_req_cmd;
  wire [2:0]            l2_req_size;
  wire [7:0]            l2_req_len;

  wire                  l2_rsp_valid_tie = 1'b0;
  wire [L2_DATA_W-1:0]  l2_rsp_data_tie  = {L2_DATA_W{1'b0}};
  wire                  l2_rsp_last_tie  = 1'b0;
  wire                  l2_rsp_err_tie   = 1'b0;
  wire                  l2_rsp_ready;

  wire                  d_l2_req_valid;
  wire                  d_l2_req_ready_tie = 1'b0;
  wire [ADDR_WIDTH-1:0] d_l2_req_addr;
  wire [1:0]            d_l2_req_cmd;
  wire [2:0]            d_l2_req_size;
  wire [7:0]            d_l2_req_len;
  wire [L2_DATA_W-1:0]  d_l2_req_wdata;
  wire [(L2_DATA_W/8)-1:0] d_l2_req_wstrb;

  wire                  d_l2_rsp_valid_tie = 1'b0;
  wire [L2_DATA_W-1:0]  d_l2_rsp_rdata_tie = {L2_DATA_W{1'b0}};
  wire                  d_l2_rsp_last_tie  = 1'b0;
  wire                  d_l2_rsp_err_tie   = 1'b0;
  wire                  d_l2_rsp_ready;

  // Debug outputs
  wire                  wb_we;
  wire [4:0]            wb_rd;
  wire [31:0]           wb_wdata;
  wire                  ifetch_err_core;
  wire                  init_calib_complete;
  wire                  boot_done;
  wire                  boot_edge_seen;
  wire                  boot_ui_edge_seen;
  wire                  boot_ui_edge_active;
  wire                  boot_boot_edge_seen;
  wire                  boot_rx_seen;
  wire                  boot_sync_seen;
  wire                  boot_rst_released;
  wire                  boot_ui_reset_released;
  wire                  boot_ui_clk_seen;
  wire                  boot_ui_clk_blink;
  wire [2:0]            boot_state;
  wire [3:0]            boot_rx_sel;
  wire                  core_running;
  wire                  core_pc_seen;
  wire                  cpu_uart_mmio_seen;
  wire                  cpu_uart_tx_fire_seen;
  wire                  cpu_uart_tx_busy_seen;
  wire                  cpu_dmem_req_seen;
  wire                  cpu_dmem_store_seen;
  wire                  cpu_dmem_rsp_seen;
  wire                  cpu_mem_stall_seen;
  wire                  cpu_wb_seen;
  wire                  boot_word0_ok;
  wire                  boot_word1_ok;
  wire                  boot_word2_ok;
  wire                  boot_word3_ok;
  wire                  boot_header_ok;
  wire                  boot_verify0_ok;
  wire                  boot_verify1_ok;
  wire                  boot_verify2_ok;
  wire                  boot_verify0_w0_ok;
  wire                  boot_verify0_w1_ok;
  wire                  boot_verify0_w2_ok;
  wire                  boot_verify0_w3_ok;
  wire                  boot_verify0_wordrev_ok;
  wire                  boot_verify0_byterev32_ok;
  wire                  boot_verify0_byterev128_ok;
  wire                  boot_verify0_memtest0_ok;
  wire                  boot_verify_req_seen;
  wire                  boot_verify_rsp_seen;
  wire                  boot_memtest_pass;
  wire                  boot_memtest_done;
  wire                  boot_memtest_rd_seen;
  wire                  boot_memtest0_ok;
  wire                  boot_memtest1_ok;
  wire                  boot_memtest2_ok;
  wire                  boot_memtest3_ok;
  wire                  clk_wiz_locked;
  wire                  aux_clk_100;
  wire                  mig_ref_clk;
  wire                  rst_n_int;
  (* ASYNC_REG = "TRUE" *) reg uart_raw_ff1;
  (* ASYNC_REG = "TRUE" *) reg uart_raw_ff2;
  reg                   uart_raw_ff2_d;
  reg                   uart_raw_seen_sticky;
  reg  [26:0]           uart_raw_active_cnt;
  (* ASYNC_REG = "TRUE" *) reg uart_tx_ff1;
  (* ASYNC_REG = "TRUE" *) reg uart_tx_ff2;
  reg                   uart_tx_ff2_d;
  reg                   uart_tx_seen_sticky;
  reg  [26:0]           uart_tx_active_cnt;
  // Hold reset for a short window after clock wizard lock to provide
  // a deterministic reset release for MIG and core logic.
  localparam [23:0] RST_HOLD_CYCLES = 24'd2_000_000; // ~20ms @100MHz
  reg  [23:0]           rst_hold_cnt;
  reg                   rst_release;

  clock_bridge u_clock_if (
    .clk_in   (sys_clk_i),
    .rst      (~rst_n),
    .clk_sys_o(aux_clk_100),
    .clk_ref_o(mig_ref_clk),
    .locked_o (clk_wiz_locked)
  );

  always @(posedge sys_clk_i or negedge rst_n) begin
    if (!rst_n) begin
      rst_hold_cnt <= 24'd0;
      rst_release  <= 1'b0;
    end else if (!clk_wiz_locked) begin
      rst_hold_cnt <= 24'd0;
      rst_release  <= 1'b0;
    end else if (!rst_release) begin
      if (rst_hold_cnt == (RST_HOLD_CYCLES - 1'b1))
        rst_release <= 1'b1;
      else
        rst_hold_cnt <= rst_hold_cnt + 1'b1;
    end
  end

  assign rst_n_int = rst_n & clk_wiz_locked & rst_release;

  // Physical UART RX edge detector (board pin activity).
  always @(posedge aux_clk_100 or negedge rst_n_int) begin
    if (!rst_n_int) begin
      uart_raw_ff1   <= 1'b1;
      uart_raw_ff2   <= 1'b1;
      uart_raw_ff2_d <= 1'b1;
      uart_raw_seen_sticky <= 1'b0;
      uart_raw_active_cnt <= 24'd0;
    end else begin
      uart_raw_ff1   <= uart_rx_i;
      uart_raw_ff2   <= uart_raw_ff1;
      uart_raw_ff2_d <= uart_raw_ff2;
      if (uart_raw_ff2 ^ uart_raw_ff2_d) begin
        uart_raw_seen_sticky <= 1'b1;
        uart_raw_active_cnt <= 27'd100_000_000; // ~1s @100MHz
      end else if (uart_raw_active_cnt != 27'd0)
        uart_raw_active_cnt <= uart_raw_active_cnt - 1'b1;
    end
  end

  // Physical UART TX edge detector (FPGA pin activity back to USB-UART bridge).
  always @(posedge aux_clk_100 or negedge rst_n_int) begin
    if (!rst_n_int) begin
      uart_tx_ff1   <= 1'b1;
      uart_tx_ff2   <= 1'b1;
      uart_tx_ff2_d <= 1'b1;
      uart_tx_seen_sticky <= 1'b0;
      uart_tx_active_cnt <= 27'd0;
    end else begin
      uart_tx_ff1   <= uart_tx_o;
      uart_tx_ff2   <= uart_tx_ff1;
      uart_tx_ff2_d <= uart_tx_ff2;
      if (uart_tx_ff2 ^ uart_tx_ff2_d) begin
        uart_tx_seen_sticky <= 1'b1;
        uart_tx_active_cnt <= 27'd100_000_000; // ~1s @100MHz
      end else if (uart_tx_active_cnt != 27'd0) begin
        uart_tx_active_cnt <= uart_tx_active_cnt - 1'b1;
      end
    end
  end

  icache_pipeline_top #(
    .ADDR_WIDTH    (ADDR_WIDTH),
    .L2_DATA_W     (L2_DATA_W),
    .USE_MIG       (USE_MIG),
    .USE_VGA       (1),
    .UART_BOOT_EN  (UART_BOOT_EN),
    .UART_BAUD     (UART_BAUD),
    .UART_CLK_HZ   (UART_CLK_HZ),
    .BOOT_RELEASE_CYCLES(100_000),
    .UART_BOOT_BASE(UART_BOOT_BASE),
    .RESET_PC      (RESET_PC)
  ) u_core (
    .clk          (aux_clk_100),
    .rst_n        (rst_n_int),
    .launcher_reset_req_i (launcher_btn_i),
    .uart_rx_i    (uart_rx_i),
    .uart_tx_o    (uart_tx_o),

    .ddr2_dq      (ddr2_dq),
    .ddr2_dqs_n   (ddr2_dqs_n),
    .ddr2_dqs_p   (ddr2_dqs_p),
    .ddr2_addr    (ddr2_addr),
    .ddr2_ba      (ddr2_ba),
    .ddr2_ras_n   (ddr2_ras_n),
    .ddr2_cas_n   (ddr2_cas_n),
    .ddr2_we_n    (ddr2_we_n),
    .ddr2_ck_p    (ddr2_ck_p),
    .ddr2_ck_n    (ddr2_ck_n),
    .ddr2_cke     (ddr2_cke),
    .ddr2_cs_n    (ddr2_cs_n),
    .ddr2_dm      (ddr2_dm),
    .ddr2_odt     (ddr2_odt),
    .sys_clk_i    (aux_clk_100),
    .clk_ref_i    (mig_ref_clk),
    .init_calib_complete (init_calib_complete),

    .l2_req_valid (l2_req_valid),
    .l2_req_ready (l2_req_ready_tie),
    .l2_req_addr  (l2_req_addr),
    .l2_req_cmd   (l2_req_cmd),
    .l2_req_size  (l2_req_size),
    .l2_req_len   (l2_req_len),
    .l2_rsp_valid (l2_rsp_valid_tie),
    .l2_rsp_ready (l2_rsp_ready),
    .l2_rsp_data  (l2_rsp_data_tie),
    .l2_rsp_last  (l2_rsp_last_tie),
    .l2_rsp_err   (l2_rsp_err_tie),

    .d_l2_req_valid (d_l2_req_valid),
    .d_l2_req_ready (d_l2_req_ready_tie),
    .d_l2_req_addr  (d_l2_req_addr),
    .d_l2_req_cmd   (d_l2_req_cmd),
    .d_l2_req_size  (d_l2_req_size),
    .d_l2_req_len   (d_l2_req_len),
    .d_l2_req_wdata (d_l2_req_wdata),
    .d_l2_req_wstrb (d_l2_req_wstrb),
    .d_l2_rsp_valid (d_l2_rsp_valid_tie),
    .d_l2_rsp_ready (d_l2_rsp_ready),
    .d_l2_rsp_rdata (d_l2_rsp_rdata_tie),
    .d_l2_rsp_last  (d_l2_rsp_last_tie),
    .d_l2_rsp_err   (d_l2_rsp_err_tie),

    .wb_we_o      (wb_we),
    .wb_rd_o      (wb_rd),
    .wb_wdata_o   (wb_wdata),
    .ifetch_err_o (ifetch_err_core),
    .boot_done_o  (boot_done),
    .boot_edge_seen_o (boot_edge_seen),
    .boot_ui_edge_seen_o (boot_ui_edge_seen),
    .boot_ui_edge_active_o (boot_ui_edge_active),
    .boot_boot_edge_seen_o (boot_boot_edge_seen),
    .boot_rx_seen_o (boot_rx_seen),
    .boot_sync_seen_o (boot_sync_seen),
    .boot_rst_released_o (boot_rst_released),
    .boot_ui_reset_released_o (boot_ui_reset_released),
    .boot_ui_clk_seen_o (boot_ui_clk_seen),
    .boot_ui_clk_blink_o (boot_ui_clk_blink),
    .boot_state_o (boot_state),
    .boot_rx_sel_o (boot_rx_sel),
    .core_running_o (core_running),
    .core_pc_seen_o (core_pc_seen),
    .uart_mmio_seen_o (cpu_uart_mmio_seen),
    .uart_tx_fire_seen_o (cpu_uart_tx_fire_seen),
    .uart_tx_busy_seen_o (cpu_uart_tx_busy_seen),
    .dmem_req_seen_o (cpu_dmem_req_seen),
    .dmem_store_seen_o (cpu_dmem_store_seen),
    .dmem_rsp_seen_o (cpu_dmem_rsp_seen),
    .mem_stall_seen_o (cpu_mem_stall_seen),
    .wb_seen_o (cpu_wb_seen),
    .boot_word0_ok_o (boot_word0_ok),
    .boot_word1_ok_o (boot_word1_ok),
    .boot_word2_ok_o (boot_word2_ok),
    .boot_word3_ok_o (boot_word3_ok),
    .boot_header_ok_o (boot_header_ok),
    .boot_verify0_ok_o (boot_verify0_ok),
    .boot_verify1_ok_o (boot_verify1_ok),
    .boot_verify2_ok_o (boot_verify2_ok),
    .boot_verify0_w0_ok_o (boot_verify0_w0_ok),
    .boot_verify0_w1_ok_o (boot_verify0_w1_ok),
    .boot_verify0_w2_ok_o (boot_verify0_w2_ok),
    .boot_verify0_w3_ok_o (boot_verify0_w3_ok),
    .boot_verify0_wordrev_ok_o (boot_verify0_wordrev_ok),
    .boot_verify0_byterev32_ok_o (boot_verify0_byterev32_ok),
    .boot_verify0_byterev128_ok_o (boot_verify0_byterev128_ok),
    .boot_verify0_memtest0_ok_o (boot_verify0_memtest0_ok),
    .boot_verify_req_seen_o (boot_verify_req_seen),
    .boot_verify_rsp_seen_o (boot_verify_rsp_seen),
    .boot_memtest_pass_o (boot_memtest_pass),
    .boot_memtest_done_o (boot_memtest_done),
    .boot_memtest_rd_seen_o (boot_memtest_rd_seen),
    .boot_memtest0_ok_o (boot_memtest0_ok),
    .boot_memtest1_ok_o (boot_memtest1_ok),
    .boot_memtest2_ok_o (boot_memtest2_ok),
    .boot_memtest3_ok_o (boot_memtest3_ok),
    .vga_hsync_o     (vga_hsync_o),
    .vga_vsync_o     (vga_vsync_o),
    .vga_red_o       (vga_red_o),
    .vga_green_o     (vga_green_o),
    .vga_blue_o      (vga_blue_o)
  );

  // Status (diagnostic):
  // Before boot_done:
  //   [1] K15 = ui_clk-domain RX edge seen
  //   [2] N14 = sync seen
  //   [3] R18 = raw UART RX edge seen
  //   [4] V17 = first 8 bytes match crt0 header
  //   [6] U16 = rx_sel[2] once sync is seen, else clk_wiz_locked
  //   [7] V16 = rx_sel[3] once sync is seen, else rst_n_int
  //   [8] T15 = multi-address DDR self-test pass
  //   [10] T16 = first 32-bit payload word matches
  //   [11] V15 = second 32-bit payload word matches
  //   [12] V14 = third 32-bit payload word matches
  //   [13] V12 = first 16-byte verify readback matches
  //   [14] V11 = verify read response ever returned
  //   J13 = fourth 32-bit payload word matches once sync is seen, else memtest addr3 pass
  //   Before sync, T16/V15/V14/J13 show memtest addr0/1/2/3 pass.
  // After sync but before boot_done:
  //   [1] K15 = verify beat0 word0 matches expected word0
  //   [2] N14 = verify beat0 full 128-bit exact match
  //   [3] R18 = verify beat0 word1 matches expected word1
  //   [4] V17 = verify beat0 still equals memtest addr0 pattern
  //   [6] U16 = verify beat0 word2 matches expected word2
  //   [7] V16 = verify beat0 word3 matches expected word3
  //   [10] T16 = verify beat0 matches expected with 32-bit word order swapped
  //   [11] V15 = verify beat0 matches expected with bytes reversed inside each 32-bit word
  //   [12] V14 = verify beat0 matches fully byte-reversed expected data
  //   [13] V12 = verify read request issued
  //   [14] V11 = verify read response returned
  //   J13 = fourth 32-bit payload word matches expected
  // After boot_done:
  //   [1] K15 = core released from reset
  //   [2] N14 = CPU hit UART MMIO
  //   [3] R18 = CPU issued any data-memory request
  //   [4] V17 = CPU issued DDR store
  //   [8] T15 = any WB commit observed
  //   [10] T16 = verify beat0 readback ok
  //   [11] V15 = verify beat1 readback ok
  //   [12] V14 = verify beat2 readback ok
  //   [13] V12 = DDR/data response observed
  //   [14] V11 = mem_stall observed
  //   J13 = PC changed after boot
  wire runtime_diag_mode = boot_done;
  wire verify_diag_mode = boot_sync_seen && ~boot_done;
  assign status_o[0] = init_calib_complete;
  assign status_o[1] = runtime_diag_mode ? core_running
                                         : (verify_diag_mode ? boot_verify0_w0_ok :
                                            (boot_sync_seen ? boot_rx_sel[0] : boot_ui_edge_seen));
  assign status_o[2] = runtime_diag_mode ? cpu_uart_mmio_seen
                                         : (verify_diag_mode ? boot_verify0_ok : boot_sync_seen);
  assign status_o[3] = runtime_diag_mode ? cpu_dmem_req_seen
                                         : (verify_diag_mode ? boot_verify0_w1_ok :
                                            (boot_sync_seen ? boot_rx_sel[1] : uart_raw_seen_sticky));
  assign status_o[4] = runtime_diag_mode ? cpu_dmem_store_seen
                                         : (verify_diag_mode ? boot_verify0_memtest0_ok : boot_header_ok);
  assign status_o[5] = boot_done;
  assign status_o[6] = runtime_diag_mode ? clk_wiz_locked
                                         : (verify_diag_mode ? boot_verify0_w2_ok :
                                            (boot_sync_seen ? boot_rx_sel[2] : clk_wiz_locked));
  assign status_o[7] = runtime_diag_mode ? rst_n_int
                                         : (verify_diag_mode ? boot_verify0_w3_ok :
                                            (boot_sync_seen ? boot_rx_sel[3] : rst_n_int));
  assign status_o[8] = runtime_diag_mode ? cpu_wb_seen : boot_memtest_pass;
  assign status_o[9] = boot_ui_clk_blink;
  assign status_o[10] = runtime_diag_mode ? boot_word0_ok
                                          : (verify_diag_mode ? boot_verify0_wordrev_ok :
                                             (boot_sync_seen ? boot_word0_ok : boot_memtest0_ok));
  assign status_o[11] = runtime_diag_mode ? boot_word1_ok
                                          : (verify_diag_mode ? boot_verify0_byterev32_ok : boot_memtest1_ok);
  assign status_o[12] = runtime_diag_mode ? boot_word2_ok
                                          : (verify_diag_mode ? boot_verify0_byterev128_ok :
                                             (boot_sync_seen ? boot_word2_ok : boot_memtest2_ok));
  assign status_o[13] = runtime_diag_mode ? cpu_dmem_rsp_seen
                                          : (verify_diag_mode ? boot_verify_req_seen : boot_verify0_ok);
  assign status_o[14] = runtime_diag_mode ? cpu_mem_stall_seen
                                          : boot_verify_rsp_seen;
  assign ifetch_err_o = runtime_diag_mode ? core_pc_seen
                                          : (boot_sync_seen ? boot_word3_ok : boot_memtest3_ok);

endmodule

