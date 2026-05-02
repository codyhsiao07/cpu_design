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

| 功能              | API                                                       | 狀態 |
| ----------------- | --------------------------------------------------------- | ---- |
| 建立 task         | `xTaskCreateStatic()`                                     | 可用 |
| 啟動 scheduler    | `vTaskStartScheduler()`                                   | 可用 |
| 延遲 / 讓出 CPU   | `vTaskDelay()`                                            | 可用 |
| 取得 tick         | `xTaskGetTickCount()`                                     | 可用 |
| Queue             | `xQueueCreateStatic()`, `xQueueSend()`, `xQueueReceive()` | 可用 |
| Critical section  | `taskENTER_CRITICAL()`, `taskEXIT_CRITICAL()`             | 可用 |
| Task notification | `xTaskNotify...`, `ulTaskNotifyTake()`                    | 可用 |

### 2.1 可用 API 詳細說明

這一節把上表列出的 API 拆開說明。讀者在寫新的 RTOS app 時，通常會先用 `xTaskCreateStatic()` 建立 task，再用 `vTaskStartScheduler()` 啟動排程；task 內部則用 `vTaskDelay()`、queue、critical section 或 task notification 來控制執行節奏與 task 間溝通。

#### `xTaskCreateStatic()`: 建立一個靜態配置 task

用途：建立一個會被 scheduler 排程的 task。因為本專案關閉 dynamic allocation，所以要使用 `xTaskCreateStatic()`，並由使用者自己準備 task stack 與 TCB。

常見呼叫形式：

```c
TaskHandle_t xTaskCreateStatic(
    TaskFunction_t pxTaskCode,
    const char * const pcName,
    const uint32_t ulStackDepth,
    void * const pvParameters,
    UBaseType_t uxPriority,
    StackType_t * const puxStackBuffer,
    StaticTask_t * const pxTaskBuffer
);
```

參數說明：

| 參數             | 要填什麼                          | 說明                                                                                                                                                                                                              |
| ---------------- | --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pxTaskCode`     | task function 名稱                | 函式型態通常是 `static void task_name(void *arg)`。task function 不應該 return，內部通常是 `for (;;) { ... }`。                                                                                                   |
| `pcName`         | 短字串，例如 `"PIPE-P"`           | 給 debug/log 使用的 task 名稱。受 `configMAX_TASK_NAME_LEN` 限制，目前設定是 12。                                                                                                                                 |
| `ulStackDepth`   | stack word 數量，例如 `384u`      | 單位是 `StackType_t` 的元素數，不是 byte。若宣告 `StackType_t stack[384]`，這裡就填 `384u`。函式內的一般區域變數、函式呼叫過程、RTOS 切換 task 時要保存的狀態，會用到 task stack；函式程式碼本身不放在 task stack |
| `pvParameters`   | 傳給 task 的指標，沒有就填 `NULL` | task function 會從 `arg` 收到這個值。可用來傳入設定結構、queue handle 或 MMIO context。                                                                                                                           |
| `uxPriority`     | priority，例如 `2u` 或 `3u`       | 數字越大 priority 越高。`configMAX_PRIORITIES = 5`，可用範圍通常是 `0` 到 `4`。一般 app task 可先用 `2u`。                                                                                                        |
| `puxStackBuffer` | `StackType_t` 陣列                | 必須是可長期存在的 storage，建議宣告成 `static` 或 global，不能是會離開 scope 的 local array。                                                                                                                    |
| `pxTaskBuffer`   | `StaticTask_t` 物件位址           | task 的 TCB storage，同樣要是 `static` 或 global。                                                                                                                                                                |

`ulStackDepth` 和 `puxStackBuffer` 的關係：

這兩個參數要一起看。`puxStackBuffer` 是真正提供給 task 使用的 stack 記憶體起始位址；`ulStackDepth` 則告訴 FreeRTOS 這塊 stack 有幾個 `StackType_t` 元素。

例如：

```c
#define TASK_STACK_WORDS 384u

static StackType_t worker_stack[TASK_STACK_WORDS];
```

建立 task 時應該這樣填：

```c
xTaskCreateStatic(
    worker_task,
    "WORKER",
    TASK_STACK_WORDS,
    NULL,
    2u,
    worker_stack,
    &worker_tcb
);
```

這代表：

```text
這個 task 的 stack 從 worker_stack 開始，
可用大小是 384 個 StackType_t 元素。
```

如果 `StackType_t` 是 4 bytes，384 個元素就是：

```text
384 * 4 = 1536 bytes
```

常見錯誤是實際只宣告 384 個元素，卻告訴 FreeRTOS 有 1024 個元素：

```c
static StackType_t stack[384];

xTaskCreateStatic(
    worker_task,
    "WORKER",
    1024u,
    NULL,
    2u,
    stack,
    &worker_tcb
);
```

這種寫法可能讓 FreeRTOS 使用超出 `stack[384]` 以外的記憶體，造成資料被覆蓋或系統異常。正確做法是讓 `ulStackDepth` 和陣列大小一致：

```c
static StackType_t stack[384];

xTaskCreateStatic(
    worker_task,
    "WORKER",
    384u,
    NULL,
    2u,
    stack,
    &worker_tcb
);
```

更建議使用同一個 macro 管理大小，避免陣列長度和 `ulStackDepth` 不一致：

```c
#define TASK_STACK_WORDS 384u

static StackType_t stack[TASK_STACK_WORDS];

xTaskCreateStatic(
    worker_task,
    "WORKER",
    TASK_STACK_WORDS,
    NULL,
    2u,
    stack,
    &worker_tcb
);
```

`pxTaskBuffer` 和 `puxStackBuffer` 的差異：

這兩個參數都和 static allocation 有關，也就是 FreeRTOS 不會自己 malloc task 需要的記憶體，而是使用你事先宣告好的空間。差別在於它們放的資料不同。

| 參數 | 對應宣告 | 作用 |
|---|---|---|
| `puxStackBuffer` | `static StackType_t worker_stack[384];` | task 執行時使用的 stack 空間，會放 local variable、函式呼叫資訊、暫存 register、context switch 狀態。 |
| `pxTaskBuffer` | `static StaticTask_t worker_tcb;` | task control block，也就是 FreeRTOS 用來管理這個 task 的資料結構。 |

`worker_stack` 比較像一塊 stack 陣列空間；`worker_tcb` 則是一個 struct 物件，不是陣列。剛宣告時，它們通常還沒有有意義的內容。你只需要把它們傳給 `xTaskCreateStatic()`，FreeRTOS 會在建立 task 時初始化它們。

一般情況不需要手動設定 `worker_stack[]` 或 `worker_tcb` 的內容：

```c
static StaticTask_t worker_tcb;
static StackType_t worker_stack[TASK_STACK_WORDS];

/* 不需要自己寫 worker_tcb.xxx = ... 或 worker_stack[0] = ... */
xTaskCreateStatic(
    worker_task,
    "WORKER",
    TASK_STACK_WORDS,
    NULL,
    2u,
    worker_stack,
    &worker_tcb
);
```

需要自己注意的是：每個 task 都要有自己獨立的 TCB 和 stack，不能多個 task 共用同一組。

錯誤範例：

```c
static StaticTask_t shared_tcb;
static StackType_t shared_stack[384];

xTaskCreateStatic(task_a, "A", 384u, NULL, 2u, shared_stack, &shared_tcb);
xTaskCreateStatic(task_b, "B", 384u, NULL, 2u, shared_stack, &shared_tcb);
```

上面這種寫法是錯的，因為 `task_a` 和 `task_b` 共用了同一塊 stack 和同一個 TCB，兩個 task 的執行狀態會互相覆蓋。

正確範例：

```c
static StaticTask_t task_a_tcb;
static StackType_t task_a_stack[384];

static StaticTask_t task_b_tcb;
static StackType_t task_b_stack[384];

xTaskCreateStatic(task_a, "A", 384u, NULL, 2u, task_a_stack, &task_a_tcb);
xTaskCreateStatic(task_b, "B", 384u, NULL, 2u, task_b_stack, &task_b_tcb);
```

`pvParameters` 補充說明：

`xTaskCreateStatic()` 的第 4 個參數會原封不動傳給 task function 的 `arg`。如果第 4 個參數填 `NULL`，task function 收到的 `arg` 就是 `NULL`；如果填某個 struct 的位址，task function 就可以把 `arg` cast 回該 struct 型別，讀取裡面的設定。

例如 task function 通常長這樣：

```c
static void worker_task(void *arg) {
    /* arg 來自 xTaskCreateStatic() 的第 4 個參數。 */
}
```

如果 task 不需要外部設定，可以直接傳 `NULL`：

```c
xTaskCreateStatic(
    worker_task,
    "WORKER",
    TASK_STACK_WORDS,
    NULL,
    2u,
    worker_stack,
    &worker_tcb
);
```

如果 task 需要知道要使用哪個 queue、多久執行一次，或要操作哪個硬體 MMIO base address，可以傳一個設定 struct：

```c
typedef struct {
    QueueHandle_t queue;
    uint32_t period_ms;
    volatile uint32_t *mmio_base;
} WorkerConfig_t;

static WorkerConfig_t worker_cfg;

static void worker_task(void *arg) {
    WorkerConfig_t *cfg = (WorkerConfig_t *)arg;

    for (;;) {
        use_queue(cfg->queue);
        use_mmio(cfg->mmio_base);
        vTaskDelay(pdMS_TO_TICKS(cfg->period_ms));
    }
}

worker_cfg.queue = event_queue;
worker_cfg.period_ms = 100u;
worker_cfg.mmio_base = (volatile uint32_t *)0x40000000u;

xTaskCreateStatic(
    worker_task,
    "WORKER",
    TASK_STACK_WORDS,
    &worker_cfg,
    2u,
    worker_stack,
    &worker_tcb
);
```

這種寫法的重點是：傳進 `pvParameters` 的資料必須在 task 執行期間一直有效。建議傳 `static` 或 global 物件的位址，不要傳一般 local variable 的位址，因為 task 可能晚一點才執行，到那時 local variable 可能已經離開 scope。

回傳值：

| 回傳值    | 意義                                          |
| --------- | --------------------------------------------- |
| 非 `NULL` | 建立成功，回傳 task handle。                  |
| `NULL`    | 建立失敗，通常是參數或 static buffer 不正確。 |

範例：

```c
#define TASK_STACK_WORDS 384u

static StaticTask_t worker_tcb;
static StackType_t worker_stack[TASK_STACK_WORDS];

static void worker_task(void *arg) {
    (void)arg;

    for (;;) {
        rtos_uart_write_line("[APP] worker");
        vTaskDelay(pdMS_TO_TICKS(500u));
    }
}

TaskHandle_t handle = xTaskCreateStatic(
    worker_task,
    "WORKER",
    TASK_STACK_WORDS,
    NULL,
    2u,
    worker_stack,
    &worker_tcb
);

if (handle == NULL) {
    rtos_uart_write_line("[APP] task create failed");
    for (;;) {}
}
```

補充：`worker_stack` 和 `worker_tcb` 建立後由誰使用：

```text
worker_stack -> 傳給 puxStackBuffer，給 FreeRTOS 當這個 task 的 stack 使用
worker_tcb   -> 傳給 pxTaskBuffer，給 FreeRTOS 當這個 task 的 TCB 使用
handle       -> xTaskCreateStatic() 回傳給 application，用來操作這個 task
```

`StackType_t` 不需要 application 自己定義。它由目前使用的 FreeRTOS CPU port 定義，通常來自 `portmacro.h`。application 只要 include：

```c
#include "FreeRTOS.h"
#include "task.h"
```

`TASK_STACK_WORDS` 的單位是 `StackType_t` word，不是 byte。例如 `StackType_t` 若是 32-bit，`384u` 就代表 `384 * 4 = 1536` bytes 的 stack 空間。

呼叫 `xTaskCreateStatic()` 成功後，`worker_stack` 和 `worker_tcb` 就交給 FreeRTOS 管理，application 不應該再直接讀寫或清除它們。

不要這樣做：

```c
worker_stack[0] = 123;                         /* 不要 */
memset(worker_stack, 0, sizeof(worker_stack)); /* 不要 */

