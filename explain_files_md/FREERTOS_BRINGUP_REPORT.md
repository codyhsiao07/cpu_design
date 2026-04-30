# FreeRTOS Bring-Up Report

## 1. 目標與結論

本專案已完成一套可在自製 RV32 CPU 上執行的 FreeRTOS 最小移植版本，並已在 FPGA 板上實際驗證以下能力：

- FreeRTOS scheduler 可正常啟動
- machine timer interrupt 可作為 RTOS tick source
- task context switch 可正常進行
- `taskYIELD()` 可觸發 voluntary context switch
- `vTaskDelay()` 可正常依 tick 運作
- `xQueueCreateStatic()`、`xQueueSend()`、`xQueueReceive()` 可正常運作
- 多任務 UART log 可實際觀察到 Producer / Consumer / Heartbeat 三個 task 的行為

這表示系統不只是「能進入 main」，而是已具備 RTOS 核心運作所需的基本硬體與軟體條件。

## 2. RTOS 在本專案中的意義

在本平台中，RTOS 不是像 Windows/Linux 那樣的完整桌面作業系統，而是：

- 提供 task 管理
- 提供 scheduler
- 提供 tick / delay / time slicing
- 提供 queue 與 task 間同步/通訊
- 提供 task 與 interrupt 的協作框架

因此，「把 RTOS 跑起來」的定義不是安裝某個映像，而是：

1. 將 FreeRTOS kernel source 與本地 CPU port 一起編譯
2. 產生 `.mem`
3. 燒進板子
4. 實際觀察 scheduler / tick / queue / task switch 是否正常

## 3. 系統架構

### 3.1 硬體層

本次 FreeRTOS bring-up 依賴的硬體能力包括：

- CSR
- `ecall`
- `mret`
- machine timer interrupt
- machine software / external interrupt source
- trap / exception path
- UART MMIO

主要 RTL 核心入口：

- `icache_pipeline_top.v`
- `CSR.v`
- `machine_irq_sources.v`

### 3.2 軟體分層

目前 FreeRTOS 系統可以分成四層：

1. Hardware / CPU
   - CSR
   - timer interrupt
   - trap / exception
   - UART MMIO

2. BSP / Trap Runtime
   - `OS/trap_entry.S`
   - `OS/trap.c`
   - `OS/trap.h`
   - `OS/rtos_bsp.c`
   - `OS/rtos_bsp.h`

3. FreeRTOS Port Layer
   - `OS/freertos/port.c`
   - `OS/freertos/portmacro.h`
   - `OS/freertos/FreeRTOSConfig.h`
   - `OS/freertos/freertos_libc.c`

4. FreeRTOS Application
   - `OS/freertos/freertos_demo.c`

## 4. FreeRTOS Kernel Source 來源

本專案目前直接使用外部 FreeRTOS LTS 原始碼：

- `C:\Users\a0968\Downloads\FreeRTOSv202406.04-LTS\FreeRTOS-LTS\FreeRTOS\FreeRTOS-Kernel`

當前 demo 實際編入的 kernel source 為：

- `tasks.c`
- `list.c`
- `queue.c`

也就是說，目前 `.mem` 不是只有本地 demo 程式，而是已經把 FreeRTOS kernel 真正編進去。

## 5. 本地實作的 RTOS Port / BSP API

### 5.1 Trap / Context Runtime

檔案：

- `OS/trap_entry.S`
- `OS/trap.c`
- `OS/trap.h`

主要 API：

- `trap_init()`
  - 設定 `mtvec`
- `trap_set_handler()`
  - 安裝 trap handler
- `trap_dispatch()`
  - 將 interrupt 與 exception 分流
- `trap_resume_frame(struct trap_frame *frame)`
  - 依指定 trap frame 恢復暫存器並 `mret`
- `trap_is_active()`
  - 回報目前是否在 trap 中

### 5.2 BSP API

檔案：

- `OS/rtos_bsp.h`
- `OS/rtos_bsp.c`

主要 API：

- `rtos_bsp_irq_save()`
- `rtos_bsp_irq_restore()`
- `rtos_bsp_irq_enable()`
- `rtos_bsp_irq_disable()`
- `rtos_bsp_irq_is_enabled()`
- `rtos_bsp_cpu_relax()`

用途是提供最底層的 IRQ 開關與 CPU busy-wait 支援。

### 5.3 FreeRTOS Port API

檔案：

- `OS/freertos/port.c`
- `OS/freertos/portmacro.h`

主要已完成 API：

- `pxPortInitialiseStack()`
  - 建立 task 初始 stack / trap frame
- `xPortStartScheduler()`
  - 初始化 trap、timer tick，並切進第一個 task
- `vPortEndScheduler()`
  - 停止 scheduler
- `vPortSetupTimerInterrupt()`
  - 設定 `mtime/mtimecmp`
- `uxPortSetInterruptMaskFromISR()`
- `vPortClearInterruptMaskFromISR()`
- `trap_on_interrupt()`
  - 處理 timer tick interrupt
- `trap_on_exception()`
  - 處理 `ecall` 作為 task yield

### 5.4 Port Macro

檔案：

- `OS/freertos/portmacro.h`

重要對應：

- `portYIELD()` -> `ecall`
- `portDISABLE_INTERRUPTS()` -> `csrc mstatus, MIE`
- `portENABLE_INTERRUPTS()` -> `csrs mstatus, MIE`
- `portENTER_CRITICAL()` / `portEXIT_CRITICAL()`
- `portSET_INTERRUPT_MASK_FROM_ISR()`
- `portCLEAR_INTERRUPT_MASK_FROM_ISR()`

## 6. FreeRTOS Demo 設計

目前 demo 使用 static allocation，不依賴 heap。

