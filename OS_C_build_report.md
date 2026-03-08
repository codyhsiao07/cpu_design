# C 程式編譯與上板前驗證操作報告

本文件說明如何在本專案中，把 C 程式編譯成 RV32I 映像，並轉成可供模擬或 UART 載入的 `.mem` 檔。

## 1. 目前 Makefile 的預設行為

目前 [Makefile](/c:/cpu_design/Makefile) 的預設值是：
- `SRC=game/game.c`
- `OUT_NAME=game`
- `MEM_OUT=TEST_FILES/mem_game.mem`
- `APP_DEFINES=-DGAME_USE_UART`

所以直接執行：

```powershell
make
```

等同於：

```powershell
make mem
```

輸出：
- `build_os/game.elf`
- `build_os/game.bin`
- `build_os/game.map`
- `TEST_FILES/mem_game.mem`

## 2. 常用目標

```powershell
make help
make print-config
make elf
make bin
make mem
make disasm
make run-sim
make uart-mmio-tb
make clean
```

## 3. 如果要改編別的 C 檔

例如改編 `OS/main.c`：

```powershell
make mem SRC=OS/main.c OUT_NAME=os MEM_OUT=TEST_FILES/mem_os.mem APP_DEFINES=
```

這樣會產生：
- `build_os/os.elf`
- `build_os/os.bin`
- `build_os/os.map`
- `TEST_FILES/mem_os.mem`

## 4. 建議的日常流程

### 編 `game/game.c`

```powershell
make clean
make
```

### 看目前設定

```powershell
make print-config
```

### 跑 UART MMIO 專用回歸

```powershell
make uart-mmio-tb
```

## 5. `.mem` 後續用途

產生的 `.mem` 可用於：
- 主模擬 `icache_pipeline_tb`
- 透過 `uart_send_mem.py` 載入到 DDR2

例如：

```powershell
python uart_send_mem.py --port COM5 --baud 115200 --mem TEST_FILES/mem_game.mem
```

## 6. 注意事項

- linker 可能會出現 `RWX permissions` 警告，但通常不會阻止 `.mem` 產生
- 若切換 `SRC`、`APP_DEFINES`、linker script 或啟動碼，請重新建置
- 若 `make` 在 `check-tools` 失敗，先確認：
  - RISC-V toolchain 路徑
  - `python`
  - `objcopy`
  - `objdump`

