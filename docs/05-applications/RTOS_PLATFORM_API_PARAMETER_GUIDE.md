# RTOS與Platform API參數指南

本文件回答「知道API名稱之後，每個參數到底要填什麼」。API是否已驗證、可使用或目前關閉，先查 [RTOS_PLATFORM_API_REFERENCE.md](RTOS_PLATFORM_API_REFERENCE.md)；較完整的Application資料流範例見 [FREERTOS_API_EXAMPLES.md](../04-freertos/FREERTOS_API_EXAMPLES.md)。

本文逐項覆蓋API總表中列出的Application-facing API；參數完全相同的aliases會放在同一節說明，無參數函式也會明確標示。FreeRTOS內部generic/list函式與少用的Kernel storage-introspection入口不是穩定的Application設計介面，不列為一般Application參數參考。

## 1. 先學會看C函式宣告

以Queue接收為例：

```c
BaseType_t xQueueReceive(
    QueueHandle_t xQueue,
    void *pvBuffer,
    TickType_t xTicksToWait
);
```

可拆成：

```text
BaseType_t          回傳型別
xQueueReceive       函式名稱
xQueue              第1個參數：Queue handle
pvBuffer            第2個參數：接收資料要寫到哪個地址
xTicksToWait        第3個參數：最多等待多少tick
```

呼叫：

```c
Work_t item;
BaseType_t result;

result = xQueueReceive(work_queue, &item, pdMS_TO_TICKS(100));
```

其中`&item`是output pointer：函式會將收到的資料寫進`item`。

## 2. 共通型別、常數與命名

### 2.1 常用型別

| 型別 | 本平台意思 |
|---|---|
| `BaseType_t` | signed基礎整數，常用於成功／失敗或布林結果 |
| `UBaseType_t` | unsigned基礎整數，常用於數量、priority、index |
| `TickType_t` | 32-bit Kernel tick值 |
| `StackType_t` | Task stack單位；RV32上一個element為4 bytes |
| `TaskHandle_t` | Task object handle，不是Task資料的副本 |
| `QueueHandle_t` | Queue object handle |
| `SemaphoreHandle_t` | Semaphore／Mutex handle |
| `EventGroupHandle_t` | Event Group handle |
| `StreamBufferHandle_t` | Stream／Message Buffer handle |
| `TimerHandle_t` | Software Timer handle |

Handle是Kernel object的識別值。建立失敗時通常得到`NULL`；建立成功後應保存handle，不要自行修改handle指向的內部資料。

### 2.2 常用回傳值

| 值 | 常見意思 |
|---|---|
| `pdPASS`／`pdTRUE` | 成功或條件成立；目前值通常都是1 |
| `pdFAIL`／`pdFALSE` | 失敗或條件不成立；目前值通常都是0 |
| `errQUEUE_FULL` | timeout內無法送入Queue |
| `errQUEUE_EMPTY` | timeout內無法從Queue取出 |
| `NULL` | object建立失敗，或查詢沒有結果 |

不要只假設「非零一定成功」後忽略語意；先看該API定義的回傳方式。

### 2.3 Timeout參數

FreeRTOS的timeout通常是`TickType_t`，不是毫秒：

```c
pdMS_TO_TICKS(250)  /* 將250 ms轉成tick。 */
```

目前tick rate為1 kHz，所以一般情況1 tick約1 ms，但仍建議使用macro。

| timeout | 意義 |
|---:|---|
| `0` | 不等待，立刻成功或失敗 |
| `pdMS_TO_TICKS(100)` | 最多等待約100 ms |
| `portMAX_DELAY` | 在目前設定下無限等待，直到事件發生 |

`FromISR` API沒有timeout，因為ISR不能Blocked。

### 2.4 `NULL`在不同位置的意思

| 寫法 | 意義 |
|---|---|
| `vTaskDelete(NULL)` | 刪除目前Task |
| `uxTaskPriorityGet(NULL)` | 查目前Task priority |
| `xTaskGetCurrentTaskHandle()` | 直接取得目前Task handle |
| `rtos_uart_getc(&ch, 10, NULL)` | 不需要overrun輸出 |
| `xTaskCreate(..., NULL, ..., &handle)` | 傳給Task的`pvParameters`為空 |

`NULL`是否允許由每個API決定，不能任意把必要output pointer設為`NULL`。

## 3. Task建立、啟動與刪除

需要：

```c
#include "FreeRTOS.h"
#include "task.h"
```

### 3.1 `xTaskCreateStatic()`

```c
TaskHandle_t xTaskCreateStatic(
    TaskFunction_t pxTaskCode,
    const char *pcName,
    configSTACK_DEPTH_TYPE uxStackDepth,
    void *pvParameters,
    UBaseType_t uxPriority,
    StackType_t *puxStackBuffer,
    StaticTask_t *pxTaskBuffer
);
```

| 參數 | 要填什麼 |
|---|---|
| `pxTaskCode` | Task入口函式，型態必須是`void function(void *arg)` |
| `pcName` | 診斷名稱；目前最多保留`configMAX_TASK_NAME_LEN=12`字元含結尾NUL |
| `uxStackDepth` | stack element數，不是bytes；RV32上`256`代表1024 bytes |
| `pvParameters` | 傳給Task入口的pointer；不用時填`NULL` |
| `uxPriority` | `0..4`；數字越大越優先，超出範圍會觸發assert或被限制 |
| `puxStackBuffer` | Application提供的`StackType_t`陣列 |
| `pxTaskBuffer` | Application提供的`StaticTask_t`控制區 |

回傳`TaskHandle_t`；失敗回`NULL`。兩個storage都必須在Task整個生命週期內存在，因此通常宣告為`static`或global。

```c
static StaticTask_t worker_tcb;
static StackType_t worker_stack[256];

worker_handle = xTaskCreateStatic(
    worker_task,
    "worker",
    256,
    NULL,
    2,
    worker_stack,
    &worker_tcb
);
```

### 3.2 `xTaskCreate()`

```c
BaseType_t xTaskCreate(
    TaskFunction_t pxTaskCode,
    const char *pcName,
    configSTACK_DEPTH_TYPE uxStackDepth,
    void *pvParameters,
    UBaseType_t uxPriority,
    TaskHandle_t *pxCreatedTask
);
```

前五個參數和static版本相同；`pxCreatedTask`是output pointer，成功時寫入新Task handle。不需要保存handle時可填`NULL`。TCB與stack從FreeRTOS heap配置。

