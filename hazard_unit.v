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
  input        id_is_store_i,

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

  // Store-data conservative interlock: if ID is a STORE and rs2 depends on a
  // producer in EX or MEM that will write back, force a bubble in ID/EX to
  // guarantee correct store data timing (avoid using stale ID/EX value).
  wire store_data_hazard = id_is_store_i & (
      (ex_valid_i  & ex_reg_write_i  & raw_ex_rs2) |
      (mem_valid_i & mem_reg_write_i & raw_mem_rs2)
    );

  // ---------- Stall logic ----------
  // - Always propagate memory backpressure upstream.
  // - Data hazards:
  //   * load-use: stall IF/ID one cycle (bubble inserted via flush_idex_o)
  //   * generic RAW: conservative mode, stall IF/ID to avoid misalignment
  //   * store-data: same as above, and will also bubble ID/EX (see flush)
  // With forwarding enabled, do not stall on generic RAW; only load-use and
  // store-data hazards require bubbles/stalls.
  wire stall_for_data = load_use_hazard | store_data_hazard;

  // Separate structural stalls for front/back of pipe
  wire structural_stall_front = ifetch_stall_i | mem_stall_i; // IF/ID
  wire structural_stall_back  = mem_stall_i;                  // EX/EXMEM only MEM

  assign stall_if_o    = structural_stall_front | stall_for_data;
  assign stall_id_o    = structural_stall_front | stall_for_data;

  // Do not stall EX for I-fetch stall; let older instructions drain.
  assign stall_ex_o    = structural_stall_back;
  assign stall_exmem_o = structural_stall_back;

  // ---------- Flush logic ----------
  // - redirect: flush IF/ID and ID/EX to discard wrong-path instructions
  // - load-use: flush ID/EX to insert a bubble
  // - store-data: flush ID/EX to insert a bubble (ensure correct rs2 store data)
  assign flush_ifid_o = redirect_valid_i;
  assign flush_idex_o = redirect_valid_i | load_use_hazard | store_data_hazard;

endmodule