memset(&worker_tcb, 0, sizeof(worker_tcb));    /* 不要 */
```

原因是 `worker_stack` 會存放 task 執行時的 call stack、local variable、return address、暫存 register 與 context switch 狀態；`worker_tcb` 則是 FreeRTOS scheduler 管理 task 狀態、priority、stack pointer 等資料用的結構。任意修改這兩塊記憶體可能造成 task crash、跳到錯誤位址、排程異常，或產生難以追蹤的 bug。

建立成功後，application 應該透過 `handle` 操作 task，例如：

```c
vTaskSuspend(handle);
vTaskResume(handle);
```

如果要觀察 stack 是否足夠，可以使用：

```c
UBaseType_t words_left = uxTaskGetStackHighWaterMark(handle);
```

這裡回傳的 `words_left` 單位同樣是 `StackType_t` word，不是 byte。

使用注意事項：

- task stack 和 TCB 不能放在會消失的區域變數中。`main()` 執行到 `vTaskStartScheduler()` 後，這些 storage 仍然要有效。
- task function 不要直接 `return`。如果 task 完成後需要停止，目前本專案未啟用 `vTaskDelete()`，所以建議設計成永久 loop。
- priority 不要全部設太高。若某個高 priority task 不 delay、不 block，低 priority task 可能沒有機會執行。
- stack 太小可能造成 stack overflow。若 task 內有較大的 local array，應改成 static/global，或提高 stack word 數。

#### `vTaskStartScheduler()`: 啟動 FreeRTOS scheduler

用途：啟動 scheduler，讓 FreeRTOS 開始根據 priority、tick interrupt、block 狀態切換 task。建立完所有必要 task 之後，`main()` 通常最後呼叫這個 API。

常見呼叫形式：

```c
void vTaskStartScheduler(void);
```

參數：無。

回傳值：無。正常情況下不會回到呼叫點。如果回到 `main()`，通常代表 scheduler 啟動失敗或設定有問題。

範例：

```c
int main(void) {
    setup_hardware();
    create_app_tasks();

    vTaskStartScheduler();

    for (;;) {
        /* 正常情況不會執行到這裡。 */
    }
}
```

使用注意事項：

- 要先建立至少一個 application task，再呼叫 `vTaskStartScheduler()`。
- scheduler 啟動後，程式流程由 task 接手，不應再期待 `main()` 的後續程式繼續做一般工作。
- 若忘記呼叫它，task 只會被建立，不會被排程執行。

`vTaskStartScheduler()` 如何知道要排程哪些程式：

`vTaskStartScheduler()` 不需要你在呼叫時指定 task list。FreeRTOS 在每次呼叫 `xTaskCreateStatic()` 時，就已經把該 task 登記到 kernel 內部的 task list。當 `vTaskStartScheduler()` 啟動後，scheduler 會從這些已建立的 task 裡挑選要執行的 task。

例如：

```c
xTaskCreateStatic(task_a, "A", 384u, NULL, 2u, task_a_stack, &task_a_tcb);
xTaskCreateStatic(task_b, "B", 384u, NULL, 2u, task_b_stack, &task_b_tcb);

vTaskStartScheduler();
```

上面程式中，`task_a` 和 `task_b` 已經在 `xTaskCreateStatic()` 時被登記。`vTaskStartScheduler()` 開始後，FreeRTOS 會排程這兩個 task，而不是排程 `main()` 後面的普通程式碼。

scheduler 選 task 的基本概念：

```text
1. 先看哪些 task 是 ready 狀態。
2. 從 ready task 裡選 priority 最高的 task。
3. 如果同 priority 有多個 ready task，會依 tick / time slicing 輪流執行。
4. 如果某個 task 呼叫 vTaskDelay() 或 xQueueReceive(..., portMAX_DELAY)，它會進入 blocked 狀態，scheduler 就換其他 ready task 執行。
```

因此 `vTaskStartScheduler()` 可以理解成：

```text
從現在開始，CPU 執行權交給 FreeRTOS。
請 FreeRTOS 從已建立的 task 中挑選 task 來執行。
```

`main()` 裡哪些程式會執行：

在 `vTaskStartScheduler()` 之前的程式會照順序執行，適合放硬體初始化、全域資料初始化、建立 queue、建立 task。

```c
int main(void) {
    init_uart();
    init_vga();
    create_queues();
    create_tasks();

    vTaskStartScheduler();

    draw_something();  /* 正常情況不會執行到這裡。 */
    for (;;) {}
}
```

正常情況下，`vTaskStartScheduler()` 啟動後不會回到 `main()`。所以寫在它後面的程式通常不會執行。如果有東西不需要長期被排程，只是初始化一次，就放在 `vTaskStartScheduler()` 之前。如果是需要長期運作的功能，就應該寫成 task。

以遊戲程式為例，`main()` 通常只負責初始化硬體、建立 task、啟動 scheduler；遊戲邏輯則放進 task function 裡：

```c
static void game_task(void *arg) {
    (void)arg;

    game_init();

    for (;;) {
        game_read_input();
        game_update();
        game_render();

        vTaskDelay(pdMS_TO_TICKS(16u));
    }
}

int main(void) {
    hardware_init();

    xTaskCreateStatic(
        game_task,
        "GAME",
        GAME_STACK_WORDS,
        NULL,
        2u,
        game_stack,
        &game_tcb
    );

    vTaskStartScheduler();

    for (;;) {}
}
```

這種寫法代表遊戲邏輯是由 scheduler 排程的 task。若遊戲邏輯沒有放進 task，也沒有在 scheduler 啟動前執行，那 `vTaskStartScheduler()` 之後它不會自己被執行。

如果某個 task 只需要做有限次工作，也不建議讓 task function 直接跑到結尾 return。標準 FreeRTOS 通常會用 `vTaskDelete(NULL)` 刪除自己，但本專案目前 `INCLUDE_vTaskDelete = 0`，所以 task 結束條件達成後應該進入不 return 的等待迴圈：

```c
static void init_once_task(void *arg) {
    (void)arg;

    setup_runtime_data();

    for (;;) {
        vTaskDelay(portMAX_DELAY);
    }
}
```

#### `vTaskDelay()`: 讓目前 task 休眠一段 tick

用途：讓目前正在執行的 task 進入 blocked state 一段時間，把 CPU 交回 scheduler，讓其他 ready task 可以執行。這是 RTOS 程式中取代 busy loop delay 的主要方式。

常見呼叫形式：

```c
void vTaskDelay(const TickType_t xTicksToDelay);
```

參數說明：

| 參數            | 要填什麼 | 說明                                                                |
| --------------- | -------- | ------------------------------------------------------------------- |
| `xTicksToDelay` | tick 數  | 單位是 RTOS tick，不是毫秒。建議用 `pdMS_TO_TICKS(ms)` 從毫秒轉換。 |

範例：

```c
vTaskDelay(pdMS_TO_TICKS(100u));
```

在本專案目前設定中，`configTICK_RATE_HZ = 1000`，所以 1 tick 約等於 1 ms。不過程式仍建議寫 `pdMS_TO_TICKS()`，避免未來 tick rate 改變時需要大幅修改程式。

`vTaskDelay()` 會讓哪個 task 休眠：

`vTaskDelay()` 沒有 task handle 參數，因為它永遠作用在「目前正在執行的 task」。誰執行到 `vTaskDelay()`，誰就進入 blocked / delayed 狀態。

例如：

```c
static void task_a(void *arg) {
    (void)arg;

    for (;;) {
        rtos_uart_write_line("A");
        vTaskDelay(pdMS_TO_TICKS(100u));
    }
}

static void task_b(void *arg) {
    (void)arg;

    for (;;) {
        rtos_uart_write_line("B");
        vTaskDelay(pdMS_TO_TICKS(300u));
    }
}
```

當 `task_a` 執行到 `vTaskDelay(pdMS_TO_TICKS(100u))`，休眠的是 `task_a`。當 `task_b` 執行到 `vTaskDelay(pdMS_TO_TICKS(300u))`，休眠的是 `task_b`。

流程可以理解成：

```text
1. scheduler 目前選中 task_a 執行。
2. task_a 執行到 vTaskDelay(100 ticks)。
3. FreeRTOS 把 task_a 標記成 delayed，醒來時間 = current_tick + 100。
4. scheduler 立刻挑下一個 ready task 執行。
5. tick interrupt 持續更新 RTOS tick。
6. 到時間後，task_a 從 delayed 變回 ready。
7. 之後 scheduler 再依 priority 決定何時讓 task_a 繼續執行。
```

有 `vTaskDelay()` 不代表 task 一被排到就立刻暫停，而是 task 執行到那一行才暫停。醒來後，會從 `vTaskDelay()` 後面的程式繼續執行。

```c
static void game_task(void *arg) {
    (void)arg;

    for (;;) {
        game_read_input();
        game_update();
        game_render();

        vTaskDelay(pdMS_TO_TICKS(16u));
    }
}
```

上面的流程是：

```text
game_task 被排到
-> game_read_input()
-> game_update()
-> game_render()
-> vTaskDelay(16 ms)，game_task 休眠
-> 16 ms 後 game_task 變回 ready
-> 下次被排到時，從 vTaskDelay() 後面繼續，回到 for 迴圈開頭
```

RTOS 也不是一次把所有 task 都執行完。單核心 CPU 同一時間只有一個 task 在 running，scheduler 會在不同 task 之間切換：

```text
Running：現在正在 CPU 上執行。
Ready：可以執行，等 scheduler 排到它。
Blocked / Delayed：正在等時間、queue、notification，暫時不能執行。
```

所以 task 通常寫成：

```c
for (;;) {
    do_some_work();
    vTaskDelay(pdMS_TO_TICKS(100u));
}
```

意思是：

```text
這個 task 長期存在。
每次醒來做一小段工作。
做完後休眠，把 CPU 讓給其他 ready task。
時間到後再變回 ready，等待 scheduler 再次排到它。
```

`pdMS_TO_TICKS()` 的作用：

`vTaskDelay()` 的參數單位是 tick，不是毫秒。`pdMS_TO_TICKS(100u)` 是把 100 ms 轉成目前 FreeRTOS 設定下對應的 tick 數。

```c
vTaskDelay(pdMS_TO_TICKS(100u));
```

讀法是：

```text
讓目前 task 休眠 100 ms。
```

如果直接寫：

```c
vTaskDelay(100u);
```

意思其實是：

```text
讓目前 task 休眠 100 個 tick。
```

目前本專案 `configTICK_RATE_HZ = 1000`，所以 1 tick 約等於 1 ms，`vTaskDelay(100u)` 剛好也是約 100 ms。但如果未來改成 `configTICK_RATE_HZ = 100`，1 tick 會變成 10 ms，`vTaskDelay(100u)` 就會變成約 1000 ms。

因此建議寫：

```c
vTaskDelay(pdMS_TO_TICKS(100u));
```

這樣程式語意是「100 ms」，即使未來 tick rate 改變，也比較不容易寫錯。

`100u` 裡面的 `u` 是 C 語言的 unsigned 常數，表示這個數字是 unsigned integer。在 embedded C 裡常這樣寫，讓型別更明確。

使用注意事項：

- `vTaskDelay()` 是相對延遲。例如呼叫當下是 tick 1000，delay 100 tick，task 約在 tick 1100 之後重新變成 ready。
- 不要用空迴圈製造延遲，因為 busy loop 會占住 CPU，降低其他 task 的反應性。
- `vTaskDelay(0)` 通常只表示讓 scheduler 有機會重新排程，不適合當作精準延遲。
- 需要固定週期時，標準 FreeRTOS 常用 `vTaskDelayUntil()`，但本專案目前 `INCLUDE_xTaskDelayUntil = 0`，所以文件中的 demo 先使用 `vTaskDelay()`。

#### `xTaskGetTickCount()`: 取得目前 RTOS tick

用途：讀取 FreeRTOS 目前累積的 tick count。常用於 UART log、簡單 timestamp、量測 task 是否有持續被排程。

常見呼叫形式：

```c
TickType_t xTaskGetTickCount(void);
```

參數：無。

回傳值：

| 回傳值       | 意義                                                          |
| ------------ | ------------------------------------------------------------- |
| `TickType_t` | 從 scheduler 啟動後累積的 tick 數。此專案設定為 32-bit tick。 |

範例：

```c
TickType_t now = xTaskGetTickCount();
rtos_uart_write("[APP] tick=");
rtos_uart_write_hex32((uint32_t)now);
rtos_uart_write("\n");
```

tick count 可以理解成 RTOS 的時間計數器。scheduler 啟動後，每次 timer interrupt 產生一個 RTOS tick，tick count 就會加 1。目前本專案 `configTICK_RATE_HZ = 1000`，所以大約每 1 ms 產生 1 個 tick。

例如 UART 印出：

```text
tick=000003E8
```

`0x3E8` 是十進位 1000，表示 scheduler 啟動後大約經過了 1000 個 tick。以目前 1000 Hz tick rate 來看，大約就是 1 秒。

`xTaskGetTickCount()` 常見用途：

- 在 UART log 中加入 timestamp，方便觀察 task 何時執行。
- 確認 scheduler 和 timer tick 是否持續運作。
- 量測某段程式大約花了幾個 tick。
- 寫簡單 timeout 判斷。

範例：量測一段程式花多少 tick。

```c
TickType_t start = xTaskGetTickCount();

do_something();

TickType_t end = xTaskGetTickCount();
TickType_t elapsed = end - start;
```

範例：簡單 timeout。

```c
TickType_t start = xTaskGetTickCount();

