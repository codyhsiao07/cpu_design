// ============================================================
// L2 Cache Top (v0.2) - Arbitration + L2 Core
// Verilog-2001, no named port connection (no ".").
//
// Arbitration policy:
//   1) Uncached/MMIO (req_uncached) > cached
//   2) D$ > I$
// Single outstanding; selection held until rsp_last.
// ============================================================
`timescale 1ns/1ps

module l2_cache_top
(
    // ---------- Clock / Reset ----------
    input                  clk,
    input                  rst,
    input                  init_calib_complete,

    // ---------- I$ upstream port ----------
    input                  i_req_valid,
    output                 i_req_ready,
    input  [1:0]           i_req_cmd,
    input  [31:0]          i_req_addr,
    input  [2:0]           i_req_size,
    input  [7:0]           i_req_len,
    input  [63:0]          i_req_wdata,
    input  [7:0]           i_req_wstrb,
    input                  i_req_uncached,

    output                 i_rsp_valid,
    input                  i_rsp_ready,
    output [63:0]          i_rsp_rdata,
    output                 i_rsp_err,
    output                 i_rsp_last,

    // ---------- D$ upstream port ----------
    input                  d_req_valid,
    output                 d_req_ready,
    input  [1:0]           d_req_cmd,
    input  [31:0]          d_req_addr,
    input  [2:0]           d_req_size,
    input  [7:0]           d_req_len,
    input  [63:0]          d_req_wdata,
    input  [7:0]           d_req_wstrb,
    input                  d_req_uncached,

    output                 d_rsp_valid,
    input                  d_rsp_ready,
    output [63:0]          d_rsp_rdata,
    output                 d_rsp_err,
    output                 d_rsp_last,

    // ---------- MIG Native App Interface ----------
    output [27:0]          app_addr,
    output [2:0]           app_cmd,
    output                 app_en,
    output [127:0]         app_wdf_data,
    output                 app_wdf_end,
    output [15:0]          app_wdf_mask,
    output                 app_wdf_wren,
    input  [127:0]         app_rd_data,
    input                  app_rd_data_end,
    input                  app_rd_data_valid,
    input                  app_rdy,
    input                  app_wdf_rdy
);
    // ---------------- Optional error injection for simulation ----------------
`ifndef SYNTHESIS
    integer dbg_test_id;
    reg     dbg_i_err_once;
    reg     dbg_d_err_once;
    initial begin
        dbg_i_err_once = 1'b0;
        dbg_d_err_once = 1'b0;
        dbg_test_id = -1;
        if ($value$plusargs("TEST=%d", dbg_test_id)) begin
            if (dbg_test_id == 15) dbg_i_err_once = 1'b1;
            if (dbg_test_id == 16) dbg_d_err_once = 1'b1;
        end
        // explicit overrides
        if ($value$plusargs("I_ERR_ONCE=%d", dbg_i_err_once)) begin end
        if ($value$plusargs("D_ERR_ONCE=%d", dbg_d_err_once)) begin end
    end
