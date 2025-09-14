// wb_stage.v
// Write-Back stage (Verilog-2001)
// - 從 MEM/WB 暫存器接收：有效位、目的暫存器、寫回允許、寫回資料
// - 產生：暫存器檔寫回訊號，以及（可選）WB 旁路訊號
module wb_stage(
  input               clk,
  input               rst_n,

  // from MEM/WB pipeline register
  input               i_valid,       // 此拍 WB 是否有有效指令
  input        [4:0]  i_rd,          // 目的暫存器編號
  input               i_rd_wen,      // 是否需要寫回（由 ID decode 一路傳下來）
  input  [31:0]   i_wb_wdata,    // 寫回資料（已由 MEM/WB mux 選好）

  // to Register File (寫回埠)
  output              rf_we_o,       // regfile write enable
  output       [4:0]  rf_waddr_o,    // regfile write addr
  output [31:0]   rf_wdata_o,    // regfile write data

  // (optional) forwarding/bypass 給前段使用
  output              wb_fwd_valid_o,
  output       [4:0]  wb_fwd_rd_o,
  output [31:0]   wb_fwd_data_o
);
  parameter XLEN = 32;
  // 不寫 x0：RISC-V 要避免對 x0 進行寫入
  wire rd_is_x0   = (i_rd == 5'd0);
  wire do_write   = i_valid & i_rd_wen & ~rd_is_x0;

  // 寫回到暫存器檔
  assign rf_we_o     = do_write;
  assign rf_waddr_o  = i_rd;
  assign rf_wdata_o  = i_wb_wdata;

  // 提供 WB 旁路：只有當本拍真的會寫回且 rd!=0 才算有效
  assign wb_fwd_valid_o = do_write;
  assign wb_fwd_rd_o    = i_rd;
  assign wb_fwd_data_o  = i_wb_wdata;

  // （可選）你也可以在這裡加入簡單的偵錯訊號或計數器
  // 例如計數實際寫回次數，或是當 i_rd_wen=1 但 i_valid=0 時做覆核等。
  // 為了保持模組精簡，這裡不加時序暫存。

endmodule