while (!device_ready()) {
    if ((xTaskGetTickCount() - start) > pdMS_TO_TICKS(1000u)) {
        break;
    }
}
```

不過如果目標只是「等待一段時間」，task 裡通常應優先使用 `vTaskDelay()`，不要用 while loop 一直查 tick，避免變成 busy loop 占住 CPU。

tick 不等於 task 切換：

每一次 tick 代表 RTOS 時間前進一格，但不代表一定會發生 context switch。tick interrupt 來時，FreeRTOS 通常會做這些事：

```text
tick count +1
檢查 delayed task 是否到時間該醒來
判斷是否需要重新排程
```

如果不需要換 task，就會繼續執行原本的 task。只有在某些條件成立時才會切換，例如：

- 目前 task 呼叫 `vTaskDelay()`，自己進入 delayed。
- 目前 task 呼叫 `xQueueReceive()` 等資料，自己進入 blocked。
- tick interrupt 發現某個較高 priority task 已經變成 ready。
- 同 priority task 啟用 time slicing 時，tick 可能讓它們輪流執行。
- interrupt 喚醒了某個高 priority task。

所以可以這樣記：

```text
tick = RTOS 的時間單位。
context switch = scheduler 決定換 task。
tick 可能導致 context switch，但 tick 不等於 context switch。
```

使用注意事項：

- tick count 會在 32-bit 最大值後回繞。短時間 log 通常不受影響，但若要計算長時間差，要用 unsigned subtraction 的方式處理。
- 在多個 task 同時印 log 時，建議搭配 critical section 避免字串交錯。

#### `xQueueCreateStatic()`: 建立靜態配置 queue

用途：建立 task 間傳資料用的 queue。因為 dynamic allocation 關閉，本專案應使用 `xQueueCreateStatic()`，由使用者自己準備 queue control block 和 item storage。

常見呼叫形式：

```c
QueueHandle_t xQueueCreateStatic(
    UBaseType_t uxQueueLength,
    UBaseType_t uxItemSize,
    uint8_t * pucQueueStorageBuffer,
    StaticQueue_t * pxQueueBuffer
);
```

參數說明：

| 參數                    | 要填什麼                 | 說明                                                                                                   |
| ----------------------- | ------------------------ | ------------------------------------------------------------------------------------------------------ |
| `uxQueueLength`         | queue 可容納的 item 數量 | 例如 `4u` 表示最多暫存 4 筆資料。                                                                      |
| `uxItemSize`            | 每個 item 的 byte 數     | 通常填 `sizeof(type)`，例如 `sizeof(uint32_t)` 或 `sizeof(AppEvent_t)`。                               |
| `pucQueueStorageBuffer` | queue storage buffer     | buffer 大小至少要 `uxQueueLength * uxItemSize` bytes。常見寫法是把 typed array cast 成 `(uint8_t *)`。 |
| `pxQueueBuffer`         | `StaticQueue_t` 物件位址 | queue control block storage，必須長期有效，建議 static/global。                                        |

回傳值：

| 回傳值    | 意義                                         |
| --------- | -------------------------------------------- |
| 非 `NULL` | queue 建立成功。                             |
| `NULL`    | queue 建立失敗，通常是參數或 buffer 不正確。 |

範例：

```c
#define EVENT_QUEUE_LENGTH 4u

typedef struct {
    uint32_t id;
    uint32_t value;
} AppEvent_t;

static StaticQueue_t event_queue_tcb;
static AppEvent_t event_queue_storage[EVENT_QUEUE_LENGTH];
static QueueHandle_t event_queue;

event_queue = xQueueCreateStatic(
    EVENT_QUEUE_LENGTH,
    sizeof(AppEvent_t),
    (uint8_t *)event_queue_storage,
    &event_queue_tcb
);

if (event_queue == NULL) {
    rtos_uart_write_line("[APP] queue create failed");
    for (;;) {}
}
```

補充：`xQueueCreateStatic()` 相關物件由誰使用：

```text
event_queue_storage -> 傳給 pucQueueStorageBuffer，給 FreeRTOS 存放 queue item
event_queue_tcb     -> 傳給 pxQueueBuffer，給 FreeRTOS 管理 queue 狀態
event_queue         -> xQueueCreateStatic() 回傳給 application，用來操作這條 queue
```

和 static task 很像，storage/control block 是 application 先準備好，再交給 FreeRTOS 使用；handle 則是 application 後續呼叫 API 時使用。

重要觀念：`event_queue_storage` 不是「某一次要傳送的資料地址」。它是 queue 內部的倉庫，FreeRTOS 用它暫存多筆 queue item。

```c
typedef struct {
    uint32_t id;
    uint32_t value;
} AppEvent_t;

static AppEvent_t event_queue_storage[EVENT_QUEUE_LENGTH];
```

上面這段代表這條 queue 的每一筆資料格式是 `AppEvent_t`，而且 `event_queue_storage[]` 最多可以暫存 `EVENT_QUEUE_LENGTH` 筆 `AppEvent_t`。

真正要送資料時，要另外準備一筆實際資料，然後用 `xQueueSend()` 傳送：

```c
AppEvent_t event;

event.id = 1u;
event.value = 123u;

xQueueSend(event_queue, &event, portMAX_DELAY);
```

這裡的 `&event` 才是「這次要送的那一筆資料地址」。FreeRTOS 會依照建立 queue 時設定的 `uxItemSize`，把 `event` 的內容複製進 `event_queue_storage` 裡。

接收資料時也一樣，要準備一個接收用的變數：

```c
AppEvent_t received;

xQueueReceive(event_queue, &received, portMAX_DELAY);
```

這裡的 `&received` 是「這次接收資料要放到哪裡」。FreeRTOS 會從 `event_queue_storage` 裡取出一筆 item，複製到 `received`。

可以這樣記：

```text
AppEvent_t                  -> 定義每筆資料長什麼樣
event_queue_storage[]       -> queue 內部倉庫，可放多筆 AppEvent_t
event                       -> 這次要送的一筆 AppEvent_t
&event                      -> 這次要送進 queue 的資料地址
received                    -> 這次要接收的一筆 AppEvent_t
&received                   -> 這次接收資料要存放的地址
xQueueSend(..., &event, ...)     -> 把 event 複製進 queue
xQueueReceive(..., &received, ...) -> 從 queue 複製一筆資料到 received
```

```text
task:
worker_stack -> 給 FreeRTOS 用
worker_tcb   -> 給 FreeRTOS 用
handle       -> application 用

queue:
queue_storage -> 給 FreeRTOS 用
queue_tcb     -> 給 FreeRTOS 用
event_queue   -> application 用，也就是 QueueHandle_t 變數
```

`xQueueCreateStatic()` 不一定要放在 `xTaskCreateStatic()` 後面。比較常見、也比較安全的初始化順序是：

```text
1. 建立 queue
2. 建立 task
3. 呼叫 vTaskStartScheduler()
```

原因是 task 開始執行後可能立刻使用 queue，所以 queue 最好在 task 被 scheduler 排程前就已經建立完成。實務上通常會在 `main()` 或初始化函式中先呼叫 `xQueueCreateStatic()`，確認回傳值不是 `NULL` 後，再建立 producer/consumer task。

哪個 task 可以使用某條 queue，不是由 FreeRTOS 權限設定決定，而是看那個 task 的程式碼能不能取得 `QueueHandle_t`。誰拿得到 queue handle，誰就可以呼叫：

```c
xQueueSend(event_queue, &event, portMAX_DELAY);
xQueueReceive(event_queue, &event, portMAX_DELAY);
```

`event_queue` 的使用流程如下：

```c
static QueueHandle_t event_queue;
```

這行只是宣告一個 queue handle 變數。真正建立 queue 時，`xQueueCreateStatic()` 會回傳代表這條 queue 的 handle：

```c
event_queue = xQueueCreateStatic(
    EVENT_QUEUE_LENGTH,
    sizeof(AppEvent_t),
    (uint8_t *)event_queue_storage,
    &event_queue_tcb
);
```

建立成功後，task 之後要操作這條 queue，就把 `event_queue` 當成第一個參數傳給 queue API：

```c
xQueueSend(event_queue, &event, portMAX_DELAY);
xQueueReceive(event_queue, &event, portMAX_DELAY);
```

所以 `event_queue` 是 application 用來指定「我要操作哪一條 queue」的代號。它的角色類似 task 的 `TaskHandle_t handle`：

```text
TaskHandle_t handle       -> 給 vTaskSuspend(handle)、vTaskResume(handle) 用
QueueHandle_t event_queue -> 給 xQueueSend(event_queue)、xQueueReceive(event_queue) 用
```

常見做法有兩種：

```text
1. 把 QueueHandle_t 宣告成 static/global，讓需要的 task 看得到。
2. 透過 xTaskCreateStatic() 的第 4 個參數 pvParameters，把 queue handle 傳給指定 task。
```

如果希望設計清楚，可以讓 producer task 只呼叫 `xQueueSend()`，consumer task 只呼叫 `xQueueReceive()`，其他 task 不要取得這條 queue 的 handle。

FreeRTOS 自帶型別整理：

| 型別 | 來源 | 用途 |
| ---- | ---- | ---- |
| `StackType_t` | FreeRTOS port | task stack 陣列的元素型別。 |
| `StaticTask_t` | FreeRTOS | static task 的 TCB storage 型別。 |
| `TaskHandle_t` | FreeRTOS | task handle，application 用來操作 task。 |
| `QueueHandle_t` | FreeRTOS | queue handle，application 用來操作 queue。 |
| `StaticQueue_t` | FreeRTOS | static queue 的 control block storage 型別。 |
| `BaseType_t` | FreeRTOS port | FreeRTOS API 常用的回傳值或狀態型別，例如 `pdPASS`。 |
| `UBaseType_t` | FreeRTOS port | FreeRTOS API 常用的 unsigned 整數型別，例如 priority、queue length。 |
| `TickType_t` | FreeRTOS port/config | RTOS tick 數值型別，例如 timeout 或 delay。 |

這些型別都不需要 application 自己定義。使用 task 和 queue 時通常 include：

```c
#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"
```

queue 的作用可以理解成 task 之間傳資料用的 FIFO 通道：

```text
Producer task -> Queue -> Consumer task
```

Producer task 用 `xQueueSend()` 把資料放進 queue，consumer task 用 `xQueueReceive()` 從 queue 取資料。queue 不一定只能給兩個 task 使用，也可以多個 producer 送到同一個 queue，或多個 consumer 從同一個 queue 收資料；只是最常見、最容易理解的形式是一個 producer 對一個 consumer。

以遊戲程式為例，可以讓 `input_task` 負責讀按鍵，再把 input event 送進 queue；`game_task` 從 queue 收 input event 後更新遊戲狀態。

```c
typedef struct {
    uint32_t key;
    uint32_t pressed;
} InputEvent_t;

#define INPUT_QUEUE_LENGTH 8u

static StaticQueue_t input_queue_tcb;
static InputEvent_t input_queue_storage[INPUT_QUEUE_LENGTH];
static QueueHandle_t input_queue;

input_queue = xQueueCreateStatic(
    INPUT_QUEUE_LENGTH,
    sizeof(InputEvent_t),
    (uint8_t *)input_queue_storage,
    &input_queue_tcb
);
```

上面這段的意思是：

```text
建立一個 queue。
最多可以存 8 筆資料。
每一筆資料大小是 sizeof(InputEvent_t)。
資料實際存在 input_queue_storage。
queue 的管理資料存在 input_queue_tcb。
建立成功後，input_queue 是之後 send / receive 會使用的 handle。
```

為什麼不用 global variable 直接溝通：

global variable 只是共享一塊記憶體；queue 則是一個有同步能力的資料通道。直接用 global variable 當 task 間資料交換時，常見問題是資料可能被覆蓋、讀寫可能被切換打斷、consumer 需要自己輪詢資料是否可用。

例如用 global variable：

```c
static uint32_t input_key;
static uint32_t input_ready;
```

如果 `input_task` 很快收到兩次輸入：

```text
LEFT
RIGHT
```

但 `game_task` 還沒讀，global variable 可能只留下最後一次 `RIGHT`，前面的 `LEFT` 就不見了。queue 則可以保存多筆事件：

```text
queue: [LEFT][RIGHT]
```

`game_task` 之後可以一筆一筆取出處理。

另一個問題是等待資料。global variable 常見寫法可能變成：

```c
while (input_ready == 0u) {
    /* busy wait，會占住 CPU。 */
}
```

queue 可以讓 consumer 在沒有資料時直接睡眠：

```c
InputEvent_t event;

xQueueReceive(input_queue, &event, portMAX_DELAY);
```

這代表如果 queue 是空的，consumer task 會進入 blocked，不會浪費 CPU；當 producer task 送資料進 queue 後，FreeRTOS 會把等待該 queue 的 task 喚醒成 ready。

queue 和 global variable 的差異可以這樣記：

```text
global variable = 共享狀態，需要自己處理同步、覆蓋、有效性。
queue = task 間傳遞事件 / 資料，並且附帶同步與等待機制。
```

global variable 不是不能用。它適合放系統設定、只讀資料、很少更新的狀態、硬體位址、或由單一 task 擁有的小型狀態。queue 比較適合 input event、UART packet、render command 這種不能隨便漏掉、需要照順序處理的資料。

`uxQueueLength` 和 `uxItemSize` 的關係：

這兩個參數定義 queue 的容量和每筆資料大小。

```text
uxQueueLength = queue 最多可以放幾筆資料。
uxItemSize    = 每一筆資料有多大，單位是 byte。
```

例如：

```c
#define QUEUE_LENGTH 4u

static uint32_t queue_storage[QUEUE_LENGTH];
static StaticQueue_t queue_tcb;

queue = xQueueCreateStatic(
    QUEUE_LENGTH,
    sizeof(uint32_t),
    (uint8_t *)queue_storage,
    &queue_tcb
);
```

這代表：

```text
queue 最多存 4 筆資料。
每筆資料大小是 sizeof(uint32_t)，通常是 4 bytes。
總 storage 至少需要 4 * 4 = 16 bytes。
```

如果傳的是 struct：

```c
typedef struct {
    uint32_t key;
    uint32_t pressed;
} InputEvent_t;

#define INPUT_QUEUE_LENGTH 8u

