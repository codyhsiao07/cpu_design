# FreeRTOS Lua 5.4.8 使用指南

## 現在能展示什麼

FPGA 可在 FreeRTOS Task 中執行真正的 Lua 5.4.8 直譯器。開機會先跑內建語言、CRC 與記憶體自測，通過後由 UART 提供單行 REPL 和最大 64 KiB 的多行 `.lua` 上傳服務；輸入錯誤不會讓 Task 或系統停止。

UART 開機成功標記：

```text
LUA_SCRIPT_PROTOCOL_PASS
LUA_FLOAT_PASS 7.0 9.0
LUA_SELFTEST_PASS 2870
LUA_REPL_RECOVERY_PASS 7.0 9.0
LUA_VERSION Lua 5.4
LUA_HEAP_READY free=...
LUA_RTOS_READY
lua>
```

## 一鍵編譯與上板

先讓 FPGA 載入目前支援 rearm 的 bitstream，接著在 PowerShell 執行：

```powershell
.\tools\run_rtos_app.ps1 -Port COM5 -App lua
```

工具會依序編譯 preflight 與 Lua、上傳 preflight 確認 CPU/DDR/FreeRTOS 正常，再切換到 Lua image。看到 `lua>` 後即可輸入指令。

Lua profile 預設使用 60 秒 target timeout、64 KiB preamble 和最多三次 retry；仍可用命令列參數覆蓋。

只編譯、不上板：

```powershell
.\tools\build_rtos_app.ps1 -App lua
```

產物位於：

```text
build_rtos_apps\lua\rtos_lua.mem
build_rtos_apps\lua\rtos_lua.elf
build_rtos_apps\lua\rtos_lua.map
build_rtos_apps\lua\rtos_lua.dis
```

## REPL 範例

每次輸入一行；運算式會用 `=>` 顯示結果，statement 則直接執行。

```lua
1 + 2
print(_VERSION)
local t={}; for i=1,10 do t[i]=i*i end; print(t[10], #t)
print(string.upper("fpga"), string.sub("FreeRTOS", 5))
print(math.floor(7.75), math.sqrt(81))
```

刻意產生錯誤後仍可繼續：

```lua
error("test")
print("still alive")
```

目前 interactive terminal 支援 Backspace、Delete、左／右、Home／End。上／下鍵會被安全忽略，尚未提供 command history。

## 執行完整 `.lua` 腳本

先用上面的 `run_rtos_app.ps1` 讓板子停在 `lua>`。因為 interactive monitor 會占用 COM5，按 `Ctrl+C` 離開 terminal 但不要重設板子，再執行：

```powershell
python .\tools\run_lua_script.py `
  --port COM5 `
  --file .\lua_apps\system_monitor.lua
```

工具會傳送來源長度、CRC32、timeout 和 instruction limit；板子回覆 `LUA_SCRIPT_RX_READY` 後才傳 payload，驗證 CRC 後在 Lua Task 編譯與執行。成功標記：

```text
LUA_SCRIPT_ACCEPTED length=...
LUA_SCRIPT_START length=...
LUA_SCRIPT_PASS
```

可直接切換其他腳本，不必重編或重傳 `.mem`：

```powershell
python .\tools\run_lua_script.py --port COM5 --file .\lua_apps\hello.lua
```

預設限制為 10 秒和 2,000,000 Lua VM instructions，可調整：

```powershell
python .\tools\run_lua_script.py `
  --port COM5 `
  --file .\lua_apps\system_monitor.lua `
  --timeout-ms 30000 `
  --instruction-limit 5000000
```

長時間腳本可先 detach，再由另一個程序停止：

```powershell
python .\tools\run_lua_script.py `
  --port COM5 `
  --file .\lua_apps\stop_test.lua `
  --timeout-ms 60000 `
  --instruction-limit 100000000 `
  --detach

python .\tools\run_lua_script.py --port COM5 --stop
```

查詢服務狀態：

```powershell
python .\tools\run_lua_script.py --port COM5 --status
```

腳本只存在 DDR RAM，重新上電、reset 或切換 `.mem` 後消失。

## UART 互動遊戲

`--interactive` 會在腳本開始後持續轉送鍵盤輸入，適合文字遊戲或選單程式。猜數字範例：

```powershell
python .\tools\run_lua_script.py `
  --port COM5 `
  --file .\lua_apps\guess_number.lua `
  --interactive `
  --timeout-ms 600000 `
  --instruction-limit 5000000
```

在終端輸入 `1` 到 `20` 並按 Enter。腳本完成後工具會自動結束；執行期間按 `Ctrl+C` 會要求板上的 Lua script 停止。

