# RV32IM + FreeRTOS 實板效能分析結果

日期：2026-07-15  
板子：Nexys A7-100T  
核心時脈：50 MHz  
映像：RTOS Console，`perf test 100000`

這份數據是在重新上傳 Console、核心/cache reset 後，第一個 workload 命令取得。
因此 workload 本身是首次執行；RTOS/Console 啟動程式碼則已經走過 cache。

## FPGA implementation

| 項目 | 結果 |
|---|---:|
| Setup WNS | `+0.202 ns` |
| Hold WHS | `+0.015 ns` |
| Routing errors | 0 |
| Slice LUT | 27,158 / 63,400（42.84%） |
| Slice FF | 17,746 / 126,800（14.00%） |
| BRAM tile | 16 / 135（11.85%） |
| DSP | 0 |
| bitstream SHA-256 | `30890F6F3F3DB089DFE0A50D0290D03CB7B539CD09B66942D33B895E405141CB` |

相較加入計數器前的 24,725 LUT / 14,613 FF，增加 2,433 LUT 與 3,133 FF。
FF 增量主要就是 24 組 64-bit live bank 加 24 組 64-bit snapshot bank。
最差 setup path 已回到 `MEM addr_q -> I-cache PLRU`，endpoint 不在 performance
counter；PERF MMIO 的一拍註冊 response 已成功把 read mux 從核心控制路徑隔離。

## 實板原始摘要

```text
PERF_TEST iterations=100000 result=0x7CFED607
PERF cycles=5791940 instret=1085672 ipc=0.187 overflow=0
PERF_STALL frontend=0.776 backend=0.043 load_use=0.000 ex_busy=0.000
PERF_CTRL branch=205002 taken=101407 jumps=103594 miss=2429 miss_rate=0.007
PERF_CACHE i=5/1088998 i_miss=0.000 d=0/49975 d_miss=0.000 wb_beats=0
PERF_MEM load=29655 store=21063 mmio_r=394 mmio_w=349 ddr_r=16 ddr_w=0
PERF_SYSTEM exception=391 interrupt=116 flush=3443
PERF_TEST_PASS
```

Console 的三位小數是千分比顯示，所以 `frontend=0.776` 代表 77.6%，
不是 0.776%。

## 結論

### 1. 目前主要瓶頸在 front end，不在 DDR 或 D-cache

- 精確 IPC 約 `0.18745`，CPI 約 `5.335`。
- front-end stall 約 77.6%，backend stall 約 4.3%。stall 類別可能重疊，
  但量級差距已足以判斷主因。
- I-cache 只有 5 / 1,088,998 次 miss，約 `0.000459%`；D-cache miss 為 0。

這表示低 IPC 不是 cache miss 太多，而是目前 fetch request/response、`if_pending`
與 blocking front-end 控制讓 hit path 仍無法每 cycle 供應一條指令。若之後要提升這顆
in-order core 的效能，優先項應是讓 I-cache hit 能 pipeline/連續供應，或加入 fetch
queue，而不是先擴大 cache。

### 2. branch predictor 已不是最大損失來源

- conditional branch 205,002 次，jump 103,594 次。
- recovery redirect 2,429 次。
- control-flow miss rate 精確約 `0.787%`。

這個命中率對目前 workload 已經不差；即使完全消除 mispredict，也無法解釋 77.6%
的 front-end stall。未來 superscalar 核心仍需要更完整的 BTB/RAS，但在目前核心上，
先改善 fetch throughput 的收益會更高。

### 3. counter 事件分類通過交叉一致性檢查

Memory 分類完全閉合：

```text
loads + stores
= 29,655 + 21,063
= 50,718

D-cache accesses + MMIO reads + MMIO writes
= 49,975 + 394 + 349
= 50,718
```

Pipeline flush 也完全閉合：

```text
control mispredict                         2,429
391 次 taskYIELD exception + 391 次 mret     782
116 次 timer interrupt + 116 次 mret          232
------------------------------------------------
pipeline flush                            3,443
```

`run_workload()` 每 256 iteration 呼叫一次 `taskYIELD()`；100,000 iteration
正好產生 391 次 yield exception，與 counter 相符。這些關係證明 load/store/MMIO、
trap/mret 與 redirect 沒有明顯重複計數或漏計。

### 4. cache/DDR 數據代表此 workload 的工作集合很小

- 首次 workload 只增加 5 次 I-cache line fill 與 16 次 L2-to-DDR read command。
- D-cache miss、writeback、DDR write 都是 0。
- 第二次相同 workload 的 DDR read 變成 0，符合 L2 已暖機。

因此這個內建 workload 適合檢查 pipeline、branch、RTOS interrupt/yield 與 counter
一致性，但不適合評估大 working-set 的 memory bandwidth。要測 cache/DDR，應再加入
大於 L1/L2 容量的 streaming、random-access 與 dirty-eviction benchmark。

## 與未來 superscalar 核心比較時

保留同一份 counter index/ABI、同一個 `.mem` workload、同一個 50 MHz（或同時報告
頻率），並分別記錄首次執行與 warm-cache 執行。最重要的比較欄位是：

- IPC / CPI
- front-end、backend、EX busy stall ratio
- control-flow miss rate
- I/D cache miss rate
- DDR commands per 1,000 retired instructions
- LUT/FF/BRAM/DSP 與 timing margin

若 superscalar 只提高 issue width，卻沒有解除目前 fetch throughput 限制，IPC 不會按
寬度成比例提升；這份結果已把該風險量化出來。
