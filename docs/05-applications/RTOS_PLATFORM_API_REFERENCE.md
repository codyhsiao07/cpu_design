# RTOS與Platform API完整索引

本文件集中列出目前C/FreeRTOS application可以使用的主要public API，以及本專案自行提供的UART、效能計數器、VGA與board-control API。每個參數、pointer方向與回傳值查 [RTOS_PLATFORM_API_PARAMETER_GUIDE.md](RTOS_PLATFORM_API_PARAMETER_GUIDE.md)；若要先理解Queue、Task與Driver為什麼會走不同硬體路徑，讀 [SOFTWARE_HARDWARE_INTERFACE.md](../04-freertos/SOFTWARE_HARDWARE_INTERFACE.md)，較長的物件設計範例則見 [FREERTOS_API_EXAMPLES.md](../04-freertos/FREERTOS_API_EXAMPLES.md)。

## 1. 「CPU可以執行API」的意思

CPU不會辨識`xQueueSend`或`rtos_uart_write`這些C函式名稱。建置時，compiler與linker會把Application、FreeRTOS Kernel、RISC-V Port及Driver合成machine code：

```text
C API call
   -> compiler產生RV32IM/Zicsr指令
   -> linker接到Kernel或Driver實作
   -> CPU執行load/store/branch/CSR/ECALL等指令
```

因此「可使用」必須同時滿足：

1. header提供宣告或macro；
2. `FreeRTOSConfig.h`已啟用相應功能；
3. 實作source有編入firmware；
4. 呼叫環境正確，例如ISR只能使用允許的`FromISR`版本；
5. profile-specific Driver有加入build。

本文件不列FreeRTOS內部函式，例如`xQueueGenericSend()`、`xTaskIncrementTick()`與`vTaskPlaceOnEventList()`；Application應使用它們對外提供的public macro或API。

## 2. 目前平台能力與標記

目前設定來自 [`FreeRTOSConfig.h`](../../OS/rtos/config/FreeRTOSConfig.h)：

設定值的完整用途、單位與修改後驗證流程見 [FREERTOS_CONFIGURATION.md](../04-freertos/FREERTOS_CONFIGURATION.md)。

| 項目 | 目前設定 |
|---|---|
| Kernel | FreeRTOS V11.1.0，FreeRTOS 202406.04 LTS套件 |
| CPU／ABI | RV32IM + Zicsr、ILP32、single-core |
| Scheduler | preemptive + time slicing |
| Tick | 1 kHz，因此一般情況1 tick約1 ms |
| Priority | `0..4`，數字越大priority越高 |
| Allocation | static與dynamic都啟用 |
| FreeRTOS heap | `heap_4`，總大小2 MiB |
| Notifications | 啟用；每個Task有1個notification slot |
| Objects | Queue、mutex、recursive mutex、counting semaphore、Event Group、Stream/Message Buffer、Queue Set、Software Timer |

本文使用三種狀態：

| 狀態 | 意思 |
|---|---|
| 已驗證 | 現有Smoke、Platform、Console、Lua、VGA或board test已執行到此功能 |
| 可使用 | 目前configuration與build包含實作，但新的使用方式仍應自行做application test |
| 不建議／未啟用 | 內部API、目前configuration關閉，或本bare-metal port沒有合理結束目的地 |

「可使用」不代表所有參數組合都已完成實板驗證。

## 3. 先依需求選API

| 需求 | 建議API |
|---|---|
| 建立獨立執行流程 | `xTaskCreateStatic()`／`xTaskCreate()` |
| 相對延遲 | `vTaskDelay()` |
| 固定週期 | `xTaskDelayUntil()` |
| Tasks間傳固定型別資料 | Queue |
| ISR通知一個Task | Task notification或binary semaphore |
| 保護共享resource | Mutex |
| 表示N個可用resource | Counting semaphore |
| 等待多個狀態bits | Event Group |
| 傳連續bytes | Stream Buffer |
| 保留不同長度message邊界 | Message Buffer |
| 等待多個Queue/Semaphore其中之一 | Queue Set |
| 延後短callback | Software Timer |
| 動態配置 | `pvPortMalloc()`／`vPortFree()` |
| UART輸入輸出 | `rtos_uart_*()` |
| CPU效能量測 | `perf_counters_*()` |
| VGA framebuffer | `vga_fb_*()` |
| 回到UART bootloader | `rtos_board_request_image_reload()` |

## 4. 呼叫環境規則

不知道如何判斷caller是在Task或ISR、Application要在哪裡接收中斷資料時，先讀 [ISR_TASK_API_BOUNDARY.md](../04-freertos/ISR_TASK_API_BOUNDARY.md)。

