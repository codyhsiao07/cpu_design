// ex_mem_reg.v — EX/MEM pipeline register
// 把 EX 階段的 ALU 結果、分支訊號、存取控制 等等寄存，送到 MEM 階段。

module ex_mem_reg (
  input         clk,
  input         rst_n,

  // pipeline control
  input         stall_i,   // 卡住：保持不變
  input         flush_i,   // 清空：轉成安全值
  input         ex_valid_i,

  // ====== 來自 EX 階段 ======
  input  [31:0] ex_pc4_i,         // PC+4 (for JAL/JALR 回寫)
  input  [31:0] ex_alu_result_i,  // ALU 計算結果
  input  [31:0] ex_store_data_i,  // rs2，寫記憶體用
  input  [4:0]  ex_rd_i,          // 目的暫存器
  input         ex_reg_write_i,   // 是否要寫回
  input  [1:0]  ex_wb_sel_i,      // WB multiplexer 選擇
  input         ex_mem_read_i,    // 是否要做 memory read
  input         ex_mem_write_i,   // 是否要做 memory write
  input  [2:0]  ex_mem_funct3_i,    

  // ====== 輸出到 MEM 階段 ======
  output [31:0] mem_pc4_o,
  output [31:0] mem_alu_result_o,
  output [31:0] mem_store_data_o,
  output [4:0]  mem_rd_o,
  output        mem_reg_write_o,
  output [1:0]  mem_wb_sel_o,
  output        mem_mem_read_o,
  output        mem_mem_write_o,
  output [2:0]  mem_size_o,

  output        mem_valid_o
);

  // pipeline registers
  reg [31:0] pc4_q, alu_q, store_q;
  reg [4:0]  rd_q;
  reg        reg_wr_q, mem_rd_q, mem_wr_q;
  reg [1:0]  wb_sel_q;
  reg        valid_q;
  reg [2:0] mem_f3_q;
  wire [2:0] mem_f3_d = flush_i ? 3'b010 : (stall_i ? mem_f3_q : ex_mem_funct3_i);

  // next-state logic（stall / flush 處理）
  wire [31:0] pc4_d    = flush_i ? 32'b0 : (stall_i ? pc4_q   : ex_pc4_i);
  wire [31:0] alu_d    = flush_i ? 32'b0 : (stall_i ? alu_q   : ex_alu_result_i);
  wire [31:0] store_d  = flush_i ? 32'b0 : (stall_i ? store_q : ex_store_data_i);
  wire [4:0]  rd_d     = flush_i ? 5'b0  : (stall_i ? rd_q    : ex_rd_i);

  wire reg_wr_d        = flush_i ? 1'b0  : (stall_i ? reg_wr_q : ex_reg_write_i);
  wire [1:0] wb_sel_d  = flush_i ? 2'b00 : (stall_i ? wb_sel_q : ex_wb_sel_i);
  wire mem_rd_d        = flush_i ? 1'b0  : (stall_i ? mem_rd_q : ex_mem_read_i);
  wire mem_wr_d        = flush_i ? 1'b0  : (stall_i ? mem_wr_q : ex_mem_write_i);
  wire valid_d         = flush_i ? 1'b0  : (stall_i ? valid_q  : ex_valid_i);

  // 寄存器
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc4_q     <= 32'b0;
      alu_q     <= 32'b0;
      store_q   <= 32'b0;
      rd_q      <= 5'b0;
      reg_wr_q  <= 1'b0;
      wb_sel_q  <= 2'b00;
      mem_rd_q  <= 1'b0;
      mem_wr_q  <= 1'b0;
      valid_q   <= 1'b0;
      mem_f3_q <= 3'b010;
    end else begin
      pc4_q     <= pc4_d;
      alu_q     <= alu_d;
      store_q   <= store_d;
      rd_q      <= rd_d;
      reg_wr_q  <= reg_wr_d;
      wb_sel_q  <= wb_sel_d;
      mem_rd_q  <= mem_rd_d;
      mem_wr_q  <= mem_wr_d;
      valid_q   <= valid_d;
      mem_f3_q <= mem_f3_d;
    end
  end

  // output
  assign mem_pc4_o        = pc4_q;
  assign mem_alu_result_o = alu_q;
  assign mem_store_data_o = store_q;
  assign mem_rd_o         = rd_q;
  assign mem_reg_write_o  = reg_wr_q;
  assign mem_wb_sel_o     = wb_sel_q;
  assign mem_mem_read_o   = mem_rd_q;
  assign mem_mem_write_o  = mem_wr_q;
  assign mem_valid_o      = valid_q;
  assign mem_size_o = mem_f3_q;

endmodule
