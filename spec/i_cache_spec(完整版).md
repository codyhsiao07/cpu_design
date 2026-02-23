**I-Cache 規格書 (Draft v1)**

日期：2026-01-29  |  目標：in-order 5-stage 單核 L1 I$ (L2 共用)
# **1. 範圍與假設**
本文件定義 L1 I-Cache (I$) 的架構、時序、miss 行為、flush/uncacheable 規則與效能計數器。

- 核心：in-order 5-stage，單核。
- L2：I$/D$ 共用的 unified L2，I$ 透過 L2 取得 refill 資料。
- 無 MMU/TLB (後續可擴充)。
- 指令寬度：32-bit，PC 需 4-byte 對齊；不支援 RVC (16-bit compressed) 於 v1。
- I$ 為 read-only cache：無 dirty bit、無 write-back / write-allocate 概念。
# **2. 介面與訊號定義**
本節定義 I$ 與 CPU 前端 (IF) 及 L2/Memory 之介面訊號、握手規則與時序假設。v1 以單一 outstanding miss/uncached request (blocking) 為前提；未來如導入 non-blocking/MSHR 需擴充介面。
## **2.1 Clock/Reset**

| **訊號** | **方向(相對 I$)** | **位寬** | **說明**   | **備註/時序**                                     |
| :------- | :---------------- | :------- | :--------- | :------------------------------------------------ |
| clk      | In                | 1        | 系統時脈   | 上升沿觸發                                        |
| rst\_n   | In                | 1        | 低有效重置 | v1 建議同步重置；重置後 valid 全清、狀態回到 IDLE |
## **2.2 CPU Fetch Interface**
I$ 與 CPU 之取指介面採 ready/valid 握手。CPU 於 if\_req\_valid=1 時提供 if\_req\_addr；當 if\_req\_ready=1 且握手成立 (valid&ready) 時 I$ 接收該筆取指請求。I$ 於 IF2 產生回應 (hit 時固定 2 cycles latency；miss 時於 refill 完成後再回應)。若 CPU 不使用回應 backpressure，可將 if\_resp\_ready 綁定為 1。

| **訊號**        | **方向(相對 I$)** | **位寬**    | **說明**                          | **備註/時序**                                               |
| :-------------- | :---------------- | :---------- | :-------------------------------- | :---------------------------------------------------------- |
| if\_req\_valid  | In                | 1           | 取指請求有效                      | CPU 拉高表示要取 if\_req\_addr 指令                         |
| if\_req\_addr   | In                | ADDR\_WIDTH | 取指位址 (PC)                     | 必須 4B 對齊；uncacheable 判斷使用此位址                    |
| if\_req\_ready  | Out               | 1           | I$ 可接受取指請求                 | miss/refill/flush 期間可為 0；CPU 應維持 addr 穩定直到握手  |
| if\_req\_kill   | In                | 1           | 取消/清除 in-flight 取指回應      | 用於 branch redirect/flush；不取消已發出的 refill 交易 (v1) |
| if\_resp\_valid | Out               | 1           | 取指回應有效                      | 與 if\_resp\_ready 握手；有效期間 inst/pc/err 保持穩定      |
| if\_resp\_ready | In                | 1           | CPU 可接受取指回應                | 若無 IF2 backpressure，綁定為 1                             |
| if\_resp\_inst  | Out               | 32          | 指令資料                          | RV32 指令字；不支援 RVC 於 v1                               |
| if\_resp\_pc    | Out               | ADDR\_WIDTH | 對應之 PC                         | 用於 debug/trace；可選擇不輸出                              |
| if\_resp\_err   | Out               | 1           | 取指錯誤 (bus error/access fault) | 由 L2/memory 回報；CPU 可將其轉成 exception                 |
## **2.3 Control/Management Interface**
控制介面用於 fence.i flush、debug/OS invalidate 與狀態查詢。flush/invalidate 期間 I$ 會暫停接受新的取指請求。

