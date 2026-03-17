`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date:    15:17:24 04/02/2012 
// Design Name: 
// Module Name:    vga_initials_top 
// Project Name: 
// Target Devices: Xilinx Basys3
// Tool versions: 
// Description: Codes from Digital Design-Using Digilent FPGA Boards
//              Verilog/Active-HDL Edition
//              by Richard E. Haskell & Darrin M. Hanna
//
// Dependencies: 
//
// Revision: 
// Revision 0.01 - File Created
// Additional Comments: 
//
//////////////////////////////////////////////////////////////////////////////////
// `include "../VGA2_basys3/vga_640x480.v"
// `include "../VGA2_basys3/vga_initials.v"
// `include "../VGA2_basys3/clkdiv.v"
module vga_initials_top(
    input wire mclk,
    input wire clr,
    input wire [15:0] memory_data,
    //input wire [7:0] sw, adjust for the frame buffer coordinate
    output wire hsync,
    output wire vsync,
    output wire [3:0] red,
    output wire [3:0] green,
    output wire [3:0] blue,
    output wire [12:0] memory_address
    );
wire clk25, vidon;
wire [9:0] hc, vc;


clkdiv U1 (.mclk(mclk), .clr(clr), .clk25(clk25));
	 
vga_640x480 U2 (.clk(clk25), .clr(clr),
					 .hsync(hsync), .vsync(vsync),
					 .hc(hc), .vc(vc),
					 .vidon(vidon));
	 
vga_initials U3 (.vidon(vidon), .hc(hc), .vc(vc), 
					  .M(memory_data), 
					  .sw(8'h00), 
					  .rom_addr(memory_address), 
					  .red(red), 
					  .green(green), 
					  .blue(blue));
// Centered by default. `sw` provides a small positive X/Y offset for bring-up if needed.

//prom_DMH U4 (.addr(rom_addr4), .M(M));
//for testing purpose
endmodule