| 呼叫位置 | 可以做什麼 | 不可以做什麼 |
|---|---|---|
| `main()`、scheduler啟動前 | 建立objects/Tasks、UART polling輸出 | 等待Queue、delay、依賴Task切換 |
| 一般Task | 一般API，可使用timeout或`portMAX_DELAY` | 呼叫`FromISR`版本 |
| ISR／trap interrupt dispatch | `...FromISR()`、不可阻塞的MMIO操作 | 一般會block的Task API、mutex、長時間UART列印 |
| Timer callback | 短且不阻塞的工作 | `portMAX_DELAY`、長計算、等待其他object |

典型ISR結尾：

```c
BaseType_t higher_priority_woken = pdFALSE;

vTaskNotifyGiveFromISR(worker_handle, &higher_priority_woken);
portYIELD_FROM_ISR(higher_priority_woken);
```

## 5. Task與Scheduler API

需要：

```c
#include "FreeRTOS.h"
#include "task.h"
```

### 5.1 建立、啟動與刪除

| API | 狀態 | 用途 | 最小例子 |
|---|---|---|---|
| `xTaskCreateStatic()` | 已驗證 | 使用Application提供的TCB與stack建立Task | `h = xTaskCreateStatic(fn, "work", 256, NULL, 2, stack, &tcb);` |
| `xTaskCreate()` | 已驗證 | 從FreeRTOS heap動態配置Task | `xTaskCreate(fn, "work", 256, NULL, 2, &h);` |
| `vTaskStartScheduler()` | 已驗證 | 啟動tick與排程；正常不返回 | `vTaskStartScheduler();` |
| `vTaskDelete()` | 已驗證 | 刪除指定Task；`NULL`代表自己 | `vTaskDelete(NULL);` |

Static stack depth的單位是`StackType_t` word；本RV32平台一個word是4 bytes：

```c
static StaticTask_t worker_tcb;
static StackType_t worker_stack[256]; /* 1024 bytes。 */

static void worker(void *arg)
{
    (void)arg;
    for (;;) {
        /* 一般C函式也在這個Task context內執行。 */
        vTaskDelay(pdMS_TO_TICKS(100));
    }
}
```

### 5.2 時間與週期

| API | 狀態 | 用途 | 例子 |
|---|---|---|---|
| `vTaskDelay()` | 已驗證 | 從現在開始延遲 | `vTaskDelay(pdMS_TO_TICKS(100));` |
| `xTaskDelayUntil()` | 可使用 | 以固定deadline週期喚醒 | `xTaskDelayUntil(&last, pdMS_TO_TICKS(10));` |
| `xTaskGetTickCount()` | 已驗證 | Task讀取目前Kernel tick | `TickType_t now = xTaskGetTickCount();` |
| `xTaskGetTickCountFromISR()` | 可使用 | ISR讀取目前tick | `now = xTaskGetTickCountFromISR();` |

固定週期完整寫法：

```c
TickType_t last = xTaskGetTickCount();

for (;;) {
    sample_inputs();
    (void)xTaskDelayUntil(&last, pdMS_TO_TICKS(10));
}
```

`vTaskDelay(10)`會包含工作時間而產生漂移；`xTaskDelayUntil()`以先前deadline為基準。

### 5.3 Task控制與查詢

| API | 狀態 | 用途／例子 |
|---|---|---|
| `xTaskGetCurrentTaskHandle()` | 可使用 | `TaskHandle_t self = xTaskGetCurrentTaskHandle();` |
| `xTaskGetIdleTaskHandle()` | 可使用 | 取得Idle Task handle供診斷，不應任意控制它 |
| `vTaskSuspend()` | 可使用 | `vTaskSuspend(worker_handle);`；`NULL`代表暫停自己 |
| `vTaskResume()` | 可使用 | 從Task恢復被suspend的Task |
| `xTaskResumeFromISR()` | 可使用 | 從ISR恢復Task；一般事件同步較建議notification |
| `uxTaskPriorityGet()` | 可使用 | `UBaseType_t p = uxTaskPriorityGet(worker_handle);` |
| `vTaskPrioritySet()` | 可使用 | `vTaskPrioritySet(worker_handle, 3);` |
| `eTaskGetState()` | 可使用 | 查詢Running/Ready/Blocked/Suspended/Deleted |
| `xTaskGetSchedulerState()` | 可使用 | 查詢Not started/Running/Suspended |
| `uxTaskGetNumberOfTasks()` | 可使用 | 回傳目前Task數，包含系統Tasks |
| `pcTaskGetName()` | 可使用 | `const char *name = pcTaskGetName(worker_handle);` |
| `taskYIELD()` | 已驗證 | 主動要求scheduler重新選Task；不等於delay |

`vTaskSuspend()`不帶timeout，很容易忘記resume。一般等待事件時，Queue、notification或Semaphore通常比suspend/resume更安全。

### 5.4 診斷與stack