| **訊號**       | **方向(相對 I$)** | **位寬**    | **說明**                      | **備註/時序**                                       |
| :------------- | :---------------- | :---------- | :---------------------------- | :-------------------------------------------------- |
| ic\_flush\_req | In                | 1           | Flush-all 請求 (對應 fence.i) | 拉高後 I$ 清除全部 valid；完成後送出 ic\_flush\_ack |
| ic\_flush\_ack | Out               | 1           | Flush-all 完成指示            | 可為 1-cycle pulse；flush 完成前 if\_req\_ready=0   |
| ic\_inv\_valid | In                | 1           | Invalidate 請求 (可選)        | 用於 debug/OS；若不支援可忽略並回覆 ack=0           |
| ic\_inv\_all   | In                | 1           | Invalidate all                | 1=全清 valid；0=依 index/way 清除                   |
| ic\_inv\_index | In                | INDEX\_BITS | Invalidate index              | 僅 ic\_inv\_all=0 時有效                            |
| ic\_inv\_way   | In                | 1           | Invalidate way                | 0/1 對應 way0/way1；僅 ic\_inv\_all=0 時有效        |
| ic\_inv\_ack   | Out               | 1           | Invalidate 完成指示           | 可為 1-cycle pulse                                  |
## **2.4 L2/Memory Refill Interface**
I$ 對下游 (L2 或 memory bus) 採用單一請求/回應通道。v1 僅允許一個 outstanding transaction，因此不需要 ID/reorder；回應必須 in-order 回來。對 cacheable miss，I$ 發出 LINE\_FILL 讀取整條 64B line；對 uncacheable bypass，I$ 發出 UC\_READ 讀取單一 32-bit 指令字。

| **訊號**       | **方向(相對 I$)** | **位寬**    | **說明**                  | **備註/時序**                                                        |
| :------------- | :---------------- | :---------- | :------------------------ | :------------------------------------------------------------------- |
| l2\_req\_valid | Out               | 1           | 下游讀取請求有效          | 與 l2\_req\_ready 握手                                               |
| l2\_req\_ready | In                | 1           | 下游可接受請求            | ready=0 時 I$ 必須保持 addr/cmd/len/size 穩定                        |
| l2\_req\_addr  | Out               | ADDR\_WIDTH | 讀取起始位址              | LINE\_FILL 時需 line-aligned；UC\_READ 時為該指令位址                |
| l2\_req\_cmd   | Out               | 2           | 請求型別                  | 00=LINE\_FILL, 01=UC\_READ (其餘保留)                                |
| l2\_req\_size  | Out               | 3           | 每 beat 大小 (log2 bytes) | 例如 3'b010 表示 4B；依下游資料寬度調整                              |
| l2\_req\_len   | Out               | 8           | burst 長度 (beats-1)      | LINE\_FILL 時 = LINE\_BYTES/(L2\_DATA\_W/8)-1；UC\_READ 時 = 0       |
| l2\_rsp\_valid | In                | 1           | 回應資料有效              | 與 l2\_rsp\_ready 握手；data/last/err 在 valid 期間保持穩定          |
| l2\_rsp\_ready | Out               | 1           | I$ 可接受回應資料         | I$ 在等待回應/寫入 SRAM 時拉高                                       |
| l2\_rsp\_data  | In                | L2\_DATA\_W | 回應資料                  | LINE\_FILL 以 beat 連續回傳；UC\_READ 使用低 32 bits (little-endian) |
| l2\_rsp\_last  | In                | 1           | 最後一個 beat             | UC\_READ 必為 1；LINE\_FILL 於最後一拍為 1                           |
| l2\_rsp\_err   | In                | 1           | 回應錯誤                  | 下游 bus error/permission fault；I$ 需對 CPU 回報 if\_resp\_err      |
## **2.5 Event/Counter Export (Optional)**
若核心以 CSR 或 debug bus 讀取 I$ 計數器，可直接讀取內部寄存器；或由 I$ 輸出事件脈衝供外部計數。v1 建議至少輸出下列事件 (1-cycle pulse)：ic\_evt\_access, ic\_evt\_hit, ic\_evt\_miss, ic\_evt\_refill\_done, ic\_evt\_flush, ic\_evt\_uncached。
# **3. 主要參數 (Config)**

