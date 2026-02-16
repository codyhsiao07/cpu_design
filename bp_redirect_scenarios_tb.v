`timescale 1ns/1ps

module bp_redirect_scenarios_tb;
  localparam integer ADDR_WIDTH = 32;
  localparam integer L2_DATA_W  = 64;

  reg clk = 1'b0;
  reg rst_n = 1'b0;
  reg uart_rx_i = 1'b1;

  // DDR/MIG ports (unused when USE_MIG=0)
  wire [15:0] ddr2_dq;
  wire [1:0]  ddr2_dqs_n;
  wire [1:0]  ddr2_dqs_p;
  wire [13:0] ddr2_addr;
  wire [2:0]  ddr2_ba;
  wire        ddr2_ras_n;
  wire        ddr2_cas_n;
  wire        ddr2_we_n;
  wire [0:0]  ddr2_ck_p;
  wire [0:0]  ddr2_ck_n;
  wire [0:0]  ddr2_cke;
  wire [0:0]  ddr2_cs_n;
  wire [1:0]  ddr2_dm;
  wire [0:0]  ddr2_odt;
  reg         sys_clk_p = 1'b0;
  reg         sys_clk_n = 1'b1;
  reg         clk_ref_i = 1'b0;
  wire        init_calib_complete;

  // I$ L2 interface
  wire                  l2_req_valid;
  reg                   l2_req_ready = 1'b1;
  wire [ADDR_WIDTH-1:0] l2_req_addr;
  wire [1:0]            l2_req_cmd;
  wire [2:0]            l2_req_size;
  wire [7:0]            l2_req_len;
  reg                   l2_rsp_valid = 1'b0;
  wire                  l2_rsp_ready;
  reg  [L2_DATA_W-1:0]  l2_rsp_data  = {L2_DATA_W{1'b0}};
  reg                   l2_rsp_last  = 1'b0;
  reg                   l2_rsp_err   = 1'b0;

  // D$ L2 interface
  wire                  d_l2_req_valid;
  reg                   d_l2_req_ready = 1'b1;
  wire [ADDR_WIDTH-1:0] d_l2_req_addr;
  wire [1:0]            d_l2_req_cmd;
  wire [2:0]            d_l2_req_size;
  wire [7:0]            d_l2_req_len;
  wire [L2_DATA_W-1:0]  d_l2_req_wdata;
  wire [(L2_DATA_W/8)-1:0] d_l2_req_wstrb;
  reg                   d_l2_rsp_valid = 1'b0;
  wire                  d_l2_rsp_ready;
  reg  [L2_DATA_W-1:0]  d_l2_rsp_rdata = {L2_DATA_W{1'b0}};
  reg                   d_l2_rsp_last  = 1'b0;
  reg                   d_l2_rsp_err   = 1'b0;

  wire                  wb_we_o;
  wire [4:0]            wb_rd_o;
  wire [31:0]           wb_wdata_o;
  wire                  ifetch_err_o;
  wire                  boot_done_o;

  integer fail_count = 0;

  icache_pipeline_top #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .L2_DATA_W  (L2_DATA_W),
    .USE_MIG    (0),
    .RESET_PC   (32'h0000_0000)
  ) dut (
    .clk                (clk),
    .rst_n              (rst_n),
    .uart_rx_i          (uart_rx_i),
    .ddr2_dq            (ddr2_dq),
    .ddr2_dqs_n         (ddr2_dqs_n),
    .ddr2_dqs_p         (ddr2_dqs_p),
    .ddr2_addr          (ddr2_addr),
    .ddr2_ba            (ddr2_ba),
    .ddr2_ras_n         (ddr2_ras_n),
    .ddr2_cas_n         (ddr2_cas_n),
    .ddr2_we_n          (ddr2_we_n),
    .ddr2_ck_p          (ddr2_ck_p),
    .ddr2_ck_n          (ddr2_ck_n),
    .ddr2_cke           (ddr2_cke),
    .ddr2_cs_n          (ddr2_cs_n),
    .ddr2_dm            (ddr2_dm),
    .ddr2_odt           (ddr2_odt),
    .sys_clk_p          (sys_clk_p),
    .sys_clk_n          (sys_clk_n),
    .clk_ref_i          (clk_ref_i),
    .init_calib_complete(init_calib_complete),
    .l2_req_valid       (l2_req_valid),
    .l2_req_ready       (l2_req_ready),
    .l2_req_addr        (l2_req_addr),
    .l2_req_cmd         (l2_req_cmd),
    .l2_req_size        (l2_req_size),
    .l2_req_len         (l2_req_len),
    .l2_rsp_valid       (l2_rsp_valid),
    .l2_rsp_ready       (l2_rsp_ready),
    .l2_rsp_data        (l2_rsp_data),
    .l2_rsp_last        (l2_rsp_last),
    .l2_rsp_err         (l2_rsp_err),
    .d_l2_req_valid     (d_l2_req_valid),
    .d_l2_req_ready     (d_l2_req_ready),
    .d_l2_req_addr      (d_l2_req_addr),
    .d_l2_req_cmd       (d_l2_req_cmd),
    .d_l2_req_size      (d_l2_req_size),
    .d_l2_req_len       (d_l2_req_len),
    .d_l2_req_wdata     (d_l2_req_wdata),
    .d_l2_req_wstrb     (d_l2_req_wstrb),
    .d_l2_rsp_valid     (d_l2_rsp_valid),
    .d_l2_rsp_ready     (d_l2_rsp_ready),
    .d_l2_rsp_rdata     (d_l2_rsp_rdata),
    .d_l2_rsp_last      (d_l2_rsp_last),
    .d_l2_rsp_err       (d_l2_rsp_err),
    .wb_we_o            (wb_we_o),
    .wb_rd_o            (wb_rd_o),
    .wb_wdata_o         (wb_wdata_o),
    .ifetch_err_o       (ifetch_err_o),
    .boot_done_o        (boot_done_o)
  );

  always #5 clk = ~clk;
  always @(*) begin
    sys_clk_p = clk;
    sys_clk_n = ~clk;
    clk_ref_i = clk;
  end

  task check_bit;
    input [8*48-1:0] tag;
    input got;
    input exp;
    begin
      if (got !== exp) begin
        fail_count = fail_count + 1;
        $display("[FAIL] %0s got=%0b exp=%0b @%0t", tag, got, exp, $time);
      end
    end
  endtask

  task check_word;
    input [8*48-1:0] tag;
    input [31:0] got;
    input [31:0] exp;
    begin
      if (got !== exp) begin
        fail_count = fail_count + 1;
        $display("[FAIL] %0s got=0x%08x exp=0x%08x @%0t", tag, got, exp, $time);
      end
    end
  endtask

  task apply_baseline_forces;
    begin
      force dut.stall_id = 1'b0;
      force dut.stall_ex = 1'b0;

      force dut.id_valid = 1'b0;
      force dut.id_branch = 1'b0;
      force dut.id_jal = 1'b0;
      force dut.id_jalr = 1'b0;
      force dut.id_pc = 32'h0;
      force dut.id_imm = 32'h0;
      force dut.id_rs1_val = 32'h0;
      force dut.bp_pred_taken = 1'b0;

      force dut.ex_valid = 1'b0;
      force dut.ex_branch = 1'b0;
      force dut.ex_jal = 1'b0;
      force dut.ex_jalr = 1'b0;
      force dut.ex_br_taken = 1'b0;
      force dut.ex_pred_taken = 1'b0;
      force dut.ex_pred_target = 32'h0;
      force dut.ex_redirect_pc_raw = 32'h0;
      force dut.ex_pc4 = 32'h0;
    end
  endtask

  task scenario_pred_taken_hit;
    begin
      $display("[TB] Scenario 1: pred taken 命中");

      // ID predicts taken, FE should redirect speculatively.
      force dut.id_valid = 1'b1;
      force dut.id_branch = 1'b1;
      force dut.bp_pred_taken = 1'b1;
      force dut.id_pc = 32'h0000_0100;
      force dut.id_imm = 32'h0000_0010;
      #1;
      check_bit("S1 fe_redirect_valid@ID", dut.fe_redirect_valid, 1'b1);
      check_word("S1 fe_redirect_pc@ID", dut.fe_redirect_pc, 32'h0000_0110);

      // EX confirms prediction: no recovery redirect/flush.
      force dut.id_valid = 1'b0;
      force dut.ex_valid = 1'b1;
      force dut.ex_branch = 1'b1;
      force dut.ex_br_taken = 1'b1;
      force dut.ex_pred_taken = 1'b1;
      force dut.ex_pred_target = 32'h0000_0110;
      force dut.ex_redirect_pc_raw = 32'h0000_0110;
      force dut.ex_pc4 = 32'h0000_0104;
      #1;
      check_bit("S1 redirect_valid", dut.redirect_valid, 1'b0);
      check_bit("S1 flush_ifid", dut.flush_ifid, 1'b0);
      check_bit("S1 flush_idex", dut.flush_idex, 1'b0);
    end
  endtask

  task scenario_pred_taken_miss_to_pc4;
    begin
      $display("[TB] Scenario 2: pred taken 失敗 -> PC+4");

      force dut.id_valid = 1'b0;
      force dut.ex_valid = 1'b1;
      force dut.ex_branch = 1'b1;
      force dut.ex_br_taken = 1'b0;              // actual not taken
      force dut.ex_pred_taken = 1'b1;            // predicted taken
      force dut.ex_pred_target = 32'h0000_0210;
      force dut.ex_redirect_pc_raw = 32'h0000_0210;
      force dut.ex_pc4 = 32'h0000_0204;
      #1;
      check_bit("S2 redirect_valid", dut.redirect_valid, 1'b1);
      check_word("S2 redirect_pc", dut.redirect_pc, 32'h0000_0204);
      check_bit("S2 flush_ifid", dut.flush_ifid, 1'b1);
      check_bit("S2 flush_idex", dut.flush_idex, 1'b1);
      check_bit("S2 fe_redirect_valid", dut.fe_redirect_valid, 1'b1);
      check_word("S2 fe_redirect_pc", dut.fe_redirect_pc, 32'h0000_0204);
    end
  endtask

  task scenario_pred_not_taken_miss_flush_refetch;
    begin
      $display("[TB] Scenario 3: pred not taken 失敗 -> flush + 重取");

      force dut.id_valid = 1'b0;
      force dut.ex_valid = 1'b1;
      force dut.ex_branch = 1'b1;
      force dut.ex_br_taken = 1'b1;              // actual taken
      force dut.ex_pred_taken = 1'b0;            // predicted not taken
      force dut.ex_pred_target = 32'h0000_0000;
      force dut.ex_redirect_pc_raw = 32'h0000_0310; // actual target
      force dut.ex_pc4 = 32'h0000_0304;
      #1;
      check_bit("S3 redirect_valid", dut.redirect_valid, 1'b1);
      check_word("S3 redirect_pc", dut.redirect_pc, 32'h0000_0310);
      check_bit("S3 flush_ifid", dut.flush_ifid, 1'b1);
      check_bit("S3 flush_idex", dut.flush_idex, 1'b1);
      check_bit("S3 fe_redirect_valid", dut.fe_redirect_valid, 1'b1);
      check_word("S3 fe_redirect_pc", dut.fe_redirect_pc, 32'h0000_0310);
    end
  endtask

  initial begin
    $display("[TB] bp_redirect_scenarios_tb start");

    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    apply_baseline_forces();
    #1;

    scenario_pred_taken_hit();
    scenario_pred_taken_miss_to_pc4();
    scenario_pred_not_taken_miss_flush_refetch();

    if (fail_count == 0) begin
      $display("[TB] PASS: 3 scenarios all matched");
    end else begin
      $display("[TB] FAIL: fail_count=%0d", fail_count);
      $fatal(1);
    end
    $finish;
  end

endmodule

