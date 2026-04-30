# RTOS API 使用說明書

這份文件說明如何在目前的自製 RISC-V CPU 專案上使用 FreeRTOS 來寫 C 程式。目標讀者是會寫 C，但不熟 RTOS 的軟體工程師。

## 1. 這個 RTOS 在本專案中的角色

一般裸機程式通常長這樣：

```c
int main(void) {
    while (1) {
        read_uart();
        update_game();
        draw_vga();
        delay();
    }
}
```

這種寫法所有工作都擠在同一個 loop 裡。如果某一段程式等太久，其他工作就會被卡住。

FreeRTOS 的作用是把程式拆成多個 task：

```text
task A: 處理 UART input
task B: 更新遊戲邏輯
task C: 更新 VGA 畫面
```

RTOS scheduler 會根據 tick interrupt 和 task 狀態切換執行權。你不用自己寫大 while loop 去輪詢所有工作，而是讓每個 task 專心做自己的事。

目前在硬體上已驗證：

- `rtos_smoke.mem` 可以正常跑 queue producer/consumer。
- `rtos_vga_demo.mem` 可以讓三個 task 分別更新 VGA 左/中/右區塊。
- `rtos_vga_queue_demo.mem` 可以展示 Producer task 透過 FreeRTOS Queue 傳 event 給 Renderer task，再更新 VGA；同時 Heartbeat task 獨立執行。
- `mtime` tick interrupt、`vTaskDelay()`、context switch、UART、VGA MMIO 都可以運作。

## 2. 目前可用與不可用的 FreeRTOS 功能

設定檔在：

```text
OS/rtos/config/FreeRTOSConfig.h
```

目前建議使用的 API：

| 功能 | API | 狀態 |
|---|---|---|
| 建立 task | `xTaskCreateStatic()` | 可用 |
| 啟動 scheduler | `vTaskStartScheduler()` | 可用 |
| 延遲 / 讓出 CPU | `vTaskDelay()` | 可用 |
| 取得 tick | `xTaskGetTickCount()` | 可用 |
| Queue | `xQueueCreateStatic()`, `xQueueSend()`, `xQueueReceive()` | 可用 |
| Critical section | `taskENTER_CRITICAL()`, `taskEXIT_CRITICAL()` | 可用 |
| Task notification | `xTaskNotify...`, `ulTaskNotifyTake()` | 可用 |

目前不建議或尚未啟用：

| 功能 | 狀態 | 原因 |
|---|---|---|
| `xTaskCreate()` | 不可用 | dynamic allocation 關閉 |
| `pvPortMalloc()` | 不可用 | `configSUPPORT_DYNAMIC_ALLOCATION = 0` |
| Mutex | 不可用 | `configUSE_MUTEXES = 0` |
| Software timer | 不可用 | `configUSE_TIMERS = 0` |
| `vTaskDelete()` | 不可用 | `INCLUDE_vTaskDelete = 0` |

因此目前寫法要以「static allocation」為主：task stack、TCB、queue storage 都要自己宣告成 static/global。

## 3. 最小 RTOS 程式架構

一個最小 FreeRTOS app 會包含：

1. include FreeRTOS headers
2. 宣告 task TCB 和 stack
3. 寫 task function
4. 用 `xTaskCreateStatic()` 建立 task
5. 呼叫 `vTaskStartScheduler()`

範例：

```c
#include "FreeRTOS.h"
#include "task.h"
#include "uart.h"

#define TASK_STACK_WORDS 384u

static StaticTask_t blink_tcb;
static StackType_t blink_stack[TASK_STACK_WORDS];

static void blink_task(void *arg) {
    (void)arg;

    for (;;) {
        rtos_uart_write_line("[APP] blink");
        vTaskDelay(pdMS_TO_TICKS(500u));
    }
}

int main(void) {
    TaskHandle_t handle;

    rtos_uart_write_line("[APP] boot");

    handle = xTaskCreateStatic(
        blink_task,
        "BLINK",
        TASK_STACK_WORDS,
        NULL,
        2u,
        blink_stack,
        &blink_tcb
    );

    if (handle == NULL) {
        rtos_uart_write_line("[APP] task create failed");
        for (;;) {}
    }

    vTaskStartScheduler();

    for (;;) {}
}
```

重點：

- task function 不應該 return。
- task 裡面通常是 `for (;;) { ... }`。
- 用 `vTaskDelay()` 讓 task 睡眠，讓其他 task 有機會執行。
- 不要用 busy-loop delay 當主要排程方式。

