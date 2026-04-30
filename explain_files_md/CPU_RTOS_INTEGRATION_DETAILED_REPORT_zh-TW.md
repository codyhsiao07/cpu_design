# CPU / RTOS 整合詳細報告

## 1. 目的

本文件集中說明此專案中目前 CPU 與 RTOS 的整合方式。

目標讀者是：

- 了解 Verilog 硬體與 pipeline control
- 但尚未完整做過一次 RTOS 軟體 bring-up 的人

本報告的目標，是清楚回答以下問題：

- RTOS 路徑中涉及哪些檔案？
- 哪些部分屬於硬體，哪些屬於軟體，哪些部分是兩者之間的橋接？
- 一個 `.mem` 映像檔究竟如何包含 FreeRTOS、遊戲，以及 porting code？
- 控制流程如何從 reset，進到 `main()`，再到 scheduler、timer interrupt、context switch，最後回到 task？
- 原本的 bare-metal VGA 遊戲，是如何被改造成一個 RTOS task 的？

本報告聚焦在**與 RTOS 相關的路徑**，而不是整個 CPU repository 的所有檔案。

## 2. 高層概念圖

目前這套系統並不是像 Windows 把作業系統安裝到硬碟那樣「安裝 RTOS」。

它比較像典型的 embedded firmware build：

1. FPGA bitstream 內含硬體系統：
   - CPU
   - caches
   - CSR/trap logic
   - machine timer interrupt source
   - UART MMIO
   - VGA MMIO/framebuffer path
   - DDR interface
2. 軟體映像檔則包含：
   - startup code
   - trap entry/exit runtime
   - board support code
   - FreeRTOS port layer
   - FreeRTOS kernel source
   - application
   - game engine
3. 上述所有軟體會被編譯並連結成**一個單一的 firmware image**。
4. 該 binary 會再被轉成 `.mem`，並送入 DDR。
5. CPU 從 DDR 啟動並執行這個整合後的映像。

因此，正確的心智模型是：

```text
bitstream = 硬體平台
.mem      = 軟體韌體映像
```

RTOS kernel **是在 `.mem` 映像中**，不是在 bitstream 裡。

## 3. 分層架構

目前的 RTOS stack 可以看成：

```text
Application / Game Layer
  -> freertos_snake_demo.c
  -> Snake_vga.c / vga_fb.c / games_shared_ui.c

FreeRTOS Kernel Layer
  -> tasks.c
  -> list.c
  -> queue.c

FreeRTOS Port / BSP / Trap Layer
  -> port.c
  -> portmacro.h
  -> trap.c
  -> trap_entry.S
  -> rtos_bsp.c

CPU Architectural Support
  -> ID.v (CSR/ecall/ebreak/mret decode)
  -> CSR.v
  -> machine_irq_sources.v
  -> icache_pipeline_top.v

Platform / Hardware
  -> UART MMIO
  -> timer MMIO
  -> VGA path
  -> DDR
  -> board_top_vga
```

## 4. 逐檔案角色摘要

### 4.1 Build 與記憶體配置相關檔案

`tools/link_ddr.ld`

- 定義 link address。
- 將整個映像配置在 DDR 的 `0x80000000`。
- 定義 `.text`、`.data`、`.bss` 與 `__stack_top` 的位置。
- 將 `_start` 設為程式入口。

重點：

- `ENTRY(_start)`
- `DDR (rwx) : ORIGIN = 0x80000000, LENGTH = 512K`
- `.text.start` 會最先放置，因此 `_start` 位於映像最前面。

`tools/crt0.S`

- 最小化 startup runtime。
- 載入 `sp` 與 `gp`。
- 清除 `.bss`。
- 呼叫 `main()`。
- 若 `main()` 回傳，則進入無限迴圈。

這是 reset/boot 後第一段執行的軟體程式碼。

`tools/build_freertos_demo.ps1`

- 通用的 FreeRTOS build script。
- 尋找 RISC-V toolchain。
- 尋找下載下來的 `FreeRTOS-LTS` 中 FreeRTOS kernel source tree。
- 用一條 gcc link 指令，把所有需要的物件一起編譯並連結。
- 將 ELF 轉成 BIN，再把 BIN 轉成 `.mem`。

重要事實：

- 這支 script 才是把各個軟體檔案收集成單一映像的地方。
- 這些檔案**不需要**彼此直接 `#include`，也能成為同一個 firmware 的一部分。
- 它們是在 **link time** 被收進同一個最終映像中。