static InputEvent_t input_queue_storage[INPUT_QUEUE_LENGTH];
static StaticQueue_t input_queue_tcb;
```

建立 queue 時就應該使用：

```c
input_queue = xQueueCreateStatic(
    INPUT_QUEUE_LENGTH,
    sizeof(InputEvent_t),
    (uint8_t *)input_queue_storage,
    &input_queue_tcb
);
```

這代表：

```text
queue 最多存 8 筆 InputEvent_t。
每筆大小是 sizeof(InputEvent_t)。
總 storage 至少需要 8 * sizeof(InputEvent_t) bytes。
```

`pucQueueStorageBuffer` 的作用：

`pucQueueStorageBuffer` 是 queue 真正存資料的記憶體空間。`xQueueSend()` 時，FreeRTOS 會把 producer 給的 item 內容複製到這塊 storage；`xQueueReceive()` 時，FreeRTOS 會從這塊 storage 取出一筆，再複製到 consumer 提供的變數。

資料流可以理解成：

```text
producer local variable
        |
        | xQueueSend() 複製
        v
pucQueueStorageBuffer 指向的 queue storage
        |
        | xQueueReceive() 複製
        v
consumer local variable
```

因為目前使用 `xQueueCreateStatic()`，FreeRTOS 不會自己 malloc queue storage，所以 `pucQueueStorageBuffer` 指向的空間一定要先宣告好大小，而且要長期有效，通常宣告成 `static` 或 global。

正確範例：

```c
#define INPUT_QUEUE_LENGTH 8u

static InputEvent_t input_queue_storage[INPUT_QUEUE_LENGTH];

input_queue = xQueueCreateStatic(
    INPUT_QUEUE_LENGTH,
    sizeof(InputEvent_t),
    (uint8_t *)input_queue_storage,
    &input_queue_tcb
);
```

錯誤範例：

```c
#define INPUT_QUEUE_LENGTH 8u

static InputEvent_t input_queue_storage[4];

input_queue = xQueueCreateStatic(
    INPUT_QUEUE_LENGTH,
    sizeof(InputEvent_t),
    (uint8_t *)input_queue_storage,
    &input_queue_tcb
);
```

上面錯在實際 storage 只有 4 筆空間，卻告訴 FreeRTOS queue 可以存 8 筆，可能造成 queue 寫超出 storage，破壞其他記憶體。

`pucQueueStorageBuffer` 型別是 `uint8_t *`，是因為 FreeRTOS queue 可以存任何型別的資料。kernel 內部把 storage 視為一塊 byte buffer，所以常見寫法是先用實際資料型別宣告陣列，再 cast 成 `(uint8_t *)` 傳入。

`pxQueueBuffer` 的作用：

`pxQueueBuffer` 是 FreeRTOS 管理這條 queue 用的 control block storage，型別是 `StaticQueue_t *`。它不存放 queue item 本身，而是存放 queue 的管理資訊，例如：

```text
queue storage 在哪裡
每筆 item 多大
queue 有幾格
目前有幾筆資料
讀取位置在哪
寫入位置在哪
有哪些 task 正在等資料
有哪些 task 正在等空位
```

因此：

```text
pucQueueStorageBuffer = queue 真正放資料的地方。
pxQueueBuffer         = FreeRTOS 管理 queue 用的資料表。
```

一般情況不需要手動設定 `StaticQueue_t` 的內容：

```c
static StaticQueue_t input_queue_tcb;
static InputEvent_t input_queue_storage[INPUT_QUEUE_LENGTH];

input_queue = xQueueCreateStatic(
    INPUT_QUEUE_LENGTH,
    sizeof(InputEvent_t),
    (uint8_t *)input_queue_storage,
    &input_queue_tcb
);
```

不需要自己寫：

```c
input_queue_tcb.xxx = ...;
```

也通常不需要自己 `memset()`。`xQueueCreateStatic()` 會初始化 `input_queue_tcb`。

`static StaticQueue_t input_queue_tcb;` 是什麼意思：

這是 C 語言的變數宣告。

```c
static StaticQueue_t input_queue_tcb;
```

拆開看：

```text
static          StaticQueue_t      input_queue_tcb
^               ^                  ^
儲存生命週期     變數型別            變數名稱
```

- `static`：這個變數會長期存在，不會因為函式結束就消失。
- `StaticQueue_t`：FreeRTOS 定義的 queue control block 型別。
- `input_queue_tcb`：你替這個變數取的名字。

`StaticQueue_t` 不是多出來的變數，而是型別名稱。就像 `uint32_t counter;` 裡面的 `uint32_t` 是型別，`counter` 是變數名稱。

三個 queue 相關宣告各自用在哪裡：

建立一個 static queue 時，常會看到這三個宣告：

```c
static StaticQueue_t input_queue_tcb;
static InputEvent_t input_queue_storage[INPUT_QUEUE_LENGTH];
static QueueHandle_t input_queue;
```

它們看起來都和 queue 有關，但角色不同：

| 宣告 | 角色 | 實際用在哪裡 |
|---|---|---|
| `static StaticQueue_t input_queue_tcb;` | queue control block storage，給 FreeRTOS 管理 queue 用 | 建立 queue 時傳 `&input_queue_tcb` 給 `xQueueCreateStatic()` |
| `static InputEvent_t input_queue_storage[INPUT_QUEUE_LENGTH];` | queue item storage，真正存放 queue 資料的空間 | 建立 queue 時傳 `(uint8_t *)input_queue_storage` 給 `xQueueCreateStatic()` |
| `static QueueHandle_t input_queue;` | queue handle，建立成功後代表這一條 queue 的操作代號 | `xQueueCreateStatic()` 回傳後存進 `input_queue`，之後 `xQueueSend()` / `xQueueReceive()` 都使用它 |

也就是：

```text
input_queue_storage = queue 裡真正放資料的倉庫。
input_queue_tcb     = FreeRTOS 管理這個 queue 的資料表。
input_queue         = 你的程式之後操作這個 queue 用的 handle。
```

完整使用方式：

```c
input_queue = xQueueCreateStatic(
    INPUT_QUEUE_LENGTH,
    sizeof(InputEvent_t),
    (uint8_t *)input_queue_storage,
    &input_queue_tcb
);

xQueueSend(input_queue, &event, portMAX_DELAY);
xQueueReceive(input_queue, &event, portMAX_DELAY);
```

所以 `input_queue_tcb` 和 `input_queue_storage` 通常只在建立 queue 時交給 FreeRTOS，之後不直接操作；`input_queue` 則是應用程式後續 send / receive 時會一直使用的 handle。

`StaticQueue_t` 是什麼資料型別：

`StaticQueue_t` 是 FreeRTOS 提供的資料型別，用來表示 static allocation 模式下的 queue control block。它不是拿來存 input event 的型別，而是 FreeRTOS kernel 內部管理 queue 需要用的資料結構型別。

```text
StaticQueue_t = FreeRTOS 管理 queue 需要用的 control block 型別。
```

它可能包含 queue storage 位置、item 大小、queue 長度、目前資料筆數、讀寫位置、等待資料的 task list、等待空位的 task list 等資訊。這些欄位是 FreeRTOS 內部使用的，應用程式不應直接讀寫。

真正存 input event 的型別是 `InputEvent_t`：

```c
typedef struct {
    uint32_t key;
    uint32_t pressed;
} InputEvent_t;

static InputEvent_t input_queue_storage[INPUT_QUEUE_LENGTH];
```

`InputEvent_t` 決定每一筆 queue item 的格式；`StaticQueue_t` 則是 FreeRTOS 管理整條 queue 用的控制資料。

`QueueHandle_t input_queue` 用在哪裡：

`QueueHandle_t` 是 FreeRTOS 定義的 queue handle 型別，可以把它理解成 queue 的 ID 或操作代號。

```c
static QueueHandle_t input_queue;
```

建立 queue 後，`xQueueCreateStatic()` 會回傳一個 handle：

```c
input_queue = xQueueCreateStatic(
    INPUT_QUEUE_LENGTH,
    sizeof(InputEvent_t),
    (uint8_t *)input_queue_storage,
    &input_queue_tcb
);
```

之後所有 queue 操作都用這個 handle 指定要操作哪一條 queue：

```c
xQueueSend(input_queue, &event, portMAX_DELAY);
xQueueReceive(input_queue, &event, portMAX_DELAY);
```

如果程式裡有多條 queue，例如 `input_queue` 和 `render_queue`，FreeRTOS 就是靠這個 handle 知道你要送資料到哪一條 queue、或從哪一條 queue 收資料。

`(uint8_t *)input_queue_storage` 的作用：

`(uint8_t *)` 是 C 語言的 type cast，意思是把 `input_queue_storage` 的起始位址轉成 `uint8_t *`，也就是 byte pointer。

因為 `xQueueCreateStatic()` 的第三個參數型別是：

```c
uint8_t *pucQueueStorageBuffer
```

但 `input_queue_storage` 的原始型別是：

```c
InputEvent_t input_queue_storage[INPUT_QUEUE_LENGTH];
```

傳進函式時，它比較像 `InputEvent_t *`。型別不一樣，所以常見寫法會 cast：

```c
(uint8_t *)input_queue_storage
```

FreeRTOS 這樣設計是因為 queue 可以存任何資料型別，例如 `uint32_t`、`InputEvent_t`、`RenderCommand_t`。kernel 不需要知道你的 C struct 長什麼樣，只要知道 storage 起點和每筆資料大小：

```c
input_queue = xQueueCreateStatic(
    INPUT_QUEUE_LENGTH,
    sizeof(InputEvent_t),
    (uint8_t *)input_queue_storage,
    &input_queue_tcb
);
```

FreeRTOS 會把 storage 當成連續 byte buffer，並用 `uxItemSize` 計算每一筆資料的位置：

```text
第 N 筆 item 位址 = storage 起始位址 + N * uxItemSize
```

所以 `(uint8_t *)` 不是在複製資料，也不是改變 storage 大小；它只是把同一塊記憶體用 FreeRTOS 需要的 pointer 型別傳進去。

為什麼 `&input_queue_tcb` 要加 `&`：

`xQueueCreateStatic()` 的第 4 個參數型別是：

```c
StaticQueue_t *pxQueueBuffer
```

也就是它需要「指向 `StaticQueue_t` 的指標」。但我們宣告的是一個 `StaticQueue_t` 物件本身：

```c
static StaticQueue_t input_queue_tcb;
```

所以要用 `&input_queue_tcb` 取出這個物件的位址，交給 FreeRTOS 初始化和使用。

```c
xQueueCreateStatic(
    INPUT_QUEUE_LENGTH,
    sizeof(InputEvent_t),
    (uint8_t *)input_queue_storage,
    &input_queue_tcb
);
```

可以理解成：

```text
input_queue_storage:
    queue item 真正存放的資料區。

&input_queue_tcb:
    把 StaticQueue_t 物件的位置交給 FreeRTOS，
    讓 FreeRTOS 在裡面填入 queue 管理資料。
```

為什麼 `input_queue_storage` 通常不用寫 `&`：

因為陣列名稱在傳進函式時，大多數情況會自動轉成指向第一個元素的指標。也就是：

```c
input_queue_storage
```

大致等同於：

```c
&input_queue_storage[0]
```

所以這裡常寫：

```c
(uint8_t *)input_queue_storage
```

而不是：

```c
&input_queue_storage
```

送資料後接收方是否會立即執行：

當 producer task 呼叫 `xQueueSend()` 放入資料時，如果有 consumer task 正在 `xQueueReceive(queue, ..., portMAX_DELAY)` 等這條 queue，FreeRTOS 會把該 consumer 從 blocked 喚醒成 ready。

但 ready 不等於立刻 running。是否立即執行，要看 scheduler 的 priority 和目前系統狀態。

```text
queue send = 放資料 + 可能喚醒等待資料的 task
喚醒 = blocked -> ready
ready 不等於 running
running 要等 scheduler 選到它
```

如果 consumer priority 比 producer 高，producer 送資料後，scheduler 可能很快甚至立刻切到 consumer。

```c
xTaskCreateStatic(consumer_task, "CON", ..., 3u, ...);
xTaskCreateStatic(producer_task, "PROD", ..., 2u, ...);
```

如果 consumer priority 跟 producer 一樣或比較低，consumer 可能只是變成 ready，等 producer delay、block、或下一次排程時機才執行。

```c
xTaskCreateStatic(consumer_task, "CON", ..., 2u, ...);
xTaskCreateStatic(producer_task, "PROD", ..., 3u, ...);
```

所以如果希望接收方反應快，可以讓 consumer priority 稍高，並讓 consumer 用 `xQueueReceive(..., portMAX_DELAY)` 等資料；producer 送完資料後也應避免長時間占住 CPU。

使用注意事項：

- queue 會複製 item 內容，不是只保存指標。`xQueueSend(queue, &event, ...)` 會把 `event` 的 bytes 複製進 queue storage。
- 如果 queue item 是指標，queue 只會複製指標值，指標指向的資料生命週期要自行管理。
- storage buffer 必須足夠大，且不能是會消失的 local buffer。

#### `xQueueSend()`: 把資料送進 queue

用途：producer task 用它把一筆資料放入 queue，讓其他 task 之後用 `xQueueReceive()` 取出。

常見呼叫形式：

```c
BaseType_t xQueueSend(
    QueueHandle_t xQueue,
    const void * pvItemToQueue,
    TickType_t xTicksToWait
);
```

參數說明：

| 參數            | 要填什麼               | 說明                                                                                    |
| --------------- | ---------------------- | --------------------------------------------------------------------------------------- |
| `xQueue`        | queue handle           | 由 `xQueueCreateStatic()` 回傳。                                                        |
| `pvItemToQueue` | 要送出的資料位址       | 傳入 item 變數的 address，例如 `&value` 或 `&event`。                                   |
| `xTicksToWait`  | queue 滿時最多等待多久 | `0` 表示不等；`pdMS_TO_TICKS(10u)` 表示最多等 10 ms；`portMAX_DELAY` 表示可長時間等待。 |

回傳值：

| 回傳值          | 意義                               |
| --------------- | ---------------------------------- |
| `pdPASS`        | 送入成功。                         |
| `errQUEUE_FULL` | queue 滿了，且等待時間內仍無空間。 |

範例：

```c
AppEvent_t event = {
    .id = 1u,
    .value = xTaskGetTickCount()
};

