**L2 快取規格書（v0.1）**

*目標平台：Nexys A7 DDR2（Xilinx MIG Native Application Interface）*

*日期：2026-02-04*


# **1. 概述**
本文件定義一個 unified Level-2（L2）快取之功能與介面規格。L2 位於已驗證的 I-cache（I$）與 D-cache（D$）之下，服務單核心、in-order 5-stage pipeline 系統。
## **1.1 範圍**
L2 提供：(1) I$/D$ 共用的 unified cache；(2) I$ / D$ miss 與 uncached（含 MMIO）存取之仲裁；(3) 透過 Xilinx MIG native app 介面連接外部 DDR2。
## **1.2 目標**
- 真 L2 cache：包含 tag/data array、hit/miss、replacement、dirty writeback。
- Unified、non-inclusive（不追蹤 L1 狀態；不做 coherence）。
- Bring-up 友善：single-outstanding、in-order completion。
- 與現有 L1->L2 request/response（valid/ready、burst line transfer）相容。
- 下游 DDR2 透過 MIG 128-bit user interface（ui\_clk domain）。
## **1.3 非目標（v0.1）**
- 多核心一致性（coherence）/ snoop。
- ECC / parity。
- Hit-under-miss / 多筆 outstanding miss（MSHR）。
- Out-of-order 回應完成（reordering）。
## **1.4 關鍵假設**
- 單核心、in-order pipeline。
- I$/D$ 已完成驗證，且已具備 miss handling 與 uncached pathway。
- v0.1 建議 core + I$ + D$ + L2 皆使用 MIG ui\_clk（避免 CDC）。
- DDR2 映射為一段連續的物理位址區間（見第 3 章）。
# **2. 架構摘要**
L2 為 unified 2-way set-associative cache，cache line 為 64B，策略為 write-back + write-allocate。L2 對 I$ 與 D$ 請求進行仲裁。Cached access 先查 L2（hit/miss）；miss 由 DDR2 refill。Uncached（MMIO 或顯式 uncached）會 bypass L2 arrays，直接走 MIG 存取 DDR2。
## **2.1 頂層策略（v0.1 固定）**

| 項目                    | 值                                        |
| :---------------------- | :---------------------------------------- |
| Cache line 大小         | 64 bytes                                  |
| 相連度（Associativity） | 2-way                                     |
| 容量（Capacity）        | 256 KiB                                   |
| Replacement             | 每個 set 1-bit PLRU                       |
| Write policy            | Write-back + Write-allocate               |
| Inclusivity             | Non-inclusive（不追蹤 L1 狀態）           |
| Outstanding 交易數      | 全域 single outstanding（一次只處理一筆） |
| 回應排序                | In-order responses                        |
| 仲裁優先序              | Uncached/MMIO > D$ > I$                   |

# **3. 位址映射與屬性（Address Map）**
所有位址皆為 physical byte address（PA）。v0.1 定義如下：

| 區域                    | Base         | End          | 大小    | 屬性                                 |
| :---------------------- | :----------- | :----------- | :------ | :----------------------------------- |
| Boot ROM / BRAM（可選） | 0x0000\_0000 | 0x0000\_FFFF | 64 KiB  | 若實作則可 cache；若未實作則回 error |
| MMIO（保留）            | 0x4000\_0000 | 0x4000\_FFFF | 64 KiB  | Uncached、強順序（strongly ordered） |
| DDR2（MIG）             | 0x8000\_0000 | 0x87FF\_FFFF | 128 MiB | 預設 cacheable                       |
## **3.1 Cacheable vs Uncached 判定規則**
L2 對每筆上游 request 計算：

- is\_ddr  := (PA 位於 0x8000\_0000 .. 0x87FF\_FFFF)
- is\_mmio := (PA 位於 0x4000\_0000 .. 0x4000\_FFFF)
- uncached\_effective := req\_uncached\_bit OR is\_mmio

行為規範：

- 若 is\_mmio=1：一律 bypass L2 arrays（uncached path）。
- 若 is\_ddr=1 且 uncached\_effective=0：走 cached path（L2 lookup）。
- 若 is\_ddr=1 且 uncached\_effective=1：走 uncached bypass path。
- 若位址不在任何合法區間：回 rsp\_err=1，且不得對 MIG 發出交易。

I$ 取指若落到 MMIO 或非法區域，必須回 error（由 core 進一步處理）。
# **4. 上游介面（L1 <-> L2）**
上游介面採 request/response valid/ready 握手。v0.1 規格為全域 single-outstanding，且回應 in-order。
## **4.1 Request channel（請求通道）**

