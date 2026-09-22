`timescale 1ns / 1ps

module machine_irq_sources (
    input         clk,
    input         rst_n,

    input         msip_we_i,
    input  [31:0] msip_wdata_i,//只會使用msip_wdata_i[0] 這個位元 msip
    input         meip_we_i,
    input  [31:0] meip_wdata_i,//只會使用meip_wdata_i 這個位元 meip
    input         mtime_lo_we_i,//當前時間
    input  [31:0] mtime_lo_wdata_i,//讓 CPU / MMIO 可以「手動修改時間」
    input         mtime_hi_we_i,
    input  [31:0] mtime_hi_wdata_i,
    input         mtimecmp_lo_we_i,//比較目標值
    input  [31:0] mtimecmp_lo_wdata_i,
    input         mtimecmp_hi_we_i,
    input  [31:0] mtimecmp_hi_wdata_i,

    input         ext_irq_line_i,

    input         global_mie_i,
    input         msie_en_i,
    input         mtie_en_i,
    input         meie_en_i,

    output [31:0] msip_rdata_o,
    output [31:0] meip_rdata_o,
    output [31:0] mtime_lo_o,
    output [31:0] mtime_hi_o,
    output [31:0] mtimecmp_lo_o,
    output [31:0] mtimecmp_hi_o,

    output        soft_irq_pending_o,
    output        timer_irq_pending_o,
    output        ext_irq_pending_o,
    output        irq_request_o,
    output [31:0] irq_cause_o
);

    reg        msip_q;
    reg        meip_sw_q;
    reg [63:0] mtime_q;
    reg [63:0] mtimecmp_q;

    wire [63:0] mtime_inc = mtime_q + 64'd1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            msip_q     <= 1'b0;
            meip_sw_q  <= 1'b0;
            mtime_q    <= 64'd0;
            mtimecmp_q <= 64'hFFFF_FFFF_FFFF_FFFF;
        end else begin
            mtime_q <= mtime_inc;

            if (msip_we_i) begin
                msip_q <= msip_wdata_i[0];
            end
            if (meip_we_i) begin
                meip_sw_q <= meip_wdata_i[0];
            end
            if (mtime_lo_we_i) begin
                mtime_q[31:0] <= mtime_lo_wdata_i;
            end
            if (mtime_hi_we_i) begin
                mtime_q[63:32] <= mtime_hi_wdata_i;
            end
            if (mtimecmp_lo_we_i) begin
                mtimecmp_q[31:0] <= mtimecmp_lo_wdata_i;
            end
            if (mtimecmp_hi_we_i) begin
                mtimecmp_q[63:32] <= mtimecmp_hi_wdata_i;
            end
        end
    end

    assign msip_rdata_o     = {31'd0, msip_q};
    assign meip_rdata_o     = {31'd0, meip_sw_q};
    assign mtime_lo_o       = mtime_q[31:0];
    assign mtime_hi_o       = mtime_q[63:32];
    assign mtimecmp_lo_o    = mtimecmp_q[31:0];
    assign mtimecmp_hi_o    = mtimecmp_q[63:32];

    assign soft_irq_pending_o  = msip_q;
    assign timer_irq_pending_o = (mtime_q >= mtimecmp_q);
    assign ext_irq_pending_o   = meip_sw_q | ext_irq_line_i;

    wire irq_external_take = global_mie_i & meie_en_i & ext_irq_pending_o;
    wire irq_timer_take    = global_mie_i & mtie_en_i & timer_irq_pending_o;
    wire irq_software_take = global_mie_i & msie_en_i & soft_irq_pending_o;

    assign irq_request_o = irq_external_take | irq_timer_take | irq_software_take;
    assign irq_cause_o   = irq_external_take ? 32'd11 :
                           irq_software_take ? 32'd3  :
                           irq_timer_take    ? 32'd7  :
                                               32'd0;

endmodule
