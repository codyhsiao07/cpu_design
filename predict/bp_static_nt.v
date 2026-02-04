// bp_static_nt.v — Static branch predictor: always not taken
// - Predicts next PC as sequential (PC+4)
// - For observability, exposes a mispredict pulse when EX redirects
// - This integrates seamlessly with an EX-stage redirect pipeline
module bp_static_nt (
  input         clk,
  input         rst_n,

  // IF stage context (optional for future use)
  input  [31:0] if_pc_i,
  input  [31:0] if_instr_i,
  input         if_valid_i,

  // Actual redirect decision from EX stage
  input         ex_redirect_valid_i,

  // Predicted outcome/target
  output        pred_taken_o,     // 0: not taken
  output [31:0] pred_target_o,    // PC+4
  output        pred_valid_o,

  // Simple observability: 1 when our prediction is wrong this cycle
  output        pred_mispredict_o
);

  assign pred_taken_o      = 1'b0;
  assign pred_target_o     = if_pc_i + 32'd4;
  assign pred_valid_o      = if_valid_i;

  // In a static not-taken predictor, any redirect indicates a mispredict
  assign pred_mispredict_o = ex_redirect_valid_i;

endmodule