## 4. 建立多個 task

每個 task 都需要自己的 TCB 和 stack：

```c
#define TASK_STACK_WORDS 384u

static StaticTask_t task_a_tcb;
static StaticTask_t task_b_tcb;
static StackType_t task_a_stack[TASK_STACK_WORDS];
static StackType_t task_b_stack[TASK_STACK_WORDS];

static void task_a(void *arg) {
    (void)arg;
    for (;;) {
        rtos_uart_write_line("[APP] A");
        vTaskDelay(pdMS_TO_TICKS(200u));
    }
}

static void task_b(void *arg) {
    (void)arg;
    for (;;) {
        rtos_uart_write_line("[APP] B");
        vTaskDelay(pdMS_TO_TICKS(700u));
    }
}
```

在 `main()` 建立：

```c
xTaskCreateStatic(task_a, "A", TASK_STACK_WORDS, NULL, 2u, task_a_stack, &task_a_tcb);
xTaskCreateStatic(task_b, "B", TASK_STACK_WORDS, NULL, 2u, task_b_stack, &task_b_tcb);
vTaskStartScheduler();
```

如果兩個 task priority 相同，scheduler 會依照 tick 和 delay 狀態安排它們執行。  
目前建議先用 priority `2u`，保持和已驗證 demo 一致。

## 5. 使用 `vTaskDelay()`

`vTaskDelay()` 的單位是 tick，不是 ms。  
目前 `configTICK_RATE_HZ = 1000`，所以 1 tick 約等於 1 ms。

建議寫法：

```c
vTaskDelay(pdMS_TO_TICKS(500u));
```

不要寫成：

```c
for (volatile int i = 0; i < 1000000; i++) {}
```

busy loop 會浪費 CPU，而且不能清楚表達「這個 task 現在可以睡覺，讓別人跑」。

## 6. 使用 Queue 傳資料

Queue 適合用來讓 task 之間傳資料。  
目前 `rtos_smoke.mem` 就是 producer task 用 queue 傳資料給 consumer task。

### 6.1 宣告 queue

```c
#include "queue.h"

#define QUEUE_LENGTH 4u

static StaticQueue_t queue_tcb;
static uint32_t queue_storage[QUEUE_LENGTH];
static QueueHandle_t app_queue;
```

### 6.2 建立 queue

```c
app_queue = xQueueCreateStatic(
    QUEUE_LENGTH,
    sizeof(uint32_t),
    (uint8_t *)queue_storage,
    &queue_tcb
);

if (app_queue == NULL) {
    rtos_uart_write_line("[APP] queue create failed");
    for (;;) {}
}
```

### 6.3 Producer task

```c
static void producer_task(void *arg) {
    uint32_t value = 0u;
    (void)arg;

    for (;;) {
        value++;
        xQueueSend(app_queue, &value, portMAX_DELAY);
        vTaskDelay(pdMS_TO_TICKS(100u));
    }
}
```

### 6.4 Consumer task

```c
static void consumer_task(void *arg) {
    uint32_t value;
    (void)arg;

    for (;;) {
        if (xQueueReceive(app_queue, &value, portMAX_DELAY) == pdPASS) {
            rtos_uart_write("[APP] received=");
            rtos_uart_write_hex32(value);
            rtos_uart_write("\n");
        }
    }
}
```

`portMAX_DELAY` 代表如果 queue 沒資料，task 會 block，不會浪費 CPU。

## 7. 使用 Critical Section

如果多個 task 會同時使用同一個輸出裝置，例如 UART，建議用 critical section 保護一整段輸出，避免字串交錯。

```c
taskENTER_CRITICAL();
rtos_uart_write("[APP] tick=");
rtos_uart_write_hex32((uint32_t)xTaskGetTickCount());
rtos_uart_write(" task=A\n");
taskEXIT_CRITICAL();
```

注意：

- critical section 要短。
- 不要在 critical section 裡做很久的運算。
- 不要在 critical section 裡呼叫可能長時間 block 的 API。

## 8. 使用 UART

本專案提供簡單 UART helper：

```c
#include "uart.h"

rtos_uart_write("hello");
rtos_uart_write_line("hello line");
rtos_uart_write_hex32(0x12345678u);
```

UART 適合用來：

- 印 boot log
- 印 task start
- 印 frame counter
- 印錯誤訊息