| API | 狀態 | 用途／例子 |
|---|---|---|
| `uxTaskGetStackHighWaterMark()` | 已驗證 | 回傳啟動以來最少剩餘stack words |
| `uxTaskGetStackHighWaterMark2()` | 可使用 | 與上者相同，但回傳`configSTACK_DEPTH_TYPE` |
| `vTaskGetInfo()` | 可使用 | 將單一Task狀態填入`TaskStatus_t` |
| `uxTaskGetSystemState()` | 已驗證 | 取得所有Task狀態與runtime counter snapshot |

```c
UBaseType_t free_words = uxTaskGetStackHighWaterMark(NULL);
if (free_words < 32u) {
    rtos_uart_write_line("STACK_MARGIN_LOW");
}
```

`configUSE_STATS_FORMATTING_FUNCTIONS=0`，所以`vTaskListTasks()`與`vTaskGetRunTimeStatistics()`目前不可直接使用；應以`uxTaskGetSystemState()`取得結構化資料，再自行輸出。

### 5.5 Scheduler lock與critical section

| API | 用途 | 重要限制 |
|---|---|---|
| `vTaskSuspendAll()`／`xTaskResumeAll()` | 暫停scheduler切換 | 不會關閉interrupt；期間不可呼叫會block的API |
| `taskENTER_CRITICAL()`／`taskEXIT_CRITICAL()` | 短暫保護Task與ISR共享狀態 | 會影響interrupt latency，區段必須很短 |
| `taskDISABLE_INTERRUPTS()` | fatal path停用interrupt | 不適合一般互斥；正常程式應恢復interrupt |

```c
taskENTER_CRITICAL();
shared_flags |= 1u;
taskEXIT_CRITICAL();
```

## 6. Queue API

需要：

```c
#include "FreeRTOS.h"
#include "queue.h"
```

### 6.1 建立與基本傳輸

| API | 狀態 | 用途／例子 |
|---|---|---|
| `xQueueCreateStatic()` | 已驗證 | 使用Application storage建立Queue |
| `xQueueCreate()` | 已驗證 | 從heap建立Queue：`q = xQueueCreate(8, sizeof(Item_t));` |
| `xQueueSend()`／`xQueueSendToBack()` | 已驗證 | 將item副本送到尾端 |
| `xQueueSendToFront()` | 可使用 | 將緊急item副本送到前端 |
| `xQueueReceive()` | 已驗證 | 取出並移除item |
| `xQueuePeek()` | 可使用 | 讀取最前面item但不移除 |
| `xQueueOverwrite()` | 可使用 | 覆寫length=1 Queue的最新值 |
| `xQueueReset()` | 可使用 | 清空Queue；使用前先設計與等待Tasks的關係 |
| `vQueueDelete()` | 可使用 | 刪除dynamic或不再使用的Queue object |

```c
typedef struct Work {
    uint32_t command;
    uint32_t value;
} Work_t;

Work_t tx = { 1u, 42u };
Work_t rx;

if (xQueueSend(work_queue, &tx, pdMS_TO_TICKS(10)) == pdPASS) {
    (void)xQueueReceive(work_queue, &rx, portMAX_DELAY);
}
```

Queue複製`sizeof(Work_t)`bytes；若item是pointer，只複製pointer，指向資料的生命週期仍由Application負責。

### 6.2 查詢與ISR版本

| API | 狀態 | 用途／例子 |
|---|---|---|
| `uxQueueMessagesWaiting()` | 可使用 | 查詢目前item數 |
| `uxQueueSpacesAvailable()` | 可使用 | 查詢剩餘slots |
| `xQueueSendFromISR()` | 已驗證 | ISR送到Queue尾端 |
| `xQueueSendToFrontFromISR()` | 可使用 | ISR送到前端 |
| `xQueueOverwriteFromISR()` | 可使用 | ISR覆寫length=1 Queue |
| `xQueueReceiveFromISR()` | 可使用 | ISR取出item；通常ISR應只送事件給Task |
| `xQueuePeekFromISR()` | 可使用 | ISR查看但不移除 |
| `uxQueueMessagesWaitingFromISR()` | 可使用 | ISR查詢item數 |

所有`FromISR`操作的timeout固定為0，因為ISR不能Blocked。

### 6.3 Queue registry與Queue Set

| API | 狀態 | 用途 |
|---|---|---|
| `vQueueAddToRegistry()` | 可使用 | 為最多16個Queue/Semaphore登記診斷名稱 |
| `vQueueUnregisterQueue()` | 可使用 | 取消登記 |
| `pcQueueGetName()` | 可使用 | 取得已登記名稱 |
| `xQueueCreateSet()` | 已驗證 | 建立可等待多個Queue/Semaphore的集合 |
| `xQueueAddToSet()`／`xQueueRemoveFromSet()` | 已驗證 | 加入或移除member |
| `xQueueSelectFromSet()` | 已驗證 | 等待任一member ready |
| `xQueueSelectFromSetFromISR()` | 可使用 | ISR無阻塞選取ready member |

