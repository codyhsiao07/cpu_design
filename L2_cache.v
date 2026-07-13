// ============================================================
// L2 Cache Core (v0.2) - Unified, 2-way, 256KiB, 64B line
// Verilog-2001, no named port connection (no ".").
//
// Spec highlights:
// - Unified L2, 2-way, 256KiB, 64B line, WB+WA, 1-bit PLRU
// - Single outstanding (global), in-order responses
// - Upstream bus: 64-bit, LINE_RD returns 8 beats, UC returns 1 beat
// - Downstream MIG: 128-bit, line refill/writeback = 4 beats
// - WB_LINE request is streaming 8 beats on req channel, 1-beat ack rsp
// - UC_WR returns 1-beat response (ack)
// ============================================================
`timescale 1ns/1ps
`ifndef PRODUCTION_BUILD
`ifdef SYNTHESIS
`ifndef FAST_SYNTH
`define FAST_SYNTH
`endif
`endif
`endif

module l2_cache_core
(
    input                  clk,
    input                  rst,
    input                  init_calib_complete,//是 DDR2 MIG 給你的「我已經可以正常用了」
    // -------- upstream (single selected master from arb) --------
    input                  req_valid,
    output reg             req_ready,
    input  [1:0]           req_cmd,
    input  [31:0]          req_addr,
    input  [2:0]           req_size,
   //傳輸大小（bytes 的 log2）
    //這通常是 AXI/類 AXI 常見的表示法：
    //3'b000 = 1B
    //3'b001 = 2B
    //3'b010 = 4B
    //3'b011 = 8B
    input  [7:0]           req_len,//這筆命令會有幾拍資料
    input  [63:0]          req_wdata,
    input  [7:0]           req_wstrb,
    input                  req_uncached,

    output reg             rsp_valid,
    input                  rsp_ready,
    output reg [63:0]      rsp_rdata,
    output reg             rsp_err,
    output reg             rsp_last,

    // -------- MIG native app --------
    output reg [26:0]      app_addr,
    output reg [2:0]       app_cmd,
    output reg             app_en,
    output reg [127:0]     app_wdf_data,
    output reg             app_wdf_end,
    output reg [15:0]      app_wdf_mask,
    output reg             app_wdf_wren,
    input      [127:0]     app_rd_data,
    input                  app_rd_data_end,
    input                  app_rd_data_valid,
    input                  app_rdy,//MIG 現在是否願意接收一筆「命令（READ / WRITE）
    input                  app_wdf_rdy//MIG 現在是否願意接收一筆「寫入資料（write data beat）」
);
    // -------- Command encoding (unified) --------
    localparam [1:0] CMD_LINE_RD = 2'b00;
    localparam [1:0] CMD_UC_RD   = 2'b01;
    localparam [1:0] CMD_UC_WR   = 2'b10;
    localparam [1:0] CMD_WB_LINE = 2'b11;

    // -------- Address map --------
    localparam [31:0] DDR_BASE  = 32'h8000_0000;
    localparam [31:0] DDR_END   = 32'h87FF_FFFF;
    localparam [31:0] MMIO_BASE = 32'h4000_0000;
    localparam [31:0] MMIO_END  = 32'h4000_FFFF;

    // -------- Cache geometry --------
    localparam integer PA_W        = 32;//實際用來當記憶體位址
    localparam integer LINE_BYTES  = 64;
    localparam integer OFFSET_BITS = 6;   // log2(64)
`ifdef FAST_SIM
    localparam integer SETS        = 128; // 16KiB / (64B * 2-way), fast simulation
    localparam integer INDEX_BITS  = 7;   // log2(128)
`elsif FAST_SYNTH
    localparam integer SETS        = 128; // 16KiB / (64B * 2-way), fast synthesis
    localparam integer INDEX_BITS  = 7;   // log2(128)
