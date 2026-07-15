# RTOS Platform v1：大型軟體移植前置層

## 結論

目前這個 CPU 的 FreeRTOS 軟體層已不只會執行 Task 與 Queue。`platform` profile 會在開機時自動測試大型應用常用的 RTOS 與 runtime 能力，全部成功後才輸出：

```text
RTOS_PLATFORM_PASS
```

這表示可以開始移植較大型的單一應用，例如直譯器、遊戲邏輯、通訊協定或資料處理程式。它不代表 DOOM 所需的檔案系統、鍵盤、音效與顯示抽象已經完成；那些是下一層的周邊與應用平台工作。

## 已完成的前置能力

- 8 MiB DDR linker 配置。
- 64 KiB 獨立 startup/ISR stack。
- 2 MiB FreeRTOS `heap_4`，放在 NOLOAD 區段，開機不會清零整個 heap。
- `malloc`、`free`、`calloc`、`realloc` 的最小 C runtime 包裝。
- 動態與靜態 Task 配置。
- mutex、recursive mutex、counting semaphore、queue set。
- event group、stream buffer、software timer。
- runtime counter、Task 狀態與 stack high-water mark。
- malloc failure、stack overflow、assert、exception 與 unexpected interrupt 診斷。
- UART RX machine external interrupt 與 FreeRTOS-safe stream buffer。
- 通用建置器統一收錄 FreeRTOS kernel 模組，舊 smoke 建置不再維護第二份來源清單。

## 一鍵上板自測

FPGA 接在 `COM5` 時執行：

```powershell
.\tools\run_rtos_app.ps1 -Port COM5 -App platform
```

工具會依序：

1. 編譯並上傳短版 preflight。
2. 等待 `RTOS_PREFLIGHT_PASS`。
3. 上傳 `rtos_platform.mem`。
4. 等待 `RTOS_PLATFORM_PASS`。
5. 進入互動 UART terminal。

Platform 可輸入：

```text
irqping
stats
reload
```

- `irqping`：確認輸入字元確實經 UART 中斷進入 FreeRTOS stream buffer。
- `stats`：顯示 tick、Task 數、heap 剩餘量、heap 最低水位與 UART error counters。
- `reload`：回到 UART bootloader，準備換另一個 `.mem`。

若只想做自動命令探測：

```powershell
python .\tools\rtos_platform_probe.py --port COM5
```

## RTL 模擬

```powershell
.\tools\run_rtos_platform_sim.ps1
```

測試會在 RTL CPU 上執行真正的 FreeRTOS 映像，不是 host-side mock。失敗時會保留 log：

```text
build_rtos_platform_sim\rtos_platform_sim.log
```

## 建立下一個應用

固定應用可在 `tools/build_rtos_app.ps1` 的 profile table 新增名稱、main source 與額外 driver source。臨時應用也可直接指定：

```powershell
.\tools\run_rtos_app.ps1 `
  -Port COM5 `
  -MainSource OS\rtos\src\main_my_app.c `
  -ExtraSource drivers\my_driver.c `
  -TargetMarker MY_APP_READY
```

每個 `.mem` 都是「FreeRTOS kernel + 共用 platform/runtime + 該應用」的完整 firmware。切換軟體時仍會重新上傳 `.mem`，但不需要重新產生 bitstream；只有修改 CPU 或周邊 RTL 才需要重做 bitstream。

## 實測結果（2026-07-14）

| 測試 | 結果 |
|---|---|
| Platform RTL 綜合自測 | PASS |
| 原 RTOS smoke RTL 回歸 | PASS |
| preflight RTL 回歸 | PASS |
| Console RTL 回歸 | PASS |
| COM5 preflight + Platform 上板 | PASS |
| COM5 `irqping` / `stats` | PASS，UART overrun=0、stream drop=0 |
| COM5 Console 五命令回歸 | PASS |

實板上傳偶爾需要重新同步，因此通用上板工具預設使用 16 KiB SYNC preamble，preflight 與 target 最多各嘗試 3 次；成功仍以 firmware marker 為準，不會只因資料送完就判定通過。

## 下一階段還缺什麼

若目標是 DOOM 或其他有資產的大型程式，建議依序補：

1. 統一 platform API（clock、input、framebuffer、storage）。
2. 無 VGA 螢幕期間先以 UART command/input 與記憶體 checksum 驗證遊戲主迴圈。
3. WAD/資產載入方式：先做編譯內嵌或 UART upload，再考慮 SPI flash/SD 與檔案系統。
4. framebuffer 抽象與轉色/縮放路徑。
5. 需要聲音時再加入 audio driver；它不阻擋先跑遊戲邏輯。
