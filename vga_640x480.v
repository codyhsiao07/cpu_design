`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date:    11:19:34 03/28/2012 
// Design Name: 
// Module Name:    vga_640x480 
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
module vga_640x480(
    input wire clk,
    input wire clr,
    output reg hsync = 1'b1,
    output reg vsync = 1'b1,
    output reg [9:0] hc = 10'd0,
    output reg [9:0] vc = 10'd0,
    output reg vidon = 1'b0
    );
	 parameter hpixels = 10'd800;
	 //Value of pixels in a horizontal line = 800
	 parameter vlines  = 10'd525;
	 //Number of lines in the display = 525
	 parameter hbp     = 10'd144;
	 //Horizontal visible region begins after 96 sync + 48 back porch
	 parameter hfp     = 10'd784;
	 //Horizontal visible region ends after 640 active pixels
	 parameter vbp     = 10'd35;
	 //Vertical visible region begins after 2 sync + 33 back porch
	 parameter vfp     = 10'd515;
	 //Vertical visible region ends after 480 active lines
	 
	 //Counter for the horizontal sync signal
	 
	 always @(posedge clk or posedge clr)
		begin
			if(clr == 1)
			    hc <= 0;
			else
				begin
					if(hc == hpixels - 1)
						begin
							//The counter has reached the end of pixel count
							hc <= 0;   // reset the counter
						end
					else 
						begin 
							hc <= hc + 1;   //Increment the horizontal counter
						end
				end
		end
		
	//Generate hsync pulse
	//Horizontal sync pulse is low for 96 pixel clocks
	always @(*)
		begin 
			if(hc < 96)
				hsync = 0;
			else
				hsync = 1;
		end
	//Counter for the vertical sync signal
	always @(posedge clk or posedge clr)
		begin
			if (clr == 1)
				 vc <= 0;
			else 
				if(hc == hpixels - 1)
					begin
						if (vc == vlines - 1)
							//Reset when the number of lines is reached
							 vc <= 0;
						else
							 vc <= vc + 1; // Increment vertical counter
					end
		end
		
		
	//Generate vsync pulse
	//Verical Sync Pulse is low when hc is 0 or 1
	always @(*)
		begin 
			if(vc < 2)
				vsync = 0;
			else
				vsync = 1;
		end
		
		
	//Enable video out when within the porches
	always @(*)
		begin
			if((hc >= hbp) && (hc < hfp) && (vc >= vbp) && (vc < vfp))
				vidon = 1;
			else
				vidon = 0;
		end
		
endmodule
