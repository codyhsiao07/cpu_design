`timescale 1ps/1ps

// Read-only style wrapper for the generated Clocking Wizard IP.
// Keep this file as the thin IP-facing shell and place project-specific
// glue logic in a separate wrapper.
(* CORE_GENERATION_INFO = "clk_wiz_0,clk_wiz_v6_0_6_0_0,{component_name=clk_wiz_0,use_phase_alignment=true,use_min_o_jitter=false,use_max_i_jitter=false,use_dyn_phase_shift=false,use_inclk_switchover=false,use_dyn_reconfig=false,enable_axi=0,feedback_source=FDBK_AUTO,PRIMITIVE=MMCM,num_out_clk=2,clkin1_period=10.000,clkin2_period=10.000,use_power_down=false,use_reset=true,use_locked=true,use_inclk_stopped=false,feedback_type=SINGLE,CLOCK_MGR_TYPE=NA,manual_override=false}" *)
module clk_wiz_0 (
  output clk_out1,
  output clk_out2,
  input  reset,
  output locked,
  input  clk_in1
);

  clk_wiz_0_clk_wiz inst (
    .clk_out1 (clk_out1),
    .clk_out2 (clk_out2),
    .reset    (reset),
    .locked   (locked),
    .clk_in1  (clk_in1)
  );

endmodule

// Self-contained implementation of the generated Clocking Wizard netlist.
// 100 MHz board clock -> 100 MHz system clock and 200 MHz MIG reference.
// Keeping this module in source control makes board elaboration independent
// of a missing .xci/generated-IP directory.
module clk_wiz_0_clk_wiz (
  output clk_out1,
  output clk_out2,
  input  reset,
  output locked,
  input  clk_in1
);
  wire clk_in1_buf;
  wire clkfb_mmcm;
  wire clkfb_buf;
  wire clkout0_mmcm;
  wire clkout1_mmcm;

  IBUF u_clk_in_buf (
    .I(clk_in1),
    .O(clk_in1_buf)
  );

  MMCME2_BASE #(
    .BANDWIDTH("OPTIMIZED"),
    .CLKFBOUT_MULT_F(10.000),
    .CLKIN1_PERIOD(10.000),
    .CLKOUT0_DIVIDE_F(10.000),
    .CLKOUT1_DIVIDE(5),
    .DIVCLK_DIVIDE(1),
    .STARTUP_WAIT("FALSE")
  ) u_mmcm (
    .CLKFBOUT(clkfb_mmcm),
    .CLKFBOUTB(),
    .CLKOUT0(clkout0_mmcm),
    .CLKOUT0B(),
    .CLKOUT1(clkout1_mmcm),
    .CLKOUT1B(),
    .CLKOUT2(),
    .CLKOUT2B(),
    .CLKOUT3(),
    .CLKOUT3B(),
    .CLKOUT4(),
    .CLKOUT5(),
    .CLKOUT6(),
    .LOCKED(locked),
    .CLKIN1(clk_in1_buf),
    .PWRDWN(1'b0),
    .RST(reset),
    .CLKFBIN(clkfb_buf)
  );

  BUFG u_clkfb_buf (.I(clkfb_mmcm), .O(clkfb_buf));
  BUFG u_clkout1_buf (.I(clkout0_mmcm), .O(clk_out1));
  BUFG u_clkout2_buf (.I(clkout1_mmcm), .O(clk_out2));
endmodule