| Signal        | 方向     | 說明                                                          |
| :------------ | :------- | :------------------------------------------------------------ |
| req\_valid    | L1 -> L2 | Request 有效。                                                |
| req\_ready    | L2 -> L1 | L2 可接收 request（僅在無 outstanding 交易時為 1）。          |
| req\_cmd      | L1 -> L2 | 命令（I$ 與 D$ 統一）。                                       |
| req\_addr     | L1 -> L2 | Physical byte address。                                       |
| req\_size     | L1 -> L2 | Uncached 交易大小（例如 4B/8B）。Cached line op 可忽略。      |
| req\_len      | L1 -> L2 | Burst length-1。64B line 且上游 64-bit 時：len=7（8 beats）。 |
| req\_wdata    | L1 -> L2 | 寫入資料（uncached write 或 writeback beats）。               |
| req\_wstrb    | L1 -> L2 | req\_wdata 的 byte strobe（uncached store）。                 |
| req\_uncached | L1 -> L2 | 顯式 uncached 覆寫 bit。                                      |
## **4.2 Response channel（回應通道）**

| Signal     | 方向     | 說明                       |
| :--------- | :------- | :------------------------- |
| rsp\_valid | L2 -> L1 | Response beat 有效。       |
| rsp\_ready | L1 -> L2 | L1 可接收 response beat。  |
| rsp\_rdata | L2 -> L1 | 讀取資料（64-bit beat）。  |
| rsp\_err   | L2 -> L1 | 本次交易錯誤旗標。         |
| rsp\_last  | L2 -> L1 | 標示 burst 最後一個 beat。 |
## **4.3 命令集合（統一）**
L2 命令集合統一如下（編碼由設計常數定義）：

| 命令     | 描述                                                                                               |
| :------- | :------------------------------------------------------------------------------------------------- |
| LINE\_RD | Cached line read（refill）。位址需 64B 對齊。L2 回 8-beat（64-bit）burst。                         |
| WB\_LINE | Write-back 一整條 cache line 到 L2。L1 提供 8-beat（64-bit）burst，位址需 64B 對齊。               |
| UC\_RD   | Uncached read。大小由 req\_size 指示。v0.1 允許至多 8 bytes（必要時拆兩筆 16B-aligned MIG read）。 |
| UC\_WR   | Uncached write。大小由 req\_size 指示，資料/byte-enable 由 req\_wdata/req\_wstrb 提供。            |
## **4.4 仲裁（Arbitration）**
當 I$ 與 D$ 同時請求服務時，L2 仲裁優先序如下：

1. Uncached/MMIO
1. D$ cached
1. I$ cached

公平性：同一優先等級內採 round-robin。
# **5. 下游介面（L2 <-> DDR2 MIG）**
L2 透過 Xilinx MIG 7-series DDR2 native application interface 與 DDR2 互動。所有 MIG user-interface 訊號皆同步於 ui\_clk。
## **5.1 MIG 訊號（使用項）**

| Signal                | 方向      | 說明                                                                                     |
| :-------------------- | :-------- | :--------------------------------------------------------------------------------------- |
| app\_addr[27:0]       | L2 -> MIG | 位址（以 16 bytes 為單位）。                                                             |
| app\_cmd[2:0]         | L2 -> MIG | 命令（read/write）。編碼依 MIG 設定；以常數 MIG\_CMD\_READ / MIG\_CMD\_WRITE 表示。      |
| app\_en               | L2 -> MIG | 命令有效。                                                                               |
| app\_rdy              | MIG -> L2 | 命令可接受（ready）。                                                                    |
| app\_wdf\_data[127:0] | L2 -> MIG | 寫入資料（16 bytes）。                                                                   |
| app\_wdf\_mask[15:0]  | L2 -> MIG | 寫入 byte mask。規格定義 1=mask（不寫），0=寫；若 MIG 實際語意相反，adapter 可取反修正。 |
| app\_wdf\_wren        | L2 -> MIG | 寫資料有效。                                                                             |
| app\_wdf\_end         | L2 -> MIG | write burst 最後一個 beat。                                                              |
| app\_wdf\_rdy         | MIG -> L2 | 寫資料可接受（ready）。                                                                  |
| app\_rd\_data[127:0]  | MIG -> L2 | 讀取資料（16 bytes）。                                                                   |
| app\_rd\_data\_valid  | MIG -> L2 | 讀取資料有效。                                                                           |
| app\_rd\_data\_end    | MIG -> L2 | read burst 最後一個 beat。                                                               |
| ui\_clk               | MIG -> L2 | user interface clock。                                                                   |
| ui\_clk\_sync\_rst    | MIG -> L2 | ui\_clk domain 同步 reset。                                                              |
| init\_calib\_complete | MIG -> L2 | DDR2 校準完成旗標。                                                                      |
## **5.2 位址轉換（PA -> app\_addr）**
DDR2 區域常數（v0.1）：

- DDR\_BASE = 0x8000\_0000
- DDR\_END  = 0x87FF\_FFFF

對任何 targeting DDR2 的交易：

