`timescale 1ns/1ps
// icache_pipeline_tb.v
// Simple TB to verify I$ + pipeline integration.

module icache_pipeline_tb;
  localparam ADDR_WIDTH = 32;
  localparam L2_DATA_W  = 64;
  localparam MEM_WORDS  = 256;
  localparam USE_MIG    = 1;
  localparam [31:0] RESET_PC = USE_MIG ? 32'h8000_0000 : 32'h0000_0000;

  reg                   clk;
  reg                   rst_n;
  reg                   uart_rx;

  // DDR2 MIG (USE_MIG=1 uses sim model below)
  wire [15:0]           ddr2_dq;
  wire [1:0]            ddr2_dqs_n;
  wire [1:0]            ddr2_dqs_p;
  wire [13:0]           ddr2_addr;
  wire [2:0]            ddr2_ba;
  wire                  ddr2_ras_n;
  wire                  ddr2_cas_n;
  wire                  ddr2_we_n;
  wire [0:0]            ddr2_ck_p;
  wire [0:0]            ddr2_ck_n;
  wire [0:0]            ddr2_cke;
  wire [0:0]            ddr2_cs_n;
  wire [1:0]            ddr2_dm;
  wire [0:0]            ddr2_odt;
  wire                  init_calib_complete;
  wire                  sys_clk_p;
  wire                  sys_clk_n;
  wire                  clk_ref_i;

  // I$ L2 interface
  wire                  l2_req_valid;
  reg                   l2_req_ready;
  wire [ADDR_WIDTH-1:0] l2_req_addr;
  wire [1:0]            l2_req_cmd;
  wire [2:0]            l2_req_size;
  wire [7:0]            l2_req_len;

  reg                   l2_rsp_valid;
  wire                  l2_rsp_ready;
  reg  [L2_DATA_W-1:0]  l2_rsp_data;
  reg                   l2_rsp_last;
  reg                   l2_rsp_err;

  // D$ L2 interface
  wire                  d_l2_req_valid;
  wire                  d_l2_req_ready;
  wire [ADDR_WIDTH-1:0] d_l2_req_addr;
  wire [1:0]            d_l2_req_cmd;
  wire [2:0]            d_l2_req_size;
  wire [7:0]            d_l2_req_len;
  wire [L2_DATA_W-1:0]  d_l2_req_wdata;
  wire [(L2_DATA_W/8)-1:0] d_l2_req_wstrb;

  reg                   d_l2_rsp_valid;
  wire                  d_l2_rsp_ready;
  reg  [L2_DATA_W-1:0]  d_l2_rsp_rdata;
  reg                   d_l2_rsp_last;
  reg                   d_l2_rsp_err;

  // WB observability
  wire                  wb_we;
  wire [4:0]            wb_rd;
  wire [31:0]           wb_wdata;
  wire                  ifetch_err;
  wire                  boot_done;

  // DUT
  icache_pipeline_top #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .L2_DATA_W  (L2_DATA_W),
    .USE_MIG    (USE_MIG),
    .RESET_PC   (RESET_PC)
  ) dut (
    .clk          (clk),
    .rst_n        (rst_n),
    .uart_rx_i    (uart_rx),
    .ddr2_dq      (ddr2_dq),
    .ddr2_dqs_n   (ddr2_dqs_n),
    .ddr2_dqs_p   (ddr2_dqs_p),
    .ddr2_addr    (ddr2_addr),
    .ddr2_ba      (ddr2_ba),
    .ddr2_ras_n   (ddr2_ras_n),
    .ddr2_cas_n   (ddr2_cas_n),
    .ddr2_we_n    (ddr2_we_n),
    .ddr2_ck_p    (ddr2_ck_p),
    .ddr2_ck_n    (ddr2_ck_n),
    .ddr2_cke     (ddr2_cke),
    .ddr2_cs_n    (ddr2_cs_n),
    .ddr2_dm      (ddr2_dm),
    .ddr2_odt     (ddr2_odt),
    .sys_clk_p    (sys_clk_p),
    .sys_clk_n    (sys_clk_n),
    .clk_ref_i    (clk_ref_i),
    .init_calib_complete (init_calib_complete),
    .l2_req_valid (l2_req_valid),
    .l2_req_ready (l2_req_ready),
    .l2_req_addr  (l2_req_addr),
    .l2_req_cmd   (l2_req_cmd),
    .l2_req_size  (l2_req_size),
    .l2_req_len   (l2_req_len),
    .l2_rsp_valid (l2_rsp_valid),
    .l2_rsp_ready (l2_rsp_ready),
    .l2_rsp_data  (l2_rsp_data),
    .l2_rsp_last  (l2_rsp_last),
    .l2_rsp_err   (l2_rsp_err),
    .d_l2_req_valid (d_l2_req_valid),
    .d_l2_req_ready (d_l2_req_ready),
    .d_l2_req_addr  (d_l2_req_addr),
    .d_l2_req_cmd   (d_l2_req_cmd),
    .d_l2_req_size  (d_l2_req_size),
    .d_l2_req_len   (d_l2_req_len),
    .d_l2_req_wdata (d_l2_req_wdata),
    .d_l2_req_wstrb (d_l2_req_wstrb),
    .d_l2_rsp_valid (d_l2_rsp_valid),
    .d_l2_rsp_ready (d_l2_rsp_ready),
    .d_l2_rsp_rdata (d_l2_rsp_rdata),
    .d_l2_rsp_last  (d_l2_rsp_last),
    .d_l2_rsp_err   (d_l2_rsp_err),
    .wb_we_o      (wb_we),
    .wb_rd_o      (wb_rd),
    .wb_wdata_o   (wb_wdata),
    .ifetch_err_o (ifetch_err),
    .boot_done_o  (boot_done)
  );

  // Clock
  always #5 clk = ~clk;
  assign sys_clk_p = clk;
  assign sys_clk_n = ~clk;
  assign clk_ref_i = clk;

  // Shared memory for I$/D$
  reg [31:0] mem [0:MEM_WORDS-1];

  function [31:0] mem_read_word;
    input [31:0] addr;
    reg [31:0] idx;
    begin
      idx = addr[31:2];
      if (idx < MEM_WORDS)
        mem_read_word = mem[idx];
      else
        mem_read_word = 32'h00000013; // NOP
    end
  endfunction

  function [31:0] mem_word;
    input [31:0] addr;
    begin
      mem_word = mem_read_word(addr);
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
    input [31:0] addr;
    input [7:0] value;
    reg [31:0] idx;
    reg [31:0] word;
    begin
      idx = addr[31:2];
      if (idx < MEM_WORDS) begin
        word = mem[idx];
        case (addr[1:0])
          2'd0: word[7:0]   = value;
          2'd1: word[15:8]  = value;
          2'd2: word[23:16] = value;
          2'd3: word[31:24] = value;
        endcase
        mem[idx] = word;
      end
    end
  endtask

  task mem_write64;
    input [31:0] addr;
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


  function [63:0] make_beat;
    input [31:0] base;
    input [3:0]  beat;
    reg [31:0] w0;
    reg [31:0] w1;
    begin
      w0 = mem_read_word(base + (beat * 8));
      w1 = mem_read_word(base + (beat * 8) + 4);
      make_beat = {w1, w0};
    end
  endfunction

  function [63:0] uc_read_data;
    input [31:0] addr;
    input [31:0] word;
    begin
      if (addr[2])
        uc_read_data = {word, 32'h0};
      else
        uc_read_data = {32'h0, word};
    end
  endfunction

  reg        pending;
  reg        pending_uc;
  reg [31:0] pending_addr;
  reg [3:0]  pending_beat;
  integer   i_delay_cfg;
  integer   i_delay_cnt;
  reg       i_err_once;
  reg       i_err_armed;

  // D$ L2 model state
  localparam [1:0] D_CMD_LINE_RD = 2'b00;
  localparam [1:0] D_CMD_UC_RD   = 2'b01;
  localparam [1:0] D_CMD_UC_WR   = 2'b10;
  localparam [1:0] D_CMD_WB_LINE = 2'b11;
  localparam [1:0] D_RSP_LINE    = 2'b00;
  localparam [1:0] D_RSP_UC_RD   = 2'b01;
  localparam [1:0] D_RSP_UC_WR   = 2'b10;
  localparam [1:0] D_RSP_WB_ACK  = 2'b11;

  reg        d_pending;
  reg [1:0]  d_rsp_type;
  reg [31:0] d_rsp_addr;
  reg [2:0]  d_rsp_beat;
  reg [2:0]  d_wb_beat;
  integer   d_delay_cfg;
  integer   d_delay_cnt;
  reg       d_err_once;
  reg       d_err_armed;

  integer linefill_cnt;
  integer cycles;
  integer mi;
  integer test_id;
  integer expect_rd_arg;
  reg [4:0]  expect_rd;
  reg [31:0] expect_val;
  reg        require_linefill;
  reg [8*64-1:0] memfile;
  integer max_cycles;

  always @(*) begin
    l2_req_ready = ~pending;
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pending      <= 1'b0;
      pending_uc   <= 1'b0;
      pending_addr <= 32'b0;
      pending_beat <= 4'd0;
      i_delay_cnt  <= 0;
      i_err_armed  <= 1'b0;
      l2_rsp_valid <= 1'b0;
      l2_rsp_data  <= 64'b0;
      l2_rsp_last  <= 1'b0;
      l2_rsp_err   <= 1'b0;
      linefill_cnt <= 0;
    end else begin
      // count line fills
      if (l2_req_valid && l2_req_ready && (l2_req_cmd == 2'b00))
        linefill_cnt <= linefill_cnt + 1;

      // latch request
      if (l2_req_valid && l2_req_ready) begin
        pending      <= 1'b1;
        pending_uc   <= (l2_req_cmd == 2'b01);
        pending_addr <= l2_req_addr;
        pending_beat <= 4'd0;
        i_delay_cnt  <= i_delay_cfg;
        i_err_armed  <= i_err_once;
      end

      // drop valid after handshake
      if (l2_rsp_valid && l2_rsp_ready)
        l2_rsp_valid <= 1'b0;

      if (pending) begin
        if (i_delay_cnt != 0) begin
          i_delay_cnt <= i_delay_cnt - 1;
        end else if (!l2_rsp_valid || (l2_rsp_valid && l2_rsp_ready)) begin
          l2_rsp_valid <= 1'b1;
          l2_rsp_err   <= i_err_armed;
          if (pending_uc) begin
            l2_rsp_data <= {32'h0, mem_word(pending_addr)};
            l2_rsp_last <= 1'b1;
            if (l2_rsp_ready)
              pending <= 1'b0;
          end else begin
            l2_rsp_data <= make_beat(pending_addr, pending_beat);
            l2_rsp_last <= (pending_beat == 4'd7);
            if (l2_rsp_ready) begin
              if (pending_beat == 4'd7)
                pending <= 1'b0;
              else
                pending_beat <= pending_beat + 1'b1;
            end
          end
          if (i_err_armed && l2_rsp_ready)
            i_err_armed <= 1'b0;
        end
      end
    end
  end

  // D$ L2 model (simple, always-ready)
  assign d_l2_req_ready = 1'b1;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      d_pending     <= 1'b0;
      d_rsp_type    <= 2'b00;
      d_rsp_addr    <= 32'b0;
      d_rsp_beat    <= 3'd0;
      d_wb_beat     <= 3'd0;
      d_delay_cnt   <= 0;
      d_err_armed   <= 1'b0;
      d_l2_rsp_valid<= 1'b0;
      d_l2_rsp_rdata<= 64'b0;
      d_l2_rsp_last <= 1'b0;
      d_l2_rsp_err  <= 1'b0;
    end else begin
      if (d_l2_rsp_valid && d_l2_rsp_ready)
        d_l2_rsp_valid <= 1'b0;

      if (d_l2_req_valid && d_l2_req_ready) begin
        case (d_l2_req_cmd)
          D_CMD_LINE_RD: begin
            d_pending  <= 1'b1;
            d_rsp_type <= D_RSP_LINE;
            d_rsp_addr <= d_l2_req_addr;
            d_rsp_beat <= 3'd0;
            d_delay_cnt<= d_delay_cfg;
            d_err_armed<= d_err_once;
          end
          D_CMD_UC_RD: begin
            d_pending  <= 1'b1;
            d_rsp_type <= D_RSP_UC_RD;
            d_rsp_addr <= d_l2_req_addr;
            d_rsp_beat <= 3'd0;
            d_delay_cnt<= d_delay_cfg;
            d_err_armed<= d_err_once;
          end
          D_CMD_UC_WR: begin
            // Align to 8-byte boundary; wstrb selects upper/lower word
            mem_write64({d_l2_req_addr[31:3], 3'b0}, d_l2_req_wdata, d_l2_req_wstrb);
            d_pending  <= 1'b1;
            d_rsp_type <= D_RSP_UC_WR;
            d_rsp_addr <= d_l2_req_addr;
            d_rsp_beat <= 3'd0;
            d_delay_cnt<= d_delay_cfg;
            d_err_armed<= d_err_once;
          end
          D_CMD_WB_LINE: begin
            mem_write64(d_l2_req_addr + {d_wb_beat, 3'b0}, d_l2_req_wdata, d_l2_req_wstrb);
            if (d_wb_beat == 3'd7) begin
              d_wb_beat <= 3'd0;
              d_pending  <= 1'b1;
              d_rsp_type <= D_RSP_WB_ACK;
              d_rsp_addr <= d_l2_req_addr;
              d_rsp_beat <= 3'd0;
              d_delay_cnt<= d_delay_cfg;
              d_err_armed<= d_err_once;
            end else begin
              d_wb_beat <= d_wb_beat + 3'd1;
            end
          end
          default: begin
          end
        endcase
      end

      if (d_pending) begin
        if (d_delay_cnt != 0) begin
          d_delay_cnt <= d_delay_cnt - 1;
        end else if (!d_l2_rsp_valid || (d_l2_rsp_valid && d_l2_rsp_ready)) begin
          d_l2_rsp_valid <= 1'b1;
          d_l2_rsp_err   <= d_err_armed;
          case (d_rsp_type)
            D_RSP_LINE: begin
              d_l2_rsp_rdata <= make_beat(d_rsp_addr, d_rsp_beat);
              d_l2_rsp_last  <= (d_rsp_beat == 3'd7);
              if (d_l2_rsp_ready) begin
                if (d_rsp_beat == 3'd7)
                  d_pending <= 1'b0;
                else
                  d_rsp_beat <= d_rsp_beat + 3'd1;
              end
            end
            D_RSP_UC_RD: begin
              d_l2_rsp_rdata <= uc_read_data(d_rsp_addr, mem_read_word(d_rsp_addr));
              d_l2_rsp_last  <= 1'b1;
              if (d_l2_rsp_ready)
                d_pending <= 1'b0;
            end
            default: begin
              d_l2_rsp_rdata <= 64'b0;
              d_l2_rsp_last  <= 1'b1;
              if (d_l2_rsp_ready)
                d_pending <= 1'b0;
            end
          endcase
          if (d_err_armed && d_l2_rsp_ready)
            d_err_armed <= 1'b0;
        end
      end
    end
  end

  // Reset + init
  initial begin
    test_id = 0;
    if (!$value$plusargs("TEST=%d", test_id))
      test_id = 0;

    memfile = "program_ddr.mem";
    expect_rd = 5'd4;
    expect_val = 32'h00000011;
    require_linefill = 1'b1;
    max_cycles = 2000;
    i_delay_cfg = 0;
    d_delay_cfg = 0;
    i_err_once = 1'b0;
    d_err_once = 1'b0;

    case (test_id)
      1: begin
        memfile = "TEST_FILES/mem_test1_alu_fwd.mem";
        expect_rd = 5'd3;
        expect_val = 32'h00000004;
        require_linefill = 1'b0;
      end
      2: begin
        memfile = "TEST_FILES/mem_test2_load_use.mem";
        expect_rd = 5'd2;
        expect_val = 32'h00000012;
        require_linefill = 1'b0;
      end
      3: begin
        memfile = "TEST_FILES/mem_test3_store_dep.mem";
        expect_rd = 5'd2;
        expect_val = 32'h00000005;
        require_linefill = 1'b0;
      end
      4: begin
        memfile = "TEST_FILES/mem_test4_branch_taken.mem";
        expect_rd = 5'd2;
        expect_val = 32'h00000002;
        require_linefill = 1'b0;
      end
      5: begin
        memfile = "TEST_FILES/mem_test5_load_store.mem";
        expect_rd = 5'd2;
        expect_val = 32'h00000009;
        require_linefill = 1'b0;
      end
      6: begin
        memfile = "TEST_FILES/mem_test6_branch_not_taken.mem";
        expect_rd = 5'd2;
        expect_val = 32'h00000002;
        require_linefill = 1'b0;
      end
      7: begin
        memfile = "TEST_FILES/mem_test7_jal.mem";
        expect_rd = 5'd2;
        expect_val = 32'h00000004;
        require_linefill = 1'b0;
      end
      8: begin
        memfile = "TEST_FILES/mem_test8_jalr.mem";
        expect_rd = 5'd2;
        expect_val = 32'h00000004;
        require_linefill = 1'b0;
      end
      9: begin
        memfile = "TEST_FILES/mem_test9_lb_sb.mem";
        expect_rd = 5'd2;
        expect_val = 32'hFFFFFF80;
        require_linefill = 1'b0;
      end
      10: begin
        memfile = "TEST_FILES/mem_test10_lhu_sh.mem";
        expect_rd = 5'd2;
        expect_val = 32'h000000F0;
        require_linefill = 1'b0;
      end
      11: begin
        memfile = "TEST_FILES/mem_test11_long_mix.mem";
        expect_rd = 5'd8;
        expect_val = 32'h0000001B;
        require_linefill = 1'b0;
      end
      12: begin
        memfile = "TEST_FILES/mem_test12_long_mem.mem";
        expect_rd = 5'd10;
        expect_val = 32'h00000103;
        require_linefill = 1'b0;
      end
      13: begin
        memfile = "TEST_FILES/mem_test13_stress.mem";
        expect_rd = 5'd8;
        expect_val = 32'h2D064C9E;
        require_linefill = 1'b0;
        max_cycles = 20000;
      end
      14: begin
        memfile = "TEST_FILES/mem_test14_id_miss.mem";
        expect_rd = 5'd8;
        expect_val = 32'h0002FFF4;
        require_linefill = 1'b0;
        max_cycles = 20000;
      end
      15: begin
        memfile = "TEST_FILES/mem_test1_alu_fwd.mem";
        i_err_once = 1'b1;
        expect_rd = 5'd0;
        expect_val = 32'h00000000;
        require_linefill = 1'b0;
        max_cycles = 2000;
      end
      16: begin
        memfile = "TEST_FILES/mem_test5_load_store.mem";
        d_err_once = 1'b1;
        expect_rd = 5'd0;
        expect_val = 32'h00000000;
        require_linefill = 1'b0;
        max_cycles = 4000;
      end
      17: begin
        memfile = "TEST_FILES/mem_test17_icache_stress.mem";
        expect_rd = 5'd4;
        expect_val = 32'h00000011;
        require_linefill = 1'b1;
        max_cycles = 8000;
      end
      18: begin
        memfile = "TEST_FILES/mem_test18_dcache_wb.mem";
        expect_rd = 5'd8;
        expect_val = 32'h00000011;
        require_linefill = 1'b0;
        max_cycles = 8000;
      end
      19: begin
        memfile = "TEST_FILES/mem_test19_hazard_branch.mem";
        expect_rd = 5'd6;
        expect_val = 32'h000000CC;
        require_linefill = 1'b0;
        max_cycles = 4000;
      end
      20: begin
        memfile = "TEST_FILES/mem_test20_long_mix.mem";
        expect_rd = 5'd8;
        expect_val = 32'h0000005A;
        require_linefill = 1'b0;
        max_cycles = 50000;
      end
      21: begin
        memfile = "TEST_FILES/mem_test21_long_branch.mem";
        expect_rd = 5'd8;
        expect_val = 32'h0000005A;
        require_linefill = 1'b0;
        max_cycles = 200000;
      end
      default: begin
      end
    endcase

    if ($value$plusargs("MEMFILE=%s", memfile)) begin
      // optional override
    end
    if ($value$plusargs("EXPECT_RD=%d", expect_rd_arg))
      expect_rd = expect_rd_arg[4:0];
    if ($value$plusargs("EXPECT_VAL=%h", expect_val)) begin
      // expect_val set by plusarg
    end
    if ($value$plusargs("MAXCYCLES=%d", max_cycles)) begin
      // override timeout
    end
    if ($value$plusargs("I_RSP_DELAY=%d", i_delay_cfg)) begin
      // fixed I$ response delay
    end
    if ($value$plusargs("D_RSP_DELAY=%d", d_delay_cfg)) begin
      // fixed D$ response delay
    end
    if ($value$plusargs("I_ERR_ONCE=%d", i_err_once)) begin
      // inject one I$ response error
    end
    if ($value$plusargs("D_ERR_ONCE=%d", d_err_once)) begin
      // inject one D$ response error
    end

    clk  = 1'b0;
    rst_n = 1'b0;
    uart_rx = 1'b1;
    l2_rsp_valid = 1'b0;
    l2_rsp_data  = 64'b0;
    l2_rsp_last  = 1'b0;
    l2_rsp_err   = 1'b0;
    d_l2_rsp_valid = 1'b0;
    d_l2_rsp_rdata = 64'b0;
    d_l2_rsp_last  = 1'b0;
    d_l2_rsp_err   = 1'b0;

    for (mi = 0; mi < MEM_WORDS; mi = mi + 1)
      mem[mi] = 32'h00000013;
    $readmemh(memfile, mem);

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
  end

  // Cycle counter + timeout
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      cycles <= 0;
    else
      cycles <= cycles + 1;
  end

  always @(posedge clk) begin
    if (rst_n && (cycles > max_cycles)) begin
      $display("TIMEOUT");
      $finish;
    end
  end

  // PASS/FAIL conditions
  always @(posedge clk) begin
    if (rst_n && ifetch_err) begin
      if (test_id == 15) begin
        $display("PASS: test 15 I$ error observed");
      end else begin
        $display("I$ fetch error -> FAIL");
      end
      $finish;
    end
    if (rst_n && (test_id == 16) && (d_l2_rsp_valid && d_l2_rsp_err)) begin
      $display("PASS: test 16 D$ error observed");
      $finish;
    end
    if (rst_n && wb_we) begin
      $display("WB: x%0d <= 0x%08x", wb_rd, wb_wdata);
      if ((wb_rd == expect_rd) && (wb_wdata == expect_val)) begin
        if (require_linefill && (linefill_cnt == 0)) begin
          $display("FAIL: no I$ linefill observed");
          $finish;
        end
        $display("PASS: test %0d expect x%0d = 0x%08x", test_id, expect_rd, expect_val);
        $finish;
      end
    end
  end

endmodule

// ----------------------------------------------------------------------------
// Simplified MIG model for simulation (used by MIG_DDR2_interface.v wrapper).
// - app_addr is 16-byte aligned address (addr[31:4])
// - app_cmd: 3'b001 read, 3'b000 write
// - app_wdf_mask: 1=mask (no write), 0=write
// - Fixed 2-cycle read latency, always-ready interface
// ----------------------------------------------------------------------------
module mig_7series_0_mig (
  output [13:0]                       ddr2_addr,
  output [2:0]                        ddr2_ba,
  output                              ddr2_cas_n,
  output [0:0]                        ddr2_ck_n,
  output [0:0]                        ddr2_ck_p,
  output [0:0]                        ddr2_cke,
  output                              ddr2_ras_n,
  output                              ddr2_we_n,
  inout  [15:0]                       ddr2_dq,
  inout  [1:0]                        ddr2_dqs_n,
  inout  [1:0]                        ddr2_dqs_p,
  output                              init_calib_complete,
  output [0:0]                        ddr2_cs_n,
  output [1:0]                        ddr2_dm,
  output [0:0]                        ddr2_odt,
  input  [27:0]                       app_addr,
  input  [2:0]                        app_cmd,
  input                               app_en,
  input  [127:0]                      app_wdf_data,
  input                               app_wdf_end,
  input                               app_wdf_wren,
  output reg [127:0]                  app_rd_data,
  output reg                          app_rd_data_end,
  output reg                          app_rd_data_valid,
  output reg                          app_rdy,
  output reg                          app_wdf_rdy,
  input                               app_sr_req,
  input                               app_ref_req,
  input                               app_zq_req,
  output reg                          app_sr_active,
  output reg                          app_ref_ack,
  output reg                          app_zq_ack,
  output                              ui_clk,
  output reg                          ui_clk_sync_rst,
  input  [15:0]                       app_wdf_mask,
  input                               sys_clk_p,
  input                               sys_clk_n,
  input                               clk_ref_i,
  input                               sys_rst
);
  localparam integer MEM_BYTES = 1<<20;
  localparam integer MEM_WORDS = MEM_BYTES/4;
  localparam [2:0] CMD_READ  = 3'b001;
  localparam [2:0] CMD_WRITE = 3'b000;

  reg [7:0] mem_b [0:MEM_BYTES-1];
  reg [31:0] init_mem [0:MEM_WORDS-1];
  reg [8*256-1:0] memfile;
  integer wi;
  integer test_id_mig;

  // DDR2 pins are unused in this model
  assign ddr2_addr = 14'd0;
  assign ddr2_ba   = 3'd0;
  assign ddr2_cas_n = 1'b1;
  assign ddr2_ck_n  = 1'b0;
  assign ddr2_ck_p  = 1'b0;
  assign ddr2_cke   = 1'b0;
  assign ddr2_ras_n = 1'b1;
  assign ddr2_we_n  = 1'b1;
  assign ddr2_cs_n  = 1'b1;
  assign ddr2_dm    = 2'b00;
  assign ddr2_odt   = 1'b0;
  assign ddr2_dq    = 16'hzzzz;
  assign ddr2_dqs_n = 2'bzz;
  assign ddr2_dqs_p = 2'bzz;

  // Use sys_clk_p as UI clock
  assign ui_clk = sys_clk_p;
  assign init_calib_complete = ~sys_rst;

  initial begin
    memfile = "program_ddr.mem";
    if ($value$plusargs("MEMFILE=%s", memfile)) begin
      // override
    end else begin
      test_id_mig = 0;
      if ($value$plusargs("TEST=%d", test_id_mig)) begin
        case (test_id_mig)
          1:  memfile = "TEST_FILES/mem_test1_alu_fwd.mem";
          2:  memfile = "TEST_FILES/mem_test2_load_use.mem";
          3:  memfile = "TEST_FILES/mem_test3_store_dep.mem";
          4:  memfile = "TEST_FILES/mem_test4_branch_taken.mem";
          5:  memfile = "TEST_FILES/mem_test5_load_store.mem";
          6:  memfile = "TEST_FILES/mem_test6_branch_not_taken.mem";
          7:  memfile = "TEST_FILES/mem_test7_jal.mem";
          8:  memfile = "TEST_FILES/mem_test8_jalr.mem";
          9:  memfile = "TEST_FILES/mem_test9_lb_sb.mem";
          10: memfile = "TEST_FILES/mem_test10_lhu_sh.mem";
          11: memfile = "TEST_FILES/mem_test11_long_mix.mem";
          12: memfile = "TEST_FILES/mem_test12_long_mem.mem";
          13: memfile = "TEST_FILES/mem_test13_stress.mem";
          14: memfile = "TEST_FILES/mem_test14_id_miss.mem";
          15: memfile = "TEST_FILES/mem_test1_alu_fwd.mem";
          16: memfile = "TEST_FILES/mem_test5_load_store.mem";
          17: memfile = "TEST_FILES/mem_test17_icache_stress.mem";
          18: memfile = "TEST_FILES/mem_test18_dcache_wb.mem";
          19: memfile = "TEST_FILES/mem_test19_hazard_branch.mem";
          20: memfile = "TEST_FILES/mem_test20_long_mix.mem";
          21: memfile = "TEST_FILES/mem_test21_long_branch.mem";
          default: memfile = "program_ddr.mem";
        endcase
      end
    end
    for (wi = 0; wi < MEM_WORDS; wi = wi + 1)
      init_mem[wi] = 32'h00000013;
    $readmemh(memfile, init_mem);
    for (wi = 0; wi < MEM_WORDS; wi = wi + 1) begin
      mem_b[wi*4 + 0] = init_mem[wi][7:0];
      mem_b[wi*4 + 1] = init_mem[wi][15:8];
      mem_b[wi*4 + 2] = init_mem[wi][23:16];
      mem_b[wi*4 + 3] = init_mem[wi][31:24];
    end
  end

  function [127:0] rd128;
    input [27:0] a16;
    integer i;
    reg [31:0] base;
    begin
      base = {a16, 4'b0};
      for (i = 0; i < 16; i = i + 1)
        rd128[i*8 +: 8] = mem_b[base + i];
    end
  endfunction

  task wr128;
    input [27:0] a16;
    input [127:0] data;
    input [15:0] mask;
    integer i;
    reg [31:0] base;
    begin
      base = {a16, 4'b0};
      for (i = 0; i < 16; i = i + 1) begin
        if (!mask[i])
          mem_b[base + i] = data[i*8 +: 8];
      end
    end
  endtask

  reg [27:0] rd_addr_d0, rd_addr_d1;
  reg        rd_valid_d0, rd_valid_d1;

  always @(posedge ui_clk or posedge sys_rst) begin
    if (sys_rst) begin
      app_rdy          <= 1'b0;
      app_wdf_rdy      <= 1'b0;
      app_rd_data_valid<= 1'b0;
      app_rd_data_end  <= 1'b0;
      app_rd_data      <= 128'd0;
      rd_valid_d0      <= 1'b0;
      rd_valid_d1      <= 1'b0;
      rd_addr_d0       <= 28'd0;
      rd_addr_d1       <= 28'd0;
      app_sr_active    <= 1'b0;
      app_ref_ack      <= 1'b0;
      app_zq_ack       <= 1'b0;
      ui_clk_sync_rst  <= 1'b1;
    end else begin
      app_rdy         <= 1'b1;
      app_wdf_rdy     <= 1'b1;
      app_sr_active   <= 1'b0;
      app_ref_ack     <= 1'b0;
      app_zq_ack      <= 1'b0;
      ui_clk_sync_rst <= 1'b0;

      // Accept writes
      if (app_en && app_rdy && (app_cmd == CMD_WRITE) && app_wdf_wren && app_wdf_rdy) begin
        wr128(app_addr, app_wdf_data, app_wdf_mask);
      end

      // Pipeline reads (2-cycle latency)
      rd_valid_d0 <= app_en && app_rdy && (app_cmd == CMD_READ);
      rd_addr_d0  <= app_addr;
      rd_valid_d1 <= rd_valid_d0;
      rd_addr_d1  <= rd_addr_d0;

      app_rd_data_valid <= rd_valid_d1;
      app_rd_data_end   <= rd_valid_d1;
      if (rd_valid_d1)
        app_rd_data <= rd128(rd_addr_d1);
    end
  end

endmodule
