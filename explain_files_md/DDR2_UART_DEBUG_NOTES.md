# DDR2 UART Bring-Up Debug Notes

本文件整理這次 `board_top + DDR2 MIG + UART bootloader + game.c` 的實際 debug 過程、最後修正點，以及之後最容易再踩到的坑。

## 1. 目前已確認可工作的狀態

- top 固定使用 `board_top.v`
- DDR2 MIG 可正常 `init_calib_complete`
- UART bootloader 可正常透過板載 USB-UART 將 `.mem` 載入 DDR2
- CPU 可從 DDR2 開始取指並執行
- `mem_uart_smoke.mem` 已確認能持續回傳 `U`
- `mem_game.mem` 已確認能正常顯示棋盤並接受互動輸入
- 目前不需要 `Tera Term`，可直接用 `uart_send_mem.py --interactive`

## 2. 這次真正的根因

最關鍵的根因不是 UART 協定，也不是 MIG command/data 握手本身，而是：

- 我們先前把 MIG native interface 的 `app_addr` 當成 `16-byte beat index`
- 因此在多處用了 `(addr - DDR_BASE) >> 4`

這個假設對目前這顆 MIG 是錯的。

### 2.1 為什麼確定是這裡錯

有兩個決定性證據：

1. cross-address memtest
   - 一開始只做單一地址 write/read，會 pass
   - 後來改成先寫 `addr0/1/2/3`，再回頭讀 `addr0/1/2/3`
   - 板上結果出現「只有最後一個地址 pass」
   - 這非常像前面幾次寫入被後面的寫入覆蓋，代表地址單位假設錯了

2. generated MIG parameter
   - generated `mig_7series_0_mig.v` 顯示：
     - `BANK_WIDTH = 3`
     - `ROW_WIDTH = 13`
     - `COL_WIDTH = 10`
     - `ADDR_WIDTH = 27`
   - `RANKS = 1`
   - 對這顆 x16 DDR2 來說，`ADDR_WIDTH = 27` 不支持我們原本那種 `>>4` 的 beat-index 假設

結論：

- `app_addr` 要視為 byte-domain 使用
- 不是把低 4 bits 先丟掉再餵給 MIG

## 3. 最後修正的 RTL

### 3.1 bootloader address translation

修改：

- [uart_bootloader.v](C:/cpu_design/uart_bootloader.v:477)
- [uart_bootloader.v](C:/cpu_design/uart_bootloader.v:773)

修正前：

- write address 用 `(curr_addr - DDR_BASE) >> 4`
- verify read address 用 `((BOOT_ADDR - DDR_BASE) >> 4) + verify_idx`

修正後：

- write address 直接用 `curr_addr - DDR_BASE`
- verify read address 直接用 byte-domain base，再用 `16-byte` 間距前進

### 3.2 L2/MIG address translation

修改：

- [L2_cache.v](C:/cpu_design/L2_cache.v:234)

修正前：

- `pa_to_app_addr16()` 用 `off[31:4]`

修正後：

- `pa_to_app_addr16()` 改成 byte-domain `off[26:0]`

### 3.3 DDR memtest address stride

修改：

- [icache_pipeline_top.v](C:/cpu_design/icache_pipeline_top.v:1488)

修正前：

- memtest 直接測 `app_addr = 0/1/2/3`

修正後：

- memtest 用真正相鄰 burst 的地址
- 以 `16 bytes` 為間距測 `0/16/32/48`

## 4. 這次 debug 中很重要的附帶修正

### 4.1 MIG `sys_rst` 極性

之前曾經出現：

- `init_calib_complete` 行為異常
- 某些 reset 相關 LED 只有在按 reset 時閃一下

原因是：

- MIG `sys_rst` 極性一度接反

這件事之後已修正，否則後面的 bootloader debug 會全部失真。

### 4.2 bootloader 內部 RX buffering

曾修正：

- bootloader 在等待 `app_rdy/app_wdf_rdy` 時缺少足夠 RX 緩衝

後來已加入 FIFO，並且用 stall testbench 驗證：

- [uart_bootloader_stall_tb.v](C:/cpu_design/uart_bootloader_stall_tb.v)

這不是最後根因，但這個修正是必要的，否則長 payload 會在 MIG backpressure 時掉 byte。

### 4.3 `uart_send_mem.py` 互動模式

修改：

- [uart_send_mem.py](C:/cpu_design/uart_send_mem.py:56)

新增：

- `--interactive`

用途：

- 送完 `.mem` 後直接保持 `COM` 開啟
- 持續顯示板子回傳
- 把鍵盤輸入直接送到 UART

因此現在：