if (xQueueSend(event_queue, &event, pdMS_TO_TICKS(10u)) != pdPASS) {
    rtos_uart_write_line("[APP] queue send timeout");
}
```

`xQueueSend()` 三個參數和 `xQueueCreateStatic()` 的搭配：

```c
xQueueSend(
    input_queue,
    &event,
    portMAX_DELAY
);
```

三個參數分別代表：

| 參數 | 要填什麼 | 和 `xQueueCreateStatic()` 的關係 |
|---|---|---|
| `input_queue` | 要送到哪一條 queue 的 handle | 這個值來自 `input_queue = xQueueCreateStatic(...)` 的回傳值。 |
| `&event` | 要送進 queue 的資料位址 | `event` 的型別要和建立 queue 時的 `sizeof(InputEvent_t)` 對得起來。 |
| `portMAX_DELAY` | queue 滿時最多等多久 | 等的是 queue 出現空位，不是等 receiver 接收完成。 |

第一個參數不是把整段 `input_queue = xQueueCreateStatic(...)` 填進去，而是填 `xQueueCreateStatic()` 回傳後存在 `input_queue` 變數裡的 handle。

```c
input_queue = xQueueCreateStatic(
    INPUT_QUEUE_LENGTH,
    sizeof(InputEvent_t),
    (uint8_t *)input_queue_storage,
    &input_queue_tcb
);

/* 後面操作同一條 queue 時，都使用 input_queue 這個 handle。 */
xQueueSend(input_queue, &event, portMAX_DELAY);
xQueueReceive(input_queue, &event, portMAX_DELAY);
```

`&event` 的意思是把 `event` 這筆資料的位址交給 FreeRTOS。FreeRTOS 會根據 queue 建立時指定的 `uxItemSize`，從 `&event` 指向的位置複製一整筆資料到 queue storage。

```c
InputEvent_t event;

event.key = KEY_LEFT;
event.pressed = 1u;

xQueueSend(input_queue, &event, portMAX_DELAY);
```

可以理解成：

```text
input_queue          = 要送到哪一條 queue。
&event               = 要送出的資料現在放在哪裡。
sizeof(InputEvent_t) = 要複製多少 bytes，由 xQueueCreateStatic() 的 uxItemSize 決定。
```

不要寫成：

```c
xQueueSend(input_queue, event, portMAX_DELAY);
```

因為 `xQueueSend()` 要的是資料位址，不是資料值本身。

`portMAX_DELAY` 在 `xQueueSend()` 裡的意思：

`portMAX_DELAY` 不是等待 receiver「接收資料完成」的時間。它表示如果 queue 滿了，producer task 願意等到 queue 有空位為止。

```text
xQueueSend()    等的是 queue 有空位。
xQueueReceive() 等的是 queue 有資料。
```

如果 queue 沒滿，`xQueueSend()` 會直接把資料複製進 queue，回傳 `pdPASS`，不會等待。

如果 queue 滿了：

```text
queue: [1][2][3][4][5][6][7][8]
```

producer 呼叫：

```c
xQueueSend(input_queue, &event, portMAX_DELAY);
```

producer task 會進入 blocked，scheduler 會切去執行其他 ready task。等到 consumer 用 `xQueueReceive()` 取走一筆資料，queue 出現空位後，producer 才會被喚醒成 ready，之後 scheduler 排到它時，`xQueueSend()` 才能完成。

如果使用有限等待時間：

```c
xQueueSend(input_queue, &event, pdMS_TO_TICKS(10u));
```

意思是：

```text
queue 沒滿：
    立刻送入成功，回傳 pdPASS。

queue 滿了：
    producer blocked，最多等 10 ms。
    10 ms 內有空位 -> 送入成功，回傳 pdPASS。
    10 ms 到了仍沒有空位 -> 不送入，回傳 errQUEUE_FULL。
```

這不是「資料傳到一半時間到」。queue send 成功時會複製完整一筆 item；失敗時就是沒有放進 queue。

`errQUEUE_FULL` 不會讓 OS 停止：

`xQueueSend()` 回傳 `errQUEUE_FULL` 只表示這次資料沒有成功放進 queue。整個 FreeRTOS 不會因此停止，task 也不會自動壞掉。你要在程式裡決定如何處理。

丟掉這筆 event：

```c
if (xQueueSend(input_queue, &event, 0u) != pdPASS) {
    rtos_uart_write_line("[INPUT] queue full, drop event");
}
```

統計掉資料次數：

```c
static uint32_t dropped_input_count;

if (xQueueSend(input_queue, &event, 0u) != pdPASS) {
    dropped_input_count++;
}
```

短時間重試：

```c
if (xQueueSend(input_queue, &event, pdMS_TO_TICKS(10u)) != pdPASS) {
    rtos_uart_write_line("[INPUT] queue still full");
}
```

不要在高 priority task 裡無限制 busy retry，否則可能長時間占住 CPU。若資料不能丟，可以使用 `portMAX_DELAY`，但要確認系統設計允許 producer 被 block。

event 資料結構可以自己改：

`event` 的型別不是 FreeRTOS 固定的。它通常是你自己定義的 `typedef struct`，用來決定 queue 每一筆資料長什麼樣。

例如 input event：

```c
typedef struct {
    uint32_t key;
    uint32_t pressed;
} InputEvent_t;
```

如果遊戲需要更多資訊，可以改成：

```c
typedef struct {
    uint32_t type;
    uint32_t key;
    uint32_t pressed;
    int32_t x;
    int32_t y;
} InputEvent_t;
```

改 event struct 時，要一起檢查四個地方：

```text
1. typedef struct InputEvent_t 的欄位。
2. queue storage 型別，例如 static InputEvent_t input_queue_storage[...];
3. xQueueCreateStatic() 的 uxItemSize，例如 sizeof(InputEvent_t)。
4. xQueueSend() / xQueueReceive() 使用的變數型別，例如 InputEvent_t event;
```

如果建立 queue 時填的是：

```c
sizeof(InputEvent_t)
```

送資料時就要送 `InputEvent_t`：

```c
InputEvent_t event;
xQueueSend(input_queue, &event, portMAX_DELAY);
```

不要建立 queue 時用 `sizeof(uint32_t)`，卻送 `InputEvent_t`。那樣 queue 只會複製 `sizeof(uint32_t)` 的 bytes，資料會被截斷。

這句話的意思是：`xQueueCreateStatic()` 的 `uxItemSize` 會決定 FreeRTOS 每次 `xQueueSend()` / `xQueueReceive()` 要複製幾個 bytes。建立 queue 時告訴 FreeRTOS 每筆資料有多大，後面送進 queue 的資料型別就要和這個大小一致。

錯誤範例：

```c
typedef struct {
    uint32_t type;
    uint32_t key;
    uint32_t pressed;
} InputEvent_t;

static InputEvent_t input_queue_storage[INPUT_QUEUE_LENGTH];

input_queue = xQueueCreateStatic(
    INPUT_QUEUE_LENGTH,
    sizeof(uint32_t),
    (uint8_t *)input_queue_storage,
    &input_queue_tcb
);

InputEvent_t event = {
    .type = 1u,
    .key = KEY_LEFT,
    .pressed = 1u
};

xQueueSend(input_queue, &event, portMAX_DELAY);
```

上面錯在 queue 建立時使用 `sizeof(uint32_t)`，等於告訴 FreeRTOS 每筆資料只有 4 bytes。但 `InputEvent_t` 有三個 `uint32_t` 欄位，通常是 12 bytes。結果 `xQueueSend()` 只會複製前 4 bytes，可能只保存到 `type`，後面的 `key` 和 `pressed` 沒有被完整放進 queue。

正確範例：

```c
typedef struct {
    uint32_t type;
    uint32_t key;
    uint32_t pressed;
} InputEvent_t;

static InputEvent_t input_queue_storage[INPUT_QUEUE_LENGTH];

input_queue = xQueueCreateStatic(
    INPUT_QUEUE_LENGTH,
    sizeof(InputEvent_t),
    (uint8_t *)input_queue_storage,
    &input_queue_tcb
);

InputEvent_t event = {
    .type = 1u,
    .key = KEY_LEFT,
    .pressed = 1u
};

xQueueSend(input_queue, &event, portMAX_DELAY);
```

要記住這三個地方必須一致：

```text
queue storage 型別      = InputEvent_t[]
queue item size         = sizeof(InputEvent_t)
xQueueSend() 送的變數型別 = InputEvent_t
```

如果只想傳一個 `uint32_t`，那就全部都使用 `uint32_t`：

```c
static uint32_t queue_storage[QUEUE_LENGTH];

queue = xQueueCreateStatic(
    QUEUE_LENGTH,
    sizeof(uint32_t),
    (uint8_t *)queue_storage,
    &queue_tcb
);

uint32_t value = 123u;
xQueueSend(queue, &value, portMAX_DELAY);
```

完整範例：input task 透過 queue 傳 event 給 game task。

```c
#include <stdint.h>
#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"
#include "uart.h"

#define INPUT_QUEUE_LENGTH 8u
#define INPUT_TASK_STACK_WORDS 384u
#define GAME_TASK_STACK_WORDS 512u

#define KEY_LEFT  1u
#define KEY_RIGHT 2u

typedef struct {
    uint32_t type;
    uint32_t key;
    uint32_t pressed;
} InputEvent_t;

static StaticQueue_t input_queue_tcb;
static InputEvent_t input_queue_storage[INPUT_QUEUE_LENGTH];
static QueueHandle_t input_queue;

static StaticTask_t input_task_tcb;
static StackType_t input_task_stack[INPUT_TASK_STACK_WORDS];

static StaticTask_t game_task_tcb;
static StackType_t game_task_stack[GAME_TASK_STACK_WORDS];

static uint32_t read_key_sample(void) {
    static uint32_t toggle;

    toggle ^= 1u;
    return toggle ? KEY_LEFT : KEY_RIGHT;
}

static void handle_input_event(const InputEvent_t *event) {
    rtos_uart_write("[GAME] key=");
    rtos_uart_write_hex32(event->key);
    rtos_uart_write("\n");
}

static void input_task(void *arg) {
    InputEvent_t event;
    (void)arg;

    for (;;) {
        event.type = 1u;
        event.key = read_key_sample();
        event.pressed = 1u;

        if (xQueueSend(input_queue, &event, pdMS_TO_TICKS(10u)) != pdPASS) {
            rtos_uart_write_line("[INPUT] input queue full");
        }

        vTaskDelay(pdMS_TO_TICKS(50u));
    }
}

static void game_task(void *arg) {
    InputEvent_t event;
    (void)arg;

    for (;;) {
        if (xQueueReceive(input_queue, &event, portMAX_DELAY) == pdPASS) {
            handle_input_event(&event);
        }
    }
}

int main(void) {
    input_queue = xQueueCreateStatic(
        INPUT_QUEUE_LENGTH,
        sizeof(InputEvent_t),
        (uint8_t *)input_queue_storage,
        &input_queue_tcb
    );

    if (input_queue == NULL) {
        rtos_uart_write_line("[APP] input queue create failed");
        for (;;) {}
    }

    xTaskCreateStatic(
        input_task,
        "INPUT",
        INPUT_TASK_STACK_WORDS,
        NULL,
        2u,
        input_task_stack,
        &input_task_tcb
    );

    xTaskCreateStatic(
        game_task,
        "GAME",
        GAME_TASK_STACK_WORDS,
        NULL,
        2u,
        game_task_stack,
        &game_task_tcb
    );

    vTaskStartScheduler();

    for (;;) {}
}
```

這個範例的資料流是：

```text
input_task 建立 InputEvent_t event
-> xQueueSend(input_queue, &event, ...)
-> FreeRTOS 複製 event 到 input_queue_storage
-> game_task 在 xQueueReceive(input_queue, &event, ...) 等資料
-> 收到後呼叫 handle_input_event(&event)
```

重點是 `input_task` 和 `game_task` 不需要直接呼叫彼此，也不需要共用一個容易被覆蓋的 global event。queue 會保存事件順序，並在沒有資料時讓 consumer task 睡眠。

使用注意事項：

- `pvItemToQueue` 要傳 item 的位址，不要傳 item 值本身。
- 如果不希望 producer 被 queue 卡住，可使用較短 timeout，例如 `0` 或 `pdMS_TO_TICKS(10u)`。
- 如果資料不能遺失，可使用 `portMAX_DELAY`，但要確認系統設計允許 producer block。

#### `xQueueReceive()`: 從 queue 取出資料

用途：consumer task 用它等待並取出 queue 中的一筆資料。常見於 renderer task 等待 producer event，收到資料後再更新 VGA。

常見呼叫形式：

```c
BaseType_t xQueueReceive(
    QueueHandle_t xQueue,
    void * pvBuffer,
    TickType_t xTicksToWait
);
```

參數說明：

| 參數           | 要填什麼               | 說明                                                                                        |
| -------------- | ---------------------- | ------------------------------------------------------------------------------------------- |
| `xQueue`       | queue handle           | 由 `xQueueCreateStatic()` 回傳。                                                            |
| `pvBuffer`     | 接收資料的 buffer 位址 | 型別和 queue item size 要一致，例如 `&event`。                                              |
| `xTicksToWait` | queue 空時最多等待多久 | `0` 表示不等；`pdMS_TO_TICKS(10u)` 表示最多等 10 ms；`portMAX_DELAY` 表示一直等到收到資料。 |

回傳值：

| 回傳值           | 意義                                 |
| ---------------- | ------------------------------------ |
| `pdPASS`         | 成功收到資料，`pvBuffer` 已被填入。  |
| `errQUEUE_EMPTY` | queue 空，且等待時間內沒有收到資料。 |

範例：

```c
AppEvent_t event;