遊戲不依賴桌面遊戲引擎。規則與狀態使用 Lua 實作，`print()` 經 UART 顯示，`rtos.read_line()` 經 FreeRTOS Queue 取得玩家輸入。因為目前沒有 VGA 顯示器，這是一個 UART terminal game。

## Task 架構

```text
UART RX ISR
    -> lua_rx Task (priority 3，接收／編輯／CRC／stop)
    -> command Queue / player-input Queue
    -> lua Task (priority 2，唯一操作 lua_State 並執行腳本)

lua_heart Task (priority 1，scheduler heartbeat)
Timer Task (priority 4，FreeRTOS 自動建立)
Idle Task (priority 0，FreeRTOS 自動建立)
```

分離 `lua_rx` 和 `lua` 後，即使 Lua 正在無限迴圈，UART stop 仍能由較高優先權 RX Task 接收，再由 Lua instruction hook 安全中止；`rtos.sleep()` 也會每 50 ticks 檢查停止／timeout。

## FreeRTOS API

Lua 可透過 `rtos` table 查詢系統或讓目前 Lua Task 暫停：

| API | 功能 |
|---|---|
| `rtos.tick()` | 目前 FreeRTOS tick |
| `rtos.sleep(ms)` | 讓 Lua Task 延遲 0～60000 ticks；目前 1 tick = 1 ms |
| `rtos.heap_free()` | 目前剩餘 FreeRTOS heap bytes |
| `rtos.heap_min()` | 啟動後最低剩餘 heap bytes |
| `rtos.tasks()` | 目前 Task 數量 |
| `rtos.heartbeat()` | 背景 heartbeat Task 計數 |
| `rtos.irq_count()` | UART RX interrupt 次數 |
| `rtos.read_line(timeout_ms)` | 等候一行 UART 玩家輸入；成功回傳字串，逾時回傳 `nil, "timeout"` |
| `rtos.ping()` | 印出 tick 並回傳 tick |
| `rtos.status()` | 印出 tick、heap、heartbeat、UART IRQ 摘要 |
| `rtos.reload()` | 返回 UART loader，準備上傳另一個 `.mem` |

例如：

```lua
rtos.status()
local before=rtos.heartbeat(); rtos.sleep(1100); print(rtos.heartbeat()>before)
```

## 已支援與目前限制

這是針對小型 FPGA/FreeRTOS 的 freestanding 移植，不是桌面版 Lua 執行環境。

- Lua 整數與浮點數都是 32-bit，適合 RV32 且能降低 RAM/程式空間需求。
- 已開啟 base、coroutine、table、utf8。
- `string` 支援 `len/sub/upper/lower/reverse/rep/byte/char`。
- `math` 支援 `abs/floor/ceil/sqrt/min/max/pi`。
- 尚未開啟 `io`、`os`、`package`、`debug` 與完整桌面版 `string`/`math`。
- 尚無檔案系統，因此 `loadfile` 和模組檔不可用；`.lua` 由 PC 工具傳到 DDR RAM。
- REPL 每行最多 383 bytes；完整 script service 最大 65,536 bytes。
- Lua VM 集中在單一 Lua Task；RX/Control Task 不會同時操作 `lua_State`。
- script buffer 第一次使用時從 2 MiB FreeRTOS heap 配置 65,537 bytes，之後重複使用。
- instruction hook 只能在 Lua VM 指令邊界中止；本移植的 `rtos.sleep()` 已另外加入 50-tick 檢查。

## 自動測試

RTL 測試（會真的在 RTL CPU 上執行 Lua/FreeRTOS firmware）：

```powershell
.\tools\run_rtos_lua_sim.ps1
```

Lua 已經在板上執行時，可跑 UART 實板 probe：

```powershell
python .\tools\rtos_lua_probe.py --port COM5
python .\tools\rtos_lua_script_probe.py --port COM5 --large-bytes 65536
python .\tools\rtos_lua_game_probe.py --port COM5
```

第一支 probe 驗證 REPL、Lua 語言與 RTOS API。第二支驗證多行腳本、CRC rejection、語法/runtime error 恢復、timeout、instruction limit、外部 stop、65,536-byte 腳本與最後 idle 狀態。第三支使用固定測試答案，實際送入無效、太低、太高與正確答案，驗證 UART 輸入 Queue、遊戲提示、獲勝及返回 idle。

## 原始碼版本

移植基線是官方 Lua 5.4.8，原始壓縮檔 SHA-256：

```text
4f18ddae154e793e46eeab727c59ef1c0c0c2b744e7b94219710d76f530629ae
```

官方核心保留於 `third_party/lua-5.4.8`；FreeRTOS、UART、freestanding C/math glue 與精簡函式庫整合位於 `OS/rtos/src`。
