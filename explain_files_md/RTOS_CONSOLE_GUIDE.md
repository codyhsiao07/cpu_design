# RTOS Console 使用指南

`console` 是第一個可透過 UART 操作的正式 FreeRTOS 應用程式。它不只是在迴圈裡呼叫 API，而是把輸入、命令解析、背景工作與存活監測拆成獨立 Task，並用 Queue 傳遞資料。

## 一鍵編譯、預檢並上板

先關閉 PuTTY、Tera Term 等占用 COM5 的程式，再於專案根目錄執行：

```powershell
.\tools\run_rtos_app.ps1 -Port COM5 -App console
```

工具會自動完成：

1. 編譯 `main_console.c` 與 FreeRTOS。
2. 先要求仍在執行的舊 Console 自動回到 bootloader。
3. 上傳短版 preflight，驗證 CPU、scheduler、timer tick、Queue 與 UART TX；無回覆時自動重傳一次。
4. 收到 `RTOS_PREFLIGHT_PASS` 後讓 bootloader 重新待命。
5. 上傳 Console 應用程式；若沒有收到啟動標記，會自動 reload 並重傳一次。
6. 收到 `APP_READY` 後進入互動終端機。

看到下面內容即可開始輸入：

```text
RTOS_CONSOLE_BOOT
APP_READY
RTOS Console ready. Type 'help'.
>
```

按 `Ctrl+C` 只會離開電腦端終端機，不會停止 FPGA 上的程式。使用新版 host-sync recovery bitstream 時，可直接再次執行上板命令，工具會自動讓 bootloader 接管；`reload` 仍可用於手動切換。只有自動重傳也失敗時，才需要按板上的 `CPU RESET`。

## 可用命令

| 命令 | 功能 |
|---|---|
| `help` | 顯示命令列表 |
| `ping` | 回覆 `PONG` 與目前 tick |
| `status` | 顯示 heartbeat、命令數、工作數、Queue 深度及 UART 錯誤統計 |
| `tasks` | 顯示 Console 的 Task、priority 與角色 |
| `echo <文字>` | 回傳輸入文字 |
| `work [次數]` | 將工作送進 Queue；範圍 1–100000，預設 1000 |
| `reload` | 結束目前應用程式並重新開啟 UART bootloader |

範例：

```text
> ping
PONG tick=7342
> work 256
WORK queued id=1 iterations=256
WORK done id=1 result=0x06305D75
> status
STATUS tick=7425 heartbeat=7 commands=3 lines=3
```

## FreeRTOS 架構

| Task | Priority | 職責 |
|---|---:|---|
| `console_rx` | 3 | 輪詢 UART RX、echo、退格與整行輸入 |
| `console_cmd` | 2 | 解析命令並輸出結果 |
| `worker` | 1 | 從工作 Queue 取件並執行可重現的背景運算 |
| `heartbeat` | 1 | 週期性增加存活計數器 |
| `IDLE` | 0 | FreeRTOS idle task |

資料路徑如下：

```text
UART RX -> console_rx -> command queue -> console_cmd
                                      -> work queue -> worker
                                      <- result queue <- worker
```

目前 UART RX 硬體是單一 byte holding register，沒有 FIFO。互動工具已將鍵盤輸入限制為每字元約 2 ms，避免一次貼上大量文字造成遺失；`status` 的 `rx_overrun`、`line_overflow`、`command_drop` 可用來檢查異常。

目前板上 LED 仍是硬體診斷訊號，尚未提供軟體 GPIO MMIO，因此 Console 暫時不能用命令控制 LED。這需要另外加入 GPIO 周邊與位址映射。

## 自動驗證

板上已經在執行 Console 時，可以用另一個終端機測試主要命令：

```powershell
python .\tools\rtos_console_probe.py --port COM5
```

它會依序驗證 `ping`、`status`、`tasks`、`echo` 與 `work`。執行前必須先離開互動終端機，確保 COM5 沒有被占用。

不接 FPGA 的完整 RTL / FreeRTOS 啟動模擬：

```powershell
.\tools\run_rtos_console_sim.ps1
```

模擬必須看到 `RTOS_CONSOLE_BOOT` 與 `APP_READY`，並且不得出現 trap、assert 或 timeout。