回傳`pdPASS`或`errCOULD_NOT_ALLOCATE_REQUIRED_MEMORY`。

### 3.3 Task入口的`pvParameters`

```c
typedef struct WorkerConfig {
    QueueHandle_t queue;
    uint32_t period_ms;
} WorkerConfig_t;

static WorkerConfig_t config;

static void worker_task(void *arg)
{
    WorkerConfig_t *cfg = (WorkerConfig_t *)arg;
    vTaskDelay(pdMS_TO_TICKS(cfg->period_ms));
}
```

傳入pointer不會複製整份資料；`config`必須在Task使用期間仍有效。不要傳入`main()`即將離開的local variable地址。

### 3.4 啟動與刪除

| API | 參數 | 回傳／注意事項 |
|---|---|---|
| `vTaskStartScheduler()` | 無 | 正常不返回；啟動Idle/Timer Task、tick與第一個Application Task |
| `vTaskDelete(xTask)` | `xTask`為要刪除的handle；`NULL`代表自己 | 無；dynamic Task資源由Idle Task稍後回收，static storage仍由Application擁有 |

## 4. Task時間、控制與查詢

### 4.1 Delay

```c
void vTaskDelay(TickType_t xTicksToDelay);
```

`xTicksToDelay`是從現在開始Blocked的tick數。填0沒有實際delay效果；若目的是讓同priority Task執行，可明確使用`taskYIELD()`。

```c
BaseType_t xTaskDelayUntil(
    TickType_t *pxPreviousWakeTime,
    TickType_t xTimeIncrement
);
```

| 參數 | 意義 |
|---|---|
| `pxPreviousWakeTime` | caller保存的上一個deadline；第一次先設為`xTaskGetTickCount()` |
| `xTimeIncrement` | 固定週期tick數，不是下一個絕對tick |

回傳`pdTRUE`表示有實際delay，`pdFALSE`通常表示deadline已經錯過。

### 4.2 Tick查詢

| API | 參數 | 回傳 |
|---|---|---|
| `xTaskGetTickCount()` | 無；Task使用 | 目前`TickType_t` tick |
| `xTaskGetTickCountFromISR()` | 無；ISR使用 | 目前tick |

32-bit tick會自然wrap；比較deadline時不要假設tick永遠增加而不溢位，優先使用FreeRTOS提供的delay機制。

### 4.3 Suspend、Resume與Priority

| API | 參數 | 回傳／注意事項 |
|---|---|---|
| `vTaskSuspend(xTask)` | Task handle；`NULL`代表自己 | 無；沒有timeout |
| `vTaskResume(xTask)` | 被suspend的Task handle | 無；只從Task呼叫 |
| `xTaskResumeFromISR(xTask)` | 被suspend的Task handle | 回傳是否可能需要context switch |
| `uxTaskPriorityGet(xTask)` | handle；`NULL`代表目前Task | 目前priority `0..4` |
| `vTaskPrioritySet(xTask, uxNewPriority)` | handle／`NULL`與新priority | 無；提高priority可能立刻引發切換 |

### 4.4 Handle、名稱與狀態

| API | 參數 | 回傳 |
|---|---|---|
| `xTaskGetCurrentTaskHandle()` | 無 | caller Task handle |
| `xTaskGetIdleTaskHandle()` | 無 | Idle Task handle，只供診斷 |
| `pcTaskGetName(xTask)` | handle；`NULL`可表示目前Task | 指向Task內部名稱字串的pointer |
| `eTaskGetState(xTask)` | 目標Task handle，不應為`NULL` | `eRunning/eReady/eBlocked/eSuspended/eDeleted`等 |
| `xTaskGetSchedulerState()` | 無 | `taskSCHEDULER_NOT_STARTED/RUNNING/SUSPENDED` |
| `uxTaskGetNumberOfTasks()` | 無 | Task總數，包含Idle與Timer Task |

### 4.5 Stack與runtime診斷

```c
UBaseType_t uxTaskGetStackHighWaterMark(TaskHandle_t xTask);
configSTACK_DEPTH_TYPE uxTaskGetStackHighWaterMark2(TaskHandle_t xTask);
```

`xTask`填`NULL`查目前Task，或填目標handle。回傳啟動以來「最少剩餘stack elements」；RV32需乘4才是bytes。回傳0代表margin已耗盡或非常危險。

```c
void vTaskGetInfo(
    TaskHandle_t xTask,
    TaskStatus_t *pxTaskStatus,
    BaseType_t xGetFreeStackSpace,
    eTaskState eState
);
```

| 參數 | 意義 |
|---|---|
| `xTask` | 目標Task handle；依FreeRTOS語意`NULL`可查目前Task |
| `pxTaskStatus` | 必要output pointer，由caller提供`TaskStatus_t` |
| `xGetFreeStackSpace` | `pdTRUE`時計算stack high-water mark，較耗時；`pdFALSE`略過 |
| `eState` | 已知狀態可直接傳入；不知道時傳`eInvalid`讓Kernel查詢 |

```c
UBaseType_t uxTaskGetSystemState(
    TaskStatus_t *pxTaskStatusArray,
    UBaseType_t uxArraySize,
    configRUN_TIME_COUNTER_TYPE *pulTotalRunTime
);
```

| 參數 | 意義 |
|---|---|
| `pxTaskStatusArray` | caller提供的`TaskStatus_t`陣列 |
| `uxArraySize` | 陣列可容納的elements，不是bytes；至少要等於目前Task數 |
| `pulTotalRunTime` | optional output；需要總runtime counter時給地址，不需要可填`NULL` |

回傳實際填入的Task數；陣列太小時可能回0，因此先以`uxTaskGetNumberOfTasks()`估算並保留margin。

### 4.6 Scheduler與critical section

| API／macro | 參數 | 回傳／配對規則 |
|---|---|---|
| `taskYIELD()` | 無 | 無；要求重新排程 |
| `vTaskSuspendAll()` | 無 | 無；可nest |
| `xTaskResumeAll()` | 無 | 回傳是否已發生／需要yield；每次suspend都要配一次resume |
| `taskENTER_CRITICAL()` | 無 | 無；每次enter都要配一次exit |
| `taskEXIT_CRITICAL()` | 無 | 無 |
| `taskDISABLE_INTERRUPTS()` | 無 | 無；只適合fatal／極低階路徑 |

