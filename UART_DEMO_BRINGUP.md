# UART Demo Bring-Up

本文件說明目前 `DDR2 + MIG + game.c` 這條路徑，如何在板上完成 UART 展示。

## 1. 先決條件

你需要：
1. 已可正常下載 bitstream
2. 已安裝 `pyserial`
3. 板子已透過原本的 USB 線連到電腦（同一條線可用於下載與板載 UART）

安裝 `pyserial`：

```powershell
python -m pip install pyserial
```

## 2. 目前時鐘架構（重要）

目前文件已依照最新 RTL 更新：
- 不再需要額外從板外提供一條獨立的 top-level `clk_ref_i`
- `board_top.v` 只接收板載 `100 MHz` 的 `sys_clk_i`
- `clock_bridge.v` 會在 FPGA 內部產生：
  - `clk_sys_o`（100 MHz）
  - `clk_ref_o`（200 MHz，接到 MIG `clk_ref_i`）

因此：
- 不需要另外外接一條獨立的 200 MHz `clk_ref_i` 線
- 不需要另外外接時鐘模組
- 目前這顆 MIG 已是：
  - `System Clock = No Buffer`
  - `Reference Clock = No Buffer`
- 所以 `sys_clk_i` 的 pin 與 `create_clock` 由板級 XDC 自己約束，不再由 MIG XDC 提供

目前設計預期：
- `sys_clk_i = 100 MHz`（板載振盪器，`E3`）
- `clock_bridge.v` 內部再產生 200 MHz 給 MIG `clk_ref_i`

## 3. UART 連線

目前板級 XDC 使用板載 USB-UART：
- `uart_rx_i -> C4`
- `uart_tx_o -> D4`

也就是：
- 不需要額外外接 USB-TTL 模組
- 不需要另外接 TX/RX/GND 線
- 直接使用板子的 USB-UART 橋接器即可

## 4. 查詢 Windows COM Port

插上板子後，用 PowerShell 查詢：

```powershell
Get-WmiObject Win32_SerialPort | Select-Object DeviceID,Name
```

假設看到是 `COM5`，後面指令就用 `COM5`。

## 5. 產生 `.mem`

目前 `Makefile` 預設會編：
- `game.c`
- 並開 `GAME_USE_UART`

直接執行：

```powershell
make
```

會產生：
- `TEST_FILES/mem_game.mem`

## 6. 透過 UART 傳送程式

```powershell
python uart_send_mem.py --port COM5 --baud 115200 --mem TEST_FILES/mem_game.mem
```

若要保守一點，可加延遲：

```powershell
python uart_send_mem.py --port COM5 --baud 115200 --mem TEST_FILES/mem_game.mem --delay 1.0
```

## 7. 開終端機觀察輸出

可用：
- PuTTY
- Tera Term
- MobaXterm serial session

設定：
1. Port: `COM5`
2. Baud: `115200`
3. Data bits: `8`
4. Parity: `None`
5. Stop bits: `1`
6. Flow control: `None`

## 8. 展示流程

1. 下載 bitstream
2. 確認板載時鐘與 DDR2 MIG 約束已使用正確版本
3. 開終端機 `115200 8N1`
4. 用 `uart_send_mem.py` 傳 `mem_game.mem`
5. bootloader 把程式寫入 DDR2
6. CPU 開始執行，終端機會看到棋盤與提示
7. 在終端機輸入，例如：
   - `1 1`
   - `2 1`
   - `1 2`

## 9. `game.c` 的 UART 輸入規則

- 接受 `1..5`
- 可輸入：
  - `1 3`
  - `13`
- 其他字元會被忽略
- 若位置重複，會顯示 `Cell already used.`
- 遊戲結束後會詢問 `Play again? (y/n):`

## 10. 常見問題

### 沒有輸出
檢查：
1. `uart_send_mem.py` 是否真的送完
2. 終端機是否連到正確 `COMx`
3. 是否是 `115200 8N1`
4. USB 驅動是否正常
5. `sys_clk_i` 是否真的存在且符合 XDC / MIG 設定

### 有亂碼
檢查：
1. 終端機 baud 是否為 `115200`
2. `UART_CLK_HZ` 是否與實際核心時鐘一致

### boot 沒啟動
檢查：
1. `TEST_FILES/mem_game.mem` 是否已重新產生
2. bitstream 是否是最新版本
3. MIG 是否完成初始化（`LED0` 亮）
4. bootloader 是否完成（`LED1` 亮）
