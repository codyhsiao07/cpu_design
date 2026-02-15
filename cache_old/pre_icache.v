module i_cache
#(
    parameter ADDR_WIDTH  = 32,
    parameter CACHE_BYTES = 65536,
    parameter LINE_BYTES  = 64,
    parameter NUM_WAYS    = 2,
    parameter OFFSET_BITS = 6,
    parameter INDEX_BITS  = 9,
    parameter TAG_BITS    = (ADDR_WIDTH - OFFSET_BITS - INDEX_BITS),
    parameter L2_DATA_W   = 64,
    parameter UNC_BASE    = 32'h0000_0000,
    parameter UNC_MASK    = 32'h0000_0000
)
(
    input                       clk,
    input                       rst_n,

    input                       if_req_valid,
    input  [ADDR_WIDTH-1:0]     if_req_addr,
    output                      if_req_ready,
    input                       if_req_kill,

    output reg                  if_resp_valid,
    input                       if_resp_ready,
    output reg [31:0]           if_resp_inst,
    output reg [ADDR_WIDTH-1:0] if_resp_pc,
    output reg                  if_resp_err,

    input                       ic_flush_req,
    output reg                  ic_flush_ack,
    input                       ic_inv_valid,
    input                       ic_inv_all,
    input  [INDEX_BITS-1:0]     ic_inv_index,
    input                       ic_inv_way,
    output reg                  ic_inv_ack,

    output reg                  l2_req_valid,
    input                       l2_req_ready,
    output reg [ADDR_WIDTH-1:0] l2_req_addr,
    output reg [1:0]            l2_req_cmd,
    output reg [2:0]            l2_req_size,
    output reg [7:0]            l2_req_len,

    input                       l2_rsp_valid,
    output reg                  l2_rsp_ready,
    input  [L2_DATA_W-1:0]      l2_rsp_data,
    input                       l2_rsp_last,
    input                       l2_rsp_err
);

    // ----------------------------
    // Derived constants
    // ----------------------------
    localparam LINE_BITS = LINE_BYTES * 8;
    localparam NUM_SETS  = (CACHE_BYTES / (LINE_BYTES * NUM_WAYS)); // 512

    // ----------------------------
    // Cache arrays (simple reg arrays)
    // ----------------------------
    reg [LINE_BITS-1:0] data_way0 [0:NUM_SETS-1];
    reg [LINE_BITS-1:0] data_way1 [0:NUM_SETS-1];

    reg [TAG_BITS-1:0]  tag_way0  [0:NUM_SETS-1];
    reg [TAG_BITS-1:0]  tag_way1  [0:NUM_SETS-1];

    reg                 valid_way0[0:NUM_SETS-1];
    reg                 valid_way1[0:NUM_SETS-1];

    reg                 plru_bit  [0:NUM_SETS-1]; // 2-way pseudo LRU: 0/1 indicates victim

    // ----------------------------
    // Helper: uncacheable check
    // ----------------------------
    wire is_uncached_req;
    assign is_uncached_req = (((if_req_addr & UNC_MASK) == (UNC_BASE & UNC_MASK)) && (UNC_MASK != 0));
    // UNC_BASE & UNC_MASK 隞?”??抵??詨???雿???芾?擃??詨?嚗?雿停銝摰?冽迨蝭???    // ?嗅???if_req_addr & UNC_MASK???拙??擃??臬?詨?嚗???誨銵刻?決ASK蝭???    // ----------------------------
    // Kill toggle (drop in-flight response but do NOT cancel refill)
    // ----------------------------
    reg kill_prev;
    reg kill_toggle;

    // ----------------------------
    // IF1/IF2 pipeline registers
    // ----------------------------
    reg                  s1_valid;
    reg [ADDR_WIDTH-1:0]  s1_pc;
    reg                  s1_uncached;
    reg                  s1_kill_tag;

    reg                  s2_valid;
    reg [ADDR_WIDTH-1:0]  s2_pc;
    reg                  s2_uncached;
    reg                  s2_kill_tag;

    reg [TAG_BITS-1:0]   s2_tag0, s2_tag1;
    reg                  s2_v0, s2_v1;
    reg [LINE_BITS-1:0]  s2_d0, s2_d1;

    wire [INDEX_BITS-1:0] s1_index;
    wire [TAG_BITS-1:0]   s2_req_tag;
    wire [INDEX_BITS-1:0] s2_index;
    wire [3:0]            s2_word_sel; // 16 words per 64B line (32-bit inst)

    // PC[31:15]    PC[14:6]     PC[5:0]
    //  TAG          INDEX        OFFSET
    assign s1_index   = s1_pc[OFFSET_BITS+INDEX_BITS-1:OFFSET_BITS];
    assign s2_index   = s2_pc[OFFSET_BITS+INDEX_BITS-1:OFFSET_BITS];
    assign s2_req_tag = s2_pc[ADDR_WIDTH-1:OFFSET_BITS+INDEX_BITS];
    assign s2_word_sel = s2_pc[OFFSET_BITS-1:2];  // [5:2]
    //PC[1:0]嚗yte in word嚗? 32-bit ?誘?虜?箏???00嚗誨銵?4-byte 撠?嚗?    //PC[5:2]嚗ord index嚗?~15嚗?    // ----------------------------
    // Word picker: 512b line -> 32b word (Verilog-2001 safe)
    // ----------------------------
    function [31:0] pick_word32;
        input [LINE_BITS-1:0] line;
        input [3:0] wsel;
        begin
            case (wsel)
                4'd0:  pick_word32 = line[31:0];
                4'd1:  pick_word32 = line[63:32];
                4'd2:  pick_word32 = line[95:64];
                4'd3:  pick_word32 = line[127:96];
                4'd4:  pick_word32 = line[159:128];
                4'd5:  pick_word32 = line[191:160];
                4'd6:  pick_word32 = line[223:192];
                4'd7:  pick_word32 = line[255:224];
                4'd8:  pick_word32 = line[287:256];
                4'd9:  pick_word32 = line[319:288];
                4'd10: pick_word32 = line[351:320];
                4'd11: pick_word32 = line[383:352];
                4'd12: pick_word32 = line[415:384];
                4'd13: pick_word32 = line[447:416];
                4'd14: pick_word32 = line[479:448];
                4'd15: pick_word32 = line[511:480];
                default: pick_word32 = 32'h0000_0013; // NOP (ADDI x0,x0,0) as safe default
            endcase
        end
    endfunction

    // ----------------------------
    // Tag compare in IF2
    // ----------------------------
    wire hit0, hit1, hit;
    assign hit0 = s2_valid && s2_v0 && (s2_tag0 == s2_req_tag);
    assign hit1 = s2_valid && s2_v1 && (s2_tag1 == s2_req_tag);
    assign hit  = hit0 || hit1;

    wire drop_resp;
    assign drop_resp = (s2_kill_tag != kill_toggle); // kill happened after accept 
    //?? S2 ??request ?臬?? epoch?◤?亙????乩?敺?? kill嚗poch ?寡?嚗?撠望?摰? response 銝?嚗??頝臬??誘??decode??
    // ----------------------------
    // Miss / refill state machine
    // ----------------------------
    localparam ST_IDLE       = 3'd0;
    localparam ST_MISS_REQ   = 3'd1;
    localparam ST_WAIT_RSP   = 3'd2;
    localparam ST_WRITE_LINE = 3'd3;
    localparam ST_REPLAY1    = 3'd4;
    localparam ST_REPLAY2    = 3'd5;
    localparam ST_FLUSH      = 3'd6;

    reg [2:0] state;

    // Hold info for miss/refill
    reg [ADDR_WIDTH-1:0] miss_pc;
    reg                  miss_uncached;
    reg                  miss_kill_tag;

    reg [ADDR_WIDTH-1:0] refill_addr_aligned;
    reg [INDEX_BITS-1:0] refill_index;
    reg                  refill_victim_way; // 0=way0, 1=way1
    reg [TAG_BITS-1:0]   refill_tag;

    reg [LINE_BITS-1:0]  refill_buf;
    reg [3:0]            refill_beat_cnt;   // for 64-bit beats: 0..7
    reg                  refill_err_q;

    // flush control
    reg                  flush_pending;
    reg [INDEX_BITS-1:0] flush_idx;

    // invalidate pending
    reg                  inv_pending;
    reg                  inv_all_pending;
    reg [INDEX_BITS-1:0] inv_index_pending;
    reg                  inv_way_pending;

    // ----------------------------
    // if_req_ready policy:
    //  - accept requests in IDLE
    //  - stall when miss/refill/flush
    //  - stall if response is holding and CPU not ready
    // ----------------------------
    assign if_req_ready = (state == ST_IDLE) && !(if_resp_valid && !if_resp_ready);

    wire accept_req;
    // Block request acceptance on kill cycle to avoid stale sequential PC capture.
    assign accept_req = if_req_valid && if_req_ready && !if_req_kill;

    // ----------------------------
    // Main sequential logic
    // ----------------------------
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // reset
            state <= ST_IDLE;

            s1_valid <= 1'b0;
            s2_valid <= 1'b0;

            if_resp_valid <= 1'b0;
            if_resp_inst  <= 32'b0;
            if_resp_pc    <= {ADDR_WIDTH{1'b0}};
            if_resp_err   <= 1'b0;

            l2_req_valid <= 1'b0;
            l2_req_addr  <= {ADDR_WIDTH{1'b0}};
            l2_req_cmd   <= 2'b00;
            l2_req_size  <= 3'b000;
            l2_req_len   <= 8'b0;
            l2_rsp_ready <= 1'b0;

            ic_flush_ack <= 1'b0;
            ic_inv_ack   <= 1'b0;

            kill_prev   <= 1'b0;
            kill_toggle <= 1'b0;

            flush_pending <= 1'b0;
            flush_idx <= {INDEX_BITS{1'b0}};

            inv_pending <= 1'b0;
            inv_all_pending <= 1'b0;
            inv_index_pending <= {INDEX_BITS{1'b0}};
            inv_way_pending <= 1'b0;
            refill_err_q <= 1'b0;

            // clear valids
            for (i = 0; i < NUM_SETS; i = i + 1) begin
                valid_way0[i] <= 1'b0;
                valid_way1[i] <= 1'b0;
                plru_bit[i]   <= 1'b0;
            end
        end else begin
            // default pulses
            ic_flush_ack <= 1'b0;
            ic_inv_ack   <= 1'b0;

            // kill toggle edge detect
            kill_prev <= if_req_kill;
            if (if_req_kill && !kill_prev) begin
                kill_toggle <= ~kill_toggle;
                // Drop queued pre-redirect response/path state from old epoch.
                if_resp_valid <= 1'b0;
                s1_valid <= 1'b0;
                s2_valid <= 1'b0;
            end // 蝝??阡?閬蕃頧?
            // response handshake
            if (if_resp_valid && if_resp_ready) begin
                if_resp_valid <= 1'b0;
            end//銵函內??撌脩??交?隞仿?閬脰???嚗??賢??交

            // latch pending flush/invalidate requests
            if (ic_flush_req) begin
                flush_pending <= 1'b1;
            end
            if (ic_inv_valid) begin
                inv_pending <= 1'b1;
                inv_all_pending <= ic_inv_all;
                inv_index_pending <= ic_inv_index;
                inv_way_pending <= ic_inv_way;
            end

            // default: no L2 traffic unless FSM drives it
            if (!(state == ST_MISS_REQ)) begin
                // keep valid until handshake in MISS_REQ
                if (l2_req_valid && l2_req_ready) begin
                    l2_req_valid <= 1'b0;
                end
            end

            case (state)
                // =========================
                // IDLE: accept + pipeline hit path
                // =========================
                ST_IDLE: begin
                    l2_rsp_ready <= 1'b0;

                    // if pending invalidate/flush, service it with priority
                    if (flush_pending) begin
                        flush_pending <= 1'b0;
                        flush_idx <= {INDEX_BITS{1'b0}};
                        state <= ST_FLUSH;
                    end else if (inv_pending) begin
                        inv_pending <= 1'b0;
                        if (inv_all_pending) begin
                            flush_idx <= {INDEX_BITS{1'b0}};
                            state <= ST_FLUSH;
                        end else begin
                            // single index/way invalidate (1-cycle)
                            if (inv_way_pending == 1'b0) begin
                                valid_way0[inv_index_pending] <= 1'b0;
                            end else begin
                                valid_way1[inv_index_pending] <= 1'b0;
                            end
                            ic_inv_ack <= 1'b1;
                            state <= ST_IDLE;
                        end
                    end else begin
                        // Hold IF1/IF2 when response channel is back-pressured.
                        // Without this hold, a newer response can overwrite a pending one.
                        if (if_resp_valid && !if_resp_ready) begin
                            s1_valid <= s1_valid;
                            s2_valid <= s2_valid;
                        end else begin
                            // Accept new request into IF1
                            s1_valid <= accept_req;
                            if (accept_req) begin
                                s1_pc       <= if_req_addr;
                                s1_uncached <= is_uncached_req;
                                s1_kill_tag <= kill_toggle;
                            end else begin
                                s1_pc       <= s1_pc;
                                s1_uncached <= s1_uncached;
                                s1_kill_tag <= s1_kill_tag;
                            end

                            // IF2 registers load from arrays when s1_valid
                            s2_valid <= s1_valid;
                            if (s1_valid) begin
                                // synchronous "read": capture array contents
                                s2_pc       <= s1_pc;
                                s2_uncached <= s1_uncached;
                                s2_kill_tag <= s1_kill_tag;

                                s2_tag0 <= tag_way0[s1_index];
                                s2_tag1 <= tag_way1[s1_index];
                                s2_v0   <= valid_way0[s1_index];
                                s2_v1   <= valid_way1[s1_index];
                                s2_d0   <= data_way0[s1_index];
                                s2_d1   <= data_way1[s1_index];
                            end

                            // Produce response or start miss (one cycle after s2_valid is set)
                            // Note: this is a simplified timing model; you can refine for exact cycle alignment.
                            if (s2_valid) begin
                                if (s2_uncached) begin
                                    // start UC_READ via L2 (bypass path)
                                    miss_pc       <= s2_pc;
                                    miss_uncached <= 1'b1;
                                    miss_kill_tag <= s2_kill_tag;

                                    refill_addr_aligned <= s2_pc; // UC uses exact address
                                    refill_err_q <= 1'b0;
                                    state <= ST_MISS_REQ;
                                end else if (hit) begin
                                    // hit response
                                    if (!drop_resp) begin
                                        if_resp_valid <= 1'b1;
                                        if_resp_pc    <= s2_pc;
                                        if_resp_err   <= 1'b0;
                                        if (hit0) begin
                                            if_resp_inst <= pick_word32(s2_d0, s2_word_sel);
                                            plru_bit[s2_index] <= 1'b1; // next victim tends to be way1 (simple policy)
                                        end else begin
                                            if_resp_inst <= pick_word32(s2_d1, s2_word_sel);
                                            plru_bit[s2_index] <= 1'b0; // next victim tends to be way0
                                        end
                                    end
                                    // if dropped, just do nothing (squash)
                                end else begin
                                    // miss -> start LINE_FILL
                                    miss_pc       <= s2_pc;
                                    miss_uncached <= 1'b0;
                                    miss_kill_tag <= s2_kill_tag;

                                    refill_index <= s2_index;
                                    refill_tag   <= s2_req_tag;

                                    // line aligned address
                                    refill_addr_aligned <= { s2_pc[ADDR_WIDTH-1:OFFSET_BITS], {OFFSET_BITS{1'b0}} };
                                    refill_err_q <= 1'b0;

                                    // choose victim
                                    if (!s2_v0) begin
                                        refill_victim_way <= 1'b0;
                                    end else if (!s2_v1) begin
                                        refill_victim_way <= 1'b1;
                                    end else begin
                                        refill_victim_way <= plru_bit[s2_index];
                                    end

                                    state <= ST_MISS_REQ;
                                end
                            end
                        end
                    end
                end

                // =========================
                // MISS_REQ: send one L2 request (LINE_FILL or UC_READ)
                // =========================
                ST_MISS_REQ: begin
                    // drive req until handshake
                    l2_req_valid <= 1'b1; //?2?隞亙????

                    if (miss_uncached) begin
                        l2_req_cmd  <= 2'b01; // UC_READ
                        l2_req_addr <= refill_addr_aligned;
                        l2_req_size <= 3'b010; // 4 bytes
                        l2_req_len  <= 8'd0;
                    end else begin
                        l2_req_cmd  <= 2'b00; // LINE_FILL
                        l2_req_addr <= refill_addr_aligned;
                        l2_req_size <= 3'b011; // 8 bytes/beat for 64-bit bus
                        l2_req_len  <= 8'd7;   // 8 beats - 1
                    end

                    l2_rsp_ready <= 1'b0; //?迄L2?隞交?嗉???

                    if (l2_req_valid && l2_req_ready) begin
                        // request accepted
                        l2_req_valid <= 1'b0;
                        l2_rsp_ready <= 1'b1;
                        refill_buf <= {LINE_BITS{1'b0}};
                        refill_beat_cnt <= 4'd0;
                        refill_err_q <= 1'b0;
                        state <= ST_WAIT_RSP;
                    end
                end

                // =========================
                // WAIT_RSP: collect beats; on last -> write line or respond UC
                // =========================
                ST_WAIT_RSP: begin
                    l2_rsp_ready <= 1'b1;

                    if (l2_rsp_valid && l2_rsp_ready) begin
                        if (l2_rsp_err)
                            refill_err_q <= 1'b1;
                        if (miss_uncached) begin
                            // UC_READ: use low 32 bits
                            if (!((miss_kill_tag) != kill_toggle)) begin
                                if_resp_valid <= 1'b1;
                                if_resp_pc    <= miss_pc;
                                if_resp_inst  <= l2_rsp_data[31:0];
                                if_resp_err   <= l2_rsp_err;
                            end
                            l2_rsp_ready <= 1'b0;
                            state <= ST_IDLE;
                        end else begin
                            // LINE_FILL (assume L2_DATA_W = 64 for this skeleton)
                            case (refill_beat_cnt)
                                4'd0: refill_buf[63:0]    <= l2_rsp_data;
                                4'd1: refill_buf[127:64]  <= l2_rsp_data;
                                4'd2: refill_buf[191:128] <= l2_rsp_data;
                                4'd3: refill_buf[255:192] <= l2_rsp_data;
                                4'd4: refill_buf[319:256] <= l2_rsp_data;
                                4'd5: refill_buf[383:320] <= l2_rsp_data;
                                4'd6: refill_buf[447:384] <= l2_rsp_data;
                                4'd7: refill_buf[511:448] <= l2_rsp_data;
                                default: refill_buf <= refill_buf;
                            endcase

                            if (l2_rsp_last) begin
                                l2_rsp_ready <= 1'b0;
                                state <= ST_WRITE_LINE;
                            end else begin
                                refill_beat_cnt <= refill_beat_cnt + 4'd1;
                            end
                        end
                    end
                end

                // =========================
                // WRITE_LINE: Data -> Tag -> Valid (atomic in this skeleton)
                // =========================
                ST_WRITE_LINE: begin
                    if (refill_victim_way == 1'b0) begin
                        data_way0[refill_index]  <= refill_buf;
                        tag_way0[refill_index]   <= refill_tag;
                        valid_way0[refill_index] <= 1'b1;
                        plru_bit[refill_index]   <= 1'b1;
                    end else begin
                        data_way1[refill_index]  <= refill_buf;
                        tag_way1[refill_index]   <= refill_tag;
                        valid_way1[refill_index] <= 1'b1;
                        plru_bit[refill_index]   <= 1'b0;
                    end
                    state <= ST_REPLAY1;
                end

                // =========================
                // REPLAY: do a normal lookup for miss_pc to produce response
                // =========================
                ST_REPLAY1: begin
                    // load s2 regs directly for replay (skip s1 for simplicity)
                    s2_valid <= 1'b1;
                    s2_pc <= miss_pc;
                    s2_uncached <= 1'b0;
                    s2_kill_tag <= miss_kill_tag;

                    s2_tag0 <= tag_way0[miss_pc[OFFSET_BITS+INDEX_BITS-1:OFFSET_BITS]];
                    s2_tag1 <= tag_way1[miss_pc[OFFSET_BITS+INDEX_BITS-1:OFFSET_BITS]];
                    s2_v0   <= valid_way0[miss_pc[OFFSET_BITS+INDEX_BITS-1:OFFSET_BITS]];
                    s2_v1   <= valid_way1[miss_pc[OFFSET_BITS+INDEX_BITS-1:OFFSET_BITS]];
                    s2_d0   <= data_way0[miss_pc[OFFSET_BITS+INDEX_BITS-1:OFFSET_BITS]];
                    s2_d1   <= data_way1[miss_pc[OFFSET_BITS+INDEX_BITS-1:OFFSET_BITS]];

                    state <= ST_REPLAY2;
                end

                ST_REPLAY2: begin
                    // should hit after refill
                    if (hit) begin
                        if (!((s2_kill_tag) != kill_toggle)) begin
                            if_resp_valid <= 1'b1;
                            if_resp_pc    <= s2_pc;
                            if_resp_err   <= refill_err_q;
                            if (hit0) begin
                                if_resp_inst <= pick_word32(s2_d0, s2_word_sel);
                                plru_bit[s2_index] <= 1'b1;
                            end else begin
                                if_resp_inst <= pick_word32(s2_d1, s2_word_sel);
                                plru_bit[s2_index] <= 1'b0;
                            end
                        end
                    end else begin
                        // unexpected: treat as error / or retry
                        if_resp_valid <= 1'b1;
                        if_resp_pc    <= s2_pc;
                        if_resp_inst  <= 32'h0000_0013;
                        if_resp_err   <= 1'b1;
                    end
                    s2_valid <= 1'b0;
                    state <= ST_IDLE;
                end

                // =========================
                // FLUSH: clear all valid bits (one set per cycle)
                // =========================
                ST_FLUSH: begin
                    // stall fetch implicitly since state != IDLE
                    valid_way0[flush_idx] <= 1'b0;
                    valid_way1[flush_idx] <= 1'b0;

                    if (flush_idx == (NUM_SETS-1)) begin
                        ic_flush_ack <= 1'b1;
                        ic_inv_ack   <= 1'b1; // if it was inv_all, ok to also pulse
                        state <= ST_IDLE;
                    end else begin
                        flush_idx <= flush_idx + {{(INDEX_BITS-1){1'b0}}, 1'b1};
                    end
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule

