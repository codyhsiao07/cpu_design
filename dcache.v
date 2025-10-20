// -----------------------------------------------------------------------------
// 32KB, 2-way set associative data cache (write-back, write-allocate)
// Interface matches core MEM stage handshake via storage_top bridge.
// -----------------------------------------------------------------------------
module dcache #(
  parameter integer XLEN            = 32,
  parameter integer CACHE_BYTES     = 32768,
  parameter integer LINE_BYTES      = 32,
  parameter integer WAYS            = 2,
  parameter integer WRITEBUF_DEPTH  = 1
)(
  input                       clk,
  input                       rstn,

  // Core-side request / response
  input                       cpu_req_valid,
  output                      cpu_req_ready,
  input                       cpu_req_rw,        // 0=load, 1=store
  input      [XLEN-1:0]       cpu_req_addr,
  input      [XLEN-1:0]       cpu_req_wdata,
  input      [XLEN/8-1:0]     cpu_req_wstrb,
  output                      cpu_resp_valid,
  output reg [XLEN-1:0]       cpu_resp_rdata,
  output                      cpu_resp_err,
  output                      cpu_stall_ld_miss,
  output                      cpu_stall_st_buf,
  output                      cpu_store_done_o,

  // External memory line interface
  output                      mem_req_valid,
  input                       mem_req_ready,
  output                      mem_req_write,
  output     [XLEN-1:0]       mem_req_addr,
  output     [LINE_BYTES*8-1:0] mem_req_wdata,
  output     [LINE_BYTES-1:0] mem_req_wstrb,
  input                       mem_resp_valid,
  input      [LINE_BYTES*8-1:0] mem_resp_rdata,
  input                       mem_resp_err
);

  // ---------------------------------------------------------------------------
  // Helper utilities
  // ---------------------------------------------------------------------------
  function integer clog2;
    input integer value;
    integer r;
    begin
      r = 0;
      value = value - 1;
      while (value > 0) begin
        value = value >> 1;
        r = r + 1;
      end
      clog2 = r;
    end
  endfunction

  localparam integer ADDR_WIDTH      = XLEN;
  localparam integer XLEN_BYTES      = XLEN/8;
  localparam integer LINE_BITS       = LINE_BYTES * 8;
  localparam integer SET_COUNT       = CACHE_BYTES / (LINE_BYTES * WAYS);
  localparam integer OFF_BITS        = clog2(LINE_BYTES);
  localparam integer IDX_BITS        = clog2(SET_COUNT);
  localparam integer WORDS_PER_LINE  = LINE_BYTES / XLEN_BYTES;
  localparam integer WORD_IDX_BITS   = (WORDS_PER_LINE <= 1) ? 1 : clog2(WORDS_PER_LINE);
  localparam integer TAG_BITS        = ADDR_WIDTH - OFF_BITS - IDX_BITS;

  initial begin
    if (WAYS != 2) begin
      $display("ERROR: dcache currently supports exactly 2 ways (WAYS=%0d).", WAYS);
      $finish;
    end
    if ((CACHE_BYTES % (LINE_BYTES * WAYS)) != 0) begin
      $display("ERROR: CACHE_BYTES must be divisible by LINE_BYTES*WAYS.");
      $finish;
    end
    if ((LINE_BYTES & (LINE_BYTES - 1)) != 0) begin
      $display("ERROR: LINE_BYTES must be power-of-two (got %0d).", LINE_BYTES);
      $finish;
    end
  end

  // ---------------------------------------------------------------------------
  // Cache arrays
  // ---------------------------------------------------------------------------
  reg [LINE_BITS-1:0] data_way0 [0:SET_COUNT-1];
  reg [LINE_BITS-1:0] data_way1 [0:SET_COUNT-1];
  reg [TAG_BITS-1:0]  tag_way0  [0:SET_COUNT-1];
  reg [TAG_BITS-1:0]  tag_way1  [0:SET_COUNT-1];
  reg                 valid_way0[0:SET_COUNT-1];
  reg                 valid_way1[0:SET_COUNT-1];
  reg                 dirty_way0[0:SET_COUNT-1];
  reg                 dirty_way1[0:SET_COUNT-1];
  reg                 mru_way   [0:SET_COUNT-1]; // 0 -> way0 MRU, 1 -> way1 MRU

  // ---------------------------------------------------------------------------
  // Request bookkeeping
  // ---------------------------------------------------------------------------
  reg                  req_rw_q;
  reg [IDX_BITS-1:0]   req_idx_q;
  reg [TAG_BITS-1:0]   req_tag_q;
  reg [WORD_IDX_BITS-1:0] req_word_idx_q;
  reg [XLEN-1:0]       req_wdata_q;
  reg [XLEN_BYTES-1:0] req_wstrb_q;

  reg                  victim_way_q;
  reg [ADDR_WIDTH-1:0] victim_addr_q;
  reg [LINE_BITS-1:0]  victim_line_q;
  reg                  fill_way_q;
  reg [ADDR_WIDTH-1:0] refill_addr_q;

  reg                  load_miss_active_q;
  reg                  store_miss_active_q;
  reg                  cpu_resp_valid_q;
  reg                  cpu_resp_err_q;
  reg                  cpu_store_done_q;
  reg [LINE_BITS-1:0]  fill_line_new;

  // ---------------------------------------------------------------------------
  // Derived signals for current indexed set
  // ---------------------------------------------------------------------------
  wire [LINE_BITS-1:0] line_way0 = data_way0[req_idx_q];
  wire [LINE_BITS-1:0] line_way1 = data_way1[req_idx_q];
  wire [TAG_BITS-1:0]  tag_way0_cur = tag_way0[req_idx_q];
  wire [TAG_BITS-1:0]  tag_way1_cur = tag_way1[req_idx_q];
  wire                 way0_valid = valid_way0[req_idx_q];
  wire                 way1_valid = valid_way1[req_idx_q];
  wire                 hit_way0   = way0_valid && (tag_way0_cur == req_tag_q);
  wire                 hit_way1   = way1_valid && (tag_way1_cur == req_tag_q);
  wire [XLEN-1:0]      load_word_way0 = line_get_word(line_way0, req_word_idx_q);
  wire [XLEN-1:0]      load_word_way1 = line_get_word(line_way1, req_word_idx_q);
  wire [XLEN-1:0]      load_word_sel  = hit_way0 ? load_word_way0 : load_word_way1;

  wire victim_way_calc = (~way0_valid) ? 1'b0 :
                         (~way1_valid) ? 1'b1 :
                         ((mru_way[req_idx_q] == 1'b0) ? 1'b1 : 1'b0);
  wire victim_valid_sel = (victim_way_calc == 1'b0) ? way0_valid : way1_valid;
  wire victim_dirty_sel = (victim_way_calc == 1'b0) ? dirty_way0[req_idx_q] : dirty_way1[req_idx_q];
  wire [TAG_BITS-1:0] victim_tag_sel = (victim_way_calc == 1'b0) ? tag_way0_cur : tag_way1_cur;
  wire [LINE_BITS-1:0] victim_line_sel = (victim_way_calc == 1'b0) ? line_way0 : line_way1;
  wire [ADDR_WIDTH-1:0] victim_addr_sel = {victim_tag_sel, req_idx_q, {OFF_BITS{1'b0}}};
  wire [ADDR_WIDTH-1:0] req_line_addr   = {req_tag_q, req_idx_q, {OFF_BITS{1'b0}}};

  // ---------------------------------------------------------------------------
  // Output assignments
  // ---------------------------------------------------------------------------
  localparam [2:0] ST_IDLE        = 3'd0;
  localparam [2:0] ST_LOOKUP      = 3'd1;
  localparam [2:0] ST_WB_REQ      = 3'd2;
  localparam [2:0] ST_REFILL_REQ  = 3'd3;
  localparam [2:0] ST_REFILL_WAIT = 3'd4;

  reg [2:0] state_q;

  assign cpu_req_ready     = (state_q == ST_IDLE);
  assign cpu_resp_valid    = cpu_resp_valid_q;
  assign cpu_resp_err      = cpu_resp_err_q;
  assign cpu_stall_ld_miss = load_miss_active_q;
  assign cpu_stall_st_buf  = store_miss_active_q;
  assign cpu_store_done_o  = cpu_store_done_q;

  assign mem_req_valid = (state_q == ST_WB_REQ) || (state_q == ST_REFILL_REQ);
  assign mem_req_write = (state_q == ST_WB_REQ);
  assign mem_req_addr  = (state_q == ST_WB_REQ)    ? victim_addr_q :
                         (state_q == ST_REFILL_REQ) ? refill_addr_q : {ADDR_WIDTH{1'b0}};
  assign mem_req_wdata = (state_q == ST_WB_REQ) ? victim_line_q : {LINE_BITS{1'b0}};
  assign mem_req_wstrb = (state_q == ST_WB_REQ) ? {LINE_BYTES{1'b1}} : {LINE_BYTES{1'b0}};

  // ---------------------------------------------------------------------------
  // State machine
  // ---------------------------------------------------------------------------
  integer i;
  always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      state_q            <= ST_IDLE;
      req_rw_q           <= 1'b0;
      req_idx_q          <= {IDX_BITS{1'b0}};
      req_tag_q          <= {TAG_BITS{1'b0}};
      req_word_idx_q     <= {WORD_IDX_BITS{1'b0}};
      req_wdata_q        <= {XLEN{1'b0}};
      req_wstrb_q        <= {XLEN_BYTES{1'b0}};
      victim_way_q       <= 1'b0;
      victim_addr_q      <= {ADDR_WIDTH{1'b0}};
      victim_line_q      <= {LINE_BITS{1'b0}};
      fill_way_q         <= 1'b0;
      refill_addr_q      <= {ADDR_WIDTH{1'b0}};
      load_miss_active_q <= 1'b0;
      store_miss_active_q<= 1'b0;
      cpu_resp_valid_q   <= 1'b0;
      cpu_resp_err_q     <= 1'b0;
      cpu_store_done_q   <= 1'b0;
      cpu_resp_rdata     <= {XLEN{1'b0}};
      fill_line_new      <= {LINE_BITS{1'b0}};
      for (i = 0; i < SET_COUNT; i = i + 1) begin
        data_way0[i]  <= {LINE_BITS{1'b0}};
        data_way1[i]  <= {LINE_BITS{1'b0}};
        tag_way0[i]   <= {TAG_BITS{1'b0}};
        tag_way1[i]   <= {TAG_BITS{1'b0}};
        valid_way0[i] <= 1'b0;
        valid_way1[i] <= 1'b0;
        dirty_way0[i] <= 1'b0;
        dirty_way1[i] <= 1'b0;
        mru_way[i]    <= 1'b0;
      end
    end else begin
      cpu_resp_valid_q <= 1'b0;
      cpu_resp_err_q   <= 1'b0;
      cpu_store_done_q <= 1'b0;

      case (state_q)
        ST_IDLE: begin
          if (cpu_req_valid) begin
            req_rw_q       <= cpu_req_rw;
            req_idx_q      <= cpu_req_addr[OFF_BITS + IDX_BITS - 1 : OFF_BITS];
            req_tag_q      <= cpu_req_addr[ADDR_WIDTH-1 : OFF_BITS + IDX_BITS];
            req_word_idx_q <= cpu_req_addr[OFF_BITS-1:2];
            req_wdata_q    <= cpu_req_wdata;
            req_wstrb_q    <= cpu_req_wstrb;
            state_q        <= ST_LOOKUP;
          end
        end

        ST_LOOKUP: begin
          if (hit_way0 || hit_way1) begin
            if (req_rw_q) begin
              if (hit_way0) begin
                data_way0[req_idx_q] <= line_merge_word(line_way0, req_word_idx_q, req_wdata_q, req_wstrb_q);
                dirty_way0[req_idx_q] <= 1'b1;
                mru_way[req_idx_q]    <= 1'b0;
                cpu_store_done_q      <= 1'b1;
              end else begin
                data_way1[req_idx_q] <= line_merge_word(line_way1, req_word_idx_q, req_wdata_q, req_wstrb_q);
                dirty_way1[req_idx_q] <= 1'b1;
                mru_way[req_idx_q]    <= 1'b1;
                cpu_store_done_q      <= 1'b1;
              end
              state_q <= ST_IDLE;
            end else begin
              cpu_resp_valid_q <= 1'b1;
              cpu_resp_rdata   <= load_word_sel;
              if (hit_way0)
                mru_way[req_idx_q] <= 1'b0;
              else
                mru_way[req_idx_q] <= 1'b1;
              state_q <= ST_IDLE;
            end
          end else begin
            victim_way_q        <= victim_way_calc;
            victim_addr_q       <= victim_addr_sel;
            victim_line_q       <= victim_line_sel;
            fill_way_q          <= victim_way_calc;
            refill_addr_q       <= req_line_addr;
            load_miss_active_q  <= ~req_rw_q;
            store_miss_active_q <=  req_rw_q;
            if (victim_valid_sel && victim_dirty_sel)
              state_q <= ST_WB_REQ;
            else
              state_q <= ST_REFILL_REQ;
          end
        end

        ST_WB_REQ: begin
          if (mem_req_ready) begin
            if (victim_way_q == 1'b0)
              dirty_way0[req_idx_q] <= 1'b0;
            else
              dirty_way1[req_idx_q] <= 1'b0;
            state_q <= ST_REFILL_REQ;
          end
        end

        ST_REFILL_REQ: begin
          if (mem_req_ready)
            state_q <= ST_REFILL_WAIT;
        end

        ST_REFILL_WAIT: begin
          if (mem_resp_valid) begin
            fill_line_new = mem_resp_rdata;
            if (req_rw_q)
              fill_line_new = line_merge_word(mem_resp_rdata, req_word_idx_q, req_wdata_q, req_wstrb_q);
            else begin
              cpu_resp_valid_q <= 1'b1;
              cpu_resp_rdata   <= line_get_word(mem_resp_rdata, req_word_idx_q);
              cpu_resp_err_q   <= mem_resp_err;
            end
            if (fill_way_q == 1'b0) begin
              data_way0[req_idx_q]  <= fill_line_new;
              tag_way0[req_idx_q]   <= req_tag_q;
              valid_way0[req_idx_q] <= 1'b1;
              dirty_way0[req_idx_q] <= req_rw_q;
              mru_way[req_idx_q]    <= 1'b0;
            end else begin
              data_way1[req_idx_q]  <= fill_line_new;
              tag_way1[req_idx_q]   <= req_tag_q;
              valid_way1[req_idx_q] <= 1'b1;
              dirty_way1[req_idx_q] <= req_rw_q;
              mru_way[req_idx_q]    <= 1'b1;
            end
            load_miss_active_q  <= 1'b0;
            store_miss_active_q <= 1'b0;
            if (req_rw_q)
              cpu_store_done_q <= 1'b1;
            state_q <= ST_IDLE;
          end
        end

        default: state_q <= ST_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------
  function [XLEN-1:0] mask_word;
    input [XLEN-1:0]       old_word;
    input [XLEN-1:0]       new_word;
    input [XLEN_BYTES-1:0] wstrb;
    integer b;
    integer byte_lsb;
    reg [XLEN-1:0] result;
    begin
      result = old_word;
      for (b = 0; b < XLEN_BYTES; b = b + 1) begin
        if (wstrb[b]) begin
          byte_lsb = b * 8;
          result[byte_lsb +: 8] = new_word[byte_lsb +: 8];
        end
      end
      mask_word = result;
    end
  endfunction

  function [XLEN-1:0] line_get_word;
    input [LINE_BITS-1:0] line_i;
    input [WORD_IDX_BITS-1:0] idx_i;
    integer base;
    begin
      base = idx_i * XLEN;
      line_get_word = line_i[base +: XLEN];
    end
  endfunction

  function [LINE_BITS-1:0] line_merge_word;
    input [LINE_BITS-1:0] line_i;
    input [WORD_IDX_BITS-1:0] idx_i;
    input [XLEN-1:0] new_word_i;
    input [XLEN_BYTES-1:0] wstrb_i;
    integer base;
    reg [LINE_BITS-1:0] tmp;
    reg [XLEN-1:0]      old_word;
    begin
      tmp = line_i;
      base = idx_i * XLEN;
      old_word = line_i[base +: XLEN];
      tmp[base +: XLEN] = mask_word(old_word, new_word_i, wstrb_i);
      line_merge_word = tmp;
    end
  endfunction

endmodule
