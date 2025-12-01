`timescale 1ns/1ps
// basys3_top.v - Board wrapper that connects top_rv32i to Basys3 I/O
module basys3_top #(
  parameter SRAM_INIT_FILE = "",
  parameter integer CI_CLK_FREQ_HZ = 100_000_000,
  parameter integer CI_UART_BAUD   = 115200
)(
  input         clk_100mhz,
  input         btnC,
  input         uart_rx,
  output        uart_tx,
  output [15:0] led
`ifndef SYNTHESIS
  ,
  output        sim_wb_we,
  output [4:0]  sim_wb_rd,
  output [31:0] sim_wb_wdata,
  output        sim_mem_access_err
`endif
);

  // Push button is active-high; release reset after a short synchronizer.
  wire rst_btn_n = ~btnC;
  reg  [3:0] rst_sync_q;
  always @(posedge clk_100mhz or negedge rst_btn_n) begin
    if (!rst_btn_n)
      rst_sync_q <= 4'b0000;
    else
      rst_sync_q <= {rst_sync_q[2:0], 1'b1};
  end
  wire rst_n = rst_sync_q[3];

  wire        wb_we;
  wire [4:0]  wb_rd;
  wire [31:0] wb_wdata;
  wire        mem_access_err;

  top_rv32i #(
    .SRAM_INIT_FILE("mem_init_example.mem"),
    .CLK_FREQ_HZ   (CI_CLK_FREQ_HZ),
    .UART_BAUD     (CI_UART_BAUD)
  ) u_soc (
    .clk             (clk_100mhz),
    .rst_n           (rst_n),
    .uart_rx_i       (uart_rx),
    .uart_tx_o       (uart_tx),
    .wb_we_o         (wb_we),
    .wb_rd_o         (wb_rd),
    .wb_wdata_o      (wb_wdata),
    .mem_access_err_o(mem_access_err)
  );

  // Drive LEDs with recent WB value for quick visibility; LD15 indicates mem_access_err.
  reg [15:0] led_data_q;
  always @(posedge clk_100mhz or negedge rst_n) begin
    if (!rst_n)
      led_data_q <= 16'h0000;
    else if (wb_we)
      led_data_q <= wb_wdata[15:0];
  end

  assign led[14:0] = led_data_q[14:0];
  assign led[15]   = mem_access_err;

`ifndef SYNTHESIS
  assign sim_wb_we          = wb_we;
  assign sim_wb_rd          = wb_rd;
  assign sim_wb_wdata       = wb_wdata;
  assign sim_mem_access_err = mem_access_err;
`endif

endmodule
