`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date:    00:18:09 03/30/2012 
// Design Name: 
// Module Name:    clkdiv 
// Project Name: 
// Target Devices: 
// Tool versions: 
// Description: 
//
// Dependencies: 
//
// Revision: 
// Revision 0.01 - File Created
// Additional Comments: 
//
//////////////////////////////////////////////////////////////////////////////////
module clkdiv (
input wire mclk ,
input wire clr ,
output wire clk25
);
reg [23:0] q = 24'd0;
// 24-bit counter
always @(posedge mclk or posedge clr)
begin
if(clr == 1)
q <= 0;
else
q <= q + 1;
end
assign clk25 = q[1]; // 25 MHz from 100Mhz clk
endmodule