`tools/build_freertos_snake_demo.ps1`

- 建立在 `build_freertos_demo.ps1` 之上的薄封裝。
- 用 RTOS Snake application 取代一般 queue demo。
- 加入 VGA Snake game engine 與其支援檔案。
- 加入像 `SNAKE_NO_STANDALONE_MAIN` 這類 compile-time define。

### 4.2 硬體端的 RTOS 支援檔案

`ID.v`

- 解碼 `CSRRW`、`CSRRS`、`CSRRC`
- 解碼 `ecall`、`ebreak`、`mret`
- 偵測 illegal instruction 與 illegal CSR access
- 產生後續 pipeline 驅動 CSR block 與 trap logic 所需的 control signals

沒有這個檔案，CPU 就無法辨識 RTOS runtime 所需的那些指令。

`CSR.v`

- 實作 machine CSR block：
  - `mstatus`
  - `mie`
  - `mtvec`
  - `mscratch`
  - `mepc`
  - `mcause`
  - `mip`
- 處理：
  - 一般 CSR writes
  - `trap_enter`
  - `mret_exec`
- 追蹤目前 privilege mode

這是 FreeRTOS 進行 trap/interrupt handling 所依賴的 architectural state。

`machine_irq_sources.v`

- 實作 RTOS port 所使用的 interrupt sources：
  - software interrupt source
  - timer interrupt source
  - external interrupt source
- 內含 `mtime` 與 `mtimecmp`
- 產生：
  - pending bits
  - `irq_request_o`
  - `irq_cause_o`

這是硬體 timer 與 pending-source generator，也是讓 preemptive scheduling 成為可能的關鍵。

`icache_pipeline_top.v`

- 實例化 CSR block 與 IRQ source block
- 決定 interrupt 或 exception 何時真正被 taken
- 產生導向 `mtvec` 的 trap redirect
- 產生導向 `mepc` 的 `mret` redirect
- 擷取會成為 trap `mepc` 的 architectural PC snapshot

這是 CPU pipeline 與 RTOS 相關控制路徑之間最主要的硬體整合點。

### 4.3 軟體端的 RTOS 橋接檔案

`OS/trap.h`

- 定義 `struct trap_frame`
- 這是以下元件之間的 ABI 契約：
  - assembly trap entry/exit
  - C trap dispatcher
  - FreeRTOS port

所有 context save/restore 都是圍繞這個結構來組織的。

`OS/trap_entry.S`

- 寫入 `mtvec` 的真正 trap entry point
- 將所有 GPR 與重要 CSR 儲存到 `trap_frame`
- 切換到專用的 ISR stack
- 呼叫 `trap_dispatch()`
- 恢復 `trap_dispatch()` 回傳的那個 trap frame
- 最後以 `mret` 結束

這是 CPU 硬體 trap 行為與 RTOS C 程式碼之間最核心的 assembly bridge。

`OS/trap.c`

- 初始化 `mtvec`
- 提供 `trap_dispatch()`
- 將 trap 分流為：
  - interrupt path
  - exception path
- 使用 weak hooks：
  - `trap_on_interrupt()`
  - `trap_on_exception()`

這些 weak hooks 之後會被 FreeRTOS port 覆寫。

`OS/rtos_bsp.h` 與 `OS/rtos_bsp.c`

- 提供最基本的 board support helper，用來包裝 interrupt enable/disable
- 用簡單的 C 函式封裝對 `mstatus.MIE` 的存取

這是一個小型 BSP，不是完整的 driver framework。

`OS/freertos/portmacro.h`

- 定義 CPU 相依的 FreeRTOS macros
- 告訴 FreeRTOS：
  - stack type
  - alignment
  - 如何 `yield`
  - 如何進入/離開 critical section
  - 如何在 ISR context 中 mask interrupts

其中有一行尤其重要：

```c
#define portYIELD() __asm__ volatile ( "ecall" )
```

這代表在這顆 CPU 上，FreeRTOS 的 yield 會變成一條 machine `ecall` 指令。

`OS/freertos/port.c`

- 實作真正的 FreeRTOS CPU port
- 提供：
  - `pxPortInitialiseStack()`
  - `xPortStartScheduler()`
  - timer setup
  - interrupt handler glue
  - 給 `ecall` 用的 exception handler glue
- 將 FreeRTOS scheduler 的決策轉換為實際的 trap-frame switching

