// mem_stage.v — 基礎 MEM 階段（RV32I，支援 LB/LH/LW/LBU/LHU、SB/SH/SW）
// 介面：簡單資料匯流排握手
//   req/we/addr/wdata/wstrb → slave
//   ready/rvalid/rdata      ← slave
//
// 備註：假設對齊正確（LW addr[1:0]=0、LH addr[0]=0）；未實作例外。
//      之後可在外層加入 misalign 檢查與 trap。

module mem_stage (
  input         clk,
  input         rst_n,

  // ====== 來自 EX/MEM 暫存器 ======
  input         mem_valid_i,           // 這拍有效指令
  input  [31:0] mem_alu_result_i,      // 位址 (rs1+imm)
  input  [31:0] mem_store_data_i,      // 要寫入的資料 (rs2)
  input         mem_mem_read_i,        // 1: LOAD
  input         mem_mem_write_i,       // 1: STORE
  input  [2:0]  mem_size_i,            // funct3：LOAD/STORE 大小編碼

  // ====== 對資料記憶體匯流排（之後可換成 AXI-Lite/MIG wrapper）======
  output        dmem_req_o,            // 要求有效（read 或 write）
  output        dmem_we_o,             // 1: write, 0: read
  output [31:0] dmem_addr_o,
  output [31:0] dmem_wdata_o,
  output [3:0]  dmem_wstrb_o,          // byte enable
  input         dmem_ready_i,          // write 接受 / read 發出
  input         dmem_rvalid_i,         // read 資料有效
  input  [31:0] dmem_rdata_i,

  // ====== 輸出到 MEM/WB 暫存器或 WB 階段 ======
  output [31:0] mem_load_rdata_o,      // 已經做過 sign/zero-extend 的讀取資料
  output        mem_stall_o            // 需停住上游（等待記憶體）
);

  // -------- 取便利用的欄位 --------
  wire [31:0] addr   = mem_alu_result_i;
  wire [1:0]  addr2  = addr[1:0];      // byte 選擇
  wire        is_load  = mem_valid_i & mem_mem_read_i;
  wire        is_store = mem_valid_i & mem_mem_write_i;

  // -------- 根據 size (funct3) 產生 write strobe / write data --------
  // LOAD/STORE 的 funct3 定義（精簡）
  localparam [2:0] F3_LB  = 3'b000,
                   F3_LH  = 3'b001,
                   F3_LW  = 3'b010,
                   F3_LBU = 3'b100,
                   F3_LHU = 3'b101;
  // STORE 共用編碼（與 LOAD 同一組意義：000=byte,001=half,010=word）
  localparam [2:0] F3_SB  = 3'b000,
                   F3_SH  = 3'b001,
                   F3_SW  = 3'b010;

  reg [3:0]  wstrb;
  reg [31:0] wdata_aligned;

  always @(*) begin
    wstrb        = 4'b0000;
    wdata_aligned= 32'b0;
    if (is_store) begin
      case (mem_size_i)
        F3_SB: begin
          wstrb = 4'b0001 << addr2;
          // 將欲寫入的 byte 複製到所有 lane，配合 wstrb 生效於對應 byte
          wdata_aligned = {4{mem_store_data_i[7:0]}};
        end
        F3_SH: begin
          wstrb = (addr2[1]) ? 4'b1100 : 4'b0011;
          wdata_aligned = {2{mem_store_data_i[15:0]}};
        end
        F3_SW: begin
          wstrb = 4'b1111;
          wdata_aligned = mem_store_data_i;
        end
        default: begin
          wstrb = 4'b0000;
          wdata_aligned = 32'b0;
        end
      endcase
    end
  end

  // -------- 讀取資料擴展（sign/zero extend） --------
  reg [31:0] load_ext;

  wire [7:0]  rbyte = (addr2==2'd0) ? dmem_rdata_i[7:0]   :
                      (addr2==2'd1) ? dmem_rdata_i[15:8]  :
                      (addr2==2'd2) ? dmem_rdata_i[23:16] : dmem_rdata_i[31:24];

  wire [15:0] rhalf = addr2[1] ? dmem_rdata_i[31:16] : dmem_rdata_i[15:0];

  always @(*) begin
    case (mem_size_i)
      F3_LB : load_ext = {{24{rbyte[7]}},  rbyte};     // 有號擴展
      F3_LBU: load_ext = {24'b0,          rbyte};      // 無號擴展
      F3_LH : load_ext = {{16{rhalf[15]}}, rhalf};     // 有號擴展
      F3_LHU: load_ext = {16'b0,          rhalf};      // 無號擴展
      F3_LW : load_ext = dmem_rdata_i;
      default: load_ext = dmem_rdata_i;                // 預設當作 LW
    endcase
  end

  assign mem_load_rdata_o = load_ext;

  // -------- 簡單握手狀態機：處理等待 rvalid/ready --------
  reg busy_q, is_load_q;  // 記錄當前傳輸型態（讀/寫）

  // 何時發起一筆新交易
  wire kick = (is_load | is_store) & ~busy_q;

  // 對外輸出：維持 req 直到事畢
  assign dmem_req_o   = busy_q | kick;
  assign dmem_we_o    = is_store | (busy_q & ~is_load_q);
  assign dmem_addr_o  = addr;           // 基礎版：發起當拍即採用當前 addr
  assign dmem_wdata_o = wdata_aligned;
  assign dmem_wstrb_o = wstrb;

  // 交易何時完成？
  wire done_write = (busy_q ? (~is_load_q & dmem_ready_i)
                            : (is_store  & dmem_ready_i));     // 寫：ready 即完成
  wire done_read  = (busy_q ? ( is_load_q & dmem_rvalid_i)
                            : (is_load   & dmem_rvalid_i));    // 讀：rvalid 即完成
  wire done = done_write | done_read;

  // busy 狀態寄存
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy_q    <= 1'b0;
      is_load_q <= 1'b0;
    end else begin
      // 起單
      if (kick) begin
        busy_q    <= 1'b1;
        is_load_q <= is_load;
      end
      // 完成
      if (done) begin
        busy_q    <= 1'b0;
      end
    end
  end

  // 需要讓上游停住的條件（交易未完成）
  assign mem_stall_o = busy_q | kick;  // 發起當拍也視為需要停住一拍（保守作法）

endmodule