Scheduler suspended期間interrupt仍能發生，但不可呼叫會讓Task Blocked的API。Critical section則會影響interrupt latency，必須保持很短。

## 5. Queue參數

### 5.1 建立Queue

```c
QueueHandle_t xQueueCreate(
    UBaseType_t uxQueueLength,
    UBaseType_t uxItemSize
);
```

| 參數 | 意義 |
|---|---|
| `uxQueueLength` | Queue最多保存幾個items |
| `uxItemSize` | 每個item複製的bytes，通常填`sizeof(Item_t)` |

```c
QueueHandle_t xQueueCreateStatic(
    UBaseType_t uxQueueLength,
    UBaseType_t uxItemSize,
    uint8_t *pucQueueStorageBuffer,
    StaticQueue_t *pxQueueBuffer
);
```

Static版本另需：

| 參數 | 意義 |
|---|---|
| `pucQueueStorageBuffer` | 至少`length * item_size` bytes的storage，可由typed array cast成`uint8_t *` |
| `pxQueueBuffer` | `StaticQueue_t`控制區 |

兩種建立API成功回handle、失敗回`NULL`。

### 5.2 Send、Receive、Peek與Overwrite

```c
BaseType_t xQueueSend(
    QueueHandle_t xQueue,
    const void *pvItemToQueue,
    TickType_t xTicksToWait
);
```

`xQueueSendToBack()`參數相同；`xQueueSendToFront()`也相同，只差放入位置。

| 參數 | 意義 |
|---|---|
| `xQueue` | 目標Queue handle |
| `pvItemToQueue` | 要複製的item地址；Kernel複製建立時設定的`uxItemSize` bytes |
| `xTicksToWait` | Queue滿時最多等待多久 |

回傳`pdPASS`或`errQUEUE_FULL`。

```c
BaseType_t xQueueReceive(
    QueueHandle_t xQueue,
    void *pvBuffer,
    TickType_t xTicksToWait
);
```

`xQueuePeek()`參數相同，但成功後不移除item。

| 參數 | 意義 |
|---|---|
| `xQueue` | 來源Queue handle |
| `pvBuffer` | 必須能容納一個完整item的output buffer |
| `xTicksToWait` | Queue空時最多等待多久 |

回傳`pdPASS`或`errQUEUE_EMPTY`。

```c
BaseType_t xQueueOverwrite(QueueHandle_t xQueue, const void *pvItemToQueue);
```

只能用於length=1的Queue；沒有timeout，直接保存最新值。

```c
BaseType_t xQueueReset(QueueHandle_t xQueue);
void vQueueDelete(QueueHandle_t xQueue);
```

兩者只有Queue handle參數。Reset清空內容；Delete使handle失效，之後不可再使用。

### 5.3 Queue查詢

| API | 參數 | 回傳 |
|---|---|---|
| `uxQueueMessagesWaiting(xQueue)` | Queue handle | 目前item數 |
| `uxQueueSpacesAvailable(xQueue)` | Queue handle | 剩餘slots |
| `uxQueueMessagesWaitingFromISR(xQueue)` | Queue handle | ISR安全的目前item數 |

### 5.4 Queue的ISR版本

```c
BaseType_t xQueueSendFromISR(
    QueueHandle_t xQueue,
    const void *pvItemToQueue,
    BaseType_t *pxHigherPriorityTaskWoken
);
```

`xQueueSendToFrontFromISR()`、`xQueueOverwriteFromISR()`參數相同。

```c
BaseType_t xQueueReceiveFromISR(
    QueueHandle_t xQueue,
    void *pvBuffer,
    BaseType_t *pxHigherPriorityTaskWoken
);
```

`xQueuePeekFromISR(xQueue, pvBuffer)`只有Queue handle與output buffer兩個參數；它不移除item，也不需要`pxHigherPriorityTaskWoken`，因為peek不會釋放Queue空間或喚醒等待送入的Task。

`pxHigherPriorityTaskWoken`指向caller宣告的`BaseType_t`：

```c
BaseType_t woken = pdFALSE;
xQueueSendFromISR(queue, &item, &woken);
portYIELD_FROM_ISR(woken);
```

### 5.5 Queue Registry

| API | 參數 | 回傳／注意事項 |
|---|---|---|
| `vQueueAddToRegistry(xQueue, pcName)` | Queue/Semaphore handle、長期有效的NUL字串 | 無；只保存名稱pointer，最多16筆 |
| `vQueueUnregisterQueue(xQueue)` | 已登記handle | 無 |
| `pcQueueGetName(xQueue)` | handle | 名稱pointer；未登記時為`NULL` |

### 5.6 Queue Set

| API | 參數 | 回傳 |
|---|---|---|
| `xQueueCreateSet(uxEventQueueLength)` | Set可排隊的ready事件容量 | handle或`NULL` |
| `xQueueAddToSet(xMember, xSet)` | Queue/Semaphore member與Set handle | `pdPASS/pdFAIL` |
| `xQueueRemoveFromSet(xMember, xSet)` | member與Set；member不可正處於ready狀態 | `pdPASS/pdFAIL` |
| `xQueueSelectFromSet(xSet, xTicksToWait)` | Set與timeout | ready member handle或`NULL` |
| `xQueueSelectFromSetFromISR(xSet)` | Set handle | ready member或`NULL` |

`uxEventQueueLength`至少要容納所有member Queue長度與Semaphore最大count總和。

## 6. Semaphore與Mutex參數

### 6.1 建立

| API | 參數 | 回傳 |
|---|---|---|
| `xSemaphoreCreateBinary()` | 無 | handle或`NULL`；初始為empty |
| `xSemaphoreCreateBinaryStatic(pxBuffer)` | `StaticSemaphore_t`地址 | handle或`NULL` |
| `xSemaphoreCreateMutex()` | 無 | handle或`NULL`；建立後可立即take |
| `xSemaphoreCreateMutexStatic(pxBuffer)` | static控制區地址 | handle或`NULL` |
| `xSemaphoreCreateRecursiveMutex()` | 無 | recursive mutex handle或`NULL` |
| `xSemaphoreCreateRecursiveMutexStatic(pxBuffer)` | static控制區地址 | handle或`NULL` |
| `xSemaphoreCreateCounting(uxMaxCount, uxInitialCount)` | 最大count、初始count且`initial <= max` | handle或`NULL` |
| `xSemaphoreCreateCountingStatic(max, initial, pxBuffer)` | 另加static控制區 | handle或`NULL` |