這個檔案是 generic FreeRTOS kernel 與這顆特定 CPU 之間最重要的軟體橋接層。

### 4.4 目前使用中的 FreeRTOS kernel source files

這些檔案不是我們自己寫的。它們來自：

`C:\Users\a0968\Downloads\FreeRTOSv202406.04-LTS\FreeRTOS-LTS\FreeRTOS\FreeRTOS-Kernel`

目前使用的 kernel `.c` 檔案有：

- `tasks.c`
- `list.c`
- `queue.c`

它們的角色如下：

`tasks.c`

- task creation
- ready list 管理
- delayed list 管理
- scheduler 啟動
- tick 處理
- task switching 決策

`list.c`

- scheduler 內部使用的通用 linked-list container
- ready lists 與 delay lists 都依賴它

`queue.c`

- queues
- queue send/receive
- 等待 queue 的 task 之 block/unblock

### 4.5 Application 與 game 檔案

`OS/freertos/freertos_demo.c`

- 一個乾淨的 RTOS proof demo
- 使用：
  - heartbeat task
  - producer task
  - consumer task
  - static queue
- 這個檔案比遊戲更能當作「RTOS 已成功運作」的證明，因為它清楚展示了 queue send/receive 與 blocking behavior。

`OS/freertos/freertos_snake_demo.c`

- RTOS 遊戲應用本體
- 建立：
  - input task
  - game task
  - heartbeat task
  - idle task memory hook
- 使用：
  - `xQueueCreateStatic`
  - `xTaskCreateStatic`
  - `vTaskStartScheduler`
  - `xQueueSend`
  - `xQueueReceive`
  - `vTaskDelay`
  - `xTaskGetTickCount`

`game/Snake_vga.c`

- 原本的 VGA Snake game engine
- 已被重構，使其既可獨立 standalone 編譯，也能被 RTOS tasks 驅動

`game/Snake_vga.h`

- 宣告可重用的 game API：
  - `snake_game_init`
  - `snake_game_handle_input_char`
  - `snake_game_update_tick`
  - `snake_game_render_if_needed`
  - `snake_game_shutdown`
  - 各種 state getter functions

`game/games_shared_ui.c`

- 提供 Snake RTOS app 所使用的 UART/game input helper functions

`game/vga_fb.c`

- 提供 Snake game engine 所使用的 VGA framebuffer 操作

## 5. 實際 Build 組成

目前 RTOS Snake 映像是這樣建立的：

```text
tools/crt0.S
OS/trap.c
OS/rtos_bsp.c
OS/freertos/freertos_libc.c
OS/freertos/port.c
FreeRTOS-Kernel/list.c
FreeRTOS-Kernel/queue.c
FreeRTOS-Kernel/tasks.c
OS/freertos/freertos_snake_demo.c
game/Snake_vga.c
game/games_shared_ui.c
game/vga_fb.c
OS/trap_entry.S
```

上述所有檔案都會被編譯並連結成一個 ELF。

接著：

```text
ELF -> BIN -> MEM
```

這個 `.mem` 就是被送到板子上的內容。

因此，以下這句話是正確的：

> RTOS kernel、port、trap runtime、application 與 game 都在同一個 software image 裡。

## 6. 為什麼這些檔案不需要彼此 `#include`

這一點常常會讓偏硬體背景的讀者感到困惑。

在 C/C/assembly firmware 整合中，連接方式其實有三種不同層次：

### 6.1 Header-level connection

例如：

- `freertos_snake_demo.c` 包含 `FreeRTOS.h`、`task.h`、`queue.h`

這樣做會提供：

- type declarations
- function prototypes
- macros

但它**不會**把 implementation code 直接塞進 source file 裡。

### 6.2 Link-time symbol connection

例如：

- `freertos_snake_demo.c` 呼叫 `xTaskCreateStatic()`
- 實際 implementation 在 FreeRTOS 的 `tasks.c`

compiler 會輸出一個 external symbol reference。  
linker 之後會因為 `tasks.c` 也在同一個最終 build 中，而把它解析掉。

RTOS 的大多數軟體元件，就是透過這種方式連起來的。

### 6.3 Hardware control-transfer connection

例如：

- `trap_init()` 把 `trap_entry` 的位址寫進 `mtvec`
- 當 interrupt 發生時，硬體就會直接跳到那裡

這不是一般 C function call 關係。  
這是 CPU architectural control-transfer 關係。

