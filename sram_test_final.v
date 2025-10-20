// sram_2mb.v -- Unified SRAM backing store for icache/dcache
// - Port A (IMEM): combinational read for icache (addr -> rdata)
// - Port B (DCACHE): line-based request/response (write-back capable)
//   * Accepts full cache-line read or write requests
//   * Write requests use byte strobes (one per byte in the line)
//   * Read requests complete one cycle after acceptance
//
// Default capacity = 2 MiB, address window 0x8000_0000 .. 0x801F_FFFF
// Region partitions: TEXT (read-only), DATA/STACK (read-write)
// -----------------------------------------------------------------------------
module sram_2mb #(
  parameter [31:0] SRAM_BASE_ADDR  = 32'h0000_0000,
  parameter [31:0] SRAM_SIZE_BYTES = 32'd2097152,   // 2 MiB
  parameter [31:0] SRAM_LAST_ADDR  = 32'h001F_FFFF, // base + size - 1

  // Region partitions (must fully cover SRAM window)
  parameter [31:0] TEXT_BASE_ADDR  = 32'h0000_0000,
  parameter [31:0] TEXT_LAST_ADDR  = 32'h000F_FFFF,
  parameter [31:0] DATA_BASE_ADDR  = 32'h0010_0000,
  parameter [31:0] DATA_LAST_ADDR  = 32'h001B_FFFF,
  parameter [31:0] STACK_BASE_ADDR = 32'h001C_0000,
  parameter [31:0] STACK_LAST_ADDR = 32'h001F_FFFF,

  // Cache line geometry (must match dcache)
  parameter integer LINE_BYTES     = 32,

  // Optional initialization file (verilog hex), relative to sim working dir
  parameter INIT_FILE = ""
)(
  input         clk,
  input         rst_n,

  // Instruction-side (icache) combinational read port
  input  [31:0] imem_addr_i,
  output [31:0] imem_rdata_o,

  // Data-side (dcache) line-based interface
  input         dmem_req_i,
  output        dmem_ready_o,
  input         dmem_we_i,
  input  [31:0] dmem_addr_i,
  input  [LINE_BYTES*8-1:0] dmem_wdata_i,
  input  [LINE_BYTES-1:0]   dmem_wstrb_i,
  output        dmem_resp_valid_o,
  output [LINE_BYTES*8-1:0] dmem_resp_rdata_o,
  output        dmem_resp_err_o
);

  // ---------------------------------------------------------------------------
  // Helpers
  function integer clog2;
    input integer value;
    integer tmp;
    integer cnt;
    begin
      tmp = (value > 1) ? (value - 1) : 0;
      cnt = 0;
      while (tmp > 0) begin
        tmp = tmp >> 1;
        cnt = cnt + 1;
      end
      clog2 = cnt;
    end
  endfunction

  localparam integer LINE_BITS        = LINE_BYTES * 8;
  localparam integer LINE_WORDS       = LINE_BYTES / 4;
  localparam integer LINE_OFF_BITS    = clog2(LINE_BYTES);
  localparam integer MEM_WORDS        = SRAM_SIZE_BYTES / 4;

  initial begin
    if ((LINE_BYTES % 4) != 0) begin
      $display("%t [SRAM] ERROR: LINE_BYTES (%0d) must be divisible by 4.", $time, LINE_BYTES);
      $finish;
    end
    if ((SRAM_SIZE_BYTES % LINE_BYTES) != 0) begin
      $display("%t [SRAM] ERROR: SRAM_SIZE_BYTES must be a multiple of LINE_BYTES.", $time);
      $finish;
    end
  end

  // ---------------------------------------------------------------------------
  // Backing storage (word-addressable)
  reg [31:0] mem [0:MEM_WORDS-1];


`ifndef SYNTHESIS
// ==== BEGIN: Inline program (no user macros required) ====
localparam [31:0] BOOT_PC = TEXT_BASE_ADDR;
integer __tb_i;
initial begin
  #1;
  for (__tb_i = 0; __tb_i < 16; __tb_i = __tb_i + 1)
    mem[((BOOT_PC - SRAM_BASE_ADDR) >> 2) + __tb_i] = 32'h00000013;
  // LUI x10, DATA_BASE_ADDR>>12
  mem[(BOOT_PC + 32'h0000 - SRAM_BASE_ADDR) >> 2] = { DATA_BASE_ADDR[31:12], 5'd10, 7'h37 };
  // ADDI x1,5
  mem[(BOOT_PC + 32'h0004 - SRAM_BASE_ADDR) >> 2] = 32'h00500093;
  // ADDI x2,x1,7  -> 12
  mem[(BOOT_PC + 32'h0008 - SRAM_BASE_ADDR) >> 2] = 32'h00708113;
  // SW x2,0(x10)
  mem[(BOOT_PC + 32'h000C - SRAM_BASE_ADDR) >> 2] = 32'h00252023;
  // NOP (allow store to settle)
  mem[(BOOT_PC + 32'h0010 - SRAM_BASE_ADDR) >> 2] = 32'h00000013;
  // LW x3,0(x10)   -> 12
  mem[(BOOT_PC + 32'h0014 - SRAM_BASE_ADDR) >> 2] = 32'h00052183;
  // ADD x4,x3,x1   -> 17
  mem[(BOOT_PC + 32'h0018 - SRAM_BASE_ADDR) >> 2] = 32'h00118233;
  // JAL x0,0
  mem[(BOOT_PC + 32'h001C - SRAM_BASE_ADDR) >> 2] = 32'h0000006F;
end
// ==== END: Inline program ====
`endif


  localparam [31:0] RV32_NOP = 32'h0000_0013;

  // ---------------------------------------------------------------------------
  // ICACHE combinational read (word-aligned)
  wire [31:0] imem_addr_aligned = {imem_addr_i[31:2], 2'b00};
  wire        imem_in_sram      = (imem_addr_aligned >= SRAM_BASE_ADDR) && (imem_addr_aligned <= SRAM_LAST_ADDR);
  reg  [31:0] imem_rdata_q;
  integer     imem_word_idx;

  always @(*) begin
    if (imem_in_sram) begin
      imem_word_idx = (imem_addr_aligned - SRAM_BASE_ADDR) >> 2;
      imem_rdata_q  = mem[imem_word_idx];
    end else begin
      imem_rdata_q  = RV32_NOP;
    end
  end

  assign imem_rdata_o = imem_rdata_q;

  // ---------------------------------------------------------------------------
  // DCACHE line interface
  wire [31:0] line_base_addr = {dmem_addr_i[31:LINE_OFF_BITS], {LINE_OFF_BITS{1'b0}}};
  wire [31:0] line_last_addr = line_base_addr + (LINE_BYTES - 1);
  wire        line_in_sram   = (line_base_addr >= SRAM_BASE_ADDR) && (line_last_addr <= SRAM_LAST_ADDR);

  // Region overlap helpers (inclusive ranges)
  wire line_hits_text  = (line_base_addr <= TEXT_LAST_ADDR)  && (line_last_addr >= TEXT_BASE_ADDR);
  wire line_hits_data  = (line_base_addr <= DATA_LAST_ADDR)  && (line_last_addr >= DATA_BASE_ADDR);
  wire line_hits_stack = (line_base_addr <= STACK_LAST_ADDR) && (line_last_addr >= STACK_BASE_ADDR);

  wire [31:0] line_word_index = (line_base_addr - SRAM_BASE_ADDR) >> 2;

  // Ready when no pending read response
  reg pending_read_q;
  assign dmem_ready_o = ~pending_read_q;

  // Pending read bookkeeping
  reg [31:0] read_word_index_q;
  reg        read_in_range_q;

  reg                  dmem_resp_valid_q;
  reg [LINE_BITS-1:0]  dmem_resp_data_q;
  reg                  dmem_resp_err_q;

  assign dmem_resp_valid_o = dmem_resp_valid_q;
  assign dmem_resp_rdata_o = dmem_resp_data_q;
  assign dmem_resp_err_o   = dmem_resp_err_q;

  // Byte-strobe helper (apply to 32-bit word)
  function [31:0] apply_wstrb_word;
    input [31:0] base;
    input [31:0] data;
    input [3:0]  strb;
    reg   [31:0] result;
    begin
      result = base;
      if (strb[0]) result[7:0]   = data[7:0];
      if (strb[1]) result[15:8]  = data[15:8];
      if (strb[2]) result[23:16] = data[23:16];
      if (strb[3]) result[31:24] = data[31:24];
      apply_wstrb_word = result;
    end
  endfunction

  integer w_idx;
  integer word_addr_idx;
  reg [3:0]  word_strb;
  reg [31:0] new_word;
  reg [31:0] cur_word;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pending_read_q     <= 1'b0;
      read_word_index_q  <= 32'h0;
      read_in_range_q    <= 1'b0;
      dmem_resp_valid_q  <= 1'b0;
      dmem_resp_data_q   <= {LINE_BITS{1'b0}};
      dmem_resp_err_q    <= 1'b0;
    end else begin
      dmem_resp_valid_q <= 1'b0;
      dmem_resp_err_q   <= 1'b0;

      // Complete pending read (one cycle latency)
      if (pending_read_q) begin
        if (read_in_range_q) begin
          for (w_idx = 0; w_idx < LINE_WORDS; w_idx = w_idx + 1) begin
            dmem_resp_data_q[w_idx*32 +: 32] <= mem[read_word_index_q + w_idx];
          end
          dmem_resp_err_q <= 1'b0;
        end else begin
          dmem_resp_data_q <= {LINE_BITS{1'b0}};
          dmem_resp_err_q  <= 1'b1;
        end
        dmem_resp_valid_q <= 1'b1;
        pending_read_q    <= 1'b0;
      end

      // Accept new request when ready
      if (dmem_req_i && dmem_ready_o) begin
        if (dmem_we_i) begin
          if (!line_in_sram) begin
            $display("%t [SRAM] WARN: Write outside SRAM range at 0x%08h ignored.", $time, line_base_addr);
          end else if (line_hits_text) begin
            $display("%t [SRAM] ERROR: Write to read-only TEXT region (addr 0x%08h) ignored.", $time, line_base_addr);
          end else if (!(line_hits_data || line_hits_stack)) begin
            $display("%t [SRAM] WARN: Write to unmapped region at 0x%08h ignored.", $time, line_base_addr);
          end else begin
            // Apply per-word strobes within the line
            for (w_idx = 0; w_idx < LINE_WORDS; w_idx = w_idx + 1) begin
              word_addr_idx = line_word_index + w_idx;
              word_strb     = dmem_wstrb_i[w_idx*4 +: 4];
              if (word_strb != 4'b0000) begin
                cur_word = mem[word_addr_idx];
                new_word = dmem_wdata_i[w_idx*32 +: 32];
                mem[word_addr_idx] <= apply_wstrb_word(cur_word, new_word, word_strb);
              end
            end
          end
        end else begin
          pending_read_q    <= 1'b1;
          read_word_index_q <= line_word_index;
          read_in_range_q   <= line_in_sram;
          if (!line_in_sram)
            $display("%t [SRAM] WARN: Read outside SRAM range at 0x%08h (returning zeros).", $time, line_base_addr);
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Reset/init memory contents
  integer init_idx;
  initial begin
    for (init_idx = 0; init_idx < MEM_WORDS; init_idx = init_idx + 1)
      mem[init_idx] = 32'h0;

    if (TEXT_BASE_ADDR     != SRAM_BASE_ADDR ||
        STACK_LAST_ADDR    != SRAM_LAST_ADDR ||
        TEXT_LAST_ADDR + 1 != DATA_BASE_ADDR ||
        DATA_LAST_ADDR + 1 != STACK_BASE_ADDR) begin
      $display("%t [SRAM] ERROR: Region partition does not fully cover SRAM window.", $time);
      $fatal(1);
    end

    if (INIT_FILE != "") begin
      #1;
      $display("%t [SRAM] INFO: Loading init file %s", $time, INIT_FILE);
      $readmemh(INIT_FILE, mem);
    end
  end
endmodule