### 6.2 Take、Give與刪除

```c
BaseType_t xSemaphoreTake(
    SemaphoreHandle_t xSemaphore,
    TickType_t xTicksToWait
);
```

`xSemaphore`可為binary/counting semaphore或普通mutex；`xTicksToWait`是資源不可用時的等待上限。成功回`pdTRUE`，timeout回`pdFALSE`。

```c
BaseType_t xSemaphoreGive(SemaphoreHandle_t xSemaphore);
```

成功回`pdTRUE`。Mutex必須由目前owner Task give；binary/counting semaphore達最大count時give會失敗。

Recursive版本：

```c
xSemaphoreTakeRecursive(xMutex, xTicksToWait);
xSemaphoreGiveRecursive(xMutex);
```

只可使用recursive mutex handle；同一Task成功take幾次就必須give幾次。

```c
void vSemaphoreDelete(SemaphoreHandle_t xSemaphore);
```

刪除後handle失效；不可讓其他Task仍在使用或等待它。

### 6.3 ISR版本與count

```c
BaseType_t xSemaphoreGiveFromISR(
    SemaphoreHandle_t xSemaphore,
    BaseType_t *pxHigherPriorityTaskWoken
);
```

```c
BaseType_t xSemaphoreTakeFromISR(
    SemaphoreHandle_t xSemaphore,
    BaseType_t *pxHigherPriorityTaskWoken
);
```

第一參數只能是binary/counting semaphore，不可為Mutex；第二參數與Queue ISR模式相同。

| API | 參數 | 回傳 |
|---|---|---|
| `uxSemaphoreGetCount(xSemaphore)` | semaphore handle | 目前count；mutex語意不建議依賴此查詢 |
| `uxSemaphoreGetCountFromISR(xSemaphore)` | semaphore handle | ISR安全的count |

## 7. Task Notification參數

目前每個Task只有一個notification slot，因此使用非Indexed版本；Indexed版本若使用，index只能為0。

### 7.1 送出value、bits或事件

```c
BaseType_t xTaskNotify(
    TaskHandle_t xTaskToNotify,
    uint32_t ulValue,
    eNotifyAction eAction
);
```

| 參數 | 意義 |
|---|---|
| `xTaskToNotify` | 接收Task handle |
| `ulValue` | 32-bit通知值；如何使用由`eAction`決定 |
| `eAction` | `eNoAction/eSetBits/eIncrement/eSetValueWithOverwrite/eSetValueWithoutOverwrite` |

`eSetValueWithoutOverwrite`遇到尚未處理的通知時回`pdFAIL`；其他一般成功回`pdPASS`。

```c
BaseType_t xTaskNotifyAndQuery(
    TaskHandle_t xTaskToNotify,
    uint32_t ulValue,
    eNotifyAction eAction,
    uint32_t *pulPreviousNotifyValue
);
```

前三個參數相同；`pulPreviousNotifyValue`是output pointer，取得更新前的value。

### 7.2 等待通知bits/value

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
| `ulBitsToClearOnEntry` | 進入等待前先從目前notification value清除的bits |
| `ulBitsToClearOnExit` | 成功收到後、返回前要清除的bits |
| `pulNotificationValue` | optional output；取得清除exit bits之前的value，不需要可填`NULL` |
| `xTicksToWait` | 尚無pending notification時等待多久 |

收到通知回`pdTRUE`，timeout回`pdFALSE`。

### 7.3 Counting-semaphore式通知

| API | 參數 | 回傳 |
|---|---|---|
| `xTaskNotifyGive(xTask)` | 接收Task handle | `pdPASS` |
| `ulTaskNotifyTake(xClearCountOnExit, xTicksToWait)` | 是否一次清零count、timeout | 返回take前的count；timeout為0 |

`xClearCountOnExit=pdTRUE`會一次清成0；`pdFALSE`只減1。

### 7.4 ISR版本

```c
xTaskNotifyFromISR(
    xTaskToNotify,
    ulValue,
    eAction,
    pxHigherPriorityTaskWoken
);
```

前三個參數與Task版本相同，最後一個是yield output pointer。

```c
vTaskNotifyGiveFromISR(xTaskToNotify, pxHigherPriorityTaskWoken);
```

只做count加1；函式本身為`void`。

`xTaskNotifyAndQueryFromISR()`另有`pulPreviousNotificationValue` output，位置在woken pointer之前。

### 7.5 清除notification狀態

| API | 參數 | 回傳 |
|---|---|---|
| `xTaskNotifyStateClear(xTask)` | handle；`NULL`代表目前Task | 先前是否處於notification-received狀態 |
| `ulTaskNotifyValueClear(xTask, ulBitsToClear)` | handle／`NULL`與要清除的bit mask | 清除前的notification value |

## 8. Event Group參數

### 8.1 建立、Set、Clear與Get

| API | 參數 | 回傳 |
|---|---|---|
| `xEventGroupCreate()` | 無 | dynamic handle或`NULL` |
| `xEventGroupCreateStatic(pxBuffer)` | `StaticEventGroup_t`地址 | handle或`NULL` |
| `xEventGroupSetBits(xGroup, uxBitsToSet)` | group handle、要OR入的bit mask | 呼叫完成時的event bits snapshot |
| `xEventGroupClearBits(xGroup, uxBitsToClear)` | group handle、要清除的mask | 清除前的bits |
| `xEventGroupGetBits(xGroup)` | group handle | 目前bits snapshot |
| `vEventGroupDelete(xGroup)` | group handle | 無 |

Event bits不是計數器；同一bit連續set兩次仍只是1。

目前使用32-bit TickType，Event Group最高8 bits保留給Kernel control，因此Application只應使用bit 0..23，例如`1u << 0`到`1u << 23`，不要把`0xFF000000`範圍當Application事件。

### 8.2 等待bits

```c
EventBits_t xEventGroupWaitBits(
    EventGroupHandle_t xEventGroup,
    EventBits_t uxBitsToWaitFor,
    BaseType_t xClearOnExit,
    BaseType_t xWaitForAllBits,
    TickType_t xTicksToWait
);
```

| 參數 | 意義 |
|---|---|
| `xEventGroup` | 目標Event Group handle |
| `uxBitsToWaitFor` | 要等待的bit mask |
| `xClearOnExit` | `pdTRUE`時條件成立後自動清除所等待bits |
| `xWaitForAllBits` | `pdTRUE`等全部bits；`pdFALSE`任一bit即可 |
| `xTicksToWait` | 條件未成立時等待多久 |

