// board_top.v
// Final top-level wrapper for FPGA board integration.
// Exposes only board-facing IO (clocks, reset, DDR2, UART, status).

module board_top #(
  parameter integer ADDR_WIDTH    = 32,
  parameter integer L2_DATA_W     = 64,
  parameter integer USE_MIG       = 1,
  parameter integer UART_BOOT_EN  = 1,
  parameter integer UART_BAUD     = 115_200,
  parameter integer UART_CLK_HZ   = 100_000_000,
  parameter [31:0]  UART_BOOT_BASE= 32'h8000_0000,
  parameter [31:0]  RESET_PC      = 32'h8000_0000
) (
  input                   clk_in,    // optional (unused when USE_MIG=1)
  input                   rst_n,
  input                   uart_rx_i,

  // DDR2 MIG interface
  inout  [15:0]           ddr2_dq,
  inout  [1:0]            ddr2_dqs_n,
  inout  [1:0]            ddr2_dqs_p,
  output [13:0]           ddr2_addr,
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
  input                   sys_clk_p,
  input                   sys_clk_n,
  input                   clk_ref_i,

  // Status outputs
  output [1:0]            status_o,
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
  wire                  init_calib_complete;
  wire                  boot_done;

  icache_pipeline_top #(
    .ADDR_WIDTH    (ADDR_WIDTH),
    .L2_DATA_W     (L2_DATA_W),
    .USE_MIG       (USE_MIG),
    .UART_BOOT_EN  (UART_BOOT_EN),
    .UART_BAUD     (UART_BAUD),
    .UART_CLK_HZ   (UART_CLK_HZ),
    .UART_BOOT_BASE(UART_BOOT_BASE),
    .RESET_PC      (RESET_PC)
  ) u_core (
    .clk          (clk_in),
    .rst_n        (rst_n),
    .uart_rx_i    (uart_rx_i),

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
    .sys_clk_p    (sys_clk_p),
    .sys_clk_n    (sys_clk_n),
    .clk_ref_i    (clk_ref_i),
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
    .ifetch_err_o (ifetch_err_o),
    .boot_done_o  (boot_done)
  );

  // Status: [0]=MIG init done, [1]=UART boot done
  assign status_o[0] = init_calib_complete;
  assign status_o[1] = boot_done;

endmodule
