# Lua Application 範例

本文件示範目前 FPGA Lua profile 實際支援的語法與 `rtos` API。範例避免使用沒有編入的 `io`、`os`、`package`、完整 math/string library，照目前實作即可放進 `.lua` 後由 [`run_lua_script.py`](../../tools/run_lua_script.py) 上傳。

上傳流程見 [LUA_SCRIPT_UPLOAD.md](LUA_SCRIPT_UPLOAD.md)，VM 與 FreeRTOS 關係見 [LUA_ARCHITECTURE.md](LUA_ARCHITECTURE.md)。

## 範例難度地圖

```mermaid
flowchart LR
    A[REPL<br/>運算與變數] --> B[語法<br/>if／loop／function／table]
    B --> C[rtos API<br/>tick／sleep／status]
    C --> D[互動輸入<br/>read_line]
    D --> E[完整腳本<br/>狀態機／小遊戲]
    E --> F[UART 上傳與重複執行]
```

第一次使用只讀第1、2與8節即可；要寫互動程式再讀 `rtos` API與完整範例，不需要先讀完所有Lua語法。

## 1. 先用 REPL 練習

啟動 Lua firmware：

```powershell
./tools/run_rtos_app.ps1 -Port COM5 -App lua
```

看到 `lua>` 後可直接輸入：

```lua
1 + 1
```

```text
=> 2
```

```lua
6 * 7
```

```text
=> 42
```

```lua
math.sqrt(81)
```

```text
=> 9.0
```

REPL 會先把輸入當 expression；若 expression 解析失敗，再當 statement。因此下列也可執行：

```lua
local total = 0; for i = 1, 10 do total = total + i end; print(total)
```

## 2. 最小 `.lua` 檔

建立：

```lua
print("HELLO_FROM_FPGA")
print("Lua", _VERSION)
print("tick", rtos.tick())
print("tasks", rtos.tasks())
```

儲存為 `lua_apps/my_hello.lua`，再執行：

```powershell
python ./tools/run_lua_script.py `
  --port COM5 `
  --file ./lua_apps/my_hello.lua
```

專案已有相同用途的 [`hello.lua`](../../lua_apps/hello.lua)。`print()` 來自 Lua base library，輸出被本專案 port 導向 UART；它不是 FreeRTOS 原生 API，也不需要每個腳本重新實作 UART driver。

## 3. 變數與基本型別

```lua
local enabled = true
local count = 12
local voltage = 3.3
local name = "cpu"
local missing = nil

print(type(enabled), type(count), type(voltage))
print(type(name), type(missing))
```

Lua 是動態型別語言。`local` 變數限制在目前 scope/chunk，沒有 `local` 的 assignment 會建立或修改 global：

```lua
shared_value = 123
```

本專案重複使用同一個 `lua_State`，所以 global 可能在下一份 script 仍存在。正式腳本應優先使用 `local`，降低不同腳本互相污染。

## 4. 條件與 loop

```lua
local value = 17

if value < 10 then
    print("small")
elseif value < 20 then
    print("medium")
else
    print("large")
end

local total = 0
for i = 1, 100 do
    total = total + i
end
print("total", total)
```

所有 `if`、`for`、`while` 與 function block 都必須以 `end` 結束。多行 script 比 REPL 更適合撰寫 block 結構。

不要寫沒有退出條件的 loop，除非刻意測 guard：

```lua
while true do end
```

它最後會被 timeout 或 instruction limit 中斷，但在中斷前會消耗 Lua Task 的 CPU time。

## 5. Function

```lua
local function checksum(limit)
    local value = 0
    for i = 1, limit do
        value = (value ~ i) & 0x7FFFFFFF
    end
    return value
end

print("checksum", checksum(1000))
```

Lua 5.4 支援 integer bitwise operators，例如 `&`、`|`、`~`、`<<`、`>>`。本 target 的 integer 是 32-bit，對依賴超過 32-bit 範圍的程式要重新設計或用多 word 表示。

## 6. Table

```lua
local samples = {}
local sum = 0

for i = 1, 20 do
    samples[i] = i * i
    sum = sum + samples[i]
end

assert(#samples == 20)
assert(samples[20] == 400)
print("sum", sum)
```

Lua array 習慣從 index 1 開始。Table 也可作 record：

```lua
local status = {
    name = "worker",
    ready = true,
    jobs = 3
}

print(status.name, status.ready, status.jobs)
```

