`timescale 1ns/1ps
// icache_pipeline_tb.v
// Simple TB to verify I$ + pipeline integration.

module icache_pipeline_tb;
  localparam ADDR_WIDTH = 32;
  localparam L2_DATA_W  = 64;
  parameter integer MEM_WORDS = 262144;
  parameter integer USE_MIG   = 1;
  parameter [31:0] RESET_PC   = (USE_MIG != 0) ? 32'h8000_0000 : 32'h0000_0000;
  localparam integer UART_CLK_HZ = 100_000_000;
  localparam integer UART_BAUD   = 1_000_000;
  localparam integer UART_CLKS_PER_BIT = UART_CLK_HZ / UART_BAUD;

  reg                   clk;
  reg                   rst_n;
  reg                   uart_rx;
  wire                  uart_tx;

  // DDR2 MIG (USE_MIG=1 uses sim model below)
  wire [15:0]           ddr2_dq;
  wire [1:0]            ddr2_dqs_n;
  wire [1:0]            ddr2_dqs_p;
  wire [12:0]           ddr2_addr;
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
  wire                  sys_clk_i;
  wire                  clk_ref_i;

  // I$ L2 interface
  wire                  l2_req_valid;
  wire                  l2_req_ready;
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
  integer               rtos_uart_mon;
  integer               rtos_uart_finish_on_pass;
  integer               rtos_trap_trace;
  integer               rtos_pass_seen;
  integer               uart_mon_bit;
  reg [7:0]             uart_mon_byte;
  reg [8*19-1:0]        uart_pass_window;

  // DUT
  icache_pipeline_top #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .L2_DATA_W  (L2_DATA_W),
    .USE_MIG    (USE_MIG),
    .UART_BAUD   (UART_BAUD),
    .UART_CLK_HZ (UART_CLK_HZ),
    .BOOT_RELEASE_CYCLES(1),
    .RESET_PC   (RESET_PC)
  ) dut (
    .clk          (clk),
    .rst_n        (rst_n),
    .launcher_reset_req_i(1'b0),
    .uart_rx_i    (uart_rx),
    .uart_tx_o    (uart_tx),
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
    .sys_clk_i    (sys_clk_i),
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
  assign sys_clk_i = clk;
  assign clk_ref_i = clk;

  // Shared memory for I$/D$
  reg [31:0] mem [0:MEM_WORDS-1];

  function [31:0] mem_index;
    input [31:0] addr;
    begin
      mem_index = (addr[31] != 1'b0) ? ((addr - 32'h8000_0000) >> 2) : (addr >> 2);
    end
  endfunction

  function [31:0] mem_read_word;
    input [31:0] addr;
    reg [31:0] idx;
    begin
      idx = mem_index(addr);
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
      idx = mem_index(addr);
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
  integer last_wb_cycle;
  integer mi;
  integer test_id;
  integer expect_rd_arg;
  reg [4:0]  expect_rd;
  reg [31:0] expect_val;
  reg        require_linefill;
  // Leave room for absolute build paths, including nested output directories.
  reg [8*1024-1:0] memfile;
  reg [8*1024-1:0] memfile_try;
  reg            memfile_found;
  integer max_cycles;
  integer memfile_fd;
  integer rand_mem_en;
  integer rand_seed;
  integer rand_i_delay_max;
  integer rand_d_delay_max;
  integer assert_en;
  integer stall_watchdog_max;
  integer trace_en;
  integer cov_en;
  reg [8*1024-1:0] trace_file;
  reg [8*1024-1:0] cov_file;
  integer trace_fd;
  integer cov_fd;
  integer cov_active_cycles;
  integer cov_wb_commits;
  integer cov_i_req_hs;
  integer cov_d_req_hs;
  integer cov_i_rsp_hs;
  integer cov_d_rsp_hs;
  integer cov_i_req_line;
  integer cov_i_req_uc;
  integer cov_i_req_other;
  integer cov_d_req_line;
  integer cov_d_req_uc_rd;
  integer cov_d_req_uc_wr;
  integer cov_d_req_wb;
  integer cov_i_rsp_err;
  integer cov_d_rsp_err;
  integer cov_ifetch_err;
  integer cov_max_i_req_stall;
  integer cov_max_d_req_stall;
  integer cov_max_i_rsp_stall;
  integer cov_max_d_rsp_stall;
  integer cov_i_rsp_stall_cur;
  integer cov_d_rsp_stall_cur;
  integer state_cov_en;
  reg [8*1024-1:0] state_cov_file;
  integer state_cov_fd;
  reg [6:0]   cov_ic_state_seen;
  reg [11:0]  cov_dc_state_seen;
  reg [17:0]  cov_l2_state_seen;
  reg [83:0]  cov_ic_dc_cross_seen;  // 7 * 12
  reg [125:0] cov_ic_l2_cross_seen;  // 7 * 18
  reg [215:0] cov_dc_l2_cross_seen;  // 12 * 18
  integer cov_ev_both_req_valid;
  integer cov_ev_redirect_with_fetch_rsp;
  integer cov_ev_iwait_and_drefill;
  integer cov_ev_iwait_and_dwbwait;
  integer cov_ev_l2_err_rsp;
  integer cov_ev_l2_d_sel_with_i_req;
  integer cov_ev_l2_i_sel_with_d_req;

  // Request stability/watchdog checkers
  reg hold_i_req;
  reg [31:0] hold_i_addr;
  reg [1:0]  hold_i_cmd;
  reg [2:0]  hold_i_size;
  reg [7:0]  hold_i_len;
  integer    hold_i_cycles;

  reg hold_d_req;
  reg [31:0] hold_d_addr;
  reg [1:0]  hold_d_cmd;
  reg [2:0]  hold_d_size;
  reg [7:0]  hold_d_len;
  reg [63:0] hold_d_wdata;
  reg [7:0]  hold_d_wstrb;
  integer    hold_d_cycles;
  reg hold_i_rsp;
  reg [63:0] hold_i_rsp_data;
  reg        hold_i_rsp_last;
  reg        hold_i_rsp_err;
  integer    hold_i_rsp_cycles;
  reg hold_d_rsp;
  reg [63:0] hold_d_rsp_data;
  reg        hold_d_rsp_last;
  reg        hold_d_rsp_err;
  integer    hold_d_rsp_cycles;

  // Monitor channels: in MIG mode, use DUT internal L2 links; otherwise use TB external links.
  wire                  mon_i_req_valid = l2_req_valid;
  wire                  mon_i_req_ready = USE_MIG ? dut.i_l2_req_ready_int : l2_req_ready;
  wire [ADDR_WIDTH-1:0] mon_i_req_addr  = l2_req_addr;
  wire [1:0]            mon_i_req_cmd   = l2_req_cmd;
  wire [2:0]            mon_i_req_size  = l2_req_size;
  wire [7:0]            mon_i_req_len   = l2_req_len;

  wire                  mon_d_req_valid = d_l2_req_valid;
  wire                  mon_d_req_ready = USE_MIG ? dut.d_l2_req_ready_int : d_l2_req_ready;
  wire [ADDR_WIDTH-1:0] mon_d_req_addr  = d_l2_req_addr;
  wire [1:0]            mon_d_req_cmd   = d_l2_req_cmd;
  wire [2:0]            mon_d_req_size  = d_l2_req_size;
  wire [7:0]            mon_d_req_len   = d_l2_req_len;
  wire [L2_DATA_W-1:0]  mon_d_req_wdata = d_l2_req_wdata;
  wire [(L2_DATA_W/8)-1:0] mon_d_req_wstrb = d_l2_req_wstrb;

  wire                  mon_i_rsp_valid = USE_MIG ? dut.i_l2_rsp_valid_int : l2_rsp_valid;
  wire                  mon_i_rsp_ready = l2_rsp_ready;
  wire [L2_DATA_W-1:0]  mon_i_rsp_data  = USE_MIG ? dut.i_l2_rsp_data_int : l2_rsp_data;
  wire                  mon_i_rsp_last  = USE_MIG ? dut.i_l2_rsp_last_int : l2_rsp_last;
  wire                  mon_i_rsp_err   = USE_MIG ? dut.i_l2_rsp_err_int : l2_rsp_err;

  wire                  mon_d_rsp_valid = USE_MIG ? dut.d_l2_rsp_valid_int : d_l2_rsp_valid;
  wire                  mon_d_rsp_ready = d_l2_rsp_ready;
  wire [L2_DATA_W-1:0]  mon_d_rsp_rdata = USE_MIG ? dut.d_l2_rsp_rdata_int : d_l2_rsp_rdata;
  wire                  mon_d_rsp_last  = USE_MIG ? dut.d_l2_rsp_last_int : d_l2_rsp_last;
  wire                  mon_d_rsp_err   = USE_MIG ? dut.d_l2_rsp_err_int : d_l2_rsp_err;
  wire [2:0]            cov_ic_state_cur = dut.u_icache.u_icache.state;
  wire [3:0]            cov_dc_state_cur = dut.u_dcache.state;
  wire [4:0]            mig_l2_state_dbg;
  wire                  mig_l2_sel_busy_dbg;
  wire                  mig_l2_sel_is_d_dbg;
  wire                  mig_app_en_dbg;
  wire                  mig_app_rdy_dbg;
  wire [2:0]            mig_app_cmd_dbg;
  wire [26:0]           mig_app_addr_dbg;
  wire                  mig_app_rd_valid_dbg;
  wire [4:0]            cov_l2_state_cur = mig_l2_state_dbg;

  generate
    if (USE_MIG != 0) begin : GEN_TB_MIG_DBG
      assign mig_l2_state_dbg = dut.GEN_MIG.u_l2.u_core.state;
      assign mig_l2_sel_busy_dbg = dut.GEN_MIG.u_l2.sel_busy;
      assign mig_l2_sel_is_d_dbg = dut.GEN_MIG.u_l2.sel_is_d;
      assign mig_app_en_dbg = dut.GEN_MIG.app_en;
      assign mig_app_rdy_dbg = dut.GEN_MIG.app_rdy;
      assign mig_app_cmd_dbg = dut.GEN_MIG.app_cmd;
      assign mig_app_addr_dbg = dut.GEN_MIG.app_addr;
      assign mig_app_rd_valid_dbg = dut.GEN_MIG.app_rd_data_valid;
    end else begin : GEN_TB_NO_MIG_DBG
      assign mig_l2_state_dbg = 5'd0;
      assign mig_l2_sel_busy_dbg = 1'b0;
      assign mig_l2_sel_is_d_dbg = 1'b0;
      assign mig_app_en_dbg = 1'b0;
      assign mig_app_rdy_dbg = 1'b0;
      assign mig_app_cmd_dbg = 3'd0;
      assign mig_app_addr_dbg = 27'd0;
      assign mig_app_rd_valid_dbg = 1'b0;
    end
  endgenerate

`ifdef SYNTHESIS
  reg tb_i_err_force_active;
  reg tb_i_err_injected;
  reg tb_d_err_force_active;
  reg tb_d_err_injected;
