// MEM/WB pipeline register (Verilog-2001)
// Latches MEM-stage result and presents it to WB; holds output under stall
module mem_wb(
  input              clk,
  input              rst_n,

  // pipeline control
  input              i_valid,     // MEM stage result valid
  input              i_flush,     // flush younger
  input              i_stall,     // WB backpressure

  // from MEM stage
  input      [4:0]   i_rd,
  input              i_rd_wen,
  input      [31:0]  i_alu_result,
  input      [31:0]  i_mem_rdata,
  input      [31:0]  i_pc_plus4,
  input      [1:0]   i_wb_sel,    // 00:ALU,01:MEM,10:PC+4

  // to WB stage
  output             o_valid,
  output     [4:0]   o_rd,
  output             o_rd_wen,
  output     [31:0]  o_wb_wdata
);
  // state
  reg              valid_q;
  reg [4:0]        rd_q;
  reg              rd_wen_q;
  reg [31:0]       wb_wdata_q;

  // mux
  function [31:0] wb_mux;
    input [1:0]  sel;
    input [31:0] alu_result;
    input [31:0] mem_rdata;
    input [31:0] pc_plus4;
    begin
      case (sel)
        2'b00: wb_mux = alu_result;
        2'b01: wb_mux = mem_rdata;
        2'b10: wb_mux = pc_plus4;
        default: wb_mux = alu_result;
      endcase
    end
  endfunction

  // next-state
  reg              valid_d;
  reg [4:0]        rd_d;
  reg              rd_wen_d;
  reg [31:0]       wb_wdata_d;

  always @(*) begin
    // defaults
    valid_d    = valid_q;
    rd_d       = rd_q;
    rd_wen_d   = rd_wen_q;
    wb_wdata_d = wb_wdata_q;
    if (i_flush) begin
      valid_d  = 1'b0;
      rd_wen_d = 1'b0;
    end else if (!i_stall) begin
      valid_d    = i_valid; // 由上游保證 i_valid 為單拍提交
      rd_d       = i_rd;
      rd_wen_d   = i_valid ? i_rd_wen : 1'b0; // 僅在提交當拍鎖存
      wb_wdata_d = wb_mux(i_wb_sel, i_alu_result, i_mem_rdata, i_pc_plus4);
    end
  end

  // registers
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_q    <= 1'b0;
      rd_q       <= 5'b0;
      rd_wen_q   <= 1'b0;
      wb_wdata_q <= 32'h0;
    end else begin
      valid_q    <= valid_d;
      rd_q       <= rd_d;
      rd_wen_q   <= rd_wen_d;
      wb_wdata_q <= wb_wdata_d;
    end
  end

  // outputs
  assign o_valid    = valid_q;
  assign o_rd       = rd_q;
  // 由於 i_valid 為單拍，rd_wen_q 僅在提交拍為 1，下一拍即清 0
  assign o_rd_wen   = valid_q & rd_wen_q;
  assign o_wb_wdata = wb_wdata_q;

endmodule