範例：

```c
rtos_uart_write("[APP] tick=");
rtos_uart_write_hex32((uint32_t)xTaskGetTickCount());
rtos_uart_write("\n");
```

## 9. 使用 VGA

建議使用專案既有的 VGA API：

```c
#include "vga_fb.h"
```

常用 API：

```c
vga_fb_set_draw_buffer(0u);
vga_fb_clear(color);
vga_fb_fill_rect4(x, y, w, h, color);
vga_fb_present();
```

注意：

- VGA 解析度目前是 `160 x 120`。
- color 是 4-bit，範圍 `0..15`。
- `vga_fb_fill_rect4()` 的 `x` 和 `w` 必須是 4 的倍數。
- 寫完畫面後呼叫 `vga_fb_present()`。

範例：

```c
vga_fb_set_draw_buffer(0u);
vga_fb_clear(0u);
vga_fb_fill_rect4(8u, 28u, 32u, 24u, 2u);
vga_fb_present();
```

## 10. VGA + RTOS 三 task 範例概念

目前 `OS/rtos/src/main_vga_demo.c` 的做法是：

```text
left_task   每 500 ms 更新左區塊
middle_task 每 600 ms 更新中區塊
right_task  每 700 ms 更新右區塊
```

每個 task 只更新自己的 panel：

```c
for (;;) {
    frame++;
    draw_my_panel(frame);
    vTaskDelay(pdMS_TO_TICKS(500u));
}
```

這比單一 while loop 更能展示 RTOS 的意義，因為三個 task 各自有不同週期，scheduler 會根據 delay 和 tick 讓它們輪流執行。

## 11. Queue + VGA Pipeline Demo

如果要展示「task 不只是各自跑，而是能彼此傳資料」，可以使用：

```text
OS/rtos/src/main_vga_queue_demo.c
```

它的結構是：

```text
Producer Task -> FreeRTOS Queue -> Renderer Task -> VGA
Heartbeat Task -> VGA / UART
```

### 11.1 這個 demo 證明什麼

這個 demo 比三 task VGA demo 更進一步，因為它展示了 task 之間的資料流：

- Producer task 週期性產生 event。
- Producer 用 `xQueueSend()` 把 event 放進 FreeRTOS queue。
- Renderer task 用 `xQueueReceive()` 等待 event。
- Renderer 收到 event 後才更新中間 VGA 區塊。
- Heartbeat task 與 queue 無關，獨立更新右側區塊，證明 scheduler 同時排程其他 task。

因此它可以用來說明：

```text
這不是裸機 while loop 畫圖。
這是多個 FreeRTOS task 透過 queue 串成 pipeline。
```

### 11.2 VGA 畫面怎麼看

畫面上方是一條小標籤：

```text
P -> Q -> R        H
```

意義如下：

| 畫面符號 | 意義 |
|---|---|
| `P` | Producer task，負責產生 event |
| `Q` | FreeRTOS queue，負責暫存 event |
| `R` | Renderer task，收到 queue event 後更新 VGA |
| `H` | Heartbeat task，獨立週期執行 |

畫面下方有三組 8 格進度條：

- 左下：Producer 進度。
- 中下：Renderer / queue event 進度。
- 右下：Heartbeat 進度。

每次對應的 task 更新時，亮格會往右移動。觀眾不用讀數字，只要看到三組格子持續前進，就能知道三個 task 都在運作。

### 11.3 對應到的 RTOS API

這個 demo 使用：

```c
xTaskCreateStatic()
xQueueCreateStatic()
xQueueSend()
xQueueReceive()
vTaskDelay()
xTaskGetTickCount()
taskENTER_CRITICAL()
taskEXIT_CRITICAL()
```

其中最重要的是 queue 的 producer/consumer 關係：

```c
/* Producer task */
xQueueSend(event_queue, &event, pdMS_TO_TICKS(10u));

/* Renderer task */
xQueueReceive(event_queue, &event, portMAX_DELAY);
```

`portMAX_DELAY` 代表如果 queue 還沒有資料，Renderer task 會 block，不會浪費 CPU。等 Producer 送 event 進 queue 後，Renderer 才會被喚醒處理。

### 11.4 編譯與上板

