// top.v -- Minimal 5-stage RV32I core top, with external IMEM/DMEM ports
// - Wires: IF -> IF/ID -> ID -> ID/EX -> EX -> EX/MEM -> MEM -> MEM/WB -> WB
// - Exposes simple IMEM (addr->instr) and DMEM (handshake) to testbench
// - Includes hazard_unit for load-use stall, MEM backpressure, and redirect flush
module rv32i_core_top (
  input         clk,
  input         rst_n,

  // Instruction memory (combinational ROM-like interface)
  output [31:0] imem_addr_o,
  input  [31:0] imem_instr_i,

  // Data memory interface (as used by mem_stage)
  output        dmem_req_o,
  output        dmem_we_o,
  output [31:0] dmem_addr_o,
  output [31:0] dmem_wdata_o,
  output [3:0]  dmem_wstrb_o,
  input         dmem_ready_i,
  input         dmem_rvalid_i,
  input  [31:0] dmem_rdata_i,

  // Optional: expose WB commit for TB observation
  output        wb_we_o,
  output [4:0]  wb_rd_o,
  output [31:0] wb_wdata_o
);

  // ================= IF =================
  wire [31:0] if_pc;
  wire        redirect_valid;
  wire [31:0] redirect_pc;
  wire        stall_if, stall_id, stall_ex, stall_exmem;
  wire        flush_ifid, flush_idex;

  pc u_pc (
    .clk              (clk),
    .rst_n            (rst_n),
    .stall_i          (stall_if),
    .redirect_valid_i (redirect_valid),
    .redirect_pc_i    (redirect_pc),
    .pc_o             (if_pc)
  );

  wire [31:0] if_instr;
  wire        icache_stall;
  wire [31:0] icache_mem_addr;

  icache u_icache (
    .clk          (clk),
    .rst_n        (rst_n),
    .fetch_valid_i(~stall_if),
    .fetch_addr_i (if_pc),
    .fetch_data_o (if_instr),
    .fetch_stall_o(icache_stall),
    .mem_addr_o   (icache_mem_addr),
    .mem_rdata_i  (imem_instr_i)
  );

  assign imem_addr_o = icache_mem_addr;

  // IF/ID
  wire [31:0] id_pc;
  wire [31:0] id_instr;
  wire        id_valid;

  if_id_reg u_if_id (
    .clk         (clk),
    .rst_n       (rst_n),
    .stall_i     (stall_id),
    .flush_i     (flush_ifid),
    .if_pc_i     (if_pc),
    .if_instr_i  (if_instr),
    .if_valid_i  (1'b1),
    .id_pc_o     (id_pc),
    .id_instr_o  (id_instr),
    .id_valid_o  (id_valid)
  );

  // Static not-taken branch predictor (observability only; PC already uses sequential fetch)
  // You can tap pred_mispredict/pred_taken for counters or waveform checks.
  wire bp_pred_taken, bp_pred_valid;
  wire [31:0] bp_pred_target;
  wire bp_mispredict;
  bp_static_nt u_bp (
    .clk                 (clk),
    .rst_n               (rst_n),
    .if_pc_i             (if_pc),
    .if_instr_i          (if_instr),
    .if_valid_i          (1'b1),
    .ex_redirect_valid_i (redirect_valid),
    .pred_taken_o        (bp_pred_taken),
    .pred_target_o       (bp_pred_target),
    .pred_valid_o        (bp_pred_valid),
    .pred_mispredict_o   (bp_mispredict)
  );

  // ================= ID =================
  wire [31:0] id_rs1_val, id_rs2_val, id_imm;
  wire [4:0]  id_rs1, id_rs2, id_rd;
  wire [2:0]  id_alu_op;
  wire        id_alu_src_imm, id_branch, id_jal, id_jalr;
  wire        id_mem_read, id_mem_write, id_reg_write;
  wire [1:0]  id_wb_sel;
  wire [2:0]  id_br_funct3;
  wire        id_ready;
  wire        id_shift_right, id_shift_arith, id_is_auipc, id_is_lui;
  wire [2:0]  id_mem_funct3;

  // WB writeback signals (from WB stage to regfile)
  wire        rf_we;
  wire [4:0]  rf_waddr;
  wire [31:0] rf_wdata;

  id_stage u_id (
    .clk              (clk),
    .rst_n            (rst_n),
    .id_pc_i          (id_pc),
    .id_instr_i       (id_instr),
    .id_valid_i       (id_valid),
    .wb_we_i          (rf_we),
    .wb_rd_i          (rf_waddr),
    .wb_wd_i          (rf_wdata),
    .rs1_val_o        (id_rs1_val),
    .rs2_val_o        (id_rs2_val),
    .imm_o            (id_imm),
    .rs1_o            (id_rs1),
    .rs2_o            (id_rs2),
    .rd_o             (id_rd),
    .alu_op_o         (id_alu_op),
    .alu_src_imm_o    (id_alu_src_imm),
    .branch_o         (id_branch),
    .jal_o            (id_jal),
    .jalr_o           (id_jalr),
    .mem_read_o       (id_mem_read),
    .mem_write_o      (id_mem_write),
    .wb_sel_o         (id_wb_sel),
    .reg_write_o      (id_reg_write),
    .br_funct3_o      (id_br_funct3),
    .pc_o             (), // not used beyond ID/EX
    .id_ready_o       (id_ready),
    .id_shift_right_o (id_shift_right),
    .id_shift_arith_o (id_shift_arith),
    .id_is_auipc_o    (id_is_auipc),
    .id_is_lui_o      (id_is_lui),
    .id_mem_funct3_o  (id_mem_funct3)
  );

  // ================= ID/EX =================
  wire [31:0] ex_pc, ex_rs1_val, ex_rs2_val, ex_imm;
  wire [4:0]  ex_rs1, ex_rs2, ex_rd;
  wire [2:0]  ex_alu_op, ex_br_funct3;
  wire        ex_alu_src_imm, ex_branch, ex_jal, ex_jalr;
  wire        ex_mem_read, ex_mem_write, ex_reg_write, ex_valid;
  wire [1:0]  ex_wb_sel;
  wire        ex_shift_right, ex_shift_arith, ex_is_auipc, ex_is_lui;
  wire [2:0]  ex_mem_funct3;

  id_ex_reg u_id_ex (
    .clk              (clk),
    .rst_n            (rst_n),
    .stall_i          (stall_ex),
    .flush_i          (flush_idex),
    .id_valid_i       (id_ready),
    .id_pc_i          (id_pc),
    .id_rs1_val_i     (id_rs1_val),
    .id_rs2_val_i     (id_rs2_val),
    .id_imm_i         (id_imm),
    .id_rs1_i         (id_rs1),
    .id_rs2_i         (id_rs2),
    .id_rd_i          (id_rd),
    .id_alu_op_i      (id_alu_op),
    .id_alu_src_imm_i (id_alu_src_imm),
    .id_branch_i      (id_branch),
    .id_jal_i         (id_jal),
    .id_jalr_i        (id_jalr),
    .id_mem_read_i    (id_mem_read),
    .id_mem_write_i   (id_mem_write),
    .id_wb_sel_i      (id_wb_sel),
    .id_reg_write_i   (id_reg_write),
    .id_br_funct3_i   (id_br_funct3),
    .id_shift_right_i (id_shift_right),
    .id_shift_arith_i (id_shift_arith),
    .id_is_auipc_i    (id_is_auipc),
    .id_is_lui_i      (id_is_lui),
    .id_mem_funct3_i  (id_mem_funct3),
    .ex_mem_funct3_o  (ex_mem_funct3),
    .ex_shift_right_o (ex_shift_right),
    .ex_shift_arith_o (ex_shift_arith),
    .ex_is_auipc_o    (ex_is_auipc),
    .ex_is_lui_o      (ex_is_lui),
    .ex_pc_o          (ex_pc),
    .ex_rs1_val_o     (ex_rs1_val),
    .ex_rs2_val_o     (ex_rs2_val),
    .ex_imm_o         (ex_imm),
    .ex_rs1_o         (ex_rs1),
    .ex_rs2_o         (ex_rs2),
    .ex_rd_o          (ex_rd),
    .ex_alu_op_o      (ex_alu_op),
    .ex_alu_src_imm_o (ex_alu_src_imm),
    .ex_branch_o      (ex_branch),
    .ex_jal_o         (ex_jal),
    .ex_jalr_o        (ex_jalr),
    .ex_mem_read_o    (ex_mem_read),
    .ex_mem_write_o   (ex_mem_write),
    .ex_wb_sel_o      (ex_wb_sel),
    .ex_reg_write_o   (ex_reg_write),
    .ex_br_funct3_o   (ex_br_funct3),
    .ex_valid_o       (ex_valid)
  );

  // ================= EX =================
  wire [31:0] ex_alu_result, ex_store_data, ex_pc4;
  wire        ex_br_taken;
  wire [31:0] ex_br_target;

  // Forward dependencies from later stages for forwarding
  wire        mem_valid;
  wire        mem_reg_write;
  wire [1:0]  mem_wb_sel;
  wire [4:0]  mem_rd;
  wire [31:0] mem_alu_result;
  wire [31:0] mem_pc4;
  wire        wb_rd_wen;
  wire [4:0]  wb_rd;
  wire [31:0] wb_wdata;

  // Forwarding unit: prepare EX operands with bypass from MEM/WB
  wire [31:0] ex_rs1_val_fwd, ex_rs2_val_fwd;
  forward_unit u_fwd (
    .ex_rs1_idx_i     (ex_rs1),
    .ex_rs2_idx_i     (ex_rs2),
    .ex_rs1_val_i     (ex_rs1_val),
    .ex_rs2_val_i     (ex_rs2_val),
    .mem_valid_i      (mem_valid),
    .mem_reg_write_i  (mem_reg_write),
    .mem_wb_sel_i     (mem_wb_sel),
    .mem_rd_i         (mem_rd),
    .mem_alu_result_i (mem_alu_result),
    .mem_pc4_i        (mem_pc4),
    .mem_load_valid_i (mem_load_valid),
    .mem_load_data_i  (mem_load_rdata),
    .wb_we_i          (wb_rd_wen),
    .wb_rd_i          (wb_rd),
    .wb_wdata_i       (wb_wdata),
    .ex_rs1_val_o     (ex_rs1_val_fwd),
    .ex_rs2_val_o     (ex_rs2_val_fwd)
  );

  ex_stage u_ex (
    .ex_pc_i           (ex_pc),
    .ex_rs1_val_i      (ex_rs1_val_fwd),
    .ex_rs2_val_i      (ex_rs2_val_fwd),
    .ex_imm_i          (ex_imm),
    .ex_alu_op_i       (ex_alu_op),
    .ex_alu_src_imm_i  (ex_alu_src_imm),
    .ex_branch_i       (ex_branch),
    .ex_jal_i          (ex_jal),
    .ex_jalr_i         (ex_jalr),
    .ex_br_funct3_i    (ex_br_funct3),
    .ex_shift_right_i  (ex_shift_right),
    .ex_shift_arith_i  (ex_shift_arith),
    .ex_is_auipc_i     (ex_is_auipc),
    .ex_is_lui_i       (ex_is_lui),
    .ex_alu_result_o   (ex_alu_result),
    .ex_store_data_o   (ex_store_data),
    .ex_pc4_o          (ex_pc4),
    .ex_br_taken_o     (ex_br_taken),
    .ex_br_target_o    (ex_br_target),
    .redirect_valid_o  (redirect_valid),
    .redirect_pc_o     (redirect_pc)
  );

  // ================= EX/MEM =================
  wire [31:0] mem_store_data;
  wire        mem_mem_read, mem_mem_write;
  wire [2:0]  mem_size;

  ex_mem_reg u_ex_mem (
    .clk              (clk),
    .rst_n            (rst_n),
    .stall_i          (stall_exmem),
    .flush_i          (1'b0),
    .ex_valid_i       (ex_valid),
    .ex_pc4_i         (ex_pc4),
    .ex_alu_result_i  (ex_alu_result),
    .ex_store_data_i  (ex_store_data),
    .ex_rd_i          (ex_rd),
    .ex_reg_write_i   (ex_reg_write),
    .ex_wb_sel_i      (ex_wb_sel),
    .ex_mem_read_i    (ex_mem_read),
    .ex_mem_write_i   (ex_mem_write),
    .ex_mem_funct3_i  (ex_mem_funct3),
    .mem_pc4_o        (mem_pc4),
    .mem_alu_result_o (mem_alu_result),
    .mem_store_data_o (mem_store_data),
    .mem_rd_o         (mem_rd),
    .mem_reg_write_o  (mem_reg_write),
    .mem_wb_sel_o     (mem_wb_sel),
    .mem_mem_read_o   (mem_mem_read),
    .mem_mem_write_o  (mem_mem_write),
    .mem_size_o       (mem_size),
    .mem_valid_o      (mem_valid)
  );

  // ================= MEM =================
  wire [31:0] mem_load_rdata;
  wire        mem_stall;
  wire        mem_load_valid;
  wire        mem_load_active;

  // Core <-> D-cache wires
  wire        dcache_core_req;
  wire        dcache_core_we;
  wire [31:0] dcache_core_addr;
  wire [31:0] dcache_core_wdata;
  wire [3:0]  dcache_core_wstrb;
  wire        dcache_core_ready;
  wire        dcache_core_rvalid;
  wire [31:0] dcache_core_rdata;
  wire        dcache_core_store_done;

  // D-cache <-> external memory wires
  wire        dcache_mem_req;
  wire        dcache_mem_we;
  wire [31:0] dcache_mem_addr;
  wire [31:0] dcache_mem_wdata;
  wire [3:0]  dcache_mem_wstrb;
  mem_stage u_mem (
    .clk               (clk),
    .rst_n             (rst_n),
    .mem_valid_i       (mem_valid),
    .mem_alu_result_i  (mem_alu_result),
    .mem_store_data_i  (mem_store_data),
    .mem_mem_read_i    (mem_mem_read),
    .mem_mem_write_i   (mem_mem_write),
    .mem_size_i        (mem_size),
    .dmem_req_o        (dcache_core_req),
    .dmem_we_o         (dcache_core_we),
    .dmem_addr_o       (dcache_core_addr),
    .dmem_wdata_o      (dcache_core_wdata),
    .dmem_wstrb_o      (dcache_core_wstrb),
    .dmem_ready_i      (dcache_core_ready),
    .dmem_rvalid_i     (dcache_core_rvalid),
    .dmem_rdata_i      (dcache_core_rdata),
    .store_done_i      (dcache_core_store_done),
    .mem_load_rdata_o  (mem_load_rdata),
    .mem_stall_o       (mem_stall),
    .mem_load_valid_o  (mem_load_valid),
    .mem_load_active_o (mem_load_active)
  );

  dcache u_dcache (
    .clk               (clk),
    .rstn              (rst_n),
    .cpu_req_valid     (dcache_core_req),
    .cpu_req_ready     (dcache_core_ready),
    .cpu_req_rw        (dcache_core_we),
    .cpu_req_addr      (dcache_core_addr),
    .cpu_req_wdata     (dcache_core_wdata),
    .cpu_req_wstrb     (dcache_core_wstrb),
    .cpu_resp_valid    (dcache_core_rvalid),
    .cpu_resp_rdata    (dcache_core_rdata),
    .cpu_resp_err      (),
    .cpu_stall_ld_miss (),
    .cpu_stall_st_buf  (),
    .cpu_store_done_o  (dcache_core_store_done),
    .mem_req_valid     (dcache_mem_req),
    .mem_req_ready     (dmem_ready_i),
    .mem_req_write     (dcache_mem_we),
    .mem_req_addr      (dcache_mem_addr),
    .mem_req_wdata     (dcache_mem_wdata),
    .mem_req_wstrb     (dcache_mem_wstrb),
    .mem_resp_valid    (dmem_rvalid_i),
    .mem_resp_rdata    (dmem_rdata_i),
    .mem_resp_err      ()
  );

  assign dmem_req_o   = dcache_mem_req;
  assign dmem_we_o    = dcache_mem_we;
  assign dmem_addr_o  = dcache_mem_addr;
  assign dmem_wdata_o = dcache_mem_wdata;
  assign dmem_wstrb_o = dcache_mem_wstrb;


  // ================= MEM/WB =================
  wire        wb_valid;

  // WB 提交單拍：
  // - LOAD：以 D-cache 的 rvalid 作為提交脈衝
  // - 非 LOAD：僅在 MEM 不停滯時提交，避免同一指令在 MEM 停滯期間重複提交
  wire wb_i_valid = mem_mem_read ? mem_load_valid : (mem_valid & ~mem_stall);

  mem_wb u_mem_wb (
    .clk          (clk),
    .rst_n        (rst_n),
    .i_valid      (wb_i_valid),
    .i_flush      (1'b0),
    .i_stall      (1'b0),
    .i_rd         (mem_rd),
    .i_rd_wen     (mem_reg_write),
    .i_alu_result (mem_alu_result),
    .i_mem_rdata  (mem_load_rdata),
    .i_pc_plus4   (mem_pc4),
    .i_wb_sel     (mem_wb_sel),
    .o_valid      (wb_valid),
    .o_rd         (wb_rd),
    .o_rd_wen     (wb_rd_wen),
    .o_wb_wdata   (wb_wdata)
  );

  // ================= WB =================
  wb_stage u_wb (
    .clk            (clk),
    .rst_n          (rst_n),
    .i_valid        (wb_valid),
    .i_rd           (wb_rd),
    .i_rd_wen       (wb_rd_wen),
    .i_wb_wdata     (wb_wdata),
    .rf_we_o        (rf_we),
    .rf_waddr_o     (rf_waddr),
    .rf_wdata_o     (rf_wdata),
    .wb_fwd_valid_o (),
    .wb_fwd_rd_o    (),
    .wb_fwd_data_o  ()
  );

  // Expose WB to TB
  assign wb_we_o    = rf_we;
  assign wb_rd_o    = rf_waddr;
  assign wb_wdata_o = rf_wdata;

  // ================= Hazard/Control =================
  hazard_unit u_hdu (
    // ID
    .id_valid_i        (id_valid),
    .id_rs1_i          (id_rs1),
    .id_rs2_i          (id_rs2),
    .id_is_store_i     (id_mem_write),
    // EX
    .ex_valid_i        (ex_valid),
    .ex_rd_i           (ex_rd),
    .ex_reg_write_i    (ex_reg_write),
    .ex_mem_read_i     (ex_mem_read),
    // MEM
    .mem_valid_i       (mem_valid),
    .mem_rd_i          (mem_rd),
    .mem_reg_write_i   (mem_reg_write),
    .mem_stall_i       (mem_stall),
    .ifetch_stall_i   (icache_stall),
    // Redirect
    .redirect_valid_i  (redirect_valid),
    // Outputs
    .stall_if_o        (stall_if),
    .stall_id_o        (stall_id),
    .stall_ex_o        (stall_ex),
    .stall_exmem_o     (stall_exmem),
    .flush_ifid_o      (flush_ifid),
    .flush_idex_o      (flush_idex)
  );

endmodule