`endif

  function integer rand_mod_tb;
    input integer maxv;
    integer r;
    begin
      if (maxv <= 0) begin
        rand_mod_tb = 0;
      end else begin
        r = $random(rand_seed);
        if (r < 0)
          r = -r;
        rand_mod_tb = r % (maxv + 1);
      end
    end
  endfunction

  task resolve_tb_memfile;
    inout [8*1024-1:0] path_io;
    output           found_o;
    integer          fd_local;
    begin
      found_o = 1'b0;
      memfile_try = path_io;
      fd_local = $fopen(memfile_try, "r");
      // Format trimmed text: concatenating a packed path drops the prefix
      // when assigned back to a register with the same width.
      if (fd_local == 0) begin
        $sformat(memfile_try, "./%0s", path_io);
        fd_local = $fopen(memfile_try, "r");
      end
      if (fd_local == 0) begin
        $sformat(memfile_try, "../%0s", path_io);
        fd_local = $fopen(memfile_try, "r");
      end
      if (fd_local == 0) begin
        $sformat(memfile_try, "../../%0s", path_io);
        fd_local = $fopen(memfile_try, "r");
      end
      if (fd_local == 0) begin
        $sformat(memfile_try, "../../../%0s", path_io);
        fd_local = $fopen(memfile_try, "r");
      end
      if (fd_local == 0) begin
        $sformat(memfile_try, "../../../../%0s", path_io);
        fd_local = $fopen(memfile_try, "r");
      end
      if (fd_local == 0) begin
        $sformat(memfile_try, "../../../../../%0s", path_io);
        fd_local = $fopen(memfile_try, "r");
      end
      if (fd_local == 0) begin
        $sformat(memfile_try, "../../../../../../%0s", path_io);
        fd_local = $fopen(memfile_try, "r");
      end
      if (fd_local != 0) begin
        $fclose(fd_local);
        path_io = memfile_try;
        found_o = 1'b1;
      end
    end
  endtask

  task dump_cov;
    begin
      if (cov_en != 0) begin
        cov_fd = $fopen(cov_file, "w");
        if (cov_fd != 0) begin
          $fdisplay(cov_fd, "test=%0d", test_id);
          $fdisplay(cov_fd, "cycles=%0d", cycles);
          $fdisplay(cov_fd, "active_cycles=%0d", cov_active_cycles);
          $fdisplay(cov_fd, "wb_commits=%0d", cov_wb_commits);
          $fdisplay(cov_fd, "i_req_hs=%0d", cov_i_req_hs);
          $fdisplay(cov_fd, "d_req_hs=%0d", cov_d_req_hs);
          $fdisplay(cov_fd, "i_rsp_hs=%0d", cov_i_rsp_hs);
          $fdisplay(cov_fd, "d_rsp_hs=%0d", cov_d_rsp_hs);
          $fdisplay(cov_fd, "i_req_line=%0d", cov_i_req_line);
          $fdisplay(cov_fd, "i_req_uc=%0d", cov_i_req_uc);
          $fdisplay(cov_fd, "i_req_other=%0d", cov_i_req_other);
          $fdisplay(cov_fd, "d_req_line=%0d", cov_d_req_line);
          $fdisplay(cov_fd, "d_req_uc_rd=%0d", cov_d_req_uc_rd);
          $fdisplay(cov_fd, "d_req_uc_wr=%0d", cov_d_req_uc_wr);
          $fdisplay(cov_fd, "d_req_wb=%0d", cov_d_req_wb);
          $fdisplay(cov_fd, "i_rsp_err=%0d", cov_i_rsp_err);
          $fdisplay(cov_fd, "d_rsp_err=%0d", cov_d_rsp_err);
          $fdisplay(cov_fd, "ifetch_err=%0d", cov_ifetch_err);
          $fdisplay(cov_fd, "max_i_req_stall=%0d", cov_max_i_req_stall);
          $fdisplay(cov_fd, "max_d_req_stall=%0d", cov_max_d_req_stall);
          $fdisplay(cov_fd, "max_i_rsp_stall=%0d", cov_max_i_rsp_stall);
          $fdisplay(cov_fd, "max_d_rsp_stall=%0d", cov_max_d_rsp_stall);
          $fclose(cov_fd);
          cov_fd = 0;
          $display("[TB COV] wrote %0s", cov_file);
        end else begin
          $display("[TB COV] WARN: cannot open %0s", cov_file);
        end
      end
    end
  endtask

  task dump_state_cov;
    begin
      if (state_cov_en != 0) begin
        state_cov_fd = $fopen(state_cov_file, "w");
        if (state_cov_fd != 0) begin
          $fdisplay(state_cov_fd, "test=%0d", test_id);
          $fdisplay(state_cov_fd, "cycles=%0d", cycles);
          $fdisplay(state_cov_fd, "ic_state_seen=0x%0h", cov_ic_state_seen);
          $fdisplay(state_cov_fd, "dc_state_seen=0x%0h", cov_dc_state_seen);
          $fdisplay(state_cov_fd, "l2_state_seen=0x%0h", cov_l2_state_seen);
          $fdisplay(state_cov_fd, "ic_dc_cross_seen=0x%0h", cov_ic_dc_cross_seen);
          $fdisplay(state_cov_fd, "ic_l2_cross_seen=0x%0h", cov_ic_l2_cross_seen);
          $fdisplay(state_cov_fd, "dc_l2_cross_seen=0x%0h", cov_dc_l2_cross_seen);
          $fdisplay(state_cov_fd, "ev_both_req_valid=%0d", cov_ev_both_req_valid);
          $fdisplay(state_cov_fd, "ev_redirect_with_fetch_rsp=%0d", cov_ev_redirect_with_fetch_rsp);
          $fdisplay(state_cov_fd, "ev_iwait_and_drefill=%0d", cov_ev_iwait_and_drefill);
          $fdisplay(state_cov_fd, "ev_iwait_and_dwbwait=%0d", cov_ev_iwait_and_dwbwait);
          $fdisplay(state_cov_fd, "ev_l2_err_rsp=%0d", cov_ev_l2_err_rsp);
          $fdisplay(state_cov_fd, "ev_l2_d_sel_with_i_req=%0d", cov_ev_l2_d_sel_with_i_req);
          $fdisplay(state_cov_fd, "ev_l2_i_sel_with_d_req=%0d", cov_ev_l2_i_sel_with_d_req);
          $fclose(state_cov_fd);
          state_cov_fd = 0;
          $display("[TB STATECOV] wrote %0s", state_cov_file);
        end else begin
          $display("[TB STATECOV] WARN: cannot open %0s", state_cov_file);
        end
      end
    end
  endtask

  task tb_finish;
    begin
      dump_cov;
      dump_state_cov;
      if (trace_fd != 0) begin
        $fclose(trace_fd);
        trace_fd = 0;
      end
      $finish;
    end
  endtask

  task uart_wait_clocks;
    input integer n;
    integer i;
    begin
      for (i = 0; i < n; i = i + 1)
        @(posedge clk);
    end
  endtask

  initial begin
    rtos_uart_mon = 0;
    rtos_uart_finish_on_pass = 0;
    rtos_trap_trace = 0;
    rtos_pass_seen = 0;
    uart_pass_window = {8*19{1'b0}};
    #1;
    if ($value$plusargs("RTOS_UART_MON=%d", rtos_uart_mon)) begin
      // optional UART monitor
    end
    if ($value$plusargs("RTOS_UART_FINISH_ON_PASS=%d", rtos_uart_finish_on_pass)) begin
      // optional early finish once an RTOS pass marker is decoded
    end
    if ($value$plusargs("RTOS_TRAP_TRACE=%d", rtos_trap_trace)) begin
      // optional RTOS trap/mret trace
    end

    forever begin
      @(negedge uart_tx);
      if (rtos_uart_mon != 0 && rst_n) begin
        uart_wait_clocks(UART_CLKS_PER_BIT + (UART_CLKS_PER_BIT / 2));
        for (uart_mon_bit = 0; uart_mon_bit < 8; uart_mon_bit = uart_mon_bit + 1) begin
          uart_mon_byte[uart_mon_bit] = uart_tx;
          uart_wait_clocks(UART_CLKS_PER_BIT);
        end
        $write("%c", uart_mon_byte);
        $fflush;
        if (uart_mon_byte == 8'h0A) begin
          if (rtos_pass_seen != 0) begin
            $display("PASS: RTOS UART observed pass marker");
            if (rtos_uart_finish_on_pass != 0)
              tb_finish;
          end
        end else if (uart_mon_byte != 8'h0D) begin
          uart_pass_window = {uart_pass_window[(8*18)-1:0], uart_mon_byte};
          if ((uart_pass_window[(8*15)-1:0] == "RTOS_SMOKE_PASS") ||
              (uart_pass_window == "RTOS_PREFLIGHT_PASS") ||
              (uart_pass_window[(8*18)-1:0] == "RTOS_PLATFORM_PASS") ||
              (uart_pass_window[(8*14)-1:0] == "LUA_RTOS_READY") ||
              (uart_pass_window[(8*9)-1:0] == "APP_READY")) begin
            rtos_pass_seen = 1;
          end
        end
      end
    end
  end

  assign l2_req_ready = USE_MIG ? 1'b0 : ~pending;

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
      // count line fills on the active I$ request channel
      if (mon_i_req_valid && mon_i_req_ready && (mon_i_req_cmd == 2'b00))
        linefill_cnt <= linefill_cnt + 1;
      if (USE_MIG) begin
        // In MIG mode, external TB L2 model is unused.
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
      end else begin
        // latch request
        if (l2_req_valid && l2_req_ready) begin
          pending      <= 1'b1;
          pending_uc   <= (l2_req_cmd == 2'b01);
          pending_addr <= l2_req_addr;
          pending_beat <= 4'd0;
          if (rand_mem_en != 0)
            i_delay_cnt  <= rand_mod_tb(rand_i_delay_max);
          else
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
  end

  // D$ L2 model (simple, always-ready)
  assign d_l2_req_ready = USE_MIG ? 1'b0 : 1'b1;

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
    end else if (USE_MIG) begin
      d_pending      <= 1'b0;
      d_rsp_type     <= 2'b00;
      d_rsp_addr     <= 32'b0;
      d_rsp_beat     <= 3'd0;
      d_wb_beat      <= 3'd0;
      d_delay_cnt    <= 0;
      d_err_armed    <= 1'b0;
      d_l2_rsp_valid <= 1'b0;
      d_l2_rsp_rdata <= 64'b0;
      d_l2_rsp_last  <= 1'b0;
      d_l2_rsp_err   <= 1'b0;
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
            if (rand_mem_en != 0)
              d_delay_cnt<= rand_mod_tb(rand_d_delay_max);
            else
              d_delay_cnt<= d_delay_cfg;
            d_err_armed<= d_err_once;
          end
          D_CMD_UC_RD: begin
            d_pending  <= 1'b1;
            d_rsp_type <= D_RSP_UC_RD;
            d_rsp_addr <= d_l2_req_addr;
            d_rsp_beat <= 3'd0;
            if (rand_mem_en != 0)
              d_delay_cnt<= rand_mod_tb(rand_d_delay_max);
            else
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
            if (rand_mem_en != 0)
              d_delay_cnt<= rand_mod_tb(rand_d_delay_max);
            else
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
              if (rand_mem_en != 0)
                d_delay_cnt<= rand_mod_tb(rand_d_delay_max);
              else
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
    rand_mem_en = 0;
    rand_seed = 32'h1A2B3C4D;
    rand_i_delay_max = 7;
    rand_d_delay_max = 7;
    assert_en = 1;
    stall_watchdog_max = 512;
    trace_en = 0;
    cov_en = 0;
    trace_file = "build_rv32/commit_trace.log";
    cov_file = "build_rv32/tb_coverage.txt";
    state_cov_en = 0;
    state_cov_file = "build_rv32/state_coverage.txt";
    trace_fd = 0;
    cov_fd = 0;
    state_cov_fd = 0;
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
      22: begin
        memfile = "TEST_FILES/mem_test22_branch_mem_mix.mem";
        expect_rd = 5'd8;
        expect_val = 32'h00000055;
        require_linefill = 1'b0;
        max_cycles = 10000;
      end
      23: begin
        memfile = "TEST_FILES/mem_test22_from_c.mem";
        expect_rd = 5'd8;
        expect_val = 32'h00000055;
        require_linefill = 1'b0;
        max_cycles = 20000;
      end
      24: begin
        memfile = "TEST_FILES/mem_test24_from_c.mem";
        expect_rd = 5'd8;
        expect_val = 32'h2400C0DE;
        require_linefill = 1'b0;
        max_cycles = 200000;
      end
      25: begin
        memfile = "TEST_FILES/mem_test25_all_instr_stress.mem";
        expect_rd = 5'd10;
        expect_val = 32'hDEAD25FF;
        require_linefill = 1'b0;
        max_cycles = 100000;
      end
      26: begin
        // Calibrated hash check from mem_test26_mixed_stress.
        // Program emits hash on x10 before entering terminal loop.
        memfile = "TEST_FILES/mem_test26_mixed_stress.mem";
        expect_rd = 5'd10;
        expect_val = 32'h2600C0DE;
        require_linefill = 1'b0;
        // This workload runs longer than the previous timeout on iverilog,
        // so keep a larger headroom to avoid false TIMEOUT failures.
        max_cycles = 220000;
      end
      27: begin
        // Full mixed stress (branch-delay-slot-safe variant).
        // Calibrated hash is emitted in x10 before terminal loop.
        memfile = "TEST_FILES/mem_test27_full_system_stress.mem";
        expect_rd = 5'd10;
        expect_val = 32'h2700C0DE;
        require_linefill = 1'b0;
        max_cycles = 150000;
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
    if ($value$plusargs("RAND_MEM=%d", rand_mem_en)) begin
      // randomize memory delay/ready behavior
    end
    if ($value$plusargs("SEED=%d", rand_seed)) begin
      // random seed override
    end
    if ($value$plusargs("RAND_I_MAX=%d", rand_i_delay_max)) begin
      // I$ model random response delay max
    end
    if ($value$plusargs("RAND_D_MAX=%d", rand_d_delay_max)) begin
      // D$ model random response delay max
    end
    if ($value$plusargs("ASSERT_EN=%d", assert_en)) begin
      // runtime assertion enable
    end
    if ($value$plusargs("STALL_WDOG=%d", stall_watchdog_max)) begin
      // req stall watchdog cycles
    end
    if ($value$plusargs("TRACE_EN=%d", trace_en)) begin
      // commit trace enable
    end
    if ($value$plusargs("TRACE_FILE=%s", trace_file)) begin
      // commit trace file path
    end
    if ($value$plusargs("COV_EN=%d", cov_en)) begin
      // coverage report enable
    end
    if ($value$plusargs("COV_FILE=%s", cov_file)) begin
      // coverage report file path
    end
    if ($value$plusargs("STATE_COV_EN=%d", state_cov_en)) begin
      // state-space coverage report enable
    end
    if ($value$plusargs("STATE_COV_FILE=%s", state_cov_file)) begin
      // state-space coverage report path
    end

    $display("[TB CFG] TEST=%0d MEMFILE=%0s EXPECT_RD=x%0d EXPECT_VAL=0x%08x MAXCYCLES=%0d",
             test_id, memfile, expect_rd, expect_val, max_cycles);
    $display("[TB CFG] USE_MIG=%0d RESET_PC=0x%08x MEM_WORDS=%0d",
             USE_MIG, RESET_PC, MEM_WORDS);
    $display("[TB CFG] RAND_MEM=%0d SEED=%0d RAND_I_MAX=%0d RAND_D_MAX=%0d ASSERT_EN=%0d STALL_WDOG=%0d",
             rand_mem_en, rand_seed, rand_i_delay_max, rand_d_delay_max, assert_en, stall_watchdog_max);
    $display("[TB CFG] TRACE_EN=%0d TRACE_FILE=%0s COV_EN=%0d COV_FILE=%0s",
             trace_en, trace_file, cov_en, cov_file);
    $display("[TB CFG] STATE_COV_EN=%0d STATE_COV_FILE=%0s",
             state_cov_en, state_cov_file);

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
    hold_i_req     = 1'b0;
    hold_i_addr    = 32'd0;
    hold_i_cmd     = 2'd0;
    hold_i_size    = 3'd0;
    hold_i_len     = 8'd0;
    hold_i_cycles  = 0;
    hold_d_req     = 1'b0;
    hold_d_addr    = 32'd0;
    hold_d_cmd     = 2'd0;
    hold_d_size    = 3'd0;
    hold_d_len     = 8'd0;
    hold_d_wdata   = 64'd0;
    hold_d_wstrb   = 8'd0;
    hold_d_cycles  = 0;
    hold_i_rsp     = 1'b0;
    hold_i_rsp_data= 64'd0;
    hold_i_rsp_last= 1'b0;
    hold_i_rsp_err = 1'b0;
    hold_i_rsp_cycles = 0;
    hold_d_rsp     = 1'b0;
    hold_d_rsp_data= 64'd0;
    hold_d_rsp_last= 1'b0;
    hold_d_rsp_err = 1'b0;
    hold_d_rsp_cycles = 0;
    cov_active_cycles = 0;
    cov_wb_commits = 0;
    cov_i_req_hs = 0;
    cov_d_req_hs = 0;
    cov_i_rsp_hs = 0;
    cov_d_rsp_hs = 0;
    cov_i_req_line = 0;
    cov_i_req_uc = 0;
    cov_i_req_other = 0;
    cov_d_req_line = 0;
    cov_d_req_uc_rd = 0;
    cov_d_req_uc_wr = 0;
    cov_d_req_wb = 0;
    cov_i_rsp_err = 0;
    cov_d_rsp_err = 0;
    cov_ifetch_err = 0;
    cov_max_i_req_stall = 0;
    cov_max_d_req_stall = 0;
    cov_max_i_rsp_stall = 0;
    cov_max_d_rsp_stall = 0;
    cov_i_rsp_stall_cur = 0;
    cov_d_rsp_stall_cur = 0;
    cov_ic_state_seen = 7'd0;
    cov_dc_state_seen = 12'd0;
    cov_l2_state_seen = 18'd0;
    cov_ic_dc_cross_seen = 84'd0;
    cov_ic_l2_cross_seen = 126'd0;
    cov_dc_l2_cross_seen = 216'd0;
    cov_ev_both_req_valid = 0;
    cov_ev_redirect_with_fetch_rsp = 0;
    cov_ev_iwait_and_drefill = 0;
    cov_ev_iwait_and_dwbwait = 0;
    cov_ev_l2_err_rsp = 0;
    cov_ev_l2_d_sel_with_i_req = 0;
    cov_ev_l2_i_sel_with_d_req = 0;
`ifdef SYNTHESIS
    tb_i_err_force_active = 1'b0;
    tb_i_err_injected     = 1'b0;
    tb_d_err_force_active = 1'b0;
    tb_d_err_injected     = 1'b0;
