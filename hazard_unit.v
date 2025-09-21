// hazard_unit.v -- Pipeline hazard/control unit (commented)
//
// Goals (without forwarding):
// - Control hazards: when EX decides a redirect (taken branch/jump), flush younger stages.
// - Structural/Memory stalls: when MEM is busy, hold upstream stages.
// - Data hazards:
//   * Load-use: if ID uses a register that EX will load to, insert one bubble
//     (stall IF/ID for 1 cycle and flush ID/EX) -- classic single-cycle interlock.
//   * Generic RAW w/o forwarding: if ID depends on a value still in EX or MEM
//     (producer not yet at WB), stall IF/ID until the hazard clears.
//     We do NOT stall EX for data RAW (let older instructions drain), only for MEM backpressure.
module hazard_unit (
  // ===== ID stage (current instruction) =====
  input        id_valid_i,
  input  [4:0] id_rs1_i,
  input  [4:0] id_rs2_i,

  // ===== EX stage (instruction in execute) =====
  input        ex_valid_i,
  input  [4:0] ex_rd_i,
  input        ex_reg_write_i,
  input        ex_mem_read_i,  // 1 if EX instr is a LOAD

  // ===== MEM stage =====
  input        mem_valid_i,
  input  [4:0] mem_rd_i,
  input        mem_reg_write_i,
  input        mem_stall_i,    // memory/back-end is busy

  // ===== IF structural stall (I-cache miss) =====
  input        ifetch_stall_i,

  // ===== Redirect from EX (branch/jump taken) =====
  input        redirect_valid_i,

  // ===== Outputs to pipeline registers =====
  output       stall_if_o,
  output       stall_id_o,
  output       stall_ex_o,
  output       stall_exmem_o,

  output       flush_ifid_o,
  output       flush_idex_o
);

  // ---------- Helpers ----------
  wire id_use_rs1 = (id_rs1_i != 5'd0);
  wire id_use_rs2 = (id_rs2_i != 5'd0);

  // RAW against EX destination
  wire raw_ex_rs1 = id_use_rs1 && (id_rs1_i == ex_rd_i);
  wire raw_ex_rs2 = id_use_rs2 && (id_rs2_i == ex_rd_i);
  wire raw_ex     = ex_valid_i && (ex_rd_i != 5'd0) && (raw_ex_rs1 | raw_ex_rs2);

  // RAW against MEM destination
  wire raw_mem_rs1 = id_use_rs1 && (id_rs1_i == mem_rd_i);
  wire raw_mem_rs2 = id_use_rs2 && (id_rs2_i == mem_rd_i);
  wire raw_mem     = mem_valid_i && (mem_rd_i != 5'd0) && (raw_mem_rs1 | raw_mem_rs2);

  // Classic load-use (EX is a load and ID consumes rd)
  wire load_use_hazard = raw_ex && ex_mem_read_i;

  // Generic RAW without forwarding: hazard on EX or MEM producers that will write back
  // Note: WB-stage hazard is allowed (write happens same cycle as ID read in typical timing),
  // so we don't stall for WB.
  wire generic_raw = (raw_ex && ex_reg_write_i) | (raw_mem && mem_reg_write_i);

  // ---------- Stall logic ----------
  // - Always propagate memory backpressure upstream.
  // - For data hazards:
  //   * load-use: stall IF/ID one cycle (bubble inserted via flush_idex_o)
  //   * generic RAW (no fwd): stall IF/ID until producer moves to WB
  // With forwarding in place, generic RAW (ALU->ALU/PC4) can be resolved
  // via MEM or WB forwarding without stalls. Only load-use still needs one bubble.
  wire stall_for_data = load_use_hazard;

  wire structural_stall = mem_stall_i | ifetch_stall_i;

  assign stall_if_o    = structural_stall | stall_for_data;
  assign stall_id_o    = structural_stall | stall_for_data;

  // Do not stall EX for data RAW; let older instructions drain.
  assign stall_ex_o    = structural_stall;
  assign stall_exmem_o = structural_stall;

  // ---------- Flush logic ----------
  // - redirect: flush IF/ID and ID/EX to discard wrong-path instructions
  // - load-use: flush ID/EX to insert a bubble
  assign flush_ifid_o = redirect_valid_i;
  assign flush_idex_o = redirect_valid_i | load_use_hazard;

endmodule
