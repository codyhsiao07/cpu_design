// sram_2mb.v -- Unified SRAM backing store for icache/dcache
// - Port A (IMEM): combinational read for icache (addr -> rdata)
// - Port B (DCACHE): line-based request/response (write-back capable)
//   * Accepts full cache-line read or write requests
//   * Write requests use byte strobes (one per byte in the line)
//   * Read requests complete one cycle after acceptance
//
// Default capacity = 225 KiB, address window 0x0000_0000 .. 0x0003_83FF
// Region partitions: TEXT (read-only), DATA/STACK (read-write)
// -----------------------------------------------------------------------------
module sram_2mb #(
  parameter [31:0] SRAM_BASE_ADDR  = 32'h0000_0000,
  parameter [31:0] SRAM_SIZE_BYTES = 32'd230400,    // 225 KiB (Basys3 BRAM budget)
  parameter [31:0] SRAM_LAST_ADDR  = 32'h0003_83FF, // base + size - 1

  // Region partitions (must fully cover SRAM window)
  parameter [31:0] TEXT_BASE_ADDR  = 32'h0000_0000,
  parameter [31:0] TEXT_LAST_ADDR  = 32'h0000_7FFF,
  parameter [31:0] DATA_BASE_ADDR  = 32'h0000_8000,
  parameter [31:0] DATA_LAST_ADDR  = 32'h0002_7FFF,
  parameter [31:0] STACK_BASE_ADDR = 32'h0002_8000,
  parameter [31:0] STACK_LAST_ADDR = 32'h0003_83FF,

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
  localparam integer MAX_BRAM_BYTES   = 32'd230400; // 225 KiB
  localparam integer PARAM_LAST_SPAN  =
      (SRAM_LAST_ADDR >= SRAM_BASE_ADDR) ? (SRAM_LAST_ADDR - SRAM_BASE_ADDR + 32'd1) : 32'd0;
  localparam integer REQUESTED_BYTES  =
      (SRAM_SIZE_BYTES < PARAM_LAST_SPAN) ? SRAM_SIZE_BYTES : PARAM_LAST_SPAN;
  localparam integer CLAMPED_BYTES    =
      (REQUESTED_BYTES > MAX_BRAM_BYTES) ? MAX_BRAM_BYTES : REQUESTED_BYTES;
  localparam integer SRAM_SIZE_BYTES_EFF =
      (CLAMPED_BYTES / LINE_BYTES) * LINE_BYTES;
  localparam [31:0] SRAM_LAST_ADDR_EFF = SRAM_BASE_ADDR + SRAM_SIZE_BYTES_EFF - 32'd1;
  localparam integer MEM_WORDS        = (SRAM_SIZE_BYTES_EFF / 4);

`ifndef SYNTHESIS
  initial begin
    if ((LINE_BYTES % 4) != 0) begin
      $display("%t [SRAM] ERROR: LINE_BYTES (%0d) must be divisible by 4.", $time, LINE_BYTES);
      $finish;
    end
    if (SRAM_SIZE_BYTES_EFF == 0) begin
      $display("%t [SRAM] ERROR: Effective SRAM size collapsed to zero bytes. Check parameters.", $time);
      $finish;
    end
    if ((SRAM_SIZE_BYTES_EFF % LINE_BYTES) != 0) begin
      $display("%t [SRAM] ERROR: Effective SRAM size must be a multiple of LINE_BYTES.", $time);
      $finish;
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Backing storage (word-addressable)
  (* ram_style = "block" *) reg [31:0] mem [0:MEM_WORDS-1];


// sram_test_programs_full.vh  (Verilog-2001)
// A comprehensive inline test suite for your 5-stage pipeline + SRAM.
// Modes (define ONE at compile-time):
//   -D SRAM_TB_SUITE_FULL        : Broad, legal scenarios; ends with x4=17 → PASS
//   -D SRAM_TB_DIVERSE_PASS      : Medium-size legal suite; ends with x4=17 → PASS
//   -D SRAM_TB_ISA_BASELINE      : Directed ALU/branch sweep; ends with x4=17 ??PASS
//   -D SRAM_TB_STACK_EXERCISE    : Stack push/pop + subroutine; ends with x4=17 ??PASS
//   -D SRAM_TB_RANDOM_STRESS     : Pseudo-random store/loop mix; ends with x4=17 ??PASS
//   -D SRAM_TB_ILLEGAL_FAIL      : Store to TEXT (illegal) → mem_access_err expected
//   -D SRAM_TB_NEG_OOR_HI_STORE  : Store above SRAM_LAST → mem_access_err expected
//   -D SRAM_TB_NEG_OOR_LO_STORE  : Store below SRAM_BASE → mem_access_err expected
//   -D SRAM_TB_NEG_OOR_HI_LOAD   : Load above SRAM_LAST  → mem_access_err expected
//   -D SRAM_TB_SMOKE             : Tiny store/load sanity; ends with x4=17 → PASS
// Default (none defined) now runs the shortened SUITE_FULL scenario; define
// another macro to override it when needed.
//
// Optional address overrides (compile-time macros):
//   -D SRAM_TB_TEXT_BASE=32'h0000_0000
//   -D SRAM_TB_TEXT_LAST=32'h0000_7FFC
//   -D SRAM_TB_DATA_BASE=32'h0000_8000
//   -D SRAM_TB_SRAM_BASE=32'h0000_0000
//   -D SRAM_TB_SRAM_SIZE_BYTES=32'h0003_8400   // 225 KiB default
//
`ifndef SRAM_TB_TEXT_BASE
`define SRAM_TB_TEXT_BASE 32'h0000_0000
`endif
`ifndef SRAM_TB_TEXT_LAST
`define SRAM_TB_TEXT_LAST 32'h0000_7FFC
`endif
`ifndef SRAM_TB_DATA_BASE
`define SRAM_TB_DATA_BASE 32'h0000_8000
`endif
`ifndef SRAM_TB_SRAM_BASE
`define SRAM_TB_SRAM_BASE 32'h0000_0000
`endif
`ifndef SRAM_TB_SRAM_SIZE_BYTES
`define SRAM_TB_SRAM_SIZE_BYTES 32'h0003_8400 // 225 KiB
`endif
`ifndef SRAM_TB_PASS_OPCODE
`define SRAM_TB_PASS_OPCODE 32'hC0DE_CAFE
`endif
`ifndef SRAM_TB_FAIL_OPCODE
`define SRAM_TB_FAIL_OPCODE 32'h0BAD_BEEF
`endif

localparam [31:0] TB_TEXT_BASE = `SRAM_TB_TEXT_BASE;
localparam [31:0] TB_TEXT_LAST = `SRAM_TB_TEXT_LAST;
localparam [31:0] TB_DATA_BASE = `SRAM_TB_DATA_BASE;
localparam [31:0] TB_SRAM_BASE = `SRAM_TB_SRAM_BASE;
localparam [31:0] TB_SRAM_LAST = TB_SRAM_BASE + (`SRAM_TB_SRAM_SIZE_BYTES - 32'd4);
localparam [31:0] TB_PASS_OPCODE = `SRAM_TB_PASS_OPCODE;
localparam [31:0] TB_FAIL_OPCODE = `SRAM_TB_FAIL_OPCODE;

integer __sramtb_i;
integer __sramtb_uart_i;

// Default to the shortened SUITE_FULL unless another mode macro is supplied.
`ifndef SRAM_TB_ILLEGAL_FAIL
`ifndef SRAM_TB_NEG_OOR_HI_STORE
`ifndef SRAM_TB_NEG_OOR_LO_STORE
`ifndef SRAM_TB_NEG_OOR_HI_LOAD
`ifndef SRAM_TB_ISA_BASELINE
`ifndef SRAM_TB_STACK_EXERCISE
`ifndef SRAM_TB_RANDOM_STRESS
`ifndef SRAM_TB_DIVERSE_PASS
`ifndef SRAM_TB_SMOKE
`ifndef SRAM_TB_SUITE_FULL
`define SRAM_TB_SUITE_FULL
`endif
`endif
`endif
`endif
`endif
`endif
`endif
`endif
`endif
`endif

`ifndef SYNTHESIS
generate
  if (INIT_FILE == "") begin : g_inline_tb

`ifdef SRAM_TB_ILLEGAL_FAIL
  localparam [31:0] BOOT_PC = TB_TEXT_BASE;
  initial begin
    $display("SRAM_TB MODE = ILLEGAL_FAIL  TEXT=%h..%h DATA_BASE=%h SRAM=%h..%h", TB_TEXT_BASE, TB_TEXT_LAST, TB_DATA_BASE, TB_SRAM_BASE, TB_SRAM_LAST);
    #1;
    for (__sramtb_i = 0; __sramtb_i < 32; __sramtb_i = __sramtb_i + 1)
      mem[((BOOT_PC - TB_SRAM_BASE) >> 2) + __sramtb_i] = 32'h00000013;
    mem[(BOOT_PC + 32'h0000 - TB_SRAM_BASE) >> 2] = { TB_TEXT_BASE[31:12], 5'd10, 7'h37 };
    mem[(BOOT_PC + 32'h0004 - TB_SRAM_BASE) >> 2] = 32'h0DE00093;
    mem[(BOOT_PC + 32'h0008 - TB_SRAM_BASE) >> 2] = 32'h00152023;
    mem[(BOOT_PC + 32'h000C - TB_SRAM_BASE) >> 2] = 32'h0000006F;
  end

`elsif SRAM_TB_UART_SMOKE
  localparam [31:0] BOOT_PC = TB_TEXT_BASE;
  initial begin
    $display("SRAM_TB MODE = UART_SMOKE  UART_BASE=0x1000_0000");
    #1;
    for (__sramtb_uart_i = 0; __sramtb_uart_i < 32; __sramtb_uart_i = __sramtb_uart_i + 1)
      mem[((BOOT_PC - TB_SRAM_BASE) >> 2) + __sramtb_uart_i] = 32'h00000013;
    mem[(BOOT_PC + 32'h0000 - TB_SRAM_BASE) >> 2] = 32'h100002B7; // lui x5,0x1000_0000

    mem[(BOOT_PC + 32'h0004 - TB_SRAM_BASE) >> 2] = 32'h05000313; // addi x6,x0,'P'
    mem[(BOOT_PC + 32'h0008 - TB_SRAM_BASE) >> 2] = 32'h00628023; // sb x6,0(x5)
    mem[(BOOT_PC + 32'h000C - TB_SRAM_BASE) >> 2] = 32'h04100313; // addi x6,x0,'A'
    mem[(BOOT_PC + 32'h0010 - TB_SRAM_BASE) >> 2] = 32'h00628023; // sb x6,0(x5)
    mem[(BOOT_PC + 32'h0014 - TB_SRAM_BASE) >> 2] = 32'h05300313; // addi x6,x0,'S'
    mem[(BOOT_PC + 32'h0018 - TB_SRAM_BASE) >> 2] = 32'h00628023; // sb x6,0(x5)
    mem[(BOOT_PC + 32'h001C - TB_SRAM_BASE) >> 2] = 32'h05300313; // addi x6,x0,'S'
    mem[(BOOT_PC + 32'h0020 - TB_SRAM_BASE) >> 2] = 32'h00628023; // sb x6,0(x5)
    mem[(BOOT_PC + 32'h0024 - TB_SRAM_BASE) >> 2] = 32'h01100213; // addi x4,x0,17
    mem[(BOOT_PC + 32'h0028 - TB_SRAM_BASE) >> 2] = 32'h0000006F; // jal x0,0
  end

`elsif SRAM_TB_NEG_OOR_HI_STORE
  localparam [31:0] BOOT_PC = TB_TEXT_BASE;
  localparam [31:0] OOR_HI_STORE_ADDR = TB_SRAM_LAST + 32'h4;
  initial begin
    $display("SRAM_TB MODE = NEG_OOR_HI_STORE  SRAM_LAST=%h", TB_SRAM_LAST);
    #1;
    for (__sramtb_i = 0; __sramtb_i < 16; __sramtb_i = __sramtb_i + 1)
      mem[((BOOT_PC - TB_SRAM_BASE) >> 2) + __sramtb_i] = 32'h00000013;
    mem[(BOOT_PC + 32'h0000 - TB_SRAM_BASE) >> 2] = { OOR_HI_STORE_ADDR[31:12], 5'd10, 7'h37 };
    mem[(BOOT_PC + 32'h0004 - TB_SRAM_BASE) >> 2] = 32'h0CA00093;
    mem[(BOOT_PC + 32'h0008 - TB_SRAM_BASE) >> 2] = 32'h00152023;
    mem[(BOOT_PC + 32'h000C - TB_SRAM_BASE) >> 2] = 32'h0000006F;
  end

`elsif SRAM_TB_NEG_OOR_LO_STORE
  localparam [31:0] BOOT_PC = TB_TEXT_BASE;
  localparam [31:0] OOR_LO_STORE_ADDR = TB_SRAM_BASE - 32'h4;
  initial begin
    $display("SRAM_TB MODE = NEG_OOR_LO_STORE  SRAM_BASE=%h", TB_SRAM_BASE);
    #1;
    for (__sramtb_i = 0; __sramtb_i < 16; __sramtb_i = __sramtb_i + 1)
      mem[((BOOT_PC - TB_SRAM_BASE) >> 2) + __sramtb_i] = 32'h00000013;
    mem[(BOOT_PC + 32'h0000 - TB_SRAM_BASE) >> 2] = { OOR_LO_STORE_ADDR[31:12], 5'd10, 7'h37 };
    mem[(BOOT_PC + 32'h0004 - TB_SRAM_BASE) >> 2] = 32'h0B000093;
    mem[(BOOT_PC + 32'h0008 - TB_SRAM_BASE) >> 2] = 32'h00152023;
    mem[(BOOT_PC + 32'h000C - TB_SRAM_BASE) >> 2] = 32'h0000006F;
  end

`elsif SRAM_TB_NEG_OOR_HI_LOAD
  localparam [31:0] BOOT_PC = TB_TEXT_BASE;
  localparam [31:0] OOR_HI_LOAD_ADDR = TB_SRAM_LAST + 32'h4;
  initial begin
    $display("SRAM_TB MODE = NEG_OOR_HI_LOAD  SRAM_LAST=%h", TB_SRAM_LAST);
    #1;
    for (__sramtb_i = 0; __sramtb_i < 16; __sramtb_i = __sramtb_i + 1)
      mem[((BOOT_PC - TB_SRAM_BASE) >> 2) + __sramtb_i] = 32'h00000013;
    mem[(BOOT_PC + 32'h0000 - TB_SRAM_BASE) >> 2] = { OOR_HI_LOAD_ADDR[31:12], 5'd10, 7'h37 };
    mem[(BOOT_PC + 32'h0004 - TB_SRAM_BASE) >> 2] = 32'h00052183;
    mem[(BOOT_PC + 32'h0008 - TB_SRAM_BASE) >> 2] = 32'h0000006F;
  end

`elsif SRAM_TB_NEG_OOR_LO_LOAD
  localparam [31:0] BOOT_PC = TB_TEXT_BASE;
  localparam [31:0] OOR_LO_LOAD_ADDR = TB_SRAM_BASE - 32'h4;
  initial begin
    $display("SRAM_TB MODE = NEG_OOR_LO_LOAD  SRAM_BASE=%h", TB_SRAM_BASE);
    #1;
    for (__sramtb_i = 0; __sramtb_i < 16; __sramtb_i = __sramtb_i + 1)
      mem[((BOOT_PC - TB_SRAM_BASE) >> 2) + __sramtb_i] = 32'h00000013;
    mem[(BOOT_PC + 32'h0000 - TB_SRAM_BASE) >> 2] = { OOR_LO_LOAD_ADDR[31:12], 5'd10, 7'h37 };
    mem[(BOOT_PC + 32'h0004 - TB_SRAM_BASE) >> 2] = 32'h00052183; // lw x3, 0(x10)
    mem[(BOOT_PC + 32'h0008 - TB_SRAM_BASE) >> 2] = 32'h0000006F;
  end

`elsif SRAM_TB_MISALIGN_FAIL
  localparam [31:0] BOOT_PC = TB_TEXT_BASE;
  initial begin
    $display("SRAM_TB MODE = MISALIGN_FAIL  TEXT=%h..%h DATA_BASE=%h", TB_TEXT_BASE, TB_TEXT_LAST, TB_DATA_BASE);
    #1;
    for (__sramtb_i = 0; __sramtb_i < 16; __sramtb_i = __sramtb_i + 1)
      mem[((BOOT_PC - TB_SRAM_BASE) >> 2) + __sramtb_i] = 32'h00000013;

    mem[(BOOT_PC + 32'h0000 - TB_SRAM_BASE) >> 2] = { TB_DATA_BASE[31:12], 5'd10, 7'h37 }; // lui x10, DATA_BASE
    mem[(BOOT_PC + 32'h0004 - TB_SRAM_BASE) >> 2] = 32'h0CA00093; // addi x1, x0, 0x0CA
    mem[(BOOT_PC + 32'h0008 - TB_SRAM_BASE) >> 2] = 32'h00250513; // addi x10, x10, 2 (misaligned)
    mem[(BOOT_PC + 32'h000C - TB_SRAM_BASE) >> 2] = 32'h00152023; // sw x1, 0(x10) -> misaligned store
    mem[(BOOT_PC + 32'h0010 - TB_SRAM_BASE) >> 2] = 32'h0000006F;
  end

`elsif SRAM_TB_SMOKE
  localparam [31:0] BOOT_PC = TB_TEXT_BASE;
  initial begin
    $display("SRAM_TB MODE = SMOKE  TEXT=%h..%h DATA_BASE=%h", TB_TEXT_BASE, TB_TEXT_LAST, TB_DATA_BASE);
    #1;
    for (__sramtb_i = 0; __sramtb_i < 16; __sramtb_i = __sramtb_i + 1)
      mem[((BOOT_PC - TB_SRAM_BASE) >> 2) + __sramtb_i] = 32'h00000013;

    mem[(BOOT_PC + 32'h0000 - TB_SRAM_BASE) >> 2] = { TB_DATA_BASE[31:12], 5'd10, 7'h37 }; // lui x10, DATA_BASE
    mem[(BOOT_PC + 32'h0004 - TB_SRAM_BASE) >> 2] = 32'h01100293; // addi x5, x0, 0x11
    mem[(BOOT_PC + 32'h0008 - TB_SRAM_BASE) >> 2] = 32'h00552023; // sw x5, 0(x10)
    mem[(BOOT_PC + 32'h000C - TB_SRAM_BASE) >> 2] = 32'h00052203; // lw x4, 0(x10)
    mem[(BOOT_PC + 32'h0010 - TB_SRAM_BASE) >> 2] = TB_PASS_OPCODE;
  end

`elsif SRAM_TB_ISA_BASELINE
  localparam [31:0] BOOT_PC = TB_TEXT_BASE;
  initial begin
    $display("SRAM_TB MODE = ISA_BASELINE  TEXT=%h..%h DATA_BASE=%h", TB_TEXT_BASE, TB_TEXT_LAST, TB_DATA_BASE);
    #1;
    for (__sramtb_i = 0; __sramtb_i < 48; __sramtb_i = __sramtb_i + 1)
      mem[((BOOT_PC - TB_SRAM_BASE) >> 2) + __sramtb_i] = 32'h00000013;

    mem[(BOOT_PC + 32'h0000 - TB_SRAM_BASE) >> 2] = { TB_DATA_BASE[31:12], 5'd10, 7'h37 }; // lui x10, DATA_BASE
    mem[(BOOT_PC + 32'h0004 - TB_SRAM_BASE) >> 2] = 32'h00500093; // addi x1, x0, 5
    mem[(BOOT_PC + 32'h0008 - TB_SRAM_BASE) >> 2] = 32'hFFD00113; // addi x2, x0, -3
    mem[(BOOT_PC + 32'h000C - TB_SRAM_BASE) >> 2] = 32'h002081B3; // add x3, x1, x2
    mem[(BOOT_PC + 32'h0010 - TB_SRAM_BASE) >> 2] = 32'h40208233; // sub x4, x1, x2
    mem[(BOOT_PC + 32'h0014 - TB_SRAM_BASE) >> 2] = 32'h0041C2B3; // xor x5, x3, x4
    mem[(BOOT_PC + 32'h0018 - TB_SRAM_BASE) >> 2] = 32'h0041E333; // or  x6, x3, x4
    mem[(BOOT_PC + 32'h001C - TB_SRAM_BASE) >> 2] = 32'h0041F3B3; // and x7, x3, x4
    mem[(BOOT_PC + 32'h0020 - TB_SRAM_BASE) >> 2] = 32'h00019433; // sll x8, x3, x0
    mem[(BOOT_PC + 32'h0024 - TB_SRAM_BASE) >> 2] = 32'h001124B3; // slt x9, x2, x1
    mem[(BOOT_PC + 32'h0028 - TB_SRAM_BASE) >> 2] = 32'h00452023; // sw x4, 0(x10)
    mem[(BOOT_PC + 32'h002C - TB_SRAM_BASE) >> 2] = 32'h00052583; // lw x11, 0(x10)
    mem[(BOOT_PC + 32'h0030 - TB_SRAM_BASE) >> 2] = 32'h00458463; // beq x11, x4, +8
    mem[(BOOT_PC + 32'h0034 - TB_SRAM_BASE) >> 2] = 32'h0100006F; // jal x0, fail
    mem[(BOOT_PC + 32'h0038 - TB_SRAM_BASE) >> 2] = 32'h00958233; // add x4, x11, x9
    mem[(BOOT_PC + 32'h003C - TB_SRAM_BASE) >> 2] = 32'h00820213; // addi x4, x4, 8 -> 0x11
    mem[(BOOT_PC + 32'h0040 - TB_SRAM_BASE) >> 2] = TB_PASS_OPCODE;
    mem[(BOOT_PC + 32'h0044 - TB_SRAM_BASE) >> 2] = 32'hBAD00213; // fail: addi x4, x0, 0xBAD
    mem[(BOOT_PC + 32'h0048 - TB_SRAM_BASE) >> 2] = TB_FAIL_OPCODE;
  end

`elsif SRAM_TB_STACK_EXERCISE
  localparam [31:0] BOOT_PC = TB_TEXT_BASE;
  initial begin
    $display("SRAM_TB MODE = STACK_EXERCISE  TEXT=%h..%h DATA_BASE=%h STACK_BASE=%h", TB_TEXT_BASE, TB_TEXT_LAST, TB_DATA_BASE, STACK_BASE_ADDR);
    #1;
    for (__sramtb_i = 0; __sramtb_i < 64; __sramtb_i = __sramtb_i + 1)
      mem[((BOOT_PC - TB_SRAM_BASE) >> 2) + __sramtb_i] = 32'h00000013;

    mem[(BOOT_PC + 32'h0000 - TB_SRAM_BASE) >> 2] = { TB_DATA_BASE[31:12], 5'd10, 7'h37 }; // lui x10, DATA_BASE
    mem[(BOOT_PC + 32'h0004 - TB_SRAM_BASE) >> 2] = { STACK_BASE_ADDR[31:12], 5'd2, 7'h37 }; // lui x2, STACK_BASE
    mem[(BOOT_PC + 32'h0008 - TB_SRAM_BASE) >> 2] = 32'hFF010113; // addi x2, x2, -16
    mem[(BOOT_PC + 32'h000C - TB_SRAM_BASE) >> 2] = 32'h02100293; // addi x5, x0, 0x21
    mem[(BOOT_PC + 32'h0010 - TB_SRAM_BASE) >> 2] = 32'h00512023; // sw x5, 0(x2)
    mem[(BOOT_PC + 32'h0014 - TB_SRAM_BASE) >> 2] = 32'h00512223; // sw x5, 4(x2)
    mem[(BOOT_PC + 32'h0018 - TB_SRAM_BASE) >> 2] = 32'h010000EF; // jal x1, helper
    mem[(BOOT_PC + 32'h001C - TB_SRAM_BASE) >> 2] = 32'h01010113; // addi x2, x2, 16
    mem[(BOOT_PC + 32'h0020 - TB_SRAM_BASE) >> 2] = TB_PASS_OPCODE;

    mem[(BOOT_PC + 32'h0028 - TB_SRAM_BASE) >> 2] = 32'h00012303; // helper: lw x6, 0(x2)
    mem[(BOOT_PC + 32'h002C - TB_SRAM_BASE) >> 2] = 32'h00412383; // lw x7, 4(x2)
    mem[(BOOT_PC + 32'h0030 - TB_SRAM_BASE) >> 2] = 32'h00730433; // add x8, x6, x7
    mem[(BOOT_PC + 32'h0034 - TB_SRAM_BASE) >> 2] = 32'h00852023; // sw x8, 0(x10)
    mem[(BOOT_PC + 32'h0038 - TB_SRAM_BASE) >> 2] = 32'h00052483; // lw x9, 0(x10)
    mem[(BOOT_PC + 32'h003C - TB_SRAM_BASE) >> 2] = 32'h0014D493; // srli x9, x9, 1
    mem[(BOOT_PC + 32'h0040 - TB_SRAM_BASE) >> 2] = 32'hFF048213; // addi x4, x9, -0x10 -> 0x11
    mem[(BOOT_PC + 32'h0044 - TB_SRAM_BASE) >> 2] = 32'h00008067; // jalr x0, x1, 0
  end

`elsif SRAM_TB_RANDOM_STRESS
  localparam [31:0] BOOT_PC = TB_TEXT_BASE;
  initial begin
    $display("SRAM_TB MODE = RANDOM_STRESS  TEXT=%h..%h DATA_BASE=%h", TB_TEXT_BASE, TB_TEXT_LAST, TB_DATA_BASE);
    #1;
    for (__sramtb_i = 0; __sramtb_i < 64; __sramtb_i = __sramtb_i + 1)
      mem[((BOOT_PC - TB_SRAM_BASE) >> 2) + __sramtb_i] = 32'h00000013;

    mem[(BOOT_PC + 32'h0000 - TB_SRAM_BASE) >> 2] = { TB_DATA_BASE[31:12], 5'd10, 7'h37 }; // lui x10, DATA_BASE
    mem[(BOOT_PC + 32'h0004 - TB_SRAM_BASE) >> 2] = 32'h00100293; // addi x5, x0, 1
    mem[(BOOT_PC + 32'h0008 - TB_SRAM_BASE) >> 2] = 32'h00800313; // addi x6, x0, 8
    mem[(BOOT_PC + 32'h000C - TB_SRAM_BASE) >> 2] = 32'h00552023; // sw x5, 0(x10)
    mem[(BOOT_PC + 32'h0010 - TB_SRAM_BASE) >> 2] = 32'h005282B3; // add x5, x5, x5
    mem[(BOOT_PC + 32'h0014 - TB_SRAM_BASE) >> 2] = 32'h1D52C293; // xori x5, x5, 0x1D5
    mem[(BOOT_PC + 32'h0018 - TB_SRAM_BASE) >> 2] = 32'h00450513; // addi x10, x10, 4
    mem[(BOOT_PC + 32'h001C - TB_SRAM_BASE) >> 2] = 32'hFFF30313; // addi x6, x6, -1
    mem[(BOOT_PC + 32'h0020 - TB_SRAM_BASE) >> 2] = 32'hFE0316E3; // bne x6, x0, loop
    mem[(BOOT_PC + 32'h0024 - TB_SRAM_BASE) >> 2] = 32'h00028213; // addi x4, x5, 0
    mem[(BOOT_PC + 32'h0028 - TB_SRAM_BASE) >> 2] = 32'h03F27213; // andi x4, x4, 0x3F
    mem[(BOOT_PC + 32'h002C - TB_SRAM_BASE) >> 2] = 32'h01020213; // addi x4, x4, 0x10
    mem[(BOOT_PC + 32'h0030 - TB_SRAM_BASE) >> 2] = 32'hFCE20213; // addi x4, x4, -0x32 -> 0x11
    mem[(BOOT_PC + 32'h0034 - TB_SRAM_BASE) >> 2] = TB_PASS_OPCODE;
  end

`elsif SRAM_TB_SUITE_FULL
  localparam [31:0] BOOT_PC = TB_TEXT_BASE;
`ifdef SRAM_TB_SUITE_SHORT
  localparam integer SUITE_SHORT_WORDS = 48;
  initial begin
    $display("SRAM_TB MODE = SUITE_FULL (short) TEXT=%h..%h DATA_BASE=%h STACK_BASE=%h SRAM=%h..%h",
             TB_TEXT_BASE, TB_TEXT_LAST, TB_DATA_BASE, STACK_BASE_ADDR, TB_SRAM_BASE, TB_SRAM_LAST);
    #1;
    for (__sramtb_i = 0; __sramtb_i < SUITE_SHORT_WORDS; __sramtb_i = __sramtb_i + 1)
      mem[((BOOT_PC - TB_SRAM_BASE) >> 2) + __sramtb_i] = 32'h00000013;

    // 0x0000: Prepare pointers and seed values in DATA.
    mem[(BOOT_PC + 32'h0000 - TB_SRAM_BASE) >> 2] = { TB_DATA_BASE[31:12], 5'd10, 7'h37 };
    mem[(BOOT_PC + 32'h0004 - TB_SRAM_BASE) >> 2] = 32'h00500093; // addi x1, x0, 5
    mem[(BOOT_PC + 32'h0008 - TB_SRAM_BASE) >> 2] = 32'h00C00113; // addi x2, x0, 12
    mem[(BOOT_PC + 32'h000C - TB_SRAM_BASE) >> 2] = 32'h00252023; // sw x2, 0(x10)
    mem[(BOOT_PC + 32'h0010 - TB_SRAM_BASE) >> 2] = 32'h00450593; // addi x11, x10, 4
    mem[(BOOT_PC + 32'h0014 - TB_SRAM_BASE) >> 2] = 32'h0015A023; // sw x1, 0(x11)

    // 0x0018: Read back and accumulate to x6 = 0x11.
    mem[(BOOT_PC + 32'h0018 - TB_SRAM_BASE) >> 2] = 32'h00052183; // lw x3, 0(x10)
    mem[(BOOT_PC + 32'h001C - TB_SRAM_BASE) >> 2] = 32'h0005A283; // lw x5, 0(x11)
    mem[(BOOT_PC + 32'h0020 - TB_SRAM_BASE) >> 2] = 32'h00518333; // add x6, x3, x5

    // 0x0024: Touch STACK region and form the pass signature.
    mem[(BOOT_PC + 32'h0024 - TB_SRAM_BASE) >> 2] = { STACK_BASE_ADDR[31:12], 5'd12, 7'h37 }; // lui x12, STACK
    mem[(BOOT_PC + 32'h0028 - TB_SRAM_BASE) >> 2] = 32'h00662023; // sw x6, 0(x12)
    mem[(BOOT_PC + 32'h002C - TB_SRAM_BASE) >> 2] = 32'h00062383; // lw x7, 0(x12)
    mem[(BOOT_PC + 32'h0030 - TB_SRAM_BASE) >> 2] = 32'h00038213; // addi x4, x7, 0

    // 0x0034: Halt.
    mem[(BOOT_PC + 32'h0034 - TB_SRAM_BASE) >> 2] = TB_PASS_OPCODE;
  end
`else
  initial begin
    $display("SRAM_TB MODE = SUITE_FULL  TEXT=%h..%h DATA_BASE=%h STACK_BASE=%h SRAM=%h..%h",
             TB_TEXT_BASE, TB_TEXT_LAST, TB_DATA_BASE, STACK_BASE_ADDR, TB_SRAM_BASE, TB_SRAM_LAST);
    #1;
    for (__sramtb_i = 0; __sramtb_i < 128; __sramtb_i = __sramtb_i + 1)
      mem[((BOOT_PC - TB_SRAM_BASE) >> 2) + __sramtb_i] = 32'h00000013;

    mem[(BOOT_PC + 32'h0000 - TB_SRAM_BASE) >> 2] = { TB_DATA_BASE[31:12], 5'd10, 7'h37 };
    mem[(BOOT_PC + 32'h0004 - TB_SRAM_BASE) >> 2] = 32'h00000293;
    mem[(BOOT_PC + 32'h0008 - TB_SRAM_BASE) >> 2] = 32'h00000313;
    mem[(BOOT_PC + 32'h000C - TB_SRAM_BASE) >> 2] = 32'h00800393;
    mem[(BOOT_PC + 32'h0010 - TB_SRAM_BASE) >> 2] = 32'h00231613;
    mem[(BOOT_PC + 32'h0014 - TB_SRAM_BASE) >> 2] = 32'h00C505B3;
    mem[(BOOT_PC + 32'h0018 - TB_SRAM_BASE) >> 2] = 32'h01030693;
    mem[(BOOT_PC + 32'h001C - TB_SRAM_BASE) >> 2] = 32'h00D5A023;
    mem[(BOOT_PC + 32'h0020 - TB_SRAM_BASE) >> 2] = 32'h0005A703;
    mem[(BOOT_PC + 32'h0024 - TB_SRAM_BASE) >> 2] = 32'h00E282B3;
    mem[(BOOT_PC + 32'h0028 - TB_SRAM_BASE) >> 2] = 32'h00130313;
    mem[(BOOT_PC + 32'h002C - TB_SRAM_BASE) >> 2] = 32'hFE7312E3;
    mem[(BOOT_PC + 32'h0030 - TB_SRAM_BASE) >> 2] = 32'h05500793;
    mem[(BOOT_PC + 32'h0034 - TB_SRAM_BASE) >> 2] = 32'h01C00613;
    mem[(BOOT_PC + 32'h0038 - TB_SRAM_BASE) >> 2] = 32'h00C505B3;
    mem[(BOOT_PC + 32'h003C - TB_SRAM_BASE) >> 2] = 32'h00F5A023;
    mem[(BOOT_PC + 32'h0040 - TB_SRAM_BASE) >> 2] = 32'h0AA00813;
    mem[(BOOT_PC + 32'h0044 - TB_SRAM_BASE) >> 2] = 32'h00460613;
    mem[(BOOT_PC + 32'h0048 - TB_SRAM_BASE) >> 2] = 32'h00C505B3;
    mem[(BOOT_PC + 32'h004C - TB_SRAM_BASE) >> 2] = 32'h0105A023;
    mem[(BOOT_PC + 32'h0050 - TB_SRAM_BASE) >> 2] = 32'hFFC5A883;
    mem[(BOOT_PC + 32'h0054 - TB_SRAM_BASE) >> 2] = 32'h02100913;
    mem[(BOOT_PC + 32'h0058 - TB_SRAM_BASE) >> 2] = 32'h01252023;
    mem[(BOOT_PC + 32'h005C - TB_SRAM_BASE) >> 2] = 32'h00052983;
    mem[(BOOT_PC + 32'h0060 - TB_SRAM_BASE) >> 2] = 32'h00000A13;
    mem[(BOOT_PC + 32'h0064 - TB_SRAM_BASE) >> 2] = 32'h00400A93;
    mem[(BOOT_PC + 32'h0068 - TB_SRAM_BASE) >> 2] = 32'h003A1B13;
    mem[(BOOT_PC + 32'h006C - TB_SRAM_BASE) >> 2] = 32'h016505B3;
    mem[(BOOT_PC + 32'h0070 - TB_SRAM_BASE) >> 2] = 32'h004B1613;
    mem[(BOOT_PC + 32'h0074 - TB_SRAM_BASE) >> 2] = 32'h00C50BB3;
    mem[(BOOT_PC + 32'h0078 - TB_SRAM_BASE) >> 2] = 32'h06400C13;
    mem[(BOOT_PC + 32'h007C - TB_SRAM_BASE) >> 2] = 32'h0C800C93;
    mem[(BOOT_PC + 32'h0080 - TB_SRAM_BASE) >> 2] = 32'h0185A023;
    mem[(BOOT_PC + 32'h0084 - TB_SRAM_BASE) >> 2] = 32'h019BA023;
    mem[(BOOT_PC + 32'h0088 - TB_SRAM_BASE) >> 2] = 32'h0005AD03;
    mem[(BOOT_PC + 32'h008C - TB_SRAM_BASE) >> 2] = 32'h000BAD83;
    mem[(BOOT_PC + 32'h0090 - TB_SRAM_BASE) >> 2] = 32'h01A282B3;
    mem[(BOOT_PC + 32'h0094 - TB_SRAM_BASE) >> 2] = 32'h01B282B3;
    mem[(BOOT_PC + 32'h0098 - TB_SRAM_BASE) >> 2] = 32'h001A0A13;
    mem[(BOOT_PC + 32'h009C - TB_SRAM_BASE) >> 2] = 32'hFEAA90E3;
    mem[(BOOT_PC + 32'h00A0 - TB_SRAM_BASE) >> 2] = 32'h00500093;
    mem[(BOOT_PC + 32'h00A4 - TB_SRAM_BASE) >> 2] = 32'h00708113;
    mem[(BOOT_PC + 32'h00A8 - TB_SRAM_BASE) >> 2] = 32'h00110233;
    mem[(BOOT_PC + 32'h00AC - TB_SRAM_BASE) >> 2] = TB_PASS_OPCODE;
  end
`endif // SRAM_TB_SUITE_SHORT

`elsif SRAM_TB_DIVERSE_PASS
  localparam [31:0] BOOT_PC = TB_TEXT_BASE;
`ifdef SRAM_TB_DIVERSE_SHORT
  // Shorter diverse program (reuse SUITE sequence) for quicker smoke runs
  localparam integer DIVERSE_SHORT_WORDS = 48;
  initial begin
    $display("SRAM_TB MODE = DIVERSE_PASS_SHORT  TEXT=%h..%h DATA_BASE=%h STACK_BASE=%h SRAM=%h..%h",
             TB_TEXT_BASE, TB_TEXT_LAST, TB_DATA_BASE, STACK_BASE_ADDR, TB_SRAM_BASE, TB_SRAM_LAST);
    #1;
    for (__sramtb_i = 0; __sramtb_i < DIVERSE_SHORT_WORDS; __sramtb_i = __sramtb_i + 1)
      mem[((BOOT_PC - TB_SRAM_BASE) >> 2) + __sramtb_i] = 32'h00000013;

    mem[(BOOT_PC + 32'h0000 - TB_SRAM_BASE) >> 2] = { TB_DATA_BASE[31:12], 5'd10, 7'h37 };
    mem[(BOOT_PC + 32'h0004 - TB_SRAM_BASE) >> 2] = 32'h00500093;
    mem[(BOOT_PC + 32'h0008 - TB_SRAM_BASE) >> 2] = 32'h00C00113;
    mem[(BOOT_PC + 32'h000C - TB_SRAM_BASE) >> 2] = 32'h00252023;
    mem[(BOOT_PC + 32'h0010 - TB_SRAM_BASE) >> 2] = 32'h00450593;
    mem[(BOOT_PC + 32'h0014 - TB_SRAM_BASE) >> 2] = 32'h0015A023;
    mem[(BOOT_PC + 32'h0018 - TB_SRAM_BASE) >> 2] = 32'h00052183;
    mem[(BOOT_PC + 32'h001C - TB_SRAM_BASE) >> 2] = 32'h0005A283;
    mem[(BOOT_PC + 32'h0020 - TB_SRAM_BASE) >> 2] = 32'h00518333;
    mem[(BOOT_PC + 32'h0024 - TB_SRAM_BASE) >> 2] = { STACK_BASE_ADDR[31:12], 5'd12, 7'h37 };
    mem[(BOOT_PC + 32'h0028 - TB_SRAM_BASE) >> 2] = 32'h00662023;
    mem[(BOOT_PC + 32'h002C - TB_SRAM_BASE) >> 2] = 32'h00062383;
    mem[(BOOT_PC + 32'h0030 - TB_SRAM_BASE) >> 2] = 32'h00038213;
    mem[(BOOT_PC + 32'h0034 - TB_SRAM_BASE) >> 2] = TB_PASS_OPCODE;
  end
`else
  initial begin
    $display("SRAM_TB MODE = DIVERSE_PASS  TEXT=%h..%h DATA_BASE=%h SRAM=%h..%h", TB_TEXT_BASE, TB_TEXT_LAST, TB_DATA_BASE, TB_SRAM_BASE, TB_SRAM_LAST);
    #1;
    for (__sramtb_i = 0; __sramtb_i < 128; __sramtb_i = __sramtb_i + 1)
      mem[((BOOT_PC - TB_SRAM_BASE) >> 2) + __sramtb_i] = 32'h00000013;
    mem[(BOOT_PC + 32'h0000 - TB_SRAM_BASE) >> 2] = { TB_DATA_BASE[31:12], 5'd10, 7'h37 };
    mem[(BOOT_PC + 32'h0004 - TB_SRAM_BASE) >> 2] = 32'h00000293;
    mem[(BOOT_PC + 32'h0008 - TB_SRAM_BASE) >> 2] = 32'h00000313;
    mem[(BOOT_PC + 32'h000C - TB_SRAM_BASE) >> 2] = 32'h00800393;
    mem[(BOOT_PC + 32'h0010 - TB_SRAM_BASE) >> 2] = 32'h00231613;
    mem[(BOOT_PC + 32'h0014 - TB_SRAM_BASE) >> 2] = 32'h00C505B3;
    mem[(BOOT_PC + 32'h0018 - TB_SRAM_BASE) >> 2] = 32'h01030693;
    mem[(BOOT_PC + 32'h001C - TB_SRAM_BASE) >> 2] = 32'h00D5A023;
    mem[(BOOT_PC + 32'h0020 - TB_SRAM_BASE) >> 2] = 32'h0005A703;
    mem[(BOOT_PC + 32'h0024 - TB_SRAM_BASE) >> 2] = 32'h00E282B3;
    mem[(BOOT_PC + 32'h0028 - TB_SRAM_BASE) >> 2] = 32'h00130313;
    mem[(BOOT_PC + 32'h002C - TB_SRAM_BASE) >> 2] = 32'hFE7312E3;
    mem[(BOOT_PC + 32'h0030 - TB_SRAM_BASE) >> 2] = 32'h05500793;
    mem[(BOOT_PC + 32'h0034 - TB_SRAM_BASE) >> 2] = 32'h01C00613;
    mem[(BOOT_PC + 32'h0038 - TB_SRAM_BASE) >> 2] = 32'h00C505B3;
    mem[(BOOT_PC + 32'h003C - TB_SRAM_BASE) >> 2] = 32'h00F5A023;
    mem[(BOOT_PC + 32'h0040 - TB_SRAM_BASE) >> 2] = 32'h0AA00813;
    mem[(BOOT_PC + 32'h0044 - TB_SRAM_BASE) >> 2] = 32'h00460613;
    mem[(BOOT_PC + 32'h0048 - TB_SRAM_BASE) >> 2] = 32'h00C505B3;
    mem[(BOOT_PC + 32'h004C - TB_SRAM_BASE) >> 2] = 32'h0105A023;
    mem[(BOOT_PC + 32'h0050 - TB_SRAM_BASE) >> 2] = 32'hFFC5A883;
    mem[(BOOT_PC + 32'h0054 - TB_SRAM_BASE) >> 2] = 32'h02100913;
    mem[(BOOT_PC + 32'h0058 - TB_SRAM_BASE) >> 2] = 32'h01252023;
    mem[(BOOT_PC + 32'h005C - TB_SRAM_BASE) >> 2] = 32'h00052983;
    mem[(BOOT_PC + 32'h0060 - TB_SRAM_BASE) >> 2] = 32'h00000A13;
    mem[(BOOT_PC + 32'h0064 - TB_SRAM_BASE) >> 2] = 32'h00400A93;
    mem[(BOOT_PC + 32'h0068 - TB_SRAM_BASE) >> 2] = 32'h003A1B13;
    mem[(BOOT_PC + 32'h006C - TB_SRAM_BASE) >> 2] = 32'h016505B3;
    mem[(BOOT_PC + 32'h0070 - TB_SRAM_BASE) >> 2] = 32'h004B1613;
    mem[(BOOT_PC + 32'h0074 - TB_SRAM_BASE) >> 2] = 32'h00C50BB3;
    mem[(BOOT_PC + 32'h0078 - TB_SRAM_BASE) >> 2] = 32'h06400C13;
    mem[(BOOT_PC + 32'h007C - TB_SRAM_BASE) >> 2] = 32'h0C800C93;
    mem[(BOOT_PC + 32'h0080 - TB_SRAM_BASE) >> 2] = 32'h0185A023;
    mem[(BOOT_PC + 32'h0084 - TB_SRAM_BASE) >> 2] = 32'h019BA023;
    mem[(BOOT_PC + 32'h0088 - TB_SRAM_BASE) >> 2] = 32'h0005AD03;
    mem[(BOOT_PC + 32'h008C - TB_SRAM_BASE) >> 2] = 32'h000BAD83;
    mem[(BOOT_PC + 32'h0090 - TB_SRAM_BASE) >> 2] = 32'h01A282B3;
    mem[(BOOT_PC + 32'h0094 - TB_SRAM_BASE) >> 2] = 32'h01B282B3;
    mem[(BOOT_PC + 32'h0098 - TB_SRAM_BASE) >> 2] = 32'h001A0A13;
    mem[(BOOT_PC + 32'h009C - TB_SRAM_BASE) >> 2] = 32'hFEAA90E3;
    mem[(BOOT_PC + 32'h00A0 - TB_SRAM_BASE) >> 2] = 32'h00500093;
    mem[(BOOT_PC + 32'h00A4 - TB_SRAM_BASE) >> 2] = 32'h00708113;
    mem[(BOOT_PC + 32'h00A8 - TB_SRAM_BASE) >> 2] = 32'h00110233;
    mem[(BOOT_PC + 32'h00AC - TB_SRAM_BASE) >> 2] = TB_PASS_OPCODE;
  end
`endif
`else
  initial begin
    $display("SRAM_TB MODE = UNKNOWN (no valid mode defined)");
    $fatal(1);
  end
`endif

  end else begin : g_initfile_override
    initial begin
      $display("%t [SRAM] INFO: INIT_FILE (%s) set -> skipping inline TB suite.", $time, INIT_FILE);
    end
  end
endgenerate
`endif // !SYNTHESIS




  localparam [31:0] RV32_NOP = 32'h0000_0013;

  // ---------------------------------------------------------------------------
  // ICACHE combinational read (word-aligned)
  wire [31:0] imem_addr_aligned = {imem_addr_i[31:2], 2'b00};
  wire        imem_in_sram      = (imem_addr_aligned >= SRAM_BASE_ADDR) && (imem_addr_aligned <= SRAM_LAST_ADDR_EFF);
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

`ifndef SYNTHESIS
  always @(posedge clk) begin
    if (imem_in_sram && imem_rdata_q == TB_PASS_OPCODE) begin
      $display("%t [SRAM] TEST PASS opcode fetched @PC=0x%08h", $time, imem_addr_aligned);
      $finish;
    end else if (imem_in_sram && imem_rdata_q == TB_FAIL_OPCODE) begin
      $display("%t [SRAM] TEST FAIL opcode fetched @PC=0x%08h", $time, imem_addr_aligned);
      $fatal(1);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // DCACHE line interface
  wire [31:0] line_base_addr = {dmem_addr_i[31:LINE_OFF_BITS], {LINE_OFF_BITS{1'b0}}};
  wire [31:0] line_last_addr = line_base_addr + (LINE_BYTES - 1);
  wire        line_in_sram   = (line_base_addr >= SRAM_BASE_ADDR) && (line_last_addr <= SRAM_LAST_ADDR_EFF);

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
`ifndef SYNTHESIS
            $display("%t [SRAM] WARN: Write outside SRAM range at 0x%08h ignored.", $time, line_base_addr);
`endif
          end else if (line_hits_text) begin
`ifndef SYNTHESIS
            $display("%t [SRAM] ERROR: Write to read-only TEXT region (addr 0x%08h) ignored.", $time, line_base_addr);
`endif
          end else if (!(line_hits_data || line_hits_stack)) begin
`ifndef SYNTHESIS
            $display("%t [SRAM] WARN: Write to unmapped region at 0x%08h ignored.", $time, line_base_addr);
`endif
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
`ifndef SYNTHESIS
          if (!line_in_sram)
            $display("%t [SRAM] WARN: Read outside SRAM range at 0x%08h (returning zeros).", $time, line_base_addr);
`endif
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
    if (INIT_FILE != "") begin
`ifndef SYNTHESIS
      $display("%t [SRAM] INFO: Loading init file %s", $time, INIT_FILE);
`endif
      $readmemh(INIT_FILE, mem);
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (TEXT_BASE_ADDR     != SRAM_BASE_ADDR ||
        STACK_LAST_ADDR    != SRAM_LAST_ADDR_EFF ||
        TEXT_LAST_ADDR + 1 != DATA_BASE_ADDR ||
        DATA_LAST_ADDR + 1 != STACK_BASE_ADDR) begin
      $display("%t [SRAM] ERROR: Region partition does not fully cover SRAM window.", $time);
      $fatal(1);
    end
  end
`endif
endmodule