`endif

    if (trace_en != 0) begin
      trace_fd = $fopen(trace_file, "w");
      if (trace_fd == 0) begin
        $display("FATAL: cannot open TRACE_FILE=%0s", trace_file);
        tb_finish;
      end
      $fdisplay(trace_fd, "# cycle rd wdata");
    end

    for (mi = 0; mi < MEM_WORDS; mi = mi + 1)
      mem[mi] = 32'h00000013;
    if (!USE_MIG) begin
      resolve_tb_memfile(memfile, memfile_found);
      if (!memfile_found) begin
        $display("FATAL: cannot open MEMFILE=%0s", memfile);
        $display("Hint: Vivado xsim working dir may not contain TEST_FILES/. Use -testplusarg MEMFILE=<absolute-or-correct-relative-path>.");
        tb_finish;
      end
      $readmemh(memfile, mem);
    end

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

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      last_wb_cycle <= 0;
    else if (wb_we)
      last_wb_cycle <= cycles;
  end

  always @(posedge clk) begin
    if (rst_n && (cycles > max_cycles)) begin
      $display("TIMEOUT_STATE pc=0x%08x id_pc=0x%08x ex_pc=0x%08x mem_pc4=0x%08x core_running=%0d",
               dut.if_pc, dut.id_pc, dut.ex_pc, dut.mem_pc4, dut.core_running_o);
      $display("TIMEOUT_STATE stall if/id/ex/exmem=%0d/%0d/%0d/%0d redirect=%0d sys_flush=%0d",
               dut.stall_if, dut.stall_id, dut.stall_ex, dut.stall_exmem,
               dut.fe_redirect_valid, dut.sys_flush_now);
      $display("TIMEOUT_STATE ic_state=%0d dc_state=%0d if_pending=%0d fetch_req v/r=%0d/%0d fetch_rsp v/r=%0d/%0d",
               dut.u_icache.u_icache.state, dut.u_dcache.state, dut.if_pending,
               dut.fetch_req_valid, dut.fetch_req_ready,
               dut.fetch_resp_valid, dut.fetch_resp_if_ready);
      $display("TIMEOUT_STATE csr mtvec=0x%08x mepc=0x%08x mcause=0x%08x mstatus=0x%08x mie=0x%08x mip=0x%08x mscratch=0x%08x priv=%0d",
               dut.csr_mtvec_w, dut.csr_mepc_w, dut.csr_mcause_w, dut.csr_mstatus_w,
               dut.csr_mie_w, dut.csr_mip_w, dut.csr_mscratch_w, dut.csr_current_priv_w);
      $display("TIMEOUT_STATE irq request=%0d timer_pending=%0d soft_pending=%0d ext_pending=%0d global_mie=%0d mtie=%0d mtime=0x%08x_%08x mtimecmp=0x%08x_%08x",
               dut.irq_request_w, dut.irq_timer_pending_w, dut.irq_soft_pending_w, dut.irq_ext_pending_w,
               dut.csr_global_mie_w, dut.csr_mtie_en_w,
               dut.irq_mtime_hi_w, dut.irq_mtime_lo_w, dut.irq_mtimecmp_hi_w, dut.irq_mtimecmp_lo_w);
      $display("TIMEOUT_STATE regs ra=0x%08x sp=0x%08x t0=0x%08x t1=0x%08x t2=0x%08x s0=0x%08x a0=0x%08x",
               dut.u_id.u_rf.rf[1], dut.u_id.u_rf.rf[2], dut.u_id.u_rf.rf[5],
               dut.u_id.u_rf.rf[6], dut.u_id.u_rf.rf[7], dut.u_id.u_rf.rf[8],
               dut.u_id.u_rf.rf[10]);
      if (USE_MIG != 0) begin
        $display("TIMEOUT_STATE l2_state=%0d app en/rdy=%0d/%0d cmd=%0d addr=0x%08x rd_valid=%0d",
                 mig_l2_state_dbg,
                 mig_app_en_dbg, mig_app_rdy_dbg,
                 mig_app_cmd_dbg, mig_app_addr_dbg,
                 mig_app_rd_valid_dbg);
      end
      $display("TIMEOUT_STATE dmem req=%0d we=%0d addr=0x%08x ready=%0d rvalid=%0d rdata=0x%08x err=%0d",
               dut.dmem_req_o, dut.dmem_we_o, dut.dmem_addr_o,
               dut.dmem_ready_i, dut.dmem_rvalid_i, dut.dmem_rdata_i,
               dut.dmem_rsp_err_i);
      $display("TIMEOUT");
      tb_finish;
    end
  end

  always @(posedge clk) begin
    if (rst_n && (rtos_trap_trace != 0)) begin
      if (dut.csr_trap_enter_q) begin
        $display("[TRAP] cycle=%0d pc=0x%08x cause=0x%08x irq=%0d mstatus_before=0x%08x priv=%0d",
                 cycles, dut.csr_trap_pc_q, dut.csr_trap_cause_q,
                 dut.csr_trap_is_interrupt_q, dut.csr_mstatus_w, dut.csr_current_priv_w);
      end
      if (dut.csr_mret_exec_q) begin
        $display("[MRET] cycle=%0d mepc=0x%08x mstatus_after=0x%08x priv=%0d",
                 cycles, dut.csr_mepc_w, dut.csr_mstatus_w, dut.csr_current_priv_w);
      end
    end
  end

`ifdef SYNTHESIS
  // In -DSYNTHESIS simulations, l2_cache_top debug injectors are compiled as wires.
  // Force them from TB so test15/test16 still exercise real DUT error paths in MIG mode.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tb_i_err_force_active <= 1'b0;
      tb_i_err_injected     <= 1'b0;
      tb_d_err_force_active <= 1'b0;
      tb_d_err_injected     <= 1'b0;
      if (USE_MIG) begin
        release dut.GEN_MIG.u_l2.dbg_i_err_once;
        release dut.GEN_MIG.u_l2.dbg_d_err_once;
      end
    end else if (USE_MIG) begin
      if (i_err_once && !tb_i_err_injected && !tb_i_err_force_active) begin
        force dut.GEN_MIG.u_l2.dbg_i_err_once = 1'b1;
        tb_i_err_force_active <= 1'b1;
      end
      if (d_err_once && !tb_d_err_injected && !tb_d_err_force_active) begin
        force dut.GEN_MIG.u_l2.dbg_d_err_once = 1'b1;
        tb_d_err_force_active <= 1'b1;
      end

      if (tb_i_err_force_active &&
          dut.GEN_MIG.u_l2.sel_busy && !dut.GEN_MIG.u_l2.sel_is_d &&
          dut.GEN_MIG.u_l2.core_rsp_valid && dut.GEN_MIG.u_l2.core_rsp_ready) begin
        release dut.GEN_MIG.u_l2.dbg_i_err_once;
        tb_i_err_force_active <= 1'b0;
        tb_i_err_injected     <= 1'b1;
      end

      if (tb_d_err_force_active &&
          dut.GEN_MIG.u_l2.sel_busy && dut.GEN_MIG.u_l2.sel_is_d &&
          dut.GEN_MIG.u_l2.core_rsp_valid && dut.GEN_MIG.u_l2.core_rsp_ready) begin
        release dut.GEN_MIG.u_l2.dbg_d_err_once;
        tb_d_err_force_active <= 1'b0;
        tb_d_err_injected     <= 1'b1;
      end
    end
  end