回傳值是醒來或timeout時觀察到的bits。Caller要以mask重新判斷條件，不要只用回傳值是否非0判定成功。

```c
if ((bits & REQUIRED_BITS) == REQUIRED_BITS) {
    /* 全部條件成立。 */
}
```

### 8.3 Barrier同步

```c
EventBits_t xEventGroupSync(
    EventGroupHandle_t xEventGroup,
    EventBits_t uxBitsToSet,
    EventBits_t uxBitsToWaitFor,
    TickType_t xTicksToWait
);
```

目前Task先set代表自己的bits，再等待`uxBitsToWaitFor`全部成立。回傳所觀察到的bits。

### 8.4 ISR版本

```c
xEventGroupSetBitsFromISR(xGroup, uxBitsToSet, pxHigherPriorityTaskWoken);
xEventGroupClearBitsFromISR(xGroup, uxBitsToClear);
xEventGroupGetBitsFromISR(xGroup);
```

Set的第三參數是yield output pointer；Clear沒有這個參數。Set/Clear會把工作排入Timer command queue，回`pdPASS`只代表成功排隊，不代表bits已在ISR內同步修改。

## 9. Stream Buffer參數

### 9.1 建立

```c
StreamBufferHandle_t xStreamBufferCreate(
    size_t xBufferSizeBytes,
    size_t xTriggerLevelBytes
);
```

| 參數 | 意義 |
|---|---|
| `xBufferSizeBytes` | 希望dynamic Stream Buffer可保存的payload bytes；實作會額外配置內部保留空間 |
| `xTriggerLevelBytes` | reader在空buffer等待時，累積到多少bytes後被喚醒；0會改用1，不可大於buffer size |

Static版本：

```c
xStreamBufferCreateStatic(
    xBufferSizeBytes,
    xTriggerLevelBytes,
    pucStreamBufferStorageArea,
    pxStaticStreamBuffer
);
```

第三參數是至少`xBufferSizeBytes`的`uint8_t`陣列；第四參數是`StaticStreamBuffer_t`地址。Static ring buffer需要保留一格來分辨full/empty，所以可用payload是`xBufferSizeBytes-1`；例如256-byte storage可排隊255 bytes。Static版本的trigger應設在`1..可用payload`。成功回handle，失敗回`NULL`。

### 9.2 Send與Receive

```c
size_t xStreamBufferSend(
    StreamBufferHandle_t xStreamBuffer,
    const void *pvTxData,
    size_t xDataLengthBytes,
    TickType_t xTicksToWait
);
```

| 參數 | 意義 |
|---|---|
| `xStreamBuffer` | 目標handle |
| `pvTxData` | 要複製的bytes起始地址 |
| `xDataLengthBytes` | 希望送出的bytes數 |
| `xTicksToWait` | 空間不足時最多等待多久 |

回傳實際寫入bytes，可能少於要求值，caller必須檢查。

```c
size_t xStreamBufferReceive(
    StreamBufferHandle_t xStreamBuffer,
    void *pvRxData,
    size_t xBufferLengthBytes,
    TickType_t xTicksToWait
);
```

第二參數是destination，第三參數是destination可容納的最大bytes，第四參數是buffer空時timeout。回傳實際收到bytes，timeout為0。

### 9.3 ISR版本

```c
xStreamBufferSendFromISR(
    xStreamBuffer,
    pvTxData,
    xDataLengthBytes,
    pxHigherPriorityTaskWoken
);

xStreamBufferReceiveFromISR(
    xStreamBuffer,
    pvRxData,
    xBufferLengthBytes,
    pxHigherPriorityTaskWoken
);
```

前三個參數與Task版本相同，最後一個為yield output pointer；沒有timeout。回傳實際傳輸bytes。

### 9.4 查詢、Trigger、Reset與Delete

| API | 參數 | 回傳／注意事項 |
|---|---|---|
| `xStreamBufferBytesAvailable(xBuffer)` | handle | 可讀bytes |
| `xStreamBufferSpacesAvailable(xBuffer)` | handle | 可寫bytes |
| `xStreamBufferIsEmpty(xBuffer)` | handle | `pdTRUE/pdFALSE` |
| `xStreamBufferIsFull(xBuffer)` | handle | `pdTRUE/pdFALSE` |
| `xStreamBufferSetTriggerLevel(xBuffer, xTriggerLevel)` | handle、新trigger bytes | `pdPASS/pdFAIL` |
| `xStreamBufferReset(xBuffer)` | handle | `pdPASS/pdFAIL`；有Task正在等待時可能失敗 |
| `xStreamBufferResetFromISR(xBuffer)` | handle | ISR版本結果 |
| `vStreamBufferDelete(xBuffer)` | handle | 無；之後handle失效 |

Stream Buffer設計假設single writer + single reader；多writer/readers需外層序列化。

## 10. Message Buffer參數

Message Buffer使用`message_buffer.h`，底層建立在Stream Buffer上，但一筆send會保留成一筆完整message。

### 10.1 建立

```c
MessageBufferHandle_t xMessageBufferCreate(size_t xBufferSizeBytes);
```

`xBufferSizeBytes`是整體storage bytes；除了保留的1 byte，每筆message還要使用length header，因此不能把整個容量全部當payload。

```c
MessageBufferHandle_t xMessageBufferCreateStatic(
    size_t xBufferSizeBytes,
    uint8_t *pucMessageBufferStorageArea,
    StaticMessageBuffer_t *pxStaticMessageBuffer
);
```

| 參數 | 意義 |
|---|---|
| `xBufferSizeBytes` | storage總bytes |
| `pucMessageBufferStorageArea` | caller提供的byte陣列 |
| `pxStaticMessageBuffer` | caller提供的control structure |

成功回handle、失敗回`NULL`。Static版本實際可用storage是`xBufferSizeBytes-1`；RV32每筆message另使用4 bytes的`size_t` length header，例如10-byte payload需要14 bytes可用空間。

### 10.2 Send與Receive

```c
size_t xMessageBufferSend(
    MessageBufferHandle_t xMessageBuffer,
    const void *pvTxData,
    size_t xDataLengthBytes,
    TickType_t xTicksToWait
);
```