for (;;) {
    if (xQueueReceive(event_queue, &event, portMAX_DELAY) == pdPASS) {
        handle_event(&event);
    }
}
```

`xQueueReceive()` 三個參數和 `xQueueSend()` 的對照：

```c
xQueueReceive(
    input_queue,
    &event,
    portMAX_DELAY
);
```

三個參數分別代表：

| 參數 | 要填什麼 | 說明 |
|---|---|---|
| `input_queue` | 要從哪一條 queue 收資料 | 這個值來自 `input_queue = xQueueCreateStatic(...)` 的回傳值，和 `xQueueSend()` 使用同一個 queue handle。 |
| `&event` | 接收資料的變數位址 | FreeRTOS 會從 queue 複製一筆資料到 `event`。 |
| `portMAX_DELAY` | queue 空時最多等多久 | 等的是 queue 有資料。 |

第一個參數和 `xQueueSend()` 一樣，都是填 queue handle：

```c
input_queue = xQueueCreateStatic(
    INPUT_QUEUE_LENGTH,
    sizeof(InputEvent_t),
    (uint8_t *)input_queue_storage,
    &input_queue_tcb
);

xQueueSend(input_queue, &event, portMAX_DELAY);
xQueueReceive(input_queue, &event, portMAX_DELAY);
```

第二個參數和 sender 很像，都常寫 `&event`，但資料方向相反：

```text
xQueueSend()    的 &event = 資料來源，FreeRTOS 從 event 複製到 queue。
xQueueReceive() 的 &event = 資料目的地，FreeRTOS 從 queue 複製到 event。
```

第三個參數也是等待時間，但等待條件和 sender 相反：

```text
xQueueSend()    等 queue 有空位，因為 queue 滿了就放不進去。
xQueueReceive() 等 queue 有資料，因為 queue 空了就取不到資料。
```

如果 queue 有資料：

```text
xQueueReceive() 會立刻取出一筆，複製到 pvBuffer，回傳 pdPASS。
```

如果 queue 空了：

```text
xTicksToWait = 0
    不等待，立刻回傳 errQUEUE_EMPTY。

xTicksToWait = pdMS_TO_TICKS(10u)
    consumer blocked，最多等 10 ms。
    10 ms 內有資料 -> 收到，回傳 pdPASS。
    10 ms 到了仍沒有資料 -> 回傳 errQUEUE_EMPTY。

xTicksToWait = portMAX_DELAY
    consumer blocked，一直等到 queue 有資料。
```

`xQueueReceive()` 成功後，該 item 會從 queue 中移除。例如：

```text
queue 原本: [LEFT][RIGHT]

xQueueReceive(...)
    event = LEFT
    queue 剩下: [RIGHT]

xQueueReceive(...)
    event = RIGHT
    queue 變空
```

簡單 sender / receiver 範例：

這個範例用最簡單的 `uint32_t` 當 queue item。sender task 每 100 ms 送一個數字；receiver task 等 queue 有資料後取出並印出。

```c
#define NUMBER_QUEUE_LENGTH 4u

static StaticQueue_t number_queue_tcb;
static uint32_t number_queue_storage[NUMBER_QUEUE_LENGTH];
static QueueHandle_t number_queue;

static StaticTask_t sender_tcb;
static StackType_t sender_stack[384];

static StaticTask_t receiver_tcb;
static StackType_t receiver_stack[384];

static void sender_task(void *arg) {
    uint32_t value = 0u;
    (void)arg;

    for (;;) {
        value++;

        xQueueSend(
            number_queue,
            &value,
            portMAX_DELAY
        );

        vTaskDelay(pdMS_TO_TICKS(100u));
    }
}

static void receiver_task(void *arg) {
    uint32_t received;
    (void)arg;

    for (;;) {
        if (xQueueReceive(
                number_queue,
                &received,
                portMAX_DELAY
            ) == pdPASS) {
            rtos_uart_write("[RX] value=");
            rtos_uart_write_hex32(received);
            rtos_uart_write("\n");
        }
    }
}

int main(void) {
    number_queue = xQueueCreateStatic(
        NUMBER_QUEUE_LENGTH,
        sizeof(uint32_t),
        (uint8_t *)number_queue_storage,
        &number_queue_tcb
    );

    if (number_queue == NULL) {
        rtos_uart_write_line("[APP] number queue create failed");
        for (;;) {}
    }

    xTaskCreateStatic(
        sender_task,
        "SEND",
        384u,
        NULL,
        2u,
        sender_stack,
        &sender_tcb
    );

    xTaskCreateStatic(
        receiver_task,
        "RECV",
        384u,
        NULL,
        2u,
        receiver_stack,
        &receiver_tcb
    );

    vTaskStartScheduler();

    for (;;) {}
}
```

資料流可以這樣看：

```text
sender_task:
    value = 1
    xQueueSend(number_queue, &value, ...)
        -> queue 內放入 1

receiver_task:
    xQueueReceive(number_queue, &received, ...)
        -> 從 queue 取出 1
        -> received = 1

sender_task:
    value = 2
    xQueueSend(...)
        -> queue 內放入 2

receiver_task:
    xQueueReceive(...)
        -> received = 2
```

簡單記：

```text
xQueueSend(queue, &value, ...)
    = 把 value 複製進 queue。

xQueueReceive(queue, &received, ...)
    = 從 queue 拿一筆資料，複製到 received。
```

使用注意事項：

- `xQueueReceive()` 成功後，該 item 會從 queue 中移除。
- 使用 `portMAX_DELAY` 可以讓 consumer 在沒有資料時睡眠，不會浪費 CPU。
- 如果需要週期性做其他事，可使用有限 timeout，timeout 後執行背景工作。

#### `taskENTER_CRITICAL()` / `taskEXIT_CRITICAL()`: 保護不可被插斷的短區段

用途：保護一小段不希望被其他 task 或 interrupt 插斷的程式碼。此專案常用它保護 UART log，避免多個 task 同時輸出造成字串交錯。

常見呼叫形式：

```c
taskENTER_CRITICAL();
/* critical section */
taskEXIT_CRITICAL();
```

參數：無。

回傳值：無。

範例：

```c
taskENTER_CRITICAL();
rtos_uart_write("[APP] tick=");
rtos_uart_write_hex32((uint32_t)xTaskGetTickCount());
rtos_uart_write(" task=worker\n");
taskEXIT_CRITICAL();
```

critical section 可以理解成「這幾行程式必須連續做完，不希望中途被其他 task 或 interrupt 插進來」。進入 critical section 後，FreeRTOS 會暫時保護這段程式；離開後才恢復正常排程 / 中斷處理。

典型用途是保護很短的共享操作，例如 UART log 或小型 shared variable。

UART log 範例：

如果兩個 task 都會印 UART，沒有 critical section 時可能發生輸出交錯。

```c
rtos_uart_write("[A] tick=");
rtos_uart_write_hex32(tick);
rtos_uart_write("\n");
```

可能發生：

```text
task A 印到一半: [A] tick=
scheduler 切到 task B
task B 印:       [B] tick=00000100
切回 task A
task A 繼續印:   00000080
```

UART 最後可能變成：

```text
[A] tick=[B] tick=00000100
00000080
```

加上 critical section 後：

```c
taskENTER_CRITICAL();

rtos_uart_write("[A] tick=");
rtos_uart_write_hex32(tick);
rtos_uart_write("\n");

taskEXIT_CRITICAL();
```

意思是這段 UART 輸出要連續做完，不要讓其他 task 插進來印。

shared variable 範例：

```c
static uint32_t score;
```

如果多個 task 都可能更新：

```c
score = score + 1u;
```

這行在 CPU 裡不一定是一個不可分割動作，可能實際上是：

```text
讀 score
加 1
寫回 score
```

如果兩個 task 同時更新，可能發生其中一次更新被覆蓋。可以用 critical section 保護這幾行：

```c
taskENTER_CRITICAL();
score = score + 1u;
taskEXIT_CRITICAL();
```

critical section 一定要短。不要把長時間工作包進去：

```c
taskENTER_CRITICAL();

while (1) {
    draw_vga();
}

taskEXIT_CRITICAL();
```

也不要在 critical section 裡呼叫可能等待 / block 的 API：

```c
taskENTER_CRITICAL();

vTaskDelay(pdMS_TO_TICKS(100u));
xQueueReceive(queue, &event, portMAX_DELAY);

taskEXIT_CRITICAL();
```

這種寫法是錯的。critical section 期間通常會影響中斷或排程，如果在裡面等待，系統可能卡住，tick 也可能無法正常推進。

可以這樣記：

```text
taskENTER_CRITICAL()
    進入一段不能被打斷的短區域。

taskEXIT_CRITICAL()
    離開這段區域，恢復正常排程 / 中斷。
```

適合放：

```text
短 UART log
更新很小的 shared variable
讀寫共享狀態的幾行程式
```

不適合放：

```text
vTaskDelay()
xQueueReceive(..., portMAX_DELAY)
長時間 while loop
大型繪圖
複雜運算
```

如果是 task 間傳資料，通常優先用 queue，不要用 global variable 加 critical section 硬做。Queue 的同步語意比較清楚，也可以讓沒有資料的 consumer task 進入 blocked，不浪費 CPU。

使用注意事項：

- critical section 要盡量短，只放真正需要保護的幾行。
- 不要在 critical section 裡呼叫可能 block 的 API，例如 `vTaskDelay()`、`xQueueReceive(..., portMAX_DELAY)`。
- 不要把整個繪圖流程或長時間運算包進 critical section，否則會影響 tick interrupt 和整體排程反應。
- 若只是 task 間傳資料，優先用 queue 或 task notification；critical section 適合保護非常短的共享狀態或 log 輸出。

#### Task notification: task 間的輕量事件通知

用途：task notification 是 FreeRTOS 內建在每個 task 裡的輕量同步機制。它不需要額外建立 queue，適合用來做「喚醒某個 task」、「累計事件次數」、「送出簡單 flag」。本專案已啟用 `configUSE_TASK_NOTIFICATIONS = 1`，且 `configTASK_NOTIFICATION_ARRAY_ENTRIES = 1`，表示每個 task 有 1 個 notification slot。

常見 API：

```c
BaseType_t xTaskNotifyGive(TaskHandle_t xTaskToNotify);

uint32_t ulTaskNotifyTake(
    BaseType_t xClearCountOnExit,
    TickType_t xTicksToWait
);

BaseType_t xTaskNotify(
    TaskHandle_t xTaskToNotify,
    uint32_t ulValue,
    eNotifyAction eAction
);

BaseType_t xTaskNotifyWait(
    uint32_t ulBitsToClearOnEntry,
    uint32_t ulBitsToClearOnExit,
    uint32_t *pulNotificationValue,
    TickType_t xTicksToWait
);
```

更完整的相關 API 可以分成幾類：

| 類型 | API | 作用 | 常見用途 |
|---|---|---|---|
| 計數型通知 | `xTaskNotifyGive()` | 對指定 task 的 notification count 加 1 | 喚醒 worker task、事件次數 +1 |
| 計數型等待 | `ulTaskNotifyTake()` | 目前 task 等待 / 取走自己的 notification count | worker task 睡到有人通知 |
| 通用通知 | `xTaskNotify()` | 對指定 task 設定 notification value，動作由 `eNotifyAction` 決定 | 設 bit flag、覆寫 value、累加 count |
| flag / value 等待 | `xTaskNotifyWait()` | 目前 task 等待 notification，並讀出 notification value | 等待 bit flag、讀取簡單 32-bit 狀態 |
| ISR 發通知 | `vTaskNotifyGiveFromISR()` | ISR 版本的 `xTaskNotifyGive()` | interrupt 中喚醒 task |
| ISR 通用通知 | `xTaskNotifyFromISR()` | ISR 版本的 `xTaskNotify()` | interrupt 中設定 flag / value |
| 清除通知狀態 | `xTaskNotifyStateClear()` | 清除指定 task 的 notification pending 狀態 | 較少用，通常用於重置等待狀態 |
| 清除通知 value bit | `ulTaskNotifyValueClear()` | 清掉指定 task notification value 裡的某些 bit | 較少用，通常用於 bit flag 管理 |

最常用的是這兩組：

```text
單純叫某個 task 醒來：
    xTaskNotifyGive()
    ulTaskNotifyTake()