編譯：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\build_rtos_vga_queue_demo.ps1
```

目前已驗證輸出：

```text
Wrote C:\cpu_design\build_rtos\rtos_vga_queue_demo.mem with 5900 words
BIN size: 23600 bytes
```

上板：

```powershell
python .\uart_send_mem.py --port COM7 --baud 115200 --mem .\build_rtos\rtos_vga_queue_demo.mem --delay 3.0 --preamble 4096 --interactive
```

預期 UART 啟動訊息：

```text
[PIPE] RTOS queue VGA pipeline boot
[PIPE] queue
[PIPE] producer
[PIPE] renderer
[PIPE] heartbeat
[PIPE] scheduler
```

執行中應持續看到：

```text
[PIPE] tick=... task=P send=...
[PIPE] tick=... task=R recv=...
[PIPE] tick=... task=H beat=...
```

### 11.5 展示時可以怎麼說

可以這樣講：

```text
左邊 P 是 Producer task，負責產生資料。
資料不是直接拿去畫圖，而是先放進 FreeRTOS Queue。
中間 Q/R 代表 Renderer task 從 queue 收到資料後，才更新 VGA。
右邊 H 是獨立 Heartbeat task，證明 scheduler 同時排程其他工作。
所以這個 demo 展示了 task scheduling、queue IPC、blocking receive 和 VGA 輸出 pipeline。
```

這個 demo 可以作為目前專案的階段性成果展示。

## 12. 如何建立自己的 RTOS app

建議流程：

1. 複製 `OS/rtos/src/main.c` 或 `OS/rtos/src/main_vga_demo.c`。
2. 改 task function。
3. 保留 static TCB / stack 配置。
4. 使用 `xTaskCreateStatic()` 建 task。
5. 使用 `vTaskDelay()` 或 queue block，避免 busy loop。
6. 修改或複製 build script，把 source 換成你的 app。

最簡單做法是先改：

```text
OS/rtos/src/main_vga_demo.c
```

然後 build：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\build_rtos_vga_demo.ps1
```

上板：

```powershell
python .\uart_send_mem.py --port COM7 --baud 115200 --mem .\build_rtos\rtos_vga_demo.mem --delay 3.0 --preamble 4096 --interactive
```

如果是純 UART/queue 測試，可以 build smoke：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\build_rtos_smoke.ps1
```

上板：

```powershell
python .\uart_send_mem.py --port COM7 --baud 115200 --mem .\build_rtos\rtos_smoke.mem --delay 3.0 --preamble 4096 --interactive
```

如果要從 Queue + VGA pipeline demo 開始改，可以 build：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\build_rtos_vga_queue_demo.ps1
```

上板：

```powershell
python .\uart_send_mem.py --port COM7 --baud 115200 --mem .\build_rtos\rtos_vga_queue_demo.mem --delay 3.0 --preamble 4096 --interactive
```

## 13. 常見錯誤

### 13.1 忘記呼叫 `vTaskStartScheduler()`

如果沒有呼叫 scheduler，task 不會開始跑。

### 13.2 task function return

task 不應該 return。請使用：

```c
for (;;) {
    ...
}
```

### 13.3 使用 dynamic allocation API

目前不要使用：

```c
xTaskCreate(...)
pvPortMalloc(...)
```

請使用：

```c
xTaskCreateStatic(...)
xQueueCreateStatic(...)
```

### 13.4 用 busy loop 取代 `vTaskDelay()`

busy loop 會讓 task 長時間佔住 CPU。  
如果你只是想等一段時間，請用：

```c
vTaskDelay(pdMS_TO_TICKS(100u));
```

### 13.5 自己手寫 VGA framebuffer 格式

目前建議不要重新手寫 framebuffer helper。  
請使用：

```c
vga_fb_fill_rect4(...)
vga_fb_present()
```

這是目前已驗證能在板上正常更新的路徑。

## 14. 展示時可以怎麼說

可以這樣描述：

```text
這個程式跑在我們自製 RISC-V CPU 上，使用 FreeRTOS 做 task scheduling。
畫面左、中、右三個區塊分別由三個不同 task 控制。
三個 task 使用不同的 vTaskDelay 週期，所以會以不同節奏更新。
UART 同時輸出每個 task 的 frame counter，證明三個 task 都持續被 scheduler 喚醒並執行。
```

這能證明：

- CPU 可以跑 FreeRTOS。
- timer tick interrupt 正常。
- context switch 正常。
- 多個 C task 可以共享 UART/VGA MMIO。
- 可以用 RTOS API 寫出比裸機 while loop 更清楚的多工作程式。
