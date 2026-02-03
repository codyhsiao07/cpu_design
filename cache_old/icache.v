// icache.v -- 16KB 4-way set-associative instruction cache with pseudo-LRU replacement
// - Read-only interface toward the core
// - Simple combinational read port toward backing memory (matches original IMEM interface)
// - 1-cycle hit latency; miss stalls fetch until refill completes
//
// Cache organization:
//   * Total size: 16 KB
//   * Line size: 16 bytes (4x 32-bit words)
//   * 4 ways => 256 sets
//   * Tag width: 20 bits (assuming 32-bit address)
//
// NOTE: Backing memory is assumed combinational (the same interface previously used by the core).
//       On a miss, the cache iterates through the four words in the line across four cycles and
//       captures the data presented by mem_rdata_i for the requested address. Later integration
//       with a real DRAM controller should replace this simple interface with a handshake-based
//       port. The control logic is structured so that adding such a handshake is localized around
//       the refill portion.

module icache (
  input         clk,
  input         rst_n,

  // Core-side fetch request (always-on in the current pipeline)
  input         fetch_valid_i,
  input  [31:0] fetch_addr_i,
  output [31:0] fetch_data_o,
  output        fetch_stall_o,

  // Backing instruction memory (combinational read)
  output [31:0] mem_addr_o,
  input  [31:0] mem_rdata_i
);

  // ------------------------------------------------------------------
  // Cache geometry constants (hard-coded to the requested configuration)
  localparam integer LINE_BYTES  = 16;
  localparam integer LINE_WORDS  = LINE_BYTES / 4;    // 4 words per line
  localparam integer WORD_SEL_BITS = 2;               // log2(LINE_WORDS)
  localparam integer NUM_WAYS    = 4;
  localparam integer CACHE_BYTES = 16 * 1024;
  localparam integer NUM_LINES   = CACHE_BYTES / LINE_BYTES; // 1024 total lines
  localparam integer NUM_SETS    = NUM_LINES / NUM_WAYS;      // 256 sets
  localparam integer OFFSET_BITS = 4;                         // log2(16)
  localparam integer INDEX_BITS  = 8;                         // log2(256)
  localparam integer TAG_BITS    = 32 - OFFSET_BITS - INDEX_BITS;

  // Address breakdown helpers
  wire [31:0] fetch_addr_aligned = {fetch_addr_i[31:2], 2'b00};
  wire [INDEX_BITS-1:0] fetch_index = fetch_addr_aligned[OFFSET_BITS + INDEX_BITS - 1:OFFSET_BITS];
  wire [TAG_BITS-1:0]   fetch_tag   = fetch_addr_aligned[31:32-TAG_BITS];
  wire [1:0]            fetch_word  = fetch_addr_aligned[3:2];
  wire [INDEX_BITS+WORD_SEL_BITS-1:0] fetch_line_idx = {fetch_index, fetch_word};

  // ------------------------------------------------------------------
  // Tag, validity, and data arrays
  reg [TAG_BITS-1:0] tag_array   [0:NUM_WAYS-1][0:NUM_SETS-1];
  reg                valid_array [0:NUM_WAYS-1][0:NUM_SETS-1];
  reg [31:0]         data_array  [0:NUM_WAYS-1][0:NUM_SETS*LINE_WORDS-1];
  reg [2:0]          plru_array  [0:NUM_SETS-1]; // pseudo-LRU tree bits per set

  // ------------------------------------------------------------------
  // Lookup combinational logic
  integer w;
  reg              lookup_hit;
  reg [1:0]        lookup_way;
  reg [31:0]       lookup_word;

  wire [NUM_WAYS-1:0]    lookup_valid_vec;
  wire [NUM_WAYS-1:0]    lookup_tag_match_vec;
  wire [NUM_WAYS-1:0]    lookup_hit_vec;
  wire [NUM_WAYS*32-1:0] lookup_data_flat;
  genvar g_lookup;
  generate
    for (g_lookup = 0; g_lookup < NUM_WAYS; g_lookup = g_lookup + 1) begin : g_icache_lookup_taps
      localparam integer DATA_LSB = g_lookup * 32;
      localparam integer DATA_MSB = DATA_LSB + 31;
      assign lookup_valid_vec[g_lookup]     = valid_array[g_lookup][fetch_index];
      assign lookup_tag_match_vec[g_lookup] = (tag_array[g_lookup][fetch_index] == fetch_tag);
      assign lookup_hit_vec[g_lookup]       = lookup_valid_vec[g_lookup] && lookup_tag_match_vec[g_lookup];
      assign lookup_data_flat[DATA_MSB:DATA_LSB] = data_array[g_lookup][fetch_line_idx];
    end
  endgenerate

  always @(*) begin
    lookup_hit  = 1'b0;
    lookup_way  = 2'd0;
    lookup_word = 32'h0000_0013; // Default to NOP while idle/miss
    for (w = 0; w < NUM_WAYS; w = w + 1) begin
      if (lookup_hit_vec[w]) begin
        lookup_hit  = 1'b1;
        lookup_way  = w[1:0];
        lookup_word = lookup_data_flat[w*32 +: 32];
      end
    end
  end

  // ------------------------------------------------------------------
  // Pseudo-LRU helpers (4-way binary tree encoding)
  function [1:0] plru_pick;
    input [2:0] state;
    begin
      if (state[2] == 1'b0) begin
        // Prefer left subtree (ways 0/1)
        plru_pick[1] = 1'b0;
        plru_pick[0] = state[0];
      end else begin
        // Prefer right subtree (ways 2/3)
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
        // Access in left subtree -> next eviction should pick right
        next[2] = 1'b1;
        next[0] = (way[0] == 1'b0) ? 1'b1 : 1'b0;
      end else begin
        // Access in right subtree -> next eviction should pick left
        next[2] = 1'b0;
        next[1] = (way[0] == 1'b0) ? 1'b1 : 1'b0;
      end
      plru_update = next;
    end
  endfunction

  // ------------------------------------------------------------------
  // Refill state machine
  localparam STATE_LOOKUP = 1'b0;
  localparam STATE_REFILL = 1'b1;

  reg         state_q;
  reg [1:0]   refill_way_q;
  reg [INDEX_BITS-1:0] refill_index_q;
  reg [TAG_BITS-1:0]   refill_tag_q;
  reg [1:0]            refill_word_q;      // Which word is being fetched this cycle
  reg [1:0]            target_word_q;      // Word requested by the miss
  reg [31:0]           fetch_data_q;

  // Decide victim on miss (combinational)
  integer vi;
  reg [1:0] victim_way;
  reg       found_invalid;
  wire [2:0] fetch_plru_state = plru_array[fetch_index];
  always @(*) begin
    victim_way    = plru_pick(fetch_plru_state);
    found_invalid= 1'b0;
    for (vi = 0; vi < NUM_WAYS; vi = vi + 1) begin
      if (!lookup_valid_vec[vi]) begin
        victim_way    = vi[1:0];
        found_invalid = 1'b1;
      end
    end
  end

  wire miss_event = (state_q == STATE_LOOKUP) && fetch_valid_i && !lookup_hit;

  // Backing memory address selection
  reg [31:0] refill_base_q;
  wire [31:0] refill_addr = refill_base_q + {refill_word_q, 2'b00};
  assign mem_addr_o = (state_q == STATE_REFILL) ? refill_addr : fetch_addr_aligned;

  assign fetch_stall_o = (state_q != STATE_LOOKUP);
  assign fetch_data_o  = fetch_data_q;

  integer way_i, set_i, word_i;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q        <= STATE_LOOKUP;
      refill_way_q   <= 2'd0;
      refill_index_q <= {INDEX_BITS{1'b0}};
      refill_tag_q   <= {TAG_BITS{1'b0}};
      refill_word_q  <= 2'd0;
      target_word_q  <= 2'd0;
      refill_base_q  <= 32'h0000_0000;
      fetch_data_q   <= 32'h0000_0013; // NOP after reset
      for (set_i = 0; set_i < NUM_SETS; set_i = set_i + 1) begin
        plru_array[set_i] <= 3'b000;
        for (way_i = 0; way_i < NUM_WAYS; way_i = way_i + 1) begin
          valid_array[way_i][set_i] <= 1'b0;
          tag_array[way_i][set_i]   <= {TAG_BITS{1'b0}};
          for (word_i = 0; word_i < LINE_WORDS; word_i = word_i + 1) begin
            data_array[way_i][(set_i << WORD_SEL_BITS) + word_i] <= 32'h0000_0013;
          end
        end
      end
    end else begin
      case (state_q)
        STATE_LOOKUP: begin
          if (fetch_valid_i && lookup_hit) begin
            fetch_data_q <= lookup_word;
            plru_array[fetch_index] <= plru_update(plru_array[fetch_index], lookup_way);
          end

          if (miss_event) begin
            // Capture refill context
            refill_way_q   <= victim_way;
            refill_index_q <= fetch_index;
            refill_tag_q   <= fetch_tag;
            target_word_q  <= fetch_word;
            refill_word_q  <= 2'd0;
            refill_base_q  <= {fetch_addr_aligned[31:4], 4'b0000};
            state_q        <= STATE_REFILL;
          end
        end

        STATE_REFILL: begin
          // Capture word from backing memory for the current offset
          data_array[refill_way_q][(refill_index_q << WORD_SEL_BITS) + refill_word_q] <= mem_rdata_i;
          if (refill_word_q == target_word_q)
            fetch_data_q <= mem_rdata_i;

          if (refill_word_q == LINE_WORDS - 1) begin
            valid_array[refill_way_q][refill_index_q] <= 1'b1;
            tag_array[refill_way_q][refill_index_q]   <= refill_tag_q;
            plru_array[refill_index_q]                <= plru_update(plru_array[refill_index_q], refill_way_q);
            state_q                                   <= STATE_LOOKUP;
          end else begin
            refill_word_q <= refill_word_q + 1'b1;
          end
        end

        default: state_q <= STATE_LOOKUP;
      endcase
    end
  end

endmodule