這也是為什麼 assembly trap code 與 CSR logic 即使沒有一般 C 呼叫關係，仍然可以彼此「連接」。

## 7. 端到端 Runtime Flow

### 7.1 上電 / 程式開始執行

1. bitstream 已先載入 FPGA
2. `.mem` 由 UART loader 送入 DDR
3. CPU 從 `0x80000000` 開始取指
4. `crt0.S` 中的 `_start` 開始執行
5. `crt0.S` 設定 `sp`、設定 `gp`、清除 `.bss`，然後呼叫 `main()`

### 7.2 RTOS Snake application 裡的 `main()`

在 `freertos_snake_demo.c` 中，`main()` 會：

1. 用 `xQueueCreateStatic` 建立 input queue
2. 用 `xTaskCreateStatic` 建立三個 static tasks
3. 透過 `vApplicationGetIdleTaskMemory` 提供 idle task 的 static memory
4. 呼叫 `vTaskStartScheduler()`

重要的架構細節：

- 使用 static allocation，因為 `configSUPPORT_STATIC_ALLOCATION = 1`
- dynamic allocation 被關掉，因為 `configSUPPORT_DYNAMIC_ALLOCATION = 0`

因此所有 stack 與 TCB 都是預先放在 global arrays 裡。

### 7.3 Task creation 是怎麼運作的

當呼叫 `xTaskCreateStatic()` 時：

1. application 要求 FreeRTOS kernel `tasks.c` 建立 task
2. kernel 使用提供的 static memory 配置並初始化 TCB
3. kernel 呼叫 CPU port hook `pxPortInitialiseStack()`
4. `pxPortInitialiseStack()` 在 task stack 上建立一個合成的初始 `trap_frame`

這個 frame 就是未來 task 要「resume 進去」的初始 context。

`pxPortInitialiseStack()` 寫入的關鍵欄位包括：

- `mepc = task entry function`
- `a0 = task parameter`
- `ra = prvTaskExitError`
- `orig_sp = top of stack`
- `mstatus = 適合後續 `mret` 的值`

所以 task 的開始方式不是一般 C call。  
它是透過恢復一個事先人工構造好的 machine context，然後用 `mret` 跳進去。

### 7.4 啟動 scheduler

`vTaskStartScheduler()` 是由 FreeRTOS kernel 的 `tasks.c` 實作的。

它的重要工作包括：

1. 建立 idle task
2. 進行 scheduler 初始化
3. 呼叫 port hook `xPortStartScheduler()`

接著 `port.c` 中的 `xPortStartScheduler()` 會做 CPU 相依的初始化：

1. `trap_init()`
2. `vPortSetupTimerInterrupt()`
3. 啟用 `mie.MTIE`
4. 找到第一個 task 的 stack frame
5. `trap_resume_frame(first_frame)`

到這裡，控制流就離開一般 C 流程，進入 architectural restore path。

### 7.5 第一個 task 如何進入

`trap_resume_frame()` 位於 `trap_entry.S`。

它會：

1. 從被選中的 task frame 載入儲存的 `mepc`
2. 載入儲存的 `mstatus`
3. 恢復所有保存的 GPR
4. 恢復 `sp`
5. 執行 `mret`

接著 `mret` 就會把控制流轉到存放在 `mepc` 內的 task function。

這就是為什麼第一個 task 看起來像是「自己開始執行」，而不是被一般函式呼叫啟動。

## 8. Timer Interrupt 與 Preemptive Scheduling

### 8.1 硬體端

`machine_irq_sources.v` 每個 cycle 都會遞增 `mtime`。

當：

```text
mtime >= mtimecmp
```

timer pending bit 就會變成 true。

若同時：

- `mstatus.MIE = 1`
- `mie.MTIE = 1`

那麼 `irq_request_o` 就會被 assert，cause 為 `7`。

### 8.2 CPU top-level 端

`icache_pipeline_top.v` 會收到 IRQ request，並在安全邊界判斷是否可以接下這個 interrupt。

之後它會：

1. 將 trap redirect target 設為 `mtvec`
2. 設定 `trap_enter`
3. 寫入：
   - trap cause
   - trap PC
   - interrupt flag
4. 將執行流程重導向到 trap handler

### 8.3 Trap entry 端

當 interrupt 被接下時，CPU 會跳到 `trap_entry`。

`trap_entry.S` 會：