| 參數 | 意義 |
|---|---|
| `xMessageBuffer` | 目標handle |
| `pvTxData` | message起始地址 |
| `xDataLengthBytes` | 這一筆message payload長度 |
| `xTicksToWait` | 空間不足時最多等待多久 |

Message是atomic；成功回傳完整payload bytes，失敗／timeout回0，不會只送半筆message。

```c
size_t xMessageBufferReceive(
    MessageBufferHandle_t xMessageBuffer,
    void *pvRxData,
    size_t xBufferLengthBytes,
    TickType_t xTicksToWait
);
```

| 參數 | 意義 |
|---|---|
| `pvRxData` | destination buffer |
| `xBufferLengthBytes` | destination最多可容納bytes |
| `xTicksToWait` | 沒有message時最多等待多久 |

成功回傳下一筆message長度。Destination太小時回0，該message不會被部分取走；可先用`xMessageBufferNextLengthBytes()`查長度。

### 10.3 ISR與查詢

```c
xMessageBufferSendFromISR(
    xMessageBuffer,
    pvTxData,
    xDataLengthBytes,
    pxHigherPriorityTaskWoken
);

xMessageBufferReceiveFromISR(
    xMessageBuffer,
    pvRxData,
    xBufferLengthBytes,
    pxHigherPriorityTaskWoken
);
```

前三個參數與Task版本相同，最後一個為yield output pointer；沒有timeout。

| API | 參數 | 回傳 |
|---|---|---|
| `xMessageBufferNextLengthBytes(xBuffer)` | handle | 下一筆payload長度；empty時為0 |
| `xMessageBufferSpaceAvailable(xBuffer)` | handle | 目前可用storage bytes |
| `xMessageBufferIsEmpty(xBuffer)` | handle | `pdTRUE/pdFALSE` |
| `xMessageBufferIsFull(xBuffer)` | handle | `pdTRUE/pdFALSE` |
| `xMessageBufferReset(xBuffer)` | handle | `pdPASS/pdFAIL` |
| `xMessageBufferResetFromISR(xBuffer)` | handle | ISR版本結果 |

Message Buffer同樣以single writer + single reader為主要設計假設。

## 11. Software Timer參數

需要：

```c
#include "FreeRTOS.h"
#include "timers.h"
```

### 11.1 建立Timer

```c
TimerHandle_t xTimerCreate(
    const char *pcTimerName,
    TickType_t xTimerPeriodInTicks,
    BaseType_t xAutoReload,
    void *pvTimerID,
    TimerCallbackFunction_t pxCallbackFunction
);
```

| 參數 | 要填什麼 |
|---|---|
| `pcTimerName` | 診斷名稱字串；Timer只保存pointer，字串需長期有效 |
| `xTimerPeriodInTicks` | 到期週期，必須大於0；毫秒用`pdMS_TO_TICKS()` |
| `xAutoReload` | `pdTRUE`週期Timer；`pdFALSE`只到期一次 |
| `pvTimerID` | Application自訂context pointer，不需要可填`NULL` |
| `pxCallbackFunction` | `void callback(TimerHandle_t timer)`函式 |

Static版本最後多一個：

```c
StaticTimer_t *pxTimerBuffer
```

caller必須提供長期有效的`StaticTimer_t`。兩種版本成功回handle、失敗回`NULL`。

### 11.2 Start、Stop、Reset與Delete

```c
xTimerStart(xTimer, xTicksToWait);
xTimerStop(xTimer, xTicksToWait);
xTimerReset(xTimer, xTicksToWait);
xTimerDelete(xTimer, xTicksToWait);
```

| 參數 | 意義 |
|---|---|
| `xTimer` | 目標Timer handle |
| `xTicksToWait` | Timer command queue滿時，caller最多等待多久 |

回`pdPASS`只代表command成功排入Timer queue，不代表Timer Task已經執行完command。

```c
xTimerChangePeriod(xTimer, xNewPeriod, xTicksToWait);
```

`xNewPeriod`是新的非零tick週期；修改後從處理command時重新計時。

### 11.3 ISR版本

```c
xTimerStartFromISR(xTimer, pxHigherPriorityTaskWoken);
xTimerStopFromISR(xTimer, pxHigherPriorityTaskWoken);
xTimerResetFromISR(xTimer, pxHigherPriorityTaskWoken);
xTimerChangePeriodFromISR(xTimer, xNewPeriod, pxHigherPriorityTaskWoken);
```

ISR版本沒有queue timeout；最後一個參數是yield output pointer。回`pdPASS/pdFAIL`表示command是否成功排隊。

### 11.4 Timer ID、名稱與狀態

| API | 參數 | 回傳／作用 |
|---|---|---|
| `pvTimerGetTimerID(xTimer)` | Timer handle | 建立或set時保存的`void *`context |
| `vTimerSetTimerID(xTimer, pvNewID)` | handle、新context pointer | 無 |
| `pcTimerGetName(xTimer)` | handle | 名稱pointer |
| `xTimerIsTimerActive(xTimer)` | handle | active為`pdTRUE` |
| `xTimerGetPeriod(xTimer)` | handle | period ticks |
| `xTimerGetExpiryTime(xTimer)` | handle | active時預計到期的absolute tick；inactive時回傳值未定義 |
| `vTimerSetReloadMode(xTimer, xAutoReload)` | handle、`pdTRUE/pdFALSE` | runtime切換reload模式 |
| `xTimerGetReloadMode(xTimer)` | handle | reload mode |

Timer ID只是保存pointer，不會複製context資料；指向物件必須持續有效。

### 11.5 Pend Function Call

```c
BaseType_t xTimerPendFunctionCall(
    PendedFunction_t xFunctionToPend,
    void *pvParameter1,
    uint32_t ulParameter2,
    TickType_t xTicksToWait
);
```

Pended function型態：

```c
void deferred_function(void *parameter1, uint32_t parameter2);
```

| 參數 | 意義 |
|---|---|
| `xFunctionToPend` | 稍後由Timer Task執行的短函式 |
| `pvParameter1` | 原樣傳給函式的pointer |
| `ulParameter2` | 原樣傳給函式的32-bit value |
| `xTicksToWait` | Timer command queue滿時等待多久 |

`xTimerPendFunctionCallFromISR()`前三個參數相同，第四個改為`pxHigherPriorityTaskWoken`，沒有timeout。

## 12. Heap與mini C runtime參數

### 12.1 FreeRTOS heap

```c
void *pvPortMalloc(size_t xWantedSize);
```

