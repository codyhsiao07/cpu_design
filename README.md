# CPU 設計專案（RV32I + I$/D$ + L2 + DDR2 MIG）

本專案目前主線是整合式 5-stage RV32I CPU，包含：
- L1 I-Cache：`icache.v`（由 `icache_top.v` 包裝）
- L1 D-Cache：`dcache.v`
- Unified L2 + I/D 仲裁：`L2_cache.v`、`I_D_arbitration.v`
- DDR2 MIG 路徑與 UART boot：`icache_pipeline_top.v`
- 板級整合：`board_top.v`
- 內部時鐘橋接：`clock_bridge.v`

## 1. 目前主線架構

主要維護與驗證路徑：
- Top：`board_top.v`
- Core top：`icache_pipeline_top.v`
- 主測試平台：`icache_pipeline_tb.v`
- 分支重導場景測試：`bp_redirect_scenarios_tb.v`
- UART MMIO 專用測試：`uart_mmio_tb.v`

## 2. 記憶體與外設

- DDR2：由 MIG (`mig`) 提供外部記憶體介面
- UART：
  - `uart_rx_i`：板載 USB-UART 橋接器送入 FPGA
  - `uart_tx_o`：FPGA 輸出到板載 USB-UART 橋接器
- MMIO：
  - `0x4000_0000`：UART TX data
  - `0x4000_0004`：UART TX status
  - `0x4000_0008`：UART RX data
  - `0x4000_000C`：UART RX status

## 3. 時鐘架構（目前）

目前板級時鐘架構如下：
- 板載 `100 MHz` 振盪器接到 top-level `sys_clk_i`
- 使用的 DDR2 MIG 已配置為：
  - `System Clock = No Buffer`
  - `Reference Clock = No Buffer`
  - `InputClkFreq = 100`
- MIG XDC 不再負責 `sys_clk_i` 的 pin/clock 約束，這一段由板級 XDC 處理
- `board_top.v` 內部透過 `clock_bridge.v` 產生：
  - `clk_sys_o`（100 MHz）供核心時脈與 MIG `sys_clk_i` 使用
  - `clk_ref_o`（200 MHz）供 MIG `clk_ref_i` 使用

重點：
- 不需要額外拉一條獨立的 top-level `clk_ref_i` 到板外
- 不需要額外外接時鐘模組
- `clk_ref_i` 是在 FPGA 內部由 `clock_bridge.v` 產生後接進 MIG
- 目前使用的 DDR2 MIG 約束未占用 `E3`、`C4`、`D4`
- 因此可直接使用板載時鐘與板載 USB-UART

## 4. Makefile 快速用法

預設：
- `SRC=game/game.c`
- `OUT_NAME=game`
- `MEM_OUT=TEST_FILES/mem_game.mem`
- `APP_DEFINES=-DGAME_USE_UART`

常用指令：

```powershell
make
make print-config
make uart-mmio-tb
make clean
```

如果要改編別的 C 檔：

```powershell
make mem SRC=OS/main.c OUT_NAME=os MEM_OUT=TEST_FILES/mem_os.mem APP_DEFINES=
```

## 5. 本地回歸現況

近期本地回歸已驗證：
- `make mem`：PASS
- `make uart-mmio-tb`：PASS
- `bp_redirect_scenarios_tb`：PASS
- `icache_pipeline_tb` `TEST=1..27`：PASS
- `TEST=24..27` 多 seed 壓測：PASS

## 6. Vivado 專案注意事項

`constrs_1` 建議至少包含：
- `Nexys-A7-100T-Master.xdc`
- 目前使用的 DDR2 MIG `mig.xdc`
- `clk_wiz_0.xdc`

`sources_1` 應包含：
- RTL 主線檔案（含 `board_top.v`、`icache_pipeline_top.v`、`clock_bridge.v`）
- DDR2 MIG 對應的 `.xci`
- `clk_wiz_0.xci`

注意：
- `clock_interface.v` 若只是你拿來對照 IP 介面的參考檔，不應加入專案
- 如果 `clk_wiz_0.xci` 被 AutoDisabled，`synth_1` 會報 `module 'clk_wiz_0' not found`
