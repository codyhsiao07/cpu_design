// pc.v -- RV32I, 4-byte aligned PC, no I-Cache inside this block
module pc (
  input         clk,
  input         rst_n,

  // Pipeline control
  input         stall_i,            // IF structural/hazard stall
  input         redirect_valid_i,   // Branch/jump redirect valid
  input  [31:0] redirect_pc_i,      // Branch/jump redirect target

  output [31:0] pc_o                // Current PC (to IMEM)
);

  // Parameters: reset PC value
  parameter RESET_PC = 32'h1000_0000;

  reg [31:0] pc_q;   // Current PC
  reg [31:0] pc_d;   // Next PC

  // 4-byte alignment helper
  function [31:0] align4;
    input [31:0] a;
    begin
      align4 = {a[31:2], 2'b00};
    end
  endfunction

  // Next PC selection
  always @(*) begin
    if (redirect_valid_i)
      pc_d = align4(redirect_pc_i);
    else if (stall_i)
      pc_d = pc_q;              // Hold on stall
    else
      pc_d = pc_q + 32'd4;      // Sequential fetch
  end

  // PC register (async reset low)
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      pc_q <= RESET_PC;
    else
      pc_q <= pc_d;
  end

  assign pc_o = pc_q;

endmodule

