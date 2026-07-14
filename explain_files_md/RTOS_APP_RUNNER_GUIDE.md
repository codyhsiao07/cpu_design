# 通用 RTOS 應用程式上板工具

這套工具使用兩階段流程：

1. 自動編譯並上傳短版 FreeRTOS preflight。
2. preflight 驗證 scheduler、timer tick、兩個 task、queue、UART 與基本記憶體存取。
3. 只有收到 `RTOS_PREFLIGHT_PASS`，preflight 才要求硬體重新開啟 UART bootloader。
4. PC 等 bootloader 就緒後，自動上傳所選的目標 `.mem`。
5. 已知 profile 會再等待目標程式的 UART marker，確認目標確實啟動。
6. 若收到 FAIL、trap、assert 或等待逾時，流程會停止。

## 第一次使用前

bootloader 的重新接收功能位於 `uart_bootloader.v` 與 `icache_pipeline_top.v`，因此必須使用這兩個檔案重新 Generate Bitstream，並把新 bitstream 上板一次。

目前無 VGA 的 `board_top` 專案可用下列指令重建及燒入：

```powershell
.\tools\build_board_bitstream.ps1
.\tools\program_board_bitstream.ps1
```

之後切換 RTOS `.mem` 不需要重新產生 bitstream。執行另一個程式前，只要按 Nexys A7 的 `CPU RESET` 鍵讓系統回到 bootloader；不必關閉板子，也不必重新燒 FPGA。

## 最常用指令

選擇已經存在的 `.mem`：

```powershell
.\tools\run_rtos_app.ps1 -Port COM5 -Mem .\build_verify_rtos_fixed\rtos_smoke.mem
```

選擇內建 app profile，工具會先編譯它：

```powershell
.\tools\run_rtos_app.ps1 -Port COM5 -App smoke
```

目前內建 profile：

- `smoke`
- `console`（UART 互動式正式應用程式）
- `preflight`（內部診斷用途；執行後會再次回到 bootloader）
- `vga_demo`
- `vga_queue_demo`

自訂 RTOS 應用程式：

```powershell
.\tools\run_rtos_app.ps1 `
  -Port COM5 `
  -App sensor `
  -MainSource .\OS\rtos\src\main_sensor.c `
  -ExtraSource .\OS\rtos\src\sensor.c
```

`MainSource` 應提供 `main()`；FreeRTOS kernel、startup、UART、hooks、linker script 與 `.mem` 轉換會由建置器自動加入。

自訂程式也可提供啟動完成 marker，讓工具自動確認目標程式：

```powershell
.\tools\run_rtos_app.ps1 -Port COM5 -Mem .\app.mem -TargetMarker APP_READY
```

## 監看模式

預設 `interactive`：目標程式上傳後持續顯示 UART，並把鍵盤輸入送到板子。按 `Ctrl+C` 離開終端，不會重設 FPGA。

只監看 UART，最後一筆輸出後再等 30 秒：

```powershell
.\tools\run_rtos_app.ps1 -Port COM5 -Mem .\app.mem -Monitor listen -ListenSeconds 30
```

上傳完成後直接關閉 COM：

```powershell
.\tools\run_rtos_app.ps1 -Port COM5 -Mem .\app.mem -Monitor none
```

保存 UART 原始紀錄：

```powershell
.\tools\run_rtos_app.ps1 -Port COM5 -Mem .\app.mem -Log .\build_rtos_apps\last_uart.log
```

## 不接板子的檢查

下列指令會編譯 preflight 與目標 app、檢查兩個 `.mem`，但不開啟 COM：

```powershell
.\tools\run_rtos_app.ps1 -Port COM5 -App smoke -DryRun
```

preflight 的 CPU/FreeRTOS RTL 模擬：

```powershell
.\tools\run_rtos_preflight_sim.ps1
```

PC 協調器的成功、FAIL 與 timeout 單元測試：

```powershell
python -m unittest .\tools\test_rtos_board_runner.py -v
```

## 預設通訊參數

- UART：`COM5` 由命令指定，baud 預設 `115200`
- 初次等待 DDR/bootloader：`5.0` 秒
- 每次同步 preamble：`8192` 個 `0x55`
- preflight 等待上限：`20` 秒
- preflight 無回覆時自動上傳：最多 `2` 次
- preflight PASS 後切換等待：`5.0` 秒（實板驗證可避免過早傳送目標映像）
- 目標程式等待上限：`20` 秒
- 目標程式無回覆時自動 reload 並上傳：最多 `2` 次

工具開始時會先送出低速 `reload`，讓仍在執行的 RTOS Console 自動回到 bootloader；bootloader 已在等待時會忽略這些非同步字元。通常不需要調整預設值。若換了板子時鐘或 UART baud，可透過 `-Baud`、`-StartupDelay`、`-Preamble`、`-PreflightTimeout` 與 `-TargetDelay` 覆寫；特殊應用不允許啟動命令時可加上 `-SkipAutoReload`。

## 故障判斷

- 自動重傳後仍看不到 `RTOS_PREFLIGHT_BEGIN`：確認已換成支援 host-sync recovery 的新 bitstream、COM 編號正確；最後再按一次 `CPU RESET` 重試。
- `LOAD segment with RWX permissions` 是目前 linker script 的權限警告，不是 preflight timeout 的原因，也不會阻止映像產生。
- 出現 `RTOS_PREFLIGHT_FAIL`：工具會中止，不會傳目標程式；保留 UART log 再檢查原因。
- preflight PASS 後又看到 preflight 重新啟動：通常代表 FPGA 仍是舊 bitstream，bootloader 沒有進入第二次接收。
- COM 被占用：先關閉 PuTTY、Tera Term、Arduino Serial Monitor 或另一個上板工具。
