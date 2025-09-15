`timescale 1ns/1ps

module rv32i_core_tb;
  // Clock/Reset
  reg clk;
  reg rst_n; // active-low

  // IMEM interface
  wire [31:0] imem_addr;
  reg  [31:0] imem_instr;

  // DMEM interface (stubbed in this TB)
  wire        dmem_req;
  wire        dmem_we;
  wire [31:0] dmem_addr;
  wire [31:0] dmem_wdata;
  wire [3:0]  dmem_wstrb;
  reg         dmem_ready;
  reg         dmem_rvalid;
  reg  [31:0] dmem_rdata;

  // WB observation
  wire        wb_we;
  wire [4:0]  wb_rd;
  wire [31:0] wb_wdata;

  // Instantiate DUT
  rv32i_core_top dut (
    .clk            (clk),
    .rst_n          (rst_n),
    .imem_addr_o    (imem_addr),
    .imem_instr_i   (imem_instr),
    .dmem_req_o     (dmem_req),
    .dmem_we_o      (dmem_we),
    .dmem_addr_o    (dmem_addr),
    .dmem_wdata_o   (dmem_wdata),
    .dmem_wstrb_o   (dmem_wstrb),
    .dmem_ready_i   (dmem_ready),
    .dmem_rvalid_i  (dmem_rvalid),
    .dmem_rdata_i   (dmem_rdata),
    .wb_we_o        (wb_we),
    .wb_rd_o        (wb_rd),
    .wb_wdata_o     (wb_wdata)
  );

  // Clock generation
  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk; // 100MHz
  end

  // Reset sequence (active-low)
  initial begin
    rst_n = 1'b0;
    dmem_ready  = 1'b1;    // DMEM always ready (we don't use it here)
    dmem_rvalid = 1'b0;
    dmem_rdata  = 32'b0;
    repeat (8) @(posedge clk);
    rst_n = 1'b1;
  end

  // Simple IMEM (ROM) mapped at 0x1000_0000, word addressing
  localparam [31:0] ROM_BASE = 32'h1000_0000;

  // Program (ALU focus: sub/slli/xor, redirect flush; no LOAD/STORE):
  // 0: addi x1, x0, 5       => x1 = 5                 (0x0050_0093)
  // 1: add  x2, x1, x1      => x2 = 10 (ALU→ALU fwd)  (0x0010_8133)
  // 2: sub  x3, x2, x1      => x3 = 5                  (0x4011_01B3)
  // 3: slli x4, x3, 1       => x4 = 10                 (0x0011_9213)
  // 4: jal  x0, +8           => redirect, skip next     (0x0080_006F)
  // 5: addi x5, x0, 1       => will be skipped         (0x0010_0293)
  // 6: xor  x5, x4, x1      => x5 = 10 ^ 5 = 15        (0x0012_42B3)
  // 7: jal  x0, 0           => loop (halt)             (0x0000_006F)
  function [31:0] rom_rd;
    input [31:0] addr;
    reg   [31:0] idx;
    begin
      if (addr < ROM_BASE) begin
        rom_rd = 32'h0000_0013; // NOP
      end else begin
        idx = (addr - ROM_BASE) >> 2;
        case (idx)
          32'd0: rom_rd = 32'h0050_0093; // addi x1, x0, 5
          32'd1: rom_rd = 32'h0010_8133; // add  x2, x1, x1
          32'd2: rom_rd = 32'h4011_01B3; // sub  x3, x2, x1
          32'd3: rom_rd = 32'h0011_9213; // slli x4, x3, 1
          32'd4: rom_rd = 32'h0080_006F; // jal  x0, +8
          32'd5: rom_rd = 32'h0010_0293; // addi x5, x0, 1 (skipped)
          32'd6: rom_rd = 32'h0012_42B3; // xor  x5, x4, x1
          32'd7: rom_rd = 32'h0000_006F; // jal  x0, 0 (halt)
          default: rom_rd = 32'h0000_0013; // NOP
        endcase
      end
    end
  endfunction

  always @(*) begin
    imem_instr = rom_rd(imem_addr);
  end

  // Commit monitor and simple checks
  integer commit_cnt;
  initial commit_cnt = 0;

  // Expected sequence of (rd, data)
  reg [4:0]  exp_rd   [0:4];
  reg [31:0] exp_data [0:4];
  initial begin
    exp_rd[0]   = 5'd1; exp_data[0] = 32'd5;   // addi x1,5
    exp_rd[1]   = 5'd2; exp_data[1] = 32'd10;  // add x2,x1,x1
    exp_rd[2]   = 5'd3; exp_data[2] = 32'd5;   // sub x3,x2,x1
    exp_rd[3]   = 5'd4; exp_data[3] = 32'd10;  // slli x4,1
    exp_rd[4]   = 5'd5; exp_data[4] = 32'd15;  // xor x5,x4,x1
  end

  always @(posedge clk) begin
    if (rst_n && wb_we) begin
      $display("[WB] rd=%0d data=0x%08x (t=%0t)", wb_rd, wb_wdata, $time);
      if (commit_cnt < 5) begin
        if (wb_rd   !== exp_rd[commit_cnt]) begin
          $error("WB rd mismatch at #%0d: got %0d, exp %0d", commit_cnt, wb_rd, exp_rd[commit_cnt]);
        end
        if (wb_wdata !== exp_data[commit_cnt]) begin
          $error("WB data mismatch at #%0d: got 0x%08x, exp 0x%08x", commit_cnt, wb_wdata, exp_data[commit_cnt]);
        end
      end
      commit_cnt <= commit_cnt + 1;
      if (commit_cnt == 5) begin
        $display("All expected commits observed. Test PASS.");
        #20 $finish;
      end
    end
  end

  // Waveform dump (optional; enable if your simulator supports it)
  initial begin
    $dumpfile("rv32i_core_tb.vcd");
    $dumpvars(0, rv32i_core_tb);
  end

  // ---------------- DMEM stub with 1-cycle read latency ----------------
  // 1KB (256 words) simple memory, word-addressed by [9:2]
  reg [31:0] dmem_array [0:255];
  reg [31:0] write_word;
  integer i;
  initial begin
    for (i = 0; i < 256; i = i + 1) dmem_array[i] = 32'b0;
  end

  // always-ready for writes/reads
  always @(*) begin
    dmem_ready = 1'b1;
  end

  // write path with byte strobes
  always @(posedge clk) begin
    if (rst_n && dmem_req && dmem_we) begin
      write_word = dmem_array[dmem_addr[9:2]];
      if (dmem_wstrb[0]) write_word[7:0]   = dmem_wdata[7:0];
      if (dmem_wstrb[1]) write_word[15:8]  = dmem_wdata[15:8];
      if (dmem_wstrb[2]) write_word[23:16] = dmem_wdata[23:16];
      if (dmem_wstrb[3]) write_word[31:24] = dmem_wdata[31:24];
      dmem_array[dmem_addr[9:2]] <= write_word;
    end
  end

  // read path: capture request, respond next cycle (1-cycle latency)
  reg rd_pending;
  reg [31:0] rd_addr_q;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_pending  <= 1'b0;
      dmem_rvalid <= 1'b0;
      rd_addr_q   <= 32'b0;
      dmem_rdata  <= 32'b0;
    end else begin
      dmem_rvalid <= 1'b0; // default low, pulse for 1 cycle on response
      if (dmem_req && !dmem_we) begin
        rd_pending <= 1'b1;
        rd_addr_q  <= dmem_addr;
      end
      if (rd_pending) begin
        dmem_rdata  <= dmem_array[rd_addr_q[9:2]];
        dmem_rvalid <= 1'b1;
        rd_pending  <= 1'b0;
      end
    end
  end

endmodule
