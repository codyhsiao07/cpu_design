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
module hazard_unit #(
  // 1: assumes forwarding in EX is available; only stall for load-use/pending load
  // 0: no forwarding; stall on any RAW hazard
  parameter FORWARDING_EN = 1'b1,
  // 1: stall front-end whenever any pending load exists (very conservative)
  parameter STALL_ON_ANY_PENDING_LOAD = 1'b0
) (
  // ===== ID stage (current instruction) =====
  input        id_valid_i,//ID 這拍是不是一條真的指令
  input  [4:0] id_rs1_i,//第一個 source register
  input  [4:0] id_rs2_i,//第二個 source register
  input        id_is_store_i,//這條 ID 指令是不是 store

  // ===== EX stage (instruction in execute) =====
  input        ex_valid_i,//指令有效性
  input  [4:0] ex_rd_i,//EX stage 指令的目的暫存器 rd
  input        ex_reg_write_i,//EX stage 這條指令「最終會不會寫回 register file」。
  //add/lw/jal → 1
  //sw/branch → 0
  input        ex_mem_read_i,  // EX stage 這條指令是不是「load 類
  
  input        ex_stall_req_i,
  // ===== MEM stage =====
  input        mem_valid_i,//指令有效性
  input  [4:0] mem_rd_i,//MEM stage 指令目的寄存器 rd。用途同 ex_rd_i
  input        mem_reg_write_i,//MEM stage 指令是否會寫回。用途同 ex_reg_write_i
  input        mem_stall_i,       // memory/back-end is busy MEM stage（含 D$、write buffer、或更後級）這拍不能接受/推進 pipeline
  input        mem_load_active_i, // MEM stage 此時有一個 load 已經發出去、但資料還沒回來
  input  [31:0] pending_load_mask_i,//哪些 register 的值還沒 ready (無使用，預設為0)

  // ===== IF structural stall (I-cache miss) =====
  input        ifetch_stall_i,//前端取指被 I$ 卡住

  // ===== Redirect from EX (branch/jump taken) =====
  input        redirect_valid_i,//EX 決定改 PC：branch taken/jump/jalr
  //也就是 PC 將被覆寫到新 target，原本 IF/ID/IDEX 中 younger 指令都是錯路徑

  // ===== Outputs to pipeline registers =====
  output       stall_if_o,//freeze PC/IF stage
  output       stall_id_o,//freeze IF/ID pipeline register
  output       stall_ex_o,//freeze ID/EX pipeline register
  output       stall_exmem_o,//freeze EX/MEM pipeline register

  output       flush_ifid_o,//清掉 IF/ID（丟掉錯路徑指令）
  output       flush_idex_o//清掉 ID/EX（插 bubble）
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

  // Generic RAW hazard on EX or MEM producers that will write back
  // (used only when forwarding is disabled).
  // Note: WB-stage hazard is allowed (write happens same cycle as ID read).
  wire generic_raw = (raw_ex && ex_reg_write_i) | (raw_mem && mem_reg_write_i);

  // MEM-stage load still pending (data not ready for forwarding)
  wire mem_pending_load_hazard = raw_mem && mem_load_active_i;

  // Outstanding load scoreboard (load left EX but has not returned data yet)
  wire pending_load_rs1 = id_use_rs1 && pending_load_mask_i[id_rs1_i];
  wire pending_load_rs2 = id_use_rs2 && pending_load_mask_i[id_rs2_i];
  wire pending_load_any = |pending_load_mask_i;
  wire pending_load_hazard = pending_load_rs1 | pending_load_rs2 |
                             (STALL_ON_ANY_PENDING_LOAD & pending_load_any);

  // ---------- Stall logic ----------
  // - Always propagate memory backpressure upstream.
  // - Data hazards:
  //   * load-use: stall IF/ID one cycle (bubble inserted via flush_idex_o)
  //   * generic RAW: conservative mode, stall IF/ID to avoid misalignment
  //   * store-data: same as above, and will also bubble ID/EX (see flush)
  // With forwarding enabled, do not stall on generic RAW; only load-use and
  // store-data hazards require bubbles/stalls.
  wire stall_for_data = load_use_hazard |
                        mem_pending_load_hazard |
                        pending_load_hazard |
                        ((~FORWARDING_EN) & generic_raw);

  // Separate structural stalls for front/back of pipe
  wire structural_stall_front = ifetch_stall_i | mem_stall_i; // IF/ID
  wire structural_stall_back  = mem_stall_i;                  // EX/EXMEM only MEM

  wire ex_long_stall = ex_stall_req_i;

  assign stall_if_o    = structural_stall_front | stall_for_data | ex_long_stall;
  assign stall_id_o    = structural_stall_front | stall_for_data | ex_long_stall;

  // EX mul/div running: hold ID/EX so the same instruction stays in EX
  assign stall_ex_o    = structural_stall_back  | ex_long_stall;

  // Also hold EX/MEM so half-finished EX results are not captured downstream
  assign stall_exmem_o = structural_stall_back  | ex_long_stall;

  // ---------- Flush logic ----------
  // - redirect: flush IF/ID and ID/EX to discard wrong-path instructions
  // - load-use: flush ID/EX to insert a bubble
  // - no-forwarding RAW: flush ID/EX to avoid re-issuing same op each cycle
  assign flush_ifid_o = redirect_valid_i;
  assign flush_idex_o = redirect_valid_i | load_use_hazard | ((~FORWARDING_EN) & generic_raw);

`ifndef SYNTHESIS
  always @(*) begin
    if (pending_load_hazard) begin
      $display("[%0t] HAZARD pending load hit rs1=%0d rs2=%0d mask=0x%08x",
               $time, id_rs1_i, id_rs2_i, pending_load_mask_i);
    end
  end
`endif

endmodule