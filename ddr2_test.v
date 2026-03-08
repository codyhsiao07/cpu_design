`timescale 1ps/1ps
// ============================================================
// DDR2 MIG (APP interface) bring-up test top for Nexys A7
// - CLK100MHZ drives sys_clk_i and clk_ref_i
// - Add reset sync + stretcher (debounce-ish)
// - Select reset polarity via parameter
// - Write one 128b beat, wait, then read back and compare
//
// Verilog-2001; MIG instance uses positional ports only.
// ============================================================

module ddr2_test_top (
    input         CLK100MHZ,
    input         BTNC,

    inout  [15:0] ddr2_dq,
    inout  [1:0]  ddr2_dqs_n,
    inout  [1:0]  ddr2_dqs_p,
    output [12:0] ddr2_addr,
    output [2:0]  ddr2_ba,
    output        ddr2_ras_n,
    output        ddr2_cas_n,
    output        ddr2_we_n,
    output [0:0]  ddr2_ck_p,
    output [0:0]  ddr2_ck_n,
    output [0:0]  ddr2_cke,
    output [0:0]  ddr2_cs_n,
    output [1:0]  ddr2_dm,
    output [0:0]  ddr2_odt,

    output [3:0]  LED
);

    // -----------------------------
    // Clocks
    // -----------------------------
    wire sys_clk_i = CLK100MHZ;
    wire clk_ref_i = CLK100MHZ;

    // -----------------------------
    // Reset sync + stretcher (in 100MHz domain)
    // -----------------------------
    // Set this to 1 if MIG sys_rst is active-high, 0 if active-low.
    parameter MIG_RST_ACTIVE_HIGH = 1;

    // stretch length: about 0.1s @100MHz = 10,000,000 cycles
    parameter [25:0] RST_STRETCH = 26'd10_000_000;

    reg btn_ff0, btn_ff1, btn_ff1_d;
    always @(posedge sys_clk_i) begin
        btn_ff0   <= BTNC;
        btn_ff1   <= btn_ff0;
        btn_ff1_d <= btn_ff1;
    end
    wire btn_press = btn_ff1 & ~btn_ff1_d;

    reg [25:0] rst_cnt;
    reg        rst_active;
    always @(posedge sys_clk_i) begin
        if (btn_press) begin
            rst_active <= 1'b1;
            rst_cnt    <= RST_STRETCH;
        end else if (rst_active) begin
            if (rst_cnt != 26'd0)
                rst_cnt <= rst_cnt - 26'd1;
            else
                rst_active <= 1'b0;
        end
    end

    wire mig_sys_rst = (MIG_RST_ACTIVE_HIGH) ? rst_active : ~rst_active;

    // -----------------------------
    // MIG APP interface signals
    // -----------------------------
    reg  [26:0]  app_addr;
    reg  [2:0]   app_cmd;
    reg          app_en;

    reg  [127:0] app_wdf_data;
    reg          app_wdf_end;
    reg  [15:0]  app_wdf_mask;
    reg          app_wdf_wren;

    wire [127:0] app_rd_data;
    wire         app_rd_data_end;
    wire         app_rd_data_valid;
    wire         app_rdy;
    wire         app_wdf_rdy;

    wire         app_sr_req  = 1'b0;
    wire         app_ref_req = 1'b0;
    wire         app_zq_req  = 1'b0;

    wire         app_sr_active;
    wire         app_ref_ack;
    wire         app_zq_ack;

    wire         ui_clk;
    wire         ui_clk_sync_rst;
    wire         init_calib_complete;

    // -----------------------------
    // MIG instance (positional)
    // -----------------------------
    MIG_DDR2_interface u_mig (
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

        sys_clk_i,
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
        app_sr_req,
        app_ref_req,
        app_zq_req,
        app_sr_active,
        app_ref_ack,
        app_zq_ack,
        ui_clk,
        ui_clk_sync_rst,
        init_calib_complete,

        mig_sys_rst
    );

    // -----------------------------
    // Test parameters
    // -----------------------------
    localparam [2:0] MIG_CMD_WRITE = 3'b000;
    localparam [2:0] MIG_CMD_READ  = 3'b001;

    localparam [26:0]  TEST_ADDR  = 27'd0;
    localparam [127:0] TEST_WDATA = 128'h0123_4567_89AB_CDEF_FEDC_BA98_7654_3210;

    // wait cycles between write and read (ui_clk domain)
    localparam [15:0] WR2RD_WAIT = 16'd512;

    // -----------------------------
    // FSM on ui_clk
    // -----------------------------
    localparam S_RST      = 3'd0;
    localparam S_WAITCAL  = 3'd1;
    localparam S_WR_REQ   = 3'd2;
    localparam S_WR_WAIT  = 3'd3;
    localparam S_RD_REQ   = 3'd4;
    localparam S_RD_WAIT  = 3'd5;
    localparam S_PASS     = 3'd6;
    localparam S_FAIL     = 3'd7;

    reg [2:0] state;
    reg pass_r, fail_r;
    reg [15:0] wait_cnt;

    // LED0: calib_done
    // LED1: PASS
    // LED2: FAIL
    // LED3: reset_active (讓你確定 reset 真的有被按到/延長)
    assign LED[0] = init_calib_complete;
    assign LED[1] = pass_r;
    assign LED[2] = fail_r;
    assign LED[3] = rst_active;

    always @(posedge ui_clk) begin
        if (ui_clk_sync_rst) begin
            state        <= S_RST;

            app_addr     <= 27'd0;
            app_cmd      <= 3'd0;
            app_en       <= 1'b0;

            app_wdf_data <= 128'd0;
            app_wdf_end  <= 1'b0;
            app_wdf_mask <= 16'hFFFF;
            app_wdf_wren <= 1'b0;

            pass_r       <= 1'b0;
            fail_r       <= 1'b0;
            wait_cnt     <= 16'd0;
        end else begin
            app_en       <= 1'b0;
            app_wdf_wren <= 1'b0;
            app_wdf_end  <= 1'b0;

            case (state)
                S_RST: begin
                    pass_r <= 1'b0;
                    fail_r <= 1'b0;
                    state  <= S_WAITCAL;
                end

                S_WAITCAL: begin
                    if (init_calib_complete) begin
                        app_addr     <= TEST_ADDR;
                        app_cmd      <= MIG_CMD_WRITE;
                        app_wdf_data <= TEST_WDATA;
                        app_wdf_mask <= 16'h0000;
                        state        <= S_WR_REQ;
                    end
                end

                S_WR_REQ: begin
                    if (app_rdy && app_wdf_rdy) begin
                        app_en       <= 1'b1;
                        app_wdf_wren <= 1'b1;
                        app_wdf_end  <= 1'b1;
                        wait_cnt     <= WR2RD_WAIT;
                        state        <= S_WR_WAIT;
                    end
                end

                S_WR_WAIT: begin
                    if (wait_cnt != 16'd0) begin
                        wait_cnt <= wait_cnt - 16'd1;
                    end else begin
                        app_addr <= TEST_ADDR;
                        app_cmd  <= MIG_CMD_READ;
                        state    <= S_RD_REQ;
                    end
                end

                S_RD_REQ: begin
                    if (app_rdy) begin
                        app_en <= 1'b1;
                        state  <= S_RD_WAIT;
                    end
                end

                S_RD_WAIT: begin
                    if (app_rd_data_valid) begin
                        if (app_rd_data == TEST_WDATA) begin
                            pass_r <= 1'b1;
                            fail_r <= 1'b0;
                            state  <= S_PASS;
                        end else begin
                            pass_r <= 1'b0;
                            fail_r <= 1'b1;
                            state  <= S_FAIL;
                        end
                    end
                end

                S_PASS: state <= S_PASS;
                S_FAIL: state <= S_FAIL;
                default: state <= S_FAIL;
            endcase
        end
    end

endmodule