要傳 bit flag 或簡單 value：
    xTaskNotify()
    xTaskNotifyWait()
```

目前本專案 `configTASK_NOTIFICATION_ARRAY_ENTRIES = 1`，代表每個 task 只有 1 個 notification slot，所以建議先使用上面這些「非 indexed」API。FreeRTOS 也有 `xTaskNotifyIndexed()`、`ulTaskNotifyTakeIndexed()`、`xTaskNotifyWaitIndexed()` 這類 indexed API，但它們主要用在每個 task 有多個 notification slot 的情境；目前專案設定下不需要優先使用。

`eNotifyAction` 常見可填值：

`eNotifyAction` 不是 API / 函式。它是 `xTaskNotify()` 和 `xTaskNotifyFromISR()` 的參數型別，用來指定「這次通知要怎麼更新目標 task 的 notification value」。

它要放的位置是：

```c
xTaskNotify(
    worker_handle,  /* 第 1 個參數：通知哪個 task */
    EVENT_RX_READY, /* 第 2 個參數：要帶入的 value / bit mask */
    eSetBits        /* 第 3 個參數：eNotifyAction */
);

xTaskNotifyFromISR(
    worker_handle,           /* 第 1 個參數：通知哪個 task */
    EVENT_RX_READY,          /* 第 2 個參數：要帶入的 value / bit mask */
    eSetBits,                /* 第 3 個參數：eNotifyAction */
    &higher_priority_woken   /* 第 4 個參數：ISR wake flag */
);
```

例如：

```c
xTaskNotify(worker_handle, EVENT_RX_READY, eSetBits);
```

這裡 `xTaskNotify()` 是 API，`eSetBits` 是 `eNotifyAction` 的其中一種值，意思是把 `EVENT_RX_READY` 這個 bit OR 進 worker task 的 notification value。

可以這樣分：

```text
xTaskNotify() = API / 函式。
eNotifyAction = 參數型別 / 動作選項。
eSetBits      = eNotifyAction 的其中一種值。
```

| `eNotifyAction` | 對 notification value 的行為 | `ulValue` 是否使用 | 回傳值 / 注意事項 | 適合情境 |
|---|---|---|---|---|
| `eNoAction` | 只把目標 task 的 notification state 設成 pending，不改 notification value | 不使用，通常填 `0u` | 通常回傳 `pdPASS` | 單純喚醒，但多數情況 `xTaskNotifyGive()` 更直覺 |
| `eSetBits` | 把 `ulValue` 當 bit mask，OR 到 notification value | 使用，填事件 bit mask | 通常回傳 `pdPASS` | 多種事件 flag，例如 RX ready、frame done |
| `eIncrement` | notification value 加 1 | 不使用，通常填 `0u` | 通常回傳 `pdPASS` | 計數型事件，類似 `xTaskNotifyGive()` |
| `eSetValueWithOverwrite` | 直接把 notification value 覆寫成 `ulValue` | 使用，填新的 32-bit value | 即使舊 notification 還沒處理，也會覆寫，通常回傳 `pdPASS` | 只需要最新值，舊值可被覆蓋 |
| `eSetValueWithoutOverwrite` | 只有在目標 task 沒有 pending notification 時，才把 notification value 設成 `ulValue` | 使用，填新的 32-bit value | 如果舊 notification 還 pending，會失敗並回傳 `pdFAIL` | 不想覆蓋尚未處理的 value |

每個 action 的簡短範例：

```c
/* 只喚醒 worker，不改 notification value。 */
xTaskNotify(worker_handle, 0u, eNoAction);

/* 設定事件 bit。worker 可用 xTaskNotifyWait() 讀 flags。 */
xTaskNotify(worker_handle, EVENT_RX_READY, eSetBits);

/* 把 notification value 加 1。 */
xTaskNotify(worker_handle, 0u, eIncrement);

/* 直接寫入最新值，例如最新 ADC sample。 */
xTaskNotify(worker_handle, latest_sample, eSetValueWithOverwrite);

/* 只有 worker 沒有尚未處理的 notification 時才寫入。 */
if (xTaskNotify(worker_handle, command_value, eSetValueWithoutOverwrite) != pdPASS) {
    rtos_uart_write_line("[APP] command notification busy");
}
```

ISR 版本的 action 放法相同，只是 API 多了最後一個 `pxHigherPriorityTaskWoken` 參數：

```c
BaseType_t higher_priority_woken = pdFALSE;

xTaskNotifyFromISR(
    worker_handle,
    EVENT_RX_READY,
    eSetBits,
    &higher_priority_woken
);

portYIELD_FROM_ISR(higher_priority_woken);
```

選擇建議：

```text
只要叫 task 醒來：
    用 xTaskNotifyGive() + ulTaskNotifyTake()

要累計事件次數：
    用 xTaskNotifyGive() + ulTaskNotifyTake(pdFALSE, ...)
    或 xTaskNotify(..., 0, eIncrement)

要傳多個簡單事件 flag：
    用 xTaskNotify(..., EVENT_BIT, eSetBits)
    搭配 xTaskNotifyWait()

要傳一個最新 32-bit 值：
    用 xTaskNotify(..., value, eSetValueWithOverwrite)
    搭配 xTaskNotifyWait()

要傳 struct 或保存多筆資料順序：
    用 queue，不要用 task notification。
```

各 API 參數說明：

`xTaskNotifyGive()`：

```c
BaseType_t xTaskNotifyGive(TaskHandle_t xTaskToNotify);
```

| 參數 | 意義 |
|---|---|
| `xTaskToNotify` | 要通知哪個 task。通常填 `xTaskCreateStatic()` 回傳後存下來的 task handle。 |

範例：

```c
xTaskNotifyGive(worker_handle);
```

意思是通知 `worker_handle` 指向的 task，讓它的 notification count 加 1。如果該 task 正在 `ulTaskNotifyTake()` 等通知，就會被喚醒成 ready。

`ulTaskNotifyTake()`：

```c
uint32_t ulTaskNotifyTake(
    BaseType_t xClearCountOnExit,
    TickType_t xTicksToWait
);
```

| 參數 | 意義 |
|---|---|
| `xClearCountOnExit` | 收到通知後如何處理 count。`pdTRUE` 表示清成 0；`pdFALSE` 表示只減 1。 |
| `xTicksToWait` | 沒有通知時最多等多久。可填 `0`、`pdMS_TO_TICKS(...)`、`portMAX_DELAY`。 |

範例：

```c
ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
```

意思是目前 task 等自己的 notification；如果沒有通知就一直睡，收到後把 notification count 清成 0。`ulTaskNotifyTake()` 沒有 task handle 參數，因為它永遠是「目前 task 等自己的 notification」。

`xTaskNotify()`：

```c
BaseType_t xTaskNotify(
    TaskHandle_t xTaskToNotify,
    uint32_t ulValue,
    eNotifyAction eAction
);
```

| 參數 | 意義 |
|---|---|
| `xTaskToNotify` | 要通知哪個 task。 |
| `ulValue` | 要傳入的 32-bit 值或 bit mask。 |
| `eAction` | 第 3 個參數。要怎麼更新 notification value，例如 `eSetBits`、`eIncrement`、`eSetValueWithOverwrite`。 |

範例：

```c
xTaskNotify(worker_handle, EVENT_RX_READY, eSetBits);
```

意思是通知 worker task，並把 `EVENT_RX_READY` 這個 bit 設進 worker 的 notification value。

`xTaskNotifyWait()`：

```c
BaseType_t xTaskNotifyWait(
    uint32_t ulBitsToClearOnEntry,
    uint32_t ulBitsToClearOnExit,
    uint32_t *pulNotificationValue,
    TickType_t xTicksToWait
);
```

| 參數 | 意義 |
|---|---|
| `ulBitsToClearOnEntry` | 進入等待前要先清掉哪些 bit。通常填 `0u`。 |
| `ulBitsToClearOnExit` | 收到通知並離開時要清掉哪些 bit。常填事件 bit mask。 |
| `pulNotificationValue` | 接收 notification value 的變數位址，例如 `&flags`。 |
| `xTicksToWait` | 沒有通知時最多等多久。 |

範例：

```c
uint32_t flags;

xTaskNotifyWait(
    0u,
    EVENT_RX_READY | EVENT_FRAME_END,
    &flags,
    portMAX_DELAY
);
```

意思是目前 task 等 notification；收到後把 notification value 存到 `flags`，離開時清掉 `EVENT_RX_READY` 和 `EVENT_FRAME_END` 這些 bit。

`vTaskNotifyGiveFromISR()`：

```c
void vTaskNotifyGiveFromISR(
    TaskHandle_t xTaskToNotify,
    BaseType_t *pxHigherPriorityTaskWoken
);
```

| 參數 | 意義 |
|---|---|
| `xTaskToNotify` | ISR 要通知哪個 task。 |
| `pxHigherPriorityTaskWoken` | 用來告訴 FreeRTOS 是否喚醒了更高 priority task。通常傳 `&higher_priority_woken`。 |

範例：

```c
BaseType_t higher_priority_woken = pdFALSE;

vTaskNotifyGiveFromISR(worker_handle, &higher_priority_woken);
portYIELD_FROM_ISR(higher_priority_woken);
```

`xTaskNotifyFromISR()`：

```c
BaseType_t xTaskNotifyFromISR(
    TaskHandle_t xTaskToNotify,
    uint32_t ulValue,
    eNotifyAction eAction,
    BaseType_t *pxHigherPriorityTaskWoken
);
```

| 參數 | 意義 |
|---|---|
| `xTaskToNotify` | ISR 要通知哪個 task。 |
| `ulValue` | 要傳入的 32-bit 值或 bit mask。 |
| `eAction` | 第 3 個參數。notification 更新方式，例如 `eSetBits`、`eIncrement`、`eSetValueWithOverwrite`。 |
| `pxHigherPriorityTaskWoken` | 用來告訴 FreeRTOS 是否喚醒了更高 priority task。 |

範例：

```c
BaseType_t higher_priority_woken = pdFALSE;

xTaskNotifyFromISR(
    worker_handle,
    EVENT_RX_READY,
    eSetBits,
    &higher_priority_woken
);

portYIELD_FROM_ISR(higher_priority_woken);
```

這些 API 的參數不是完全通用，但有幾個概念會重複出現：

```text
xTaskToNotify
    要通知哪個 task。

xTicksToWait
    沒有通知時要等多久。

ulValue
    要傳的 32-bit value 或 bit mask。

eAction
    要怎麼處理 ulValue。

pxHigherPriorityTaskWoken
    ISR 裡用來記錄是否喚醒了更高 priority task。
```

常見參數說明：

| API / 參數          | 要填什麼              | 說明                                                                                                                     |
| ------------------- | --------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `xTaskToNotify`     | 目標 task handle      | 通常是 `xTaskCreateStatic()` 回傳的 handle。                                                                             |
| `xClearCountOnExit` | `pdTRUE` 或 `pdFALSE` | `pdTRUE` 表示 `ulTaskNotifyTake()` 收到後把 count 清成 0；`pdFALSE` 表示只減 1，適合計數型事件。                         |
| `xTicksToWait`      | 等待時間              | 和 queue 一樣，可填 `0`、`pdMS_TO_TICKS(...)` 或 `portMAX_DELAY`。                                                       |
| `ulValue`           | 32-bit 數值           | 用於 `xTaskNotify()` 傳 flag 或數值。                                                                                    |
| `eAction`           | notification 動作     | 常見有 `eSetBits`、`eSetValueWithOverwrite`、`eIncrement`。不同 action 會用不同方式更新目標 task 的 notification value。 |

`xTaskNotifyGive()` 搭配 `ulTaskNotifyTake()` 範例：

```c
static TaskHandle_t worker_handle;

static void worker_task(void *arg) {
    (void)arg;

    for (;;) {
        ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
        rtos_uart_write_line("[APP] worker notified");
    }
}

static void producer_task(void *arg) {
    (void)arg;

    for (;;) {
        xTaskNotifyGive(worker_handle);
        vTaskDelay(pdMS_TO_TICKS(100u));
    }
}
```

`xTaskNotify()` 傳 flag 範例：

```c
#define EVENT_RX_READY  (1u << 0)
#define EVENT_FRAME_END (1u << 1)

xTaskNotify(worker_handle, EVENT_RX_READY, eSetBits);
```

`xTaskNotify()` 搭配 `xTaskNotifyWait()` 等 flag 範例：

```c
#define EVENT_RX_READY  (1u << 0)
#define EVENT_FRAME_END (1u << 1)

static TaskHandle_t worker_handle;

static void worker_task(void *arg) {
    uint32_t flags;
    (void)arg;

    for (;;) {
        if (xTaskNotifyWait(
                0u,
                EVENT_RX_READY | EVENT_FRAME_END,
                &flags,
                portMAX_DELAY
            ) == pdPASS) {
            if ((flags & EVENT_RX_READY) != 0u) {
                handle_rx_ready();
            }

            if ((flags & EVENT_FRAME_END) != 0u) {
                handle_frame_end();
            }
        }
    }
}