`xWantedSize`是payload bytes。成功回aligned pointer，失敗回`NULL`；回傳記憶體未自動清零。

```c
void *pvPortCalloc(size_t xNum, size_t xSize);
```

配置`xNum * xSize` bytes並清零；乘法overflow或空間不足時回`NULL`。

```c
void vPortFree(void *pv);
```

`pv`必須是`pvPortMalloc/pvPortCalloc`回傳且尚未釋放的pointer；`NULL`可安全忽略。不可傳stack、global或MMIO地址。

| API | 參數 | 回傳 |
|---|---|---|
| `xPortGetFreeHeapSize()` | 無 | 所有free blocks總bytes，不代表最大可配置block |
| `xPortGetMinimumEverFreeHeapSize()` | 無 | 啟動以來最低free bytes |
| `vPortGetHeapStats(pxStats)` | 必要的`HeapStats_t *` output | 無；填入總free、最大／最小block、block數、最低free、成功alloc/free次數 |

### 12.2 `malloc/calloc/realloc/free`

所有RTOS profile的mini C runtime將它們接到FreeRTOS heap：

| API | 參數 | 回傳／注意事項 |
|---|---|---|
| `malloc(size)` | payload bytes；0會配置最小非零block | pointer或`NULL` |
| `calloc(count, size)` | element數與每element bytes | 清零pointer或`NULL`；檢查乘法overflow |
| `realloc(ptr, size)` | 舊pointer／`NULL`與新bytes | 新pointer或`NULL`；可能搬移，成功後舊pointer失效 |
| `free(ptr)` | 由本專案`malloc/calloc/realloc`取得的pointer | 無；`NULL`可接受 |

不要混用`pvPortMalloc()`取得的原始pointer與mini-libc `free()`；`free()`預期pointer前面有本專案allocation header。配對使用：

```text
pvPortMalloc／pvPortCalloc -> vPortFree
malloc／calloc／realloc    -> free
```

### 12.3 Memory/string helpers

| API | 參數 | 回傳 |
|---|---|---|
| `memset(dest, value, size)` | destination、低8-bit填充值、bytes | `dest` |
| `memcpy(dest, src, size)` | 不可重疊的destination/source、bytes | `dest` |
| `memmove(dest, src, size)` | 可重疊的destination/source、bytes | `dest` |
| `memcmp(a, b, size)` | 兩區域與比較bytes | `<0/0/>0` |
| `strlen(text)` | NUL結尾字串，不可為`NULL` | 不含NUL的字元數 |

## 13. UART Platform API參數

需要：

```c
#include "uart.h"
```

若不清楚ISR與Task的差異、Application在哪裡接收UART ISR送來的資料，或為何通常推薦blocking `rtos_uart_getc()`，先讀 [ISR_TASK_API_BOUNDARY.md](../04-freertos/ISR_TASK_API_BOUNDARY.md)。

### 13.1 TX輸出

| API | 參數 | 回傳／行為 |
|---|---|---|
| `rtos_uart_putc(char c)` | 一個8-bit字元 | 無；polling等待TX ready |
| `rtos_uart_write(const char *text)` | 必須為有效NUL結尾字串 | 無；遇到`\n`會先送`\r` |
| `rtos_uart_write_line(const char *text)` | NUL結尾字串 | 無；文字後自動加newline |
| `rtos_uart_write_u32(uint32_t value)` | unsigned 32-bit值 | 無；十進位輸出 |
| `rtos_uart_write_u64(uint64_t value)` | unsigned 64-bit值 | 無；十進位輸出 |
| `rtos_uart_write_hex32(uint32_t value)` | 32-bit值 | 無；輸出`0x`加8位hex |
| `rtos_uart_wait_tx_idle()` | 無 | 無；busy-wait直到最後byte完成 |

這些函式目前不接受length；`text`必須以`\0`結尾，也不可為`NULL`。

### 13.2 RX初始化與取字元

```c
int rtos_uart_rx_interrupt_init(void);
```

無參數。成功建立／重用RX StreamBuffer並開啟`mie.MEIE`時回1，建立失敗回0。

```c
int rtos_uart_try_getc(char *value, uint32_t *overrun);
```

| 參數 | 意義 |
|---|---|
| `value` | 必要output pointer；成功時寫入一個byte |
| `overrun` | optional output；自上次report後有hardware overrun或stream drop則寫1，不需要可填`NULL` |

立即有byte回1，沒有回0，不會Blocked。若在沒有其他blocking point的高priority loop中反覆呼叫，會形成busy polling並持續占用CPU；它適合只想順便查看一次的Task。

```c
int rtos_uart_getc(
    char *value,
    uint32_t timeout_ticks,
    uint32_t *overrun
);
```

`value/overrun`同上；`timeout_ticks`是FreeRTOS ticks，不是毫秒。收到byte會立即回1，不必等滿timeout；期限內沒有byte才回0。等待時只有caller Task進入Blocked，其他Tasks與CPU仍可工作。專用RX Task通常使用`portMAX_DELAY`，需要週期性工作的Task可使用`pdMS_TO_TICKS(n)`有限等待。RX interrupt尚未初始化時會退回non-blocking polling，所以需要blocking行為時必須先檢查init成功。

### 13.3 UART診斷與內部入口

| API | 參數 | 回傳／用途 |
|---|---|---|
| `rtos_uart_rx_interrupt_count()` | 無 | 累積external UART ISR次數 |
| `rtos_uart_rx_hardware_overrun_count()` | 無 | 1-byte holding register overrun累計 |
| `rtos_uart_rx_stream_drop_count()` | 無 | software StreamBuffer drop累計 |
| `rtos_uart_handle_external_interrupt()` | 無 | 內部ISR入口；回1表示喚醒較高priority Task，Application不要直接呼叫 |
| `rtos_uart_trigger_test_interrupt()` | 無 | 設synthetic MEIP做Platform test |

## 14. Performance Counter API參數

需要：

```c
#include "perf_counters.h"
```

### 14.1 無參數控制與查詢

| API | 參數 | 回傳／作用 |
|---|---|---|
| `perf_counters_available()` | 無 | ID、ABI與counter數符合時回1，否則0 |
| `perf_counters_info()` | 無 | raw INFO register |
| `perf_counters_status()` | 無 | raw STATUS register |
| `perf_counters_reset_start()` | 無 | 清零並開始 |
| `perf_counters_reset_stop()` | 無 | 清零並停止 |
| `perf_counters_start()` | 無 | 保留數值並開始 |
| `perf_counters_stop()` | 無 | 停止累計 |