```c
QueueSetMemberHandle_t ready = xQueueSelectFromSet(input_set, portMAX_DELAY);
if (ready == (QueueSetMemberHandle_t)command_queue) {
    (void)xQueueReceive(command_queue, &command, 0);
} else if (ready == (QueueSetMemberHandle_t)event_sem) {
    (void)xSemaphoreTake(event_sem, 0);
}
```

Queue Set容量至少要等於所有member Queue長度與Semaphore最大count的總和。

## 7. Semaphore與Mutex API

需要：

```c
#include "FreeRTOS.h"
#include "semphr.h"
```

### 7.1 可建立的object

| API | 狀態 | 語意 |
|---|---|---|
| `xSemaphoreCreateBinary()`／`Static()` | 可使用 | 0/1事件；建立後初始為empty |
| `xSemaphoreCreateCounting()`／`Static()` | 已驗證 | `0..max`資源或事件數量 |
| `xSemaphoreCreateMutex()`／`Static()` | 已驗證 | 單一owner，具有priority inheritance |
| `xSemaphoreCreateRecursiveMutex()`／`Static()` | 已驗證 | 同一Task可重複取得的mutex |

### 7.2 取得、釋放與查詢

| API | 狀態 | 用途／限制 |
|---|---|---|
| `xSemaphoreTake()` | 已驗證 | Task取得semaphore或mutex，可block |
| `xSemaphoreGive()` | 已驗證 | Task釋放；mutex必須由owner釋放 |
| `xSemaphoreTakeRecursive()`／`GiveRecursive()` | 已驗證 | 只用於recursive mutex，take/give次數要配對 |
| `xSemaphoreGiveFromISR()` | 可使用 | ISR釋放binary/counting semaphore；不可用於mutex |
| `xSemaphoreTakeFromISR()` | 可使用 | ISR取得binary/counting semaphore，通常較少需要 |
| `uxSemaphoreGetCount()`／`FromISR()` | 可使用 | 查詢目前count |
| `vSemaphoreDelete()` | 可使用 | 刪除不再使用的object |

```c
if (xSemaphoreTake(uart_mutex, pdMS_TO_TICKS(20)) == pdTRUE) {
    rtos_uart_write_line("protected output");
    (void)xSemaphoreGive(uart_mutex);
}
```

`xSemaphoreGetMutexHolder()`目前未啟用。若Application需要追蹤owner，應先評估是否真的是設計問題，再決定是否打開`INCLUDE_xSemaphoreGetMutexHolder`。

## 8. Task Notification API

Task notification是每個Task內建的32-bit通知欄位，適合一對一事件、計數或bits；它不會排隊保存多筆struct。本專案每個Task只有index 0，所以一般使用非Indexed版本。

| API | 狀態 | 用途 |
|---|---|---|
| `xTaskNotify()` | 可使用 | 依`eNotifyAction`設定value、bits或累加 |
| `xTaskNotifyFromISR()` | 可使用 | ISR版本 |
| `xTaskNotifyWait()` | 可使用 | 等待通知並取得32-bit value |
| `xTaskNotifyGive()` | 可使用 | 將通知count加1 |
| `vTaskNotifyGiveFromISR()` | 可使用 | ISR將通知count加1 |
| `ulTaskNotifyTake()` | 可使用 | 等待並清零或減1 |
| `xTaskNotifyAndQuery()`／`FromISR()` | 可使用 | 送通知並取得舊value |
| `xTaskNotifyStateClear()` | 可使用 | 清除pending狀態 |
| `ulTaskNotifyValueClear()` | 可使用 | 清除指定value bits |

```c
/* ISR：通知有一筆工作。 */
vTaskNotifyGiveFromISR(worker_handle, &higher_priority_woken);

/* Task：等待並一次取得累積次數。 */
uint32_t count = ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
```

`xTaskNotify()`常用action：

| Action | 效果 |
|---|---|
| `eNoAction` | 只改pending狀態，不改value |
| `eSetBits` | OR入事件bits |
| `eIncrement` | value加1 |
| `eSetValueWithOverwrite` | 直接覆寫value |
| `eSetValueWithoutOverwrite` | 尚未處理的value存在時回傳失敗 |

## 9. Event Group API

需要`event_groups.h`。Event Group適合表示多個狀態條件，不保存事件發生次數。