- 不需要 `Tera Term`
- 也不需要在 `--listen` 結束後再另外找 terminal 送指令

## 5. 現在建議的實際操作方式

### 5.1 smoke test

```powershell
python uart_send_mem.py --port COM7 --baud 115200 --mem TEST_FILES/mem_uart_smoke.mem --delay 3.0 --preamble 4096 --listen --listen-seconds 10
```

預期：

- 持續看到很多 `U`

### 5.2 遊戲互動

```powershell
python uart_send_mem.py --port COM7 --baud 115200 --mem TEST_FILES/mem_game.mem --delay 3.0 --preamble 4096 --interactive
```

預期：

- 看到棋盤
- 看到 `Player A move (row col):`
- 之後可直接輸入：
  - `11`
  - `23`
  - `45`

### 5.3 什麼時候需要重新載入 `.mem`

只在以下情況需要：

1. 重新 program bitstream
2. 按板子 `RESET`
3. 想換另一個 `.mem`
4. 板子跑飛，需要重新從 bootloader 開始

以下情況不需要重新載入：

1. 遊戲正在跑，你只是在下下一步
2. 程式已經載好，只是等待 UART 輸入

## 6. `--listen` 和 `--interactive` 的差別

`--listen`

- 只會接收板子輸出
- 不會把你鍵盤輸入送進 UART
- 適合一次性 smoke test 或觀察啟動輸出

`--interactive`

- 送完 `.mem` 後保持 COM 開啟
- 持續顯示板子輸出
- 同時把鍵盤輸入送到 UART
- 適合 `game.c` 這種需要互動輸入的程式

## 7. 現在保留的 LED 診斷

目前保留 debug LED 是合理的，因為它們在這次 bring-up 中有實際價值。

### 7.1 pre-sync

- `H17` = `init_calib_complete`
- `K15` = `ui_clk` 域看到 UART edge
- `N14` = `sync seen`
- `R18` = raw UART RX edge
- `U16` = `clk_wiz_locked`
- `V16` = `rst_n_int`
- `T15` = DDR multi-address memtest overall pass
- `U14` = `ui_clk` heartbeat
- `T16/V15/V14/J13` = memtest `addr0/1/2/3`

### 7.2 sync 後但 `boot_done` 前

- `K15` = verify beat0 word0 correct
- `N14` = verify beat0 full 128-bit exact match
- `R18` = verify beat0 word1 correct
- `V17` = verify beat0 仍等於 memtest addr0 舊資料
- `U16` = verify beat0 word2 correct
- `V16` = verify beat0 word3 correct
- `T15` = memtest overall pass
- `U14` = heartbeat
- `T16` = verify beat0 為 32-bit word order reverse
- `V15` = verify beat0 為 per-word byte reverse
- `V14` = verify beat0 為 full byte reverse
- `V12` = verify read request seen
- `V11` = verify read response seen
- `J13` = payload 第 4 個 32-bit word correct
- `U17` = `boot_done`

### 7.3 `boot_done` 後

runtime mode 會切成 CPU/記憶體/uart 診斷。

這些燈目前建議保留，因為之後如果再出問題，可以很快分辨：

- DDR 初始化問題
- bootloader 沒抓到 sync
- DDR verify 失敗
- CPU 沒跑
- UART MMIO/TX 沒動

## 8. 這次最重要的經驗

1. `ddr2_test.v` pass 不代表整條 boot path 正確
   - 它只能證明單一地址、固定資料的 write/read 沒問題
   - 它不能保證串流寫入、相鄰地址、CPU 真正取指都正確

2. 一定要做 cross-address memtest
   - 單地址 memtest 很容易假 pass

3. UART boot 成功與否，不能只看 `sync`
   - 要看 verify readback

4. `uart_send_mem.py --listen` 不是互動 terminal
   - 如果程式需要輸入，請用 `--interactive`

5. 不要在沒有 reset 的情況下直接假設新 `.mem` 會覆蓋舊程式並立刻生效
   - bootloader 是開機流程的一部分
   - reset / reprogram 後再重新下載最穩

6. 目前保留 LED debug 是值得的
   - 在 bring-up 階段，板上 sticky 診斷比純 console 猜測更有效

## 9. 之後若要收斂成正式版

等整條路徑穩定後，可考慮：

1. 保留一組最小 LED
   - `DDR init done`
   - `boot_done`
   - `core alive`
   - `UART active`

2. 把現在這組完整 LED 用 parameter 包起來
   - 例如 `DEBUG_LEDS_EN`

3. 把 bring-up 專用 smoke program、testbench、額外 verify 診斷收斂成可切換模式