| **項目**           | **值 (v1)**         | **備註**                              |
| :----------------- | :------------------ | :------------------------------------ |
| 容量 (I$ size)     | 64 KB               | L1 I$ 容量                            |
| Line size          | 64 B                | 一個 cache line = 64 bytes            |
| Associativity      | 2-way               | 2-way set associative                 |
| Set 數量           | 512 sets            | 64KB / (64B \* 2) = 512               |
| Replacement        | Pseudo-LRU          | 2-way 以 1-bit PLRU 實作              |
| Hit latency        | 2 cycles            | 採用 2-stage fetch pipeline (IF1/IF2) |
| Miss policy        | Blocking            | miss 期間停止取指直到 refill 完成     |
| Refill outstanding | 1                   | v1 僅允許 1 個 in-flight miss         |
| Prefetch           | Disabled            | v1 不做 prefetch；保留介面            |
| Uncacheable        | Region-based bypass | 支援固定區段 bypass (不配置到 I$)     |
# **4. 位址切割 (Tag/Index/Offset)**
本 I$ 使用 byte-addressed 位址。line size = 64B => offset = 6 bits；sets = 512 => index = 9 bits。tag bits 依系統實際位址寬度決定。

- OFFSET\_BITS = log2(64) = 6  (addr[5:0])
- INDEX\_BITS  = log2(512) = 9  (addr[14:6])
- TAG\_BITS    = ADDR\_WIDTH - INDEX\_BITS - OFFSET\_BITS  (addr[ADDR\_WIDTH-1:15])

指令 word 選擇：假設 32-bit instruction，word index = addr[5:2] (一個 line 有 16 個 32-bit words)。
# **5. 取指 Pipeline 與時序**
I$ 以 2 階段 pipeline 服務取指，提供每 cycle 1 條指令的理論吞吐 (無 stall 時)。
## **5.1 IF1：Array read (tag + data)**
- 輸入：PC (byte address)
- 行為：以 index=PC[14:6] 同時讀取 way0/way1 的 Tag RAM 與 Data RAM
- 輸出暫存：兩個 way 的 (valid, tag, line\_data) 進入 IF2 比對
## **5.2 IF2：Tag compare + select + deliver**
- Tag compare：命中條件 valid && (tag == PC\_tag)
- Way select：若兩 way 同時命中 (理論上不應發生)，way0 優先並視為錯誤事件
- Word select：以 PC[5:2] 從 line\_data 擷取 32-bit instruction，送往 Decode
- PLRU update：命中 way0 則該 set 的 plru\_bit<=1；命中 way1 則 plru\_bit<=0 (定義 victim=plru\_bit 指向的 way)

