# MMIO 效能計數器與分析指南

這組硬體計數器用來量化目前的 in-order RV32IM 核心，也可作為未來
superscalar 核心的共同比較介面。ABI version 為 `1`，共有 24 組 64-bit
counter；核心 reset 後預設開始計數。

## MMIO register map

Base address：`0x4000_0100`

| 位址 | 名稱 | 說明 |
|---|---|---|
| `+0x00` | ID | 固定為 `0x50455246`（ASCII `PERF`） |
| `+0x04` | INFO | `[31:16]` ABI version，`[7:0]` counter 數量 |
| `+0x08` | CONTROL | bit0 enable；bit1 clear；bit2 snapshot；bit3 release snapshot |
| `+0x0C` | STATUS | bit0 enable；bit1 snapshot valid；bit2 曾發生 64-bit overflow |
| `+0x10 + 8*n` | COUNTER[n] low | counter 低 32-bit |
| `+0x14 + 8*n` | COUNTER[n] high | counter 高 32-bit |

每次寫 CONTROL 都會用 bit0 更新 enable；bit1～bit3 是單次命令。因此常用值為：

| 寫入值 | 動作 |
|---|---|
| `0x3` | 清零並開始 |
| `0x2` | 清零並停止 |
| `0x5` | 保持運行並建立 snapshot |
| `0x4` | 停止並建立 snapshot |
| `0x9` | 釋放 snapshot，繼續運行 |
| `0x8` | 釋放 snapshot，保持停止 |

snapshot 會在同一個 clock edge 複製全部 24 組 counter。只要 STATUS.bit1
仍為 1，low/high 讀取都來自固定的 shadow bank，因此不會發生 low/high
跨越進位而撕裂的問題；live bank 可同時繼續計數。

PERF page 使用一拍 request/response：CPU 接受 MMIO request 後，下一個 core cycle
回傳資料。這個註冊邊界隔離了大型 counter read mux，不改變軟體位址或 API；MEM
stage 會自動等待 response。

## Counter 定義

| n | low 位址 | 名稱 | 精確事件 |
|---:|---:|---|---|
| 0 | `0x4000_0110` | cycles | enable 期間的 core clock |
| 1 | `0x4000_0118` | instret | 到達 WB 的有效指令，包含不寫 rd 的 branch/store |
| 2 | `0x4000_0120` | frontend_stall | `stall_if` 為 1 的 cycle |
| 3 | `0x4000_0128` | backend_stall | MEM stage 等待 memory response 的 cycle |
| 4 | `0x4000_0130` | load_use | ID 相依於 EX load rd 的 hazard cycle |
| 5 | `0x4000_0138` | ex_busy | multi-cycle EX（目前為 mul/div）忙碌 cycle |
| 6 | `0x4000_0140` | branches | EX 接受的 conditional branch |
| 7 | `0x4000_0148` | branch_taken | 實際 taken 的 conditional branch |
| 8 | `0x4000_0150` | jumps | EX 接受的 JAL/JALR |
| 9 | `0x4000_0158` | control_mispredict | branch direction 或 control target 預測錯誤造成的 recovery redirect |
| 10 | `0x4000_0160` | loads | EX 接受的 load |
| 11 | `0x4000_0168` | stores | EX 接受的 store |
| 12 | `0x4000_0170` | icache_access | I-cache 接受的 CPU fetch request |
| 13 | `0x4000_0178` | icache_miss | I-cache 發出的 L2 line-fill request |
| 14 | `0x4000_0180` | dcache_access | D-cache 接受的非 MMIO CPU request |
| 15 | `0x4000_0188` | dcache_miss | load line fill 或 no-write-allocate store miss |
| 16 | `0x4000_0190` | dcache_wb_beats | D-cache 向 L2 寫回的 64-bit beat；一條 64-byte line 是 8 beats |
| 17 | `0x4000_0198` | mmio_read | 成功完成的 local MMIO read |
| 18 | `0x4000_01A0` | mmio_write | 成功完成的 local MMIO write |
| 19 | `0x4000_01A8` | ddr_read | L2 被 MIG 接受的 DDR read command |
| 20 | `0x4000_01B0` | ddr_write | L2 被 MIG 接受的 DDR write command |
| 21 | `0x4000_01B8` | exceptions | 同步 exception/trap |
| 22 | `0x4000_01C0` | interrupts | CPU 實際接受的 machine interrupt |
| 23 | `0x4000_01C8` | pipeline_flush | mispredict recovery 或 trap/interrupt/mret flush |

bootloader 與上電 DDR memory-test 在 core reset 期間運作，不列入 DDR counter。
load/store counter 的定義是「EX 接受」，所以 misaligned 指令在進入 trap 前仍可能加 1。
frontend/backend/load-use 等 stall 類別可能在同一 cycle 重疊，不應把各比例直接相加。

## 在 RTOS Console 使用

上板後執行：

```text
perf test 100000
```

它會清零、執行內建 workload、停止並輸出：cycles、instret、IPC、stall
比例、control-flow miss rate、I/D cache miss rate、DDR traffic、exception 與
interrupt 數量。

量測任意工作區段：

```text
perf reset
work 100000
perf stop
```

其他命令：

- `perf` 或 `perf show`：不中止 live counter，建立暫時 snapshot 並顯示摘要。
- `perf raw`：列出全部 24 個原始值。
- `perf start`：不清零，繼續計數。
- `perf stop`：停止、snapshot 並分析。

Console 顯示的小數為千分比格式。例如 `ipc=0.250` 代表 IPC 0.25，
`i_miss=0.012` 代表 I-cache miss rate 1.2%。

## 在其他 C / FreeRTOS app 使用

`tools/build_rtos_app.ps1` 已經把 `perf_counters.c` 加入所有 profile。應用程式只需：

```c
#include "perf_counters.h"

PerfCounterSnapshot_t result;
perf_counters_reset_start();
/* workload */
perf_counters_snapshot( &result, 1 );
```

`result.value[PERF_CYCLES]` 與其他欄位都是 `uint64_t`。若只要非侵入式
取樣，把 `stop_after` 傳 0；API 讀完 shadow bank 後會自動 release snapshot。

## 建議比較指標

- `IPC = instret / cycles`
- `control miss rate = control_mispredict / (branches + jumps)`
- `I-cache miss rate = icache_miss / icache_access`
- `D-cache miss rate = dcache_miss / dcache_access`
- `front/back stall ratio = stall_cycles / cycles`
- `DDR commands per 1k instructions = ddr_commands * 1000 / instret`

未來 superscalar 核心應保留相同 index 與語意；若增加 counter，增加 INFO 的
count 即可。若既有語意改變，必須提升 ABI version。

目前 in-order 核心的實板數據、硬體成本與瓶頸分析見
`explain_files_md/PERFORMANCE_ANALYSIS_RESULT.md`。