1. 在目前 task stack 上為 `trap_frame` 配置空間
2. 保存所有 GPR
3. 讀取 `mepc`、`mstatus`、`mcause`、`mscratch`
4. 切換到專用 ISR stack
5. 呼叫 `trap_dispatch(frame)`

### 8.4 C dispatch 端

`trap.c` 中的 `trap_dispatch()` 會檢查 `mcause`。

若 interrupt bit 有設起來：

- 它就呼叫 `trap_on_interrupt(frame)`

在 RTOS port 中，`port.c` 的 `trap_on_interrupt()` 會做：

1. 將目前 trap frame pointer 存進 `pxCurrentTCB`
2. 安排下一次的 `mtimecmp`
3. 呼叫 `xTaskIncrementTick()`
4. 若需要 context switch，就呼叫 `vTaskSwitchContext()`
5. 回傳下一個 task 的 frame pointer

### 8.5 回到某個 task

`trap_entry.S` 會收到 `trap_dispatch()` 回傳的 frame pointer。

這個 frame pointer 可能是：

- 同一個 task
- scheduler 選出的另一個 task

然後 `trap_resume_frame()` 會恢復被選中的 context，並執行 `mret`。

這就是真正的 context switch。

## 9. 透過 `ecall` 的 `yield` 路徑

FreeRTOS 也需要一條由軟體主動觸發的 context switch 路徑。

它透過 `portmacro.h` 中的：

```c
#define portYIELD() __asm__ volatile ( "ecall" )
```

來實作。

流程如下：

1. task 呼叫某個會 yield 的 API
2. 執行 `ecall`
3. CPU 將其解碼為 SYSTEM instruction
4. 進入 trap path
5. `port.c` 中的 `trap_on_exception()` 看到 machine `ecall`
6. 它把 `mepc` 加 4，讓恢復執行時跳過這條 `ecall`
7. 它把目前 frame 存進 `pxCurrentTCB`
8. 呼叫 `vTaskSwitchContext()`
9. 回傳下一個 task 的 frame
10. `trap_resume_frame()` 恢復被選中的 task

因此：

- preemptive switch
- cooperative switch

共用同一套 trap-frame restore 機制。

差別只在來源：

- preemption 來自 timer IRQ
- explicit yield 來自 `ecall`

## 10. Queue 路徑

queue demo 與 RTOS Snake 的 input path，都依賴 FreeRTOS queue primitive。

### 10.1 建立

`xQueueCreateStatic()`

- 從使用者提供的 static memory 配置 queue state
- 不使用 heap

### 10.2 傳送

`xQueueSend()`

- 在 `queue.c` 中透過 `xQueueGenericSend()` 實作
- 若 queue 尚有空間，就把資料複製進 queue
- 若 queue 已滿且允許等待，task 可能會 block

### 10.3 接收

`xQueueReceive()`

- 在 `queue.c` 中實作
- 若 queue 中有資料，就複製出來
- 若 queue 為空且允許等待，task 可能會 block

block/unblock 的行為不是我們自己寫的。  
那是 FreeRTOS kernel 的一部分。

這點在向老師解釋時很重要：

> queue 的行為不是自製 mailbox，而是跑在自訂 CPU port 上的官方 FreeRTOS queue subsystem。

## 11. RTOS Snake 整合方式

Snake 遊戲並不是維持成一個巨大的 bare-metal `main()`。

它被拆成可重用的 game engine API：

- `snake_game_init()`
- `snake_game_handle_input_char()`
- `snake_game_update_tick()`
- `snake_game_render_if_needed()`
- `snake_game_shutdown()`
- 各種 getter functions，供 debug/heartbeat 使用

接著，RTOS application 用三個 tasks 去包裝這個 engine。

### 11.1 Input task

目的：

- 以 nonblocking 方式讀取 UART/game input
- 把 input event 放入 FreeRTOS input queue

RTOS 角色：

- 展示輸入可以成為獨立可排程單元
- 透過 queue send，而不是直接改寫 game state

### 11.2 Game task

目的：

- 消耗 queue 中的輸入
- 更新遊戲邏輯
- 渲染 VGA frame

RTOS 角色：

- 真正的 game loop 現在是一個 task
- 它透過 `vTaskDelay` 休眠
- 它不再是整個系統本身

### 11.3 Heartbeat task

目的：

- 週期性回報：
  - RTOS tick count
  - queue depth
  - score
  - length
  - speed
  - game state

RTOS 角色：

