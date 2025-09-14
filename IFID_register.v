module if_id_reg (
  input         clk,
  input         rst_n,

  // 控制
  input         stall_i,   // 停住: 保持上個值
  input         flush_i,   // 清空: 輸出變成 NOP

  // 來自 IF 的訊號
  input  [31:0] if_pc_i,
  input  [31:0] if_instr_i,
  input         if_valid_i,

  // 給 ID 的訊號
  output [31:0] id_pc_o,
  output [31:0] id_instr_o,
  output        id_valid_o
);

  // RV32I 的 NOP = ADDI x0, x0, 0 = 0x00000013
  localparam [31:0] INSTR_NOP = 32'h00000013;//只在模組內使用

  reg [31:0] pc_q, instr_q;
  reg        valid_q;

  // 下一拍值的決策
  wire [31:0] pc_d     = flush_i ? 32'b0        : (stall_i ? pc_q     : if_pc_i);
  wire [31:0] instr_d  = flush_i ? INSTR_NOP    : (stall_i ? instr_q  : if_instr_i);
  wire        valid_d  = flush_i ? 1'b0         : (stall_i ? valid_q  : if_valid_i);

  // 寄存器（rst_n 為低態有效）
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc_q    <= 32'b0;
      instr_q <= INSTR_NOP;
      valid_q <= 1'b0;
    end else begin
      pc_q    <= pc_d;
      instr_q <= instr_d;
      valid_q <= valid_d;
    end
  end

  assign id_pc_o    = pc_q;
  assign id_instr_o = instr_q;
  assign id_valid_o = valid_q;

endmodule
