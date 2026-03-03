`timescale 1ns/1ps

// Writable project-specific wrapper around the generated Clocking Wizard IP.
// - Synthesis: uses `clk_wiz_0`
// - Simulation: falls back to a pass-through model so local regression can
//   run without vendor MMCM netlists

module clock_bridge (
  input  wire clk_in,
  input  wire rst,
  output wire clk_sys_o,
  output wire clk_ref_o,
  output wire locked_o
);


  wire clk_out1_w;
  wire clk_out2_w;
  wire locked_w;

  clk_wiz_0 u_clk_wiz (
    .clk_out1 (clk_out1_w),
    .clk_out2 (clk_out2_w),
    .reset    (rst),
    .locked   (locked_w),
    .clk_in1  (clk_in)
  );

  assign clk_sys_o = clk_out1_w;
  assign clk_ref_o = clk_out2_w;
  assign locked_o  = locked_w;


endmodule
