// ================================================================
// branch_predictor.v
// Simple 2-bit saturating counter Pattern History Table (PHT)
// PC-indexed, suitable for 5-stage pipeline
// ================================================================

module branch_predictor #(
  parameter PHT_BITS = 8   // number of entries = 2^PHT_BITS
)(
  input         clk,
  input         rst_n,

  // -------- Lookup port (IF / ID) --------
  input  [31:0] pc_lookup_i,
  output        pred_taken_o,

  // -------- Update port (EX) --------
  input         update_valid_i,
  input  [31:0] pc_update_i,
  input         actual_taken_i
);

  localparam PHT_ENTRIES = (1 << PHT_BITS);

  // 2-bit saturating counters
  // 00: strongly not taken
  // 01: weakly  not taken
  // 10: weakly  taken
  // 11: strongly taken
  reg [1:0] pht [0:PHT_ENTRIES-1];

  // Index extraction (ignore 2 LSB due to 4-byte alignment)
  wire [PHT_BITS-1:0] lookup_idx =
      pc_lookup_i[2 + PHT_BITS - 1 : 2];

  wire [PHT_BITS-1:0] update_idx =
      pc_update_i[2 + PHT_BITS - 1 : 2];

  // -------- Lookup logic --------
  // MSB of counter decides direction
  assign pred_taken_o = pht[lookup_idx][1];

  // -------- Update logic --------
  integer i;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // Initialize PHT to weakly not taken (01)
      for (i = 0; i < PHT_ENTRIES; i = i + 1)
        pht[i] <= 2'b01;
    end else if (update_valid_i) begin
      case (pht[update_idx])
        2'b00: pht[update_idx] <= actual_taken_i ? 2'b01 : 2'b00;
        2'b01: pht[update_idx] <= actual_taken_i ? 2'b10 : 2'b00;
        2'b10: pht[update_idx] <= actual_taken_i ? 2'b11 : 2'b01;
        2'b11: pht[update_idx] <= actual_taken_i ? 2'b11 : 2'b10;
        default: pht[update_idx] <= 2'b01;
      endcase
    end
  end

endmodule