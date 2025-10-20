`timescale 1ns/1ps
// tb_top_rv32i_inline.v -- Verilog-2001, no dot, positional only
module tb_top_rv32i_inline;

  reg         clk;
  reg         rst_n;
  wire        wb_we;
  wire [4:0]  wb_rd;
  wire [31:0] wb_wdata;
  wire        mem_access_err;

  top_rv32i dut (
    clk,
    rst_n,
    wb_we,
    wb_rd,
    wb_wdata,
    mem_access_err
  );

  // 100 MHz clock
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // reset then run
  initial begin
    rst_n = 1'b0;
    repeat (20) @(posedge clk);
    rst_n = 1'b1;
  end

  integer cyc;
  initial cyc = 0;
  always @(posedge clk) begin
    cyc = cyc + 1;
    if (wb_we) begin
      $display("%0t  cyc=%0d  WE=%0d  RD=%0d  WD=0x%08h",
               $time, cyc, wb_we, wb_rd, wb_wdata);
    end
    if (wb_we && wb_rd == 5'd4 && wb_wdata == 32'h0000_0011) begin
      $display("%0t  PROGRAM PASS (rd4=0x00000011)", $time);
      #20 $finish;
    end
    if (mem_access_err) begin
      $display("%0t  MEM_ACCESS_ERR asserted", $time);
      #20 $finish;
    end
    if (cyc > 3000) begin
      $display("Timeout");
      $finish;
    end
  end

endmodule