Table memory 由 Lua allocator從 FreeRTOS heap取得。建立大量 table 後可觀察：

```lua
print("heap", rtos.heap_free(), "minimum", rtos.heap_min())
```

## 7. 精簡 String API

```lua
local text = "FreeRTOS"

print("length", string.len(text))
print("sub", string.sub(text, 5))
print("upper", string.upper(text))
print("lower", string.lower(text))
print("reverse", string.reverse(text))
print("repeat", string.rep("ab", 3))
print("first-byte", string.byte(text, 1))
print("char", string.char(70, 80, 71, 65))
```

目前沒有完整 pattern API，例如 `string.match`、`string.gsub`、`string.format`。移植既有腳本前要先替換這些呼叫，或在 C port 補入需要的 library function。

## 8. 精簡 Math API

```lua
print("abs", math.abs(-12))
print("floor", math.floor(7.75))
print("ceil", math.ceil(7.25))
print("sqrt", math.sqrt(81))
print("min", math.min(8, 3, 5))
print("max", math.max(8, 3, 5))
print("pi", math.pi)
```

目前沒有完整三角函式與 `math.random()`。需要簡單遊戲變化時，可像猜數字範例一樣從 `rtos.tick()` 取得變動 seed-like 值，但這不是密碼學隨機數：

```lua
local value = (rtos.tick() % 20) + 1
```

## 9. FreeRTOS 狀態查詢

```lua
print("platform", rtos.platform)
print("tick", rtos.tick())
print("tasks", rtos.tasks())
print("heap_free", rtos.heap_free())
print("heap_min", rtos.heap_min())
print("heartbeat", rtos.heartbeat())
print("uart_irq", rtos.irq_count())

local returned_tick = rtos.ping()
print("ping returned", returned_tick)
rtos.status()
```

`rtos.status()` 直接輸出一行診斷，不回傳 table。若程式要自行計算，分別呼叫 `tick/heap_free/...`。

## 10. 正確使用 `rtos.sleep()`

```lua
print("WAIT_START", rtos.tick())

for second = 1, 5 do
    rtos.sleep(1000)
    print("second", second, "tick", rtos.tick())
end

print("WAIT_DONE", rtos.tick())
```

`rtos.sleep(1000)` 會 block Lua FreeRTOS Task，其他 Tasks仍可運作。它不是 CPU busy-wait。

允許範圍是 0..60000 ms。Script execution timeout 包含 sleep 時間；上例至少需要超過 5 秒：

```powershell
python ./tools/run_lua_script.py `
  --port COM5 `
  --file ./lua_apps/my_wait.lua `
  --timeout-ms 10000
```

專案已有 [`system_monitor.lua`](../../lua_apps/system_monitor.lua)，會每秒顯示 tick、heap、heartbeat 與 UART IRQ，共執行 5 次。

## 11. 互動輸入

```lua
print("What is your name?")
local name, reason = rtos.read_line(30000)

if name == nil then
    print("INPUT_FAILED", reason)
else
    print("Hello", name)
end
```

以 interactive 模式上傳：

```powershell
python ./tools/run_lua_script.py `
  --port COM5 `
  --file ./lua_apps/ask_name.lua `
  --interactive `
  --timeout-ms 60000
```

`rtos.read_line()` 預設 timeout 30000 ms，可傳 0..60000。Timeout 時回傳 `nil, "timeout"`；stop/整個 script timeout 時則拋出 Lua error，最後由 guard 顯示停止原因。

Input Queue 長度是 4。應採「印 prompt → 等一行 → 處理」模式，不要要求使用者一次快速貼上很多行。

## 12. 猜數字遊戲

專案的 [`guess_number.lua`](../../lua_apps/guess_number.lua) 示範：

- 用 `rtos.tick()` 選擇 1..20 的答案。
- 用 `rtos.read_line()` 取得鍵盤輸入。
- 用 `tonumber()` 驗證數字。
- 最多六次嘗試。
- 回報 low、high、win 或 timeout。

執行：

```powershell
python ./tools/run_lua_script.py `
  --port COM5 `
  --file ./lua_apps/guess_number.lua `
  --interactive `
  --timeout-ms 600000 `
  --instruction-limit 5000000
```

測試流程範例：

```text
GAME_READY range=1..20 attempts=6
GAME_PROMPT next_attempt= 1
10
GAME_LOW 10
```

遊戲只有文字 UI，不需要 VGA 函式庫或 VGA 螢幕。

## 13. 有界狀態機