檔案：

- `OS/freertos/freertos_demo.c`

### 6.1 建立的 RTOS 物件

- 1 個 static queue
- 3 個 application tasks
- 1 個 idle task

### 6.2 三個 task 的角色

#### Heartbeat Task

- 優先權最高
- 每 1 秒印一次系統摘要
- 顯示：
  - tick count
  - queue 目前筆數
  - producer 已送數量
  - consumer 已收數量
  - 最後一次送出值
  - 最後一次接收值

#### Producer Task

- 每 250 ms 產生一個遞增整數
- 透過 `xQueueSend()` 送進 queue
- UART 印 `[PROD] send=...`

#### Consumer Task

- 透過 `xQueueReceive()` 阻塞等待資料
- 收到資料後立刻印 `[CONS] recv=...`

## 7. 如何建置與上板

### 7.1 建置

```powershell
cd C:\cpu_design
powershell -ExecutionPolicy Bypass -File .\tools\build_freertos_demo.ps1
```

輸出：

- `build_rv32/freertos_demo.mem`

### 7.2 上板

前提：

- FPGA bitstream 必須已包含最新 trap / timer / CSR / interrupt RTL

送檔：

```powershell
python .\uart_send_mem.py --port COM7 --baud 115200 --mem .\build_rv32\freertos_demo.mem --delay 3.0 --preamble 4096 --interactive
```

## 8. 如何證明這真的是 RTOS

若系統只做到：

- `main()`
- while loop
- UART print

那不能算 RTOS。

要證明是 RTOS，必須看到下列行為：

### 8.1 Scheduler 啟動

代表 FreeRTOS kernel 已正式接管任務排程。

對應證據：

- `[BOOT] starting scheduler`

### 8.2 多 task 真正執行

對應證據：

- `[TASK] heartbeat entered`
- `[TASK] producer entered`
- `[TASK] consumer entered`

這不是單一 loop 模擬多功能，而是多個 task 分別被 scheduler 選中後執行。

### 8.3 Timer tick 在跑

對應證據：

- `[HB] tick=0x...`

若 tick 會增加，表示 machine timer interrupt 與 RTOS tick 已接通。

### 8.4 Task delay 生效

Producer 每 250 ms 才送一次資料，Heartbeat 每 1 秒才印一次。

若 UART 顯示這種週期性行為，代表：

- `vTaskDelay()` 正常
- scheduler 可依 tick 喚醒 task

### 8.5 Queue 生效

對應證據：

- `[PROD] send=0x00000001`
- `[CONS] recv=0x00000001`

這證明：

- task 間通訊正常
- queue kernel 路徑正常

### 8.6 Consumer 能阻塞等待

若 queue 為空時 consumer 不會無限亂跑，而是在 producer 送資料後才醒來，代表：

- blocking queue receive 正常
- scheduler 能在 blocked / ready state 間切換 task

## 9. UART Log 解讀

以下是一個代表性的成功 log：

```text
[BOOT] main entered
[BOOT] queue created
[BOOT] producer task created
[BOOT] consumer task created
[BOOT] heartbeat task created
[BOOT] starting scheduler
[TASK] heartbeat entered
FreeRTOS queue demo start
[HB] tick=0x00000002 queued=0x00000000 prod=0x00000000 cons=0x00000000 last_tx=0x00000000 last_rx=0x00000000
[TASK] producer entered
[TASK] consumer entered
[PROD] send=0x00000001
[CONS] recv=0x00000001
```

解讀如下：

- `main entered`
  - CPU 成功進入應用程式
- `queue created`
  - FreeRTOS queue 已建立
- `producer/consumer/heartbeat task created`
  - 多任務已建立成功
- `starting scheduler`
  - 將進入 RTOS 排程
- `heartbeat entered`
  - 第一個被執行的 task 已啟動
- `tick=...`
  - timer tick 已生效
- `producer entered` / `consumer entered`
  - 其他 task 也被 scheduler 執行
- `send=1` / `recv=1`
  - queue 傳遞成功

### 關於 UART 字串交錯

若看到：

- `[TASK] [TASK] consproducer entered`

這通常不是 RTOS 壞掉，而是兩個 task 幾乎同時寫 UART，字串被交錯。  
這只表示目前 log 沒有加鎖，不影響 RTOS 核心是否正確運作。

## 10. 目前已展示的 RTOS 能力

目前已可展示：

- task creation
- static allocation
- scheduler start
- timer tick
- preemptive scheduling
- voluntary yield
- `vTaskDelay()`
- queue-based inter-task communication
- interrupt-driven kernel tick

## 11. 尚未展示但可延伸的 RTOS 功能

若要做更完整展示，接下來可加入：

- mutex
- semaphore
- event group
- software timer
- task notification
- dynamic allocation (`heap_4.c`)
- priority inversion demonstration
- ISR-to-task wakeup demo

## 12. 可用於報告的總結句

可直接使用以下描述：

> 本專案已完成 FreeRTOS 在自製 RV32 CPU 上的最小移植，包含 trap runtime、timer tick、context switch、task yield 與 queue 通訊。透過 FPGA 實機 UART log，已驗證 scheduler、task delay、Producer/Consumer queue 以及 Heartbeat task 皆可正常運作，證明 RTOS kernel 已成功在本 CPU 平台上執行。

## 13. 後續建議

若要把這份成果做成更完整展示，建議優先順序如下：

1. 加入 UART log 鎖，避免多 task 輸出交錯
2. 新增 semaphore / mutex demo
3. 新增不同 priority task 的 preemption demo
4. 將 RTOS 與既有遊戲或 menu 系統結合
5. 若要更像正式 RTOS 平台，可再加入 `heap_4.c`、`timers.c`、`event_groups.c`