| API | 狀態 | 用途／例子 |
|---|---|---|
| `xEventGroupCreate()`／`Static()` | 已驗證 | 建立bit集合 |
| `xEventGroupSetBits()` | 已驗證 | `xEventGroupSetBits(events, RX_READY);` |
| `xEventGroupClearBits()` | 已驗證 | 清除指定bits |
| `xEventGroupGetBits()` | 可使用 | 讀取目前bits |
| `xEventGroupWaitBits()` | 已驗證 | 等待任一或全部bits，可選擇返回時清除 |
| `xEventGroupSync()` | 可使用 | 多個Tasks barrier同步 |
| `xEventGroupSetBitsFromISR()`／`ClearBitsFromISR()` | 可使用 | ISR請Timer Task延後修改bits |
| `xEventGroupGetBitsFromISR()` | 可使用 | ISR直接讀取bits |
| `vEventGroupDelete()` | 可使用 | 刪除object |

```c
EventBits_t bits = xEventGroupWaitBits(
    events,
    RX_READY | CONFIG_READY,
    pdTRUE,                 /* 返回時清除。 */
    pdTRUE,                 /* 必須兩個bit都成立。 */
    pdMS_TO_TICKS(1000)
);
```

Event Group的ISR set/clear會使用Timer command queue；queue滿時API可能回`pdFAIL`，必須檢查。

## 10. Stream Buffer API

需要`stream_buffer.h`。適合單一writer與單一reader傳連續bytes，例如UART RX。

| API | 狀態 | 用途 |
|---|---|---|
| `xStreamBufferCreate()`／`Static()` | 已驗證 | 建立byte stream與trigger level |
| `xStreamBufferSend()`／`FromISR()` | 已驗證 | 寫入bytes，回傳實際寫入數量 |
| `xStreamBufferReceive()`／`FromISR()` | 已驗證 | 讀取bytes，回傳實際讀取數量 |
| `xStreamBufferBytesAvailable()` | 可使用 | 可讀bytes |
| `xStreamBufferSpacesAvailable()` | 可使用 | 可寫空間 |
| `xStreamBufferIsEmpty()`／`IsFull()` | 可使用 | 狀態查詢 |
| `xStreamBufferSetTriggerLevel()` | 可使用 | 修改喚醒reader的trigger level |
| `xStreamBufferReset()`／`ResetFromISR()` | 可使用 | 清空；不可在其他Tasks正等待時任意reset |
| `vStreamBufferDelete()` | 可使用 | 刪除object |

```c
uint8_t data[16];
size_t received = xStreamBufferReceive(rx_stream, data, sizeof(data), portMAX_DELAY);
```

FreeRTOS Stream Buffer會保留一個byte，因此傳入256-byte storage時，實際payload capacity通常是255 bytes。多writer或多reader時需在外層加鎖；更常見的做法是維持single owner。

## 11. Message Buffer API

需要`message_buffer.h`。Message Buffer建立在Stream Buffer實作上，但會保留每一筆message邊界。

| API | 狀態 | 用途 |
|---|---|---|
| `xMessageBufferCreate()`／`Static()` | 可使用 | 建立變長message buffer |
| `xMessageBufferSend()`／`FromISR()` | 可使用 | 送一整筆message，成功回傳message bytes |
| `xMessageBufferReceive()`／`FromISR()` | 可使用 | 一次收一筆完整message |
| `xMessageBufferNextLengthBytes()` | 可使用 | 查詢下一筆message長度 |
| `xMessageBufferSpaceAvailable()` | 可使用 | 查詢剩餘空間 |
| `xMessageBufferIsEmpty()`／`IsFull()` | 可使用 | 查詢狀態 |
| `xMessageBufferReset()`／`ResetFromISR()` | 可使用 | 清空buffer |

```c
const char request[] = "status";
char response[32];

(void)xMessageBufferSend(messages, request, sizeof(request), pdMS_TO_TICKS(10));
size_t n = xMessageBufferReceive(messages, response, sizeof(response), portMAX_DELAY);
```

接收buffer若小於下一筆完整message，該message不會被部分取出。每筆message另需length header空間；它不適合極大量固定大小items，固定大小資料通常用Queue更直接。

## 12. Software Timer API

需要`timers.h`。Callback在共用Timer Task執行，不是硬體interrupt，也不是每個Timer各有一個Task。

| API | 狀態 | 用途 |
|---|---|---|
| `xTimerCreate()`／`Static()` | 已驗證 | 建立one-shot或auto-reload timer |
| `xTimerStart()`／`StartFromISR()` | 已驗證 | 啟動timer |
| `xTimerStop()`／`StopFromISR()` | 可使用 | 停止timer |
| `xTimerReset()`／`ResetFromISR()` | 可使用 | 從現在重新開始計時 |
| `xTimerChangePeriod()`／`FromISR()` | 可使用 | 修改period並重新計時 |
| `xTimerDelete()` | 可使用 | 將刪除命令送到Timer Task |
| `xTimerIsTimerActive()` | 可使用 | 查詢active狀態 |
| `pvTimerGetTimerID()`／`vTimerSetTimerID()` | 可使用 | 讓callback取得Application context |
| `pcTimerGetName()` | 可使用 | 取得timer名稱 |
| `xTimerGetPeriod()`／`xTimerGetExpiryTime()` | 可使用 | 查詢period／預計到期tick |
| `vTimerSetReloadMode()`／`xTimerGetReloadMode()` | 可使用 | runtime切換one-shot/auto-reload |
| `xTimerPendFunctionCall()`／`FromISR()` | 可使用 | 要求Timer Task稍後執行短函式 |

