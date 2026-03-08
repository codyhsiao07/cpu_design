// uart_bootloader.v
// Minimal UART-based DDR loader using MIG app interface.
// Protocol:
//   1) Host sends 4-byte little-endian SYNC_WORD (0xC0DE5A5A)
//   2) Host sends 4-byte little-endian length N
//   3) Host sends N data bytes (written to DDR starting at BOOT_ADDR)
// After all bytes are written, boot_done_o is asserted.

module uart_bootloader #(
  parameter integer CLK_HZ    = 100_000_000,
  parameter integer BAUD      = 115_200,
  parameter [31:0] DDR_BASE   = 32'h8000_0000,
  parameter [31:0] BOOT_ADDR  = 32'h8000_0000
) (
  input               clk,
  input               uart_rx_i,
  input               init_calib_complete,

  // MIG app write interface
  output reg [26:0]   app_addr,
  output reg [2:0]    app_cmd,
  output reg          app_en,
  output reg [127:0]  app_wdf_data,
  output reg          app_wdf_end,
  output reg [15:0]   app_wdf_mask,
  output reg          app_wdf_wren,
  input               app_rdy,
  input               app_wdf_rdy,
  input [127:0]       app_rd_data,
  input               app_rd_data_end,
  input               app_rd_data_valid,

  output reg          boot_done_o,
  output reg          debug_edge_seen_o,
  output reg          debug_rx_seen_o,
  output reg          debug_sync_seen_o,
  output              debug_rst_released_o,
  output [2:0]        debug_state_o,
  output [3:0]        debug_rx_sel_o,
  output              debug_word0_ok_o,
  output              debug_word1_ok_o,
  output              debug_word2_ok_o,
  output              debug_word3_ok_o,
  output              debug_header_ok_o,
  output              debug_verify0_ok_o,
  output              debug_verify1_ok_o,
  output              debug_verify2_ok_o,
  output              debug_verify0_w0_ok_o,
  output              debug_verify0_w1_ok_o,
  output              debug_verify0_w2_ok_o,
  output              debug_verify0_w3_ok_o,
  output              debug_verify0_wordrev_ok_o,
  output              debug_verify0_byterev32_ok_o,
  output              debug_verify0_byterev128_ok_o,
  output              debug_verify0_memtest0_ok_o,
  output reg          debug_verify_req_seen_o,
  output reg          debug_verify_rsp_seen_o
);
  localparam [2:0] MIG_CMD_WRITE = 3'b000;
  localparam [2:0] MIG_CMD_READ  = 3'b001;
  localparam [31:0] SYNC_WORD    = 32'hC0DE5A5A;
  localparam [31:0] MAX_BYTES    = 32'd1_048_576; // 1 MiB guard
  localparam integer TIMEOUT_CYCLES = CLK_HZ;     // 1 second at local clock
  localparam integer TIMEOUT_W      = $clog2(TIMEOUT_CYCLES + 1);
  localparam integer VERIFY_WAIT_CYCLES = 512;
  localparam integer VERIFY_WAIT_W = (VERIFY_WAIT_CYCLES <= 1) ? 1 :
                                     $clog2(VERIFY_WAIT_CYCLES + 1);
  localparam integer RX_FIFO_AW = 6;
  localparam integer RX_FIFO_DEPTH = (1 << RX_FIFO_AW);

  // Keep bootloader in reset until MIG calibration completes.
  wire rst_n_int = init_calib_complete;

  // UART RX (sync)
  (* ASYNC_REG = "TRUE" *) reg rx_ff1;
  (* ASYNC_REG = "TRUE" *) reg rx_ff2;
  wire rx_norm = rx_ff2;
  wire rx_inv  = ~rx_ff2;
  always @(posedge clk) begin
    if (!rst_n_int) begin
      rx_ff1 <= 1'b1;
      rx_ff2 <= 1'b1;
    end else begin
      rx_ff1 <= uart_rx_i;
      rx_ff2 <= rx_ff1;
    end
  end

  wire [7:0] rx_data_div4;
  wire       rx_valid_div4;
  wire [7:0] rx_data_div2;
  wire       rx_valid_div2;
  wire [7:0] rx_data_nom;
  wire       rx_valid_nom;
  wire [7:0] rx_data_mul2;
  wire       rx_valid_mul2;
  wire [7:0] rx_data_mul4;
  wire       rx_valid_mul4;
  wire [7:0] rx_data_div4_i;
  wire       rx_valid_div4_i;
  wire [7:0] rx_data_div2_i;
  wire       rx_valid_div2_i;
  wire [7:0] rx_data_nom_i;
  wire       rx_valid_nom_i;
  wire [7:0] rx_data_mul2_i;
  wire       rx_valid_mul2_i;
  wire [7:0] rx_data_mul4_i;
  wire       rx_valid_mul4_i;
  wire       any_valid;
  wire [7:0] sel_data;
  wire       sel_valid;

  uart_rx #(
    .CLK_HZ (CLK_HZ),
    .BAUD   (BAUD/4)
  ) u_rx_div4 (
    .clk     (clk),
    .rst_n   (rst_n_int),
    .rx_i    (rx_norm),
    .data_o  (rx_data_div4),
    .valid_o (rx_valid_div4)
  );

  uart_rx #(
    .CLK_HZ (CLK_HZ),
    .BAUD   (BAUD)
  ) u_rx_nom (
    .clk     (clk),
    .rst_n   (rst_n_int),
    .rx_i    (rx_norm),
    .data_o  (rx_data_nom),
    .valid_o (rx_valid_nom)
  );

  uart_rx #(
    .CLK_HZ (CLK_HZ),
    .BAUD   (BAUD/2)
  ) u_rx_div2 (
    .clk     (clk),
    .rst_n   (rst_n_int),
    .rx_i    (rx_norm),
    .data_o  (rx_data_div2),
    .valid_o (rx_valid_div2)
  );

  uart_rx #(
    .CLK_HZ (CLK_HZ),
    .BAUD   (BAUD*2)
  ) u_rx_mul2 (
    .clk     (clk),
    .rst_n   (rst_n_int),
    .rx_i    (rx_norm),
    .data_o  (rx_data_mul2),
    .valid_o (rx_valid_mul2)
  );

  uart_rx #(
    .CLK_HZ (CLK_HZ),
    .BAUD   (BAUD*4)
  ) u_rx_mul4 (
    .clk     (clk),
    .rst_n   (rst_n_int),
    .rx_i    (rx_norm),
    .data_o  (rx_data_mul4),
    .valid_o (rx_valid_mul4)
  );

  uart_rx #(
    .CLK_HZ (CLK_HZ),
    .BAUD   (BAUD/4)
  ) u_rx_div4_i (
    .clk     (clk),
    .rst_n   (rst_n_int),
    .rx_i    (rx_inv),
    .data_o  (rx_data_div4_i),
    .valid_o (rx_valid_div4_i)
  );

  uart_rx #(
    .CLK_HZ (CLK_HZ),
    .BAUD   (BAUD)
  ) u_rx_nom_i (
    .clk     (clk),
    .rst_n   (rst_n_int),
    .rx_i    (rx_inv),
    .data_o  (rx_data_nom_i),
    .valid_o (rx_valid_nom_i)
  );

  uart_rx #(
    .CLK_HZ (CLK_HZ),
    .BAUD   (BAUD/2)
  ) u_rx_div2_i (
    .clk     (clk),
    .rst_n   (rst_n_int),
    .rx_i    (rx_inv),
    .data_o  (rx_data_div2_i),
    .valid_o (rx_valid_div2_i)
  );

  uart_rx #(
    .CLK_HZ (CLK_HZ),
    .BAUD   (BAUD*2)
  ) u_rx_mul2_i (
    .clk     (clk),
    .rst_n   (rst_n_int),
    .rx_i    (rx_inv),
    .data_o  (rx_data_mul2_i),
    .valid_o (rx_valid_mul2_i)
  );

  uart_rx #(
    .CLK_HZ (CLK_HZ),
    .BAUD   (BAUD*4)
  ) u_rx_mul4_i (
    .clk     (clk),
    .rst_n   (rst_n_int),
    .rx_i    (rx_inv),
    .data_o  (rx_data_mul4_i),
    .valid_o (rx_valid_mul4_i)
  );

  localparam [3:0] RXSEL_DIV4   = 4'd0;
  localparam [3:0] RXSEL_DIV2   = 4'd1;
  localparam [3:0] RXSEL_NOM    = 4'd2;
  localparam [3:0] RXSEL_MUL2   = 4'd3;
  localparam [3:0] RXSEL_MUL4   = 4'd4;
  localparam [3:0] RXSEL_DIV4_I = 4'd5;
  localparam [3:0] RXSEL_DIV2_I = 4'd6;
  localparam [3:0] RXSEL_NOM_I  = 4'd7;
  localparam [3:0] RXSEL_MUL2_I = 4'd8;
  localparam [3:0] RXSEL_MUL4_I = 4'd9;

  // Loader FSM
  localparam [2:0] S_WAIT = 3'd0;
  localparam [2:0] S_SYNC = 3'd1;
  localparam [2:0] S_LEN  = 3'd2;
  localparam [2:0] S_DATA = 3'd3;
  localparam [2:0] S_SEND = 3'd4;
  localparam [2:0] S_DONE = 3'd5;
  localparam [2:0] S_VERIFY_REQ  = 3'd6;
  localparam [2:0] S_VERIFY_WAIT = 3'd7;

  reg [2:0]  state;
  reg [1:0]  len_cnt;
  reg [31:0] bytes_total;
  reg [31:0] byte_cnt;
  reg [3:0]  buf_idx;
  reg [127:0] buf_data;
  reg [15:0]  buf_mask;
  reg [31:0]  curr_addr;
  reg         data_done;
  reg [3:0]   rx_sel;
  reg         send_need_cmd;
  reg         send_need_wdf;
  reg [31:0]  sync_shift_div4;
  reg [31:0]  sync_shift_div2;
  reg [31:0]  sync_shift_nom;
  reg [31:0]  sync_shift_mul2;
  reg [31:0]  sync_shift_mul4;
  reg [31:0]  sync_shift_div4_i;
  reg [31:0]  sync_shift_div2_i;
  reg [31:0]  sync_shift_nom_i;
  reg [31:0]  sync_shift_mul2_i;
  reg [31:0]  sync_shift_mul4_i;
  reg [TIMEOUT_W-1:0] idle_cnt;
  reg [31:0]  debug_word0_q;
  reg [31:0]  debug_word1_q;
  reg [31:0]  debug_word2_q;
  reg [31:0]  debug_word3_q;
  reg [26:0]  send_addr_q;
  reg [127:0] send_data_q;
  reg [15:0]  send_mask_q;
  reg [7:0]   rx_fifo_mem [0:RX_FIFO_DEPTH-1];
  reg [RX_FIFO_AW-1:0] rx_fifo_wr_ptr_q;
  reg [RX_FIFO_AW-1:0] rx_fifo_rd_ptr_q;
  reg [RX_FIFO_AW:0]   rx_fifo_count_q;
  reg [127:0] verify_exp0_q;
  reg [127:0] verify_exp1_q;
  reg [127:0] verify_exp2_q;
  reg [127:0] verify_got0_q;
  reg [15:0]  verify_vld0_q;
  reg [15:0]  verify_vld1_q;
  reg [15:0]  verify_vld2_q;
  reg [1:0]   verify_idx_q;
  reg [VERIFY_WAIT_W-1:0] verify_wait_cnt_q;
  reg         debug_verify0_ok_q;
  reg         debug_verify1_ok_q;
  reg         debug_verify2_ok_q;

  localparam [31:0] CRT0_WORD0 = 32'h0008_0117;
  localparam [31:0] CRT0_WORD1 = 32'hFFC1_0113;
  localparam [31:0] CRT0_WORD2 = 32'h0000_1197;
  localparam [31:0] CRT0_WORD3 = 32'h8341_8193;
  localparam [127:0] MEMTEST0_WORD = 128'h0123_4567_89AB_CDEF_FEDC_BA98_7654_3210;

  assign any_valid = rx_valid_nom   | rx_valid_div2   | rx_valid_mul2   |
                     rx_valid_div4  | rx_valid_mul4   | rx_valid_nom_i  |
                     rx_valid_div2_i| rx_valid_mul2_i | rx_valid_div4_i |
                     rx_valid_mul4_i;

  assign sel_valid = (rx_sel == RXSEL_DIV4  ) ? rx_valid_div4   :
                     (rx_sel == RXSEL_DIV2  ) ? rx_valid_div2   :
                     (rx_sel == RXSEL_NOM   ) ? rx_valid_nom    :
                     (rx_sel == RXSEL_MUL2  ) ? rx_valid_mul2   :
                     (rx_sel == RXSEL_MUL4  ) ? rx_valid_mul4   :
                     (rx_sel == RXSEL_DIV4_I) ? rx_valid_div4_i :
                     (rx_sel == RXSEL_DIV2_I) ? rx_valid_div2_i :
                     (rx_sel == RXSEL_NOM_I ) ? rx_valid_nom_i  :
                     (rx_sel == RXSEL_MUL2_I) ? rx_valid_mul2_i :
                                                 rx_valid_mul4_i;

  assign sel_data  = (rx_sel == RXSEL_DIV4  ) ? rx_data_div4   :
                     (rx_sel == RXSEL_DIV2  ) ? rx_data_div2   :
                     (rx_sel == RXSEL_NOM   ) ? rx_data_nom    :
                     (rx_sel == RXSEL_MUL2  ) ? rx_data_mul2   :
                     (rx_sel == RXSEL_MUL4  ) ? rx_data_mul4   :
                     (rx_sel == RXSEL_DIV4_I) ? rx_data_div4_i :
                     (rx_sel == RXSEL_DIV2_I) ? rx_data_div2_i :
                     (rx_sel == RXSEL_NOM_I ) ? rx_data_nom_i  :
                     (rx_sel == RXSEL_MUL2_I) ? rx_data_mul2_i :
                                                 rx_data_mul4_i;

  wire [31:0] sync_next_div4 = {rx_data_div4, sync_shift_div4[31:8]};
  wire [31:0] sync_next_div2 = {rx_data_div2, sync_shift_div2[31:8]};
  wire [31:0] sync_next_nom  = {rx_data_nom,  sync_shift_nom[31:8]};
  wire [31:0] sync_next_mul2 = {rx_data_mul2, sync_shift_mul2[31:8]};
  wire [31:0] sync_next_mul4 = {rx_data_mul4, sync_shift_mul4[31:8]};
  wire [31:0] sync_next_div4_i = {rx_data_div4_i, sync_shift_div4_i[31:8]};
  wire [31:0] sync_next_div2_i = {rx_data_div2_i, sync_shift_div2_i[31:8]};
  wire [31:0] sync_next_nom_i  = {rx_data_nom_i,  sync_shift_nom_i[31:8]};
  wire [31:0] sync_next_mul2_i = {rx_data_mul2_i, sync_shift_mul2_i[31:8]};
  wire [31:0] sync_next_mul4_i = {rx_data_mul4_i, sync_shift_mul4_i[31:8]};
  wire        match_div4 = rx_valid_div4 && (sync_next_div4 == SYNC_WORD);
  wire        match_div2 = rx_valid_div2 && (sync_next_div2 == SYNC_WORD);
  wire        match_nom  = rx_valid_nom  && (sync_next_nom  == SYNC_WORD);
  wire        match_mul2 = rx_valid_mul2 && (sync_next_mul2 == SYNC_WORD);
  wire        match_mul4 = rx_valid_mul4 && (sync_next_mul4 == SYNC_WORD);
  wire        match_div4_i = rx_valid_div4_i && (sync_next_div4_i == SYNC_WORD);
  wire        match_div2_i = rx_valid_div2_i && (sync_next_div2_i == SYNC_WORD);
  wire        match_nom_i  = rx_valid_nom_i  && (sync_next_nom_i  == SYNC_WORD);
  wire        match_mul2_i = rx_valid_mul2_i && (sync_next_mul2_i == SYNC_WORD);
  wire        match_mul4_i = rx_valid_mul4_i && (sync_next_mul4_i == SYNC_WORD);

  wire fire_send = (state == S_SEND) && app_rdy && app_wdf_rdy;
  wire fire_verify_req = (state == S_VERIFY_REQ) &&
                         (verify_wait_cnt_q == {VERIFY_WAIT_W{1'b0}}) &&
                         app_rdy;
  wire rx_fifo_empty = (rx_fifo_count_q == {RX_FIFO_AW+1{1'b0}});
  wire rx_fifo_full  = (rx_fifo_count_q == RX_FIFO_DEPTH);
  wire [7:0] rx_fifo_rdata = rx_fifo_mem[rx_fifo_rd_ptr_q];

  // Export internal reset release directly for board-level LED debug.
  assign debug_rst_released_o = rst_n_int;
  assign debug_state_o = state;
  assign debug_rx_sel_o = rx_sel;
  assign debug_word0_ok_o = (debug_word0_q == CRT0_WORD0);
  assign debug_word1_ok_o = (debug_word1_q == CRT0_WORD1);
  assign debug_word2_ok_o = (debug_word2_q == CRT0_WORD2);
  assign debug_word3_ok_o = (debug_word3_q == CRT0_WORD3);
  assign debug_header_ok_o = (debug_word0_q == CRT0_WORD0) &&
                             (debug_word1_q == CRT0_WORD1);
  assign debug_verify0_ok_o = debug_verify0_ok_q;
  assign debug_verify1_ok_o = debug_verify1_ok_q;
  assign debug_verify2_ok_o = debug_verify2_ok_q;
  assign debug_verify0_w0_ok_o = debug_verify_rsp_seen_o &&
                                 (verify_got0_q[31:0] == verify_exp0_q[31:0]);
  assign debug_verify0_w1_ok_o = debug_verify_rsp_seen_o &&
                                 (verify_got0_q[63:32] == verify_exp0_q[63:32]);
  assign debug_verify0_w2_ok_o = debug_verify_rsp_seen_o &&
                                 (verify_got0_q[95:64] == verify_exp0_q[95:64]);
  assign debug_verify0_w3_ok_o = debug_verify_rsp_seen_o &&
                                 (verify_got0_q[127:96] == verify_exp0_q[127:96]);

  function masked_cmp128;
    input [127:0] got;
    input [127:0] exp;
    input [15:0]  vld;
    integer i;
    reg ok;
    begin
      ok = 1'b1;
      for (i = 0; i < 16; i = i + 1) begin
        if (vld[i] && (got[i*8 +: 8] != exp[i*8 +: 8]))
          ok = 1'b0;
      end
      masked_cmp128 = ok;
    end
  endfunction

  function [127:0] set_byte128;
    input [127:0] prev;
    input [3:0]   idx;
    input [7:0]   data;
    reg   [127:0] tmp;
    begin
      tmp = prev;
      tmp[idx*8 +: 8] = data;
      set_byte128 = tmp;
    end
  endfunction

  function [15:0] clear_mask_bit16;
    input [15:0] prev;
    input [3:0]  idx;
    reg   [15:0] tmp;
    begin
      tmp = prev;
      tmp[idx] = 1'b0;
      clear_mask_bit16 = tmp;
    end
  endfunction

  function [127:0] swap_word_order128;
    input [127:0] din;
    begin
      swap_word_order128 = {din[31:0], din[63:32], din[95:64], din[127:96]};
    end
  endfunction

  function [31:0] reverse_bytes32;
    input [31:0] din;
    begin
      reverse_bytes32 = {din[7:0], din[15:8], din[23:16], din[31:24]};
    end
  endfunction

  function [127:0] reverse_bytes_each_word128;
    input [127:0] din;
    begin
      reverse_bytes_each_word128 = {
        reverse_bytes32(din[127:96]),
        reverse_bytes32(din[95:64]),
        reverse_bytes32(din[63:32]),
        reverse_bytes32(din[31:0])
      };
    end
  endfunction

  function [127:0] reverse_bytes128;
    input [127:0] din;
    integer i;
    reg [127:0] tmp;
    begin
      tmp = 128'd0;
      for (i = 0; i < 16; i = i + 1)
        tmp[i*8 +: 8] = din[(15-i)*8 +: 8];
      reverse_bytes128 = tmp;
    end
  endfunction

  assign debug_verify0_wordrev_ok_o = debug_verify_rsp_seen_o &&
                                      (verify_got0_q == swap_word_order128(verify_exp0_q));
  assign debug_verify0_byterev32_ok_o = debug_verify_rsp_seen_o &&
                                        (verify_got0_q == reverse_bytes_each_word128(verify_exp0_q));
  assign debug_verify0_byterev128_ok_o = debug_verify_rsp_seen_o &&
                                         (verify_got0_q == reverse_bytes128(verify_exp0_q));
  assign debug_verify0_memtest0_ok_o = debug_verify_rsp_seen_o &&
                                       (verify_got0_q == MEMTEST0_WORD);

  // Default MIG outputs
  always @(*) begin
    app_addr     = 27'd0;
    app_cmd      = MIG_CMD_WRITE;
    app_en       = 1'b0;
    app_wdf_data = send_data_q;
    app_wdf_end  = 1'b0;
    app_wdf_mask = send_mask_q;
    app_wdf_wren = 1'b0;
    if (state == S_SEND) begin
      app_addr     = send_addr_q;
      app_cmd      = MIG_CMD_WRITE;
      app_en       = app_rdy && app_wdf_rdy;
      app_wdf_wren = app_rdy && app_wdf_rdy;
      app_wdf_end  = app_rdy && app_wdf_rdy;
    end else if (state == S_VERIFY_REQ) begin
      app_addr     = (BOOT_ADDR - DDR_BASE) + {21'd0, verify_idx_q, 4'b0000};
      app_cmd      = MIG_CMD_READ;
      app_en       = fire_verify_req;
    end
  end

  always @(posedge clk) begin
    if (!rst_n_int) begin
      state       <= S_WAIT;
      len_cnt     <= 2'd0;
      bytes_total <= 32'd0;
      byte_cnt    <= 32'd0;
      buf_idx     <= 4'd0;
      buf_data    <= 128'd0;
      buf_mask    <= 16'hFFFF;
      curr_addr   <= BOOT_ADDR;
      data_done   <= 1'b0;
      boot_done_o <= 1'b0;
      debug_edge_seen_o <= 1'b0;
      debug_rx_seen_o   <= 1'b0;
      debug_sync_seen_o <= 1'b0;
      debug_verify_req_seen_o <= 1'b0;
      debug_verify_rsp_seen_o <= 1'b0;
      rx_sel <= RXSEL_NOM;
      send_need_cmd <= 1'b0;
      send_need_wdf <= 1'b0;
      sync_shift_div4 <= 32'd0;
      sync_shift_div2 <= 32'd0;
      sync_shift_nom  <= 32'd0;
      sync_shift_mul2 <= 32'd0;
      sync_shift_mul4 <= 32'd0;
      sync_shift_div4_i <= 32'd0;
      sync_shift_div2_i <= 32'd0;
      sync_shift_nom_i  <= 32'd0;
      sync_shift_mul2_i <= 32'd0;
      sync_shift_mul4_i <= 32'd0;
      idle_cnt    <= {TIMEOUT_W{1'b0}};
      debug_word0_q <= 32'd0;
      debug_word1_q <= 32'd0;
      debug_word2_q <= 32'd0;
      debug_word3_q <= 32'd0;
      send_addr_q <= 27'd0;
      send_data_q <= 128'd0;
      send_mask_q <= 16'hFFFF;
      rx_fifo_wr_ptr_q <= {RX_FIFO_AW{1'b0}};
      rx_fifo_rd_ptr_q <= {RX_FIFO_AW{1'b0}};
      rx_fifo_count_q <= {(RX_FIFO_AW+1){1'b0}};
      verify_exp0_q <= 128'd0;
      verify_exp1_q <= 128'd0;
      verify_exp2_q <= 128'd0;
      verify_got0_q <= 128'd0;
      verify_vld0_q <= 16'd0;
      verify_vld1_q <= 16'd0;
      verify_vld2_q <= 16'd0;
      verify_idx_q <= 2'd0;
      verify_wait_cnt_q <= {VERIFY_WAIT_W{1'b0}};
      debug_verify0_ok_q <= 1'b0;
      debug_verify1_ok_q <= 1'b0;
      debug_verify2_ok_q <= 1'b0;
    end else begin
      if (rx_ff1 ^ rx_ff2)
        debug_edge_seen_o <= 1'b1;
      if (any_valid)
        debug_rx_seen_o <= 1'b1;

      case (state)
        S_WAIT: begin
          boot_done_o <= 1'b0;
          rx_sel <= RXSEL_NOM;
          send_need_cmd <= 1'b0;
          send_need_wdf <= 1'b0;
          sync_shift_div4 <= 32'd0;
          sync_shift_div2 <= 32'd0;
          sync_shift_nom  <= 32'd0;
          sync_shift_mul2 <= 32'd0;
          sync_shift_mul4 <= 32'd0;
          sync_shift_div4_i <= 32'd0;
          sync_shift_div2_i <= 32'd0;
          sync_shift_nom_i  <= 32'd0;
          sync_shift_mul2_i <= 32'd0;
          sync_shift_mul4_i <= 32'd0;
          idle_cnt    <= {TIMEOUT_W{1'b0}};
          if (init_calib_complete) begin
            len_cnt     <= 2'd0;
            bytes_total <= 32'd0;
            state       <= S_SYNC;
          end
        end
        S_SYNC: begin
          boot_done_o <= 1'b0;
          send_need_cmd <= 1'b0;
          send_need_wdf <= 1'b0;
          len_cnt     <= 2'd0;
          idle_cnt    <= {TIMEOUT_W{1'b0}};
          if (rx_valid_div4)
            sync_shift_div4 <= sync_next_div4;
          if (rx_valid_div2)
            sync_shift_div2 <= sync_next_div2;
          if (rx_valid_nom)
            sync_shift_nom <= sync_next_nom;
          if (rx_valid_mul2)
            sync_shift_mul2 <= sync_next_mul2;
          if (rx_valid_mul4)
            sync_shift_mul4 <= sync_next_mul4;
          if (rx_valid_div4_i)
            sync_shift_div4_i <= sync_next_div4_i;
          if (rx_valid_div2_i)
            sync_shift_div2_i <= sync_next_div2_i;
          if (rx_valid_nom_i)
            sync_shift_nom_i <= sync_next_nom_i;
          if (rx_valid_mul2_i)
            sync_shift_mul2_i <= sync_next_mul2_i;
          if (rx_valid_mul4_i)
            sync_shift_mul4_i <= sync_next_mul4_i;

          if (match_nom || match_div2 || match_mul2 || match_div4 || match_mul4 ||
              match_nom_i || match_div2_i || match_mul2_i || match_div4_i || match_mul4_i) begin
            debug_sync_seen_o <= 1'b1;
            bytes_total <= 32'd0;
            byte_cnt    <= 32'd0;
            buf_idx     <= 4'd0;
            buf_data    <= 128'd0;
            buf_mask    <= 16'hFFFF;
            curr_addr   <= BOOT_ADDR;
            data_done   <= 1'b0;
            debug_word0_q <= 32'd0;
            debug_word1_q <= 32'd0;
            debug_word2_q <= 32'd0;
            debug_word3_q <= 32'd0;
            send_addr_q <= 27'd0;
            send_data_q <= 128'd0;
            send_mask_q <= 16'hFFFF;
            rx_fifo_wr_ptr_q <= {RX_FIFO_AW{1'b0}};
            rx_fifo_rd_ptr_q <= {RX_FIFO_AW{1'b0}};
            rx_fifo_count_q <= {(RX_FIFO_AW+1){1'b0}};
            verify_exp0_q <= 128'd0;
            verify_exp1_q <= 128'd0;
            verify_exp2_q <= 128'd0;
            verify_got0_q <= 128'd0;
            verify_vld0_q <= 16'd0;
            verify_vld1_q <= 16'd0;
            verify_vld2_q <= 16'd0;
            verify_idx_q <= 2'd0;
            verify_wait_cnt_q <= {VERIFY_WAIT_W{1'b0}};
            debug_verify0_ok_q <= 1'b0;
            debug_verify1_ok_q <= 1'b0;
            debug_verify2_ok_q <= 1'b0;
            debug_verify_req_seen_o <= 1'b0;
            debug_verify_rsp_seen_o <= 1'b0;
            if (match_nom)
              rx_sel <= RXSEL_NOM;
            else if (match_div2)
              rx_sel <= RXSEL_DIV2;
            else if (match_mul2)
              rx_sel <= RXSEL_MUL2;
            else if (match_div4)
              rx_sel <= RXSEL_DIV4;
            else if (match_nom_i)
              rx_sel <= RXSEL_NOM_I;
            else if (match_div2_i)
              rx_sel <= RXSEL_DIV2_I;
            else if (match_mul2_i)
              rx_sel <= RXSEL_MUL2_I;
            else if (match_div4_i)
              rx_sel <= RXSEL_DIV4_I;
            else
              rx_sel <= match_mul4 ? RXSEL_MUL4 : RXSEL_MUL4_I;
            state       <= S_LEN;
          end
        end
        S_LEN: begin
          if (sel_valid && !rx_fifo_full) begin
            rx_fifo_mem[rx_fifo_wr_ptr_q] <= sel_data;
            rx_fifo_wr_ptr_q <= rx_fifo_wr_ptr_q + 1'b1;
          end

          if (!rx_fifo_empty) begin
            idle_cnt <= {TIMEOUT_W{1'b0}};
            bytes_total[8*len_cnt +: 8] <= rx_fifo_rdata;
            rx_fifo_rd_ptr_q <= rx_fifo_rd_ptr_q + 1'b1;
            if (!(sel_valid && !rx_fifo_full))
              rx_fifo_count_q <= rx_fifo_count_q - 1'b1;
            if (len_cnt == 2'd3) begin
              len_cnt   <= 2'd0;
              byte_cnt  <= 32'd0;
              buf_idx   <= 4'd0;
              buf_data  <= 128'd0;
              buf_mask  <= 16'hFFFF;
              curr_addr <= BOOT_ADDR;
              data_done <= 1'b0;
              debug_word0_q <= 32'd0;
              debug_word1_q <= 32'd0;
              debug_word2_q <= 32'd0;
              debug_word3_q <= 32'd0;
              send_addr_q <= 27'd0;
              send_data_q <= 128'd0;
              send_mask_q <= 16'hFFFF;
              rx_fifo_wr_ptr_q <= {RX_FIFO_AW{1'b0}};
              rx_fifo_rd_ptr_q <= {RX_FIFO_AW{1'b0}};
              rx_fifo_count_q <= {(RX_FIFO_AW+1){1'b0}};
              verify_exp0_q <= 128'd0;
              verify_exp1_q <= 128'd0;
              verify_exp2_q <= 128'd0;
              verify_got0_q <= 128'd0;
              verify_vld0_q <= 16'd0;
              verify_vld1_q <= 16'd0;
              verify_vld2_q <= 16'd0;
              verify_idx_q <= 2'd0;
              verify_wait_cnt_q <= {VERIFY_WAIT_W{1'b0}};
              debug_verify0_ok_q <= 1'b0;
              debug_verify1_ok_q <= 1'b0;
              debug_verify2_ok_q <= 1'b0;
              debug_verify_req_seen_o <= 1'b0;
              debug_verify_rsp_seen_o <= 1'b0;
              send_need_cmd <= 1'b0;
              send_need_wdf <= 1'b0;
              if ({rx_fifo_rdata, bytes_total[23:0]} == 32'd0) begin
                boot_done_o <= 1'b1;
                state <= S_DONE;
              end else if ({rx_fifo_rdata, bytes_total[23:0]} > MAX_BYTES) begin
                rx_sel <= RXSEL_NOM;
                sync_shift_div4 <= 32'd0;
                sync_shift_div2 <= 32'd0;
                sync_shift_nom  <= 32'd0;
                sync_shift_mul2 <= 32'd0;
                sync_shift_mul4 <= 32'd0;
                sync_shift_div4_i <= 32'd0;
                sync_shift_div2_i <= 32'd0;
                sync_shift_nom_i  <= 32'd0;
                sync_shift_mul2_i <= 32'd0;
                sync_shift_mul4_i <= 32'd0;
                state <= S_SYNC;
              end else begin
                state <= S_DATA;
              end
            end else begin
              len_cnt <= len_cnt + 1'b1;
            end
          end else if (sel_valid && !rx_fifo_full) begin
            idle_cnt <= {TIMEOUT_W{1'b0}};
            rx_fifo_count_q <= rx_fifo_count_q + 1'b1;
          end else if (idle_cnt == TIMEOUT_CYCLES - 1) begin
            idle_cnt   <= {TIMEOUT_W{1'b0}};
            rx_sel <= RXSEL_NOM;
            sync_shift_div4 <= 32'd0;
            sync_shift_div2 <= 32'd0;
            sync_shift_nom  <= 32'd0;
            sync_shift_mul2 <= 32'd0;
            sync_shift_mul4 <= 32'd0;
            sync_shift_div4_i <= 32'd0;
            sync_shift_div2_i <= 32'd0;
            sync_shift_nom_i  <= 32'd0;
            sync_shift_mul2_i <= 32'd0;
            sync_shift_mul4_i <= 32'd0;
            state      <= S_SYNC;
          end else begin
            idle_cnt <= idle_cnt + 1'b1;
          end
        end
        S_DATA: begin
          if (sel_valid && !rx_fifo_full) begin
            rx_fifo_mem[rx_fifo_wr_ptr_q] <= sel_data;
            rx_fifo_wr_ptr_q <= rx_fifo_wr_ptr_q + 1'b1;
          end

          if (!rx_fifo_empty) begin
            idle_cnt <= {TIMEOUT_W{1'b0}};
            if (byte_cnt < 32'd4)
              debug_word0_q[byte_cnt[1:0]*8 +: 8] <= rx_fifo_rdata;
            else if (byte_cnt < 32'd8)
              debug_word1_q[byte_cnt[1:0]*8 +: 8] <= rx_fifo_rdata;
            else if (byte_cnt < 32'd12)
              debug_word2_q[byte_cnt[1:0]*8 +: 8] <= rx_fifo_rdata;
            else if (byte_cnt < 32'd16)
              debug_word3_q[byte_cnt[1:0]*8 +: 8] <= rx_fifo_rdata;
            if (byte_cnt < 32'd16) begin
              verify_exp0_q[byte_cnt[3:0]*8 +: 8] <= rx_fifo_rdata;
              verify_vld0_q[byte_cnt[3:0]] <= 1'b1;
            end else if (byte_cnt < 32'd32) begin
              verify_exp1_q[byte_cnt[3:0]*8 +: 8] <= rx_fifo_rdata;
              verify_vld1_q[byte_cnt[3:0]] <= 1'b1;
            end else if (byte_cnt < 32'd48) begin
              verify_exp2_q[byte_cnt[3:0]*8 +: 8] <= rx_fifo_rdata;
              verify_vld2_q[byte_cnt[3:0]] <= 1'b1;
            end
            buf_data[buf_idx*8 +: 8] <= rx_fifo_rdata;
            buf_mask[buf_idx] <= 1'b0;
            if (byte_cnt == (bytes_total - 1)) begin
              data_done <= 1'b1;
            end
            byte_cnt <= byte_cnt + 1'b1;
            rx_fifo_rd_ptr_q <= rx_fifo_rd_ptr_q + 1'b1;
            if (!(sel_valid && !rx_fifo_full))
              rx_fifo_count_q <= rx_fifo_count_q - 1'b1;

            if ((buf_idx == 4'd15) || (byte_cnt == (bytes_total - 1))) begin
              send_addr_q <= curr_addr - DDR_BASE;
              send_data_q <= set_byte128(buf_data, buf_idx, rx_fifo_rdata);
              send_mask_q <= clear_mask_bit16(buf_mask, buf_idx);
              send_need_cmd <= 1'b1;
              send_need_wdf <= 1'b1;
              state <= S_SEND;
            end
            buf_idx <= buf_idx + 1'b1;
          end else if (sel_valid && !rx_fifo_full) begin
            idle_cnt <= {TIMEOUT_W{1'b0}};
            rx_fifo_count_q <= rx_fifo_count_q + 1'b1;
          end else if (idle_cnt == TIMEOUT_CYCLES - 1) begin
            idle_cnt   <= {TIMEOUT_W{1'b0}};
            rx_sel <= RXSEL_NOM;
            sync_shift_div4 <= 32'd0;
            sync_shift_div2 <= 32'd0;
            sync_shift_nom  <= 32'd0;
            sync_shift_mul2 <= 32'd0;
            sync_shift_mul4 <= 32'd0;
            sync_shift_div4_i <= 32'd0;
            sync_shift_div2_i <= 32'd0;
            sync_shift_nom_i  <= 32'd0;
            sync_shift_mul2_i <= 32'd0;
            sync_shift_mul4_i <= 32'd0;
            verify_idx_q <= 2'd0;
            verify_wait_cnt_q <= {VERIFY_WAIT_W{1'b0}};
            debug_verify0_ok_q <= 1'b0;
            debug_verify1_ok_q <= 1'b0;
            debug_verify2_ok_q <= 1'b0;
            debug_verify_req_seen_o <= 1'b0;
            debug_verify_rsp_seen_o <= 1'b0;
            send_need_cmd <= 1'b0;
            send_need_wdf <= 1'b0;
            state      <= S_SYNC;
          end else begin
            idle_cnt <= idle_cnt + 1'b1;
          end
        end
        S_SEND: begin
          if (sel_valid && !rx_fifo_full) begin
            rx_fifo_mem[rx_fifo_wr_ptr_q] <= sel_data;
            rx_fifo_wr_ptr_q <= rx_fifo_wr_ptr_q + 1'b1;
            rx_fifo_count_q <= rx_fifo_count_q + 1'b1;
          end

          if (fire_send) begin
            idle_cnt <= {TIMEOUT_W{1'b0}};
            send_need_cmd <= 1'b0;
            send_need_wdf <= 1'b0;
            if (data_done) begin
              verify_idx_q <= 2'd0;
              verify_wait_cnt_q <= VERIFY_WAIT_CYCLES[VERIFY_WAIT_W-1:0];
              state <= S_VERIFY_REQ;
            end else begin
              curr_addr <= curr_addr + 32'd16;
              buf_idx  <= 4'd0;
              buf_data <= 128'd0;
              buf_mask <= 16'hFFFF;
              state <= S_DATA;
            end
          end else if (sel_valid && !rx_fifo_full) begin
            idle_cnt <= {TIMEOUT_W{1'b0}};
          end else if (idle_cnt == TIMEOUT_CYCLES - 1) begin
            idle_cnt   <= {TIMEOUT_W{1'b0}};
            rx_sel <= RXSEL_NOM;
            sync_shift_div4 <= 32'd0;
            sync_shift_div2 <= 32'd0;
            sync_shift_nom  <= 32'd0;
            sync_shift_mul2 <= 32'd0;
            sync_shift_mul4 <= 32'd0;
            sync_shift_div4_i <= 32'd0;
            sync_shift_div2_i <= 32'd0;
            sync_shift_nom_i  <= 32'd0;
            sync_shift_mul2_i <= 32'd0;
            sync_shift_mul4_i <= 32'd0;
            verify_idx_q <= 2'd0;
            verify_wait_cnt_q <= {VERIFY_WAIT_W{1'b0}};
            debug_verify0_ok_q <= 1'b0;
            debug_verify1_ok_q <= 1'b0;
            debug_verify2_ok_q <= 1'b0;
            debug_verify_req_seen_o <= 1'b0;
            debug_verify_rsp_seen_o <= 1'b0;
            send_need_cmd <= 1'b0;
            send_need_wdf <= 1'b0;
            state      <= S_SYNC;
          end else begin
            idle_cnt <= idle_cnt + 1'b1;
          end
        end
        S_VERIFY_REQ: begin
          if (verify_wait_cnt_q != {VERIFY_WAIT_W{1'b0}}) begin
            verify_wait_cnt_q <= verify_wait_cnt_q - 1'b1;
          end else if (fire_verify_req) begin
            idle_cnt <= {TIMEOUT_W{1'b0}};
            debug_verify_req_seen_o <= 1'b1;
            state <= S_VERIFY_WAIT;
          end else if (idle_cnt == TIMEOUT_CYCLES - 1) begin
            idle_cnt   <= {TIMEOUT_W{1'b0}};
            rx_sel <= RXSEL_NOM;
            sync_shift_div4 <= 32'd0;
            sync_shift_div2 <= 32'd0;
            sync_shift_nom  <= 32'd0;
            sync_shift_mul2 <= 32'd0;
            sync_shift_mul4 <= 32'd0;
            sync_shift_div4_i <= 32'd0;
            sync_shift_div2_i <= 32'd0;
            sync_shift_nom_i  <= 32'd0;
            sync_shift_mul2_i <= 32'd0;
            sync_shift_mul4_i <= 32'd0;
            verify_wait_cnt_q <= {VERIFY_WAIT_W{1'b0}};
            state <= S_SYNC;
          end else begin
            idle_cnt <= idle_cnt + 1'b1;
          end
        end
        S_VERIFY_WAIT: begin
          if (app_rd_data_valid && app_rd_data_end) begin
            idle_cnt <= {TIMEOUT_W{1'b0}};
            debug_verify_rsp_seen_o <= 1'b1;
            if (verify_idx_q == 2'd0)
              verify_got0_q <= app_rd_data;
            case (verify_idx_q)
              2'd0: debug_verify0_ok_q <= masked_cmp128(app_rd_data, verify_exp0_q, verify_vld0_q);
              2'd1: debug_verify1_ok_q <= masked_cmp128(app_rd_data, verify_exp1_q, verify_vld1_q);
              default: debug_verify2_ok_q <= masked_cmp128(app_rd_data, verify_exp2_q, verify_vld2_q);
            endcase
            if (verify_idx_q == 2'd2) begin
              if (debug_verify0_ok_q &&
                  debug_verify1_ok_q &&
                  masked_cmp128(app_rd_data, verify_exp2_q, verify_vld2_q)) begin
                boot_done_o <= 1'b1;
                state <= S_DONE;
              end else begin
                boot_done_o <= 1'b0;
                state <= S_SYNC;
              end
            end else begin
              verify_idx_q <= verify_idx_q + 1'b1;
              state <= S_VERIFY_REQ;
            end
          end else if (idle_cnt == TIMEOUT_CYCLES - 1) begin
            idle_cnt   <= {TIMEOUT_W{1'b0}};
            rx_sel <= RXSEL_NOM;
            sync_shift_div4 <= 32'd0;
            sync_shift_div2 <= 32'd0;
            sync_shift_nom  <= 32'd0;
            sync_shift_mul2 <= 32'd0;
            sync_shift_mul4 <= 32'd0;
            sync_shift_div4_i <= 32'd0;
            sync_shift_div2_i <= 32'd0;
            sync_shift_nom_i  <= 32'd0;
            sync_shift_mul2_i <= 32'd0;
            sync_shift_mul4_i <= 32'd0;
            verify_wait_cnt_q <= {VERIFY_WAIT_W{1'b0}};
            state <= S_SYNC;
          end else begin
            idle_cnt <= idle_cnt + 1'b1;
          end
        end
        S_DONE: begin
          boot_done_o <= 1'b1;
          send_need_cmd <= 1'b0;
          send_need_wdf <= 1'b0;
          idle_cnt    <= {TIMEOUT_W{1'b0}};
        end
        default: begin
          state <= S_WAIT;
        end
      endcase
    end
  end

endmodule
