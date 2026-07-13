`timescale 1ns/1ps
`ifndef PRODUCTION_BUILD
`ifdef SYNTHESIS
`ifndef FAST_SYNTH
`define FAST_SYNTH
`endif
`endif
`endif
// icache_pipeline_top.v
// Minimal 5-stage RV32I pipeline wired to i_cache via icache_top.
// Data memory is a tiny zero-wait-state RAM stub for basic loads/stores.
// Intended for verifying I$ + pipeline integration only.

module icache_pipeline_top #(
  parameter integer ADDR_WIDTH  = 32,
  parameter integer L2_DATA_W   = 64,
  parameter integer DMEM_WORDS  = 1024,
  parameter integer USE_MIG     = 0,
  parameter integer USE_VGA     = 0,
  parameter integer UART_BOOT_EN = 0,
  parameter integer UART_BAUD    = 115_200,
  parameter integer UART_CLK_HZ  = 100_000_000,
  parameter integer BOOT_RELEASE_CYCLES = 100_000,
  parameter [31:0]  UART_BOOT_BASE = 32'h8000_0000,
  parameter [31:0]  RESET_PC    = 32'h0000_0000
) (
  input                   clk,
  input                   rst_n,
  input                   launcher_reset_req_i,
  input                   uart_rx_i,
  output                  uart_tx_o,

  // DDR2 MIG interface (used when USE_MIG=1)
  inout  [15:0]            ddr2_dq,
  inout  [1:0]             ddr2_dqs_n,
  inout  [1:0]             ddr2_dqs_p,
  output [12:0]            ddr2_addr,
  output [2:0]             ddr2_ba,
  output                   ddr2_ras_n,
  output                   ddr2_cas_n,
  output                   ddr2_we_n,
  output [0:0]             ddr2_ck_p,
  output [0:0]             ddr2_ck_n,
  output [0:0]             ddr2_cke,
  output [0:0]             ddr2_cs_n,
  output [1:0]             ddr2_dm,
  output [0:0]             ddr2_odt,
  input                    sys_clk_i,
  input                    clk_ref_i,
  output                   init_calib_complete,

  // L2 interface (for I$ refill)
  output                  l2_req_valid,
  input                   l2_req_ready,
  output [ADDR_WIDTH-1:0] l2_req_addr,
  output [1:0]            l2_req_cmd,
  output [2:0]            l2_req_size,
  output [7:0]            l2_req_len,

  input                   l2_rsp_valid,
  output                  l2_rsp_ready,
  input  [L2_DATA_W-1:0]  l2_rsp_data,
  input                   l2_rsp_last,
  input                   l2_rsp_err,

  // D$ L2 interface (for data cache)
  output                  d_l2_req_valid,
  input                   d_l2_req_ready,
  output [ADDR_WIDTH-1:0] d_l2_req_addr,
  output [1:0]            d_l2_req_cmd,
  output [2:0]            d_l2_req_size,
  output [7:0]            d_l2_req_len,
  output [L2_DATA_W-1:0]  d_l2_req_wdata,
  output [(L2_DATA_W/8)-1:0] d_l2_req_wstrb,

  input                   d_l2_rsp_valid,
  output                  d_l2_rsp_ready,
  input  [L2_DATA_W-1:0]  d_l2_rsp_rdata,
  input                   d_l2_rsp_last,
  input                   d_l2_rsp_err,

  // Observability
  output                  wb_we_o,
  output [4:0]            wb_rd_o,
  output [31:0]           wb_wdata_o,
  output                  ifetch_err_o,
  output                  boot_done_o,
  output                  boot_edge_seen_o,
  output                  boot_ui_edge_seen_o,
  output                  boot_ui_edge_active_o,
  output                  boot_boot_edge_seen_o,
  output                  boot_rx_seen_o,
  output                  boot_sync_seen_o,
  output                  boot_rst_released_o,
  output                  boot_ui_reset_released_o,
  output                  boot_ui_clk_seen_o,
  output                  boot_ui_clk_blink_o,
  output [2:0]            boot_state_o,
  output [3:0]            boot_rx_sel_o,
  output                  core_running_o,
  output                  core_pc_seen_o,
  output                  uart_mmio_seen_o,
  output                  uart_tx_fire_seen_o,
  output                  uart_tx_busy_seen_o,
  output                  dmem_req_seen_o,
  output                  dmem_store_seen_o,
  output                  dmem_rsp_seen_o,
  output                  mem_stall_seen_o,
  output                  wb_seen_o,
  output                  boot_word0_ok_o,
  output                  boot_word1_ok_o,
  output                  boot_word2_ok_o,
  output                  boot_word3_ok_o,
  output                  boot_header_ok_o,
  output                  boot_verify0_ok_o,
  output                  boot_verify1_ok_o,
  output                  boot_verify2_ok_o,
  output                  boot_verify0_w0_ok_o,
  output                  boot_verify0_w1_ok_o,
  output                  boot_verify0_w2_ok_o,
  output                  boot_verify0_w3_ok_o,
  output                  boot_verify0_wordrev_ok_o,
  output                  boot_verify0_byterev32_ok_o,
  output                  boot_verify0_byterev128_ok_o,
  output                  boot_verify0_memtest0_ok_o,
  output                  boot_verify_req_seen_o,
  output                  boot_verify_rsp_seen_o,
  output                  boot_memtest_pass_o,
  output                  boot_memtest_done_o,
  output                  boot_memtest_rd_seen_o,
  output                  boot_memtest0_ok_o,
  output                  boot_memtest1_ok_o,
  output                  boot_memtest2_ok_o,
  output                  boot_memtest3_ok_o,
  output                  vga_hsync_o,
  output                  vga_vsync_o,
  output [3:0]            vga_red_o,
  output [3:0]            vga_green_o,
  output [3:0]            vga_blue_o
);

  // ---------------- Clock/Reset selection ----------------
  wire core_clk;
  wire core_rst_n;
  wire core_rst_n_base;
  wire core_rst;

  wire ui_clk;
  wire ui_clk_sync_rst;
  wire boot_done_int;
  wire boot_edge_seen_boot_int;
  wire boot_edge_seen_int;
  wire boot_rx_seen_int;
  wire boot_sync_seen_int;
  wire boot_rst_released_int;
  wire boot_ui_reset_released_w;
  wire [2:0] boot_state_int;
  localparam integer BOOT_RELEASE_W = (BOOT_RELEASE_CYCLES <= 1) ? 1 : $clog2(BOOT_RELEASE_CYCLES + 1);
  (* ASYNC_REG = "TRUE" *) reg ui_rx_ff1_q;
  (* ASYNC_REG = "TRUE" *) reg ui_rx_ff2_q;
  reg  ui_rx_ff2_d_q;
  reg  boot_ui_edge_seen_q;
  reg  boot_ui_clk_seen_q;
  reg [25:0] boot_ui_edge_active_cnt_q;
  reg [24:0] ui_clk_blink_cnt_q;
  reg  [31:0] if_pc_prev_q;
  reg         core_pc_seen_q;
  reg         uart_mmio_seen_q;
  reg         uart_tx_fire_seen_q;
  reg         uart_tx_busy_seen_q;
  reg         dmem_req_seen_q;
  reg         dmem_store_seen_q;
  reg         dmem_rsp_seen_q;
  reg         mem_stall_seen_q;
  reg         wb_seen_q;
  reg [BOOT_RELEASE_W-1:0] boot_release_cnt_q;
  reg         boot_release_ok_q;
  localparam integer LAUNCHER_BTN_DEBOUNCE_CYCLES = 50_000;
  localparam integer LAUNCHER_BTN_DEBOUNCE_W =
      (LAUNCHER_BTN_DEBOUNCE_CYCLES <= 1) ? 1 : $clog2(LAUNCHER_BTN_DEBOUNCE_CYCLES + 1);
  // Larger games such as Gomoku/Pacman/Chess can still have framebuffer/MMIO
  // traffic in flight when software requests a launcher return. Give that work
  // time to drain before asserting reset; otherwise the reset can land in the
  // middle of active video writes and leave the system visually hung.
  localparam integer LAUNCHER_RESET_ARM_CYCLES = 5_000_000;
  localparam integer LAUNCHER_RESET_ARM_W =
      (LAUNCHER_RESET_ARM_CYCLES <= 1) ? 1 : $clog2(LAUNCHER_RESET_ARM_CYCLES + 1);
  localparam integer LAUNCHER_RESET_CYCLES = 2_000_000;
  localparam integer LAUNCHER_RESET_W =
      (LAUNCHER_RESET_CYCLES <= 1) ? 1 : $clog2(LAUNCHER_RESET_CYCLES + 1);
  (* ASYNC_REG = "TRUE" *) reg launcher_reset_ff1_q;
  (* ASYNC_REG = "TRUE" *) reg launcher_reset_ff2_q;
  reg         launcher_reset_btn_q;
  reg         launcher_reset_pending_q;
  reg         launcher_reset_active_q;
  reg [LAUNCHER_BTN_DEBOUNCE_W-1:0] launcher_reset_db_cnt_q;
  reg [LAUNCHER_RESET_ARM_W-1:0] launcher_reset_arm_cnt_q;
  reg [LAUNCHER_RESET_W-1:0] launcher_reset_cnt_q;
  (* SHREG_EXTRACT = "NO" *) reg [1:0] core_reset_sync_q = 2'b00;
  wire        boot_word0_ok_int;
  wire        boot_word1_ok_int;
  wire        boot_word2_ok_int;
  wire        boot_word3_ok_int;
  wire        boot_header_ok_int;
  wire        boot_verify0_ok_int;
  wire        boot_verify1_ok_int;
  wire        boot_verify2_ok_int;
  wire        boot_verify0_w0_ok_int;
  wire        boot_verify0_w1_ok_int;
  wire        boot_verify0_w2_ok_int;
  wire        boot_verify0_w3_ok_int;
  wire        boot_verify0_wordrev_ok_int;
  wire        boot_verify0_byterev32_ok_int;
  wire        boot_verify0_byterev128_ok_int;
  wire        boot_verify0_memtest0_ok_int;
  wire        boot_verify_req_seen_int;
  wire        boot_verify_rsp_seen_int;
  wire [3:0]  boot_rx_sel_int;
  wire        boot_memtest_pass_int;
  wire        boot_memtest_done_int;
  wire        boot_memtest_rd_seen_int;
  wire        boot_memtest0_ok_int;
  wire        boot_memtest1_ok_int;
  wire        boot_memtest2_ok_int;
  wire        boot_memtest3_ok_int;
  wire        vga_hsync_w;
  wire        vga_vsync_w;
  wire [3:0]  vga_red_w;
  wire [3:0]  vga_green_w;
  wire [3:0]  vga_blue_w;

  // Assert/release the core reset on core_clk.  This keeps calibration and
  // launcher combinational logic away from thousands of asynchronous reset
  // pins and guarantees a clean two-cycle release.
  always @(posedge core_clk) begin
    if (!rst_n)
      core_reset_sync_q <= 2'b00;
    else if (!core_rst_n_base || launcher_reset_active_q)
      core_reset_sync_q <= 2'b00;
    else
      core_reset_sync_q <= {core_reset_sync_q[0], 1'b1};
  end

  assign core_rst_n = core_reset_sync_q[1];
  assign core_rst = ~core_rst_n;
  assign boot_edge_seen_int = boot_edge_seen_boot_int | boot_ui_edge_seen_q;
  assign boot_ui_reset_released_w = ~ui_clk_sync_rst & init_calib_complete;

  // UI-clock domain UART edge detector. This is independent from bootloader
  // FSM state and helps isolate clock/reset vs protocol issues on board.
  always @(posedge ui_clk or posedge ui_clk_sync_rst) begin
    if (ui_clk_sync_rst || !init_calib_complete) begin
      ui_rx_ff1_q <= 1'b1;
      ui_rx_ff2_q <= 1'b1;
      ui_rx_ff2_d_q <= 1'b1;
      boot_ui_edge_seen_q <= 1'b0;
      boot_ui_clk_seen_q <= 1'b0;
      boot_ui_edge_active_cnt_q <= 26'd0;
      ui_clk_blink_cnt_q <= 25'd0;
    end else begin
      ui_rx_ff1_q <= uart_rx_i;
      ui_rx_ff2_q <= ui_rx_ff1_q;
      ui_rx_ff2_d_q <= ui_rx_ff2_q;
      boot_ui_clk_seen_q <= 1'b1;
      ui_clk_blink_cnt_q <= ui_clk_blink_cnt_q + 1'b1;
      if (ui_rx_ff2_q ^ ui_rx_ff2_d_q) begin
        boot_ui_edge_seen_q <= 1'b1;
        boot_ui_edge_active_cnt_q <= 26'd50_000_000;
      end else if (boot_ui_edge_active_cnt_q != 26'd0) begin
        boot_ui_edge_active_cnt_q <= boot_ui_edge_active_cnt_q - 1'b1;
      end
    end
  end

  always @(posedge ui_clk or posedge ui_clk_sync_rst) begin
    if (ui_clk_sync_rst || !init_calib_complete) begin
      boot_release_cnt_q <= {BOOT_RELEASE_W{1'b0}};
      boot_release_ok_q  <= 1'b0;
    end else if (!boot_done_int) begin
      boot_release_cnt_q <= {BOOT_RELEASE_W{1'b0}};
      boot_release_ok_q  <= 1'b0;
    end else if (!boot_release_ok_q) begin
      if (BOOT_RELEASE_CYCLES <= 1) begin
        boot_release_ok_q <= 1'b1;
      end else if (boot_release_cnt_q == BOOT_RELEASE_CYCLES - 1) begin
        boot_release_ok_q <= 1'b1;
      end else begin
        boot_release_cnt_q <= boot_release_cnt_q + 1'b1;
      end
    end
  end

  // ---------------- Internal L2 wires (I$ / D$) ----------------
  wire                  i_l2_req_ready_int;
  wire                  i_l2_rsp_valid_int;
  wire [L2_DATA_W-1:0]   i_l2_rsp_data_int;
  wire                  i_l2_rsp_last_int;
  wire                  i_l2_rsp_err_int;

  wire                  d_l2_req_ready_int;
  wire                  d_l2_rsp_valid_int;
  wire [L2_DATA_W-1:0]   d_l2_rsp_rdata_int;
  wire                  d_l2_rsp_last_int;
  wire                  d_l2_rsp_err_int;

  // Uncached indicator for D$ (derived from cmd)
  wire d_l2_req_uncached = (d_l2_req_cmd == 2'b01) || (d_l2_req_cmd == 2'b10);

  // ---------------- MIG / L2 integration ----------------
  generate
    if (USE_MIG) begin : GEN_MIG
      // MIG app interface
      wire [26:0]  app_addr;
      wire [2:0]   app_cmd;
      wire         app_en;
      wire [127:0] app_wdf_data;
      wire         app_wdf_end;
      wire [15:0]  app_wdf_mask;
      wire         app_wdf_wren;
      wire [127:0] app_rd_data;
      wire         app_rd_data_end;
      wire         app_rd_data_valid;
      wire         app_rdy;
      wire         app_wdf_rdy;
      wire         app_sr_active;
      wire         app_ref_ack;
      wire         app_zq_ack;

      // L2 app interface
      wire [26:0]  app_addr_l2;
      wire [2:0]   app_cmd_l2;
      wire         app_en_l2;
      wire [127:0] app_wdf_data_l2;
      wire         app_wdf_end_l2;
      wire [15:0]  app_wdf_mask_l2;
      wire         app_wdf_wren_l2;

      // Bootloader app interface
      wire [26:0]  app_addr_boot;
      wire [2:0]   app_cmd_boot;
      wire         app_en_boot;
      wire [127:0] app_wdf_data_boot;
      wire         app_wdf_end_boot;
      wire [15:0]  app_wdf_mask_boot;
      wire         app_wdf_wren_boot;
      wire         boot_active_w;
      wire [26:0]  app_addr_memtest;
      wire [2:0]   app_cmd_memtest;
      wire         app_en_memtest;
      wire [127:0] app_wdf_data_memtest;
      wire         app_wdf_end_memtest;
      wire [15:0]  app_wdf_mask_memtest;
      wire         app_wdf_wren_memtest;
      wire         memtest_active_w;

      // MIG instance
      mig_7series_0 u_mig (
        .ddr2_dq (ddr2_dq),
        .ddr2_dqs_n (ddr2_dqs_n),
        .ddr2_dqs_p (ddr2_dqs_p),
        .ddr2_addr (ddr2_addr),
        .ddr2_ba (ddr2_ba),
        .ddr2_ras_n (ddr2_ras_n),
        .ddr2_cas_n (ddr2_cas_n),
        .ddr2_we_n (ddr2_we_n),
        .ddr2_ck_p (ddr2_ck_p),
        .ddr2_ck_n (ddr2_ck_n),
        .ddr2_cke (ddr2_cke),
        .ddr2_cs_n (ddr2_cs_n),
        .ddr2_dm (ddr2_dm),
        .ddr2_odt (ddr2_odt),
        .sys_clk_i (sys_clk_i),
        .clk_ref_i (clk_ref_i),
        .app_addr (app_addr),
        .app_cmd (app_cmd),
        .app_en (app_en),
        .app_wdf_data (app_wdf_data),
        .app_wdf_end (app_wdf_end),
        .app_wdf_mask (app_wdf_mask),
        .app_wdf_wren (app_wdf_wren),
        .app_rd_data (app_rd_data),
        .app_rd_data_end (app_rd_data_end),
        .app_rd_data_valid (app_rd_data_valid),
        .app_rdy (app_rdy),
        .app_wdf_rdy (app_wdf_rdy),
        .app_sr_req (1'b0),                 // app_sr_req
        .app_ref_req (1'b0),                 // app_ref_req
        .app_zq_req (1'b0),                 // app_zq_req
        .app_sr_active (app_sr_active),
        .app_ref_ack (app_ref_ack),
        .app_zq_ack (app_zq_ack),
        .ui_clk (ui_clk),
        .ui_clk_sync_rst (ui_clk_sync_rst),
        .init_calib_complete (init_calib_complete),
        .sys_rst (rst_n)                 // MIG sys_rst is active low in this IP config
      );

      // Core clock/reset from MIG UI
      assign core_clk      = ui_clk;
      assign core_rst_n_base = rst_n & ~ui_clk_sync_rst & init_calib_complete & boot_release_ok_q;

      // L2 + arbitration
      l2_cache_top u_l2 (
        .clk (core_clk),
        .rst (core_rst),
        .init_calib_complete (init_calib_complete),

        .i_req_valid(l2_req_valid),
        .i_req_ready(i_l2_req_ready_int),
        .i_req_cmd (l2_req_cmd),
        .i_req_addr (l2_req_addr),
        .i_req_size (l2_req_size),
        .i_req_len (l2_req_len),
        .i_req_wdata (64'd0),
        .i_req_wstrb (8'd0),
        .i_req_uncached (1'b0),

        .i_rsp_valid (i_l2_rsp_valid_int),
        .i_rsp_ready (l2_rsp_ready),
        .i_rsp_rdata (i_l2_rsp_data_int),
        .i_rsp_err (i_l2_rsp_err_int),
        .i_rsp_last (i_l2_rsp_last_int),

        .d_req_valid (d_l2_req_valid),
        .d_req_ready (d_l2_req_ready_int),
        .d_req_cmd (d_l2_req_cmd),
        .d_req_addr (d_l2_req_addr),
        .d_req_size (d_l2_req_size),
        .d_req_len (d_l2_req_len),
        .d_req_wdata (d_l2_req_wdata),
        .d_req_wstrb (d_l2_req_wstrb),
        .d_req_uncached (d_l2_req_uncached),

        .d_rsp_valid (d_l2_rsp_valid_int),
        .d_rsp_ready (d_l2_rsp_ready),
        .d_rsp_rdata (d_l2_rsp_rdata_int),
        .d_rsp_err (d_l2_rsp_err_int),
        .d_rsp_last (d_l2_rsp_last_int),
        .app_addr (app_addr_l2),
        .app_cmd (app_cmd_l2),
        .app_en (app_en_l2),
        .app_wdf_data (app_wdf_data_l2),
        .app_wdf_end (app_wdf_end_l2),
        .app_wdf_mask (app_wdf_mask_l2),
        .app_wdf_wren (app_wdf_wren_l2),
        .app_rd_data (app_rd_data),
        .app_rd_data_end (app_rd_data_end),
        .app_rd_data_valid (app_rd_data_valid),
        .app_rdy (app_rdy),
        .app_wdf_rdy (app_wdf_rdy)
      );

      ddr_app_memtest #(
        .TEST_BASE_ADDR (27'd0),
        .WAIT_CYCLES    (512)
      ) u_boot_memtest (
        .clk             (ui_clk),
        .start_i         (init_calib_complete),
        .app_addr        (app_addr_memtest),
        .app_cmd         (app_cmd_memtest),
        .app_en          (app_en_memtest),
        .app_wdf_data    (app_wdf_data_memtest),
        .app_wdf_end     (app_wdf_end_memtest),
        .app_wdf_mask    (app_wdf_mask_memtest),
        .app_wdf_wren    (app_wdf_wren_memtest),
        .app_rd_data     (app_rd_data),
        .app_rd_data_end (app_rd_data_end),
        .app_rd_data_valid (app_rd_data_valid),
        .app_rdy         (app_rdy),
        .app_wdf_rdy     (app_wdf_rdy),
        .done_o          (boot_memtest_done_int),
        .pass_o          (boot_memtest_pass_int),
        .rd_seen_o       (boot_memtest_rd_seen_int),
        .beat0_ok_o      (boot_memtest0_ok_int),
        .beat1_ok_o      (boot_memtest1_ok_int),
        .beat2_ok_o      (boot_memtest2_ok_int),
        .beat3_ok_o      (boot_memtest3_ok_int)
      );

      assign memtest_active_w = (UART_BOOT_EN != 0) && init_calib_complete && ~boot_memtest_done_int;

      // UART bootloader (optional)
      if (UART_BOOT_EN) begin : GEN_UART_BOOT
        uart_bootloader #(
          .CLK_HZ   (UART_CLK_HZ),
          .BAUD     (UART_BAUD),
          .DDR_BASE (32'h8000_0000),
          .BOOT_ADDR(UART_BOOT_BASE)
        ) u_boot (
          .clk               (ui_clk),
          .uart_rx_i         (uart_rx_i),
          .init_calib_complete (init_calib_complete & boot_memtest_done_int),
          .app_addr          (app_addr_boot),
          .app_cmd           (app_cmd_boot),
          .app_en            (app_en_boot),
          .app_wdf_data      (app_wdf_data_boot),
          .app_wdf_end       (app_wdf_end_boot),
          .app_wdf_mask      (app_wdf_mask_boot),
          .app_wdf_wren      (app_wdf_wren_boot),
          .app_rdy           (app_rdy),
          .app_wdf_rdy       (app_wdf_rdy),
          .app_rd_data       (app_rd_data),
          .app_rd_data_end   (app_rd_data_end),
          .app_rd_data_valid (app_rd_data_valid),
          .boot_done_o       (boot_done_int),
          .debug_edge_seen_o (boot_edge_seen_boot_int),
          .debug_rx_seen_o   (boot_rx_seen_int),
          .debug_sync_seen_o (boot_sync_seen_int),
          .debug_rst_released_o (boot_rst_released_int),
          .debug_state_o     (boot_state_int),
          .debug_rx_sel_o    (boot_rx_sel_int),
          .debug_word0_ok_o  (boot_word0_ok_int),
          .debug_word1_ok_o  (boot_word1_ok_int),
          .debug_word2_ok_o  (boot_word2_ok_int),
          .debug_word3_ok_o  (boot_word3_ok_int),
          .debug_header_ok_o (boot_header_ok_int),
          .debug_verify0_ok_o (boot_verify0_ok_int),
          .debug_verify1_ok_o (boot_verify1_ok_int),
          .debug_verify2_ok_o (boot_verify2_ok_int),
          .debug_verify0_w0_ok_o (boot_verify0_w0_ok_int),
          .debug_verify0_w1_ok_o (boot_verify0_w1_ok_int),
          .debug_verify0_w2_ok_o (boot_verify0_w2_ok_int),
          .debug_verify0_w3_ok_o (boot_verify0_w3_ok_int),
          .debug_verify0_wordrev_ok_o (boot_verify0_wordrev_ok_int),
          .debug_verify0_byterev32_ok_o (boot_verify0_byterev32_ok_int),
          .debug_verify0_byterev128_ok_o (boot_verify0_byterev128_ok_int),
          .debug_verify0_memtest0_ok_o (boot_verify0_memtest0_ok_int),
          .debug_verify_req_seen_o (boot_verify_req_seen_int),
          .debug_verify_rsp_seen_o (boot_verify_rsp_seen_int)
        );
        assign boot_active_w = ~boot_done_int;
      end else begin : GEN_NO_UART_BOOT
        assign app_addr_boot     = 27'd0;
        assign app_cmd_boot      = 3'd0;
        assign app_en_boot       = 1'b0;
        assign app_wdf_data_boot = 128'd0;
        assign app_wdf_end_boot  = 1'b0;
        assign app_wdf_mask_boot = 16'hFFFF;
        assign app_wdf_wren_boot = 1'b0;
                assign boot_active_w      = 1'b0;
        assign boot_done_int      = 1'b1;
        assign boot_edge_seen_boot_int = 1'b0;
        assign boot_rx_seen_int   = 1'b0;
        assign boot_sync_seen_int = 1'b0;
        assign boot_rst_released_int = 1'b1;
        assign boot_state_int     = 3'd0;
        assign boot_rx_sel_int    = 4'd0;
        assign boot_word0_ok_int  = 1'b0;
        assign boot_word1_ok_int  = 1'b0;
        assign boot_word2_ok_int  = 1'b0;
        assign boot_word3_ok_int  = 1'b0;
        assign boot_header_ok_int = 1'b0;
        assign boot_verify0_ok_int = 1'b0;
        assign boot_verify1_ok_int = 1'b0;
        assign boot_verify2_ok_int = 1'b0;
        assign boot_verify0_w0_ok_int = 1'b0;
        assign boot_verify0_w1_ok_int = 1'b0;
        assign boot_verify0_w2_ok_int = 1'b0;
        assign boot_verify0_w3_ok_int = 1'b0;
        assign boot_verify0_wordrev_ok_int = 1'b0;
        assign boot_verify0_byterev32_ok_int = 1'b0;
        assign boot_verify0_byterev128_ok_int = 1'b0;
        assign boot_verify0_memtest0_ok_int = 1'b0;
        assign boot_verify_req_seen_int = 1'b0;
        assign boot_verify_rsp_seen_int = 1'b0;
      end

      // MIG app mux: memtest first, then bootloader, then L2.
      assign app_addr     = memtest_active_w ? app_addr_memtest :
                            (boot_active_w ? app_addr_boot : app_addr_l2);
      assign app_cmd      = memtest_active_w ? app_cmd_memtest :
                            (boot_active_w ? app_cmd_boot : app_cmd_l2);
      assign app_en       = memtest_active_w ? app_en_memtest :
                            (boot_active_w ? app_en_boot : app_en_l2);
      assign app_wdf_data = memtest_active_w ? app_wdf_data_memtest :
                            (boot_active_w ? app_wdf_data_boot : app_wdf_data_l2);
      assign app_wdf_end  = memtest_active_w ? app_wdf_end_memtest :
                            (boot_active_w ? app_wdf_end_boot : app_wdf_end_l2);
      assign app_wdf_mask = memtest_active_w ? app_wdf_mask_memtest :
                            (boot_active_w ? app_wdf_mask_boot : app_wdf_mask_l2);
      assign app_wdf_wren = memtest_active_w ? app_wdf_wren_memtest :
                            (boot_active_w ? app_wdf_wren_boot : app_wdf_wren_l2);
    end else begin : GEN_NO_MIG
      assign init_calib_complete = 1'b1;
      assign ui_clk = clk;
      assign ui_clk_sync_rst = 1'b0;

      assign core_clk            = clk;
      assign core_rst_n_base     = rst_n;
      assign boot_done_int       = 1'b1;
      assign boot_edge_seen_boot_int = 1'b0;
      assign boot_rx_seen_int    = 1'b0;
      assign boot_sync_seen_int  = 1'b0;
      assign boot_rst_released_int = 1'b1;
      assign boot_state_int      = 3'd0;
      assign boot_rx_sel_int     = 4'd0;
      assign boot_word0_ok_int   = 1'b0;
      assign boot_word1_ok_int   = 1'b0;
      assign boot_word2_ok_int   = 1'b0;
      assign boot_word3_ok_int   = 1'b0;
      assign boot_header_ok_int  = 1'b0;
      assign boot_verify0_ok_int = 1'b0;
      assign boot_verify1_ok_int = 1'b0;
      assign boot_verify2_ok_int = 1'b0;
      assign boot_verify0_w0_ok_int = 1'b0;
      assign boot_verify0_w1_ok_int = 1'b0;
      assign boot_verify0_w2_ok_int = 1'b0;
      assign boot_verify0_w3_ok_int = 1'b0;
      assign boot_verify0_wordrev_ok_int = 1'b0;
      assign boot_verify0_byterev32_ok_int = 1'b0;
      assign boot_verify0_byterev128_ok_int = 1'b0;
      assign boot_verify0_memtest0_ok_int = 1'b0;
      assign boot_verify_req_seen_int = 1'b0;
      assign boot_verify_rsp_seen_int = 1'b0;
      assign boot_memtest_pass_int = 1'b1;
      assign boot_memtest_done_int = 1'b1;
      assign boot_memtest_rd_seen_int = 1'b0;
      assign boot_memtest0_ok_int = 1'b1;
      assign boot_memtest1_ok_int = 1'b1;
      assign boot_memtest2_ok_int = 1'b1;
      assign boot_memtest3_ok_int = 1'b1;

      assign i_l2_req_ready_int = l2_req_ready;
      assign i_l2_rsp_valid_int = l2_rsp_valid;
      assign i_l2_rsp_data_int  = l2_rsp_data;
      assign i_l2_rsp_last_int  = l2_rsp_last;
      assign i_l2_rsp_err_int   = l2_rsp_err;

      assign d_l2_req_ready_int = d_l2_req_ready;
      assign d_l2_rsp_valid_int = d_l2_rsp_valid;
      assign d_l2_rsp_rdata_int = d_l2_rsp_rdata;
      assign d_l2_rsp_last_int  = d_l2_rsp_last;
      assign d_l2_rsp_err_int   = d_l2_rsp_err;
    end
  endgenerate

  wire uart_mmio_launcher_reset_fire;

  always @(posedge core_clk or negedge core_rst_n_base) begin
    if (!core_rst_n_base) begin
      launcher_reset_ff1_q <= 1'b0;
      launcher_reset_ff2_q <= 1'b0;
      launcher_reset_btn_q <= 1'b0;
      launcher_reset_pending_q <= 1'b0;
      launcher_reset_active_q <= 1'b0;
      launcher_reset_db_cnt_q <= {LAUNCHER_BTN_DEBOUNCE_W{1'b0}};
      launcher_reset_arm_cnt_q <= {LAUNCHER_RESET_ARM_W{1'b0}};
      launcher_reset_cnt_q <= {LAUNCHER_RESET_W{1'b0}};
    end else begin
      launcher_reset_ff1_q <= launcher_reset_req_i;
      launcher_reset_ff2_q <= launcher_reset_ff1_q;

      if (launcher_reset_ff2_q == launcher_reset_btn_q) begin
        launcher_reset_db_cnt_q <= {LAUNCHER_BTN_DEBOUNCE_W{1'b0}};
      end else if (LAUNCHER_BTN_DEBOUNCE_CYCLES <= 1) begin
        launcher_reset_btn_q <= launcher_reset_ff2_q;
        launcher_reset_db_cnt_q <= {LAUNCHER_BTN_DEBOUNCE_W{1'b0}};
      end else if (launcher_reset_db_cnt_q == LAUNCHER_BTN_DEBOUNCE_CYCLES - 1) begin
        launcher_reset_btn_q <= launcher_reset_ff2_q;
        launcher_reset_db_cnt_q <= {LAUNCHER_BTN_DEBOUNCE_W{1'b0}};
      end else begin
        launcher_reset_db_cnt_q <= launcher_reset_db_cnt_q + 1'b1;
      end

      if (!boot_done_int) begin
        launcher_reset_pending_q <= 1'b0;
        launcher_reset_active_q <= 1'b0;
        launcher_reset_arm_cnt_q <= {LAUNCHER_RESET_ARM_W{1'b0}};
        launcher_reset_cnt_q <= {LAUNCHER_RESET_W{1'b0}};
      end else if (launcher_reset_active_q) begin
        if (LAUNCHER_RESET_CYCLES <= 1) begin
          launcher_reset_active_q <= 1'b0;
          launcher_reset_cnt_q <= {LAUNCHER_RESET_W{1'b0}};
        end else if (launcher_reset_cnt_q == LAUNCHER_RESET_CYCLES - 1) begin
          launcher_reset_active_q <= 1'b0;
          launcher_reset_cnt_q <= {LAUNCHER_RESET_W{1'b0}};
        end else begin
          launcher_reset_cnt_q <= launcher_reset_cnt_q + 1'b1;
        end
      end else if (launcher_reset_pending_q) begin
        if (LAUNCHER_RESET_ARM_CYCLES <= 1) begin
          launcher_reset_pending_q <= 1'b0;
          launcher_reset_active_q <= 1'b1;
          launcher_reset_arm_cnt_q <= {LAUNCHER_RESET_ARM_W{1'b0}};
          launcher_reset_cnt_q <= {LAUNCHER_RESET_W{1'b0}};
        end else if (launcher_reset_arm_cnt_q == LAUNCHER_RESET_ARM_CYCLES - 1) begin
          launcher_reset_pending_q <= 1'b0;
          launcher_reset_active_q <= 1'b1;
          launcher_reset_arm_cnt_q <= {LAUNCHER_RESET_ARM_W{1'b0}};
          launcher_reset_cnt_q <= {LAUNCHER_RESET_W{1'b0}};
        end else begin
          launcher_reset_arm_cnt_q <= launcher_reset_arm_cnt_q + 1'b1;
          launcher_reset_cnt_q <= {LAUNCHER_RESET_W{1'b0}};
        end
      end else if (uart_mmio_launcher_reset_fire) begin
        launcher_reset_pending_q <= 1'b1;
        launcher_reset_arm_cnt_q <= {LAUNCHER_RESET_ARM_W{1'b0}};
        launcher_reset_cnt_q <= {LAUNCHER_RESET_W{1'b0}};
      end else begin
        launcher_reset_pending_q <= 1'b0;
        launcher_reset_arm_cnt_q <= {LAUNCHER_RESET_ARM_W{1'b0}};
        launcher_reset_cnt_q <= {LAUNCHER_RESET_W{1'b0}};
      end
    end
  end

  assign boot_done_o = boot_done_int;
  assign boot_edge_seen_o = boot_edge_seen_int;
  assign boot_ui_edge_seen_o = boot_ui_edge_seen_q;
  assign boot_ui_edge_active_o = (boot_ui_edge_active_cnt_q != 26'd0);
  assign boot_boot_edge_seen_o = boot_edge_seen_boot_int;
  assign boot_rx_seen_o = boot_rx_seen_int;
  assign boot_sync_seen_o = boot_sync_seen_int;
  assign boot_rst_released_o = boot_rst_released_int;
  assign boot_ui_reset_released_o = boot_ui_reset_released_w;
  assign boot_ui_clk_seen_o = boot_ui_clk_seen_q;
  assign boot_ui_clk_blink_o = ui_clk_blink_cnt_q[23];
  assign boot_state_o = boot_state_int;
  assign boot_rx_sel_o = boot_rx_sel_int;
  assign core_running_o = core_rst_n;
  assign core_pc_seen_o = core_pc_seen_q;
  assign uart_mmio_seen_o = uart_mmio_seen_q;
  assign uart_tx_fire_seen_o = uart_tx_fire_seen_q;
  assign uart_tx_busy_seen_o = uart_tx_busy_seen_q;
  assign dmem_req_seen_o = dmem_req_seen_q;
  assign dmem_store_seen_o = dmem_store_seen_q;
  assign dmem_rsp_seen_o = dmem_rsp_seen_q;
  assign mem_stall_seen_o = mem_stall_seen_q;
  assign wb_seen_o = wb_seen_q;
  assign boot_word0_ok_o = boot_word0_ok_int;
  assign boot_word1_ok_o = boot_word1_ok_int;
  assign boot_word2_ok_o = boot_word2_ok_int;
  assign boot_word3_ok_o = boot_word3_ok_int;
  assign boot_header_ok_o = boot_header_ok_int;
  assign boot_verify0_ok_o = boot_verify0_ok_int;
  assign boot_verify1_ok_o = boot_verify1_ok_int;
  assign boot_verify2_ok_o = boot_verify2_ok_int;
  assign boot_verify0_w0_ok_o = boot_verify0_w0_ok_int;
  assign boot_verify0_w1_ok_o = boot_verify0_w1_ok_int;
  assign boot_verify0_w2_ok_o = boot_verify0_w2_ok_int;
  assign boot_verify0_w3_ok_o = boot_verify0_w3_ok_int;
  assign boot_verify0_wordrev_ok_o = boot_verify0_wordrev_ok_int;
  assign boot_verify0_byterev32_ok_o = boot_verify0_byterev32_ok_int;
  assign boot_verify0_byterev128_ok_o = boot_verify0_byterev128_ok_int;
  assign boot_verify0_memtest0_ok_o = boot_verify0_memtest0_ok_int;
  assign boot_verify_req_seen_o = boot_verify_req_seen_int;
  assign boot_verify_rsp_seen_o = boot_verify_rsp_seen_int;
  assign boot_memtest_pass_o = boot_memtest_pass_int;
  assign boot_memtest_done_o = boot_memtest_done_int;
  assign boot_memtest_rd_seen_o = boot_memtest_rd_seen_int;
  assign boot_memtest0_ok_o = boot_memtest0_ok_int;
  assign boot_memtest1_ok_o = boot_memtest1_ok_int;
  assign boot_memtest2_ok_o = boot_memtest2_ok_int;
  assign boot_memtest3_ok_o = boot_memtest3_ok_int;
  assign vga_hsync_o = vga_hsync_w;
  assign vga_vsync_o = vga_vsync_w;
  assign vga_red_o   = vga_red_w;
  assign vga_green_o = vga_green_w;
  assign vga_blue_o  = vga_blue_w;

  // ================= IF =================
  wire [31:0] if_pc;
  wire [31:0] ex_redirect_pc_raw;
  wire        redirect_valid;
  wire [31:0] redirect_pc;
  wire        fe_redirect_valid;
  wire [31:0] fe_redirect_pc;
  wire        stall_if, stall_id, stall_ex, stall_exmem;
  wire        flush_ifid, flush_idex;
  wire        ex_valid;

  pc #(
    .RESET_PC (RESET_PC)
  ) u_pc (
    .clk              (core_clk),
    .rst_n            (core_rst_n),
    .stall_i          (stall_if),
    .redirect_valid_i (fe_redirect_valid),
    .redirect_pc_i    (fe_redirect_pc),
    .pc_o             (if_pc)
  );

  // I$ fetch interface
  reg         if_pending;
  wire        fetch_req_valid;
  wire [31:0] fetch_req_addr  = if_pc;
  wire        fetch_req_ready;
  wire        fetch_req_kill  = fe_redirect_valid;
  wire        fetch_req_hs;

  wire        fetch_resp_raw_valid;
  wire        fetch_resp_raw_ready;
  wire [31:0] fetch_resp_raw_inst;
  wire [31:0] fetch_resp_raw_pc;
  wire        fetch_resp_raw_err;
  reg         fetch_resp_buf_valid_q;
  reg  [31:0] fetch_resp_buf_inst_q;
  reg  [31:0] fetch_resp_buf_pc_q;
  reg         fetch_resp_buf_err_q;
  wire        fetch_resp_valid;
  wire        fetch_resp_valid_pipe;
  wire        fetch_resp_valid_filt;
  wire        fetch_resp_if_ready = ~stall_id;
  wire [31:0] fetch_resp_inst;
  wire [31:0] fetch_resp_pc;
  wire        fetch_resp_err;
  wire        fetch_resp_buf_push;
  wire        fetch_resp_buf_pop;
  wire        fetch_resp_buf_blocked;
  reg         icache_flush_pending_q;
  wire        icache_flush_ack_w;
  wire        sys_flush_now;
  wire        ifetch_sync_candidate;
  wire        ifetch_sync_trap;
  reg  [31:0] last_if_resp_pc_q;
  reg         last_if_resp_v_q;
  reg         irq_pc_override_valid_q;
  reg  [31:0] irq_pc_override_q;
  wire        irq_quiesce_id;
  wire        stall_if_hdu, stall_id_hdu, stall_ex_hdu, stall_exmem_hdu;

`ifdef FAST_SIM
  localparam integer I_CACHE_BYTES_CFG = 8192; // fast simulation
  localparam integer I_CACHE_INDEX_BITS_CFG = 6;
`elsif FAST_SYNTH
  localparam integer I_CACHE_BYTES_CFG = 8192; // fast synthesis
  localparam integer I_CACHE_INDEX_BITS_CFG = 6;
`else
  localparam integer I_CACHE_BYTES_CFG = 65536; // production default (64KiB)
  localparam integer I_CACHE_INDEX_BITS_CFG = 9;
`endif
  localparam integer I_CACHE_TAG_BITS_CFG = ADDR_WIDTH - 6 - I_CACHE_INDEX_BITS_CFG;

  icache_top #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .L2_DATA_W  (L2_DATA_W),
    .CACHE_BYTES(I_CACHE_BYTES_CFG),
    .LINE_BYTES (64),
    .NUM_WAYS   (2),
    .OFFSET_BITS(6),
    .INDEX_BITS (I_CACHE_INDEX_BITS_CFG),
    .TAG_BITS   (I_CACHE_TAG_BITS_CFG)
  ) u_icache (
    .clk              (core_clk),
    .rst_n            (core_rst_n),
    .fetch_req_valid_i  (fetch_req_valid),
    .fetch_req_addr_i   (fetch_req_addr),
    .fetch_req_kill_i   (fetch_req_kill),
    .fetch_req_ready_o  (fetch_req_ready),
    .fetch_resp_valid_o (fetch_resp_raw_valid),
    .fetch_resp_ready_i (fetch_resp_raw_ready),
    .fetch_resp_inst_o  (fetch_resp_raw_inst),
    .fetch_resp_pc_o    (fetch_resp_raw_pc),
    .fetch_resp_err_o   (fetch_resp_raw_err),
    .ic_flush_req_i     (icache_flush_pending_q),
    .ic_flush_ack_o     (icache_flush_ack_w),
    .l2_req_valid       (l2_req_valid),
    .l2_req_ready       (i_l2_req_ready_int),
    .l2_req_addr        (l2_req_addr),
    .l2_req_cmd         (l2_req_cmd),
    .l2_req_size        (l2_req_size),
    .l2_req_len         (l2_req_len),
    .l2_rsp_valid       (i_l2_rsp_valid_int),
    .l2_rsp_ready       (l2_rsp_ready),
    .l2_rsp_data        (i_l2_rsp_data_int),
    .l2_rsp_last        (i_l2_rsp_last_int),
    .l2_rsp_err         (i_l2_rsp_err_int)
  );

  // Keep request valid independent from redirect. Redirect still blocks the
  // handshake through fetch_req_kill, but removing it from valid shortens the
  // critical control path that feeds the I$ stage-1 enable.
  assign fetch_resp_valid = fetch_resp_buf_valid_q;
  assign fetch_resp_inst  = fetch_resp_buf_inst_q;
  assign fetch_resp_pc    = fetch_resp_buf_pc_q;
  assign fetch_resp_err   = fetch_resp_buf_err_q;
  assign fetch_resp_raw_ready = ~fetch_resp_buf_valid_q;
  assign fetch_resp_buf_push = fetch_resp_raw_valid & fetch_resp_raw_ready;
  assign fetch_resp_buf_blocked = fetch_resp_buf_valid_q;

  // One-entry fetch response buffer.
  // This decouples the I$ response hold/ready network from decode stall logic so
  // the front-end does not synthesize into a zero-delay feedback loop.
  always @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      icache_flush_pending_q <= 1'b1;
      fetch_resp_buf_valid_q <= 1'b0;
      fetch_resp_buf_inst_q  <= 32'b0;
      fetch_resp_buf_pc_q    <= 32'b0;
      fetch_resp_buf_err_q   <= 1'b0;
    end else begin
      if (icache_flush_ack_w)
        icache_flush_pending_q <= 1'b0;

      if (fe_redirect_valid | sys_flush_now | icache_flush_pending_q) begin
        fetch_resp_buf_valid_q <= 1'b0;
        fetch_resp_buf_inst_q  <= 32'b0;
        fetch_resp_buf_pc_q    <= 32'b0;
        fetch_resp_buf_err_q   <= 1'b0;
      end else begin
        if (fetch_resp_buf_push) begin
          fetch_resp_buf_valid_q <= 1'b1;
          fetch_resp_buf_inst_q  <= fetch_resp_raw_inst;
          fetch_resp_buf_pc_q    <= fetch_resp_raw_pc;
          fetch_resp_buf_err_q   <= fetch_resp_raw_err;
        end else if (fetch_resp_buf_pop) begin
          fetch_resp_buf_valid_q <= 1'b0;
        end
      end
    end
  end

  wire req_blocked = fetch_req_valid & ~fetch_req_ready & ~fetch_req_kill;
  wire resp_blocked = fetch_resp_raw_valid & ~fetch_resp_raw_ready;
  // On redirect cycle, suppress same-cycle fetch response into IF/ID.
  // This prevents stale wrong-path instruction from entering decode.
  assign ifetch_sync_candidate = fetch_resp_valid_filt & fetch_resp_if_ready & fetch_resp_err;
  assign fetch_resp_valid_pipe = fetch_resp_valid & ~fe_redirect_valid;
  // Error should not be masked by redirect; expose any accepted fetch error event.
  assign ifetch_err_o = fetch_resp_valid & fetch_resp_err;

  wire [6:0] fetch_opcode = fetch_resp_inst[6:0];
  wire fetch_is_ctrl = (fetch_opcode == 7'b1100011) || // BRANCH
                       (fetch_opcode == 7'b1101111) || // JAL
                       (fetch_opcode == 7'b1100111);   // JALR
  wire fetch_resp_dup_nonctrl = 1'b0;
  assign fetch_resp_valid_filt = fetch_resp_valid_pipe && !fetch_resp_dup_nonctrl &&
                                 !irq_quiesce_id;
  assign fetch_resp_buf_pop = fetch_resp_valid_filt & fetch_resp_if_ready;

  // Redirect cancels the request via fetch_req_kill. Do not fold redirect into
  // fetch_req_valid itself; that duplicate gating created the worst setup path
  // into the I$ request accept/CE logic.
  assign fetch_req_valid = ~if_pending & ~stall_if_hdu & ~fetch_resp_buf_valid_q &
                           ~icache_flush_pending_q;
  assign fetch_req_hs = fetch_req_valid & fetch_req_ready & ~fetch_req_kill;

  always @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      if_pending <= 1'b0;
    end else begin
      if (fe_redirect_valid | sys_flush_now | icache_flush_pending_q) begin
        if_pending <= 1'b0;
      end else if (fetch_resp_buf_push) begin
        // Response wins: same-cycle request+response means no outstanding left.
        if_pending <= 1'b0;
      end else if (fetch_req_hs) begin
        if_pending <= 1'b1;
      end
    end
  end

  always @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      last_if_resp_pc_q <= 32'b0;
      last_if_resp_v_q  <= 1'b0;
      irq_pc_override_valid_q <= 1'b0;
      irq_pc_override_q       <= 32'b0;
    end else if (fe_redirect_valid | sys_flush_now) begin
      last_if_resp_pc_q <= 32'b0;
      last_if_resp_v_q  <= 1'b0;

      if (fe_redirect_valid) begin
        irq_pc_override_valid_q <= 1'b1;
        irq_pc_override_q       <= fe_redirect_pc;
      end else begin
        irq_pc_override_valid_q <= 1'b0;
        irq_pc_override_q       <= 32'b0;
      end
    end else if (fetch_resp_buf_pop) begin
      last_if_resp_pc_q <= fetch_resp_pc;
      last_if_resp_v_q  <= 1'b1;

      if (irq_pc_override_valid_q && (fetch_resp_pc == irq_pc_override_q)) begin
        irq_pc_override_valid_q <= 1'b0;
        irq_pc_override_q       <= 32'b0;
      end
    end
  end

  // IF/ID
  wire [31:0] id_pc;
  wire [31:0] id_instr;
  wire        id_valid;

  if_id_reg u_if_id (
    .clk              (core_clk),
    .rst_n            (core_rst_n),
    .stall_i     (stall_id),
    .flush_i     (flush_ifid),
    .if_pc_i     (fetch_resp_pc),
    .if_instr_i  (fetch_resp_inst),
    .if_valid_i  (fetch_resp_valid_filt),
    .id_pc_o     (id_pc),
    .id_instr_o  (id_instr),
    .id_valid_o  (id_valid)
  );

  // ================= ID =================
  wire [31:0] id_rs1_val, id_rs2_val, id_imm;
  wire [4:0]  id_rs1, id_rs2, id_rd;
  wire [3:0]  id_alu_op;
  wire        id_alu_src_imm, id_branch, id_jal, id_jalr;
  wire        id_mem_read, id_mem_write, id_reg_write;
  wire [1:0]  id_wb_sel;
  wire [2:0]  id_br_funct3;
  wire        id_ready;
  wire        id_shift_right, id_shift_arith, id_is_auipc, id_is_lui;
  wire [2:0]  id_mem_funct3;
  wire        id_csr_en;
  wire [2:0]  id_csr_cmd;
  wire [11:0] id_csr_addr;
  wire        id_ecall;
  wire        id_ebreak;
  wire        id_mret;
  wire        id_illegal;
  wire [1:0]  csr_current_priv_w;

  // WB writeback signals (from WB stage to regfile)
  wire        rf_we;
  wire [4:0]  rf_waddr;
  wire [31:0] rf_wdata;

  id_stage u_id (
    .clk              (core_clk),
    .rst_n            (core_rst_n),
    .id_pc_i          (id_pc),
    .id_instr_i       (id_instr),
    .id_valid_i       (id_valid),
    .id_stall_i       (stall_id),
    .current_priv_i   (csr_current_priv_w),
    .wb_we_i          (rf_we),
    .wb_rd_i          (rf_waddr),
    .wb_wd_i          (rf_wdata),
    .rs1_val_o        (id_rs1_val),
    .rs2_val_o        (id_rs2_val),
    .imm_o            (id_imm),
    .rs1_o            (id_rs1),
    .rs2_o            (id_rs2),
    .rd_o             (id_rd),
    .alu_op_o         (id_alu_op),
    .alu_src_imm_o    (id_alu_src_imm),
    .branch_o         (id_branch),
    .jal_o            (id_jal),
    .jalr_o           (id_jalr),
    .mem_read_o       (id_mem_read),
    .mem_write_o      (id_mem_write),
    .wb_sel_o         (id_wb_sel),
    .reg_write_o      (id_reg_write),
    .br_funct3_o      (id_br_funct3),
    .pc_o             (),// pc ?��?�可??�可?��
    .id_ready_o       (id_ready),
    .id_shift_right_o (id_shift_right),
    .id_shift_arith_o (id_shift_arith),
    .id_is_auipc_o    (id_is_auipc),
    .id_is_lui_o      (id_is_lui),
    .id_mem_funct3_o  (id_mem_funct3),
    .id_csr_en_o      (id_csr_en),
    .id_csr_cmd_o     (id_csr_cmd),
    .id_csr_addr_o    (id_csr_addr),
    .id_ecall_o       (id_ecall),
    .id_ebreak_o      (id_ebreak),
    .id_mret_o        (id_mret),
    .id_illegal_o     (id_illegal)
  );

  // ID-stage control prediction:
  // - Conditional branches use PHT direction.
  // - JAL is always predicted taken.
  // - JALR is resolved in EX (rs1 may require forwarding).
  wire id_is_ctrl = id_branch | id_jal | id_jalr;
  wire [31:0] id_ctrl_target = id_jalr ?
                               ((id_rs1_val + id_imm) & 32'hFFFF_FFFE) :
                               (id_pc + id_imm);

  // ================= ID/EX =================
  wire [31:0] ex_pc, ex_rs1_val, ex_rs2_val, ex_imm;
  wire [4:0]  ex_rs1, ex_rs2, ex_rd;
  wire [2:0]  ex_br_funct3;
  wire [3:0]  ex_alu_op;
  wire        ex_alu_src_imm, ex_branch, ex_jal, ex_jalr;
  wire        ex_mem_read, ex_mem_write, ex_reg_write;
  wire [1:0]  ex_wb_sel;
  wire        ex_shift_right, ex_shift_arith, ex_is_auipc, ex_is_lui;
  wire [2:0]  ex_mem_funct3;
  wire        ex_csr_en;
  wire [2:0]  ex_csr_cmd;
  wire [11:0] ex_csr_addr;
  wire        ex_ecall;
  wire        ex_ebreak;
  wire        ex_mret;
  wire        ex_illegal;
  wire        ex_pred_taken;
  wire [31:0] ex_pred_target;
  wire        ex_br_taken;
  wire        bp_pred_taken;
  wire        bp_update_valid = ex_valid & ex_branch & ~stall_ex;
  wire        id_pred_taken = id_valid & id_is_ctrl &
                              (id_jal | (id_branch & bp_pred_taken));
  wire        id_pred_redirect_valid = id_pred_taken & ~stall_id;

  branch_predictor #(
    .PHT_BITS (8)
  ) u_bp (
    .clk            (core_clk),
    .rst_n          (core_rst_n),
    .pc_lookup_i    (id_pc),
    .pred_taken_o   (bp_pred_taken),
    .update_valid_i (bp_update_valid),
    .pc_update_i    (ex_pc),
    .actual_taken_i (ex_br_taken)
  );

  id_ex_reg u_id_ex (
    .clk              (core_clk),
    .rst_n            (core_rst_n),
    .stall_i          (stall_ex),
    .flush_i          (flush_idex),
    .redirect_valid_i (redirect_valid),
    .id_valid_i       (id_ready),
    .id_pc_i          (id_pc),
    .id_rs1_val_i     (id_rs1_val),
    .id_rs2_val_i     (id_rs2_val),
    .id_imm_i         (id_imm),
    .id_rs1_i         (id_rs1),
    .id_rs2_i         (id_rs2),
    .id_rd_i          (id_rd),
    .id_alu_op_i      (id_alu_op),
    .id_alu_src_imm_i (id_alu_src_imm),
    .id_branch_i      (id_branch),
    .id_jal_i         (id_jal),
    .id_jalr_i        (id_jalr),
    .id_mem_read_i    (id_mem_read),
    .id_mem_write_i   (id_mem_write),
    .id_wb_sel_i      (id_wb_sel),
    .id_reg_write_i   (id_reg_write),
    .id_br_funct3_i   (id_br_funct3),
    .id_shift_right_i (id_shift_right),
    .id_shift_arith_i (id_shift_arith),
    .id_is_auipc_i    (id_is_auipc),
    .id_is_lui_i      (id_is_lui),
    .id_mem_funct3_i  (id_mem_funct3),
    .id_csr_en_i      (id_csr_en),
    .id_csr_cmd_i     (id_csr_cmd),
    .id_csr_addr_i    (id_csr_addr),
    .id_ecall_i       (id_ecall),
    .id_ebreak_i      (id_ebreak),
    .id_mret_i        (id_mret),
    .id_illegal_i     (id_illegal),
    .id_pred_taken_i  (id_pred_taken),
    .id_pred_target_i (id_ctrl_target),
    .ex_mem_funct3_o  (ex_mem_funct3),
    .ex_shift_right_o (ex_shift_right),
    .ex_shift_arith_o (ex_shift_arith),
    .ex_is_auipc_o    (ex_is_auipc),
    .ex_is_lui_o      (ex_is_lui),
    .ex_csr_en_o      (ex_csr_en),
    .ex_csr_cmd_o     (ex_csr_cmd),
    .ex_csr_addr_o    (ex_csr_addr),
    .ex_ecall_o       (ex_ecall),
    .ex_ebreak_o      (ex_ebreak),
    .ex_mret_o        (ex_mret),
    .ex_illegal_o     (ex_illegal),
    .ex_pc_o          (ex_pc),
    .ex_rs1_val_o     (ex_rs1_val),
    .ex_rs2_val_o     (ex_rs2_val),
    .ex_imm_o         (ex_imm),
    .ex_rs1_o         (ex_rs1),
    .ex_rs2_o         (ex_rs2),
    .ex_rd_o          (ex_rd),
    .ex_alu_op_o      (ex_alu_op),
    .ex_alu_src_imm_o (ex_alu_src_imm),
    .ex_branch_o      (ex_branch),
    .ex_jal_o         (ex_jal),
    .ex_jalr_o        (ex_jalr),
    .ex_mem_read_o    (ex_mem_read),
    .ex_mem_write_o   (ex_mem_write),
    .ex_wb_sel_o      (ex_wb_sel),
    .ex_reg_write_o   (ex_reg_write),
    .ex_br_funct3_o   (ex_br_funct3),
    .ex_pred_taken_o  (ex_pred_taken),
    .ex_pred_target_o (ex_pred_target),
    .ex_valid_o       (ex_valid)
  );

  // ================= EX =================
  wire [31:0] ex_alu_result, ex_store_data, ex_pc4;

  // Forward dependencies from later stages for forwarding
  wire        mem_valid;
  wire        mem_mem_read, mem_mem_write;
  wire        mem_reg_write;
  wire [1:0]  mem_wb_sel;
  wire [4:0]  mem_rd;
  wire [31:0] mem_alu_result;
  wire [31:0] mem_pc4;
  wire [31:0] mem_load_rdata;
  wire        mem_load_valid;
  wire        mem_load_active;
  wire        mem_stall;
  wire        ex_stall_o;
  wire        wb_rd_wen;
  wire [4:0]  wb_rd;
  wire [31:0] wb_wdata;
  wire [31:0] csr_rdata_w;
  wire [31:0] csr_mtvec_w;
  wire [31:0] csr_mepc_w;
  wire [31:0] csr_mcause_w;
  wire [31:0] csr_mstatus_w;
  wire [31:0] csr_mie_w;
  wire [31:0] csr_mip_w;
  wire [31:0] csr_mscratch_w;
  wire        csr_global_mie_w;
  wire        csr_msie_en_w;
  wire        csr_mtie_en_w;
  wire        csr_meie_en_w;
  wire [31:0] irq_msip_rdata_w;
  wire [31:0] irq_meip_rdata_w;
  wire [31:0] irq_mtime_lo_w;
  wire [31:0] irq_mtime_hi_w;
  wire [31:0] irq_mtimecmp_lo_w;
  wire [31:0] irq_mtimecmp_hi_w;
  wire        irq_soft_pending_w;
  wire        irq_timer_pending_w;
  wire        irq_ext_pending_w;
  wire        irq_request_w;
  wire [31:0] irq_cause_w;
  wire        ex_insn_misaligned;
  wire        ex_load_misaligned;
  wire        ex_store_misaligned;
  wire        mem_sync_trap;
  wire [31:0] mem_trap_cause;
  wire [31:0] mem_trap_pc;
  wire        sync_trap_valid;
  wire [31:0] sync_trap_cause;
  wire [31:0] sync_trap_pc;
  wire [31:0] sync_trap_tval;
  wire        ex_sync_trap;
  wire        ex_mret_fire = ex_valid & ~stall_ex & ex_mret;
  wire [31:0] ex_trap_cause;
  wire [31:0] ex_trap_vector = {csr_mtvec_w[31:2], 2'b00};
  wire [31:0] ex_mret_vector = {csr_mepc_w[31:2], 2'b00};
  reg         ex_sys_redirect_valid_q;
  reg  [31:0] ex_sys_redirect_pc_q;
  reg         csr_trap_enter_q;
  reg         csr_trap_is_interrupt_q;
  reg  [31:0] csr_trap_pc_q;
  reg  [31:0] csr_trap_cause_q;
  reg  [31:0] csr_trap_tval_q;
  reg         csr_mret_exec_q;
  reg  [31:0] irq_arch_pc_q;
  reg         irq_mem_pc_suppress_q;
  wire        ex_sys_redirect_valid = ex_sys_redirect_valid_q;
  wire [31:0] ex_sys_redirect_pc = ex_sys_redirect_pc_q;
  wire        irq_frontend_hold;
  wire        irq_take_now;
  wire        irq_take_effective;
  wire [31:0] irq_trap_pc;
  reg  [1:0]  irq_redirect_settle_q;
  wire        csr_exec_write_en = ex_valid & ex_csr_en & ~stall_ex;
  wire        ex_irq_pc_commit = ex_valid & ~stall_ex & ~ex_insn_misaligned &
                                 (ex_jal | ex_jalr | ex_br_taken);
  wire        mem_irq_pc_commit = mem_valid & ~mem_sync_trap &
                                  ((mem_mem_read & mem_load_valid) |
                                   (~mem_mem_read & ~mem_stall));

  wire [31:0] ex_rs1_val_fwd, ex_rs2_val_fwd;
  forward_unit u_fwd (
    .ex_rs1_idx_i     (ex_rs1),
    .ex_rs2_idx_i     (ex_rs2),
    .ex_rs1_val_i     (ex_rs1_val),
    .ex_rs2_val_i     (ex_rs2_val),
    .mem_valid_i      (mem_valid),
    .mem_reg_write_i  (mem_reg_write),
    .mem_wb_sel_i     (mem_wb_sel),
    .mem_rd_i         (mem_rd),
    .mem_alu_result_i (mem_alu_result),
    .mem_pc4_i        (mem_pc4),
    .mem_load_valid_i (mem_load_valid),
    .mem_load_data_i  (mem_load_rdata),
    .wb_we_i          (wb_rd_wen),
    .wb_rd_i          (wb_rd),
    .wb_wdata_i       (wb_wdata),
    .ex_rs1_val_o     (ex_rs1_val_fwd),
    .ex_rs2_val_o     (ex_rs2_val_fwd)
  );

  ex_stage u_ex (
    .clk               (core_clk),
    .rst_n             (core_rst_n),
    .ex_valid_i        (ex_valid),
    .ex_pipe_hold_i    (mem_stall),
    .ex_pc_i           (ex_pc),
    .ex_rs1_val_i      (ex_rs1_val_fwd),
    .ex_rs2_val_i      (ex_rs2_val_fwd),
    .ex_imm_i          (ex_imm),
    .ex_alu_op_i       (ex_alu_op),
    .ex_alu_src_imm_i  (ex_alu_src_imm),
    .ex_branch_i       (ex_branch),
    .ex_jal_i          (ex_jal),
    .ex_jalr_i         (ex_jalr),
    .ex_br_funct3_i    (ex_br_funct3),
    .ex_shift_right_i  (ex_shift_right),
    .ex_shift_arith_i  (ex_shift_arith),
    .ex_is_auipc_i     (ex_is_auipc),
    .ex_is_lui_i       (ex_is_lui),
    .ex_csr_en_i       (ex_csr_en),
    .ex_csr_rdata_i    (csr_rdata_w),
    .ex_stall_o        (ex_stall_o),
    .ex_alu_result_o   (ex_alu_result),
    .ex_store_data_o   (ex_store_data),
    .ex_pc4_o          (ex_pc4),
    .ex_br_taken_o     (ex_br_taken),
    .ex_br_target_o    (),//??�已經在top??��?��?��?��?��?要�?�ex??��?�target??��?��?��??
    .redirect_valid_o  (),
    .redirect_pc_o     (ex_redirect_pc_raw)
  );

  misalign_check u_misalign (
    .is_ctrl_taken_i          (ex_valid & ~stall_ex & (ex_jal | ex_jalr | ex_br_taken)),
    .ctrl_target_i            (ex_redirect_pc_raw),
    .mem_read_i               (ex_valid & ~stall_ex & ex_mem_read),
    .mem_write_i              (ex_valid & ~stall_ex & ex_mem_write),
    .mem_funct3_i             (ex_mem_funct3),
    .mem_addr_i               (ex_alu_result),
    .insn_addr_misaligned_o   (ex_insn_misaligned),
    .load_addr_misaligned_o   (ex_load_misaligned),
    .store_addr_misaligned_o  (ex_store_misaligned)
  );

  assign ex_sync_trap = ex_valid & ~stall_ex &
                        (ex_ecall | ex_ebreak | ex_illegal |
                         ex_insn_misaligned | ex_load_misaligned | ex_store_misaligned);
  assign ex_trap_cause = ex_insn_misaligned ? 32'd0 :
                         ex_load_misaligned ? 32'd4 :
                         ex_store_misaligned ? 32'd6 :
                         ex_illegal ? 32'd2 :
                         (ex_ebreak ? 32'd3 :
                         (ex_ecall ? ((csr_current_priv_w == 2'b00) ? 32'd8 :
                                      ((csr_current_priv_w == 2'b01) ? 32'd9 : 32'd11))
                                   : 32'd11));
  assign ifetch_sync_trap = ifetch_sync_candidate &
                            ~(mem_sync_trap | ex_sync_trap | ex_mret_fire | redirect_valid | id_pred_redirect_valid);
  assign sync_trap_valid = mem_sync_trap | ex_sync_trap | ifetch_sync_trap;
  assign sync_trap_cause = mem_sync_trap ? mem_trap_cause :
                           (ex_sync_trap ? ex_trap_cause : 32'd1);
  assign sync_trap_pc = mem_sync_trap ? mem_trap_pc :
                        (ex_sync_trap ? ex_pc : fetch_resp_pc);
  assign sync_trap_tval = mem_sync_trap ? mem_alu_result :
                          (ex_sync_trap ?
                            (ex_insn_misaligned ? ex_redirect_pc_raw :
                             ((ex_load_misaligned | ex_store_misaligned) ? ex_alu_result : 32'b0)) :
                            fetch_resp_pc);
  assign irq_take_effective = irq_take_now & ~sync_trap_valid & ~ex_mret_fire;
  assign sys_flush_now = sync_trap_valid | irq_take_effective | ex_mret_fire;

  always @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      ex_sys_redirect_valid_q <= 1'b0;
      ex_sys_redirect_pc_q    <= 32'b0;
      csr_trap_enter_q        <= 1'b0;
      csr_trap_is_interrupt_q <= 1'b0;
      csr_trap_pc_q           <= 32'b0;
      csr_trap_cause_q        <= 32'b0;
      csr_trap_tval_q         <= 32'b0;
      csr_mret_exec_q         <= 1'b0;
      irq_redirect_settle_q   <= 2'b00;
      irq_arch_pc_q           <= RESET_PC;
      irq_mem_pc_suppress_q   <= 1'b0;
    end else begin
      ex_sys_redirect_valid_q <= 1'b0;
      ex_sys_redirect_pc_q    <= 32'b0;
      csr_trap_enter_q        <= 1'b0;
      csr_trap_is_interrupt_q <= 1'b0;
      csr_trap_pc_q           <= 32'b0;
      csr_trap_cause_q        <= 32'b0;
      csr_trap_tval_q         <= 32'b0;
      csr_mret_exec_q         <= 1'b0;
      irq_mem_pc_suppress_q   <= ex_irq_pc_commit | ex_mret_fire;

      if (mem_irq_pc_commit && !irq_mem_pc_suppress_q) begin
        irq_arch_pc_q <= mem_pc4;
      end

      if (ex_irq_pc_commit) begin
        irq_arch_pc_q <= ex_redirect_pc_raw;
      end else if (ex_mret_fire) begin
        irq_arch_pc_q <= ex_mret_vector;
      end

      if (redirect_valid | ex_sys_redirect_valid | id_pred_redirect_valid |
          ex_mret_fire | sync_trap_valid | irq_take_effective) begin
        irq_redirect_settle_q <= 2'd2;
      end else if (irq_redirect_settle_q != 2'b00) begin
        irq_redirect_settle_q <= irq_redirect_settle_q - 2'd1;
      end

      if (sync_trap_valid | irq_take_effective) begin
        ex_sys_redirect_valid_q <= 1'b1;
        ex_sys_redirect_pc_q    <= ex_trap_vector;
        csr_trap_enter_q        <= 1'b1;
        csr_trap_is_interrupt_q <= irq_take_effective;
        csr_trap_pc_q           <= sync_trap_valid ? sync_trap_pc : irq_trap_pc;
        csr_trap_cause_q        <= sync_trap_valid ? sync_trap_cause : irq_cause_w;
        csr_trap_tval_q         <= sync_trap_valid ? sync_trap_tval : 32'b0;
      end else if (ex_mret_fire) begin
        ex_sys_redirect_valid_q <= 1'b1;
        ex_sys_redirect_pc_q    <= ex_mret_vector;
        csr_mret_exec_q         <= 1'b1;
      end
    end
  end

  csr_file u_csr (
    .clk               (core_clk),
    .rst_n             (core_rst_n),
    .csr_en            (csr_exec_write_en),
    .csr_cmd           (ex_csr_cmd),
    .csr_addr          (ex_csr_addr),
    .csr_wdata         (ex_rs1_val_fwd),
    .csr_rdata         (csr_rdata_w),
    .trap_enter        (csr_trap_enter_q),
    .trap_is_interrupt (csr_trap_is_interrupt_q),
    .trap_pc           (csr_trap_pc_q),
    .trap_cause        (csr_trap_cause_q),
    .trap_tval         (csr_trap_tval_q),
    .mret_exec         (csr_mret_exec_q),
    .ext_irq_pending   (irq_ext_pending_w),
    .timer_irq_pending (irq_timer_pending_w),
    .soft_irq_pending  (irq_soft_pending_w),
    .mtvec_o           (csr_mtvec_w),
    .mepc_o            (csr_mepc_w),
    .mcause_o          (csr_mcause_w),
    .mstatus_o         (csr_mstatus_w),
    .mie_o             (csr_mie_w),
    .mip_o             (csr_mip_w),
    .mscratch_o        (csr_mscratch_w),
    .current_priv_o    (csr_current_priv_w),
    .global_mie_o      (csr_global_mie_w),
    .msie_en_o         (csr_msie_en_w),
    .mtie_en_o         (csr_mtie_en_w),
    .meie_en_o         (csr_meie_en_w)
  );

  // EX validation for predicted control flow.
  wire ex_actual_taken  = ex_jal | ex_jalr | ex_br_taken;
  wire ex_is_ctrl_valid = ex_valid & (ex_branch | ex_jal | ex_jalr);
  wire ex_pred_dir_miss = (ex_pred_taken != ex_actual_taken);
  wire ex_pred_tgt_miss = ex_actual_taken & ex_pred_taken &
                          (ex_pred_target != ex_redirect_pc_raw);

  // redirect_valid/redirect_pc are for wrong-path recovery and synchronous
  // system redirects (ecall/ebreak -> mtvec, mret -> mepc).
  assign redirect_valid = ex_is_ctrl_valid & ~stall_ex &
                          (ex_pred_dir_miss | ex_pred_tgt_miss);
  assign redirect_pc    = ex_actual_taken ? ex_redirect_pc_raw : ex_pc4;

  // Front-end redirect includes synchronous traps/interrupts, normal EX
  // recovery, and speculative ID prediction.
  assign fe_redirect_valid = ex_sys_redirect_valid | redirect_valid | id_pred_redirect_valid;
  assign fe_redirect_pc    = ex_sys_redirect_valid ? ex_sys_redirect_pc :
                             (redirect_valid ? redirect_pc : id_ctrl_target);

  // ================= EX/MEM =================
  wire [31:0] mem_store_data;
  wire [2:0]  mem_size;
  wire ex_mem_flush = ex_sync_trap;

  ex_mem_reg u_ex_mem (
    .clk              (core_clk),
    .rst_n            (core_rst_n),
    .stall_i          (stall_exmem),
    .flush_i          (ex_mem_flush),
    .ex_valid_i       (ex_valid),
    .ex_pc4_i         (ex_pc4),
    .ex_alu_result_i  (ex_alu_result),
    .ex_store_data_i  (ex_store_data),
    .ex_rd_i          (ex_rd),
    .ex_reg_write_i   (ex_reg_write),
    .ex_wb_sel_i      (ex_wb_sel),
    .ex_mem_read_i    (ex_mem_read),
    .ex_mem_write_i   (ex_mem_write),
    .ex_mem_funct3_i  (ex_mem_funct3),
    .mem_pc4_o        (mem_pc4),
    .mem_alu_result_o (mem_alu_result),
    .mem_store_data_o (mem_store_data),
    .mem_rd_o         (mem_rd),
    .mem_reg_write_o  (mem_reg_write),
    .mem_wb_sel_o     (mem_wb_sel),
    .mem_mem_read_o   (mem_mem_read),
    .mem_mem_write_o  (mem_mem_write),
    .mem_size_o       (mem_size),
    .mem_valid_o      (mem_valid)
  );

  // ================= MEM =================
  wire        dmem_req_o;
  wire        dmem_we_o;
  wire [31:0] dmem_addr_o;
  wire [31:0] dmem_wdata_o;
  wire [3:0]  dmem_wstrb_o;
  wire        dmem_ready_i;
  wire        dmem_rvalid_i;
  wire [31:0] dmem_rdata_i;
  wire        store_done_i;
  wire        dmem_rsp_err_i;

  mem_stage u_mem (
    .clk              (core_clk),
    .rst_n            (core_rst_n),
    .mem_valid_i      (mem_valid),
    .mem_alu_result_i (mem_alu_result),
    .mem_store_data_i (mem_store_data),
    .mem_mem_read_i   (mem_mem_read),
    .mem_mem_write_i  (mem_mem_write),
    .mem_size_i       (mem_size),
    .dmem_req_o       (dmem_req_o),
    .dmem_we_o        (dmem_we_o),
    .dmem_addr_o      (dmem_addr_o),
    .dmem_wdata_o     (dmem_wdata_o),
    .dmem_wstrb_o     (dmem_wstrb_o),
    .dmem_ready_i     (dmem_ready_i),
    .dmem_rvalid_i    (dmem_rvalid_i),
    .dmem_rdata_i     (dmem_rdata_i),
    .store_done_i     (store_done_i),
    .mem_load_rdata_o (mem_load_rdata),
    .mem_stall_o      (mem_stall),
    .mem_load_valid_o (mem_load_valid),
    .mem_load_active_o(mem_load_active)
  );

  // UART MMIO region (0x4000_0000..0x4000_FFFF):
  //   0x4000_0000 write -> TX data (lowest asserted byte lane)
  //   0x4000_0004 read  -> TX status, bit0 = tx_ready
  //   0x4000_0008 read  -> RX data, low byte = received char, read pops one byte
  //   0x4000_000C read  -> RX status, bit0 = rx_valid, bit1 = rx_overrun
  //   0x4000_0010 read  -> launcher button status, bit0 = pressed
  //   0x4000_0014 write -> launcher soft reset request, bit0 = trigger
  //   0x4000_0018 read/write -> MSIP synthetic pending bit, bit0
  //   0x4000_001C read/write -> MEIP synthetic pending bit, bit0
  //   0x4000_0020 read/write -> MTIME low 32 bits
  //   0x4000_0024 read/write -> MTIME high 32 bits
  //   0x4000_0028 read/write -> MTIMECMP low 32 bits
  //   0x4000_002C read/write -> MTIMECMP high 32 bits
  // Other addresses in the region return an error response.
  localparam [31:0] UART_MMIO_BASE   = 32'h4000_0000;
  localparam [31:0] UART_MMIO_TX_STATUS = 32'h4000_0004;
  localparam [31:0] UART_MMIO_RX_DATA   = 32'h4000_0008;
  localparam [31:0] UART_MMIO_RX_STATUS = 32'h4000_000C;
  localparam [31:0] UART_MMIO_LAUNCHER_STATUS = 32'h4000_0010;
  localparam [31:0] UART_MMIO_LAUNCHER_RESET  = 32'h4000_0014;
  localparam [31:0] UART_MMIO_MSIP            = 32'h4000_0018;
  localparam [31:0] UART_MMIO_MEIP            = 32'h4000_001C;
  localparam [31:0] UART_MMIO_MTIME_LO        = 32'h4000_0020;
  localparam [31:0] UART_MMIO_MTIME_HI        = 32'h4000_0024;
  localparam [31:0] UART_MMIO_MTIMECMP_LO     = 32'h4000_0028;
  localparam [31:0] UART_MMIO_MTIMECMP_HI     = 32'h4000_002C;
  localparam [31:0] VGA_MMIO_BASE    = 32'h5000_0000;
  localparam [31:0] VGA_MMIO_LAST    = 32'h5000_7FFF;

  wire        uart_mmio_hit = (dmem_addr_o[31:16] == UART_MMIO_BASE[31:16]);
  wire        uart_mmio_sel_tx_data =
      (dmem_addr_o[31:2] == UART_MMIO_BASE[31:2]);
  wire        uart_mmio_sel_tx_status =
      (dmem_addr_o[31:2] == UART_MMIO_TX_STATUS[31:2]);
  wire        uart_mmio_sel_rx_data =
      (dmem_addr_o[31:2] == UART_MMIO_RX_DATA[31:2]);
  wire        uart_mmio_sel_rx_status =
      (dmem_addr_o[31:2] == UART_MMIO_RX_STATUS[31:2]);
  wire        uart_mmio_sel_launcher_status =
      (dmem_addr_o[31:2] == UART_MMIO_LAUNCHER_STATUS[31:2]);
  wire        uart_mmio_sel_launcher_reset =
      (dmem_addr_o[31:2] == UART_MMIO_LAUNCHER_RESET[31:2]);
  wire        uart_mmio_sel_msip =
      (dmem_addr_o[31:2] == UART_MMIO_MSIP[31:2]);
  wire        uart_mmio_sel_meip =
      (dmem_addr_o[31:2] == UART_MMIO_MEIP[31:2]);
  wire        uart_mmio_sel_mtime_lo =
      (dmem_addr_o[31:2] == UART_MMIO_MTIME_LO[31:2]);
  wire        uart_mmio_sel_mtime_hi =
      (dmem_addr_o[31:2] == UART_MMIO_MTIME_HI[31:2]);
  wire        uart_mmio_sel_mtimecmp_lo =
      (dmem_addr_o[31:2] == UART_MMIO_MTIMECMP_LO[31:2]);
  wire        uart_mmio_sel_mtimecmp_hi =
      (dmem_addr_o[31:2] == UART_MMIO_MTIMECMP_HI[31:2]);
  wire        uart_mmio_addr_valid =
      uart_mmio_sel_tx_data |
      uart_mmio_sel_tx_status |
      uart_mmio_sel_rx_data |
      uart_mmio_sel_rx_status |
      uart_mmio_sel_launcher_status |
      uart_mmio_sel_launcher_reset |
      uart_mmio_sel_msip |
      uart_mmio_sel_meip |
      uart_mmio_sel_mtime_lo |
      uart_mmio_sel_mtime_hi |
      uart_mmio_sel_mtimecmp_lo |
      uart_mmio_sel_mtimecmp_hi;
  wire        uart_mmio_req_valid = dmem_req_o & uart_mmio_hit;
  wire        vga_mmio_hit =
      (USE_VGA != 0) &&
      (dmem_addr_o >= VGA_MMIO_BASE) &&
      (dmem_addr_o <= VGA_MMIO_LAST);
  wire        vga_mmio_req_valid = dmem_req_o & vga_mmio_hit;
  wire        local_mmio_hit = uart_mmio_hit | vga_mmio_hit;

  wire [7:0] uart_mmio_wbyte =
      dmem_wstrb_o[0] ? dmem_wdata_o[7:0]   :
      dmem_wstrb_o[1] ? dmem_wdata_o[15:8]  :
      dmem_wstrb_o[2] ? dmem_wdata_o[23:16] :
                        dmem_wdata_o[31:24];
  wire       uart_mmio_has_byte = |dmem_wstrb_o;

  wire       uart_tx_busy;
  reg  [7:0] uart_tx_data_q;
  reg        uart_tx_en_q;
  reg        uart_rx_ff1_q;
  reg        uart_rx_ff2_q;
  wire [7:0] uart_rx_data_w;
  wire       uart_rx_valid_w;
  reg  [7:0] uart_rx_data_q;
  reg        uart_rx_valid_q;
  reg        uart_rx_overrun_q;

  wire uart_mmio_ready =
      ~uart_mmio_req_valid ? 1'b0 :
      (dmem_we_o && uart_mmio_sel_tx_data && uart_mmio_has_byte) ? ~uart_tx_busy :
      1'b1;
  wire uart_mmio_fire = uart_mmio_req_valid & uart_mmio_ready;
  wire uart_mmio_write_err =
      dmem_we_o & (~(uart_mmio_sel_tx_data |
                     uart_mmio_sel_launcher_reset |
                     uart_mmio_sel_msip |
                     uart_mmio_sel_meip |
                     uart_mmio_sel_mtime_lo |
                     uart_mmio_sel_mtime_hi |
                     uart_mmio_sel_mtimecmp_lo |
                     uart_mmio_sel_mtimecmp_hi) | ~uart_mmio_has_byte);
  wire uart_mmio_read_err =
      (~dmem_we_o) & (~uart_mmio_addr_valid);
  wire uart_mmio_rsp_err = uart_mmio_fire & (uart_mmio_write_err | uart_mmio_read_err);
  wire [31:0] uart_mmio_rsp_rdata =
      uart_mmio_sel_tx_status ? {31'd0, ~uart_tx_busy} :
      uart_mmio_sel_rx_data   ? {24'd0, uart_rx_data_q} :
      uart_mmio_sel_rx_status ? {30'd0, uart_rx_overrun_q, uart_rx_valid_q} :
      uart_mmio_sel_launcher_status ? {31'd0, launcher_reset_btn_q} :
      uart_mmio_sel_msip      ? irq_msip_rdata_w :
      uart_mmio_sel_meip      ? irq_meip_rdata_w :
      uart_mmio_sel_mtime_lo  ? irq_mtime_lo_w :
      uart_mmio_sel_mtime_hi  ? irq_mtime_hi_w :
      uart_mmio_sel_mtimecmp_lo ? irq_mtimecmp_lo_w :
      uart_mmio_sel_mtimecmp_hi ? irq_mtimecmp_hi_w :
      32'd0;
  wire uart_mmio_rsp_valid = uart_mmio_fire;
  wire uart_mmio_tx_fire =
      uart_mmio_fire & dmem_we_o & uart_mmio_sel_tx_data & uart_mmio_has_byte;
  assign uart_mmio_launcher_reset_fire =
      uart_mmio_fire & dmem_we_o & uart_mmio_sel_launcher_reset & uart_mmio_has_byte & uart_mmio_wbyte[0];
  wire uart_mmio_msip_fire =
      uart_mmio_fire & dmem_we_o & uart_mmio_sel_msip & uart_mmio_has_byte;
  wire uart_mmio_meip_fire =
      uart_mmio_fire & dmem_we_o & uart_mmio_sel_meip & uart_mmio_has_byte;
  wire uart_mmio_mtime_lo_fire =
      uart_mmio_fire & dmem_we_o & uart_mmio_sel_mtime_lo & uart_mmio_has_byte;
  wire uart_mmio_mtime_hi_fire =
      uart_mmio_fire & dmem_we_o & uart_mmio_sel_mtime_hi & uart_mmio_has_byte;
  wire uart_mmio_mtimecmp_lo_fire =
      uart_mmio_fire & dmem_we_o & uart_mmio_sel_mtimecmp_lo & uart_mmio_has_byte;
  wire uart_mmio_mtimecmp_hi_fire =
      uart_mmio_fire & dmem_we_o & uart_mmio_sel_mtimecmp_hi & uart_mmio_has_byte;
  wire uart_mmio_rx_pop =
      uart_mmio_fire & (~dmem_we_o) & uart_mmio_sel_rx_data;
  wire uart_mmio_rx_status_read =
      uart_mmio_fire & (~dmem_we_o) & uart_mmio_sel_rx_status;
  wire        vga_mmio_ready;
  wire        vga_mmio_rsp_valid;
  wire [31:0] vga_mmio_rsp_rdata;
  wire        vga_mmio_rsp_err;

  generate
    if (USE_VGA) begin : GEN_VGA
      vga_subsystem #(
        .FB_BASE_ADDR (VGA_MMIO_BASE)
      ) u_vga (
        .cpu_clk       (core_clk),
        .rst_n         (core_rst_n),
        .vga_mclk      (clk),
        .cpu_req_valid (vga_mmio_req_valid),
        .cpu_req_we    (dmem_we_o),
        .cpu_req_addr  (dmem_addr_o),
        .cpu_req_wdata (dmem_wdata_o),
        .cpu_req_wstrb (dmem_wstrb_o),
        .cpu_req_ready (vga_mmio_ready),
        .cpu_rsp_valid (vga_mmio_rsp_valid),
        .cpu_rsp_rdata (vga_mmio_rsp_rdata),
        .cpu_rsp_err   (vga_mmio_rsp_err),
        .hsync_o       (vga_hsync_w),
        .vsync_o       (vga_vsync_w),
        .red_o         (vga_red_w),
        .green_o       (vga_green_w),
        .blue_o        (vga_blue_w)
      );
    end else begin : GEN_NO_VGA
      assign vga_mmio_ready = 1'b0;
      assign vga_mmio_rsp_valid = 1'b0;
      assign vga_mmio_rsp_rdata = 32'd0;
      assign vga_mmio_rsp_err = 1'b0;
      assign vga_hsync_w = 1'b1;
      assign vga_vsync_w = 1'b1;
      assign vga_red_w = 4'd0;
      assign vga_green_w = 4'd0;
      assign vga_blue_w = 4'd0;
    end
  endgenerate

  always @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      if_pc_prev_q        <= RESET_PC;
      core_pc_seen_q      <= 1'b0;
      uart_mmio_seen_q    <= 1'b0;
      uart_tx_fire_seen_q <= 1'b0;
      uart_tx_busy_seen_q <= 1'b0;
      dmem_req_seen_q     <= 1'b0;
      dmem_store_seen_q   <= 1'b0;
      dmem_rsp_seen_q     <= 1'b0;
      mem_stall_seen_q    <= 1'b0;
      wb_seen_q           <= 1'b0;
    end else begin
      if (if_pc != if_pc_prev_q)
        core_pc_seen_q <= 1'b1;
      if_pc_prev_q <= if_pc;
      if (dmem_req_o)
        dmem_req_seen_q <= 1'b1;
      if (dmem_req_o && dmem_we_o && ~local_mmio_hit)
        dmem_store_seen_q <= 1'b1;
      if (dmem_rvalid_i && ~local_mmio_hit)
        dmem_rsp_seen_q <= 1'b1;
      if (mem_stall)
        mem_stall_seen_q <= 1'b1;
      if (rf_we)
        wb_seen_q <= 1'b1;
      if (uart_mmio_fire)
        uart_mmio_seen_q <= 1'b1;
      if (uart_mmio_tx_fire)
        uart_tx_fire_seen_q <= 1'b1;
      if (uart_tx_busy)
        uart_tx_busy_seen_q <= 1'b1;
    end
  end

  always @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      uart_tx_data_q <= 8'h00;
      uart_tx_en_q   <= 1'b0;
      uart_rx_ff1_q  <= 1'b1;
      uart_rx_ff2_q  <= 1'b1;
      uart_rx_data_q <= 8'h00;
      uart_rx_valid_q <= 1'b0;
      uart_rx_overrun_q <= 1'b0;
    end else begin
      uart_tx_en_q <= uart_mmio_tx_fire;
      uart_rx_ff1_q <= uart_rx_i;
      uart_rx_ff2_q <= uart_rx_ff1_q;
      if (uart_mmio_tx_fire) begin
        uart_tx_data_q <= uart_mmio_wbyte;
      end
      if (uart_rx_valid_w) begin
        if (!uart_rx_valid_q || uart_mmio_rx_pop) begin
          uart_rx_data_q  <= uart_rx_data_w;
          uart_rx_valid_q <= 1'b1;
        end else begin
          uart_rx_overrun_q <= 1'b1;
        end
      end else if (uart_mmio_rx_pop) begin
        uart_rx_valid_q <= 1'b0;
      end
      if (uart_mmio_rx_status_read) begin
        uart_rx_overrun_q <= 1'b0;
      end
    end
  end

  uart_rx #(
    .CLK_HZ (UART_CLK_HZ),
    .BAUD   (UART_BAUD)
  ) u_uart_rx_mmio (
    .clk     (core_clk),
    .rst_n   (core_rst_n),
    .rx_i    (uart_rx_ff2_q),
    .data_o  (uart_rx_data_w),
    .valid_o (uart_rx_valid_w)
  );

  uart_tx #(
    .CLK_HZ (UART_CLK_HZ),
    .BAUD   (UART_BAUD)
  ) u_uart_tx (
    .data_in (uart_tx_data_q),
    .Tx_en   (uart_tx_en_q),
    .clk_50m (core_clk),
    .rst_n   (core_rst_n),
    .Tx      (uart_tx_o),
    .Tx_busy (uart_tx_busy)
  );

  machine_irq_sources u_irq_sources (
    .clk              (core_clk),
    .rst_n            (core_rst_n),
    .msip_we_i        (uart_mmio_msip_fire),
    .msip_wdata_i     (dmem_wdata_o),
    .meip_we_i        (uart_mmio_meip_fire),
    .meip_wdata_i     (dmem_wdata_o),
    .mtime_lo_we_i    (uart_mmio_mtime_lo_fire),
    .mtime_lo_wdata_i (dmem_wdata_o),
    .mtime_hi_we_i    (uart_mmio_mtime_hi_fire),
    .mtime_hi_wdata_i (dmem_wdata_o),
    .mtimecmp_lo_we_i (uart_mmio_mtimecmp_lo_fire),
    .mtimecmp_lo_wdata_i(dmem_wdata_o),
    .mtimecmp_hi_we_i (uart_mmio_mtimecmp_hi_fire),
    .mtimecmp_hi_wdata_i(dmem_wdata_o),
    .ext_irq_line_i   (uart_rx_valid_q),
    .global_mie_i     (csr_global_mie_w),
    .msie_en_i        (csr_msie_en_w),
    .mtie_en_i        (csr_mtie_en_w),
    .meie_en_i        (csr_meie_en_w),
    .msip_rdata_o     (irq_msip_rdata_w),
    .meip_rdata_o     (irq_meip_rdata_w),
    .mtime_lo_o       (irq_mtime_lo_w),
    .mtime_hi_o       (irq_mtime_hi_w),
    .mtimecmp_lo_o    (irq_mtimecmp_lo_w),
    .mtimecmp_hi_o    (irq_mtimecmp_hi_w),
    .soft_irq_pending_o (irq_soft_pending_w),
    .timer_irq_pending_o(irq_timer_pending_w),
    .ext_irq_pending_o  (irq_ext_pending_w),
    .irq_request_o      (irq_request_w),
    .irq_cause_o        (irq_cause_w)
  );

  // D$ instance (blocking cache)
  wire        dcache_cpu_req_ready;
  wire        dcache_cpu_rsp_valid;
  wire [31:0] dcache_cpu_rsp_rdata;
  wire        dcache_cpu_rsp_err;
  wire        dcache_cpu_rsp_ready = 1'b1;
  wire [1:0]  dcache_req_size = mem_size[1:0];
  wire        dcache_cpu_req_valid = dmem_req_o & ~local_mmio_hit;
`ifdef FAST_SIM
  localparam integer D_CACHE_BYTES_CFG = 8192;   // fast simulation
`elsif FAST_SYNTH
  localparam integer D_CACHE_BYTES_CFG = 8192;   // fast synthesis
`else
  localparam integer D_CACHE_BYTES_CFG = 131072; // production default (128KiB)
`endif

  dcache_blocking #(
    .ADDR_W     (32),
    .CPU_DATA_W (32),
    .CPU_STRB_W (4),
    .BUS_W      (L2_DATA_W),
    .LINE_BYTES (64),
    .CACHE_BYTES(D_CACHE_BYTES_CFG),
    .WAYS       (2)
  ) u_dcache (
    .clk              (core_clk),
    .rst_n            (core_rst_n),
    .cpu_req_valid   (dcache_cpu_req_valid),
    .cpu_req_ready   (dcache_cpu_req_ready),
    .cpu_req_addr    (dmem_addr_o),
    .cpu_req_we      (dmem_we_o),
    .cpu_req_wdata   (dmem_wdata_o),
    .cpu_req_wstrb   (dmem_wstrb_o),
    .cpu_req_size    (dcache_req_size),
    .cpu_req_uncached(1'b0),
    .cpu_rsp_valid   (dcache_cpu_rsp_valid),
    .cpu_rsp_ready   (dcache_cpu_rsp_ready),
    .cpu_rsp_rdata   (dcache_cpu_rsp_rdata),
    .cpu_rsp_err     (dcache_cpu_rsp_err),
    .l2_req_valid    (d_l2_req_valid),
    .l2_req_ready    (d_l2_req_ready_int),
    .l2_req_cmd      (d_l2_req_cmd),
    .l2_req_addr     (d_l2_req_addr),
    .l2_req_size     (d_l2_req_size),
    .l2_req_len      (d_l2_req_len),
    .l2_req_wdata    (d_l2_req_wdata),
    .l2_req_wstrb    (d_l2_req_wstrb),
    .l2_rsp_valid    (d_l2_rsp_valid_int),
    .l2_rsp_ready    (d_l2_rsp_ready),
    .l2_rsp_rdata    (d_l2_rsp_rdata_int),
    .l2_rsp_last     (d_l2_rsp_last_int),
    .l2_rsp_err      (d_l2_rsp_err_int)
  );

  assign dmem_ready_i  = uart_mmio_hit ? uart_mmio_ready :
                         (vga_mmio_hit ? vga_mmio_ready : dcache_cpu_req_ready);
  assign dmem_rvalid_i = uart_mmio_hit ? uart_mmio_rsp_valid :
                         (vga_mmio_hit ? vga_mmio_rsp_valid : dcache_cpu_rsp_valid);
  assign dmem_rdata_i  = uart_mmio_hit ? uart_mmio_rsp_rdata :
                         (vga_mmio_hit ? vga_mmio_rsp_rdata : dcache_cpu_rsp_rdata);
  assign dmem_rsp_err_i = uart_mmio_hit ? uart_mmio_rsp_err :
                          (vga_mmio_hit ? vga_mmio_rsp_err : dcache_cpu_rsp_err);
  assign store_done_i  = dmem_rvalid_i;
  wire        mem_err_event = dmem_rvalid_i & dmem_rsp_err_i;
  assign mem_sync_trap = mem_err_event;
  assign mem_trap_cause = mem_mem_write ? 32'd7 : 32'd5;
  assign mem_trap_pc = mem_pc4 - 32'd4;

  // ================= MEM/WB =================
  wire        wb_valid;
  wire        wb_i_valid;
  wire        wb_stall;

  assign wb_i_valid = mem_mem_read ? mem_load_valid : (mem_valid & ~mem_stall);
  assign wb_stall   = mem_stall & ~mem_load_valid;

  mem_wb u_mem_wb (
    .clk              (core_clk),
    .rst_n            (core_rst_n),
    .i_valid      (wb_i_valid),
    .i_flush      (mem_err_event),
    .i_stall      (wb_stall),
    .i_rd         (mem_rd),
    .i_rd_wen     (mem_reg_write),
    .i_alu_result (mem_alu_result),
    .i_mem_rdata  (mem_load_rdata),
    .i_pc_plus4   (mem_pc4),
    .i_wb_sel     (mem_wb_sel),
    .o_valid      (wb_valid),
    .o_rd         (wb_rd),
    .o_rd_wen     (wb_rd_wen),
    .o_wb_wdata   (wb_wdata)
  );

  // ================= WB =================
  wb_stage u_wb (
    .clk              (core_clk),
    .rst_n            (core_rst_n),
    .i_valid        (wb_valid),
    .i_rd           (wb_rd),
    .i_rd_wen       (wb_rd_wen),
    .i_wb_wdata     (wb_wdata),
    .rf_we_o        (rf_we),
    .rf_waddr_o     (rf_waddr),
    .rf_wdata_o     (rf_wdata),
    //?��??? 已�?��?? forwarding，只?��?��??�是 mem_wb 輸出??? wb_rd_wen / wb_rd / wb_wdata ?��?��餵給 forward_unit
    .wb_fwd_valid_o (),//?��?��?��?? WB ??��?��?�寫???
    .wb_fwd_rd_o    (),//被寫??��?�目??�暫存器編�??
    .wb_fwd_data_o  ()//要寫??��?��?��??
  );

  // Expose WB for TB
  assign wb_we_o    = rf_we;
  assign wb_rd_o    = rf_waddr;
  assign wb_wdata_o = rf_wdata;

  // Interrupts are taken between instructions. When one is pending, stop
  // feeding younger instructions into IF/ID, but let the current ID
  // instruction continue draining into EX so returns/redirects resolve before
  // we snapshot mepc.
  //
  // Keep this hold independent from same-cycle trap/mret combinational logic;
  // otherwise the IRQ quiesce path can feed predicted redirect / ifetch trap
  // masking and create a control loop.
  assign irq_take_now      = irq_request_w & ~id_valid & ~ex_valid & ~mem_valid & ~wb_valid & ~mem_stall &
                             (irq_redirect_settle_q == 2'b00);
  assign irq_frontend_hold = irq_request_w & ~irq_take_now;
  assign irq_quiesce_id    = irq_frontend_hold;
  assign irq_trap_pc       = irq_pc_override_valid_q ? irq_pc_override_q :
                             irq_arch_pc_q;

  // ================= Hazard/Control =================
  wire flush_ifid_hdu, flush_idex_hdu;
  wire [31:0] pending_load_mask = 32'b0;

  hazard_unit u_hdu (
    .id_valid_i         (id_valid),
    .id_rs1_i           (id_rs1),
    .id_rs2_i           (id_rs2),
    .id_is_store_i      (id_mem_write),
    .ex_valid_i         (ex_valid),
    .ex_rd_i            (ex_rd),
    .ex_reg_write_i     (ex_reg_write),
    .ex_mem_read_i      (ex_mem_read),
    .ex_stall_req_i     (ex_stall_o),
    .mem_valid_i        (mem_valid),
    .mem_rd_i           (mem_rd),
    .mem_reg_write_i    (mem_reg_write),
    .mem_stall_i        (mem_stall),
    .mem_load_active_i  (mem_load_active),
    .pending_load_mask_i(pending_load_mask),
    .ifetch_stall_i     (1'b0),
    .redirect_valid_i   (redirect_valid),
    .stall_if_o         (stall_if_hdu),
    .stall_id_o         (stall_id_hdu),
    .stall_ex_o         (stall_ex_hdu),
    .stall_exmem_o      (stall_exmem_hdu),
    .flush_ifid_o       (flush_ifid_hdu),
    .flush_idex_o       (flush_idex_hdu)
  );

  // Front-end hold while an outstanding fetch exists or handshake is back-pressured.
  assign stall_if    = stall_if_hdu | if_pending | req_blocked | resp_blocked |
                       fetch_resp_buf_blocked | icache_flush_pending_q | irq_frontend_hold;
  assign stall_id    = stall_id_hdu;
  assign stall_ex    = stall_ex_hdu;
  assign stall_exmem = stall_exmem_hdu;
  assign flush_ifid  = flush_ifid_hdu | sys_flush_now;
  assign flush_idex  = flush_idex_hdu | sys_flush_now;

`ifndef SYNTHESIS
  reg ifdbg_en;
  integer ifdbg_cnt;
  initial begin
    ifdbg_en = 1'b0;
    ifdbg_cnt = 0;
    if ($test$plusargs("IFDBG")) begin
      ifdbg_en = 1'b1;
    end
  end
  always @(posedge core_clk) begin
    if (core_rst_n && ifdbg_en && (ifdbg_cnt < 300)) begin
      if (fetch_req_valid && fetch_req_ready) begin
        $display("[IFDBG %0t] REQ  pc=0x%08x pend=%0d stall_if=%0d kill=%0d",
                 $time, fetch_req_addr, if_pending, stall_if, fetch_req_kill);
        ifdbg_cnt <= ifdbg_cnt + 1;
      end
      if (fetch_resp_buf_pop) begin
        $display("[IFDBG %0t] RESP pc=0x%08x inst=0x%08x pend=%0d stall_if=%0d",
                 $time, fetch_resp_pc, fetch_resp_inst, if_pending, stall_if);
        ifdbg_cnt <= ifdbg_cnt + 1;
      end
    end
  end
`endif

endmodule

module ddr_app_memtest #(
  parameter [26:0] TEST_BASE_ADDR = 27'd0,
  parameter integer WAIT_CYCLES = 512
) (
  input               clk,
  input               start_i,
  output reg [26:0]   app_addr,
  output reg [2:0]    app_cmd,
  output reg          app_en,
  output reg [127:0]  app_wdf_data,
  output reg          app_wdf_end,
  output reg [15:0]   app_wdf_mask,
  output reg          app_wdf_wren,
  input [127:0]       app_rd_data,
  input               app_rd_data_end,
  input               app_rd_data_valid,
  input               app_rdy,
  input               app_wdf_rdy,
  output reg          done_o,
  output reg          pass_o,
  output reg          rd_seen_o,
  output reg          beat0_ok_o,
  output reg          beat1_ok_o,
  output reg          beat2_ok_o,
  output reg          beat3_ok_o
);
  localparam [2:0] MIG_CMD_WRITE = 3'b000;
  localparam [2:0] MIG_CMD_READ  = 3'b001;

  localparam [2:0] S_IDLE    = 3'd0;
  localparam [2:0] S_WR_REQ  = 3'd1;
  localparam [2:0] S_WR_WAIT = 3'd2;
  localparam [2:0] S_RD_REQ  = 3'd3;
  localparam [2:0] S_RD_WAIT = 3'd4;
  localparam [2:0] S_DONE    = 3'd5;

  localparam integer WAIT_W = (WAIT_CYCLES <= 1) ? 1 : $clog2(WAIT_CYCLES + 1);

  reg [2:0] state_q;
  reg [WAIT_W-1:0] wait_cnt_q;
  reg [1:0] test_idx_q;
  reg       wr_need_cmd_q;
  reg       wr_need_data_q;

  wire wr_cmd_fire  = wr_need_cmd_q && app_rdy;
  wire wr_data_fire = wr_need_data_q && app_wdf_rdy;
  wire wr_req_done  = (!wr_need_cmd_q || wr_cmd_fire) &&
                      (!wr_need_data_q || wr_data_fire);

  function [127:0] test_wdata;
    input [1:0] idx;
    begin
      case (idx)
        2'd0: test_wdata = 128'h0123_4567_89AB_CDEF_FEDC_BA98_7654_3210;
        2'd1: test_wdata = 128'h89AB_CDEF_0123_4567_7654_3210_FEDC_BA98;
        2'd2: test_wdata = 128'h55AA_33CC_0F0F_F0F0_A5A5_5A5A_9696_6969;
        default: test_wdata = 128'hDEAD_BEEF_CAFE_1234_1357_9BDF_2468_ACED;
      endcase
    end
  endfunction

  always @(*) begin
    app_addr     = TEST_BASE_ADDR + ({25'd0, test_idx_q} << 4);
    app_cmd      = MIG_CMD_WRITE;
    app_en       = 1'b0;
    app_wdf_data = test_wdata(test_idx_q);
    app_wdf_end  = 1'b0;
    app_wdf_mask = 16'h0000;
    app_wdf_wren = 1'b0;

    case (state_q)
      S_WR_REQ: begin
        app_cmd      = MIG_CMD_WRITE;
        app_en       = wr_need_cmd_q;
        app_wdf_wren = wr_need_data_q;
        app_wdf_end  = wr_need_data_q;
      end
      S_RD_REQ: begin
        app_cmd      = MIG_CMD_READ;
        app_en       = 1'b1;
      end
      default: begin
      end
    endcase
  end

  always @(posedge clk) begin
    if (!start_i) begin
      state_q    <= S_IDLE;
      wait_cnt_q <= {WAIT_W{1'b0}};
      test_idx_q <= 2'd0;
      wr_need_cmd_q  <= 1'b0;
      wr_need_data_q <= 1'b0;
      done_o     <= 1'b0;
      pass_o     <= 1'b0;
      rd_seen_o  <= 1'b0;
      beat0_ok_o <= 1'b0;
      beat1_ok_o <= 1'b0;
      beat2_ok_o <= 1'b0;
      beat3_ok_o <= 1'b0;
    end else begin
      case (state_q)
        S_IDLE: begin
          done_o     <= 1'b0;
          pass_o     <= 1'b0;
          rd_seen_o  <= 1'b0;
          beat0_ok_o <= 1'b0;
          beat1_ok_o <= 1'b0;
          beat2_ok_o <= 1'b0;
          beat3_ok_o <= 1'b0;
          wait_cnt_q <= {WAIT_W{1'b0}};
          test_idx_q <= 2'd0;
          wr_need_cmd_q  <= 1'b1;
          wr_need_data_q <= 1'b1;
          state_q    <= S_WR_REQ;
        end
        S_WR_REQ: begin
          if (wr_cmd_fire)
            wr_need_cmd_q <= 1'b0;
          if (wr_data_fire)
            wr_need_data_q <= 1'b0;
          if (wr_req_done) begin
            wr_need_cmd_q  <= 1'b0;
            wr_need_data_q <= 1'b0;
            wait_cnt_q <= WAIT_CYCLES[WAIT_W-1:0];
            state_q    <= S_WR_WAIT;
          end
        end
        S_WR_WAIT: begin
          if (wait_cnt_q != {WAIT_W{1'b0}})
            wait_cnt_q <= wait_cnt_q - 1'b1;
          else if (test_idx_q == 2'd3) begin
            test_idx_q <= 2'd0;
            state_q <= S_RD_REQ;
          end else begin
            test_idx_q <= test_idx_q + 1'b1;
            wr_need_cmd_q  <= 1'b1;
            wr_need_data_q <= 1'b1;
            state_q <= S_WR_REQ;
          end
        end
        S_RD_REQ: begin
          if (app_rdy)
            state_q <= S_RD_WAIT;
        end
        S_RD_WAIT: begin
          if (app_rd_data_valid && app_rd_data_end) begin
            rd_seen_o <= 1'b1;
            case (test_idx_q)
              2'd0: beat0_ok_o <= (app_rd_data == test_wdata(test_idx_q));
              2'd1: beat1_ok_o <= (app_rd_data == test_wdata(test_idx_q));
              2'd2: beat2_ok_o <= (app_rd_data == test_wdata(test_idx_q));
              default: beat3_ok_o <= (app_rd_data == test_wdata(test_idx_q));
            endcase
            if (test_idx_q == 2'd3) begin
              pass_o  <= beat0_ok_o &
                         beat1_ok_o &
                         beat2_ok_o &
                         (app_rd_data == test_wdata(test_idx_q));
              done_o  <= 1'b1;
              state_q <= S_DONE;
            end else begin
              test_idx_q <= test_idx_q + 1'b1;
              state_q    <= S_RD_REQ;
            end
          end
        end
        default: begin
          done_o   <= 1'b1;
          state_q  <= S_DONE;
        end
      endcase
    end
  end
endmodule