### 14.2 Snapshot

```c
int perf_counters_snapshot(
    PerfCounterSnapshot_t *snapshot,
    int stop_after
);
```

| 參數 | 意義 |
|---|---|
| `snapshot` | 必要output pointer；接收24組64-bit counter及status |
| `stop_after` | 0表示拍照後release並維持原本running；非0表示拍照後保持停止 |

硬體不可用或pointer為`NULL`回0，成功回1。

### 14.3 名稱與比例

```c
const char *perf_counter_name(uint32_t index);
```

`index`有效範圍`0..23`，回傳固定名稱pointer；超出範圍回`"unknown"`。

```c
uint32_t perf_counters_per_mille(
    uint64_t numerator,
    uint64_t denominator
);
```

計算`numerator / denominator * 1000`並避免中間overflow。`denominator=0`回0；結果超過32-bit時飽和為`0xFFFFFFFF`。

## 15. VGA Framebuffer API參數

需要`vga_fb.h`並將`game/vga_fb.c`編入profile。

| API | 參數 | 回傳／限制 |
|---|---|---|
| `vga_fb_clear(color)` | palette index；只使用低4 bits | 無；清除目前draw buffer |
| `vga_fb_put_pixel(x, y, color)` | `x=0..159`、`y=0..119`、4-bit color | 無；超界時不動作 |
| `vga_fb_fill_rect4(x, y, w, h, color)` | 左上角、寬高、color | 無；`x`與`w`必須為4的倍數、矩形不得超界，否則不動作 |
| `vga_fb_set_draw_buffer(index)` | buffer index；實作取`index & 1` | 無；0/1選擇bank |
| `vga_fb_present()` | 無 | 無；要求顯示目前draw buffer，不等待ack |
| `vga_fb_present_sync()` | 無 | frame切換在poll上限內完成回1，timeout回0 |
| `vga_fb_swap_draw_buffer()` | 無 | 無；draw index在0/1間切換 |
| `vga_fb_draw_buffer_index()` | 無 | 目前CPU draw bank 0/1 |
| `vga_fb_display_buffer_index()` | 無 | 目前VGA front/display bank 0/1 |

```c
vga_fb_fill_rect4(8u, 10u, 40u, 20u, 14u);
```

合法是因為`x=8`與`w=40`皆能被4整除，且矩形未超出160x120。

## 16. Board-control API參數

| API | 參數 | 回傳／行為 |
|---|---|---|
| `rtos_board_disable_external_interrupts()` | 無 | 無；清除`mie.MEIE`，不是一般mutex替代品 |
| `rtos_board_request_image_reload()` | 無 | `noreturn`；等待UART idle、寫reload MMIO，接著等待硬體reset |

Custom profile必須額外編入`OS/rtos/src/board_control.c`。

## 17. Lua `rtos.*`參數

這些只供`lua` profile中的Lua script使用。

| Lua API | 參數 | 回傳／行為 |
|---|---|---|
| `rtos.tick()` | 無 | tick integer |
| `rtos.heap_free()` | 無 | free heap bytes |
| `rtos.heap_min()` | 無 | minimum-ever free bytes |
| `rtos.tasks()` | 無 | Task數量 |
| `rtos.heartbeat()` | 無 | heartbeat count |
| `rtos.irq_count()` | 無 | UART external interrupt count |
| `rtos.sleep(milliseconds)` | 必填integer `0..60000` | 無；每50 ms檢查stop，block Lua Task |
| `rtos.read_line([timeout_ms])` | optional integer `0..60000`，預設30000 | 成功回字串；timeout回`nil, "timeout"`；stop則raise error |
| `rtos.ping()` | 無 | UART印PONG並回tick |
| `rtos.status()` | 無 | 直接UART輸出狀態，不回table |
| `rtos.reload()` | 無 | 不返回，切回bootloader |

`rtos.platform`是字串欄位，不是函式，所以寫：

```lua
print(rtos.platform)
```

不是：

```lua
print(rtos.platform())
```

## 18. 如何判斷一個pointer參數是input還是output

FreeRTOS命名慣例可幫助閱讀，但仍要以prototype與文件為準：

| 名稱特徵 | 通常意思 | 例子 |
|---|---|---|
| `const void *pvItemToQueue` | input，函式只讀 | `xQueueSend(..., &item, ...)` |
| `void *pvBuffer` | output destination | `xQueueReceive(..., &item, ...)` |
| `BaseType_t *pxHigherPriorityTaskWoken` | ISR output flag | caller先設`pdFALSE` |
| `TaskHandle_t *pxCreatedTask` | output handle | `xTaskCreate(..., &handle)` |
| `StaticTask_t *pxTaskBuffer` | caller提供storage，input/output皆可能 | Kernel在其中建立control data |
| `void *pvParameters` | opaque input pointer | Kernel不解讀，原樣傳給Task |

## 19. 使用API前的參數檢查

```text
1. 這是Task版本還是FromISR版本？
2. timeout單位是tick還是毫秒？
3. pointer是input、output，還是caller提供storage？
4. storage單位是bytes、items，還是StackType_t words？
5. handle是否已成功建立且仍有效？
6. static storage生命週期是否足夠？
7. 回傳值代表真正完成，還是只代表command成功排隊？
8. Queue／Buffer API可能部分傳輸嗎？
9. `NULL`在這個位置是否被允許？
10. profile-specific source是否已加入build？
```

## 20. 文件分工

| 想知道什麼 | 文件 |
|---|---|
| API是否可用／已驗證 | [RTOS_PLATFORM_API_REFERENCE.md](RTOS_PLATFORM_API_REFERENCE.md) |
| 每個參數怎麼填 | 本文件 |
| 該選Queue、Notification還是Semaphore | [RTOS_APPLICATION_API_GUIDE.md](RTOS_APPLICATION_API_GUIDE.md) |
| 完整C程式骨架 | [FREERTOS_API_EXAMPLES.md](../04-freertos/FREERTOS_API_EXAMPLES.md) |
| API如何變成DDR／CSR／MMIO動作 | [SOFTWARE_HARDWARE_INTERFACE.md](../04-freertos/SOFTWARE_HARDWARE_INTERFACE.md) |
| 新Application如何build與上板 | [ADDING_NEW_RTOS_APP.md](ADDING_NEW_RTOS_APP.md) |
