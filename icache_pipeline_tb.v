`timescale 1ns/1ps
// icache_pipeline_tb.v
// Simple TB to verify I$ + pipeline integration.

module icache_pipeline_tb;
  localparam ADDR_WIDTH = 32;
  localparam L2_DATA_W  = 64;
  localparam MEM_WORDS  = 256;

  reg                   clk;
  reg                   rst_n;

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

  // DUT
  icache_pipeline_top #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .L2_DATA_W  (L2_DATA_W)
  ) dut (
    .clk          (clk),
    .rst_n        (rst_n),
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
    .ifetch_err_o (ifetch_err)
  );

  // Clock
  always #5 clk = ~clk;

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

    memfile = "mem_init_example.mem";
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
        memfile = "mem_test1_alu_fwd.mem";
        expect_rd = 5'd3;
        expect_val = 32'h00000004;
        require_linefill = 1'b0;
      end
      2: begin
        memfile = "mem_test2_load_use.mem";
        expect_rd = 5'd2;
        expect_val = 32'h00000012;
        require_linefill = 1'b0;
      end
      3: begin
        memfile = "mem_test3_store_dep.mem";
        expect_rd = 5'd2;
        expect_val = 32'h00000005;
        require_linefill = 1'b0;
      end
      4: begin
        memfile = "mem_test4_branch_taken.mem";
        expect_rd = 5'd2;
        expect_val = 32'h00000002;
        require_linefill = 1'b0;
      end
      5: begin
        memfile = "mem_test5_load_store.mem";
        expect_rd = 5'd2;
        expect_val = 32'h00000009;
        require_linefill = 1'b0;
      end
      6: begin
        memfile = "mem_test6_branch_not_taken.mem";
        expect_rd = 5'd2;
        expect_val = 32'h00000002;
        require_linefill = 1'b0;
      end
      7: begin
        memfile = "mem_test7_jal.mem";
        expect_rd = 5'd2;
        expect_val = 32'h00000004;
        require_linefill = 1'b0;
      end
      8: begin
        memfile = "mem_test8_jalr.mem";
        expect_rd = 5'd2;
        expect_val = 32'h00000004;
        require_linefill = 1'b0;
      end
      9: begin
        memfile = "mem_test9_lb_sb.mem";
        expect_rd = 5'd2;
        expect_val = 32'hFFFFFF80;
        require_linefill = 1'b0;
      end
      10: begin
        memfile = "mem_test10_lhu_sh.mem";
        expect_rd = 5'd2;
        expect_val = 32'h000000F0;
        require_linefill = 1'b0;
      end
      11: begin
        memfile = "mem_test11_long_mix.mem";
        expect_rd = 5'd8;
        expect_val = 32'h0000001B;
        require_linefill = 1'b0;
      end
      12: begin
        memfile = "mem_test12_long_mem.mem";
        expect_rd = 5'd10;
        expect_val = 32'h00000103;
        require_linefill = 1'b0;
      end
      13: begin
        memfile = "mem_test13_stress.mem";
        expect_rd = 5'd8;
        expect_val = 32'h000009AE;
        require_linefill = 1'b0;
        max_cycles = 20000;
      end
      14: begin
        memfile = "mem_test14_id_miss.mem";
        expect_rd = 5'd8;
        expect_val = 32'h0002FFF4;
        require_linefill = 1'b0;
        max_cycles = 20000;
      end
      15: begin
        memfile = "mem_test1_alu_fwd.mem";
        i_err_once = 1'b1;
        expect_rd = 5'd0;
        expect_val = 32'h00000000;
        require_linefill = 1'b0;
        max_cycles = 2000;
      end
      16: begin
        memfile = "mem_test5_load_store.mem";
        d_err_once = 1'b1;
        expect_rd = 5'd0;
        expect_val = 32'h00000000;
        require_linefill = 1'b0;
        max_cycles = 4000;
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
