# Memory Map Report

## 1. CPU 可見位址空間

### DDR2 主記憶體
- 範圍：`0x8000_0000 ~ 0x87FF_FFFF`
- 大小：`128 MiB`
- 用途：程式碼、全域資料、heap、stack

### DDR2 Alias
- 範圍：`0x0000_0000 ~ 0x07FF_FFFF`
- 對應到：`0x8000_0000 ~ 0x87FF_FFFF`
- 例如：
  - `0x0000_1000` 等價於 `0x8000_1000`

### MMIO 區
- 範圍：`0x4000_0000 ~ 0x4000_FFFF`
- 大小：`64 KiB`
- 用途：外設控制，不是一般 RAM

## 2. UART MMIO Register

- `0x4000_0000`：UART TX DATA
  - 寫入 1 byte，送出一個字元
- `0x4000_0004`：UART TX STATUS
  - bit0 = `tx_ready`
- `0x4000_0008`：UART RX DATA
  - 讀取低 8 bit 為收到的字元
  - 讀一次會把目前資料取走
- `0x4000_000C`：UART RX STATUS
  - bit0 = `rx_valid`
  - bit1 = `rx_overrun`

## 3. Boot Flow

- `BOOT_ADDR = 0x8000_0000`
- `RESET_PC  = 0x8000_0000`

流程：
1. PC 用 `uart_send_mem.py` 傳送 `.mem`
2. `uart_bootloader` 經由 UART 收資料
3. 透過 MIG app write 寫入 DDR2
4. 寫入完成後 CPU 從 `0x8000_0000` 開始執行

## 4. Cache 容量（正式版）

- I$：`64 KiB`
- D$：`128 KiB`
- L2：`256 KiB`

如果開 `FAST_SYNTH` / `FAST_SIM`，容量會縮小以加快合成或模擬。

## 5. UART 腳位

目前板級 XDC 使用板載 USB-UART：
- `uart_rx_i -> C4`
- `uart_tx_o -> D4`

不需要外接 USB-TTL 模組。

## 6. 時鐘說明（目前架構）

- 不再需要額外的 top-level `clk_ref_i` 腳位
- `board_top.v` 只接收板載 `100 MHz` 的 `sys_clk_i`（`E3`）
- `clock_bridge.v` 會在 FPGA 內部產生：
  - 核心與 MIG `sys_clk_i` 使用的 100 MHz 時鐘
  - MIG 使用的 200 MHz `clk_ref_i`
- 目前使用的 MIG 配置為：
  - `System Clock = No Buffer`
  - `Reference Clock = No Buffer`

也就是：
- 不需要外接時鐘模組
- 內部再產生 MIG 需要的 `clk_ref_i`

補充：
- MIG XDC 不再負責 `sys_clk_i` 的 pin/clock 約束
- 這部分由板級 XDC 另外設定

## 7. 目前 `game/game.c` 的實際程式配置

依 [game.map](/c:/cpu_design/build_os/game.map) 與 [link_ddr.ld](/c:/cpu_design/tools/link_ddr.ld)，目前 `game/game.c` 連結後的配置如下：

- `.text`：`0x8000_0000 ~ 0x8000_08AE`
  - 含 `_start` 與 `main`
- `.rodata`：接在 `.text` 之後
  - 目前字串常量落在 `0x8000_0828` 開始
- `.data`：目前幾乎為空
  - 起始仍在 `0x8000_08AF`
- `.bss`：`0x8000_08B0 ~ 0x8000_08C8`
  - 目前大小 `0x19`
- `__global_pointer$`：`0x8000_10AF`
- `__stack_top`：`0x8007_FFFC`

這代表：

- 目前 `game/game.c` 的程式碼與資料段確實是分開排的
- 正常情況下，I$ 主要碰 `.text/.rodata`
- D$ 主要碰 `.data/.bss/stack`

但這是「連結配置」造成的分段，不是硬體保證的 I$/D$ 專用地址區。

也就是說：

- 一般情況下 I$ 與 D$ 不太會碰到同位址
- 但如果軟體主動寫入可執行區、做自修改程式、或把資料當指令執行，仍然可能碰到同位址

## 8. C 程式可直接使用的定義

```c
#define DDR_BASE        0x80000000u
#define UART_TX_DATA    (*(volatile unsigned int *)0x40000000u)
#define UART_TX_STATUS  (*(volatile unsigned int *)0x40000004u)
#define UART_RX_DATA    (*(volatile unsigned int *)0x40000008u)
#define UART_RX_STATUS  (*(volatile unsigned int *)0x4000000Cu)
```
