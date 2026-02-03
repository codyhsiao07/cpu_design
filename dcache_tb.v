`timescale 1ns/1ps

module dcache_tb;
  localparam ADDR_W      = 32;
  localparam CPU_DATA_W  = 32;
  localparam CPU_STRB_W  = 4;
  localparam BUS_W       = 64;
  localparam LINE_BYTES  = 64;
  localparam CACHE_BYTES = 131072;
  localparam WAYS        = 2;

  // DUT I/O
  reg                   clk;
  reg                   rst_n;

  reg                   cpu_req_valid;
  wire                  cpu_req_ready;
  reg  [ADDR_W-1:0]     cpu_req_addr;
  reg                   cpu_req_we;
  reg  [CPU_DATA_W-1:0] cpu_req_wdata;
  reg  [CPU_STRB_W-1:0] cpu_req_wstrb;
  reg  [1:0]            cpu_req_size;
  reg                   cpu_req_uncached;

  wire                  cpu_rsp_valid;
  reg                   cpu_rsp_ready;
  wire [CPU_DATA_W-1:0] cpu_rsp_rdata;
  wire                  cpu_rsp_err;

  wire                  l2_req_valid;
  reg                   l2_req_ready;
  wire [1:0]            l2_req_cmd;
  wire [ADDR_W-1:0]     l2_req_addr;
  wire [2:0]            l2_req_size;
  wire [7:0]            l2_req_len;
  wire [BUS_W-1:0]      l2_req_wdata;
  wire [(BUS_W/8)-1:0]  l2_req_wstrb;

  reg                   l2_rsp_valid;
  wire                  l2_rsp_ready;
  reg  [BUS_W-1:0]      l2_rsp_rdata;
  reg                   l2_rsp_last;
  reg                   l2_rsp_err;

  dcache_blocking #(
    .ADDR_W(ADDR_W),
    .CPU_DATA_W(CPU_DATA_W),
    .CPU_STRB_W(CPU_STRB_W),
    .BUS_W(BUS_W),
    .LINE_BYTES(LINE_BYTES),
    .CACHE_BYTES(CACHE_BYTES),
    .WAYS(WAYS)
  ) dut (
    .clk(clk),
    .rst_n(rst_n),
    .cpu_req_valid(cpu_req_valid),
    .cpu_req_ready(cpu_req_ready),
    .cpu_req_addr(cpu_req_addr),
    .cpu_req_we(cpu_req_we),
    .cpu_req_wdata(cpu_req_wdata),
    .cpu_req_wstrb(cpu_req_wstrb),
    .cpu_req_size(cpu_req_size),
    .cpu_req_uncached(cpu_req_uncached),
    .cpu_rsp_valid(cpu_rsp_valid),
    .cpu_rsp_ready(cpu_rsp_ready),
    .cpu_rsp_rdata(cpu_rsp_rdata),
    .cpu_rsp_err(cpu_rsp_err),
    .l2_req_valid(l2_req_valid),
    .l2_req_ready(l2_req_ready),
    .l2_req_cmd(l2_req_cmd),
    .l2_req_addr(l2_req_addr),
    .l2_req_size(l2_req_size),
    .l2_req_len(l2_req_len),
    .l2_req_wdata(l2_req_wdata),
    .l2_req_wstrb(l2_req_wstrb),
    .l2_rsp_valid(l2_rsp_valid),
    .l2_rsp_ready(l2_rsp_ready),
    .l2_rsp_rdata(l2_rsp_rdata),
    .l2_rsp_last(l2_rsp_last),
    .l2_rsp_err(l2_rsp_err)
  );

  // clock
  always #5 clk = ~clk;

  // ---------------------------
  // Simple backing memory model
  // ---------------------------
  localparam MEM_WORDS = 65536; // 256KB
  reg [31:0] mem [0:MEM_WORDS-1];
  reg [31:0] mem_ref [0:MEM_WORDS-1];

  function [31:0] mem_read_word;
    input [ADDR_W-1:0] addr;
    reg [15:0] idx;
    begin
      idx = addr[17:2];
      mem_read_word = mem[idx];
    end
  endfunction

  function [31:0] mem_ref_read_word;
    input [ADDR_W-1:0] addr;
    reg [15:0] idx;
    begin
      idx = addr[17:2];
      mem_ref_read_word = mem_ref[idx];
    end
  endfunction

  function [7:0] get_byte;
    input [63:0] data;
    input integer idx;
    begin
      case (idx)
        0: get_byte = data[7:0];
        1: get_byte = data[15:8];
        2: get_byte = data[23:16];
        3: get_byte = data[31:24];
        4: get_byte = data[39:32];
        5: get_byte = data[47:40];
        6: get_byte = data[55:48];
        7: get_byte = data[63:56];
        default: get_byte = 8'h00;
      endcase
    end
  endfunction

  task mem_write_byte;
    input [ADDR_W-1:0] addr;
    input [7:0] value;
    reg [31:0] word;
    integer idx;
    begin
      idx = addr[17:2];
      word = mem[idx];
      case (addr[1:0])
        2'd0: word[7:0]   = value;
        2'd1: word[15:8]  = value;
        2'd2: word[23:16] = value;
        2'd3: word[31:24] = value;
      endcase
      mem[idx] = word;
    end
  endtask

  task mem_ref_write_byte;
    input [ADDR_W-1:0] addr;
    input [7:0] value;
    reg [31:0] word;
    integer idx;
    begin
      idx = addr[17:2];
      word = mem_ref[idx];
      case (addr[1:0])
        2'd0: word[7:0]   = value;
        2'd1: word[15:8]  = value;
        2'd2: word[23:16] = value;
        2'd3: word[31:24] = value;
      endcase
      mem_ref[idx] = word;
    end
  endtask

  task mem_write64;
    input [ADDR_W-1:0] addr;
    input [63:0] data;
    input [7:0]  wstrb;
    integer b;
    begin
      for (b = 0; b < 8; b = b + 1) begin
        if (wstrb[b]) begin
          mem_write_byte(addr + b, get_byte(data, b));
        end
      end
    end
  endtask

  task mem_ref_write64;
    input [ADDR_W-1:0] addr;
    input [63:0] data;
    input [7:0]  wstrb;
    integer b;
    begin
      for (b = 0; b < 8; b = b + 1) begin
        if (wstrb[b]) begin
          mem_ref_write_byte(addr + b, get_byte(data, b));
        end
      end
    end
  endtask

  function [63:0] make_beat64;
    input [ADDR_W-1:0] base;
    input [2:0] beat;
    reg [31:0] w0;
    reg [31:0] w1;
    begin
      w0 = mem_read_word(base + {beat, 3'b0});
      w1 = mem_read_word(base + {beat, 3'b0} + 4);
      make_beat64 = {w1, w0};
    end
  endfunction

  function [63:0] make_beat64_ref;
    input [ADDR_W-1:0] base;
    input [2:0] beat;
    reg [31:0] w0;
    reg [31:0] w1;
    begin
      w0 = mem_ref_read_word(base + {beat, 3'b0});
      w1 = mem_ref_read_word(base + {beat, 3'b0} + 4);
      make_beat64_ref = {w1, w0};
    end
  endfunction

  function [63:0] uc_read_data;
    input [ADDR_W-1:0] addr;
    input [31:0] word;
    begin
      if (addr[2])
        uc_read_data = {word, 32'h0};
      else
        uc_read_data = {32'h0, word};
    end
  endfunction

  function [63:0] uc_read_data_ref;
    input [ADDR_W-1:0] addr;
    input [31:0] word;
    begin
      if (addr[2])
        uc_read_data_ref = {word, 32'h0};
      else
        uc_read_data_ref = {32'h0, word};
    end
  endfunction

  function [31:0] apply_wstrb32;
    input [31:0] old_w;
    input [31:0] new_w;
    input [3:0]  wstrb;
    reg [31:0] mask;
    begin
      mask = { {8{wstrb[3]}}, {8{wstrb[2]}}, {8{wstrb[1]}}, {8{wstrb[0]}} };
      apply_wstrb32 = (old_w & ~mask) | (new_w & mask);
    end
  endfunction

  function [3:0] wstrb_from_size_addr;
    input [1:0] size;
    input [ADDR_W-1:0] addr;
    begin
      case (size)
        2'b00: wstrb_from_size_addr = (4'b0001 << addr[1:0]); // byte
        2'b01: wstrb_from_size_addr = addr[1] ? 4'b1100 : 4'b0011; // halfword
        default: wstrb_from_size_addr = 4'b1111; // word
      endcase
    end
  endfunction

  // ---------------------------
  // Shadow cache model (scoreboard)
  // ---------------------------
  localparam OFFSET_BITS = 6;
  localparam INDEX_BITS  = 10;
  localparam TAG_BITS    = ADDR_W - OFFSET_BITS - INDEX_BITS;
  localparam LINE_BITS   = LINE_BYTES * 8;
  localparam SETS        = (CACHE_BYTES / (LINE_BYTES * WAYS));

  reg [TAG_BITS-1:0]   sh_tag0   [0:SETS-1];
  reg [TAG_BITS-1:0]   sh_tag1   [0:SETS-1];
  reg                 sh_valid0 [0:SETS-1];
  reg                 sh_valid1 [0:SETS-1];
  reg                 sh_dirty0 [0:SETS-1];
  reg                 sh_dirty1 [0:SETS-1];
  reg [LINE_BITS-1:0]  sh_data0  [0:SETS-1];
  reg [LINE_BITS-1:0]  sh_data1  [0:SETS-1];
  reg                 sh_lru    [0:SETS-1]; // 0 -> way0 LRU, 1 -> way1 LRU

  // ---------------------------
  // Trace buffer (last N ops)
  // ---------------------------
  localparam TRACE_DEPTH = 64;
  reg [1:0]           trace_op   [0:TRACE_DEPTH-1]; // 0=load, 1=store
  reg [ADDR_W-1:0]    trace_addr [0:TRACE_DEPTH-1];
  reg [31:0]          trace_data [0:TRACE_DEPTH-1];
  reg [3:0]           trace_wstrb[0:TRACE_DEPTH-1];
  reg                 trace_uc   [0:TRACE_DEPTH-1];
  reg [31:0]          trace_exp  [0:TRACE_DEPTH-1];
  integer             trace_ptr;

  task trace_reset;
    integer t;
    begin
      trace_ptr = 0;
      for (t = 0; t < TRACE_DEPTH; t = t + 1) begin
        trace_op[t]    = 2'b00;
        trace_addr[t]  = {ADDR_W{1'b0}};
        trace_data[t]  = 32'b0;
        trace_wstrb[t] = 4'b0;
        trace_uc[t]    = 1'b0;
        trace_exp[t]   = 32'b0;
      end
    end
  endtask

  task trace_log;
    input [1:0]        op;
    input [ADDR_W-1:0] addr;
    input [31:0]       data;
    input [3:0]        wstrb;
    input              uncached;
    input [31:0]       exp;
    begin
      trace_op[trace_ptr]    = op;
      trace_addr[trace_ptr]  = addr;
      trace_data[trace_ptr]  = data;
      trace_wstrb[trace_ptr] = wstrb;
      trace_uc[trace_ptr]    = uncached;
      trace_exp[trace_ptr]   = exp;
      if (trace_ptr == (TRACE_DEPTH-1))
        trace_ptr = 0;
      else
        trace_ptr = trace_ptr + 1;
    end
  endtask

  task trace_dump;
    integer t;
    integer idx;
    begin
      $display("---- TRACE DUMP (last %0d ops) ----", TRACE_DEPTH);
      for (t = 0; t < TRACE_DEPTH; t = t + 1) begin
        idx = trace_ptr + t;
        if (idx >= TRACE_DEPTH)
          idx = idx - TRACE_DEPTH;
        if (trace_op[idx] == 2'b00)
          $display("  [%0d] L addr=%h exp=%h uc=%b", t, trace_addr[idx], trace_exp[idx], trace_uc[idx]);
        else
          $display("  [%0d] S addr=%h data=%h wstrb=%b uc=%b", t, trace_addr[idx], trace_data[idx], trace_wstrb[idx], trace_uc[idx]);
      end
      $display("---- END TRACE ----");
    end
  endtask

  integer cov_load;
  integer cov_store;
  integer cov_load_hit;
  integer cov_load_miss;
  integer cov_store_hit;
  integer cov_store_miss;
  integer cov_uc_load;
  integer cov_uc_store;
  integer cov_store_full;
  integer cov_store_partial;
  integer cov_uc_hi;
  integer cov_uc_lo;
  integer cov_l2_req_bp;
  integer cov_l2_rsp_bp;
  integer cov_cpu_rsp_bp;
  integer cov_ld_sz_b;
  integer cov_ld_sz_h;
  integer cov_ld_sz_w;
  integer cov_st_sz_b;
  integer cov_st_sz_h;
  integer cov_st_sz_w;

  function [31:0] line_get_word32;
    input [LINE_BITS-1:0] line;
    input [3:0] word;
    integer sh;
    begin
      sh = {word, 5'b0}; // word * 32 (unsigned)
      line_get_word32 = (line >> sh);
    end
  endfunction

  function [LINE_BITS-1:0] line_set_word32;
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

  function [LINE_BITS-1:0] build_line_from_mem;
    input [ADDR_W-1:0] base;
    integer w;
    reg [LINE_BITS-1:0] line;
    begin
      line = {LINE_BITS{1'b0}};
      for (w = 0; w < 16; w = w + 1) begin
        line = line_set_word32(line, w[3:0], mem_read_word(base + (w * 4)));
      end
      build_line_from_mem = line;
    end
  endfunction

  function [LINE_BITS-1:0] build_line_from_mem_ref;
    input [ADDR_W-1:0] base;
    integer w;
    reg [LINE_BITS-1:0] line;
    begin
      line = {LINE_BITS{1'b0}};
      for (w = 0; w < 16; w = w + 1) begin
        line = line_set_word32(line, w[3:0], mem_ref_read_word(base + (w * 4)));
      end
      build_line_from_mem_ref = line;
    end
  endfunction

  task mem_write_word_wstrb;
    input [ADDR_W-1:0] addr;
    input [31:0] data;
    input [3:0] wstrb;
    reg [31:0] old_w;
    begin
      old_w = mem_read_word(addr);
      mem[addr[17:2]] = apply_wstrb32(old_w, data, wstrb);
    end
  endtask

  task mem_ref_write_word_wstrb;
    input [ADDR_W-1:0] addr;
    input [31:0] data;
    input [3:0] wstrb;
    reg [31:0] old_w;
    begin
      old_w = mem_ref_read_word(addr);
      mem_ref[addr[17:2]] = apply_wstrb32(old_w, data, wstrb);
    end
  endtask

  task write_line_to_mem;
    input [ADDR_W-1:0] base;
    input [LINE_BITS-1:0] line;
    integer w;
    begin
      for (w = 0; w < 16; w = w + 1) begin
        mem[base[17:2] + w] = line_get_word32(line, w[3:0]);
      end
    end
  endtask

  task write_line_to_mem_ref;
    input [ADDR_W-1:0] base;
    input [LINE_BITS-1:0] line;
    integer w;
    begin
      for (w = 0; w < 16; w = w + 1) begin
        mem_ref[base[17:2] + w] = line_get_word32(line, w[3:0]);
      end
    end
  endtask

  task model_reset;
    integer s;
    begin
      for (s = 0; s < SETS; s = s + 1) begin
        sh_tag0[s]   = {TAG_BITS{1'b0}};
        sh_tag1[s]   = {TAG_BITS{1'b0}};
        sh_valid0[s] = 1'b0;
        sh_valid1[s] = 1'b0;
        sh_dirty0[s] = 1'b0;
        sh_dirty1[s] = 1'b0;
        sh_data0[s]  = {LINE_BITS{1'b0}};
        sh_data1[s]  = {LINE_BITS{1'b0}};
        sh_lru[s]    = 1'b0;
      end
      cov_load = 0;
      cov_store = 0;
      cov_load_hit = 0;
      cov_load_miss = 0;
      cov_store_hit = 0;
      cov_store_miss = 0;
      cov_uc_load = 0;
      cov_uc_store = 0;
      cov_store_full = 0;
      cov_store_partial = 0;
      cov_uc_hi = 0;
      cov_uc_lo = 0;
      cov_l2_req_bp = 0;
      cov_l2_rsp_bp = 0;
      cov_cpu_rsp_bp = 0;
      cov_ld_sz_b = 0;
      cov_ld_sz_h = 0;
      cov_ld_sz_w = 0;
      cov_st_sz_b = 0;
      cov_st_sz_h = 0;
      cov_st_sz_w = 0;
      trace_reset();
    end
  endtask

  task model_load;
    input [ADDR_W-1:0] addr;
    input              uncached;
    output [31:0]      exp_data;
    reg [INDEX_BITS-1:0] idx;
    reg [TAG_BITS-1:0]   tag;
    reg [3:0]            word;
    reg                  hit0;
    reg                  hit1;
    reg                  victim;
    reg [LINE_BITS-1:0]  line;
    reg [ADDR_W-1:0]     base;
    begin
      if (uncached) begin
        cov_uc_load = cov_uc_load + 1;
        if (addr[2]) cov_uc_hi = cov_uc_hi + 1;
        else         cov_uc_lo = cov_uc_lo + 1;
        exp_data = mem_ref_read_word(addr);
      end else begin
        cov_load = cov_load + 1;
        idx  = addr[OFFSET_BITS+INDEX_BITS-1:OFFSET_BITS];
        tag  = addr[ADDR_W-1:OFFSET_BITS+INDEX_BITS];
        word = addr[OFFSET_BITS-1:2];
        hit0 = sh_valid0[idx] && (sh_tag0[idx] == tag);
        hit1 = sh_valid1[idx] && (sh_tag1[idx] == tag);

        if (hit0) begin
          cov_load_hit = cov_load_hit + 1;
          exp_data = line_get_word32(sh_data0[idx], word);
          sh_lru[idx] = 1'b1;
        end else if (hit1) begin
          cov_load_hit = cov_load_hit + 1;
          exp_data = line_get_word32(sh_data1[idx], word);
          sh_lru[idx] = 1'b0;
        end else begin
          cov_load_miss = cov_load_miss + 1;
          victim = sh_lru[idx];

          if (victim == 1'b0) begin
            if (sh_valid0[idx] && sh_dirty0[idx]) begin
              base = {sh_tag0[idx], idx, {OFFSET_BITS{1'b0}}};
              write_line_to_mem_ref(base, sh_data0[idx]);
            end
            line = build_line_from_mem_ref({tag, idx, {OFFSET_BITS{1'b0}}});
            sh_data0[idx]  = line;
            sh_tag0[idx]   = tag;
            sh_valid0[idx] = 1'b1;
            sh_dirty0[idx] = 1'b0;
            sh_lru[idx]    = 1'b1;
            exp_data = line_get_word32(line, word);
          end else begin
            if (sh_valid1[idx] && sh_dirty1[idx]) begin
              base = {sh_tag1[idx], idx, {OFFSET_BITS{1'b0}}};
              write_line_to_mem_ref(base, sh_data1[idx]);
            end
            line = build_line_from_mem_ref({tag, idx, {OFFSET_BITS{1'b0}}});
            sh_data1[idx]  = line;
            sh_tag1[idx]   = tag;
            sh_valid1[idx] = 1'b1;
            sh_dirty1[idx] = 1'b0;
            sh_lru[idx]    = 1'b0;
            exp_data = line_get_word32(line, word);
          end
        end
      end
    end
  endtask

  task model_store;
    input [ADDR_W-1:0] addr;
    input [31:0] data;
    input [3:0]  wstrb;
    input        uncached;
    reg [INDEX_BITS-1:0] idx;
    reg [TAG_BITS-1:0]   tag;
    reg [3:0]            word;
    reg                  hit0;
    reg                  hit1;
    reg [31:0]           old_w;
    begin
      if (uncached) begin
        cov_uc_store = cov_uc_store + 1;
        if (addr[2]) cov_uc_hi = cov_uc_hi + 1;
        else         cov_uc_lo = cov_uc_lo + 1;
        mem_ref_write_word_wstrb(addr, data, wstrb);
      end else begin
        cov_store = cov_store + 1;
        if (wstrb == 4'hF) cov_store_full = cov_store_full + 1;
        else               cov_store_partial = cov_store_partial + 1;
        idx  = addr[OFFSET_BITS+INDEX_BITS-1:OFFSET_BITS];
        tag  = addr[ADDR_W-1:OFFSET_BITS+INDEX_BITS];
        word = addr[OFFSET_BITS-1:2];
        hit0 = sh_valid0[idx] && (sh_tag0[idx] == tag);
        hit1 = sh_valid1[idx] && (sh_tag1[idx] == tag);

        if (hit0) begin
          cov_store_hit = cov_store_hit + 1;
          old_w = line_get_word32(sh_data0[idx], word);
          sh_data0[idx]  = line_set_word32(sh_data0[idx], word, apply_wstrb32(old_w, data, wstrb));
          sh_dirty0[idx] = 1'b1;
          sh_lru[idx]    = 1'b1;
        end else if (hit1) begin
          cov_store_hit = cov_store_hit + 1;
          old_w = line_get_word32(sh_data1[idx], word);
          sh_data1[idx]  = line_set_word32(sh_data1[idx], word, apply_wstrb32(old_w, data, wstrb));
          sh_dirty1[idx] = 1'b1;
          sh_lru[idx]    = 1'b0;
        end else begin
          cov_store_miss = cov_store_miss + 1;
          // store miss -> no-write-allocate (UC_WR)
          mem_ref_write_word_wstrb(addr, data, wstrb);
        end
      end
    end
  endtask

  // ---------------------------
  // L2 model + counters
  // ---------------------------
  reg        pending_rsp;
  reg [1:0]  rsp_type; // 0=line, 1=uc_rd, 2=uc_wr_ack, 3=wb_ack
  reg [ADDR_W-1:0] rsp_addr;
  reg [2:0]  rsp_beat;
  integer    rsp_delay;
  integer    rsp_delay_cfg;
  integer    rsp_gap_cfg;
  reg        rsp_err_latched;

  reg        wb_active;
  reg [2:0]  wb_beat;
  reg [ADDR_W-1:0] wb_addr;

  integer line_rd_cnt;
  integer uc_rd_cnt;
  integer uc_wr_cnt;
  integer wb_cnt;
  integer req_stall_cnt;
  reg     l2_err_once;
  reg     nonstream_accepted;
  reg     wb_accept_block;
  reg [31:0] uc_wr_data;
  reg [3:0]  uc_wr_strb;

  // l2_req_ready with optional stalling
  always @(*) begin
    if (req_stall_cnt > 0)
      l2_req_ready = 1'b0;
    else
      l2_req_ready = 1'b1;
  end

  // L2 response handling
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      l2_rsp_valid <= 1'b0;
      l2_rsp_rdata <= 64'b0;
      l2_rsp_last  <= 1'b0;
      l2_rsp_err   <= 1'b0;

      pending_rsp  <= 1'b0;
      rsp_type     <= 2'b00;
      rsp_addr     <= {ADDR_W{1'b0}};
      rsp_beat     <= 3'd0;
      rsp_delay    <= 0;
      rsp_delay_cfg<= 0;
      rsp_gap_cfg  <= 0;
      rsp_err_latched <= 1'b0;

      wb_active    <= 1'b0;
      wb_beat      <= 3'd0;
      wb_addr      <= {ADDR_W{1'b0}};

      line_rd_cnt  <= 0;
      uc_rd_cnt    <= 0;
      uc_wr_cnt    <= 0;
      wb_cnt       <= 0;
      req_stall_cnt<= 0;
      l2_err_once  <= 1'b0;
      nonstream_accepted <= 1'b0;
      wb_accept_block <= 1'b0;
    end else begin
      if (req_stall_cnt > 0)
        req_stall_cnt <= req_stall_cnt - 1;

      if (l2_req_valid && !l2_req_ready)
        cov_l2_req_bp <= cov_l2_req_bp + 1;
      if (l2_rsp_valid && !l2_rsp_ready)
        cov_l2_rsp_bp <= cov_l2_rsp_bp + 1;
      if (cpu_rsp_valid && !cpu_rsp_ready)
        cov_cpu_rsp_bp <= cov_cpu_rsp_bp + 1;

      // track non-stream request acceptance to avoid double-counting
      if (!l2_req_valid)
        nonstream_accepted <= 1'b0;
      else if (l2_req_valid && l2_req_ready && (l2_req_cmd != 2'b11))
        nonstream_accepted <= 1'b1;

      // block stray WB accept until valid drops after last beat
      if (!l2_req_valid)
        wb_accept_block <= 1'b0;

      // capture requests
      if (l2_req_valid && l2_req_ready) begin
        // basic protocol assertions
        if (l2_req_cmd == 2'b00 || l2_req_cmd == 2'b11) begin
          if (l2_req_len !== 8'd7 || l2_req_size !== 3'b011)
            $fatal(1, "Bad LINE cmd size/len: cmd=%b size=%b len=%b", l2_req_cmd, l2_req_size, l2_req_len);
        end else begin
          if (l2_req_len !== 8'd0 || l2_req_size !== 3'b010)
            $fatal(1, "Bad UC cmd size/len: cmd=%b size=%b len=%b", l2_req_cmd, l2_req_size, l2_req_len);
        end
        if (l2_req_cmd == 2'b11 && l2_req_wstrb !== 8'hFF)
          $fatal(1, "WB wstrb not all ones: %b", l2_req_wstrb);
        if (l2_req_cmd == 2'b01 && l2_req_wstrb !== 8'h00)
          $fatal(1, "UC_RD wstrb not zero: %b", l2_req_wstrb);
        if (l2_req_cmd == 2'b10) begin
          if (!((l2_req_wstrb[7:4] == 4'h0) || (l2_req_wstrb[3:0] == 4'h0)))
            $fatal(1, "UC_WR wstrb should have one nibble zero: %b", l2_req_wstrb);
        end
        case (l2_req_cmd)
          2'b00: begin // LINE_RD
            if (!nonstream_accepted) begin
              line_rd_cnt <= line_rd_cnt + 1;
              pending_rsp <= 1'b1;
              rsp_type    <= 2'b00;
              rsp_addr    <= l2_req_addr;
              rsp_beat    <= 3'd0;
              rsp_delay   <= rsp_delay_cfg;
              rsp_err_latched <= l2_err_once;
              l2_err_once <= 1'b0;
            end
          end
          2'b01: begin // UC_RD
            if (!nonstream_accepted) begin
              uc_rd_cnt   <= uc_rd_cnt + 1;
              pending_rsp <= 1'b1;
              rsp_type    <= 2'b01;
              rsp_addr    <= l2_req_addr;
              rsp_beat    <= 3'd0;
              rsp_delay   <= rsp_delay_cfg;
              rsp_err_latched <= l2_err_once;
              l2_err_once <= 1'b0;
            end
          end
          2'b10: begin // UC_WR
            if (!nonstream_accepted) begin
              uc_wr_cnt   <= uc_wr_cnt + 1;
              if (l2_req_addr[2]) begin
                uc_wr_data = l2_req_wdata[63:32];
                uc_wr_strb = l2_req_wstrb[7:4];
              end else begin
                uc_wr_data = l2_req_wdata[31:0];
                uc_wr_strb = l2_req_wstrb[3:0];
              end
              mem_write_word_wstrb(l2_req_addr, uc_wr_data, uc_wr_strb);
              pending_rsp <= 1'b1;
              rsp_type    <= 2'b10;
              rsp_addr    <= l2_req_addr;
              rsp_beat    <= 3'd0;
              rsp_delay   <= rsp_delay_cfg;
              rsp_err_latched <= l2_err_once;
              l2_err_once <= 1'b0;
            end
          end
          2'b11: begin // WB_LINE beat
            if (!wb_accept_block) begin
              if (!wb_active) begin
                // first beat of writeback
                wb_active <= 1'b1;
                wb_addr   <= l2_req_addr;
                wb_beat   <= 3'd1;
                mem_write64(l2_req_addr, l2_req_wdata, l2_req_wstrb);
              end else begin
                mem_write64(wb_addr + {wb_beat, 3'b0}, l2_req_wdata, l2_req_wstrb);
                if (wb_beat == 3'd7) begin
                  wb_active  <= 1'b0;
                  wb_cnt     <= wb_cnt + 1;
                  pending_rsp<= 1'b1;
                  rsp_type   <= 2'b11;
                  rsp_addr   <= wb_addr;
                  rsp_beat   <= 3'd0;
                  rsp_delay  <= rsp_delay_cfg;
                  rsp_err_latched <= l2_err_once;
                  l2_err_once <= 1'b0;
                  wb_accept_block <= 1'b1;
                end else begin
                  wb_beat <= wb_beat + 3'd1;
                end
              end
            end
          end
        endcase
      end

      // response handshake + sequencing
      if (l2_rsp_valid) begin
        if (l2_rsp_ready) begin
          l2_rsp_valid <= 1'b0;
          if (rsp_type == 2'b00) begin
            if (rsp_beat == 3'd7) begin
              pending_rsp <= 1'b0;
            end else begin
              rsp_beat  <= rsp_beat + 3'd1;
              rsp_delay <= rsp_gap_cfg;
            end
          end else begin
            pending_rsp <= 1'b0;
          end
        end
      end else if (pending_rsp) begin
        if (rsp_delay > 0) begin
          rsp_delay <= rsp_delay - 1;
        end else begin
          l2_rsp_valid <= 1'b1;
          l2_rsp_err   <= rsp_err_latched;
          case (rsp_type)
            2'b00: begin // line
              l2_rsp_rdata <= make_beat64(rsp_addr, rsp_beat);
              l2_rsp_last  <= (rsp_beat == 3'd7);
            end
            2'b01: begin // uc read
              l2_rsp_rdata <= uc_read_data(rsp_addr, mem_read_word(rsp_addr));
              l2_rsp_last  <= 1'b1;
            end
            2'b10: begin // uc write ack
              l2_rsp_rdata <= 64'b0;
              l2_rsp_last  <= 1'b1;
            end
            2'b11: begin // wb ack
              l2_rsp_rdata <= 64'b0;
              l2_rsp_last  <= 1'b1;
            end
          endcase
        end
      end
    end
  end

  // ---------------------------
  // CPU tasks
  // ---------------------------
  task wait_cycles;
    input integer n;
    integer k;
    begin
      for (k = 0; k < n; k = k + 1)
        @(posedge clk);
    end
  endtask

  task do_load_sz;
    input [ADDR_W-1:0] addr;
    input [1:0]        size;
    input [31:0] exp_data;
    input        exp_err;
    input        uncached;
    integer      timeout;
    begin
      cpu_req_addr     <= addr;
      cpu_req_we       <= 1'b0;
      cpu_req_wdata    <= 32'b0;
      cpu_req_wstrb    <= 4'b0000;
      cpu_req_size     <= size;
      cpu_req_uncached <= uncached;
      cpu_req_valid    <= 1'b1;
      timeout = 0;
      while (!(cpu_req_valid && cpu_req_ready)) begin
        @(posedge clk);
        timeout = timeout + 1;
        if (timeout > 200) $fatal(1, "Timeout waiting for cpu_req_ready");
      end
      @(posedge clk);
      cpu_req_valid <= 1'b0;

      timeout = 0;
      while (!cpu_rsp_valid) begin
        @(posedge clk);
        timeout = timeout + 1;
        if (timeout > 400) $fatal(1, "Timeout waiting for cpu_rsp_valid");
      end
      if (cpu_rsp_err !== exp_err) begin
        trace_dump();
        $fatal(1, "Err mismatch: addr=%h exp=%b got=%b", addr, exp_err, cpu_rsp_err);
      end
      if (cpu_rsp_rdata !== exp_data) begin
        trace_dump();
        $fatal(1, "Data mismatch: addr=%h exp=%h got=%h", addr, exp_data, cpu_rsp_rdata);
      end
      if (cpu_rsp_ready)
        @(posedge clk);
    end
  endtask

  task do_load;
    input [ADDR_W-1:0] addr;
    input [31:0] exp_data;
    input        exp_err;
    input        uncached;
    begin
      do_load_sz(addr, 2'b10, exp_data, exp_err, uncached);
    end
  endtask

  task do_load_bp;
    input [ADDR_W-1:0] addr;
    input [1:0]        size;
    input [31:0]       exp_data;
    input              exp_err;
    input              uncached;
    input integer      hold_cycles;
    integer            timeout;
    begin
      cpu_rsp_ready <= 1'b0;
      cpu_req_addr     <= addr;
      cpu_req_we       <= 1'b0;
      cpu_req_wdata    <= 32'b0;
      cpu_req_wstrb    <= 4'b0000;
      cpu_req_size     <= size;
      cpu_req_uncached <= uncached;
      cpu_req_valid    <= 1'b1;
      timeout = 0;
      while (!(cpu_req_valid && cpu_req_ready)) begin
        @(posedge clk);
        timeout = timeout + 1;
        if (timeout > 200) $fatal(1, "Timeout waiting for cpu_req_ready");
      end
      @(posedge clk);
      cpu_req_valid <= 1'b0;

      timeout = 0;
      while (!cpu_rsp_valid) begin
        @(posedge clk);
        timeout = timeout + 1;
        if (timeout > 400) $fatal(1, "Timeout waiting for cpu_rsp_valid");
      end
      wait_cycles(hold_cycles);
      if (!cpu_rsp_valid)
        $fatal(1, "cpu_rsp_valid should hold while ready is low");
      if (cpu_rsp_err !== exp_err)
        $fatal(1, "Err mismatch (bp): addr=%h exp=%b got=%b", addr, exp_err, cpu_rsp_err);
      if (cpu_rsp_rdata !== exp_data)
        $fatal(1, "Data mismatch (bp): addr=%h exp=%h got=%h", addr, exp_data, cpu_rsp_rdata);
      cpu_rsp_ready <= 1'b1;
      @(posedge clk);
    end
  endtask

  task do_load_nochk;
    input [ADDR_W-1:0] addr;
    input        uncached;
    integer      timeout;
    begin
      cpu_req_addr     <= addr;
      cpu_req_we       <= 1'b0;
      cpu_req_wdata    <= 32'b0;
      cpu_req_wstrb    <= 4'b0000;
      cpu_req_size     <= 2'b10;
      cpu_req_uncached <= uncached;
      cpu_req_valid    <= 1'b1;
      timeout = 0;
      while (!(cpu_req_valid && cpu_req_ready)) begin
        @(posedge clk);
        timeout = timeout + 1;
        if (timeout > 200) $fatal(1, "Timeout waiting for cpu_req_ready");
      end
      @(posedge clk);
      cpu_req_valid <= 1'b0;

      timeout = 0;
      while (!cpu_rsp_valid) begin
        @(posedge clk);
        timeout = timeout + 1;
        if (timeout > 400) $fatal(1, "Timeout waiting for cpu_rsp_valid");
      end
      if (cpu_rsp_err !== 1'b0)
        $fatal(1, "Unexpected error on load: addr=%h err=%b", addr, cpu_rsp_err);
      if (^cpu_rsp_rdata === 1'bX)
        $fatal(1, "X data on load: addr=%h data=%h", addr, cpu_rsp_rdata);
      if (cpu_rsp_ready)
        @(posedge clk);
    end
  endtask

  task do_store_sz;
    input [ADDR_W-1:0] addr;
    input [1:0]        size;
    input [31:0] data;
    input [3:0]  wstrb;
    input        exp_err;
    input        uncached;
    integer      timeout;
    begin
      cpu_req_addr     <= addr;
      cpu_req_we       <= 1'b1;
      cpu_req_wdata    <= data;
      cpu_req_wstrb    <= wstrb;
      cpu_req_size     <= size;
      cpu_req_uncached <= uncached;
      cpu_req_valid    <= 1'b1;
      timeout = 0;
      while (!(cpu_req_valid && cpu_req_ready)) begin
        @(posedge clk);
        timeout = timeout + 1;
        if (timeout > 200) $fatal(1, "Timeout waiting for cpu_req_ready");
      end
      @(posedge clk);
      cpu_req_valid <= 1'b0;

      timeout = 0;
      while (!cpu_rsp_valid) begin
        @(posedge clk);
        timeout = timeout + 1;
        if (timeout > 400) $fatal(1, "Timeout waiting for cpu_rsp_valid");
      end
      if (cpu_rsp_err !== exp_err) begin
        trace_dump();
        $fatal(1, "Err mismatch on store: addr=%h exp=%b got=%b", addr, exp_err, cpu_rsp_err);
      end
      if (cpu_rsp_rdata !== 32'b0) begin
        trace_dump();
        $fatal(1, "Store rsp data not zero: addr=%h got=%h", addr, cpu_rsp_rdata);
      end
      if (cpu_rsp_ready)
        @(posedge clk);
    end
  endtask

  task do_store;
    input [ADDR_W-1:0] addr;
    input [31:0] data;
    input [3:0]  wstrb;
    input        exp_err;
    input        uncached;
    begin
      do_store_sz(addr, 2'b10, data, wstrb, exp_err, uncached);
    end
  endtask

  task do_load_model_sz;
    input [ADDR_W-1:0] addr;
    input [1:0]        size;
    input              uncached;
    reg [31:0]         exp_data;
    begin
      case (size)
        2'b00: cov_ld_sz_b = cov_ld_sz_b + 1;
        2'b01: cov_ld_sz_h = cov_ld_sz_h + 1;
        default: cov_ld_sz_w = cov_ld_sz_w + 1;
      endcase
      model_load(addr, uncached, exp_data);
      trace_log(2'b00, addr, 32'b0, 4'b0, uncached, exp_data);
      do_load_sz(addr, size, exp_data, 1'b0, uncached);
    end
  endtask

  task do_load_model_bp;
    input [ADDR_W-1:0] addr;
    input [1:0]        size;
    input              uncached;
    input integer      hold_cycles;
    reg [31:0]         exp_data;
    begin
      case (size)
        2'b00: cov_ld_sz_b = cov_ld_sz_b + 1;
        2'b01: cov_ld_sz_h = cov_ld_sz_h + 1;
        default: cov_ld_sz_w = cov_ld_sz_w + 1;
      endcase
      model_load(addr, uncached, exp_data);
      trace_log(2'b00, addr, 32'b0, 4'b0, uncached, exp_data);
      do_load_bp(addr, size, exp_data, 1'b0, uncached, hold_cycles);
    end
  endtask

  task do_store_model_sz;
    input [ADDR_W-1:0] addr;
    input [1:0]        size;
    input [31:0] data;
    input [3:0]  wstrb_in;
    input        uncached;
    reg [3:0]    wstrb;
    begin
      case (size)
        2'b00: cov_st_sz_b = cov_st_sz_b + 1;
        2'b01: cov_st_sz_h = cov_st_sz_h + 1;
        default: cov_st_sz_w = cov_st_sz_w + 1;
      endcase
      wstrb = wstrb_in;
      if (wstrb === 4'b0000)
        wstrb = wstrb_from_size_addr(size, addr);
      model_store(addr, data, wstrb, uncached);
      trace_log(2'b01, addr, data, wstrb, uncached, 32'b0);
      do_store_sz(addr, size, data, wstrb, 1'b0, uncached);
    end
  endtask

  task do_load_model;
    input [ADDR_W-1:0] addr;
    input              uncached;
    reg [31:0]         exp_data;
    begin
      do_load_model_sz(addr, 2'b10, uncached);
    end
  endtask

  task do_store_model;
    input [ADDR_W-1:0] addr;
    input [31:0] data;
    input [3:0]  wstrb;
    input        uncached;
    begin
      do_store_model_sz(addr, 2'b10, data, wstrb, uncached);
    end
  endtask

  // ---------------------------
  // Test sequence
  // ---------------------------
  integer i;
  integer line_rd_before;
  integer wb_before;
  reg [31:0] addr_a;
  reg [31:0] addr_b;
  reg [31:0] addr_c;
  reg [31:0] addr_d;
  reg [31:0] addr_u;
  reg [31:0] old_word;
  reg [31:0] exp_word;
  reg [31:0] rand_addr;
  reg [31:0] rand_data;
  reg [3:0]  rand_wstrb;
  reg [1:0]  rand_size;
  reg        rand_uncached;
  integer    seed;
  integer    reg_iters;

  initial begin
    // init
    clk = 1'b0;
    rst_n = 1'b0;
    cpu_req_valid = 1'b0;
    cpu_req_addr  = 32'b0;
    cpu_req_we    = 1'b0;
    cpu_req_wdata = 32'b0;
    cpu_req_wstrb = 4'b0;
    cpu_req_size  = 2'b00;
    cpu_req_uncached = 1'b0;
    cpu_rsp_ready = 1'b1;

    l2_rsp_valid = 1'b0;
    l2_rsp_rdata = 64'b0;
    l2_rsp_last  = 1'b0;
    l2_rsp_err   = 1'b0;

    // init memory with pattern
    for (i = 0; i < MEM_WORDS; i = i + 1) begin
      mem[i] = i ^ 32'h1234_5678;
      mem_ref[i] = mem[i];
    end

    wait_cycles(4);
    rst_n = 1'b1;
    wait_cycles(2);

    // Test 1: cold miss -> refill -> response (with req stall/resp delay)
    req_stall_cnt = 2;
    rsp_delay_cfg = 2;
    addr_a = 32'h0000_1000;
    do_load(addr_a, mem_read_word(addr_a), 1'b0, 1'b0);
    if (line_rd_cnt != 1) begin
      $display("line_rd_cnt=%0d after cold miss", line_rd_cnt);
      $fatal(1, "Expected 1 line read after cold miss");
    end

    // Test 2: same line hit, no new line read
    line_rd_before = line_rd_cnt;
    do_load(addr_a + 4, mem_read_word(addr_a + 4), 1'b0, 1'b0);
    if (line_rd_cnt != line_rd_before)
      $fatal(1, "Unexpected line read on hit");

    // Test 3: store hit -> load sees updated data
    do_store(addr_a, 32'hA5A5_1234, 4'hF, 1'b0, 1'b0);
    do_load(addr_a, 32'hA5A5_1234, 1'b0, 1'b0);
    if (uc_wr_cnt != 0)
      $fatal(1, "Unexpected UC_WR on store hit");

    // Test 4: store miss -> UC_WR (no-write-allocate) then load miss linefill
    addr_d = 32'h0000_8000;
    line_rd_before = line_rd_cnt;
    do_store(addr_d, 32'hDEAD_BEEF, 4'hF, 1'b0, 1'b0);
    if (uc_wr_cnt == 0)
      $fatal(1, "Expected UC_WR on store miss");
    if (line_rd_cnt != line_rd_before)
      $fatal(1, "Line fill should not happen on store miss");
    do_load(addr_d, 32'hDEAD_BEEF, 1'b0, 1'b0);

    // Test 5: uncached read (no allocate), then cached read re-miss
    addr_u = 32'h0000_9004;
    do_load(addr_u, mem_read_word(addr_u), 1'b0, 1'b1);
    line_rd_before = line_rd_cnt;
    do_load(addr_u, mem_read_word(addr_u), 1'b0, 1'b0);
    if (line_rd_cnt == line_rd_before)
      $fatal(1, "Expected line fill after cached read following UC read");

    // Test 6: dirty eviction triggers writeback, data persists in memory
    addr_a = 32'h0000_3000;
    addr_b = addr_a + 32'h0001_0000;
    addr_c = addr_a + 32'h0002_0000;
    do_load(addr_a, mem_read_word(addr_a), 1'b0, 1'b0);
    do_load(addr_b, mem_read_word(addr_b), 1'b0, 1'b0);
    do_store(addr_a, 32'hCAFE_BABE, 4'hF, 1'b0, 1'b0);
    do_load(addr_b, mem_read_word(addr_b), 1'b0, 1'b0); // make addr_a LRU
    wb_before = wb_cnt;
    do_load(addr_c, mem_read_word(addr_c), 1'b0, 1'b0); // evict dirty addr_a
    if (wb_cnt == wb_before)
      $fatal(1, "Expected writeback on dirty eviction");
    do_load(addr_a, 32'hCAFE_BABE, 1'b0, 1'b0);

    // Test 7: uncached read error propagation
    l2_err_once = 1'b1;
    do_load(32'h0000_A004, mem_read_word(32'h0000_A004), 1'b1, 1'b1);

    // Test 8: cached miss error propagation
    l2_err_once = 1'b1;
    do_load(32'h0000_B000, mem_read_word(32'h0000_B000), 1'b1, 1'b0);

    // Test 9: cpu_rsp backpressure
    cpu_rsp_ready = 1'b0;
    addr_d = 32'h0000_C000;
    cpu_req_addr     <= addr_d;
    cpu_req_we       <= 1'b0;
    cpu_req_wdata    <= 32'b0;
    cpu_req_wstrb    <= 4'b0;
    cpu_req_size     <= 2'b10;
    cpu_req_uncached <= 1'b0;
    cpu_req_valid    <= 1'b1;
    while (!(cpu_req_valid && cpu_req_ready)) @(posedge clk);
    @(posedge clk);
    cpu_req_valid <= 1'b0;
    while (!cpu_rsp_valid) @(posedge clk);
    wait_cycles(3);
    if (!cpu_rsp_valid)
      $fatal(1, "cpu_rsp_valid should hold while ready is low");
    cpu_rsp_ready = 1'b1;
    @(posedge clk);

    // Test 10: L2 request backpressure
    req_stall_cnt = 3;
    do_load(32'h0000_D000, mem_read_word(32'h0000_D000), 1'b0, 1'b0);

    // Test 11: response gap between refill beats
    rsp_delay_cfg = 0;
    rsp_gap_cfg = 2;
    do_load(32'h0000_D100, mem_read_word(32'h0000_D100), 1'b0, 1'b0);
    rsp_delay_cfg = 1;
    rsp_gap_cfg = 0;

    // Test 12: clean eviction should not writeback
    addr_a = 32'h0000_4000;
    addr_b = addr_a + 32'h0001_0000;
    addr_c = addr_a + 32'h0002_0000;
    do_load(addr_a, mem_read_word(addr_a), 1'b0, 1'b0);
    do_load(addr_b, mem_read_word(addr_b), 1'b0, 1'b0);
    do_load(addr_b, mem_read_word(addr_b), 1'b0, 1'b0); // make addr_a LRU
    wb_before = wb_cnt;
    do_load(addr_c, mem_read_word(addr_c), 1'b0, 1'b0);
    if (wb_cnt != wb_before)
      $fatal(1, "Unexpected writeback on clean eviction");

    // Test 13: uncached store updates memory, cached load sees it after miss
    addr_u = 32'h0000_F008;
    old_word = mem_read_word(addr_u);
    exp_word = apply_wstrb32(old_word, 32'h55AA_1234, 4'hF);
    do_store(addr_u, 32'h55AA_1234, 4'hF, 1'b0, 1'b1);
    if (mem_read_word(addr_u) !== exp_word)
      $fatal(1, "UC store did not update memory");
    // verify via uncached read-back
    do_load(addr_u, exp_word, 1'b0, 1'b1);

    // Test 14: store miss with partial wstrb uses UC_WR and updates memory
    addr_d = 32'h0001_F100;
    old_word = mem_read_word(addr_d);
    exp_word = apply_wstrb32(old_word, 32'hAABB_CCDD, 4'b0011);
    line_rd_before = line_rd_cnt;
    do_store(addr_d, 32'hAABB_CCDD, 4'b0011, 1'b0, 1'b0);
    if (mem_read_word(addr_d) !== exp_word)
      $fatal(1, "Store miss UC_WR did not update memory");
    if (line_rd_cnt != line_rd_before)
      $fatal(1, "Line fill should not happen on store miss (partial)");
    do_load(addr_d, exp_word, 1'b0, 1'b0);

    // Test 15: uncached read high word lane (addr[2]=1)
    addr_u = 32'h0000_A008;
    do_load(addr_u, mem_read_word(addr_u), 1'b0, 1'b1);

    // Test 16: UC_WR error propagation
    l2_err_once = 1'b1;
    do_store(32'h0001_A000, 32'h0BAD_F00D, 4'hF, 1'b1, 1'b1);

    // Test 17: multi-word dirty line writeback preserves both words
    addr_a = 32'h0000_5000;
    addr_b = addr_a + 32'h0001_0000;
    addr_c = addr_a + 32'h0002_0000;
    do_load(addr_a, mem_read_word(addr_a), 1'b0, 1'b0);
    do_load(addr_b, mem_read_word(addr_b), 1'b0, 1'b0);
    do_store(addr_a, 32'h1111_2222, 4'hF, 1'b0, 1'b0);
    do_store(addr_a + 4, 32'h3333_4444, 4'hF, 1'b0, 1'b0);
    do_load(addr_b, mem_read_word(addr_b), 1'b0, 1'b0); // make addr_a LRU
    wb_before = wb_cnt;
    do_load(addr_c, mem_read_word(addr_c), 1'b0, 1'b0); // evict dirty addr_a
    if (wb_cnt == wb_before)
      $fatal(1, "Expected writeback on multi-word dirty eviction");
    if (mem_read_word(addr_a) !== 32'h1111_2222)
      $fatal(1, "Writeback word0 mismatch");
    if (mem_read_word(addr_a + 4) !== 32'h3333_4444)
      $fatal(1, "Writeback word1 mismatch");

    // Test 18: cpu_req_ready stays low while miss in progress
    rsp_delay_cfg = 4;
    cpu_req_addr     <= 32'h0002_0000;
    cpu_req_we       <= 1'b0;
    cpu_req_wdata    <= 32'b0;
    cpu_req_wstrb    <= 4'b0;
    cpu_req_size     <= 2'b10;
    cpu_req_uncached <= 1'b0;
    cpu_req_valid    <= 1'b1;
    while (!(cpu_req_valid && cpu_req_ready)) @(posedge clk);
    @(posedge clk);
    cpu_req_valid <= 1'b0;
    wait_cycles(3);
    if (cpu_req_ready)
      $fatal(1, "cpu_req_ready should be low during miss handling");
    // wait for response to complete
    while (!cpu_rsp_valid) @(posedge clk);
    @(posedge clk);
    rsp_delay_cfg = 0;

    // Test 19: LRU eviction correctness (same index, 3 tags)
    addr_a = 32'h0000_0000;
    addr_b = 32'h0001_0000;
    addr_c = 32'h0002_0000;
    line_rd_before = line_rd_cnt;
    do_load(addr_a, mem_read_word(addr_a), 1'b0, 1'b0);
    do_load(addr_b, mem_read_word(addr_b), 1'b0, 1'b0);
    // touch A again to make B LRU
    do_load(addr_a, mem_read_word(addr_a), 1'b0, 1'b0);
    do_load(addr_c, mem_read_word(addr_c), 1'b0, 1'b0); // should evict B
    // reload B should miss -> new linefill
    line_rd_before = line_rd_cnt;
    do_load(addr_b, mem_read_word(addr_b), 1'b0, 1'b0);
    if (line_rd_cnt == line_rd_before)
      $fatal(1, "Expected miss/linefill on reloading evicted B");

    // Test 20: double store miss same line (no-write-allocate)
    addr_d = 32'h0000_7000;
    line_rd_before = line_rd_cnt;
    do_store(addr_d, 32'hAAAA_BBBB, 4'hF, 1'b0, 1'b0);
    do_store(addr_d + 4, 32'hCCCC_DDDD, 4'hF, 1'b0, 1'b0);
    if (line_rd_cnt != line_rd_before)
      $fatal(1, "Line fill should not happen on store miss (double)");
    do_load(addr_d, 32'hAAAA_BBBB, 1'b0, 1'b0);
    do_load(addr_d + 4, 32'hCCCC_DDDD, 1'b0, 1'b0);

    // Test 21: store hit with byte/halfword patterns (size + wstrb)
    addr_d = 32'h0000_7200;
    do_load(addr_d, mem_read_word(addr_d), 1'b0, 1'b0);
    old_word = mem_read_word(addr_d);
    rand_data = 32'h5566_7788;
    exp_word = old_word;

    rand_wstrb = 4'b0001;
    exp_word = apply_wstrb32(exp_word, rand_data, rand_wstrb);
    do_store_sz(addr_d + 0, 2'b00, rand_data, rand_wstrb, 1'b0, 1'b0);
    do_load_sz(addr_d, 2'b00, exp_word, 1'b0, 1'b0);

    rand_wstrb = 4'b0010;
    exp_word = apply_wstrb32(exp_word, rand_data, rand_wstrb);
    do_store_sz(addr_d + 1, 2'b00, rand_data, rand_wstrb, 1'b0, 1'b0);
    do_load_sz(addr_d, 2'b00, exp_word, 1'b0, 1'b0);

    rand_wstrb = 4'b0100;
    exp_word = apply_wstrb32(exp_word, rand_data, rand_wstrb);
    do_store_sz(addr_d + 2, 2'b00, rand_data, rand_wstrb, 1'b0, 1'b0);
    do_load_sz(addr_d, 2'b00, exp_word, 1'b0, 1'b0);

    rand_wstrb = 4'b1000;
    exp_word = apply_wstrb32(exp_word, rand_data, rand_wstrb);
    do_store_sz(addr_d + 3, 2'b00, rand_data, rand_wstrb, 1'b0, 1'b0);
    do_load_sz(addr_d, 2'b00, exp_word, 1'b0, 1'b0);

    rand_wstrb = 4'b0011;
    exp_word = apply_wstrb32(exp_word, rand_data, rand_wstrb);
    do_store_sz(addr_d + 0, 2'b01, rand_data, rand_wstrb, 1'b0, 1'b0);
    do_load_sz(addr_d, 2'b01, exp_word, 1'b0, 1'b0);

    rand_wstrb = 4'b1100;
    exp_word = apply_wstrb32(exp_word, rand_data, rand_wstrb);
    do_store_sz(addr_d + 2, 2'b01, rand_data, rand_wstrb, 1'b0, 1'b0);
    do_load_sz(addr_d, 2'b01, exp_word, 1'b0, 1'b0);

    // Test 22: uncached byte/halfword store + load
    addr_u = 32'h0000_F100;
    old_word = mem_read_word(addr_u);
    rand_data = 32'h0000_00AA;
    rand_wstrb = 4'b0100;
    exp_word = apply_wstrb32(old_word, rand_data, rand_wstrb);
    do_store_sz(addr_u + 2, 2'b00, rand_data, rand_wstrb, 1'b0, 1'b1);
    do_load_sz(addr_u, 2'b00, exp_word, 1'b0, 1'b1);
    rand_data = 32'h00BB_0000;
    rand_wstrb = 4'b1100;
    exp_word = apply_wstrb32(exp_word, rand_data, rand_wstrb);
    do_store_sz(addr_u + 2, 2'b01, rand_data, rand_wstrb, 1'b0, 1'b1);
    do_load_sz(addr_u, 2'b01, exp_word, 1'b0, 1'b1);

    // Test 23: cpu_req_ready low during uncached wait
    rsp_delay_cfg = 3;
    cpu_req_addr     <= 32'h0000_8800;
    cpu_req_we       <= 1'b0;
    cpu_req_wdata    <= 32'b0;
    cpu_req_wstrb    <= 4'b0;
    cpu_req_size     <= 2'b10;
    cpu_req_uncached <= 1'b1;
    cpu_req_valid    <= 1'b1;
    while (!(cpu_req_valid && cpu_req_ready)) @(posedge clk);
    @(posedge clk);
    cpu_req_valid <= 1'b0;
    wait_cycles(2);
    if (cpu_req_ready)
      $fatal(1, "cpu_req_ready should be low during UC wait");
    while (!cpu_rsp_valid) @(posedge clk);
    @(posedge clk);
    rsp_delay_cfg = 0;

    // Test 24: randomized mixed accesses with size + backpressure
    rst_n = 1'b0;
    cpu_req_valid = 1'b0;
    wait_cycles(3);
    rst_n = 1'b1;
    wait_cycles(2);

    for (i = 0; i < MEM_WORDS; i = i + 1) begin
      mem[i] = i ^ 32'h1234_5678;
      mem_ref[i] = mem[i];
    end
    model_reset();
    cpu_rsp_ready = 1'b1;
    req_stall_cnt = 0;
    rsp_delay_cfg = 0;
    rsp_gap_cfg   = 0;
    l2_err_once   = 1'b0;

    // size sweep to guarantee coverage counters
    rand_addr = 32'h0000_2000;
    do_store_model_sz(rand_addr + 0, 2'b00, 32'h1122_3344, 4'b0000, 1'b0);
    do_store_model_sz(rand_addr + 2, 2'b01, 32'h5566_7788, 4'b0000, 1'b0);
    do_store_model_sz(rand_addr + 4, 2'b10, 32'h99AA_BBCC, 4'b0000, 1'b0);
    do_load_model_sz(rand_addr + 0, 2'b00, 1'b0);
    do_load_model_sz(rand_addr + 2, 2'b01, 1'b0);
    do_load_model_sz(rand_addr + 4, 2'b10, 1'b0);
    do_store_model_sz(rand_addr + 8, 2'b00, 32'h0000_00EE, 4'b0000, 1'b1);
    do_load_model_sz(rand_addr + 8, 2'b00, 1'b1);

    // backpressure sweep after reset
    req_stall_cnt = 8;
    rsp_delay_cfg = 1;
    rsp_gap_cfg   = 0;
    do_load_model_sz(32'h0000_3100, 2'b10, 1'b0);
    req_stall_cnt = 0;
    rsp_delay_cfg = 0;
    do_load_model_bp(32'h0000_3200, 2'b10, 1'b0, 3);
    cpu_rsp_ready = 1'b1;

    seed = 32'h1A2B_3C4D;
    reg_iters = 20000;
    for (i = 0; i < reg_iters; i = i + 1) begin
      seed = (seed * 32'h343f_d + 32'h269e_c3);
      rand_size = seed[3:2];
      if (rand_size == 2'b11)
        rand_size = 2'b10;
      rand_addr = (seed & 32'h0003_FFFF);
      // occasionally force same index to stress replacement
      if (seed[5])
        rand_addr = (rand_addr & 32'hFFFF_003F) | (10'h055 << 6);
      if (rand_size == 2'b01)
        rand_addr[0] = 1'b0;
      else if (rand_size == 2'b10)
        rand_addr[1:0] = 2'b00;
      rand_data = {seed, ~seed};
      rand_wstrb = wstrb_from_size_addr(rand_size, rand_addr);
      rand_uncached = seed[7] & seed[6];

      req_stall_cnt = seed[10:9];
      rsp_delay_cfg = seed[12:11];
      rsp_gap_cfg   = seed[14:13];

      if (seed[0]) begin
        do_load_model_sz(rand_addr, rand_size, rand_uncached);
      end else begin
        do_store_model_sz(rand_addr, rand_size, rand_data, rand_wstrb, rand_uncached);
      end
      if ((i % 200) == 0)
        $display("Regression progress: %0d / %0d", i, reg_iters);
    end

    $display("Coverage summary:");
    $display("  load=%0d hit=%0d miss=%0d uc_load=%0d", cov_load, cov_load_hit, cov_load_miss, cov_uc_load);
    $display("  store=%0d hit=%0d miss=%0d uc_store=%0d", cov_store, cov_store_hit, cov_store_miss, cov_uc_store);
    $display("  store_full=%0d store_partial=%0d", cov_store_full, cov_store_partial);
    $display("  uc_hi=%0d uc_lo=%0d", cov_uc_hi, cov_uc_lo);
    $display("  ld_size: b=%0d h=%0d w=%0d", cov_ld_sz_b, cov_ld_sz_h, cov_ld_sz_w);
    $display("  st_size: b=%0d h=%0d w=%0d", cov_st_sz_b, cov_st_sz_h, cov_st_sz_w);
    $display("  l2_req_bp=%0d l2_rsp_bp=%0d cpu_rsp_bp=%0d", cov_l2_req_bp, cov_l2_rsp_bp, cov_cpu_rsp_bp);
    if (cov_load == 0 || cov_store == 0 || cov_load_miss == 0 || cov_load_hit == 0 ||
        cov_store_hit == 0 || cov_store_miss == 0) begin
      $fatal(1, "Coverage insufficient: load/store hit/miss not all exercised");
    end
    if (cov_uc_load == 0 || cov_uc_store == 0)
      $fatal(1, "Coverage insufficient: uncached load/store not exercised");
    if (cov_store_partial == 0)
      $fatal(1, "Coverage insufficient: partial store not exercised");
    if (cov_ld_sz_b == 0 || cov_ld_sz_h == 0 || cov_ld_sz_w == 0)
      $fatal(1, "Coverage insufficient: load sizes not all exercised");
    if (cov_st_sz_b == 0 || cov_st_sz_h == 0 || cov_st_sz_w == 0)
      $fatal(1, "Coverage insufficient: store sizes not all exercised");
    if (cov_l2_req_bp == 0 || cov_cpu_rsp_bp == 0)
      $fatal(1, "Coverage insufficient: backpressure not exercised");
    $display("dcache_tb: All tests passed.");
    $finish;
  end

endmodule