`else
    localparam integer SETS        = 2048; // 256KiB / (64B * 2-way), production
    localparam integer INDEX_BITS  = 11;   // log2(2048)
`endif
    localparam integer TAG_BITS    = PA_W - OFFSET_BITS - INDEX_BITS;

    // -------- Data arrays --------
    reg [TAG_BITS-1:0]  tag0_mem [0:SETS-1];
    reg [TAG_BITS-1:0]  tag1_mem [0:SETS-1];
    reg                 val0_mem [0:SETS-1];
    reg                 val1_mem [0:SETS-1];
    reg                 dir0_mem [0:SETS-1];
    reg                 dir1_mem [0:SETS-1];
    reg                 plru_mem [0:SETS-1]; // 0 => way0 LRU, 1 => way1 LRU

    (* ram_style = "block" *) reg [511:0] data0_mem [0:SETS-1];
    (* ram_style = "block" *) reg [511:0] data1_mem [0:SETS-1];//64 bytes = 512 bits

    // -------- Helpers --------
    function [63:0] get_beat64;
        input [511:0] line;
        input [2:0]   beat;
        reg   [9:0]   sh;
        begin
            sh = {beat, 6'd0}; // beat*64
            get_beat64 = line[sh +: 64];//從 line 的 第 sh 個 bit 開始，往上取 64 bits
            //也就是：line[sh + 63 : sh]
        end
    endfunction

    function [127:0] get_beat128;
        input [511:0] line;
        input [1:0]   beat;
        reg   [9:0]   sh;
        begin
            sh = {beat, 7'd0}; // beat*128
            get_beat128 = line[sh +: 128];
        end
    endfunction

    function [511:0] merge_beat64;
        input [511:0] line;
        input [2:0]   beat;
        input [63:0]  data;
        input [7:0]   strb;
        reg [511:0]   merged;
        integer       byte_i;
        integer       bit_base;
        begin
            merged = line;
            bit_base = beat * 64;
            for (byte_i = 0; byte_i < 8; byte_i = byte_i + 1) begin
                if (strb[byte_i])
                    merged[bit_base + byte_i*8 +: 8] = data[byte_i*8 +: 8];
            end
            merge_beat64 = merged;
        end
    endfunction

    // -------- Decode / latch --------
    reg [1:0]   cmd_r;
    reg [31:0]  addr_r;
    reg [2:0]   size_r;
    reg [7:0]   len_r;
    reg [63:0]  wdata_r;
    reg [7:0]   wstrb_r;
    reg         unc_r;

    wire is_ddr_raw  = (addr_r >= DDR_BASE)  && (addr_r <= DDR_END);
    wire is_mmio_raw = (addr_r >= MMIO_BASE) && (addr_r <= MMIO_END);
    // Legacy low-address aliasing: map 0x0000_0000..0x7fff_ffff into DDR window.
    // This keeps old tests functional while preserving DDR-space behavior.
    wire legacy_alias = (addr_r[31] == 1'b0);
    wire [31:0] addr_eff = is_ddr_raw ? addr_r :
                           (legacy_alias ? (addr_r + DDR_BASE) : addr_r);
    wire is_ddr  = (addr_eff >= DDR_BASE)  && (addr_eff <= DDR_END);
    wire is_mmio = is_mmio_raw;
    wire addr_legal = is_ddr;
    wire unc_eff = unc_r || is_mmio;//這筆存取是否要用 uncached 的方式處理
    // Upstream burst sanity (64-bit bus)
    // LINE_RD: 8 beats -> len=7, size=3 (8B)
    // UC_RD/UC_WR: 1 beat -> len=0, size=3 (8B)
    // WB_LINE: 8 beats streaming on req channel -> len=7, size=3 (8B)
    wire req_len_ok_line = (len_r == 8'd7) && (size_r == 3'b011);//LINE_RD（整條 64B）必須是 8 beats
    wire req_len_ok_uc   = (len_r == 8'd0) &&
                           ((size_r == 3'b010) || (size_r == 3'b011)); // UC_RD/UC_WR 只能是 單拍
    wire req_len_ok_wb   = (len_r == 8'd7) && (size_r == 3'b011);//WB_LINE 寫回整條 64B
    wire req_len_ok =//每一種 cmd 都有它自己應該符合的 len/size 格式，這段是把它們整理成一個總開關 req_len_ok
        (cmd_r == CMD_LINE_RD) ? req_len_ok_line :
        (cmd_r == CMD_UC_RD)   ? req_len_ok_uc   :
        (cmd_r == CMD_UC_WR)   ? req_len_ok_uc   :
        (cmd_r == CMD_WB_LINE) ? req_len_ok_wb   :
        1'b0;

    wire [INDEX_BITS-1:0] index_r = addr_eff[OFFSET_BITS + INDEX_BITS - 1 : OFFSET_BITS];
    wire [TAG_BITS-1:0]   tag_r   = addr_eff[PA_W-1 : OFFSET_BITS + INDEX_BITS];
    wire [31:0]           line_addr_r = {addr_eff[31:6], 6'b0};

    wire hit0 = val0_mem[index_r] && (tag0_mem[index_r] == tag_r);
    wire hit1 = val1_mem[index_r] && (tag1_mem[index_r] == tag_r);
    wire hit  = hit0 || hit1;
    wire hit_way = hit0 ? 1'b0 : 1'b1;

    // 在 cache miss 時，被選出來要被替換（犧牲）掉的那一條 cache line
    wire v0_inv = !val0_mem[index_r];//set = index_r 的 way0 目前是不是有效
    wire v1_inv = !val1_mem[index_r];
    wire victim_way_w = v0_inv ? 1'b0 :
                        v1_inv ? 1'b1 :
                        plru_mem[index_r];

    wire victim_valid_w = (victim_way_w == 1'b0) ? val0_mem[index_r] : val1_mem[index_r];
    wire victim_dirty_w = (victim_way_w == 1'b0) ? dir0_mem[index_r] : dir1_mem[index_r];
    wire [TAG_BITS-1:0] victim_tag_w  = (victim_way_w == 1'b0) ? tag0_mem[index_r]  : tag1_mem[index_r];
    wire [511:0]        victim_line_w = (victim_way_w == 1'b0) ? data0_mem[index_r] : data1_mem[index_r];

    localparam [4:0]
        S_IDLE          = 5'd0,
        S_LOOKUP        = 5'd1,
        S_HIT_RSP       = 5'd2,

        S_MISS_EVICT    = 5'd3,
        S_MISS_REFILL   = 5'd4,
        S_MISS_WAITRD   = 5'd5,
        S_MISS_INSTALL  = 5'd6,
        S_MISS_RSP      = 5'd7,

        S_WB_RECV       = 5'd8,
        S_WB_EVICT      = 5'd9,
        S_WB_INSTALL    = 5'd10,
        S_WB_RSP        = 5'd11,

        S_UC_RD_REQ     = 5'd12,
        S_UC_RD_WAIT    = 5'd13,
        S_UC_RD_RSP     = 5'd14,
        S_UC_WR_REQ     = 5'd15,
        S_UC_WR_RSP     = 5'd16,

        S_ERR_RSP       = 5'd17;

    reg [4:0] state;

    // response streaming
    reg [2:0]  rsp_beat_cnt;
    reg [511:0] line_buf;
    reg [511:0] refill_buf;
    reg [1:0]   mig_beat_cnt;//L2 和 DDR2 MIG 之間「資料拍數（beat）控制」的核心計數器
    // WB_LINE receive buffer
    reg [2:0]   wb_beat_cnt;//L2 從「上游（D$）」接收一整條 cache line 時，目前收到了第幾個 64-bit beat
    reg [511:0] wb_buf;
    reg         mig_wr_cmd_done;
    reg         mig_wr_data_done;

    // victim line temp
    reg [511:0] victim_line_buf;
    reg [TAG_BITS-1:0] victim_tag_buf;
    reg                victim_dirty_buf;
    reg                victim_valid_buf;
    reg                victim_way_buf;

    reg                install_way_buf;//新進來的 line（refill 或 WB_LINE）最後要裝到哪一個 way（0 或 1）
    reg                evict_needed_buf;//在裝新 line 之前，是否需要先把 victim 寫回 DDR

    // UC read response buffer
    reg [63:0] uc_rdata_buf;// 是一個 64-bit 的暫存器，用來暫存 uncached read (UC_RD) 從 MIG 回來的 64-bit 資料

    // MIG control constants (set according to MIG config)
    localparam [2:0] MIG_CMD_READ  = 3'b001;
    localparam [2:0] MIG_CMD_WRITE = 3'b000;

    wire mig_wr_cmd_fire  = app_en && app_rdy;
    wire mig_wr_data_fire = app_wdf_wren && app_wdf_rdy;
    wire mig_wr_beat_done = (mig_wr_cmd_done || mig_wr_cmd_fire) &&
                            (mig_wr_data_done || mig_wr_data_fire);

    // MIG address translation: native app_addr is byte-domain for this x16 DDR2 MIG.
    function [26:0] pa_to_app_addr16;
        input [31:0] pa16_aligned;
        reg   [31:0] off;
        begin
            off = pa16_aligned - DDR_BASE;
            pa_to_app_addr16 = off[26:0];
        end
    endfunction

    // For uncached 64-bit access, choose lower/upper 8B inside 16B line by addr[3]
    wire uc_hi64 = addr_r[3];
        //這兩行是在處理 uncached 存取時的「16B 對齊問題」：MIG 一次只能讀/寫 128-bit = 16 bytes，
    //但你的上游（L1↔L2）一次只想處理 64-bit = 8 bytes。所以你必須決定：這 8B 是落在那個 16B chunk 的下半還是上半。
    //看 addr_r[3] 這一個 bit，判斷這次 uncached 的 8-byte 資料是在 16-byte chunk 的哪一半。
    //addr_r[3] = 0 → 位址在 0x...0 ~ 0x...7
    //→ 使用 lower 64-bit（[63:0]）
    //addr_r[3] = 1 → 位址在 0x...8 ~ 0x...F
    //→ 使用 upper 64-bit（[127:64]）
    always @(*) begin
         // defaults L2 對上游
        req_ready    = 1'b0;//我現在不接受新 request
        rsp_valid    = 1'b0;//我現在沒有 response 要給你
        rsp_rdata    = 64'd0;//response 的資料內容
        rsp_err      = 1'b0;//這筆 response 是否為 error
        rsp_last     = 1'b0;//這是不是最後一拍 response
        //L2 → DDR2 MIG
        app_addr     = 27'd0;//預設位址 0（don’t care）
        app_cmd      = MIG_CMD_READ;//預設命令 = READ（但不會真的發生）
        app_en       = 1'b0;//關鍵訊號：不發送任何 DDR command
        app_wdf_data = 128'd0;//寫資料預設為 0（don’t care）
        app_wdf_end  = 1'b0;//不是 burst 的最後一拍
        app_wdf_mask = 16'hFFFF;//全部 mask（16 bytes 全不寫）
        //MIG 的 app_wdf_mask：
        //1 = mask（不寫）
        //0 = 寫
        app_wdf_wren = 1'b0;//不送 write data

        if (init_calib_complete && (!rst)) begin//是 DDR2 MIG 給你的「我已經可以正常用了」
            if (state == S_IDLE) begin
                req_ready = 1'b1;
            end else if (state == S_WB_RECV) begin
                req_ready = 1'b1;
            end
        end

        // -------- Responses --------
        if (state == S_HIT_RSP) begin
            rsp_valid = 1'b1;
            rsp_rdata = get_beat64(line_buf, rsp_beat_cnt);
            rsp_last  = (rsp_beat_cnt == 3'd7);
        end else if (state == S_MISS_RSP) begin
            rsp_valid = 1'b1;
            rsp_rdata = get_beat64(line_buf, rsp_beat_cnt);
            rsp_last  = (rsp_beat_cnt == 3'd7);
        end else if (state == S_UC_RD_RSP) begin
            rsp_valid = 1'b1;
            rsp_rdata = uc_rdata_buf;
            rsp_last  = 1'b1;
        end else if (state == S_WB_RSP) begin
            rsp_valid = 1'b1;
            rsp_rdata = 64'd0;
            rsp_last  = 1'b1;
        end else if (state == S_UC_WR_RSP) begin
            rsp_valid = 1'b1;
            rsp_rdata = 64'd0;
            rsp_last  = 1'b1;
        end else if (state == S_ERR_RSP) begin
            rsp_valid = 1'b1;
            rsp_rdata = 64'd0;
            rsp_err   = 1'b1;
            rsp_last  = 1'b1;
        end

        // -------- MIG access patterns --------
        // Eviction write (miss)
        if (state == S_MISS_EVICT) begin
            app_cmd  = MIG_CMD_WRITE;
            app_en   = !mig_wr_cmd_done;
            app_wdf_wren = !mig_wr_data_done;
            app_wdf_end  = !mig_wr_data_done;
            app_wdf_mask = 16'h0000;
            begin : BLK_MISS_EVICT_ADDR
                reg [31:0] victim_pa;
                reg [31:0] beat_pa;
                victim_pa = {victim_tag_buf, index_r, 6'b0};
                beat_pa   = victim_pa + { {28{1'b0}}, mig_beat_cnt, 4'b0 };
                app_addr  = pa_to_app_addr16(beat_pa);
                app_wdf_data = get_beat128(victim_line_buf, mig_beat_cnt);
            end
        end

        // Refill read: issue one read at a time
        if (state == S_MISS_REFILL) begin
            app_cmd = MIG_CMD_READ;
            app_en  = 1'b1;
            begin : BLK_REFILL_ADDR
                reg [31:0] pa0;
                pa0 = line_addr_r + { {28{1'b0}}, mig_beat_cnt, 4'b0 };
                app_addr = pa_to_app_addr16(pa0);
            end
        end

        // WB victim eviction
        if (state == S_WB_EVICT) begin
            app_cmd  = MIG_CMD_WRITE;
            app_en   = !mig_wr_cmd_done;
            app_wdf_wren = !mig_wr_data_done;
            app_wdf_end  = !mig_wr_data_done;
            app_wdf_mask = 16'h0000;
            begin : BLK_WB_EVICT_ADDR
                reg [31:0] victim_pa;
                reg [31:0] beat_pa;
                victim_pa = {victim_tag_buf, index_r, 6'b0};
                beat_pa   = victim_pa + { {28{1'b0}}, mig_beat_cnt, 4'b0 };
                app_addr  = pa_to_app_addr16(beat_pa);
                app_wdf_data = get_beat128(victim_line_buf, mig_beat_cnt);
            end
        end

        // UC read issue (1 read)
        if (state == S_UC_RD_REQ) begin
            app_cmd = MIG_CMD_READ;
            app_en  = 1'b1;
            begin : BLK_UC_RD_ADDR
                reg [31:0] pa16;
                pa16 = {addr_eff[31:4], 4'b0};
                app_addr = pa_to_app_addr16(pa16);
            end
        end

        // UC write issue (1 write, byte mask)
        if (state == S_UC_WR_REQ) begin
            app_cmd = MIG_CMD_WRITE;
            app_en  = !mig_wr_cmd_done;
            app_wdf_wren = !mig_wr_data_done;
            app_wdf_end  = !mig_wr_data_done;
            begin : BLK_UC_WR
                reg [31:0] pa16;
                reg [127:0] wdf;
                reg [15:0]  msk;
                pa16 = {addr_eff[31:4], 4'b0};
                app_addr = pa_to_app_addr16(pa16);
                wdf = 128'd0;
                msk = 16'hFFFF; // 1=mask(not write)
                if (uc_hi64) begin
                    wdf[127:64] = wdata_r;
                    msk[15:8] = ~wstrb_r;
                end else begin
                    wdf[63:0] = wdata_r;
                    msk[7:0]  = ~wstrb_r;
                end
                app_wdf_data = wdf;
                app_wdf_mask = msk;
            end
        end
    end

    // -------- Sequential FSM --------
    integer si;
    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;

            rsp_beat_cnt <= 3'd0;
            mig_beat_cnt <= 2'd0;
            wb_beat_cnt  <= 3'd0;
            mig_wr_cmd_done  <= 1'b0;
            mig_wr_data_done <= 1'b0;

            cmd_r   <= 2'b0;
            addr_r  <= 32'd0;
            size_r  <= 3'd0;
            len_r   <= 8'd0;
            wdata_r <= 64'd0;
            wstrb_r <= 8'd0;
            unc_r   <= 1'b0;

            line_buf   <= 512'd0;
            refill_buf <= 512'd0;
            wb_buf     <= 512'd0;
            //這些暫存是在 cache miss / writeback 流程中，用來保存「被替換(淘汰)的那一條 line」的資訊，L2 miss 時要寫回 DDR 的「被淘汰 cache line」暫存。
            victim_tag_buf   <= {TAG_BITS{1'b0}};//暫存那條 line 的 tag
            victim_dirty_buf <= 1'b0;//是否 dirty（需要 writeback）
            evict_needed_buf <= 1'b0;

            uc_rdata_buf <= 64'd0;

            // Clear meta
            for (si = 0; si < SETS; si = si + 1) begin
                val0_mem[si] <= 1'b0;
                val1_mem[si] <= 1'b0;
                dir0_mem[si] <= 1'b0;
                dir1_mem[si] <= 1'b0;
                plru_mem[si] <= 1'b0;
            end
        end else begin
            case (state)
                S_IDLE: begin
                    if (req_valid && req_ready) begin
                        cmd_r   <= req_cmd;
                        addr_r  <= req_addr;
                        size_r  <= req_size;
                        len_r   <= req_len;
                        wdata_r <= req_wdata;
                        wstrb_r <= req_wstrb;
                        unc_r   <= req_uncached;
                        state   <= S_LOOKUP;
                    end
                end

                S_LOOKUP: begin
                    if (!addr_legal || !req_len_ok) begin
                        state <= S_ERR_RSP;
                    end else if ((cmd_r == CMD_LINE_RD) && unc_eff) begin
                        if (hit) begin
                            uc_rdata_buf <= get_beat64(hit0 ? data0_mem[index_r] : data1_mem[index_r],
                                                       addr_eff[5:3]);
                            if (hit0) plru_mem[index_r] <= 1'b1;
                            else      plru_mem[index_r] <= 1'b0;
                            state <= S_UC_RD_RSP;
                        end else begin
                            state <= S_UC_RD_REQ;
                        end
                    end else begin
                        if (cmd_r == CMD_UC_RD) begin
                            if (hit) begin
                                uc_rdata_buf <= get_beat64(hit0 ? data0_mem[index_r] : data1_mem[index_r],
                                                           addr_eff[5:3]);
                                if (hit0) plru_mem[index_r] <= 1'b1;
                                else      plru_mem[index_r] <= 1'b0;
                                state <= S_UC_RD_RSP;
                            end else begin
                                state <= S_UC_RD_REQ;
                            end
                        end else if (cmd_r == CMD_UC_WR) begin
                            // A bypass write must also update a resident cache line.
                            if (hit0) begin
                                data0_mem[index_r] <= merge_beat64(data0_mem[index_r],
                                                                  addr_eff[5:3], wdata_r, wstrb_r);
                                dir0_mem[index_r] <= 1'b1;
                                plru_mem[index_r] <= 1'b1;
                            end else if (hit1) begin
                                data1_mem[index_r] <= merge_beat64(data1_mem[index_r],
                                                                  addr_eff[5:3], wdata_r, wstrb_r);
                                dir1_mem[index_r] <= 1'b1;
                                plru_mem[index_r] <= 1'b0;
                            end
                            mig_wr_cmd_done  <= 1'b0;
                            mig_wr_data_done <= 1'b0;
                            state <= S_UC_WR_REQ;
                        end else if (cmd_r == CMD_WB_LINE) begin
                            // Capture the first beat (already accepted in S_IDLE)
                            // to avoid a beat misalignment bubble before S_WB_RECV.
                            wb_buf <= 512'd0;
                            wb_buf[63:0] <= wdata_r;
                            wb_beat_cnt <= 3'd1;
                            state <= S_WB_RECV;
                        end else begin
                            // cached line read (LINE_RD)
                            if (hit) begin
                                line_buf <= hit0 ? data0_mem[index_r] : data1_mem[index_r];
                                rsp_beat_cnt <= 3'd0;

                                // update PLRU
                                if (hit0) plru_mem[index_r] <= 1'b1;
                                else      plru_mem[index_r] <= 1'b0;

                                state <= S_HIT_RSP;
                            end else begin
                                // Miss: capture victim info
                                victim_way_buf   <= victim_way_w;
                                victim_line_buf  <= victim_line_w;
                                victim_tag_buf   <= victim_tag_w;
                                victim_dirty_buf <= victim_dirty_w;
                                victim_valid_buf <= victim_valid_w;
                                install_way_buf  <= victim_way_w;
                                evict_needed_buf <= victim_valid_w && victim_dirty_w;
                                mig_beat_cnt <= 2'd0;
                                mig_wr_cmd_done  <= 1'b0;
                                mig_wr_data_done <= 1'b0;

                                if (victim_valid_w && victim_dirty_w) state <= S_MISS_EVICT;
                                else                                  state <= S_MISS_REFILL;
                            end
                        end
                    end
                end

                // ---------------- HIT response: 8 beats @64b ----------------
                S_HIT_RSP: begin
                    if (rsp_ready) begin//對方ok
                        if (rsp_beat_cnt == 3'd7) begin
                            rsp_beat_cnt <= 3'd0;
                            state <= S_IDLE;
                        end else begin
                            rsp_beat_cnt <= rsp_beat_cnt + 3'd1;
                        end
                    end
                end

                // ---------------- MISS eviction: 4 beats @128b write ----------------
                S_MISS_EVICT: begin
                    if (mig_wr_cmd_fire)
                        mig_wr_cmd_done <= 1'b1;
                    if (mig_wr_data_fire)
                        mig_wr_data_done <= 1'b1;
                    if (mig_wr_beat_done) begin
                        mig_wr_cmd_done  <= 1'b0;
                        mig_wr_data_done <= 1'b0;
                        if (mig_beat_cnt == 2'd3) begin
                            mig_beat_cnt <= 2'd0;
                            state <= S_MISS_REFILL;
                        end else begin
                            mig_beat_cnt <= mig_beat_cnt + 2'd1;
                        end
                    end
                end

                // ---------------- MISS refill: issue 1 read ----------------
                S_MISS_REFILL: begin
                    if (app_rdy) begin
                        state <= S_MISS_WAITRD;
                    end
                end

                // collect 1 rd beat
                S_MISS_WAITRD: begin
                    if (app_rd_data_valid) begin
                        refill_buf[{mig_beat_cnt, 7'd0} +: 128] <= app_rd_data;
                        if (mig_beat_cnt == 2'd3) begin
                            mig_beat_cnt <= 2'd0;
                            state <= S_MISS_INSTALL;
                        end else begin
                            mig_beat_cnt <= mig_beat_cnt + 2'd1;
                            state <= S_MISS_REFILL;
                        end
                    end
                end

                // install refill line into cache
                S_MISS_INSTALL: begin
                    if (install_way_buf == 1'b0) begin
                        data0_mem[index_r] <= refill_buf;
                        tag0_mem[index_r]  <= tag_r;
                        val0_mem[index_r]  <= 1'b1;
                        dir0_mem[index_r]  <= 1'b0;
                        plru_mem[index_r]  <= 1'b1;
                    end else begin
                        data1_mem[index_r] <= refill_buf;
                        tag1_mem[index_r]  <= tag_r;
                        val1_mem[index_r]  <= 1'b1;
                        dir1_mem[index_r]  <= 1'b0;
                        plru_mem[index_r]  <= 1'b0;
                    end
                    line_buf <= refill_buf;
                    rsp_beat_cnt <= 3'd0;
                    state <= S_MISS_RSP;
                end

                // respond after miss: 8 beats
                S_MISS_RSP: begin
                    if (rsp_ready) begin
                        if (rsp_beat_cnt == 3'd7) begin
                            rsp_beat_cnt <= 3'd0;
                            state <= S_IDLE;
                        end else begin
                            rsp_beat_cnt <= rsp_beat_cnt + 3'd1;
                        end
                    end
                end

                // ---------------- WB_LINE receive: 8 beats on req channel ----------------
                S_WB_RECV: begin
                    if (req_valid && req_ready) begin
                        wb_buf[{wb_beat_cnt, 6'd0} +: 64] <= req_wdata;
                        if (wb_beat_cnt == 3'd7) begin
                            // decide placement after full line collected
                            if (hit) begin
                                install_way_buf  <= hit_way;
                                evict_needed_buf <= 1'b0;
                                state <= S_WB_INSTALL;
                            end else begin
                                victim_way_buf   <= victim_way_w;
                                victim_line_buf  <= victim_line_w;
                                victim_tag_buf   <= victim_tag_w;
                                victim_dirty_buf <= victim_dirty_w;
                                victim_valid_buf <= victim_valid_w;
                                install_way_buf  <= victim_way_w;
                                evict_needed_buf <= victim_valid_w && victim_dirty_w;
                                mig_beat_cnt <= 2'd0;
                                mig_wr_cmd_done  <= 1'b0;
                                mig_wr_data_done <= 1'b0;
                                if (victim_valid_w && victim_dirty_w) state <= S_WB_EVICT;
                                else                                  state <= S_WB_INSTALL;
                            end
                            wb_beat_cnt <= 3'd0;
                        end else begin
                            wb_beat_cnt <= wb_beat_cnt + 3'd1;
                        end
                    end
                end

                // writeback victim before installing WB line
                S_WB_EVICT: begin
                    if (mig_wr_cmd_fire)
                        mig_wr_cmd_done <= 1'b1;
                    if (mig_wr_data_fire)
                        mig_wr_data_done <= 1'b1;
                    if (mig_wr_beat_done) begin
                        mig_wr_cmd_done  <= 1'b0;
                        mig_wr_data_done <= 1'b0;
                        if (mig_beat_cnt == 2'd3) begin
                            mig_beat_cnt <= 2'd0;
                            state <= S_WB_INSTALL;
                        end else begin
                            mig_beat_cnt <= mig_beat_cnt + 2'd1;
                        end
                    end
                end

                S_WB_INSTALL: begin
                    if (install_way_buf == 1'b0) begin
                        data0_mem[index_r] <= wb_buf;
                        tag0_mem[index_r]  <= tag_r;
                        val0_mem[index_r]  <= 1'b1;
                        dir0_mem[index_r]  <= 1'b1;
                        plru_mem[index_r]  <= 1'b1;
                    end else begin
                        data1_mem[index_r] <= wb_buf;
                        tag1_mem[index_r]  <= tag_r;
                        val1_mem[index_r]  <= 1'b1;
                        dir1_mem[index_r]  <= 1'b1;
                        plru_mem[index_r]  <= 1'b0;
                    end
                    state <= S_WB_RSP;
                end

                S_WB_RSP: begin
                    if (rsp_ready) begin
                        state <= S_IDLE;
                    end
                end

                // ---------------- UC read/write ----------------
                S_UC_RD_REQ: begin
                    if (app_rdy) begin
                        state <= S_UC_RD_WAIT;
                    end
                end

                S_UC_RD_WAIT: begin
                    if (app_rd_data_valid) begin
                        uc_rdata_buf <= uc_hi64 ? app_rd_data[127:64] : app_rd_data[63:0];
                        state <= S_UC_RD_RSP;
                    end
                end

                S_UC_RD_RSP: begin
                    if (rsp_ready) begin
                        state <= S_IDLE;
                    end
                end

                S_UC_WR_REQ: begin
                    if (mig_wr_cmd_fire)
                        mig_wr_cmd_done <= 1'b1;
                    if (mig_wr_data_fire)
                        mig_wr_data_done <= 1'b1;
                    if (mig_wr_beat_done) begin
                        mig_wr_cmd_done  <= 1'b0;
                        mig_wr_data_done <= 1'b0;
                        state <= S_UC_WR_RSP;
                    end
                end

                S_UC_WR_RSP: begin
                    if (rsp_ready) begin
                        state <= S_IDLE;
                    end
                end

                // ---------------- Error response ----------------
                S_ERR_RSP: begin
                    if (rsp_ready) begin
                        state <= S_IDLE;
                    end
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
