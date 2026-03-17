`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date:    15:46:46 04/02/2012 
// Design Name: 
// Module Name:    vga_initials 
// Project Name: 
// Target Devices: Xilinx Basys3
// Tool versions: 
// Description: Codes are modified based on "Digital Design-Using Digilent FPGA Boards"
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
module vga_initials(
    input wire vidon,
    input wire [9:0] hc,
    input wire [9:0] vc,
    input wire [15:0] M,
    input wire [7:0] sw,
    output wire [12:0] rom_addr,
    output reg [3:0] red,
    output reg [3:0] green,
    output reg [3:0] blue
    );
	
	 parameter hpixels = 10'd800;
	 parameter vlines = 10'd525;
	 parameter hbp = 10'd144;
			//Horizontal visible region begins after 96 sync + 48 back porch
	 parameter vbp = 10'd35;
			//Vertical visible region begins after 2 sync + 33 back porch
	 parameter FB_W = 160;
	 parameter FB_H = 120;
	 parameter SCALE_SHIFT = 2;
	 parameter WORDS_PER_ROW = 40;
	 parameter W = 640;
	 parameter H = 480;
	 parameter X_BASE = 0;
	 parameter Y_BASE = 0;
	 wire [9:0] C1, R1;
	 wire [9:0] hc_next, vc_next;
	 wire [9:0] hc_adjust, vc_adjust;
	 wire [9:0] fetch_hc_adjust, fetch_vc_adjust;
	 wire [9:0] fb_hc;
	 wire [9:0] fb_vc;
	 wire [9:0] fetch_fb_hc;
	 wire [9:0] fetch_fb_vc;
	 wire [12:0] fetch_row_base;
	 wire [12:0] fetch_col_word;
	 wire window_on;
	 wire fetch_window_on;
	 reg [3:0] pixel_color;
	 reg [11:0] rgb;
	 
	 assign C1 = X_BASE + {6'b000000, sw[3:0]};
	 assign R1 = Y_BASE + {6'b000000, sw[7:4]};

	 assign hc_next = (hc == hpixels - 1) ? 10'd0 : hc + 10'd1;
	 assign vc_next = (hc == hpixels - 1) ?
	                  ((vc == vlines - 1) ? 10'd0 : vc + 10'd1) :
	                  vc;
	 
	 assign window_on =
	     vidon &&
	     (hc >= hbp + C1) && (hc < hbp + C1 + W) &&
	     (vc >= vbp + R1) && (vc < vbp + R1 + H);

	 assign fetch_window_on =
	     (hc_next >= hbp + C1) && (hc_next < hbp + C1 + W) &&
	     (vc_next >= vbp + R1) && (vc_next < vbp + R1 + H);

	 assign vc_adjust = window_on ? (vc - vbp - R1) : 10'd0;
	 assign hc_adjust = window_on ? (hc - hbp - C1) : 10'd0;
	 assign fetch_vc_adjust = fetch_window_on ? (vc_next - vbp - R1) : 10'd0;
	 assign fetch_hc_adjust = fetch_window_on ? (hc_next - hbp - C1) : 10'd0;
	 assign fb_hc = hc_adjust >> SCALE_SHIFT;
	 assign fb_vc = vc_adjust >> SCALE_SHIFT;
	 assign fetch_fb_hc = fetch_hc_adjust >> SCALE_SHIFT;
	 assign fetch_fb_vc = fetch_vc_adjust >> SCALE_SHIFT;

	 // Prefetch the next pixel word so synchronous BRAM data is aligned when the pixel is displayed.
	 assign fetch_row_base = fetch_fb_vc * WORDS_PER_ROW;
	 assign fetch_col_word = fetch_fb_hc[9:2];
	 assign rom_addr = fetch_window_on ? (fetch_row_base + fetch_col_word) : 13'd0;
		
	//Output video color signals
	
	always @(*)
		begin 
			case (fb_hc[1:0])
				2'b00: pixel_color = M[15:12];
				2'b01: pixel_color = M[11:8];
				2'b10: pixel_color = M[7:4];
				default: pixel_color = M[3:0];
			endcase

			rgb = 12'h000;
			if (window_on)
				begin
					case (pixel_color)
						4'h0: rgb = 12'h112;
						4'h1: rgb = 12'hc74;
						4'h2: rgb = 12'h5b8;
						4'h3: rgb = 12'h4a8;
						4'h4: rgb = 12'hda6;
						4'h5: rgb = 12'h6aa;
						4'h6: rgb = 12'h4bc;
						4'h7: rgb = 12'heee;
						4'h8: rgb = 12'h243;
						4'h9: rgb = 12'h476;
						4'ha: rgb = 12'h113;
						4'hb: rgb = 12'hb98;
						4'hc: rgb = 12'h445;
						4'hd: rgb = 12'h286;
						4'he: rgb = 12'h9ab;
						4'hf: rgb = 12'hfd6;
						default: rgb = 12'h000;
					endcase
				end

			red = rgb[11:8];
			green = rgb[7:4];
			blue = rgb[3:0];
		end
	 
endmodule