```c
static void heartbeat_callback(TimerHandle_t timer)
{
    uint32_t *count = (uint32_t *)pvTimerGetTimerID(timer);
    (*count)++;
}

heartbeat = xTimerCreate(
    "beat",
    pdMS_TO_TICKS(1000),
    pdTRUE,
    &heartbeat_count,
    heartbeat_callback
);
(void)xTimerStart(heartbeat, 0);
```

Start/stop/reset/change/delete通常只是把command送入長度8的Timer queue，因此要檢查`pdPASS`。Callback不可呼叫會長時間block的API。

## 13. Heap與mini C runtime

需要`FreeRTOS.h`；heap查詢宣告來自portable layer。

| API | 狀態 | 用途 |
|---|---|---|
| `pvPortMalloc()` | 已驗證 | 從2 MiB `heap_4`配置aligned block |
| `pvPortCalloc()` | 可使用 | 配置`count * size` bytes並清零 |
| `vPortFree()` | 已驗證 | 釋放block；`heap_4`會合併相鄰free blocks |
| `xPortGetFreeHeapSize()` | 已驗證 | 目前總free bytes |
| `xPortGetMinimumEverFreeHeapSize()` | 已驗證 | 啟動後最低free bytes |
| `vPortGetHeapStats()` | 可使用 | 取得最大free block、free blocks數量等資料 |

```c
uint32_t *values = pvPortMalloc(64u * sizeof(*values));
if (values != NULL) {
    /* 使用values。 */
    vPortFree(values);
}
```

所有RTOS profile也編入 [`minilibc.c`](../../OS/rtos/src/minilibc.c)，提供`memset`、`memcpy`、`memmove`、`memcmp`、`strlen`，以及以FreeRTOS heap實作的`malloc/free/calloc/realloc`。這不是完整glibc/newlib，沒有filesystem、process、socket或一般host OS服務。

## 14. UART Platform API

需要 [`uart.h`](../../OS/rtos/src/uart.h)；`uart.c`由RTOS build自動加入。

| API | 狀態 | 用途／例子 |
|---|---|---|
| `rtos_uart_putc()` | 已驗證 | polling送一個byte |
| `rtos_uart_write()` | 已驗證 | 送出NUL結尾字串，不自動換行 |
| `rtos_uart_write_line()` | 已驗證 | 送字串後加換行 |
| `rtos_uart_write_u32()`／`u64()` | 已驗證 | 以十進位輸出unsigned數值 |
| `rtos_uart_write_hex32()` | 已驗證 | 以8位hex輸出32-bit數值 |
| `rtos_uart_wait_tx_idle()` | 已驗證 | 等硬體完成最後byte，reload前需要 |
| `rtos_uart_rx_interrupt_init()` | 已驗證 | 建立RX StreamBuffer並開啟machine external interrupt |
| `rtos_uart_try_getc()` | 已驗證 | non-blocking取一個byte |
| `rtos_uart_getc()` | 已驗證 | 等待一個byte或timeout |
| `rtos_uart_rx_interrupt_count()` | 已驗證 | 累計RX interrupt數 |
| `rtos_uart_rx_hardware_overrun_count()` | 已驗證 | 硬體holding register來不及讀的次數 |
| `rtos_uart_rx_stream_drop_count()` | 已驗證 | ISR無法寫進software StreamBuffer的次數 |

```c
char ch;
uint32_t overrun;

if (rtos_uart_getc(&ch, pdMS_TO_TICKS(1000), &overrun) != 0) {
    rtos_uart_putc(ch);
}
```

`rtos_uart_handle_external_interrupt()`是project trap dispatch呼叫的Driver內部入口；`rtos_uart_trigger_test_interrupt()`是Platform測試用途。一般Application不應直接呼叫兩者。

目前UART TX是polling，沒有一般用途的多byte TX software queue；多Task輸出時應以Mutex保護完整訊息，避免文字互相穿插。

## 15. Performance Counter API

需要 [`perf_counters.h`](../../OS/rtos/src/perf_counters.h)；實作由RTOS build自動加入。

