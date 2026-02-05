`timescale 1ns/1ps
// icache_pipeline_top.v
// Minimal 5-stage RV32I pipeline wired to i_cache via icache_top.
// Data memory is a tiny zero-wait-state RAM stub for basic loads/stores.
// Intended for verifying I$ + pipeline integration only.

module icache_pipeline_top #(
  parameter integer ADDR_WIDTH  = 32,
  parameter integer L2_DATA_W   = 64,
  parameter integer DMEM_WORDS  = 1024,
  parameter integer USE_MIG     = 0,
  parameter integer UART_BOOT_EN = 0,
  parameter integer UART_BAUD    = 115_200,
  parameter integer UART_CLK_HZ  = 100_000_000,
  parameter [31:0]  UART_BOOT_BASE = 32'h8000_0000,
  parameter [31:0]  RESET_PC    = 32'h0000_0000
) (
  input                   clk,
  input                   rst_n,
  input                   uart_rx_i,

  // DDR2 MIG interface (used when USE_MIG=1)
  inout  [15:0]            ddr2_dq,
  inout  [1:0]             ddr2_dqs_n,
  inout  [1:0]             ddr2_dqs_p,
  output [13:0]            ddr2_addr,
  output [2:0]             ddr2_ba,
  output                   ddr2_ras_n,
  output                   ddr2_cas_n,
  output                   ddr2_we_n,
  output [0:0]             ddr2_ck_p,
  output [0:0]             ddr2_ck_n,
  output [0:0]             ddr2_cke,
  output [0:0]             ddr2_cs_n,
  output [1:0]             ddr2_dm,
  output [0:0]             ddr2_odt,
  input                    sys_clk_p,
  input                    sys_clk_n,
  input                    clk_ref_i,
  output                   init_calib_complete,

  // L2 interface (for I$ refill)
  output                  l2_req_valid,
  input                   l2_req_ready,
  output [ADDR_WIDTH-1:0] l2_req_addr,
  output [1:0]            l2_req_cmd,
  output [2:0]            l2_req_size,
  output [7:0]            l2_req_len,

  input                   l2_rsp_valid,
  output                  l2_rsp_ready,
  input  [L2_DATA_W-1:0]  l2_rsp_data,
  input                   l2_rsp_last,
  input                   l2_rsp_err,

  // D$ L2 interface (for data cache)
  output                  d_l2_req_valid,
  input                   d_l2_req_ready,
  output [ADDR_WIDTH-1:0] d_l2_req_addr,
  output [1:0]            d_l2_req_cmd,
  output [2:0]            d_l2_req_size,
  output [7:0]            d_l2_req_len,
  output [L2_DATA_W-1:0]  d_l2_req_wdata,
  output [(L2_DATA_W/8)-1:0] d_l2_req_wstrb,

  input                   d_l2_rsp_valid,
  output                  d_l2_rsp_ready,
  input  [L2_DATA_W-1:0]  d_l2_rsp_rdata,
  input                   d_l2_rsp_last,
  input                   d_l2_rsp_err,

  // Observability
  output                  wb_we_o,
  output [4:0]            wb_rd_o,
  output [31:0]           wb_wdata_o,
  output                  ifetch_err_o,
  output                  boot_done_o
);

  // ---------------- Clock/Reset selection ----------------
  wire core_clk;
  wire core_rst_n;
  wire core_rst;

  wire ui_clk;
  wire ui_clk_sync_rst;
  wire boot_done_int;

  assign core_rst = ~core_rst_n;

  // ---------------- Internal L2 wires (I$ / D$) ----------------
  wire                  i_l2_req_ready_int;
  wire                  i_l2_rsp_valid_int;
  wire [L2_DATA_W-1:0]   i_l2_rsp_data_int;
  wire                  i_l2_rsp_last_int;
  wire                  i_l2_rsp_err_int;

  wire                  d_l2_req_ready_int;
  wire                  d_l2_rsp_valid_int;
  wire [L2_DATA_W-1:0]   d_l2_rsp_rdata_int;
  wire                  d_l2_rsp_last_int;
  wire                  d_l2_rsp_err_int;

  // Uncached indicator for D$ (derived from cmd)
  wire d_l2_req_uncached = (d_l2_req_cmd == 2'b01) || (d_l2_req_cmd == 2'b10);

  // ---------------- MIG / L2 integration ----------------
  generate
    if (USE_MIG) begin : GEN_MIG
      // MIG app interface
      wire [27:0]  app_addr;
      wire [2:0]   app_cmd;
      wire         app_en;
      wire [127:0] app_wdf_data;
      wire         app_wdf_end;
      wire [15:0]  app_wdf_mask;
      wire         app_wdf_wren;
      wire [127:0] app_rd_data;
      wire         app_rd_data_end;
      wire         app_rd_data_valid;
      wire         app_rdy;
      wire         app_wdf_rdy;
      wire         app_sr_active;
      wire         app_ref_ack;
      wire         app_zq_ack;

      // L2 app interface
      wire [27:0]  app_addr_l2;
      wire [2:0]   app_cmd_l2;
      wire         app_en_l2;
      wire [127:0] app_wdf_data_l2;
      wire         app_wdf_end_l2;
      wire [15:0]  app_wdf_mask_l2;
      wire         app_wdf_wren_l2;

      // Bootloader app interface
      wire [27:0]  app_addr_boot;
      wire [2:0]   app_cmd_boot;
      wire         app_en_boot;
      wire [127:0] app_wdf_data_boot;
      wire         app_wdf_end_boot;
      wire [15:0]  app_wdf_mask_boot;
      wire         app_wdf_wren_boot;
      wire         boot_active_w;

      // MIG instance
      mig_7series_0 u_mig (
        ddr2_dq,
        ddr2_dqs_n,
        ddr2_dqs_p,
        ddr2_addr,
        ddr2_ba,
        ddr2_ras_n,
        ddr2_cas_n,
        ddr2_we_n,
        ddr2_ck_p,
        ddr2_ck_n,
        ddr2_cke,
        ddr2_cs_n,
        ddr2_dm,
        ddr2_odt,
        sys_clk_p,
        sys_clk_n,
        clk_ref_i,
        app_addr,
        app_cmd,
        app_en,
        app_wdf_data,
        app_wdf_end,
        app_wdf_mask,
        app_wdf_wren,
        app_rd_data,
        app_rd_data_end,
        app_rd_data_valid,
        app_rdy,
        app_wdf_rdy,
        1'b0,                 // app_sr_req
        1'b0,                 // app_ref_req
        1'b0,                 // app_zq_req
        app_sr_active,
        app_ref_ack,
        app_zq_ack,
        ui_clk,
        ui_clk_sync_rst,
        init_calib_complete,
        ~rst_n                // sys_rst (active high)
      );

      // Core clock/reset from MIG UI
      assign core_clk   = ui_clk;
      assign core_rst_n = rst_n & ~ui_clk_sync_rst & init_calib_complete & boot_done_int;

      // L2 + arbitration
      l2_cache_top u_l2 (
        core_clk,
        core_rst,
        init_calib_complete,

        l2_req_valid,
        i_l2_req_ready_int,
        l2_req_cmd,
        l2_req_addr,
        l2_req_size,
        l2_req_len,
        64'd0,
        8'd0,
        1'b0,

        i_l2_rsp_valid_int,
        l2_rsp_ready,
        i_l2_rsp_data_int,
        i_l2_rsp_err_int,
        i_l2_rsp_last_int,

        d_l2_req_valid,
        d_l2_req_ready_int,
        d_l2_req_cmd,
        d_l2_req_addr,
        d_l2_req_size,
        d_l2_req_len,
        d_l2_req_wdata,
        d_l2_req_wstrb,
        d_l2_req_uncached,

        d_l2_rsp_valid_int,
        d_l2_rsp_ready,
        d_l2_rsp_rdata_int,
        d_l2_rsp_err_int,
        d_l2_rsp_last_int,
        app_addr_l2,
        app_cmd_l2,
        app_en_l2,
        app_wdf_data_l2,
        app_wdf_end_l2,
        app_wdf_mask_l2,
        app_wdf_wren_l2,
        app_rd_data,
        app_rd_data_end,
        app_rd_data_valid,
        app_rdy,
        app_wdf_rdy
      );

      // UART bootloader (optional)
      if (UART_BOOT_EN) begin : GEN_UART_BOOT
        uart_bootloader #(
          .CLK_HZ   (UART_CLK_HZ),
          .BAUD     (UART_BAUD),
          .DDR_BASE (32'h8000_0000),
          .BOOT_ADDR(UART_BOOT_BASE)
        ) u_boot (
          .clk               (ui_clk),
          .rst_n             (rst_n & ~ui_clk_sync_rst),
          .uart_rx_i         (uart_rx_i),
          .init_calib_complete (init_calib_complete),
          .app_addr          (app_addr_boot),
          .app_cmd           (app_cmd_boot),
          .app_en            (app_en_boot),
          .app_wdf_data      (app_wdf_data_boot),
          .app_wdf_end       (app_wdf_end_boot),
          .app_wdf_mask      (app_wdf_mask_boot),
          .app_wdf_wren      (app_wdf_wren_boot),
          .app_rdy           (app_rdy),
          .app_wdf_rdy       (app_wdf_rdy),
          .boot_done_o       (boot_done_int)
        );
        assign boot_active_w = ~boot_done_int;
      end else begin : GEN_NO_UART_BOOT
        assign app_addr_boot     = 28'd0;
        assign app_cmd_boot      = 3'd0;
        assign app_en_boot       = 1'b0;
        assign app_wdf_data_boot = 128'd0;
        assign app_wdf_end_boot  = 1'b0;
        assign app_wdf_mask_boot = 16'hFFFF;
        assign app_wdf_wren_boot = 1'b0;
        assign boot_active_w     = 1'b0;
        assign boot_done_int     = 1'b1;
      end

      // MIG app mux: bootloader has priority until done
      assign app_addr     = boot_active_w ? app_addr_boot     : app_addr_l2;
      assign app_cmd      = boot_active_w ? app_cmd_boot      : app_cmd_l2;
      assign app_en       = boot_active_w ? app_en_boot       : app_en_l2;
      assign app_wdf_data = boot_active_w ? app_wdf_data_boot : app_wdf_data_l2;
      assign app_wdf_end  = boot_active_w ? app_wdf_end_boot  : app_wdf_end_l2;
      assign app_wdf_mask = boot_active_w ? app_wdf_mask_boot : app_wdf_mask_l2;
      assign app_wdf_wren = boot_active_w ? app_wdf_wren_boot : app_wdf_wren_l2;
    end else begin : GEN_NO_MIG
      assign init_calib_complete = 1'b1;
      assign ui_clk = clk;
      assign ui_clk_sync_rst = 1'b0;

      assign core_clk   = clk;
      assign core_rst_n = rst_n;
      assign boot_done_int = 1'b1;

      assign i_l2_req_ready_int = l2_req_ready;
      assign i_l2_rsp_valid_int = l2_rsp_valid;
      assign i_l2_rsp_data_int  = l2_rsp_data;
      assign i_l2_rsp_last_int  = l2_rsp_last;
      assign i_l2_rsp_err_int   = l2_rsp_err;

      assign d_l2_req_ready_int = d_l2_req_ready;
      assign d_l2_rsp_valid_int = d_l2_rsp_valid;
      assign d_l2_rsp_rdata_int = d_l2_rsp_rdata;
      assign d_l2_rsp_last_int  = d_l2_rsp_last;
      assign d_l2_rsp_err_int   = d_l2_rsp_err;
    end
  endgenerate

  assign boot_done_o = boot_done_int;

  // ================= IF =================
  wire [31:0] if_pc;
  wire        redirect_valid;
  wire [31:0] redirect_pc;
  wire        stall_if, stall_id, stall_ex, stall_exmem;
  wire        flush_ifid, flush_idex;

  pc #(
    .RESET_PC (RESET_PC)
  ) u_pc (
    .clk              (core_clk),
    .rst_n            (core_rst_n),
    .stall_i          (stall_if),
    .redirect_valid_i (redirect_valid),
    .redirect_pc_i    (redirect_pc),
    .pc_o             (if_pc)
  );

  // I$ fetch interface
  reg         if_pending;
  wire        fetch_req_valid;
  wire [31:0] fetch_req_addr  = if_pc;
  wire        fetch_req_ready;
  wire        fetch_req_kill  = redirect_valid;

  wire        fetch_resp_valid;
  wire        fetch_resp_ready = ~stall_id;
  wire [31:0] fetch_resp_inst;
  wire [31:0] fetch_resp_pc;
  wire        fetch_resp_err;

  icache_top u_icache (
    .clk              (core_clk),
    .rst_n            (core_rst_n),
    .fetch_req_valid_i  (fetch_req_valid),
    .fetch_req_addr_i   (fetch_req_addr),
    .fetch_req_kill_i   (fetch_req_kill),
    .fetch_req_ready_o  (fetch_req_ready),
    .fetch_resp_valid_o (fetch_resp_valid),
    .fetch_resp_ready_i (fetch_resp_ready),
    .fetch_resp_inst_o  (fetch_resp_inst),
    .fetch_resp_pc_o    (fetch_resp_pc),
    .fetch_resp_err_o   (fetch_resp_err),
    .l2_req_valid       (l2_req_valid),
    .l2_req_ready       (i_l2_req_ready_int),
    .l2_req_addr        (l2_req_addr),
    .l2_req_cmd         (l2_req_cmd),
    .l2_req_size        (l2_req_size),
    .l2_req_len         (l2_req_len),
    .l2_rsp_valid       (i_l2_rsp_valid_int),
    .l2_rsp_ready       (l2_rsp_ready),
    .l2_rsp_data        (i_l2_rsp_data_int),
    .l2_rsp_last        (i_l2_rsp_last_int),
    .l2_rsp_err         (i_l2_rsp_err_int)
  );

  wire req_blocked = fetch_req_valid & ~fetch_req_ready;
  wire resp_blocked = fetch_resp_valid & ~fetch_resp_ready;
  assign ifetch_err_o = fetch_resp_valid & fetch_resp_err;

  assign fetch_req_valid = ~if_pending & ~stall_if_hdu;

  always @(posedge core_clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      if_pending <= 1'b0;
    end else begin
      if (redirect_valid) begin
        if_pending <= 1'b0;
      end else if (fetch_resp_valid && fetch_resp_ready) begin
        if_pending <= 1'b0;
      end else if (fetch_req_valid && fetch_req_ready) begin
        if_pending <= 1'b1;
      end
    end
  end

  // IF/ID
  wire [31:0] id_pc;
  wire [31:0] id_instr;
  wire        id_valid;

  if_id_reg u_if_id (
    .clk              (core_clk),
    .rst_n            (core_rst_n),
    .stall_i     (stall_id),
    .flush_i     (flush_ifid),
    .if_pc_i     (fetch_resp_pc),
    .if_instr_i  (fetch_resp_inst),
    .if_valid_i  (fetch_resp_valid),
    .id_pc_o     (id_pc),
    .id_instr_o  (id_instr),
    .id_valid_o  (id_valid)
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
    .clk              (core_clk),
    .rst_n            (core_rst_n),
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
    .pc_o             (),// pc 值，可有可無
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
    .clk              (core_clk),
    .rst_n            (core_rst_n),
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

  // Forward dependencies from later stages for forwarding
  wire        mem_valid;
  wire        mem_reg_write;
  wire [1:0]  mem_wb_sel;
  wire [4:0]  mem_rd;
  wire [31:0] mem_alu_result;
  wire [31:0] mem_pc4;
  wire [31:0] mem_load_rdata;
  wire        mem_load_valid;
  wire        mem_load_active;
  wire        mem_stall;

  wire        wb_rd_wen;
  wire [4:0]  wb_rd;
  wire [31:0] wb_wdata;

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
    .ex_br_taken_o     (),//表示「這條 branch 是否成立」
    .ex_br_target_o    (),//表示「branch 目標位址」，也就是 PC + imm
    .redirect_valid_o  (redirect_valid),
    .redirect_pc_o     (redirect_pc)
  );

  // ================= EX/MEM =================
  wire [31:0] mem_store_data;
  wire        mem_mem_read, mem_mem_write;
  wire [2:0]  mem_size;
  wire ex_mem_flush = 1'b0;

  ex_mem_reg u_ex_mem (
    .clk              (core_clk),
    .rst_n            (core_rst_n),
    .stall_i          (stall_exmem),
    .flush_i          (ex_mem_flush),
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
  wire        dmem_req_o;
  wire        dmem_we_o;
  wire [31:0] dmem_addr_o;
  wire [31:0] dmem_wdata_o;
  wire [3:0]  dmem_wstrb_o;
  wire        dmem_ready_i;
  wire        dmem_rvalid_i;
  wire [31:0] dmem_rdata_i;
  wire        store_done_i;

  mem_stage u_mem (
    .clk              (core_clk),
    .rst_n            (core_rst_n),
    .mem_valid_i      (mem_valid),
    .mem_alu_result_i (mem_alu_result),
    .mem_store_data_i (mem_store_data),
    .mem_mem_read_i   (mem_mem_read),
    .mem_mem_write_i  (mem_mem_write),
    .mem_size_i       (mem_size),
    .dmem_req_o       (dmem_req_o),
    .dmem_we_o        (dmem_we_o),
    .dmem_addr_o      (dmem_addr_o),
    .dmem_wdata_o     (dmem_wdata_o),
    .dmem_wstrb_o     (dmem_wstrb_o),
    .dmem_ready_i     (dmem_ready_i),
    .dmem_rvalid_i    (dmem_rvalid_i),
    .dmem_rdata_i     (dmem_rdata_i),
    .store_done_i     (store_done_i),
    .mem_load_rdata_o (mem_load_rdata),
    .mem_stall_o      (mem_stall),
    .mem_load_valid_o (mem_load_valid),
    .mem_load_active_o(mem_load_active)
  );

  // D$ instance (blocking cache)
  wire        dcache_cpu_req_ready;
  wire        dcache_cpu_rsp_valid;
  wire [31:0] dcache_cpu_rsp_rdata;
  wire        dcache_cpu_rsp_err;
  wire        dcache_cpu_rsp_ready = 1'b1;
  wire [1:0]  dcache_req_size = mem_size[1:0];

  dcache_blocking #(
    .ADDR_W     (32),
    .CPU_DATA_W (32),
    .CPU_STRB_W (4),
    .BUS_W      (L2_DATA_W),
    .LINE_BYTES (64),
    .CACHE_BYTES(131072),
    .WAYS       (2)
  ) u_dcache (
    .clk              (core_clk),
    .rst_n            (core_rst_n),
    .cpu_req_valid   (dmem_req_o),
    .cpu_req_ready   (dcache_cpu_req_ready),
    .cpu_req_addr    (dmem_addr_o),
    .cpu_req_we      (dmem_we_o),
    .cpu_req_wdata   (dmem_wdata_o),
    .cpu_req_wstrb   (dmem_wstrb_o),
    .cpu_req_size    (dcache_req_size),
    .cpu_req_uncached(1'b0),
    .cpu_rsp_valid   (dcache_cpu_rsp_valid),
    .cpu_rsp_ready   (dcache_cpu_rsp_ready),
    .cpu_rsp_rdata   (dcache_cpu_rsp_rdata),
    .cpu_rsp_err     (dcache_cpu_rsp_err),
    .l2_req_valid    (d_l2_req_valid),
    .l2_req_ready    (d_l2_req_ready_int),
    .l2_req_cmd      (d_l2_req_cmd),
    .l2_req_addr     (d_l2_req_addr),
    .l2_req_size     (d_l2_req_size),
    .l2_req_len      (d_l2_req_len),
    .l2_req_wdata    (d_l2_req_wdata),
    .l2_req_wstrb    (d_l2_req_wstrb),
    .l2_rsp_valid    (d_l2_rsp_valid_int),
    .l2_rsp_ready    (d_l2_rsp_ready),
    .l2_rsp_rdata    (d_l2_rsp_rdata_int),
    .l2_rsp_last     (d_l2_rsp_last_int),
    .l2_rsp_err      (d_l2_rsp_err_int)
  );

  assign dmem_ready_i  = dcache_cpu_req_ready;
  assign dmem_rvalid_i = dcache_cpu_rsp_valid;
  assign dmem_rdata_i  = dcache_cpu_rsp_rdata;
  assign store_done_i  = dcache_cpu_rsp_valid;

  // ================= MEM/WB =================
  wire        wb_valid;
  wire        wb_i_valid;
  wire        wb_stall;

  assign wb_i_valid = mem_mem_read ? mem_load_valid : (mem_valid & ~mem_stall);
  assign wb_stall   = mem_stall & ~mem_load_valid;

  mem_wb u_mem_wb (
    .clk              (core_clk),
    .rst_n            (core_rst_n),
    .i_valid      (wb_i_valid),
    .i_flush      (mem_err_event),
    .i_stall      (wb_stall),
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
    .clk              (core_clk),
    .rst_n            (core_rst_n),
    .i_valid        (wb_valid),
    .i_rd           (wb_rd),
    .i_rd_wen       (wb_rd_wen),
    .i_wb_wdata     (wb_wdata),
    .rf_we_o        (rf_we),
    .rf_waddr_o     (rf_waddr),
    .rf_wdata_o     (rf_wdata),
    //目前 已經有 forwarding，只是用的是 mem_wb 輸出的 wb_rd_wen / wb_rd / wb_wdata 直接餵給 forward_unit
    .wb_fwd_valid_o (),//這個週期 WB 有有效寫回
    .wb_fwd_rd_o    (),//被寫回的目的暫存器編號
    .wb_fwd_data_o  ()//要寫回的資料
  );

  // Expose WB for TB
  assign wb_we_o    = rf_we;
  assign wb_rd_o    = rf_waddr;
  assign wb_wdata_o = rf_wdata;

  // ================= Hazard/Control =================
  wire stall_if_hdu, stall_id_hdu, stall_ex_hdu, stall_exmem_hdu;
  wire flush_ifid_hdu, flush_idex_hdu;
  wire [31:0] pending_load_mask = 32'b0;

  hazard_unit u_hdu (
    .id_valid_i         (id_valid),
    .id_rs1_i           (id_rs1),
    .id_rs2_i           (id_rs2),
    .id_is_store_i      (id_mem_write),
    .ex_valid_i         (ex_valid),
    .ex_rd_i            (ex_rd),
    .ex_reg_write_i     (ex_reg_write),
    .ex_mem_read_i      (ex_mem_read),
    .mem_valid_i        (mem_valid),
    .mem_rd_i           (mem_rd),
    .mem_reg_write_i    (mem_reg_write),
    .mem_stall_i        (mem_stall),
    .mem_load_active_i  (mem_load_active),
    .pending_load_mask_i(pending_load_mask),
    .ifetch_stall_i     (1'b0),
    .redirect_valid_i   (redirect_valid),
    .stall_if_o         (stall_if_hdu),
    .stall_id_o         (stall_id_hdu),
    .stall_ex_o         (stall_ex_hdu),
    .stall_exmem_o      (stall_exmem_hdu),
    .flush_ifid_o       (flush_ifid_hdu),
    .flush_idex_o       (flush_idex_hdu)
  );

  assign stall_if    = stall_if_hdu | if_pending | req_blocked | resp_blocked;
  assign stall_id    = stall_id_hdu;
  assign stall_ex    = stall_ex_hdu;
  assign stall_exmem = stall_exmem_hdu;
  assign flush_ifid  = flush_ifid_hdu;
  assign flush_idex  = flush_idex_hdu;

endmodule
