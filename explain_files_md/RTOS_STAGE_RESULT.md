# RTOS Queue + VGA Pipeline Demo

## 階段目標

這個階段的成果是建立一個可以在 FPGA 板子上展示的 RTOS pipeline demo：

```text
Producer Task -> FreeRTOS Queue -> Renderer Task -> VGA
Heartbeat Task -> VGA / UART
```

它用 VGA 畫面和 UART log 同時證明三件事：

- FreeRTOS 可以建立多個 task。
- task 之間可以用 queue 傳遞資料。
- scheduler 會讓不同 task 交錯執行，且 VGA 畫面會持續被不同 task 更新。

## Demo 檔案

- 主程式：`OS/rtos/src/main_vga_queue_demo.c`
- 編譯腳本：`tools/build_rtos_vga_queue_demo.ps1`
- 產物：`build_rtos/rtos_vga_queue_demo.mem`

這個 demo 沿用已驗證穩定的 VGA/RTOS 路徑：

- 使用 stock FreeRTOS RISC-V `portASM.S`
- 保持 `mtime/mtimecmp` tick interrupt 啟用
- task 內使用 `vTaskDelay()`
- VGA 繪圖使用專案既有 `game/vga_fb.c`
- 不使用先前不穩定的自製 32-bit framebuffer helper

## RTOS API 使用點

這個 demo 展示以下 RTOS API：

- `xTaskCreateStatic()`：建立 producer、renderer、heartbeat 三個靜態配置 task。
- `xQueueCreateStatic()`：建立靜態 queue，不依賴 heap。
- `xQueueSend()`：producer 將事件送進 queue。
- `xQueueReceive()`：renderer 從 queue 取事件，收到資料後才更新 VGA。
- `vTaskDelay()`：讓 task 週期性休眠，把 CPU 交回 scheduler。
- `xTaskGetTickCount()`：在 UART log 中顯示 RTOS tick。
- `taskENTER_CRITICAL()` / `taskEXIT_CRITICAL()`：避免 UART log 被多個 task 插斷。

## VGA 畫面意義

畫面分成三個區塊：

- 左側：Producer task。週期性產生 event，成功送進 queue 後更新左側色塊。
- 中間：Renderer task。只有從 queue 收到 event 後才更新中間色塊。
- 右側：Heartbeat task。獨立週期更新，證明還有第三個 task 同時活著。

因此如果左側和中間同步持續變化，就代表 queue pipeline 正在傳資料；如果右側也持續變化，就代表 scheduler 仍在排程其他 task。

## 編譯指令

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\build_rtos_vga_queue_demo.ps1
```

成功時會產生：

```text
build_rtos/rtos_vga_queue_demo.elf
build_rtos/rtos_vga_queue_demo.bin
build_rtos/rtos_vga_queue_demo.mem
build_rtos/rtos_vga_queue_demo.dis
build_rtos/rtos_vga_queue_demo.map
```

目前已驗證可成功編譯：

```text
Wrote C:\cpu_design\build_rtos\rtos_vga_queue_demo.mem with 5900 words
BIN size: 23600 bytes
```

## 上板測試指令

使用 VGA 版本 bitstream，頂層應使用 `board_top_vga`，約束檔使用：

- `xdc_for_vga.xdc`
- `mig.xdc`
- `clk_wiz_0.xdc`

將 `.mem` 傳到板子：

```powershell
python .\uart_send_mem.py --port COM7 --baud 115200 --mem .\build_rtos\rtos_vga_queue_demo.mem --delay 3.0 --preamble 4096 --interactive
```

## 預期 UART 輸出

啟動時應看到：

```text
[PIPE] RTOS queue VGA pipeline boot
[PIPE] queue
[PIPE] producer
[PIPE] renderer
[PIPE] heartbeat
[PIPE] scheduler
[PIPE] task=R renderer start
[PIPE] task=P producer start
[PIPE] task=H heartbeat start
```

執行中應持續看到類似：

```text
[PIPE] tick=0x00000ABC task=P send=0x00000004
[PIPE] tick=0x00000ABD task=R recv=0x00000004
[PIPE] tick=0x00000FA0 task=H beat=0x00000002
```

`P send` 和 `R recv` 的 event number 會往上增加，表示 queue 真的有在傳資料。

## 完成標準

這個階段可以視為完成，如果符合以下條件：

- `.mem` 可以成功產生。
- UART 沒有出現 `[RTOS] exception`、`stack overflow` 或 `[PIPE] fatal`。
- VGA 左側 producer 區塊會動。
- VGA 中間 renderer 區塊會跟著 producer event 更新。
- VGA 右側 heartbeat 區塊會獨立週期更新。
- UART 持續出現 `task=P send`、`task=R recv`、`task=H beat`。

## 可以如何講解

這個 demo 可以說明：

「這不是單純裸機 while loop 畫圖。Producer task 負責產生資料，Renderer task 阻塞等待 queue，只有收到資料才畫畫面。Heartbeat task 同時週期執行，證明系統還能排程其他工作。這代表目前 CPU 已經可以跑 FreeRTOS task、tick interrupt、context switch、delay，以及 task 間 queue 通訊。」

## 下一階段建議

下一個合理階段是加入一個簡單 driver/service 架構：

- Input task：讀 UART 或按鍵。
- Logic task：根據 input 更新狀態。
- Render task：根據狀態更新 VGA。

這會把目前的 demo 從「RTOS pipeline 證明」推進到「可以寫互動式 RTOS 應用程式」。

## 畫面可讀性更新

新版畫面改用穩定的矩形繪圖路徑，加入上方小標籤、queue 格子與底部進度條，讓觀眾可以直接理解每個區塊：

- `P`：Producer task 產生 event，並用 `xQueueSend()` 放入 FreeRTOS queue。
- `Q`：中間上方的格子代表 queue/event slot，目前亮起的格子代表最新處理到的 event 序號。
- `R`：Renderer task 用 `xQueueReceive()` 收到 event 之後，才更新中間色塊。
- `H`：Heartbeat task 與 queue 無關，獨立週期更新，用來證明 scheduler 同時排程其他 task。
- 底部三組 8 格進度條分別代表 Producer、Renderer、Heartbeat 的進度；亮格持續移動就表示 task 持續被 scheduler 執行。

展示時可以說：

```text
左邊 P 產生資料，資料進入中間 Q；
Renderer 收到資料後，中間 R 區域才更新；
右邊 H 同時跳動，表示 RTOS 仍在排程第三個獨立任務。
```