```lua
local state = "idle"
local cycles = 0

while cycles < 10 do
    if state == "idle" then
        print("STATE idle")
        state = "working"
    elseif state == "working" then
        print("STATE working")
        state = "done"
    else
        print("STATE done")
        state = "idle"
    end

    cycles = cycles + 1
    rtos.sleep(100)
end

print("STATE_MACHINE_PASS", cycles)
```

這種有最大 cycle 次數、每輪會 sleep 的狀態機很適合目前 Lua 平台：容易停止、容易量測，也不會永久占住 Lua Task。

## 14. Error handling

Lua base library提供 `pcall()`：

```lua
local function may_fail(value)
    assert(value >= 0, "value must be non-negative")
    return math.sqrt(value)
end

local ok, result = pcall(may_fail, -1)
if ok then
    print("result", result)
else
    print("caught", result)
end
```

未被 script 自己捕捉的 error 會讓該 chunk得到 `LUA_SCRIPT_ERROR`，但 VM 應回到 prompt，可再傳下一份 script。

專案故意保留兩個負向測試：

- [`syntax_error.lua`](../../lua_apps/syntax_error.lua)
- [`runtime_error.lua`](../../lua_apps/runtime_error.lua)

它們預期失敗，不應把這兩個檔案的非零 exit code當成平台故障；真正要確認的是錯誤後仍能執行 `hello.lua`。

## 15. Stop 與長時間執行

[`stop_test.lua`](../../lua_apps/stop_test.lua) 是 tight infinite loop：

```lua
print("STOP_TEST_START")
local value = 0
while true do
    value = value + 1
end
```

測試 external stop：

```powershell
python ./tools/run_lua_script.py `
  --port COM5 `
  --file ./lua_apps/stop_test.lua `
  --timeout-ms 60000 `
  --instruction-limit 100000000 `
  --detach

python ./tools/run_lua_script.py --port COM5 --status
python ./tools/run_lua_script.py --port COM5 --stop
```

[`sleep_stop_test.lua`](../../lua_apps/sleep_stop_test.lua) 則驗證 script 在 `rtos.sleep(60000)` 中仍會每 50 ms 檢查 stop。

## 16. Reload

Lua 可以要求重新進入 bootloader：

```lua
print("about to reload")
rtos.reload()
```

`rtos.reload()` 不會回到下一行。它會等待 UART TX idle，再由 board-control MMIO reset CPU／交還 DDR。

只想結束目前 script 不應呼叫 reload；讓 script自然 return，或用 host `--stop` 即可。

## 17. Lua 目前不能直接做什麼

### 不能建立新的 FreeRTOS Task

目前 `rtos` library 沒有 `task_create()`、Queue create 或 mutex API。整份 Lua script 在既有 `lua` Task 中執行；`coroutine` 也不是 FreeRTOS Task。

若需要真正背景 worker：

1. 在 C 中建立固定 FreeRTOS Task/Queue。
2. 在 `lua_rtos_libs.c` 加入安全的 Lua C binding。
3. Binding 只送 request 或讀 result，不讓多個 Tasks 同時操作同一 `lua_State`。

### 不能讀寫檔案

沒有 filesystem 與 `io` library。資料需要寫在 script、由 UART輸入，或未來新增 SD/SPI flash driver與受限 API。

### 不能直接畫 VGA

目前 Lua library沒有 framebuffer binding。Lua 可以做遊戲邏輯與文字遊戲；若要 VGA，需要先在 C driver 層提供有邊界檢查的畫圖 API，再暴露給 Lua。

### 不能使用任意 PC Lua module

沒有 package loader、shared library 或 host OS。第三方純 Lua module 若只使用現有語法/library，可以把 source 合併進同一 script；依賴 `io/os/package` 或 native C module 者需要移植。

## 18. 建議的腳本結構

正式腳本可採：

```lua
local function main()
    print("APP_START")

    -- 初始化 local state。
    -- 執行有界 loop，必要時 sleep/read_line。

    print("APP_PASS")
end

local ok, reason = pcall(main)
if not ok then
    print("APP_ERROR", reason)
    error(reason)
end
```

設計原則：

- 盡量使用 `local`。
- Loop 有明確結束條件或 sleep。
- 輸入有 timeout 與 invalid-data path。
- 用固定 marker 方便自動 probe。
- 根據最長 sleep/輸入時間設定 host `--timeout-ms`。
- 大量資料結構前後觀察 heap，並測試 error 後能恢復。