static void producer_task(void *arg) {
    (void)arg;

    for (;;) {
        xTaskNotify(worker_handle, EVENT_RX_READY, eSetBits);
        vTaskDelay(pdMS_TO_TICKS(100u));
    }
}
```

`xTaskNotifyWait()` 四個參數的意思：

| 參數 | 說明 |
|---|---|
| `ulBitsToClearOnEntry` | 進入等待前要先清掉哪些 bit。通常填 `0u`，表示不要先清。 |
| `ulBitsToClearOnExit` | 收到 notification 並離開時要清掉哪些 bit。常填事件 bit mask。 |
| `pulNotificationValue` | 用來接收目前 notification value 的變數位址，例如 `&flags`。 |
| `xTicksToWait` | 沒有 notification 時最多等多久，例如 `0`、`pdMS_TO_TICKS(10u)`、`portMAX_DELAY`。 |

ISR 版本範例：

如果是在 interrupt handler 裡通知 task，不能直接使用一般 task 版本，應使用 `FromISR` 版本。

```c
void uart_isr_handler(void) {
    BaseType_t higher_priority_woken = pdFALSE;

    xTaskNotifyFromISR(
        worker_handle,
        EVENT_RX_READY,
        eSetBits,
        &higher_priority_woken
    );

    portYIELD_FROM_ISR(higher_priority_woken);
}
```

或使用計數型通知：

```c
void timer_isr_handler(void) {
    BaseType_t higher_priority_woken = pdFALSE;

    vTaskNotifyGiveFromISR(worker_handle, &higher_priority_woken);

    portYIELD_FROM_ISR(higher_priority_woken);
}
```

ISR 版本多出來的 `higher_priority_woken` 用來告訴 FreeRTOS：這次 interrupt 是否喚醒了更高 priority 的 task。如果有，`portYIELD_FROM_ISR()` 可以讓系統在 ISR 結束後盡快切到那個 task。實際 port 名稱要以本專案 FreeRTOS port 提供的 macro 為準。

使用注意事項：

- task notification 適合傳簡單事件，不適合傳複雜資料。要傳結構化資料時，queue 比較清楚。
- 每個 task 目前只有 1 個 notification slot，所以同一個 task 若同時被多個來源通知，要先定義好 bit mask 或計數規則。
- `ulTaskNotifyTake()` 只等待「目前 task」自己的 notification，不需要傳 task handle。
- 如果需要一筆一筆保存資料，不要用 notification 取代 queue，因為 notification value 只有一個 32-bit 狀態。

目前不建議或尚未啟用：

| 功能             | 狀態   | 原因                                   |
| ---------------- | ------ | -------------------------------------- |
| `xTaskCreate()`  | 不可用 | dynamic allocation 關閉                |
| `pvPortMalloc()` | 不可用 | `configSUPPORT_DYNAMIC_ALLOCATION = 0` |
| Mutex            | 不可用 | `configUSE_MUTEXES = 0`                |
| Software timer   | 不可用 | `configUSE_TIMERS = 0`                 |
| `vTaskDelete()`  | 不可用 | `INCLUDE_vTaskDelete = 0`              |

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

目前可用的 UART helper 定義在：

```text
OS/rtos/src/uart.h
```

API 清單：

| API | 參數 | 作用 |
|---|---|---|
| `rtos_uart_putc(char c)` | `c`：要送出的單一字元 | 送出 1 個字元。 |
| `rtos_uart_write(const char *text)` | `text`：以 `\0` 結尾的 C 字串 | 送出一整串字，不會自動補換行。 |
| `rtos_uart_write_line(const char *text)` | `text`：以 `\0` 結尾的 C 字串 | 送出字串後，自動補一個換行。 |
| `rtos_uart_write_hex32(uint32_t value)` | `value`：要印出的 32-bit 數值 | 用 `0xXXXXXXXX` 格式印出 32-bit hex。 |

這些 helper 目前主要是 UART TX 輸出，用來印 debug log。`rtos_uart_putc()` 會先等 UART TX ready，再把字元寫到 UART MMIO。UART TX MMIO 位址目前在 `uart.c` 裡：

```text
0x40000000  TX data
0x40000004  TX status
```

`rtos_uart_write()` 送字串時，如果遇到 `\n`，會先送 `\r` 再送 `\n`，讓終端機換行顯示比較正常。

各 API 範例：

```c
rtos_uart_putc('A');
```

送出單一字元 `A`。

```c
rtos_uart_write("hello");
```

送出 `hello`，但不會自動換行。

```c
rtos_uart_write_line("hello line");
```

送出 `hello line`，並自動換行。

```c
rtos_uart_write_hex32(0x12345678u);
```

輸出：

```text
0x12345678
```

常見 log 寫法：

```c
rtos_uart_write("[APP] tick=");
rtos_uart_write_hex32((uint32_t)xTaskGetTickCount());
rtos_uart_write(" task=GAME\n");
```

也可以寫成比較短的 boot log：

```c
rtos_uart_write_line("[APP] boot");
rtos_uart_write_line("[APP] scheduler");
```

如果多個 task 都會印 UART，建議用 critical section 包住一整段 log，避免字串被其他 task 插進來打斷。

```c
taskENTER_CRITICAL();

rtos_uart_write("[GAME] frame=");
rtos_uart_write_hex32(frame);
rtos_uart_write(" tick=");
rtos_uart_write_hex32((uint32_t)xTaskGetTickCount());
rtos_uart_write("\n");

taskEXIT_CRITICAL();
```

不要把很長的輸出或大量迴圈都包進 critical section。短 log 可以保護，長時間輸出會影響排程與 interrupt 反應。

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

目前 demo 使用的 VGA helper API：

| API | 參數 | 作用 |
|---|---|---|
| `vga_fb_set_draw_buffer(uint32_t buffer)` | `buffer`：要畫到哪個 framebuffer / draw buffer，目前 demo 常用 `0u` | 選擇後續繪圖要寫入的 buffer。 |
| `vga_fb_clear(uint8_t color)` | `color`：4-bit 顏色，範圍 `0..15` | 把目前 draw buffer 清成指定顏色。 |
| `vga_fb_fill_rect4(uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint8_t color)` | `x, y`：矩形左上角；`w, h`：寬高；`color`：4-bit 顏色 | 在目前 draw buffer 畫一個實心矩形。 |
| `vga_fb_present()` | 無 | 把目前 draw buffer 的畫面送到 VGA 顯示。 |

這組 API 是 framebuffer helper。你不需要直接手算 VGA framebuffer 格式，也不需要直接對 VGA MMIO 寫每個 pixel；一般畫面更新可以透過 clear、fill rect、present 組合完成。

`vga_fb_set_draw_buffer()`：

```c
vga_fb_set_draw_buffer(0u);
```

意思是選擇 buffer 0 當作接下來要畫的目標。demo 目前都使用 `0u`。如果未來有多 buffer / double buffering 設計，這個參數才會更明顯地影響畫到哪一個 buffer。

`vga_fb_clear()`：

```c
vga_fb_clear(0u);
```

意思是把目前 draw buffer 清成 color 0。常用在一開始建立背景，或每一 frame 重新畫面前先清空。

`vga_fb_fill_rect4()`：

```c
vga_fb_fill_rect4(8u, 28u, 32u, 24u, 2u);
```

參數意思是：

```text
x     = 8
y     = 28
w     = 32
h     = 24
color = 2
```

也就是在 `(8, 28)` 的位置畫一個寬 32、高 24、顏色為 2 的矩形。

重要限制是：`x` 和 `w` 必須是 4 的倍數。這是因為目前 framebuffer helper 以 4-pixel group 的格式寫入。如果 `x` 或 `w` 不是 4 的倍數，畫面可能不符合預期。

正確範例：

```c
vga_fb_fill_rect4(8u, 28u, 32u, 24u, 2u);
```

錯誤或不建議：

```c
vga_fb_fill_rect4(7u, 28u, 31u, 24u, 2u);
```

上面錯在 `x = 7` 不是 4 的倍數，`w = 31` 也不是 4 的倍數。

`vga_fb_present()`：

```c
vga_fb_present();
```

意思是把你剛剛畫在 draw buffer 裡的內容顯示到 VGA。通常畫完一批圖形後呼叫一次，不需要每畫一個矩形就 present 一次。

基本畫面範例：

```c
vga_fb_set_draw_buffer(0u);
vga_fb_clear(0u);

vga_fb_fill_rect4(0u, 0u, 160u, 16u, 1u);
vga_fb_fill_rect4(8u, 28u, 32u, 24u, 2u);
vga_fb_fill_rect4(64u, 28u, 32u, 24u, 3u);
vga_fb_fill_rect4(120u, 28u, 32u, 24u, 4u);

vga_fb_present();
```

這段會：

```text
選擇 draw buffer 0。
把背景清成 color 0。
畫一條 160x16 的 header。
畫三個不同顏色的矩形。
最後 present 到 VGA。
```

在 RTOS task 裡週期性更新畫面：

```c
static void render_task(void *arg) {
    uint32_t frame = 0u;
    uint32_t y;
    (void)arg;

    vga_fb_set_draw_buffer(0u);
    vga_fb_clear(0u);
    vga_fb_present();

    for (;;) {
        frame++;
        y = 24u + ((frame % 40u) * 2u);

        vga_fb_clear(0u);
        vga_fb_fill_rect4(8u, y, 32u, 16u, 2u);
        vga_fb_present();

        vTaskDelay(pdMS_TO_TICKS(100u));
    }
}
```

這個 task 會每 100 ms 更新一次矩形位置。`vTaskDelay()` 讓 render task 畫完一 frame 後休眠，把 CPU 交給其他 task。

多 task 同時畫 VGA 的注意事項：

如果多個 task 都會呼叫 VGA API，畫面可能互相覆蓋。例如 task A 清畫面後，還沒 present，task B 又畫了自己的區塊，最後畫面內容可能不是你預期的。比較建議的設計是：

```text
簡單 demo：
    每個 task 只畫自己的固定區塊，避免互相覆蓋。

較完整架構：
    讓一個 render task 專門負責畫 VGA。
    其他 task 透過 queue 傳 render command 或 game state 給 render task。
```

例如：

```text
input_task -> queue -> game_task -> queue -> render_task -> VGA
```

這樣 VGA 更新集中在一個 task，比較容易控制畫面順序，也比較不容易互相覆蓋。

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

| 畫面符號 | 意義                                       |
| -------- | ------------------------------------------ |
| `P`      | Producer task，負責產生 event              |
| `Q`      | FreeRTOS queue，負責暫存 event             |
| `R`      | Renderer task，收到 queue event 後更新 VGA |
| `H`      | Heartbeat task，獨立週期執行               |

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

### 13.4 不要用 busy loop 取代 `vTaskDelay()`

busy loop 會讓 task 長時間佔住 CPU。  
如果你只是想等一段時間，請用：

```c
vTaskDelay(pdMS_TO_TICKS(100u));
```

### 13.5 不要直接手寫 VGA framebuffer 格式

這裡的意思是：不要一開始就自己用 MMIO 指標去算 VGA framebuffer 位址、pixel packing、每個 pixel 要放在哪個 bit。除非你很確定底層 framebuffer layout，否則很容易寫錯。

不建議一開始寫成這種低階形式：

```c
volatile uint32_t *fb = (volatile uint32_t *)0x50000000u;

uint32_t index = y * 40u + (x / 4u);
uint32_t packed_pixels = 0x22222222u;

fb[index] = packed_pixels;
```

上面這種寫法看起來像是在 `(x, y)` 畫 pixel，但其實你必須自己知道很多細節：

```text
framebuffer base address 是多少
一列有幾個 32-bit word
一個 word 裡包幾個 pixel
每個 pixel 是幾 bit
color 要放到哪幾個 bit
x 是否需要對齊 4-pixel group
寫完後是否還需要 present
```

目前 VGA helper 已經把這些細節包起來，所以建議使用：

```c
vga_fb_fill_rect4(...)
vga_fb_present()
```

例如你想在畫面上畫一個矩形，不建議自己算 framebuffer index；建議寫成：

```c
vga_fb_set_draw_buffer(0u);
vga_fb_clear(0u);
vga_fb_fill_rect4(8u, 28u, 32u, 24u, 2u);
vga_fb_present();
```

這段意思是：

```text
選擇 draw buffer 0。
把背景清成 color 0。
在 x=8, y=28 畫一個 32x24 的 color 2 矩形。
把畫好的 buffer 顯示到 VGA。
```

helper 會處理底層 framebuffer 寫入格式。你只需要遵守目前 helper 的限制：

```text
VGA 解析度目前是 160 x 120。
color 是 4-bit，範圍 0..15。
vga_fb_fill_rect4() 的 x 和 w 必須是 4 的倍數。
畫完一批內容後呼叫 vga_fb_present()。
```

錯誤或不建議的例子：

```c
vga_fb_fill_rect4(7u, 28u, 31u, 24u, 2u);
```

原因是 `x = 7` 不是 4 的倍數，`w = 31` 也不是 4 的倍數。這會違反目前 `vga_fb_fill_rect4()` 的對齊限制。

正確例子：

```c
vga_fb_fill_rect4(8u, 28u, 32u, 24u, 2u);
```

這是目前已驗證能在板上正常更新的路徑。等到你真的需要畫單點、字型、sprite 或更複雜圖形時，再考慮在 helper 上方新增更高階的函式，例如：

```c
draw_sprite4(x, y, sprite);
draw_digit4(x, y, value, color);
draw_text4(x, y, "HI", color);
```

這些高階函式內部仍然可以呼叫 `vga_fb_fill_rect4()` 或其他已驗證的 framebuffer helper，而不是每個 application task 都自己直接操作底層 framebuffer。

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
