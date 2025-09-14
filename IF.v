// pc.v — RV32I, 4-byte aligned, no I-Cache
module pc (
  input         clk,
  input         rst_n,

  // pipeline control
  input         stall_i,            // IF 停住 (cache miss / hazard 等)
  input         redirect_valid_i,   // 分支/跳躍有效
  input  [31:0] redirect_pc_i,      // 分支/跳躍目標

  output [31:0] pc_o                // 當前 PC (送到 IMEM)
);

  // 固定參數：重置起始位址
  parameter RESET_PC = 32'h1000_0000;

  reg [31:0] pc_q;   // 暫存 PC
  reg [31:0] pc_d;   // 下一個 PC

  // 對齊函數 (4-byte)
  function [31:0] align4;
    input [31:0] a;
    begin
      align4 = {a[31:2], 2'b00};
    end
  endfunction

  // 下一個 PC 的選擇
  always @(*) begin
    if (redirect_valid_i)
      pc_d = align4(redirect_pc_i);
    else if (stall_i)
      pc_d = pc_q;              // 停住不變
    else
      pc_d = pc_q + 32'd4;      // 預設順序取指
  end

  // PC 暫存器（rst_n 為低態有效）
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      pc_q <= RESET_PC;
    else
      pc_q <= pc_d;
  end

  assign pc_o = pc_q;

endmodule