`else
    wire dbg_i_err_once = 1'b0;
    wire dbg_d_err_once = 1'b0;
`endif
    //優先權（Arb Policy）
    //uncached/MMIO（req_uncached=1）優先於 cached
    //在同類型下：D$ 優先於 I$
    //single outstanding：一次只允許一筆交易進 core（含多-beat），選到誰就鎖到 rsp_last 才放掉（sel_busy hold）
    // ---------------- Arbitration (single outstanding) ----------------
    reg  sel_busy;
    reg  sel_is_d;      // 1: D selected, 0: I selected

    // Uncached priority
    wire d_unc = d_req_valid && d_req_uncached;
    wire i_unc = i_req_valid && i_req_uncached;

    // Choose when idle
    wire choose_d = d_req_valid && (d_req_uncached || !i_unc);
    wire choose_i = i_req_valid && !choose_d;

    wire sel_next_is_d = choose_d ? 1'b1 : 1'b0;

    // Drive core req_valid from selected master
    wire core_req_valid = sel_busy ? (sel_is_d ? d_req_valid : i_req_valid) :
                          (choose_d ? d_req_valid : (choose_i ? i_req_valid : 1'b0));

    // Mux signals into core
    wire [1:0]  core_req_cmd   = sel_busy ? (sel_is_d ? d_req_cmd   : i_req_cmd)   :
                                 (sel_next_is_d ? d_req_cmd  : i_req_cmd);
    wire [31:0] core_req_addr  = sel_busy ? (sel_is_d ? d_req_addr  : i_req_addr)  :
                                 (sel_next_is_d ? d_req_addr : i_req_addr);
    wire [2:0]  core_req_size  = sel_busy ? (sel_is_d ? d_req_size  : i_req_size)  :
                                 (sel_next_is_d ? d_req_size : i_req_size);
    wire [7:0]  core_req_len   = sel_busy ? (sel_is_d ? d_req_len   : i_req_len)   :
                                 (sel_next_is_d ? d_req_len  : i_req_len);
    wire [63:0] core_req_wdata = sel_busy ? (sel_is_d ? d_req_wdata : i_req_wdata) :
                                 (sel_next_is_d ? d_req_wdata: i_req_wdata);
    wire [7:0]  core_req_wstrb = sel_busy ? (sel_is_d ? d_req_wstrb : i_req_wstrb) :
                                 (sel_next_is_d ? d_req_wstrb: i_req_wstrb);
    wire        core_req_unc   = sel_busy ? (sel_is_d ? d_req_uncached : i_req_uncached) :
                                 (sel_next_is_d ? d_req_uncached : i_req_uncached);

    // Backpressure to masters
    wire core_req_ready;
    assign d_req_ready = sel_busy ? (sel_is_d ? core_req_ready : 1'b0) :
                         (choose_d ? core_req_ready : 1'b0);
    assign i_req_ready = sel_busy ? (!sel_is_d ? core_req_ready : 1'b0) :
                         (choose_i ? core_req_ready : 1'b0);

    // Core response routing
    wire        core_rsp_valid;
    wire [63:0] core_rsp_rdata;
    wire        core_rsp_err;
    wire        core_rsp_last;
    wire core_rsp_ready = sel_busy ? (sel_is_d ? d_rsp_ready : i_rsp_ready) : 1'b0;

    // Inject error once per selected master (simulation only)
    wire inject_err = sel_busy && core_rsp_valid &&
                      ((sel_is_d && dbg_d_err_once) || (!sel_is_d && dbg_i_err_once));
    wire core_rsp_err_inj = core_rsp_err | inject_err;

    assign d_rsp_valid = (sel_busy && sel_is_d) ? core_rsp_valid : 1'b0;
    assign d_rsp_rdata = core_rsp_rdata;
    assign d_rsp_err   = (sel_busy && sel_is_d) ? core_rsp_err_inj : 1'b0;
    assign d_rsp_last  = (sel_busy && sel_is_d) ? core_rsp_last  : 1'b0;

    assign i_rsp_valid = (sel_busy && (!sel_is_d)) ? core_rsp_valid : 1'b0;
    assign i_rsp_rdata = core_rsp_rdata;
    assign i_rsp_err   = (sel_busy && (!sel_is_d)) ? core_rsp_err_inj : 1'b0;
    assign i_rsp_last  = (sel_busy && (!sel_is_d)) ? core_rsp_last  : 1'b0;

    // Selection hold / release
    wire core_req_fire = core_req_valid && core_req_ready && (!sel_busy);
    wire core_rsp_fire = core_rsp_valid && core_rsp_ready && sel_busy;

    always @(posedge clk) begin
        if (rst) begin
            sel_busy  <= 1'b0;
            sel_is_d  <= 1'b0;
        end else begin
            if (core_req_fire) begin
                sel_busy <= 1'b1;
                sel_is_d <= sel_next_is_d;
            end

            if (sel_busy) begin
                if (core_rsp_fire) begin
`ifndef SYNTHESIS
                    if (sel_is_d && dbg_d_err_once) dbg_d_err_once <= 1'b0;
                    if (!sel_is_d && dbg_i_err_once) dbg_i_err_once <= 1'b0;
`endif
                end
                if (core_rsp_fire && core_rsp_last) begin
                    sel_busy <= 1'b0;
                end
            end
        end
    end

    // ---------------- L2 core instance (positional ports only) ----------------
    l2_cache_core u_core
    (
        clk,
        rst,
        init_calib_complete,

        core_req_valid,
        core_req_ready,
        core_req_cmd,
        core_req_addr,
        core_req_size,
        core_req_len,
        core_req_wdata,
        core_req_wstrb,
        core_req_unc,

        core_rsp_valid,
        core_rsp_ready,
        core_rsp_rdata,
        core_rsp_err,
        core_rsp_last,

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
        app_wdf_rdy
    );

endmodule
