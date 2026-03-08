# UART Send Mem Guide

## 用途

[uart_send_mem.py](/c:/cpu_design/uart_send_mem.py) 會把 `.mem` 檔轉成 UART 傳輸格式，送到 FPGA 的 `uart_bootloader`。

它做的事是：

1. 讀取 `.mem` 檔中的 32-bit hex word
2. 轉成 little-endian byte stream
3. 先送 4-byte 長度
4. 再送完整 payload

目前最常用的映像是：

- [mem_game.mem](/c:/cpu_design/TEST_FILES/mem_game.mem)

## 前置條件

1. 先編譯出 `.mem`

```powershell
cd C:\cpu_design
make
```

成功後會產生：

- [mem_game.mem](/c:/cpu_design/TEST_FILES/mem_game.mem)

2. 確認 Python 已安裝 `pyserial`

```powershell
python -m pip install pyserial
```

3. 確認 FPGA 已燒入正確 bitstream，且目前會進入 bootloader

4. 確認板子的 COM port

例如：

- `COM3`
- `COM4`

## 基本用法

```powershell
python uart_send_mem.py --port COM3 --mem TEST_FILES/mem_game.mem
```

參數說明：

- `--port`：必填，Windows 串列埠，例如 `COM3`
- `--mem`：必填，要送的 `.mem` 檔
- `--baud`：可選，預設 `115200`
- `--delay`：可選，送資料前先等待幾秒

## 建議實際指令

```powershell
python uart_send_mem.py --port COM3 --baud 115200 --mem TEST_FILES/mem_game.mem --delay 0.2
```

這條指令的用途是：

- 使用 `115200`
- 先等 `0.2` 秒
- 然後把 [mem_game.mem](/c:/cpu_design/TEST_FILES/mem_game.mem) 送進 bootloader

## 建議操作順序

1. 編譯程式

```powershell
make
```

2. 確認 COM port

3. 按板上 reset，讓 bootloader 回到等待狀態

4. 立刻執行：

```powershell
python uart_send_mem.py --port COM3 --mem TEST_FILES/mem_game.mem --delay 0.2
```

5. 若送入成功，bootloader 完成後 CPU 會開始執行程式

## 成功時的輸出

成功時終端機會印出類似：

```text
Sent 2224 bytes from TEST_FILES/mem_game.mem to COM3 @ 115200
```

這表示：

- `.mem` 已被讀取
- UART header + payload 已送出

這不代表板上執行一定成功，但至少 PC 端送檔已完成。

## 常見問題

### 1. `pyserial not found`

代表沒安裝 `pyserial`：

```powershell
python -m pip install pyserial
```

### 2. `could not open port`

常見原因：

- COM port 寫錯
- 串列埠被其他終端機佔用
- USB 線尚未正確連接

### 3. 送完沒有反應

先檢查：

1. 板子是否真的在 bootloader 等待狀態
2. 是否在送之前有按 reset
3. baud 是否一致（目前預設 `115200`）
4. bitstream 是否正確

### 4. 想送別的程式

只要把 `--mem` 換掉即可，例如：

```powershell
python uart_send_mem.py --port COM3 --mem TEST_FILES/mem_os.mem
```

前提是該 `.mem` 已先成功產生。

## 補充

- `uart_send_mem.py` 只負責「送檔」
- 它不會幫你開啟互動終端機

如果你要和遊戲互動：

1. 先用 `uart_send_mem.py` 送檔
2. 再用串列埠終端機連到同一個 `COM` 埠
3. 用 `115200 8N1` 和遊戲互動
4. python uart_send_mem.py --port COM7 --baud 115200 --mem TEST_FILES/mem_game.mem --delay 3.0 --preamble 4096 --interactive
5. python uart_send_mem.py --port COM7 --baud 115200 --mem TEST_FILES/mem_tetris.mem --delay 3.0 --preamble 4096 --interactive
6. python uart_send_mem.py --port COM7 --baud 115200 --mem TEST_FILES/mem_games_menu.mem --delay 3.0 --preamble 4096 --interactive

