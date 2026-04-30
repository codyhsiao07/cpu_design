# Timing Closure 設定說明

本文件整理目前專案在 Vivado 做 implementation 時，較穩定的 timing closure 設定。

## 1. 適用範圍

適用於：
- `board_top.v` 為 top
- 使用 DDR2 MIG 路徑
- 已完成 `synth_1`
- 想先用 implementation directive 提高 timing 收斂機率

## 2. 建議的 Implementation Directive

目前建議使用：
- `Place Design`: `ExtraTimingOpt`
- `Physical Optimization`: `ExploreWithAggressiveHoldFix`
- `Route Design`: `AggressiveExplore`

這組是目前較穩定的設定，不建議全部用 default。

## 3. GUI 設定方式

1. 打開 Vivado 專案
2. `Project Manager -> Settings`
3. 選 `Implementation`
4. 選 `impl_1`
5. 設定：
   - `Place Design` -> `ExtraTimingOpt`
   - `Physical Optimization` -> `ExploreWithAggressiveHoldFix`
   - `Route Design` -> `AggressiveExplore`
6. `OK`
7. `Reset Run impl_1`
8. 重新 `Launch Implementation`

## 4. Tcl 設定方式

```tcl
open_project C:/Users/a0968/project_2/project_2.xpr
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE ExtraTimingOpt [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE ExploreWithAggressiveHoldFix [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
reset_run impl_1
launch_runs impl_1 -jobs 8
```

## 5. `FAST_SYNTH` 的正確設定方式

如果你要用快速版 synthesis：
- 請在 `Synthesis -> Verilog Options -> Verilog Defines` 填：-verilog_define FAST_SYNTH

不要填：
- `-FAST_SYNTH`
- 也不要把它當成 `More Options` 的 positional argument

正確 Tcl：

```tcl
set_property verilog_define {FAST_SYNTH} [get_filesets sources_1]
```

## 6. 什麼情況要重跑 `synth_1`

以下任一項變動後，應先重跑 `synth_1`：
- RTL (`.v`) 改動
- XDC 約束改動
- IP 變更（MIG / Clocking Wizard）
- `FAST_SYNTH` 開關改變

如果只有 implementation directive 改變，而 synthesis netlist 沒變，可以只重跑 `impl_1`。

## 7. Timing 判斷標準

至少要滿足：
- `WNS >= 0`
- `TNS = 0`
- `Setup failing endpoints = 0`

如果 `route_design` 完成但 `WNS < 0`，仍然屬於 `Failed Timing`，不能算 timing 收斂。

## 8. 這份文件不包含的內容

本文件只處理 implementation directive。

不處理：
- MIG 腳位規劃
- Clocking Wizard / `clk_wiz_0.xci` 是否被讀入
- `clk_wiz_0` AutoDisabled 導致的 synthesis 失敗

這些屬於專案 source / IP 設定問題，不是 timing directive 問題。