- ddr\_byte\_addr = PA - DDR\_BASE
- app\_addr = ddr\_byte\_addr[31:4]（即 app\_addr = ddr\_byte\_addr >> 4）
- L2 僅能對 16B 對齊位址發出 MIG 命令（PA[3:0]=0）。
## **5.3 Cache line 固定 burst 對映**
一條 64B cache line 對映為 4 個 MIG beats（每 beat 128-bit）。line base 位址：line\_addr = {PA[31:6], 6b0}。第 k 個 beat（k=0..3）使用：app\_addr = ((line\_addr - DDR\_BASE) >> 4) + k。
## **5.4 命令與寫資料握手規則**
Write 操作需要 command 與 write-data 兩個通道皆完成握手。L2 僅在 (app\_en && app\_rdy) AND (app\_wdf\_wren && app\_wdf\_rdy) 同拍成立時，才視為該 beat 已送出。

Read 操作只需 command 握手（app\_en && app\_rdy）。資料於後續以 app\_rd\_data\_valid 回傳；cache line refill 期望 4 個 read beats，並於最後一個 beat 令 app\_rd\_data\_end=1。
# **6. L2 快取行為（Cached path）**
## **6.1 幾何參數（Geometry）**
Capacity=256KiB、2-way、line=64B。sets = 256KiB / (64B \* 2) = 2048 sets；index bits=11；offset bits=6。Tag width = (PA\_W - 17)，其中 PA\_W 為物理位址寬度參數。
## **6.2 查找與命中回應（Hit）**
對 cached request（LINE\_RD），L2 進行 tag lookup 與 data read。v0.1 規格定義 hit latency：自 request acceptance 起算 1 cycle 後開始輸出第一個 response beat（rsp\_valid=1）。

Hit 時，L2 回傳完整 64B line：上游 8-beat（64-bit）burst，並在第 8 beat 令 rsp\_last=1。
## **6.3 Miss 處理（Refill / Eviction）**
Miss 時以 1-bit PLRU 選擇 victim way。若 victim line valid 且 dirty，先 writeback 到 DDR2（4 MIG beats）。接著自 DDR2 refill 目標 line（4 MIG beats），更新 tag/valid/dirty，最後回應上游 8-beat burst。
## **6.4 寫入與 store merge**
L2 採 write-back + write-allocate。對 cached store 的 sub-line 更新，L2 以 byte-enable 進行 store merge，並標記 dirty。

WB\_LINE 語意：L1 提供完整 64B（8 upstream beats）。L2 若該 line 不存在則 allocate；以提供的 beats 填入資料並更新 tag/valid，並將 dirty 置 1。
# **7. Uncached 操作（Bypass path）**
Uncached 交易會 bypass L2 arrays，直接透過 MIG 存取 DDR2。當 req\_uncached=1 或位址落於 MMIO 區域時，選用 uncached path。
## **7.1 Uncached read**
v0.1 uncached read 支援總長度至多 8 bytes。L2 以 16B 對齊方式對 MIG 發出 read，並從 app\_rd\_data 擷取所需 bytes。若 requested byte range 跨越 16B boundary，L2 拆成兩筆 MIG read，並在 L2 端拼接。
## **7.2 Uncached write**
v0.1 uncached write 支援總長度至多 8 bytes，並以 MIG byte mask 實作 byte-enable。L2 對齊到 16B boundary，產生 app\_wdf\_data 與 app\_wdf\_mask，使得僅指定 bytes 被寫入。若 requested byte range 跨越 16B boundary，L2 拆成兩筆 MIG write。
# **8. Reset / 校準 / 錯誤處理**
## **8.1 校準 gating**
在 init\_calib\_complete=1 且 ui\_clk\_sync\_rst=0 之前，L2 不得發出任何 MIG 命令。此期間 L2 必須對 I$/D$ 解除 req\_ready（backpressure），使整機停等。
## **8.2 L2 reset 行為**
Reset 後 L2 清除所有 tag array 的 valid 與 dirty。Replacement 狀態（PLRU）重置為 deterministic 值（例如：初始 victim 固定選 way0，直到更新）。
## **8.3 錯誤條件（rsp\_err）**
- 位址超出 address map：rsp\_err=1，且不得對 MIG 發交易。
- Uncached size > 8 bytes：rsp\_err=1。
- Cached line op burst 非法（上游 64B line 但 len != 7）：rsp\_err=1。
- I$ 取指到 MMIO/非法區：rsp\_err=1。
# **9. 驗證檢查清單（v0.1）**
- Cached hit：回傳正確 64B line（8 upstream beats）。
- Cached miss：可由 DDR2 refill（4 MIG beats）並正確更新 tag/valid。
- Dirty eviction：refill 前先完成 writeback（4 MIG beats）。
- WB\_LINE：可 allocate/更新 line 並標記 dirty。
- Uncached read/write：bypass 正確、byte-enable 正確；跨 16B boundary 之拆分/拼接正確。
- 仲裁優先序與 round-robin 公平性符合規格。
- 無 request/response 漏失：single-outstanding invariant 成立。