- 展示 periodic task scheduling
- 在 VGA 執行時提供系統可視性

## 12. 為什麼這是真正的 RTOS 整合，而不只是花俏的 loop

這個系統確實是在使用 RTOS kernel，因為：

- task objects 由 FreeRTOS `tasks.c` 的 `xTaskCreateStatic()` 建立
- scheduler startup 由 FreeRTOS `tasks.c` 的 `vTaskStartScheduler()` 處理
- tick advancement 由 FreeRTOS `tasks.c` 的 `xTaskIncrementTick()` 處理
- task choice 由 FreeRTOS `tasks.c` 的 `vTaskSwitchContext()` 決定
- task communication 使用 FreeRTOS `queue.c` 的 `xQueueCreateStatic()`、`xQueueSend()`、`xQueueReceive()`
- task 的 block/unblock 行為來自 FreeRTOS kernel 的 lists 與 queue subsystem

我們自己實作的**不是 scheduler 本身**。

我們自己實作的是：

- architectural port
- trap runtime
- board support
- game/application

這正是 CPU/RTOS bring-up 應該要做的事。

## 13. 重要指令說明

本節是寫給硬體強、但低階韌體經驗較少的讀者。

### 13.1 Startup 與 trap code 中用到的指令

`la rd, symbol`

- pseudo-instruction
- 將某個 symbol 的位址載入暫存器
- 用途包括：
  - stack top
  - global pointer
  - ISR stack top

`sw rs, offset(base)`

- 將暫存器內容存入記憶體
- 在 `trap_entry.S` 中大量使用，用來把目前 context 存進 trap frame

`lw rd, offset(base)`

- 從記憶體載入暫存器
- 在 `trap_resume_frame()` 中使用，用來從選定的 trap frame 恢復 context

`csrr rd, csr`

- 將 CSR 讀到暫存器
- 用來讀取：
  - `mepc`
  - `mstatus`
  - `mcause`
  - `mscratch`

`csrw csr, rs`

- 將暫存器內容寫入 CSR
- 用來恢復：
  - `mepc`
  - `mstatus`
  - `mscratch`

`csrs csr, rs`

- 設定 CSR bit
- 用來透過設定 `mstatus` 或 `mie` 的特定位元啟用中斷

`csrc csr, rs`

- 清除 CSR bit
- 用來關閉中斷，或在 ISR critical section 中 mask interrupt

`ecall`

- 同步例外
- 在這裡被用作 software yield instruction
- 當 FreeRTOS 想透過 trap path 觸發 context switch 時，就會用它

`mret`

- 從 machine-mode trap 返回
- 這是離開 trap handler 並恢復選定 task context 的關鍵指令

### 13.2 為什麼 `mret` 這麼重要

這顆 CPU 的 port 在啟動 task 與恢復 task 時，使用的是 `mret`，而不是一般的 C function call。

這代表：

- RTOS 不會直接用一般函式呼叫來切進某個 task
- 它是先恢復一個 machine context，其中：
  - `mepc = task entry`
  - `sp = task stack`
  - 各個 register 設為保存好的狀態
- 然後再用 `mret` 讓 CPU 從那個 architectural state 繼續執行

這就是 task switching 的核心。

## 14. 控制流程與檔案關係圖

最有用的一張關係圖如下：

```text
build_freertos_snake_demo.ps1
  -> build_freertos_demo.ps1
      -> gcc links:
         crt0.S
         trap.c
         rtos_bsp.c
         port.c
         trap_entry.S
         FreeRTOS tasks.c/list.c/queue.c
         freertos_snake_demo.c
         Snake_vga.c
         games_shared_ui.c
         vga_fb.c
      -> ELF
      -> BIN
      -> MEM

MEM loaded to DDR
  -> CPU starts at _start
  -> crt0.S calls main
  -> freertos_snake_demo.c creates queue/tasks
  -> FreeRTOS tasks.c starts scheduler
  -> port.c configures trap + timer
  -> trap_resume_frame() enters first task
  -> timer IRQ / ecall
  -> trap_entry.S saves context
  -> trap.c dispatches
  -> port.c chooses next frame
  -> trap_resume_frame() restores selected task
```

最重要的硬體關係圖如下：

