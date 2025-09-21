// dcache.v -- 16KB 4-way set-associative data cache (write-back, write-allocate)
// - Core interface mirrors the existing MEM stage handshake (req/we/addr/wdata/wstrb + ready/rvalid)
// - Backing memory interface reuses the same simple handshake (req/we/addr/wdata/wstrb / ready / rvalid)
// - 1-cycle hit latency (responses returned the cycle after request is observed)
// - Miss handling: choose victim via pseudo-LRU; write back dirty lines before refill

module dcache (
  input         clk,
  input         rst_n,

  // Core side (from MEM stage)
  input         core_req_i,
  input         core_we_i,
  input  [31:0] core_addr_i,
  input  [31:0] core_wdata_i,
  input  [3:0]  core_wstrb_i,
  output        core_ready_o,
  output        core_rvalid_o,
  output [31:0] core_rdata_o,

  // Backing memory side (to be hooked to DRAM controller later)
  output        mem_req_o,
  output        mem_we_o,
  output [31:0] mem_addr_o,
  output [31:0] mem_wdata_o,
  output [3:0]  mem_wstrb_o,
  input         mem_ready_i,
  input         mem_rvalid_i,
  input  [31:0] mem_rdata_i
);

  // ------------------------------------------------------------------
  // Cache geometry constants
  localparam integer LINE_BYTES  = 16;
  localparam integer LINE_WORDS  = LINE_BYTES / 4;
  localparam integer WORD_SEL_BITS = 2;
  localparam integer NUM_WAYS    = 4;
  localparam integer CACHE_BYTES = 16 * 1024;
  localparam integer NUM_LINES   = CACHE_BYTES / LINE_BYTES;
  localparam integer NUM_SETS    = NUM_LINES / NUM_WAYS;
  localparam integer OFFSET_BITS = 4;
  localparam integer INDEX_BITS  = 8;
  localparam integer TAG_BITS    = 32 - OFFSET_BITS - INDEX_BITS;

  // Convenience wires for the incoming address
  wire [31:0] addr_aligned  = {core_addr_i[31:2], 2'b00};
  wire [INDEX_BITS-1:0] req_index = addr_aligned[OFFSET_BITS + INDEX_BITS - 1:OFFSET_BITS];
  wire [TAG_BITS-1:0]   req_tag   = addr_aligned[31:32-TAG_BITS];
  wire [1:0]            req_word  = addr_aligned[3:2];
  wire [INDEX_BITS+WORD_SEL_BITS-1:0] req_line_idx = {req_index, req_word};

  // ------------------------------------------------------------------
  // Arrays
  reg [TAG_BITS-1:0] tag_array   [0:NUM_WAYS-1][0:NUM_SETS-1];
  reg                valid_array [0:NUM_WAYS-1][0:NUM_SETS-1];
  reg                dirty_array [0:NUM_WAYS-1][0:NUM_SETS-1];
  reg [31:0]         data_array  [0:NUM_WAYS-1][0:NUM_SETS*LINE_WORDS-1];
  reg [2:0]          plru_array  [0:NUM_SETS-1];

  // ------------------------------------------------------------------
  // Lookup logic (only used when we start a new request)
  integer w;
  reg              lookup_hit;
  reg [1:0]        lookup_way;
  reg [31:0]       lookup_word;

  wire [NUM_WAYS-1:0]    req_valid_vec;
  wire [NUM_WAYS-1:0]    req_hit_vec;
  wire [NUM_WAYS*32-1:0] req_data_flat;
  genvar g_lookup;
  generate
    for (g_lookup = 0; g_lookup < NUM_WAYS; g_lookup = g_lookup + 1) begin : g_dcache_lookup_taps
      localparam integer DATA_LSB = g_lookup * 32;
      localparam integer DATA_MSB = DATA_LSB + 31;
      assign req_valid_vec[g_lookup] = valid_array[g_lookup][req_index];
      assign req_hit_vec[g_lookup]   = req_valid_vec[g_lookup] && (tag_array[g_lookup][req_index] == req_tag);
      assign req_data_flat[DATA_MSB:DATA_LSB] = data_array[g_lookup][req_line_idx];
    end
  endgenerate

  always @(*) begin
    lookup_hit  = 1'b0;
    lookup_way  = 2'd0;
    lookup_word = req_data_flat[31:0];
    for (w = 0; w < NUM_WAYS; w = w + 1) begin
      if (req_hit_vec[w]) begin
        lookup_hit  = 1'b1;
        lookup_way  = w[1:0];
        lookup_word = req_data_flat[w*32 +: 32];
      end
    end
  end

  // ------------------------------------------------------------------
  // Pseudo-LRU helpers
  function [1:0] plru_pick;
    input [2:0] state;
    begin
      if (state[2] == 1'b0) begin
        plru_pick[1] = 1'b0;
        plru_pick[0] = state[0];
      end else begin
        plru_pick[1] = 1'b1;
        plru_pick[0] = state[1];
      end
    end
  endfunction

  function [2:0] plru_update;
    input [2:0] state;
    input [1:0] way;
    reg [2:0] next;
    begin
      next = state;
      if (way[1] == 1'b0) begin
        next[2] = 1'b1;
        next[0] = (way[0] == 1'b0) ? 1'b1 : 1'b0;
      end else begin
        next[2] = 1'b0;
        next[1] = (way[0] == 1'b0) ? 1'b1 : 1'b0;
      end
      plru_update = next;
    end
  endfunction

  // Helper to merge store data with byte strobes
  function [31:0] apply_wstrb;
    input [31:0] base;
    input [31:0] wdata;
    input [3:0]  wstrb;
    reg [31:0] result;
    begin
      result = base;
      if (wstrb[0]) result[7:0]   = wdata[7:0];
      if (wstrb[1]) result[15:8]  = wdata[15:8];
      if (wstrb[2]) result[23:16] = wdata[23:16];
      if (wstrb[3]) result[31:24] = wdata[31:24];
      apply_wstrb = result;
    end
  endfunction

  // ------------------------------------------------------------------
  // Victim selection (combinational)
  integer vi;
  reg [1:0] victim_way;
  reg       found_invalid;
  wire [2:0] req_plru_state = plru_array[req_index];
  always @(*) begin
    victim_way    = plru_pick(req_plru_state);
    found_invalid = 1'b0;
    for (vi = 0; vi < NUM_WAYS; vi = vi + 1) begin
      if (!req_valid_vec[vi]) begin
        victim_way    = vi[1:0];
        found_invalid = 1'b1;
      end
    end
  end

  // ------------------------------------------------------------------
  // State machine
  localparam S_IDLE      = 3'd0;
  localparam S_RESP      = 3'd1;
  localparam S_WRITEBACK = 3'd2;
  localparam S_REFILL    = 3'd3;

  reg [2:0] state_q;

  // Latched request metadata
  reg        pending_is_load_q;
  reg [31:0] pending_addr_q;
  reg [1:0]  pending_word_q;
  reg [31:0] pending_store_data_q;
  reg [3:0]  pending_store_strb_q;
  reg [1:0]  pending_way_q;   // way selected for hit or victim
  reg [INDEX_BITS-1:0] pending_index_q;
  reg [TAG_BITS-1:0]   pending_tag_q;
  reg [TAG_BITS-1:0]   victim_old_tag_q;
  reg [31:0]           refill_store_word_q;

  // Counters for write-back/fill
  reg [1:0] wb_cnt_q;
  reg [1:0] fill_cnt_q;

  // Response registers
  reg        core_ready_q;
  reg        core_rvalid_q;
  reg [31:0] core_rdata_q;

  assign core_ready_o  = core_ready_q;
  assign core_rvalid_o = core_rvalid_q;
  assign core_rdata_o  = core_rdata_q;

  // Backing memory control registers
  reg        mem_req_q;
  reg        mem_we_q;
  reg [31:0] mem_addr_q;
  reg [31:0] mem_wdata_q;
  reg [3:0]  mem_wstrb_q;

  assign mem_req_o   = mem_req_q;
  assign mem_we_o    = mem_we_q;
  assign mem_addr_o  = mem_addr_q;
  assign mem_wdata_o = mem_wdata_q;
  assign mem_wstrb_o = mem_wstrb_q;

  // Helper
  wire serve_request = (state_q == S_IDLE) && core_req_i;

  integer set_i, way_i, word_i;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q              <= S_IDLE;
      pending_is_load_q    <= 1'b0;
      pending_addr_q       <= 32'h0;
      pending_word_q       <= 2'd0;
      pending_store_data_q <= 32'h0;
      pending_store_strb_q <= 4'b0000;
      pending_way_q        <= 2'd0;
      pending_index_q      <= {INDEX_BITS{1'b0}};
      pending_tag_q        <= {TAG_BITS{1'b0}};
      victim_old_tag_q     <= {TAG_BITS{1'b0}};
      refill_store_word_q  <= 32'h0;
      wb_cnt_q             <= 2'd0;
      fill_cnt_q           <= 2'd0;
      core_ready_q         <= 1'b0;
      core_rvalid_q        <= 1'b0;
      core_rdata_q         <= 32'h0;
      mem_req_q            <= 1'b0;
      mem_we_q             <= 1'b0;
      mem_addr_q           <= 32'h0;
      mem_wdata_q          <= 32'h0;
      mem_wstrb_q          <= 4'b0000;
      for (set_i = 0; set_i < NUM_SETS; set_i = set_i + 1) begin
        plru_array[set_i] <= 3'b000;
        for (way_i = 0; way_i < NUM_WAYS; way_i = way_i + 1) begin
          valid_array[way_i][set_i] <= 1'b0;
          dirty_array[way_i][set_i] <= 1'b0;
          tag_array[way_i][set_i]   <= {TAG_BITS{1'b0}};
          for (word_i = 0; word_i < LINE_WORDS; word_i = word_i + 1) begin
            data_array[way_i][(set_i << WORD_SEL_BITS) + word_i] <= 32'h0;
          end
        end
      end
    end else begin
      // Defaults each cycle
      core_ready_q  <= 1'b0;
      core_rvalid_q <= 1'b0;
      mem_req_q     <= 1'b0;
      mem_we_q      <= 1'b0;
      mem_addr_q    <= 32'h0;
      mem_wdata_q   <= 32'h0;
      mem_wstrb_q   <= 4'b0000;

      case (state_q)
        S_IDLE: begin
          if (serve_request) begin
            pending_is_load_q   <= ~core_we_i;
            pending_addr_q      <= addr_aligned;
            pending_word_q      <= req_word;
            pending_index_q     <= req_index;
            pending_tag_q       <= req_tag;
            refill_store_word_q <= 32'h0;

            if (core_we_i) begin
              pending_store_data_q <= core_wdata_i;
              pending_store_strb_q <= core_wstrb_i;
            end

            if (lookup_hit) begin
              pending_way_q <= lookup_way;
              plru_array[req_index] <= plru_update(plru_array[req_index], lookup_way);
              if (core_we_i) begin
                data_array[lookup_way][(req_index << WORD_SEL_BITS) + req_word] <= apply_wstrb(lookup_word, core_wdata_i, core_wstrb_i);
                dirty_array[lookup_way][req_index] <= 1'b1;
                state_q <= S_RESP;
              end else begin
                core_rdata_q <= lookup_word;
                dirty_array[lookup_way][req_index] <= dirty_array[lookup_way][req_index];
                state_q <= S_RESP;
              end
            end else begin
              pending_way_q     <= victim_way;
              victim_old_tag_q  <= tag_array[victim_way][req_index];
              wb_cnt_q          <= 2'd0;
              fill_cnt_q        <= 2'd0;
              if (valid_array[victim_way][req_index] && dirty_array[victim_way][req_index]) begin
                state_q <= S_WRITEBACK;
              end else begin
                state_q <= S_REFILL;
              end
            end
          end
        end

        S_RESP: begin
          if (pending_is_load_q) begin
            core_rvalid_q <= 1'b1;
          end else begin
            core_ready_q  <= 1'b1;
          end
          state_q <= S_IDLE;
        end

        S_WRITEBACK: begin
          mem_req_q   <= 1'b1;
          mem_we_q    <= 1'b1;
          mem_addr_q  <= {victim_old_tag_q, pending_index_q, 4'b0000} + {wb_cnt_q, 2'b00};
          mem_wdata_q <= data_array[pending_way_q][(pending_index_q << WORD_SEL_BITS) + wb_cnt_q];
          mem_wstrb_q <= 4'b1111;

          if (mem_ready_i) begin
            if (wb_cnt_q == LINE_WORDS - 1) begin
              dirty_array[pending_way_q][pending_index_q] <= 1'b0;
              state_q <= S_REFILL;
              fill_cnt_q <= 2'd0;
            end else begin
              wb_cnt_q <= wb_cnt_q + 1'b1;
            end
          end
        end

        S_REFILL: begin
          mem_req_q  <= 1'b1;
          mem_we_q   <= 1'b0;
          mem_addr_q <= {pending_tag_q, pending_index_q, 4'b0000} + {fill_cnt_q, 2'b00};

          if (mem_rvalid_i) begin
            data_array[pending_way_q][(pending_index_q << WORD_SEL_BITS) + fill_cnt_q] <= mem_rdata_i;
            if (fill_cnt_q == pending_word_q) begin
              core_rdata_q        <= mem_rdata_i;
              refill_store_word_q <= mem_rdata_i;
            end

            if (fill_cnt_q == LINE_WORDS - 1) begin
              valid_array[pending_way_q][pending_index_q] <= 1'b1;
              tag_array[pending_way_q][pending_index_q]   <= pending_tag_q;
              plru_array[pending_index_q]                 <= plru_update(plru_array[pending_index_q], pending_way_q);

              if (pending_is_load_q) begin
                dirty_array[pending_way_q][pending_index_q] <= 1'b0;
                core_rvalid_q <= 1'b1;
              end else begin
                data_array[pending_way_q][(pending_index_q << WORD_SEL_BITS) + pending_word_q] <= apply_wstrb(refill_store_word_q, pending_store_data_q, pending_store_strb_q);
                dirty_array[pending_way_q][pending_index_q] <= 1'b1;
                core_ready_q <= 1'b1;
              end

              state_q <= S_IDLE;
            end else begin
              fill_cnt_q <= fill_cnt_q + 1'b1;
            end
          end
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule
