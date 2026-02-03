`timescale 1ns/1ps
// sram_fpga.v - FPGA-friendly synchronous dual-port memory (line-based)
// - IMEM: synchronous read (1-cycle latency), 32-bit
// - DMEM: line (LINE_BYTES) read/write with byte strobes
// - Uses a single write per cycle to infer BRAM (width = LINE_BITS)
module sram_fpga #(
  parameter [31:0] SRAM_BASE_ADDR  = 32'h0000_0000,
  parameter [31:0] SRAM_SIZE_BYTES = 32'd65536,   // clamp externally if needed
  parameter [31:0] SRAM_LAST_ADDR  = 32'h0000_FFFF,
  parameter integer LINE_BYTES     = 32,          // 256-bit line
  parameter INIT_FILE = ""
)(
  input         clk,
  input         rst_n,
  // Instruction port (synchronous read)
  input  [31:0] imem_addr_i,
  output [31:0] imem_rdata_o,
  // Data port (line interface)
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

  function integer clog2;
    input integer value;
    integer tmp, cnt;
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

  localparam integer LINE_BITS     = LINE_BYTES * 8;      // 256
  localparam integer LINE_OFF_BITS = clog2(LINE_BYTES);   // 5 for 32-byte line
  localparam integer NUM_LINES     = SRAM_SIZE_BYTES / LINE_BYTES;
  localparam integer WORDS_PER_LINE= LINE_BYTES / 4;

  // One line per entry to keep a single write per cycle (BRAM friendly)
  (* ram_style = "block" *) reg [LINE_BITS-1:0] mem [0:NUM_LINES-1];

  // Optional init file
  integer init_idx;
  initial begin
`ifndef SYNTHESIS
    if (INIT_FILE != "") begin
      $display("[SRAM_FPGA] INFO: Loading init file %s", INIT_FILE);
      $readmemh(INIT_FILE, mem);
    end else begin
      for (init_idx = 0; init_idx < NUM_LINES; init_idx = init_idx + 1)
        mem[init_idx] = {LINE_BITS{1'b0}};
    end
`else
    if (INIT_FILE != "") begin
      $readmemh(INIT_FILE, mem);
    end else begin
      for (init_idx = 0; init_idx < NUM_LINES; init_idx = init_idx + 1)
        mem[init_idx] = {LINE_BITS{1'b0}};
    end
`endif
  end

  // IMEM synchronous read (1-cycle latency)
  reg [31:0] imem_rdata_q;
  wire [31:0] imem_addr_aligned = {imem_addr_i[31:2], 2'b00};
  wire [LINE_OFF_BITS-1:0] imem_word_off = imem_addr_aligned[LINE_OFF_BITS+1:2];
  wire [clog2(NUM_LINES)-1:0] imem_line_idx =
      (imem_addr_aligned - SRAM_BASE_ADDR) >> LINE_OFF_BITS;
  wire imem_in_range = (imem_addr_aligned >= SRAM_BASE_ADDR) &&
                       (imem_addr_aligned <= SRAM_LAST_ADDR);

  always @(posedge clk) begin
    if (!rst_n) begin
      imem_rdata_q  <= 32'h0000_0013; // NOP
    end else if (imem_in_range) begin
      imem_rdata_q <= mem[imem_line_idx][imem_word_off*32 +: 32];
    end else begin
      imem_rdata_q <= 32'h0000_0013;
    end
  end
  assign imem_rdata_o = imem_rdata_q;

  // DMEM interface (always ready; read has 1-cycle latency)
  assign dmem_ready_o = 1'b1;

  wire [31:0] line_base_addr = {dmem_addr_i[31:LINE_OFF_BITS], {LINE_OFF_BITS{1'b0}}};
  wire [31:0] line_last_addr = line_base_addr + (LINE_BYTES - 1);
  wire line_in_range = (line_base_addr >= SRAM_BASE_ADDR) && (line_last_addr <= SRAM_LAST_ADDR);
  wire [clog2(NUM_LINES)-1:0] line_idx = (line_base_addr - SRAM_BASE_ADDR) >> LINE_OFF_BITS;

  reg                  resp_valid_q;
  reg                  resp_err_q;
  reg [LINE_BITS-1:0]  resp_data_q;

  assign dmem_resp_valid_o = resp_valid_q;
  assign dmem_resp_rdata_o = resp_data_q;
  assign dmem_resp_err_o   = resp_err_q;

  integer b;
  reg [LINE_BITS-1:0] new_line;

  always @(posedge clk) begin
    if (!rst_n) begin
      resp_valid_q <= 1'b0;
      resp_err_q   <= 1'b0;
      resp_data_q  <= {LINE_BITS{1'b0}};
    end else begin
      resp_valid_q <= 1'b0;
      resp_err_q   <= 1'b0;
      if (dmem_req_i) begin
        if (dmem_we_i) begin
          if (line_in_range) begin
            new_line = mem[line_idx];
            for (b = 0; b < LINE_BYTES; b = b + 1) begin
              if (dmem_wstrb_i[b]) begin
                new_line[b*8 +: 8] = dmem_wdata_i[b*8 +: 8];
              end
            end
            mem[line_idx] <= new_line;
          end else begin
            resp_err_q <= 1'b1;
          end
        end else begin
          // read path
          if (line_in_range) begin
            resp_data_q  <= mem[line_idx];
            resp_err_q   <= 1'b0;
          end else begin
            resp_data_q  <= {LINE_BITS{1'b0}};
            resp_err_q   <= 1'b1;
          end
          resp_valid_q <= 1'b1;
        end
      end
    end
  end

endmodule