| API | 狀態 | 用途 |
|---|---|---|
| `perf_counters_available()` | 已驗證 | 檢查MMIO ID/ABI是否存在 |
| `perf_counters_info()` | 已驗證 | 讀取counter count與ABI資訊 |
| `perf_counters_status()` | 已驗證 | 讀取running/snapshot等狀態 |
| `perf_counters_reset_start()` | 已驗證 | 歸零後開始計數 |
| `perf_counters_reset_stop()` | 已驗證 | 歸零並保持停止 |
| `perf_counters_start()`／`stop()` | 已驗證 | 不清零地開始／停止 |
| `perf_counters_snapshot()` | 已驗證 | 原子取得24組64-bit shadow counters |
| `perf_counter_name()` | 已驗證 | index轉成固定名稱 |
| `perf_counters_per_mille()` | 已驗證 | 安全計算`numerator/denominator * 1000` |

```c
PerfCounterSnapshot_t before;
PerfCounterSnapshot_t after;

perf_counters_reset_start();
(void)perf_counters_snapshot(&before, 0);
run_workload();
(void)perf_counters_snapshot(&after, 1);

uint64_t cycles = after.value[PERF_CYCLES] - before.value[PERF_CYCLES];
```

Counter每cycle由RTL直接累加，不會為每次`+1`產生CPU store。只有control與snapshot讀取會經MMIO。24個counter的定義見 [PERFORMANCE_COUNTER_REGISTERS.md](../02-memory-io/PERFORMANCE_COUNTER_REGISTERS.md)。

## 16. VGA Framebuffer API

需要 [`vga_fb.h`](../../game/vga_fb.h)，並把 [`vga_fb.c`](../../game/vga_fb.c)加入profile或`-ExtraSource`。它不是所有custom RTOS build的common source。

| API | 狀態 | 用途 |
|---|---|---|
| `vga_fb_clear()` | 已驗證 | 以4-bit palette index清除draw buffer |
| `vga_fb_put_pixel()` | 已驗證 | 寫一個160x120 logical pixel |
| `vga_fb_fill_rect4()` | 已驗證 | 填滿矩形區域 |
| `vga_fb_set_draw_buffer()` | 已驗證 | 指定CPU繪圖bank 0/1 |
| `vga_fb_present()` | 已驗證 | 要求下個frame切換front buffer |
| `vga_fb_present_sync()` | 已驗證 | 要求切換並等待ack |
| `vga_fb_swap_draw_buffer()` | 已驗證 | draw bank切到另一bank |
| `vga_fb_draw_buffer_index()` | 已驗證 | 查詢目前draw bank |
| `vga_fb_display_buffer_index()` | 已驗證 | 查詢目前display bank |

```c
vga_fb_set_draw_buffer(1u);
vga_fb_clear(1u);
vga_fb_fill_rect4(10u, 10u, 40u, 20u, 14u);
(void)vga_fb_present_sync();
vga_fb_swap_draw_buffer();
```

多個Tasks不可同時無保護地畫同一buffer；建議只讓Renderer Task擁有VGA API，其他Tasks以Queue送draw command。

## 17. Board-control API

需要 [`board_control.h`](../../OS/rtos/src/board_control.h)，且custom profile必須加入`OS/rtos/src/board_control.c`。

| API | 狀態 | 用途 |
|---|---|---|
| `rtos_board_request_image_reload()` | 已驗證 | 等待UART idle後觸發reload，函式不返回 |
| `rtos_board_disable_external_interrupts()` | 已驗證 | 關閉board machine-external interrupt來源；屬低階控制 |

```c
rtos_uart_write_line("RELOADING");
rtos_board_request_image_reload(); /* 後面的程式不會執行。 */
```

一般Application不要用第二個API代替critical section；它是reload與低階故障處理使用的板級操作。

## 18. Lua可見的`rtos` API

這些API只存在於`lua` profile，供UART上傳的Lua script呼叫；它們不是C header，也不讓Lua任意建立FreeRTOS Task。

| Lua API | 狀態 | 用途／例子 |
|---|---|---|
| `rtos.platform` | 已驗證 | 平台識別字串 |
| `rtos.tick()` | 已驗證 | 目前FreeRTOS tick |
| `rtos.heap_free()`／`heap_min()` | 已驗證 | heap診斷 |
| `rtos.tasks()` | 已驗證 | Task數量 |
| `rtos.heartbeat()` | 已驗證 | Lua firmware heartbeat |
| `rtos.irq_count()` | 已驗證 | UART RX interrupt count |
| `rtos.sleep(ms)` | 已驗證 | block Lua Task 0..60000 ms |
| `rtos.read_line(timeout_ms)` | 已驗證 | 等使用者輸入一行 |
| `rtos.ping()` | 已驗證 | UART輸出PONG並回傳tick |
| `rtos.status()` | 已驗證 | 輸出一行平台狀態 |
| `rtos.reload()` | 已驗證 | 回到bootloader，不返回 |