```text
ID.v
  -> decodes CSR / ecall / ebreak / mret / illegal

CSR.v
  -> stores mtvec / mepc / mcause / mstatus / mie / mip

machine_irq_sources.v
  -> generates timer/software/external interrupt requests

icache_pipeline_top.v
  -> instantiates CSR.v and machine_irq_sources.v
  -> decides when trap/interrupt is taken
  -> redirects PC to mtvec or mepc

trap_entry.S / trap.c / port.c
  -> use those hardware facilities at software level
```

## 15. 哪些部分是 Kernel、哪些是 Port、哪些是 Application

這個區分在報告或口頭答辯中，應該明確講出來。

### Kernel

- `tasks.c`
- `list.c`
- `queue.c`

這些由 FreeRTOS 擁有。  
它們實作 RTOS 的政策與核心服務。

### Port / Glue / BSP

- `port.c`
- `portmacro.h`
- `trap_entry.S`
- `trap.c`
- `rtos_bsp.c`

這些是為這顆 CPU / 平台撰寫的。  
它們是讓 generic kernel 能在這顆 CPU 上運作的 adaptation layer。

### Application

- `freertos_demo.c`
- `freertos_snake_demo.c`

這些檔案是 RTOS 服務的使用者。

### Game Engine

- `Snake_vga.c`
- `Snake_vga.h`
- `games_shared_ui.c`
- `vga_fb.c`

這些檔案負責遊戲本身與 VGA/UI 支援。

## 16. 目前 RTOS 設定已包含與尚未包含的內容

### 目前已包含且可運作的部分

- preemptive scheduling
- timer tick
- machine-mode trap entry/exit
- 以 `ecall` 為基礎的 yield
- static task creation
- static queue
- RTOS queue demo
- 搭配 VGA 與 UART heartbeat 的 RTOS Snake demo

### 目前映像尚未特別著重的部分

- dynamic allocation / `heap_4.c`
- mutex / semaphore / event groups demos
- software timers
- 完整 POSIX-like 環境
- process isolation
- user-mode task separation

這是一個**精簡但真正可運作的 FreeRTOS port**，不是完整桌面作業系統環境。

## 17. 一句話正確描述

如果你需要一句精準描述給老師：

> 我把 FreeRTOS kernel source 與我針對 CPU 撰寫的 trap/port layer、startup code、BSP、application，以及 VGA game engine 一起編譯成單一 firmware image；CPU 再利用 CSR/trap/timer 硬體機制，讓 FreeRTOS scheduler 能在我自製的 RV32 平台上驅動 preemptive task switching。

## 18. 稍長一點的口頭答辯版本

如果被問到「CPU 和 RTOS 到底是怎麼接起來的？」一個不錯的回答是：

> 硬體端提供 CSR state、`mtvec/mepc/mcause`、machine timer interrupt generation，以及 pipeline trap redirect logic。軟體端則提供 `crt0`、trap entry/exit assembly、C trap dispatcher，以及 FreeRTOS port，去實作 stack initialization、scheduler start、timer-tick handling 與以 `ecall` 為基礎的 yield。FreeRTOS kernel 本身則以 `tasks.c`、`list.c`、`queue.c` 等 source file 的形式被連結進來。application 再透過官方 FreeRTOS API 建立 tasks 與 queues，而被選中的 task context 則透過 `mret` 來恢復執行。

## 19. 建議閱讀順序

對第一次讀這份程式碼、而且偏硬體背景的人，建議閱讀順序如下：

1. `tools/link_ddr.ld`
2. `tools/crt0.S`
3. `OS/trap.h`
4. `OS/trap_entry.S`
5. `OS/trap.c`
6. `OS/freertos/portmacro.h`
7. `OS/freertos/port.c`
8. `OS/freertos/FreeRTOSConfig.h`
9. `OS/freertos/freertos_demo.c`
10. `OS/freertos/freertos_snake_demo.c`
11. `game/Snake_vga.h`
12. `machine_irq_sources.v`
13. `CSR.v`
14. `icache_pipeline_top.v`

這個順序和實際控制流程相當接近。

## 20. 最後總結

這個系統之所以能運作，是因為以下三層同時存在：

- 支援 traps、CSRs 與 timer interrupts 的硬體 architectural support
- 將 trap event 轉換成 FreeRTOS context management 的軟體 glue code
- 被連結進同一個 firmware image 中的 FreeRTOS kernel 本體，以及 application 與 game

最關鍵的概念是：

> RTOS 不是外部服務。它是被編譯進 firmware image 裡，而它之所以能運作，是因為這顆自製 CPU 現在已經提供了 port layer 所需要的完整 trap/interrupt 機制。
