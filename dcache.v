// ============================================================================
// Blocking D-Cache Skeleton (Verilog-2001)
// - 32-bit CPU data, 64-bit L2 bus
// - 128KB, 2-way, 64B line, 1-bit LRU
// - Write-back + no-write-allocate
// - 1 outstanding transaction (blocking)
// - PIPT, uncached/MMIO is pre-decoded (cpu_req_uncached)
// Notes:
//   * This is an architecture skeleton intended to be completed/verified.
//   * SRAM inference style: synchronous read via registered array reads.
//   * No named port connections are used (no '.' operator), per requirement.
// ============================================================================

`timescale 1ns/1ps

module dcache_blocking
#(
    parameter ADDR_W      = 32,//地址寬度
    parameter CPU_DATA_W  = 32,//CPU 端資料寬度
    parameter CPU_STRB_W  = 4,//CPU 端 byte strobe 寬度
    parameter BUS_W       = 64,//一次搬運 64-bit
    parameter LINE_BYTES  = 64,//cache line 大小（每條 cache line 64 bytes）
    parameter CACHE_BYTES = 131072,//快取總容量（bytes），這裡是 128 KiB
    parameter WAYS        = 2//組相聯度
)
(
    input                   clk,
    input                   rst_n,

    // ---------------- CPU request ----------------
    input                   cpu_req_valid,//CPU 端「有一筆記憶體存取請求」要送進 DCache 時拉高  CPU→DCache
    output                  cpu_req_ready,//DCache 端回應「我現在能不能接新請求」CPU→DCache
    input  [ADDR_W-1:0]     cpu_req_addr,//CPU 要存取的「位址」
    input                   cpu_req_we,         // 這筆是 store 還是 load  1=store, 0=load
    input  [CPU_DATA_W-1:0] cpu_req_wdata,//store 要寫入的資料（只有 cpu_req_we=1 時有意義）
    input  [CPU_STRB_W-1:0] cpu_req_wstrb,      // 表示 32-bit word 裡哪幾個 byte 要被寫 哪幾個 byte 要寫
    //wstrb[0] → 寫 wdata[7:0]
    //wstrb[1] → 寫 wdata[15:8]
    //wstrb[2] → 寫 wdata[23:16]
    //wstrb[3] → 寫 wdata[31:24]
    input  [1:0]            cpu_req_size,       // 這筆 access 的「資料大小」（通常用來做對齊檢查) 這次存取有多大
    //2'b00：1 byte 
    //2'b01：2 bytes  
    //2'b10：4 bytes  
    //2'b11：保留/未用（可當非法）
    input                   cpu_req_uncached,   // 表示這筆 access 不走 cache 由外部 address map 先 decode 好再送進來
    //uncached=1：DCache 不查 tag/data array，直接對 L2 發 UC_RD/UC_WR
    //uncached=0：正常 cached 行為
    // ---------------- CPU response ----------------
    output reg              cpu_rsp_valid,//DCache 告訴 CPU：「我現在有一筆回應可以給你」。 DCache→CPU
    //對 load：代表 cpu_rsp_rdata 已經是有效讀回資料。
    //對 store：代表「store 已完成
    input                   cpu_rsp_ready,//CPU 告訴 DCache：「我這拍可以接收 response」 DCache→CPU
    output reg [CPU_DATA_W-1:0] cpu_rsp_rdata,//回傳給 CPU 的讀取資料
    output reg              cpu_rsp_err,         // 表示這筆 response 有錯誤

    // ---------------- L2 request (streaming on req channel) ----------------
    output reg              l2_req_valid,//DCache 表示：「我這拍要送一個 L2 request / 或送 burst 的某個 beat」
    input                   l2_req_ready,//L2 表示：「我這拍可以接受你的 request（或這個 beat）
    output reg [1:0]        l2_req_cmd,          // 這筆 request 的「命令類型」
    //2'b00 → CMD_LINE_RD 讀取整條 cache line（refill）
    //2'b01 → CMD_UC_RD uncached 讀
    //2'b10 → CMD_UC_WR uncached 寫
    //2'b11 → CMD_WB_LINE  寫回整條 line
    output reg [ADDR_W-1:0] l2_req_addr,//本次 transaction 的起始位址
    output reg [2:0]        l2_req_size,         // 「每個 beat 的大小」
    //3'b011 表示 8 bytes/beat
    //3'b010 表示 4 bytes/beat
    output reg [7:0]        l2_req_len,          // burst 長度
    output reg [BUS_W-1:0]  l2_req_wdata,        // 寫入資料
    output reg [(BUS_W/8)-1:0] l2_req_wstrb,     // 寫入 byte-enable（和 CPU 的 wstrb 概念一樣，只是寬度變成 bus 的 byte 數）


    //bus=64-bit ⇒ 8 bytes ⇒ wstrb[7:0]
    //CMD_UC_WR：精準指出哪些 byte 要被寫（支援 SB/SH/SW）
    //CMD_WB_LINE：通常固定全 1（8'hFF），因為是整條 line 寫回

    // ---------------- L2 response (streaming on rsp channel) ----------------
    input                   l2_rsp_valid,//L2 表示：「我現在有一個 response beat 可以送給你」
    output                  l2_rsp_ready,//DCache 表示：「我這拍準備好接收一個 response beat」
    input  [BUS_W-1:0]      l2_rsp_rdata,//L2 回傳的資料（只對讀有意義）
    input                   l2_rsp_last,         // 表示「這個 beat 是這筆 burst 的最後一拍」
    input                   l2_rsp_err           // 表示這個 response（或這筆 transaction）有錯誤
);

    // ---------------- Derived geometry ----------------
    localparam integer BUS_BYTES   = BUS_W/8; //匯流排一次傳輸的 byte 數
    localparam integer LINE_BITS   = LINE_BYTES*8;//一條 cache line 的位元數
    localparam integer SETS        = (CACHE_BYTES/(LINE_BYTES*WAYS)); // 128KB/(64B*2)=1024 //以註解中的數值：128KB ÷ (64B × 2-way) = 1024 sets
    localparam integer OFFSET_BITS = 6;   // log2(64B)
    localparam integer INDEX_BITS  = $clog2(SETS);
    localparam integer TAG_BITS    = ADDR_W - OFFSET_BITS - INDEX_BITS;

    // ---------------- L2 commands (example) ----------------
    localparam [1:0] CMD_LINE_RD = 2'b00; // 快取填充用的整條 line 讀取
    localparam [1:0] CMD_UC_RD   = 2'b01; //uncacheable 讀取
    localparam [1:0] CMD_UC_WR   = 2'b10; // uncacheable 寫入
    localparam [1:0] CMD_WB_LINE = 2'b11; // 寫回整條 line

    // ---------------- State machine ----------------
    localparam [3:0]
        S_IDLE          = 4'd0, //閒置，等待 CPU 請求
        S_LOOKUP0       = 4'd1, // registered SRAM read發起/對齊到 SRAM 的註冊讀
        S_LOOKUP1       = 4'd2, // hit/miss decision + (store hit write)第 2 拍完成查找，做 hit/miss 判斷，若是 store hit，這拍可能直接寫入。
        S_RESP          = 4'd3, // CPU response handshake回應 CPU，完成握手/返回資料或確認寫入

        S_MISS_SELECT   = 4'd4, // choose victim; capture wb/refill info ，miss 時選 victim way，並擷取需要 writeback/ refill 的資訊。
        S_WB_STREAM     = 4'd5, // stream 8 beats of victim line 把 victim line 的資料以 8 個 beat 串流寫回
        S_WB_WAIT       = 4'd6, // wait for L2 ack/resp after writeback (1 beat) 等待 L2/匯流排對 writeback 的回覆（通常 1 beat）

        S_REFILL_REQ    = 4'd7, // issue LINE_RD request 發起 line read（填充）請求。
        S_REFILL_RECV   = 4'd8, // receive 8 beats into refill buffer 接收 8 個 beat 的 line 資料，放進 refill buffer
        S_REFILL_COMMIT = 4'd9, // write line into cache 把 refill buffer 寫入 cache line（含 tag/valid 等）。

        S_UC_REQ        = 4'd10, // issue UC_RD/UC_WR request 發起 uncacheable 讀/寫請求（不進 cache）
        S_UC_WAIT       = 4'd11  // wait for UC response (1 beat) 等待 uncacheable 回覆（通常 1 beat）
    ;

    reg [3:0] state;

    // ---------------- Request latch ----------------
    reg [ADDR_W-1:0]     req_addr_r;
    reg                 req_we_r;
    reg [CPU_DATA_W-1:0] req_wdata_r;
    reg [CPU_STRB_W-1:0] req_wstrb_r;
    reg [1:0]            req_size_r;
    reg                 req_uncached_r;
    reg [INDEX_BITS-1:0] req_index_r;
    reg [TAG_BITS-1:0]   req_tag_r;
    reg [3:0]            req_word_r;
    reg                  req_word_hi_r;

    // ---------------- Tag/Data/Meta arrays ----------------
    // Way 0
    reg [TAG_BITS-1:0]    tag0_mem [0:SETS-1];
    reg                  val0_mem [0:SETS-1];
    reg                  dir0_mem [0:SETS-1];
    (* ram_style = "block" *) reg [LINE_BITS-1:0] data0_mem [0:SETS-1];//(* ram_style = "block" *) 給 Vivado 一個提示：這個 array 請優先推論成 Block RAM
    // Way 1
    reg [TAG_BITS-1:0]    tag1_mem [0:SETS-1];
    reg                  val1_mem [0:SETS-1];
    reg                  dir1_mem [0:SETS-1];
    (* ram_style = "block" *) reg [LINE_BITS-1:0] data1_mem [0:SETS-1];

    // 1-bit LRU per set: lru=0 => way0 is LRU(victim), lru=1 => way1 is LRU(victim)
    reg lru_mem [0:SETS-1];

    // ---------------- Registered read outputs ----------------
    reg [INDEX_BITS-1:0]  index_r;

    reg [TAG_BITS-1:0]    tag0_r, tag1_r;
    reg                  val0_r, val1_r;//讀出兩個 way 的 valid bit
    reg                  dir0_r, dir1_r;//讀出兩個 way 的 dirty bit
    reg [LINE_BITS-1:0]   line0_r, line1_r;
    reg                  lru_r;

    // ---------------- Hit detection ----------------
    wire hit0_w = val0_r && (tag0_r == req_tag_r);
    wire hit1_w = val1_r && (tag1_r == req_tag_r);
    wire hit_w  = hit0_w || hit1_w;

    // Used way on hit (0 or 1)
    wire used_way_w = hit1_w ? 1'b1 : 1'b0;

    // ---------------- Victim selection ----------------
    //當發生 cache miss，這條被換掉的 line 就叫 victim line
    wire victim_way_w   = lru_r; // 0 -> victim way0, 1 -> victim way1 ，victim_way_w 表示「這次要被替換的是 way0 還是 way1」
    wire victim_valid_w = (victim_way_w==1'b0) ? val0_r : val1_r;//victim 這個 way 目前有沒有「有效的 line」
    wire victim_dirty_w = (victim_way_w==1'b0) ? dir0_r : dir1_r;//victim line 是否 dirty
    wire [TAG_BITS-1:0]  victim_tag_w  = (victim_way_w==1'b0) ? tag0_r  : tag1_r;//victim line 的 tag，用來組出它在 memory 對應的實際地址，以便 writeback
    wire [LINE_BITS-1:0] victim_line_w = (victim_way_w==1'b0) ? line0_r : line1_r;//victim line 的整條資料（64B）。
    //若需要 writeback，就要把這 64B 拆成 8 個 64-bit beats 送到 L2。

    // ---------------- Writeback / refill buffers ----------------
    reg [2:0]            beat_cnt_r;       // beat_cnt_r 用來記錄你目前在送/收第幾個 beat
    reg [ADDR_W-1:0]     wb_addr_r;//當 victim dirty 需要 writeback 時，這是那條 victim line 在 memory 的 line-aligned base address
    reg [LINE_BITS-1:0]  wb_line_r; //writeback 要送出的整條 64B 資料 拿來「寫回（writeback）」的 victim line（從 cache 裡被趕出去的舊資料）

    reg [LINE_BITS-1:0]  refill_line_r; //refill 暫存 buffer：整條收滿才 commit，拿來「補入（refill）」的新 line
    reg                  refill_way_r;     // refill 要寫入哪個 way
    reg [TAG_BITS-1:0]    refill_tag_r; // refill 回來的這條 line 要被標成哪個 tag
    reg                  wb_err_r; // latch WB ack error for pending miss response
    // temps for store-hit merge (declared here for Verilog-2001 compatibility)
    reg [31:0]            old_w;
    reg [31:0]            merged_w;
    reg [LINE_BITS-1:0]   new_line;
    //old_w：從 cache line 裡取出原本的 32-bit word
    //merged_w：用 wstrb 把 req_wdata 的部份 byte 蓋到 old_w 上
    //new_line：把 merged_w 塞回 line 的對應 word 位置，得到更新後的整條 line

    // ---------------- Helper functions (Verilog-2001 compliant) ----------------
    function [63:0] line_get_beat64;//用途：在 writeback/或 L2 串流傳輸時，把 line 拆成 8 個 64-bit beat 送出去
        input [LINE_BITS-1:0] line;
        input [2:0] beat;
        integer sh;
        begin
            sh = {beat, 6'b0}; // beat * 64 (unsigned)
            line_get_beat64 = (line >> sh);
        end
    endfunction

    function [LINE_BITS-1:0] line_set_beat64;//把 line[(beat*64 + 63) : (beat*64)] 這段 64 bits 改成 data，其他 bits 不變
        input [LINE_BITS-1:0] line;
        input [2:0] beat;
        input [63:0] data;
        reg [LINE_BITS-1:0] mask;
        reg [LINE_BITS-1:0] data_ext;
        integer sh;
        begin
            sh = {beat, 6'b0}; // beat * 64 (unsigned)
            mask = ({{(LINE_BITS-64){1'b0}}, 64'hFFFF_FFFF_FFFF_FFFF} << sh);
            data_ext = ({{(LINE_BITS-64){1'b0}}, data} << sh);
            line_set_beat64 = (line & ~mask) | data_ext;
        end
    endfunction

    function [31:0] line_get_word32;//從整條 line（512 bits）中，取出第 word 個 32-bit word 回傳。
        input [LINE_BITS-1:0] line;
        input [3:0] word;
        integer sh;
        begin
            sh = {word, 5'b0}; // word * 32 (unsigned)
            line_get_word32 = (line >> sh);
        end
    endfunction

    function [LINE_BITS-1:0] line_set_word32;//line_set_word32(line, word, data) 
    //用來把一條 512-bit cache line（64B）裡的第 word 個 32-bit word（0..15）更新成新的 data，其他 bits 都保持不變。
        input [LINE_BITS-1:0] line;
        input [3:0] word;
        input [31:0] data;
        reg [LINE_BITS-1:0] mask;
        reg [LINE_BITS-1:0] data_ext;
        integer sh;
        begin
            sh = {word, 5'b0}; // word * 32 (unsigned)
            mask = ({{(LINE_BITS-32){1'b0}}, 32'hFFFF_FFFF} << sh);
            data_ext = ({{(LINE_BITS-32){1'b0}}, data} << sh);
            line_set_word32 = (line & ~mask) | data_ext;
        end
    endfunction

    function [31:0] merge_wstrb32;//用來做 byte-enable 的寫入合併
        input [31:0] old_w;
        input [31:0] new_w;
        input [3:0]  wstrb;
        reg [31:0] mask;
        begin
            mask = { {8{wstrb[3]}}, {8{wstrb[2]}}, {8{wstrb[1]}}, {8{wstrb[0]}} };
            merge_wstrb32 = (old_w & ~mask) | (new_w & mask);
        end
    endfunction
    //Store Byte（SB）
    //假設你要寫最低 byte：
    //wstrb = 4'b0001
    //mask = 32'h000000FF
    //結果：只有 merged_w[7:0] 來自 new_w[7:0]，其他 24 bits 保留 old

    //Store Halfword（SH）寫低半部
    //wstrb = 4'b0011
    //mask = 32'h0000FFFF
    //結果：[15:0] 更新、[31:16] 保留

    // ---------------- CPU handshake ----------------
    assign cpu_req_ready = (state == S_IDLE);
    assign l2_rsp_ready  = (state == S_WB_WAIT) ||
                           (state == S_REFILL_RECV) ||
                           (state == S_UC_WAIT) ||
                           ((state == S_REFILL_REQ) && l2_req_ready) ||
                           ((state == S_UC_REQ) && l2_req_ready) ||
                           ((state == S_WB_STREAM) && l2_req_ready && (beat_cnt_r == 3'd7));
    // ---------------- Main sequential logic ----------------
    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;

            cpu_rsp_valid <= 1'b0;
            cpu_rsp_rdata <= {CPU_DATA_W{1'b0}};
            cpu_rsp_err   <= 1'b0;

            l2_req_valid  <= 1'b0;
            l2_req_cmd    <= 2'b00;
            l2_req_addr   <= {ADDR_W{1'b0}};
            l2_req_size   <= 3'b011;
            l2_req_len    <= 8'd0;
            l2_req_wdata  <= {BUS_W{1'b0}};
            l2_req_wstrb  <= {(BUS_W/8){1'b0}};


            req_addr_r     <= {ADDR_W{1'b0}};//這筆 request 的位址
            req_we_r       <= 1'b0;//這筆是 store(1) 還是 load(0)
            req_wdata_r    <= {CPU_DATA_W{1'b0}};//store 要寫入的資料
            req_wstrb_r    <= {CPU_STRB_W{1'b0}};//store 的 byte enable（SB/SH/SW）
            req_size_r     <= 2'b00;//資料大小（1B/2B/4B）供對齊檢查、或傳給 L2/UC 用
            req_uncached_r <= 1'b0;//是否 bypass cache
            req_index_r    <= {INDEX_BITS{1'b0}};
            req_tag_r      <= {TAG_BITS{1'b0}};
            req_word_r     <= 4'b0;
            req_word_hi_r  <= 1'b0;
            
            //某個 set 的 snapshot（讀出結果），用來在下一個 cycle 做 lookup/決策
            index_r <= {INDEX_BITS{1'b0}};
            tag0_r  <= {TAG_BITS{1'b0}};
            tag1_r  <= {TAG_BITS{1'b0}};
            val0_r  <= 1'b0;
            val1_r  <= 1'b0;
            dir0_r  <= 1'b0;//讀出兩個 way 的 dirty bit
            dir1_r  <= 1'b0;
            line0_r <= {LINE_BITS{1'b0}};//讀出兩個 way 的整條 64B line data
            line1_r <= {LINE_BITS{1'b0}};
            lru_r   <= 1'b0;//讀出該 set 的 1-bit LRU 值

            beat_cnt_r    <= 3'd0;//burst beat 計數器
            wb_addr_r     <= {ADDR_W{1'b0}};
            wb_line_r     <= {LINE_BITS{1'b0}};
            refill_line_r <= {LINE_BITS{1'b0}};//是 refill 暫存 buffer
            refill_way_r  <= 1'b0;
            refill_tag_r  <= {TAG_BITS{1'b0}};
            wb_err_r      <= 1'b0;

            // init meta (optional; for synth you may omit this loop)
            for (i=0; i<SETS; i=i+1) begin
                val0_mem[i] <= 1'b0;
                val1_mem[i] <= 1'b0;
                dir0_mem[i] <= 1'b0;
                dir1_mem[i] <= 1'b0;
                lru_mem[i]  <= 1'b0;
`ifndef SYNTHESIS
                tag0_mem[i] <= {TAG_BITS{1'b0}};
                tag1_mem[i] <= {TAG_BITS{1'b0}};
                data0_mem[i] <= {LINE_BITS{1'b0}};
                data1_mem[i] <= {LINE_BITS{1'b0}};
`endif
            end
        end else begin
            // defaults each cycle

            // clear cpu_rsp_valid when accepted
            if (cpu_rsp_valid && cpu_rsp_ready) begin
                cpu_rsp_valid <= 1'b0;
            end

            // deassert L2 req valid unless state keeps it asserted
            if (!(state==S_WB_STREAM || state==S_REFILL_REQ || state==S_UC_REQ)) begin
                l2_req_valid <= 1'b0;
            end

            case (state)
                S_IDLE: begin
                    cpu_rsp_err <= 1'b0;

                    if (cpu_req_valid) begin
                        req_addr_r     <= cpu_req_addr;
                        req_we_r       <= cpu_req_we;
                        req_wdata_r    <= cpu_req_wdata;
                        req_wstrb_r    <= cpu_req_wstrb;
                        req_size_r     <= cpu_req_size;
                        req_uncached_r <= cpu_req_uncached;
                        req_index_r    <= cpu_req_addr[OFFSET_BITS+INDEX_BITS-1:OFFSET_BITS];
                        req_tag_r      <= cpu_req_addr[ADDR_W-1:OFFSET_BITS+INDEX_BITS];
                        req_word_r     <= cpu_req_addr[OFFSET_BITS-1:2];
                        req_word_hi_r  <= cpu_req_addr[2];
                        wb_err_r       <= 1'b0;
                        state <= S_LOOKUP0;
                    end
                end

                // 1-cycle array read
                S_LOOKUP0: begin
                    index_r <= req_index_r;

                    tag0_r  <= tag0_mem[req_index_r];
                    val0_r  <= val0_mem[req_index_r];
                    dir0_r  <= dir0_mem[req_index_r];
                    line0_r <= data0_mem[req_index_r];

                    tag1_r  <= tag1_mem[req_index_r];
                    val1_r  <= val1_mem[req_index_r];
                    dir1_r  <= dir1_mem[req_index_r];
                    line1_r <= data1_mem[req_index_r];

                    lru_r   <= lru_mem[req_index_r];

                    state <= S_LOOKUP1;
                end

                // hit/miss decision
                S_LOOKUP1: begin
                    if (req_uncached_r) begin
                        state <= S_UC_REQ;
                    end 
                    else if (hit_w) begin
                        // LRU update
                        lru_mem[index_r] <= (used_way_w==1'b0) ? 1'b1 : 1'b0;

                        if (!req_we_r) begin
                            // load hit
                            if (used_way_w==1'b0) cpu_rsp_rdata <= line_get_word32(line0_r, req_word_r);
                            else                  cpu_rsp_rdata <= line_get_word32(line1_r, req_word_r);

                            cpu_rsp_err   <= 1'b0;
                            cpu_rsp_valid <= 1'b1;
                            state <= S_RESP;
                        end else begin
                            // store hit (byte mask merge)
                            if (hit0_w) begin
                                old_w    = line_get_word32(line0_r, req_word_r);//從line中取出舊的word
                                merged_w = merge_wstrb32(old_w, req_wdata_r, req_wstrb_r);//改舊的word中的byte
                                new_line = line_set_word32(line0_r, req_word_r, merged_w);//把改過後的新word合併到新的line上
                                data0_mem[index_r] <= new_line;
                                dir0_mem[index_r]  <= 1'b1;
                            end else begin
                                old_w    = line_get_word32(line1_r, req_word_r);
                                merged_w = merge_wstrb32(old_w, req_wdata_r, req_wstrb_r);
                                new_line = line_set_word32(line1_r, req_word_r, merged_w);
                                data1_mem[index_r] <= new_line;
                                dir1_mem[index_r]  <= 1'b1;
                            end

                            cpu_rsp_rdata <= {CPU_DATA_W{1'b0}};//寫入不需要會傳資料
                            cpu_rsp_err   <= 1'b0;
                            cpu_rsp_valid <= 1'b1;
                            state <= S_RESP;
                        end
                    end 
                    else begin
                        // miss: store miss => no-WA => UC_WR
                        if (req_we_r) state <= S_UC_REQ;//store
                        else          state <= S_MISS_SELECT;//load
                    end
                end

                S_RESP: begin
                    if (cpu_rsp_valid && cpu_rsp_ready) state <= S_IDLE;
                end

                // choose victim; if dirty => WB; else => refill
                S_MISS_SELECT: begin
                    refill_way_r <= victim_way_w;
                    refill_tag_r <= req_tag_r;

                    wb_line_r  <= victim_line_w;
                    wb_addr_r  <= { victim_tag_w, index_r, {OFFSET_BITS{1'b0}} };
                    beat_cnt_r <= 3'd0;

                    if (victim_valid_w && victim_dirty_w) state <= S_WB_STREAM;//只有在 victim line「有效」且「髒」時，才需要進入 S_WB_STREAM 做寫回。
                    else                                 state <= S_REFILL_REQ;//等待資料回復
                end

                // WB burst (8 beats on req channel)
                S_WB_STREAM: begin
                    l2_req_valid <= 1'b1;
                    l2_req_cmd   <= CMD_WB_LINE;
                    l2_req_addr  <= wb_addr_r;
                    l2_req_size  <= 3'b011;
                    l2_req_len   <= 8'd7;
                    l2_req_wdata <= line_get_beat64(wb_line_r, beat_cnt_r);
                    l2_req_wstrb <= { (BUS_W/8){1'b1} };

                    if (l2_req_ready) begin
                        if (beat_cnt_r == 3'd7) begin
                            state <= S_WB_WAIT;
                        end
                        beat_cnt_r <= beat_cnt_r + 3'd1;
                    end
                end

                // wait 1-beat ack (you可依你的L2協議改成不等ack)
                S_WB_WAIT: begin
                    if (l2_rsp_valid && l2_rsp_ready) begin
                        wb_err_r <= l2_rsp_err;
                        state <= S_REFILL_REQ;
                    end
                end

                // line read request (1 handshake)
                S_REFILL_REQ: begin
                    l2_req_valid <= 1'b1;
                    l2_req_cmd   <= CMD_LINE_RD;
                    l2_req_addr  <= { req_tag_r, index_r, {OFFSET_BITS{1'b0}} };
                    l2_req_size  <= 3'b011;
                    l2_req_len   <= 8'd7;
                    l2_req_wdata <= {BUS_W{1'b0}};//因為這是 讀 request，wdata/wstrb 無意義，清 0 讓波形乾淨
                    l2_req_wstrb <= {(BUS_W/8){1'b0}};

                    if (l2_req_ready) begin//refill request 已被 L2 接受，接下來就可以開始等 L2 回傳資料了
                        refill_line_r <= {LINE_BITS{1'b0}};
                        //因為從下一個 state S_REFILL_RECV 開始，你會逐拍把回來的 64-bit beat 塞進 refill_line_r：
                        //清成 0 可以避免殘留上一筆 refill 的內容beat_cnt_r=0 表示下一拍開始收的是 beat0
                        beat_cnt_r <= 3'd0;
                        state <= S_REFILL_RECV;
                    end
                end

                // receive 8 beats
                S_REFILL_RECV: begin
                    if (l2_rsp_valid && l2_rsp_ready) begin
                        refill_line_r <= line_set_beat64(refill_line_r, beat_cnt_r, l2_rsp_rdata);
                        // L2 may terminate early on error (single-beat ERR_RSP).
                        // Treat any early-last/error as transaction failure and
                        // return an error response instead of waiting forever.
                        if (l2_rsp_err) begin
                            cpu_rsp_rdata <= {CPU_DATA_W{1'b0}};
                            cpu_rsp_err   <= 1'b1 | wb_err_r;
                            cpu_rsp_valid <= 1'b1;
                            state <= S_RESP;
                        end else if (l2_rsp_last) begin
                            if (beat_cnt_r == 3'd7) begin
                                state <= S_REFILL_COMMIT;
                            end else begin
                                // Protocol mismatch: short LINE_RD without explicit error.
                                cpu_rsp_rdata <= {CPU_DATA_W{1'b0}};
                                cpu_rsp_err   <= 1'b1 | wb_err_r;
                                cpu_rsp_valid <= 1'b1;
                                state <= S_RESP;
                            end
                        end else begin
                            beat_cnt_r <= beat_cnt_r + 3'd1;
                        end
                    end
                end

                // commit line + respond load
                S_REFILL_COMMIT: begin
                    if (refill_way_r == 1'b0) begin
                        data0_mem[index_r] <= refill_line_r;
                        tag0_mem[index_r]  <= refill_tag_r;
                        val0_mem[index_r]  <= 1'b1;
                        dir0_mem[index_r]  <= 1'b0;
                    end else begin
                        data1_mem[index_r] <= refill_line_r;
                        tag1_mem[index_r]  <= refill_tag_r;
                        val1_mem[index_r]  <= 1'b1;
                        dir1_mem[index_r]  <= 1'b0;
                    end
                    lru_mem[index_r] <= (refill_way_r==1'b0) ? 1'b1 : 1'b0;

                    cpu_rsp_rdata <= line_get_word32(refill_line_r, req_word_r);
                    cpu_rsp_err   <= l2_rsp_err | wb_err_r;
                    cpu_rsp_valid <= 1'b1;
                    state <= S_RESP;
                end

                // uncached read/write
                S_UC_REQ: begin
                    l2_req_valid <= 1'b1;
                    l2_req_addr  <= req_addr_r;
                    l2_req_len   <= 8'd0;

                    if (!req_we_r) begin//uncached read（load）
                        l2_req_cmd   <= CMD_UC_RD;
                        l2_req_size  <= 3'b010; // 4B
                        l2_req_wdata <= {BUS_W{1'b0}};
                        l2_req_wstrb <= {(BUS_W/8){1'b0}};
                    end else begin//uncached write（store）
                        l2_req_cmd  <= CMD_UC_WR;
                        l2_req_size <= 3'b010; // 4B

                        if (req_word_hi_r) begin
                            l2_req_wdata <= {req_wdata_r, 32'h0};
                            l2_req_wstrb <= {req_wstrb_r, 4'h0};
                        end else begin
                            l2_req_wdata <= {32'h0, req_wdata_r};
                            l2_req_wstrb <= {4'h0, req_wstrb_r};
                        end
                    end

                    if (l2_req_ready) begin
                        state <= S_UC_WAIT;
                    end
                end

                S_UC_WAIT: begin
                    if (l2_rsp_valid && l2_rsp_ready) begin
                        cpu_rsp_err <= l2_rsp_err;
                        if (!req_we_r) cpu_rsp_rdata <= req_word_hi_r ? l2_rsp_rdata[63:32] : l2_rsp_rdata[31:0];
                        else           cpu_rsp_rdata <= {CPU_DATA_W{1'b0}};
                        cpu_rsp_valid <= 1'b1;
                        state <= S_RESP;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