```lua
print(rtos.platform)
print("tick", rtos.tick())
rtos.sleep(1000)
rtos.status()
```

詳細限制與腳本範例見 [LUA_APP_EXAMPLES.md](LUA_APP_EXAMPLES.md)。

## 19. 目前未啟用或不應由Application呼叫

| API／功能 | 現況 | 原因 |
|---|---|---|
| Co-routine API | 未啟用 | `configUSE_CO_ROUTINES=0`；不要與Lua coroutine混淆 |
| SMP／core affinity APIs | 未啟用 | CPU與Kernel設定皆為single-core |
| MPU restricted Task APIs | 不適用 | 目前Port沒有Application MPU隔離架構 |
| `xTaskAbortDelay()` | 未啟用 | `INCLUDE_xTaskAbortDelay=0` |
| `xTaskGetHandle(name)` | 未啟用 | `INCLUDE_xTaskGetHandle=0`；建立時保存handle |
| `xSemaphoreGetMutexHolder()` | 未啟用 | `INCLUDE_xSemaphoreGetMutexHolder=0` |
| `vTaskListTasks()`／`vTaskGetRunTimeStatistics()` | 未啟用 | formatting functions關閉；用`uxTaskGetSystemState()` |
| Idle／Tick／Daemon startup hooks | 關閉 | 相應`configUSE_*_HOOK=0` |
| `vTaskEndScheduler()` | 不建議 | Bare-metal FPGA沒有可返回的host OS；通常reload image |
| `vPortDefineHeapRegions()` | 不適用 | 這是`heap_5`模式；本專案使用`heap_4` |
| FreeRTOS內部generic/list API | 不應直接使用 | 不是穩定Application介面，Kernel內部自行呼叫 |
| UART external interrupt handler | 不應直接使用 | 已由project trap dispatch統一管理 |

若修改`FreeRTOSConfig.h`開啟新API，必須重新build、補simulation與Platform實板測試，並同步更新此表。

## 20. Build時哪些API會自動加入

`build_rtos_app.ps1`的custom application會自動加入：

```text
FreeRTOS tasks/queue/event_groups/stream_buffer/timers/list
heap_4
RISC-V port.c / portASM.S
uart.c
perf_counters.c
freertos_hooks.c
rtos_heap.c
minilibc.c
startup.S
```

所以使用一般FreeRTOS、UART與performance-counter API不需將Kernel source逐一放進`-ExtraSource`。

需要額外加入：

| 功能 | 額外source |
|---|---|
| Reload／board control | `OS/rtos/src/board_control.c` |
| VGA framebuffer | `game/vga_fb.c` |
| 自己的library | 每個含實作的`.c`或`.S` |
| Lua VM | 使用內建`-App lua` profile，不要手動漏列數十個sources |

建立自己的Application與額外`.c/.h`的完整命令見 [ADDING_NEW_RTOS_APP.md](ADDING_NEW_RTOS_APP.md)。

## 21. 使用前檢查表

1. 確認API屬於Task、ISR或Timer callback版本。
2. Include `FreeRTOS.h`後，再include需要的FreeRTOS object header。
3. 檢查create／send／take／timer command的回傳值。
4. 為所有blocking call設定合理timeout與timeout政策。
5. 不在critical section、scheduler suspended期間或Timer callback內blocking。
6. Static object的TCB、stack、storage生命週期必須覆蓋整個object使用期間。
7. Queue傳pointer時定義buffer ownership與釋放者。
8. ISR使用`FromISR` API並在最後處理`higher_priority_woken`。
9. Profile-specific Driver確認已加入build。
10. 新用法先跑simulation或Platform test，再做長時間實板測試。

## 22. 相關文件

- [RTOS_PLATFORM_API_PARAMETER_GUIDE.md](RTOS_PLATFORM_API_PARAMETER_GUIDE.md)：逐項參數、pointer方向、timeout單位與回傳值。
- [FREERTOS_API_EXAMPLES.md](../04-freertos/FREERTOS_API_EXAMPLES.md)：較完整的C程式骨架。
- [RTOS_APPLICATION_API_GUIDE.md](RTOS_APPLICATION_API_GUIDE.md)：依資料語意選擇object。
- [SOFTWARE_HARDWARE_INTERFACE.md](../04-freertos/SOFTWARE_HARDWARE_INTERFACE.md)：API如何變成DDR、CSR、MMIO與interrupt動作。
- [HEAP_AND_STACK.md](../04-freertos/HEAP_AND_STACK.md)：記憶體配置與stack量測。
- [ADDING_NEW_RTOS_APP.md](ADDING_NEW_RTOS_APP.md)：將Application及額外sources建置、上板。
- [PLATFORM_APP.md](PLATFORM_APP.md)：目前綜合API實板測試內容。
