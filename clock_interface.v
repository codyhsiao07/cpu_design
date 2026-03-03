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