`endif

  // PASS/FAIL conditions
  always @(posedge clk) begin
    if (rst_n && ifetch_err) begin
      if (test_id == 15) begin
        $display("PASS: test 15 I$ error observed");
      end else begin
        $display("I$ fetch error -> FAIL");
      end
      tb_finish;
    end
    if (rst_n && (test_id == 16) && (mon_d_rsp_valid && mon_d_rsp_err)) begin
      $display("PASS: test 16 D$ error observed");
      tb_finish;
    end
    if (rst_n && wb_we) begin
      cov_wb_commits <= cov_wb_commits + 1;
      if ((trace_en != 0) && (trace_fd != 0))
        $fdisplay(trace_fd, "%0d %0d %08x", cycles, wb_rd, wb_wdata);
`ifdef PIPE_TRACE
        $display("WB: x%0d <= 0x%08x", wb_rd, wb_wdata);
`endif
      if ((wb_rd == expect_rd) && (wb_wdata == expect_val)) begin
        if (require_linefill && (linefill_cnt == 0)) begin
          $display("FAIL: no I$ linefill observed");
          tb_finish;
        end
        $display("PASS: test %0d expect x%0d = 0x%08x", test_id, expect_rd, expect_val);
        tb_finish;
      end
    end
  end

  // Coverage counters and optional commit trace.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cov_active_cycles <= 0;
      cov_i_rsp_stall_cur <= 0;
      cov_d_rsp_stall_cur <= 0;
    end else begin
      cov_active_cycles <= cov_active_cycles + 1;

      if (ifetch_err)
        cov_ifetch_err <= cov_ifetch_err + 1;

      if (mon_i_req_valid && mon_i_req_ready) begin
        cov_i_req_hs <= cov_i_req_hs + 1;
        case (mon_i_req_cmd)
          2'b00: cov_i_req_line <= cov_i_req_line + 1;
          2'b01: cov_i_req_uc   <= cov_i_req_uc + 1;
          default: cov_i_req_other <= cov_i_req_other + 1;
        endcase
      end

      if (mon_d_req_valid && mon_d_req_ready) begin
        cov_d_req_hs <= cov_d_req_hs + 1;
        case (mon_d_req_cmd)
          2'b00: cov_d_req_line  <= cov_d_req_line + 1;
          2'b01: cov_d_req_uc_rd <= cov_d_req_uc_rd + 1;
          2'b10: cov_d_req_uc_wr <= cov_d_req_uc_wr + 1;
          2'b11: cov_d_req_wb    <= cov_d_req_wb + 1;
        endcase
      end

      if (mon_i_rsp_valid && mon_i_rsp_ready) begin
        cov_i_rsp_hs <= cov_i_rsp_hs + 1;
        if (mon_i_rsp_err)
          cov_i_rsp_err <= cov_i_rsp_err + 1;
      end

      if (mon_d_rsp_valid && mon_d_rsp_ready) begin
        cov_d_rsp_hs <= cov_d_rsp_hs + 1;
        if (mon_d_rsp_err)
          cov_d_rsp_err <= cov_d_rsp_err + 1;
      end

      if (mon_i_req_valid && !mon_i_req_ready) begin
        if ((hold_i_cycles + 1) > cov_max_i_req_stall)
          cov_max_i_req_stall <= hold_i_cycles + 1;
      end
      if (mon_d_req_valid && !mon_d_req_ready) begin
        if ((hold_d_cycles + 1) > cov_max_d_req_stall)
          cov_max_d_req_stall <= hold_d_cycles + 1;
      end

      if (mon_i_rsp_valid && !mon_i_rsp_ready) begin
        cov_i_rsp_stall_cur <= cov_i_rsp_stall_cur + 1;
        if ((cov_i_rsp_stall_cur + 1) > cov_max_i_rsp_stall)
          cov_max_i_rsp_stall <= cov_i_rsp_stall_cur + 1;
      end else begin
        cov_i_rsp_stall_cur <= 0;
      end

      if (mon_d_rsp_valid && !mon_d_rsp_ready) begin
        cov_d_rsp_stall_cur <= cov_d_rsp_stall_cur + 1;
        if ((cov_d_rsp_stall_cur + 1) > cov_max_d_rsp_stall)
          cov_max_d_rsp_stall <= cov_d_rsp_stall_cur + 1;
      end else begin
        cov_d_rsp_stall_cur <= 0;
      end
    end
  end

  // Optional state-space coverage: FSM state hits + cross-state hits + rare contention events.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cov_ic_state_seen <= 7'd0;
      cov_dc_state_seen <= 12'd0;
      cov_l2_state_seen <= 18'd0;
      cov_ic_dc_cross_seen <= 84'd0;
      cov_ic_l2_cross_seen <= 126'd0;
      cov_dc_l2_cross_seen <= 216'd0;
      cov_ev_both_req_valid <= 0;
      cov_ev_redirect_with_fetch_rsp <= 0;
      cov_ev_iwait_and_drefill <= 0;
      cov_ev_iwait_and_dwbwait <= 0;
      cov_ev_l2_err_rsp <= 0;
      cov_ev_l2_d_sel_with_i_req <= 0;
      cov_ev_l2_i_sel_with_d_req <= 0;
    end else begin
      if (cov_ic_state_cur <= 3'd6)
        cov_ic_state_seen[cov_ic_state_cur] <= 1'b1;
      if (cov_dc_state_cur <= 4'd11)
        cov_dc_state_seen[cov_dc_state_cur] <= 1'b1;
      if (cov_l2_state_cur <= 5'd17)
        cov_l2_state_seen[cov_l2_state_cur] <= 1'b1;

      if ((cov_ic_state_cur <= 3'd6) && (cov_dc_state_cur <= 4'd11))
        cov_ic_dc_cross_seen[(cov_ic_state_cur * 12) + cov_dc_state_cur] <= 1'b1;
      if ((cov_ic_state_cur <= 3'd6) && (cov_l2_state_cur <= 5'd17))
        cov_ic_l2_cross_seen[(cov_ic_state_cur * 18) + cov_l2_state_cur] <= 1'b1;
      if ((cov_dc_state_cur <= 4'd11) && (cov_l2_state_cur <= 5'd17))
        cov_dc_l2_cross_seen[(cov_dc_state_cur * 18) + cov_l2_state_cur] <= 1'b1;

      if (mon_i_req_valid && mon_d_req_valid)
        cov_ev_both_req_valid <= cov_ev_both_req_valid + 1;
      if (dut.fe_redirect_valid && dut.fetch_resp_valid)
        cov_ev_redirect_with_fetch_rsp <= cov_ev_redirect_with_fetch_rsp + 1;
      if ((cov_ic_state_cur == 3'd2) && (cov_dc_state_cur == 4'd8))
        cov_ev_iwait_and_drefill <= cov_ev_iwait_and_drefill + 1;
      if ((cov_ic_state_cur == 3'd2) && (cov_dc_state_cur == 4'd6))
        cov_ev_iwait_and_dwbwait <= cov_ev_iwait_and_dwbwait + 1;
      if (cov_l2_state_cur == 5'd17)
        cov_ev_l2_err_rsp <= cov_ev_l2_err_rsp + 1;
      if ((USE_MIG != 0) && mig_l2_sel_busy_dbg && mig_l2_sel_is_d_dbg && mon_i_req_valid)
        cov_ev_l2_d_sel_with_i_req <= cov_ev_l2_d_sel_with_i_req + 1;
      if ((USE_MIG != 0) && mig_l2_sel_busy_dbg && !mig_l2_sel_is_d_dbg && mon_d_req_valid)
        cov_ev_l2_i_sel_with_d_req <= cov_ev_l2_i_sel_with_d_req + 1;
    end
  end

  // Runtime assertions for request-channel stability and forward progress.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hold_i_req    <= 1'b0;
      hold_i_cycles <= 0;
      hold_d_req    <= 1'b0;
      hold_d_cycles <= 0;
      hold_i_rsp    <= 1'b0;
      hold_i_rsp_cycles <= 0;
      hold_d_rsp    <= 1'b0;
      hold_d_rsp_cycles <= 0;
    end else begin
      // I$ request must be stable while stalled.
      if (mon_i_req_valid && !mon_i_req_ready) begin
        if (!hold_i_req) begin
          hold_i_req   <= 1'b1;
          hold_i_addr  <= mon_i_req_addr;
          hold_i_cmd   <= mon_i_req_cmd;
          hold_i_size  <= mon_i_req_size;
          hold_i_len   <= mon_i_req_len;
          hold_i_cycles<= 1;
        end else begin
          hold_i_cycles <= hold_i_cycles + 1;
          if (assert_en != 0) begin
            if ((mon_i_req_addr != hold_i_addr) ||
                (mon_i_req_cmd  != hold_i_cmd)  ||
                (mon_i_req_size != hold_i_size) ||
                (mon_i_req_len  != hold_i_len)) begin
              $display("ASSERT_FAIL: I req changed while stalled at cycle=%0d", cycles);
              tb_finish;
            end
            if (hold_i_cycles > stall_watchdog_max) begin
              $display("ASSERT_FAIL: I req stalled too long (%0d cycles)", hold_i_cycles);
              tb_finish;
            end
          end
        end
      end else begin
        hold_i_req    <= 1'b0;
        hold_i_cycles <= 0;
      end

      // D$ request must be stable while stalled.
      if (mon_d_req_valid && !mon_d_req_ready) begin
        if (!hold_d_req) begin
          hold_d_req    <= 1'b1;
          hold_d_addr   <= mon_d_req_addr;
          hold_d_cmd    <= mon_d_req_cmd;
          hold_d_size   <= mon_d_req_size;
          hold_d_len    <= mon_d_req_len;
          hold_d_wdata  <= mon_d_req_wdata;
          hold_d_wstrb  <= mon_d_req_wstrb;
          hold_d_cycles <= 1;
        end else begin
          hold_d_cycles <= hold_d_cycles + 1;
          if (assert_en != 0) begin
            if ((mon_d_req_addr  != hold_d_addr)  ||
                (mon_d_req_cmd   != hold_d_cmd)   ||
                (mon_d_req_size  != hold_d_size)  ||
                (mon_d_req_len   != hold_d_len)   ||
                (mon_d_req_wdata != hold_d_wdata) ||
                (mon_d_req_wstrb != hold_d_wstrb)) begin
              $display("ASSERT_FAIL: D req changed while stalled at cycle=%0d", cycles);
              tb_finish;
            end
            if (hold_d_cycles > stall_watchdog_max) begin
              $display("ASSERT_FAIL: D req stalled too long (%0d cycles)", hold_d_cycles);
              tb_finish;
            end
          end
        end
      end else begin
        hold_d_req    <= 1'b0;
        hold_d_cycles <= 0;
      end

      // I$ response must be stable while stalled.
      if (mon_i_rsp_valid && !mon_i_rsp_ready) begin
        if (!hold_i_rsp) begin
          hold_i_rsp       <= 1'b1;
          hold_i_rsp_data  <= mon_i_rsp_data;
          hold_i_rsp_last  <= mon_i_rsp_last;
          hold_i_rsp_err   <= mon_i_rsp_err;
          hold_i_rsp_cycles<= 1;
        end else begin
          hold_i_rsp_cycles <= hold_i_rsp_cycles + 1;
          if (assert_en != 0) begin
            if ((mon_i_rsp_data != hold_i_rsp_data) ||
                (mon_i_rsp_last != hold_i_rsp_last) ||
                (mon_i_rsp_err  != hold_i_rsp_err)) begin
              $display("ASSERT_FAIL: I rsp changed while stalled at cycle=%0d", cycles);
              tb_finish;
            end
            if (hold_i_rsp_cycles > stall_watchdog_max) begin
              $display("ASSERT_FAIL: I rsp stalled too long (%0d cycles)", hold_i_rsp_cycles);
              tb_finish;
            end
          end
        end
      end else begin
        hold_i_rsp       <= 1'b0;
        hold_i_rsp_cycles<= 0;
      end

      // D$ response must be stable while stalled.
      if (mon_d_rsp_valid && !mon_d_rsp_ready) begin
        if (!hold_d_rsp) begin
          hold_d_rsp       <= 1'b1;
          hold_d_rsp_data  <= mon_d_rsp_rdata;
          hold_d_rsp_last  <= mon_d_rsp_last;
          hold_d_rsp_err   <= mon_d_rsp_err;
          hold_d_rsp_cycles<= 1;
        end else begin
          hold_d_rsp_cycles <= hold_d_rsp_cycles + 1;
          if (assert_en != 0) begin
            if ((mon_d_rsp_rdata != hold_d_rsp_data) ||
                (mon_d_rsp_last  != hold_d_rsp_last) ||
                (mon_d_rsp_err   != hold_d_rsp_err)) begin
              $display("ASSERT_FAIL: D rsp changed while stalled at cycle=%0d", cycles);
              tb_finish;
            end
            if (hold_d_rsp_cycles > stall_watchdog_max) begin
              $display("ASSERT_FAIL: D rsp stalled too long (%0d cycles)", hold_d_rsp_cycles);
              tb_finish;
            end
          end
        end
      end else begin
        hold_d_rsp       <= 1'b0;
        hold_d_rsp_cycles<= 0;
      end
    end
  end

  // Hang watchdog: print key internal state when no WB for a long window.
  always @(posedge clk) begin
    if (rst_n && (rtos_uart_mon == 0) && ((cycles - last_wb_cycle) == 2000)) begin
      $display("[DBG] no WB for 2000 cycles at cycle=%0d", cycles);
      $display("[DBG] ic_l2 i_req v/r=%0d/%0d i_rsp v/r=%0d/%0d",
               mon_i_req_valid, mon_i_req_ready,
               mon_i_rsp_valid, mon_i_rsp_ready);
      $display("[DBG] dc_l2 d_req v/r=%0d/%0d d_rsp v/r=%0d/%0d",
               mon_d_req_valid, mon_d_req_ready,
               mon_d_rsp_valid, mon_d_rsp_ready);
      $display("[DBG] wb_we=%0d wb_rd=%0d wb_wdata=0x%08x ifetch_err=%0d boot_done=%0d",
               wb_we, wb_rd, wb_wdata, ifetch_err, boot_done);
`ifndef SYNTHESIS
`ifdef TB_DEEP_DBG
      $display("[DBG] if_pc=0x%08x if_pending=%0d stall_if=%0d stall_id=%0d stall_ex=%0d stall_exmem=%0d",
               dut.if_pc, dut.if_pending, dut.stall_if, dut.stall_id, dut.stall_ex, dut.stall_exmem);
      $display("[DBG] fetch_req v/r=%0d/%0d fetch_rsp v/r=%0d/%0d req_blocked=%0d resp_blocked=%0d",
               dut.fetch_req_valid, dut.fetch_req_ready,
               dut.fetch_resp_valid, dut.fetch_resp_if_ready,
               dut.req_blocked, dut.resp_blocked);
      $display("[DBG] redirect=%0d fetch_kill=%0d ex_valid=%0d ex_pc=0x%08x",
               dut.redirect_valid, dut.fetch_req_kill, dut.ex_valid, dut.ex_pc);
      $display("[DBG] ic_state=%0d if_req v/r/k=%0d/%0d/%0d if_resp v/r=%0d/%0d s1_v=%0d s2_v=%0d",
               dut.u_icache.u_icache.state,
               dut.u_icache.u_icache.if_req_valid,
               dut.u_icache.u_icache.if_req_ready,
               dut.u_icache.u_icache.if_req_kill,
               dut.u_icache.u_icache.if_resp_valid,
               dut.u_icache.u_icache.if_resp_ready,
               dut.u_icache.u_icache.s1_valid,
               dut.u_icache.u_icache.s2_valid);
      $display("[DBG] ic_accept=%0d kill_prev=%0d kill_toggle=%0d drop_resp=%0d",
               dut.u_icache.u_icache.accept_req,
               dut.u_icache.u_icache.kill_prev,
               dut.u_icache.u_icache.kill_toggle,
               dut.u_icache.u_icache.drop_resp);
      $display("[DBG] mem_stall=%0d dmem_req=%0d dcache_req_ready=%0d dcache_rsp_valid=%0d",
               dut.mem_stall, dut.dmem_req_o, dut.dcache_cpu_req_ready, dut.dcache_cpu_rsp_valid);
      if (USE_MIG) begin
        $display("[DBG] l2_state=%0d mig_beat=%0d app en/rdy=%0d/%0d cmd=%0d addr=0x%08x rd_valid=%0d init=%0d ui_rst=%0d memtest_active=%0d",
                 dut.GEN_MIG.u_l2.u_core.state,
                 dut.GEN_MIG.u_l2.u_core.mig_beat_cnt,
                 dut.GEN_MIG.app_en, dut.GEN_MIG.app_rdy,
                 dut.GEN_MIG.app_cmd, dut.GEN_MIG.app_addr,
                 dut.GEN_MIG.app_rd_data_valid,
                 dut.init_calib_complete,
                 dut.ui_clk_sync_rst,
                 dut.GEN_MIG.memtest_active_w);
      end
`endif
`endif
    end
  end

`ifndef SYNTHESIS
`ifdef TB_DEEP_DBG
  // Early front-end trace for pinpointing duplicated fetch/issue.
  always @(posedge clk) begin
    if (rst_n && (test_id == 24) && (cycles >= 35) && (cycles <= 80)) begin
      $display("[DBGIF] cyc=%0d pc=%08x pend=%0d st_if/id/ex=%0d/%0d/%0d req_v/r=%0d/%0d rsp_v/r=%0d/%0d id_v=%0d id_pc=%08x",
               cycles, dut.if_pc, dut.if_pending,
               dut.stall_if, dut.stall_id, dut.stall_ex,
               dut.fetch_req_valid, dut.fetch_req_ready,
               dut.fetch_resp_valid, dut.fetch_resp_if_ready,
               dut.id_valid, dut.id_pc);
      $display("[DBGIC] cyc=%0d ic_state=%0d s1_v=%0d s1_pc=%08x s2_v=%0d s2_pc=%08x acc=%0d if_resp_v/r=%0d/%0d",
               cycles, dut.u_icache.u_icache.state,
               dut.u_icache.u_icache.s1_valid, dut.u_icache.u_icache.s1_pc,
               dut.u_icache.u_icache.s2_valid, dut.u_icache.u_icache.s2_pc,
               dut.u_icache.u_icache.accept_req,
               dut.u_icache.u_icache.if_resp_valid, dut.u_icache.u_icache.if_resp_ready);
    end
  end

  // Focus debug for test27 outer-loop exit compare:
  // beq x16, x5 at PC=0x800001e0
  always @(posedge clk) begin
    if (rst_n && (test_id == 27) && dut.ex_valid && (dut.ex_pc == 32'h800001e0)) begin
      $display("[DBG27] ex_pc=0x%08x rs1(x16)=0x%08x rs2(x5)=0x%08x redirect=%0d",
               dut.ex_pc, dut.ex_rs1_val_fwd, dut.ex_rs2_val_fwd, dut.redirect_valid);
    end
    if (rst_n && (test_id == 27) && dut.ex_valid &&
        ((dut.ex_pc == 32'h80000330) || (dut.ex_pc == 32'h80000360) || (dut.ex_pc == 32'h80000390))) begin
      $display("[DBG27L] ex_pc=0x%08x rs1=0x%08x rs2=0x%08x redirect=%0d flush_ifid=%0d flush_idex=%0d stall_if=%0d stall_id=%0d stall_ex=%0d",
               dut.ex_pc, dut.ex_rs1_val_fwd, dut.ex_rs2_val_fwd, dut.redirect_valid,
               dut.flush_ifid, dut.flush_idex, dut.stall_if, dut.stall_id, dut.stall_ex);
    end
  end

`endif
`endif

endmodule

// ----------------------------------------------------------------------------
// Simplified MIG model for simulation (used by MIG_DDR2_interface wrapper).
// - app_addr is a byte-domain offset from DDR base, aligned to 16 bytes
// - app_cmd: 3'b001 read, 3'b000 write
// - app_wdf_mask: 1=mask (no write), 0=write
// - Fixed 2-cycle read latency, always-ready interface
// ----------------------------------------------------------------------------
module mig_7series_0_mig (
  output [12:0]                       ddr2_addr,
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
  input  [26:0]                       app_addr,
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
  input                               sys_clk_i,
  input                               clk_ref_i,
  output [11:0]                       device_temp,
  input                               sys_rst
);
  localparam integer MEM_BYTES = 1<<20;
  localparam integer MEM_WORDS = MEM_BYTES/4;
  localparam [2:0] CMD_READ  = 3'b001;
  localparam [2:0] CMD_WRITE = 3'b000;

  reg [7:0] mem_b [0:MEM_BYTES-1];
  reg [31:0] init_mem [0:MEM_WORDS-1];
  reg [8*1024-1:0] memfile;
  reg [8*1024-1:0] memfile_base;
  reg [8*1024-1:0] memfile_try;
  reg             memfile_found;
  reg             memfile_is_plusarg;
  integer         rand_mem_en;
  integer         rand_seed;
  integer         rand_bp_pct;
  integer         assert_en;
  integer         rd_accepted;
  integer         rd_returned;
  integer         rd_silence;
  integer         rd_watchdog_max;
  integer         not_ready_streak;
  reg             rand_ready_bit;
  integer wi;
  integer test_id_mig;
  integer mig_memfile_fd;

  function integer rand_mod_mig;
    input integer maxv;
    integer r;
    begin
      if (maxv <= 0) begin
        rand_mod_mig = 0;
      end else begin
        r = $random(rand_seed);
        if (r < 0)
          r = -r;
        rand_mod_mig = r % (maxv + 1);
      end
    end
  endfunction

  task resolve_mig_memfile;
    inout [8*1024-1:0] path_io;
    input [8*1024-1:0]  base_io;
    input             skip_fallback_i;
    output            found_o;
    integer           fd_local;
    begin
      found_o = 1'b0;
      memfile_try = path_io;
      fd_local = $fopen(memfile_try, "r");
      if (fd_local == 0) begin
        $sformat(memfile_try, "./%0s", path_io);
        fd_local = $fopen(memfile_try, "r");
      end
      if (fd_local == 0) begin
        $sformat(memfile_try, "../%0s", path_io);
        fd_local = $fopen(memfile_try, "r");
      end
      if (fd_local == 0) begin
        $sformat(memfile_try, "../../%0s", path_io);
        fd_local = $fopen(memfile_try, "r");
      end
      if (fd_local == 0) begin
        $sformat(memfile_try, "../../../%0s", path_io);
        fd_local = $fopen(memfile_try, "r");
      end
      if (fd_local == 0) begin
        $sformat(memfile_try, "../../../../%0s", path_io);
        fd_local = $fopen(memfile_try, "r");
      end
      if (fd_local == 0) begin
        $sformat(memfile_try, "../../../../../%0s", path_io);
        fd_local = $fopen(memfile_try, "r");
      end
      if (fd_local == 0) begin
        $sformat(memfile_try, "../../../../../../%0s", path_io);
        fd_local = $fopen(memfile_try, "r");
      end
      if ((fd_local == 0) && !skip_fallback_i && (base_io != 0)) begin
        memfile_try = base_io;
        fd_local = $fopen(memfile_try, "r");
      end
      if ((fd_local == 0) && !skip_fallback_i && (base_io != 0)) begin
        $sformat(memfile_try, "./%0s", base_io);
        fd_local = $fopen(memfile_try, "r");
      end
      if ((fd_local == 0) && !skip_fallback_i && (base_io != 0)) begin
        $sformat(memfile_try, "TEST_FILES/%0s", base_io);
        fd_local = $fopen(memfile_try, "r");
      end
      if ((fd_local == 0) && !skip_fallback_i && (base_io != 0)) begin
        $sformat(memfile_try, "./TEST_FILES/%0s", base_io);
        fd_local = $fopen(memfile_try, "r");
      end
      if ((fd_local == 0) && !skip_fallback_i && (base_io != 0)) begin
        $sformat(memfile_try, "../TEST_FILES/%0s", base_io);
        fd_local = $fopen(memfile_try, "r");
      end
      if ((fd_local == 0) && !skip_fallback_i && (base_io != 0)) begin
        $sformat(memfile_try, "../../TEST_FILES/%0s", base_io);
        fd_local = $fopen(memfile_try, "r");
      end
      if ((fd_local == 0) && !skip_fallback_i && (base_io != 0)) begin
        $sformat(memfile_try, "../../../TEST_FILES/%0s", base_io);
        fd_local = $fopen(memfile_try, "r");
      end
      if ((fd_local == 0) && !skip_fallback_i && (base_io != 0)) begin
        $sformat(memfile_try, "../../../../TEST_FILES/%0s", base_io);
        fd_local = $fopen(memfile_try, "r");
      end
      if ((fd_local == 0) && !skip_fallback_i && (base_io != 0)) begin
        $sformat(memfile_try, "../../../../../TEST_FILES/%0s", base_io);
        fd_local = $fopen(memfile_try, "r");
      end
      if ((fd_local == 0) && !skip_fallback_i && (base_io != 0)) begin
        $sformat(memfile_try, "../../../../../../TEST_FILES/%0s", base_io);
        fd_local = $fopen(memfile_try, "r");
      end
      if (fd_local != 0) begin
        $fclose(fd_local);
        path_io = memfile_try;
        found_o = 1'b1;
      end
    end
  endtask

  task try_mig_candidate;
    input [8*1024-1:0] cand_i;
    inout              found_io;
    begin
      if (!found_io) begin
        mig_memfile_fd = $fopen(cand_i, "r");
        if (mig_memfile_fd != 0) begin
          $fclose(mig_memfile_fd);
          memfile = cand_i;
          found_io = 1'b1;
        end
      end
    end
  endtask

  // DDR2 pins are unused in this model
  assign ddr2_addr    = 13'd0;
  assign ddr2_ba      = 3'd0;
  assign ddr2_cas_n   = 1'b1;
  assign ddr2_ck_n    = 1'b0;
  assign ddr2_ck_p    = 1'b0;
  assign ddr2_cke     = 1'b0;
  assign ddr2_ras_n   = 1'b1;
  assign ddr2_we_n    = 1'b1;
  assign ddr2_cs_n    = 1'b1;
  assign ddr2_dm      = 2'b00;
  assign ddr2_odt     = 1'b0;
  assign ddr2_dq      = 16'hzzzz;
  assign ddr2_dqs_n   = 2'bzz;
  assign ddr2_dqs_p   = 2'bzz;
  assign device_temp  = 12'd0;

  // Use sys_clk_i as UI clock
  assign ui_clk = sys_clk_i;
  assign init_calib_complete = sys_rst;

  initial begin
    // Wait one tick so top TB can finish its own TEST/MEMFILE selection.
    #1;
    rand_mem_en = 0;
    rand_seed = 32'h1A2B3C4D;
    rand_bp_pct = 20;
    assert_en = 1;
    rd_watchdog_max = 256;
    if ($value$plusargs("RAND_MEM=%d", rand_mem_en)) begin
      // random ready/backpressure mode
    end
    if ($value$plusargs("SEED=%d", rand_seed)) begin
      // random seed override
    end
    if ($value$plusargs("RAND_BP_PCT=%d", rand_bp_pct)) begin
      // percentage [0..100] for app_rdy/app_wdf_rdy to be deasserted
    end
    if ($value$plusargs("ASSERT_EN=%d", assert_en)) begin
      // runtime assertion switch
    end
    if ($value$plusargs("RD_WDOG=%d", rd_watchdog_max)) begin
      // read-return watchdog
    end
    if (rand_bp_pct < 0)
      rand_bp_pct = 0;
    if (rand_bp_pct > 95)
      rand_bp_pct = 95;

    memfile = "program_ddr.mem";
    memfile_base = "program_ddr.mem";
    memfile_is_plusarg = 1'b0;
    if ($value$plusargs("MEMFILE=%s", memfile)) begin
      // override
      memfile_is_plusarg = 1'b1;
    end else begin
      test_id_mig = 0;
      if ($value$plusargs("TEST=%d", test_id_mig)) begin
        case (test_id_mig)
          1:  begin memfile = "TEST_FILES/mem_test1_alu_fwd.mem";          memfile_base = "mem_test1_alu_fwd.mem"; end
          2:  begin memfile = "TEST_FILES/mem_test2_load_use.mem";         memfile_base = "mem_test2_load_use.mem"; end
          3:  begin memfile = "TEST_FILES/mem_test3_store_dep.mem";        memfile_base = "mem_test3_store_dep.mem"; end
          4:  begin memfile = "TEST_FILES/mem_test4_branch_taken.mem";     memfile_base = "mem_test4_branch_taken.mem"; end
          5:  begin memfile = "TEST_FILES/mem_test5_load_store.mem";       memfile_base = "mem_test5_load_store.mem"; end
          6:  begin memfile = "TEST_FILES/mem_test6_branch_not_taken.mem"; memfile_base = "mem_test6_branch_not_taken.mem"; end
          7:  begin memfile = "TEST_FILES/mem_test7_jal.mem";              memfile_base = "mem_test7_jal.mem"; end
          8:  begin memfile = "TEST_FILES/mem_test8_jalr.mem";             memfile_base = "mem_test8_jalr.mem"; end
          9:  begin memfile = "TEST_FILES/mem_test9_lb_sb.mem";            memfile_base = "mem_test9_lb_sb.mem"; end
          10: begin memfile = "TEST_FILES/mem_test10_lhu_sh.mem";          memfile_base = "mem_test10_lhu_sh.mem"; end
          11: begin memfile = "TEST_FILES/mem_test11_long_mix.mem";        memfile_base = "mem_test11_long_mix.mem"; end
          12: begin memfile = "TEST_FILES/mem_test12_long_mem.mem";        memfile_base = "mem_test12_long_mem.mem"; end
          13: begin memfile = "TEST_FILES/mem_test13_stress.mem";          memfile_base = "mem_test13_stress.mem"; end
          14: begin memfile = "TEST_FILES/mem_test14_id_miss.mem";         memfile_base = "mem_test14_id_miss.mem"; end
          15: begin memfile = "TEST_FILES/mem_test1_alu_fwd.mem";          memfile_base = "mem_test1_alu_fwd.mem"; end
          16: begin memfile = "TEST_FILES/mem_test5_load_store.mem";       memfile_base = "mem_test5_load_store.mem"; end
          17: begin memfile = "TEST_FILES/mem_test17_icache_stress.mem";   memfile_base = "mem_test17_icache_stress.mem"; end
          18: begin memfile = "TEST_FILES/mem_test18_dcache_wb.mem";       memfile_base = "mem_test18_dcache_wb.mem"; end
          19: begin memfile = "TEST_FILES/mem_test19_hazard_branch.mem";   memfile_base = "mem_test19_hazard_branch.mem"; end
          20: begin memfile = "TEST_FILES/mem_test20_long_mix.mem";        memfile_base = "mem_test20_long_mix.mem"; end
          21: begin memfile = "TEST_FILES/mem_test21_long_branch.mem";     memfile_base = "mem_test21_long_branch.mem"; end
          22: begin memfile = "TEST_FILES/mem_test22_branch_mem_mix.mem";  memfile_base = "mem_test22_branch_mem_mix.mem"; end
          23: begin memfile = "TEST_FILES/mem_test22_from_c.mem";          memfile_base = "mem_test22_from_c.mem"; end
          24: begin memfile = "TEST_FILES/mem_test24_from_c.mem";          memfile_base = "mem_test24_from_c.mem"; end
          25: begin memfile = "TEST_FILES/mem_test25_all_instr_stress.mem"; memfile_base = "mem_test25_all_instr_stress.mem"; end
          26: begin memfile = "TEST_FILES/mem_test26_mixed_stress.mem";    memfile_base = "mem_test26_mixed_stress.mem"; end
          27: begin memfile = "TEST_FILES/mem_test27_full_system_stress.mem"; memfile_base = "mem_test27_full_system_stress.mem"; end
          default: begin memfile = "program_ddr.mem"; memfile_base = "program_ddr.mem"; end
        endcase
      end else begin
        // Some simulators may not allow reading the same plusarg twice.
        // Use a local default fallback when no plusarg is visible here.
        memfile = "TEST_FILES/program_ddr.mem";
        memfile_base = "program_ddr.mem";
      end
    end
    resolve_mig_memfile(memfile, memfile_base, memfile_is_plusarg, memfile_found);
    if (!memfile_found && !memfile_is_plusarg) begin
      // Retry with local default path when simulator cwd differs.
      memfile = "TEST_FILES/program_ddr.mem";
      memfile_base = "program_ddr.mem";
      resolve_mig_memfile(memfile, memfile_base, 1'b1, memfile_found);
    end
    if (!memfile_found && !memfile_is_plusarg) begin
      // Explicit fallback paths for regression tests 24..27 in deep sim workdirs.
      case (test_id_mig)
        24: begin
          try_mig_candidate("TEST_FILES/mem_test24_from_c.mem", memfile_found);
          try_mig_candidate("./TEST_FILES/mem_test24_from_c.mem", memfile_found);
          try_mig_candidate("../TEST_FILES/mem_test24_from_c.mem", memfile_found);
          try_mig_candidate("../../TEST_FILES/mem_test24_from_c.mem", memfile_found);
          try_mig_candidate("../../../TEST_FILES/mem_test24_from_c.mem", memfile_found);
          try_mig_candidate("../../../../TEST_FILES/mem_test24_from_c.mem", memfile_found);
          try_mig_candidate("../../../../../TEST_FILES/mem_test24_from_c.mem", memfile_found);
          try_mig_candidate("../../../../../../TEST_FILES/mem_test24_from_c.mem", memfile_found);
        end
        25: begin
          try_mig_candidate("TEST_FILES/mem_test25_all_instr_stress.mem", memfile_found);
          try_mig_candidate("./TEST_FILES/mem_test25_all_instr_stress.mem", memfile_found);
          try_mig_candidate("../TEST_FILES/mem_test25_all_instr_stress.mem", memfile_found);
          try_mig_candidate("../../TEST_FILES/mem_test25_all_instr_stress.mem", memfile_found);
          try_mig_candidate("../../../TEST_FILES/mem_test25_all_instr_stress.mem", memfile_found);
          try_mig_candidate("../../../../TEST_FILES/mem_test25_all_instr_stress.mem", memfile_found);
          try_mig_candidate("../../../../../TEST_FILES/mem_test25_all_instr_stress.mem", memfile_found);
          try_mig_candidate("../../../../../../TEST_FILES/mem_test25_all_instr_stress.mem", memfile_found);
        end
        26: begin
          try_mig_candidate("TEST_FILES/mem_test26_mixed_stress.mem", memfile_found);
          try_mig_candidate("./TEST_FILES/mem_test26_mixed_stress.mem", memfile_found);
          try_mig_candidate("../TEST_FILES/mem_test26_mixed_stress.mem", memfile_found);
          try_mig_candidate("../../TEST_FILES/mem_test26_mixed_stress.mem", memfile_found);
          try_mig_candidate("../../../TEST_FILES/mem_test26_mixed_stress.mem", memfile_found);
          try_mig_candidate("../../../../TEST_FILES/mem_test26_mixed_stress.mem", memfile_found);
          try_mig_candidate("../../../../../TEST_FILES/mem_test26_mixed_stress.mem", memfile_found);
          try_mig_candidate("../../../../../../TEST_FILES/mem_test26_mixed_stress.mem", memfile_found);
        end
        27: begin
          try_mig_candidate("TEST_FILES/mem_test27_full_system_stress.mem", memfile_found);
          try_mig_candidate("./TEST_FILES/mem_test27_full_system_stress.mem", memfile_found);
          try_mig_candidate("../TEST_FILES/mem_test27_full_system_stress.mem", memfile_found);
          try_mig_candidate("../../TEST_FILES/mem_test27_full_system_stress.mem", memfile_found);
          try_mig_candidate("../../../TEST_FILES/mem_test27_full_system_stress.mem", memfile_found);
          try_mig_candidate("../../../../TEST_FILES/mem_test27_full_system_stress.mem", memfile_found);
          try_mig_candidate("../../../../../TEST_FILES/mem_test27_full_system_stress.mem", memfile_found);
          try_mig_candidate("../../../../../../TEST_FILES/mem_test27_full_system_stress.mem", memfile_found);
        end
        default: begin
        end
      endcase
    end
    if (!memfile_found) begin
      $display("FATAL: MIG model cannot open MEMFILE=%0s", memfile);
      $display("Hint: set xsim option: -testplusarg MEMFILE=<absolute-or-correct-relative-path>.");
      $finish;
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
    input [26:0] a16;
    integer i;
    reg [31:0] base;
    begin
      base = a16;
      for (i = 0; i < 16; i = i + 1)
        rd128[i*8 +: 8] = mem_b[base + i];
    end
  endfunction

  task wr128;
    input [26:0] a16;
    input [127:0] data;
    input [15:0] mask;
    integer i;
    reg [31:0] base;
    begin
      base = a16;
      for (i = 0; i < 16; i = i + 1) begin
        if (!mask[i])
          mem_b[base + i] = data[i*8 +: 8];
      end
    end
  endtask

  reg [26:0] rd_addr_d0, rd_addr_d1;
  reg        rd_valid_d0, rd_valid_d1;

  always @(posedge ui_clk or negedge sys_rst) begin
    if (!sys_rst) begin
      app_rdy          <= 1'b0;
      app_wdf_rdy      <= 1'b0;
      app_rd_data_valid<= 1'b0;
      app_rd_data_end  <= 1'b0;
      app_rd_data      <= 128'd0;
      rd_valid_d0      <= 1'b0;
      rd_valid_d1      <= 1'b0;
      rd_addr_d0       <= 27'd0;
      rd_addr_d1       <= 27'd0;
      app_sr_active    <= 1'b0;
      app_ref_ack      <= 1'b0;
      app_zq_ack       <= 1'b0;
      ui_clk_sync_rst  <= 1'b1;
      rd_accepted      <= 0;
      rd_returned      <= 0;
      rd_silence       <= 0;
      not_ready_streak <= 0;
      rand_ready_bit   <= 1'b0;
    end else begin
      if (rand_mem_en != 0) begin
        // Keep cmd/data ready synchronized to match L2's same-cycle write handshake.
        // Also force periodic readiness to guarantee forward progress in stress mode.
        if (not_ready_streak >= 8)
          rand_ready_bit <= 1'b1;
        else
          rand_ready_bit <= (rand_mod_mig(99) >= rand_bp_pct);
        app_rdy     <= rand_ready_bit;
        app_wdf_rdy <= rand_ready_bit;
        if (rand_ready_bit)
          not_ready_streak <= 0;
        else
          not_ready_streak <= not_ready_streak + 1;
      end else begin
        app_rdy     <= 1'b1;
        app_wdf_rdy <= 1'b1;
        not_ready_streak <= 0;
      end
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

      // Read progress/accounting checks
      if (app_en && app_rdy && (app_cmd == CMD_READ))
        rd_accepted <= rd_accepted + 1;
      if (app_rd_data_valid)
        rd_returned <= rd_returned + 1;

      if ((rd_accepted > rd_returned) && !app_rd_data_valid)
        rd_silence <= rd_silence + 1;
      else
        rd_silence <= 0;

      if (assert_en != 0) begin
        if (app_en && app_rdy && ((^app_cmd === 1'bx) || (^app_addr === 1'bx))) begin
          $display("ASSERT_FAIL: MIG app cmd/addr has X when accepted");
          $finish;
        end
        if (rd_returned > rd_accepted) begin
          $display("ASSERT_FAIL: MIG returned read data without accepted read");
          $finish;
        end
        if (rd_silence > rd_watchdog_max) begin
          $display("ASSERT_FAIL: MIG read response watchdog timeout (%0d cycles), outstanding=%0d",
                   rd_silence, (rd_accepted - rd_returned));
          $finish;
        end
      end
    end
  end

endmodule
