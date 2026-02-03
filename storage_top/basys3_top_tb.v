`timescale 1ns/1ps
module basys3_top_tb;

  // 100 MHz board clock
  reg clk_100mhz = 1'b0;
  always #5 clk_100mhz = ~clk_100mhz;

  // BTN_C (active-high reset in this wrapper)
  reg btnC;

  // UART pins
  reg  uart_rx;
  wire uart_tx;
  reg  capturing = 1'b0;
  reg  uart_tx_q = 1'b1;
  reg [9:0] shift_reg = 10'h3FF;
  reg [7:0] capture_byte = 8'h00;
  reg [3:0] bit_count = 4'd0;
  integer sample_cnt = 0;

  // LEDs
  wire [15:0] led;

  // Instantiate the FPGA wrapper with an example mem init file.
  wire        sim_wb_we;
  wire [4:0]  sim_wb_rd;
  wire [31:0] sim_wb_wdata;
  wire        sim_mem_err;

  basys3_top #(
    .SRAM_INIT_FILE("mem_init_example.mem"),
    .CI_UART_BAUD(5_000_000)
  ) dut (
    .clk_100mhz (clk_100mhz),
    .btnC       (btnC),
    .uart_rx    (uart_rx),
    .uart_tx    (uart_tx),
    .led        (led),
    .sim_wb_we  (sim_wb_we),
    .sim_wb_rd  (sim_wb_rd),
    .sim_wb_wdata(sim_wb_wdata),
    .sim_mem_access_err(sim_mem_err)
  );

  // Reset generation: hold BTN_C high for a short duration.
  initial begin
    btnC    = 1'b1;
    uart_rx = 1'b1; // idle high
    repeat (20) @(posedge clk_100mhz);
    btnC = 1'b0;
  end

  // Coarse UART monitor based on start-bit detection.

  always @(posedge clk_100mhz) begin
    uart_tx_q <= uart_tx;
    if (!btnC) begin
      if (!capturing && uart_tx_q && ~uart_tx) begin
        capturing  <= 1'b1;
        bit_count  <= 4'd0;
        sample_cnt <= 0;
      end else if (capturing) begin
        sample_cnt <= sample_cnt + 1;
        if (sample_cnt == 20) begin
          sample_cnt <= 0;
          bit_count  <= bit_count + 4'd1;
          if (bit_count >= 1 && bit_count <= 8) begin
            capture_byte <= {uart_tx, capture_byte[7:1]};
          end else if (bit_count == 9) begin
            $display("%0t  UART TX BYTE (approx) = 0x%02h", $time, capture_byte);
            capturing <= 1'b0;
          end
        end
      end
    end
  end

  // PASS/FAIL monitors using internal wires exported in basys3_top.
  always @(posedge clk_100mhz) begin
    if (!btnC && sim_wb_we && (sim_wb_rd == 5'd4) && (sim_wb_wdata == 32'h0000_0011)) begin
      $display("%0t  PROGRAM PASS (rd4=0x00000011)", $time);
      #100 $finish;
    end
  end

  always @(posedge clk_100mhz) begin
    if (!btnC && sim_mem_err) begin
      $display("%0t  MEM_ACCESS_ERR asserted -> FAIL", $time);
      #100 $finish;
    end
  end

  // Timeout guard
  initial begin
    repeat (200000) @(posedge clk_100mhz);
    $fatal(1, "Timeout waiting for PASS.");
  end

endmodule