Hit latency 定義：IF1 發出 PC 的當下算第 0 cycle，IF2 末端輸出 instruction 送入 Decode，故 hit latency=2 cycles。
# **6. Miss 行為與 Refill 流程 (Blocking)**
v1 為 blocking I$：偵測 miss 後，取指前端停住直到 refill 完成並更新 tag/valid。miss 期間不允許新的取指讀 array (single-port 限制)。
## **6.1 Victim 選擇**
- 若 set 內有 invalid way：優先選 invalid way 作為 victim (避免不必要替換)
- 否則：使用 plru\_bit 指示 victim way (2-way pseudo-LRU)
## **6.2 Refill Request/Response**
- Refill address：line-aligned = {PC[ADDR\_WIDTH-1:6], 6'b0}
- 下游介面需支援一次取得整個 64B line (burst 或多拍回傳)
- Refill 完成後依序寫入 Data RAM (64B) -> Tag RAM (tag) -> Valid=1
- Refill 期間若發生 branch redirect/flush：仍允許 refill 完成 (不取消)，完成後以最新 PC 重新啟動取指
## **6.3 Miss penalty 與重新取指**
miss penalty 由 L2/memory latency 決定。Refill 完成後，下一個 cycle 重新進入 IF1 讀 array；因此 miss 後首次可輸出指令通常為 refill 完成後 +2 cycles (IF1/IF2)。
# **7. Flush/Invalidate、Ordering 與 Self-modifying Code**
單核、無 coherence。I$ 與 D$ 的可見性由軟體 fence 保證。v1 定義與 RISC-V fence.i 等價的 I$ flush 行為。
## **7.1 fence.i 語意 (v1)**
1. fence.i 之前的所有 store (可能由 D$ 寫回/寫穿) 必須先對 memory 可見。實作上：等待 L2 回覆 'write complete' 或 drain write buffer (若未來加入)。
1. I$ 執行全域 invalidate：清除全部 valid bits (flush all)。
1. flush 完成後，後續取指一定能觀察到 fence.i 之前對指令記憶體的修改 (支援 self-modifying code)。
## **7.2 Invalidate 介面 (Debug/OS 擴充)**
- 必要：invalidate\_all (對應 fence.i)
- 可選：invalidate\_by\_index\_way(index, way) 作為 debug/test hook；若實作，操作期間需 stall 取指
# **8. Uncacheable (Bypass) 規則**
由於無 MMU，uncacheable 使用固定區段判斷。v1 建議提供 1 組可參數化的 base/mask，匹配時 bypass I$ 直接向 L2 取 32-bit 指令，不配置到 I$。

- UNC\_BASE, UNC\_MASK：若 (PC & UNC\_MASK) == (UNC\_BASE & UNC\_MASK) 則視為 uncacheable
- uncached fetch：向 L2 發 single-beat read；回傳後直接送往 Decode，不寫入 I$ tag/data
- 若不需要從 MMIO/ROM 執行：可將 UNC\_MASK 設為 0 以關閉此功能
# **9. 錯誤處理**
- 若 L2 回覆 bus error / access fault：I$ 需回報 fetch\_fault 給 CPU，觸發 instruction access fault 例外。
- Miss/replay 簡化：blocking 設計下，fault 發生時不會有多筆等待者。
# **10. 監測與效能計數器 (建議)**
建議提供以下 64-bit saturating counters (或可讀 CSR) 以利 debug/效能分析：

| **Counter 名稱**         | **計數時機**                  | **備註**                   |
| :----------------------- | :---------------------------- | :------------------------- |
| icache\_access           | 每次 IF1 發出一個取指請求     | 含 hit/miss/uncached       |
| icache\_hit              | IF2 tag compare 命中          |                            |
| icache\_miss             | IF2 判定 miss 且啟動 refill   |                            |
| icache\_refill\_line     | 每完成一個 64B line refill    | burst 完成後 +1            |
| icache\_stall\_cycles    | 前端因 I$ stall 的 cycle 數   | miss / flush / uncached 等 |
| icache\_flush\_all       | 每次執行 invalidate\_all      | 對應 fence.i               |
| icache\_uncached\_access | 每次 uncacheable bypass fetch |                            |
| icache\_error            | 每次下游回覆 fetch\_fault     |                            |
# **11. 保留介面與未來擴充**
- 分支預測接口：保留 redirect/flush/btb/bht 等訊號介面，但 v1 可不實作 predictor。
- Non-blocking / MSHR：v2 可擴充為 hit-under-miss (至少 2 entries MSHR)，提升 miss hiding 能力。
- RVC 支援：若支援 16-bit 指令，需要處理跨 word/跨 line 的取指與對齊問題。
- MMU/TLB：引入 VA/PA 後需重新定義 tag 使用 PA、以及 ASID/flush 規則。
