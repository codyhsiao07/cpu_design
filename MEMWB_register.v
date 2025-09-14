// MEM/WB pipeline register (Verilog-2001)
// 假設：在進入此模組前，所有 memory 動作已完成
module mem_wb(
  input              clk,
  input              rst_n,

  // pipeline control
  input              i_valid,     // 此拍的 MEM 結果有效
  input              i_flush,     // flush：氣泡/例外/分支修正
  input              i_stall,     // WB 端背壓，保持輸出

  // from MEM stage
  input      [4:0]   i_rd,          // 目的暫存器編號
  input              i_rd_wen,      // 是否寫回暫存器
  input  [31:0]  i_alu_result,  // ALU 結果
  input  [31:0]  i_mem_rdata,   // 資料記憶體讀出
  input  [31:0]  i_pc_plus4,    // JAL/JALR link value
  input      [1:0]   i_wb_sel,      // 決定寫回來源（00:ALU,01:MEM,10:PC+4,11:保留）

  // to WB stage
  output             o_valid,
  output     [4:0]   o_rd,
  output             o_rd_wen,
  output [31:0]  o_wb_wdata
);
  parameter XLEN = 32;
  // 暫存器 (state)
  reg              valid_q;
  reg [4:0]        rd_q;
  reg              rd_wen_q;
  reg [31:0]   wb_wdata_q;

  // 組合邏輯 (next state)
  reg              valid_d;
  reg [4:0]        rd_d;
  reg              rd_wen_d;
  reg [31:0]   wb_wdata_d;

  // 寫回來源選擇
  function [31:0] wb_mux;
    input [1:0]       sel;
    input [31:0]  alu_result;
    input [31:0]  mem_rdata;
    input [31:0]  pc_plus4;
    begin
      case (sel)
        2'b00: wb_mux = alu_result;
        2'b01: wb_mux = mem_rdata;
        2'b10: wb_mux = pc_plus4;
        default: wb_mux = alu_result; // 其他保留 → 當作 ALU
      endcase
    end
  endfunction

  // 組合邏輯：決定下一態
  always @(*) begin
    // 預設保持
    valid_d    = valid_q;
    rd_d       = rd_q;
    rd_wen_d   = rd_wen_q;
    wb_wdata_d = wb_wdata_q;

    if (i_flush) begin
      // flush -> 氣泡
      valid_d   = 1'b0;
      rd_wen_d  = 1'b0;
    end
    else if (!i_stall) begin
      // 正常推進
      valid_d    = i_valid;
      rd_d       = i_rd;
      rd_wen_d   = i_valid ? i_rd_wen : 1'b0;
      wb_wdata_d = wb_mux(i_wb_sel, i_alu_result, i_mem_rdata, i_pc_plus4);
    end
    // else stall -> 保持
  end

  // 時序邏輯：鎖存狀態
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_q    <= 1'b0;
      rd_q       <= 5'b0;
      rd_wen_q   <= 1'b0;
      wb_wdata_q <= {32{1'b0}};
    end else begin
      valid_q    <= valid_d;
      rd_q       <= rd_d;
      rd_wen_q   <= rd_wen_d;
      wb_wdata_q <= wb_wdata_d;
    end
  end

  // 對外輸出
  assign o_valid    = valid_q;
  assign o_rd       = rd_q;
  assign o_rd_wen   = rd_wen_q & valid_q; // 保險：只有有效拍才寫回
  assign o_wb_wdata = wb_wdata_q;

endmodule
