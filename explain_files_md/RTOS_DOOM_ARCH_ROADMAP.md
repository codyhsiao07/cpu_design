# CPU Architecture Assessment And Roadmap

## 1. Current Assessment

目前這個專案已經不是只有「能跑指令」的 CPU，而是一個有平台雛形的系統。

你們現在已經具備的主線能力：

- 5-stage pipeline core
- RV32I + RV32M
- I-Cache / D-Cache / Unified L2
- DDR2 main memory through MIG
- UART bootloader
- UART MMIO
- VGA subsystem
- basic branch predictor

對應主線檔案：

- Top: `board_top.v`, `board_top_vga.v`
- Core top: `icache_pipeline_top.v`
- Decode / EX: `ID.v`, `EX.v`
- Cache: `icache.v`, `dcache.v`, `L2_cache.v`
- Boot: `uart_bootloader.v`
- VGA: `vga_subsystem.v`

所以如果目標只是：

- 裸機程式
- 小型遊戲
- UART / VGA demo
- 課程專題展示

這個架構已經夠完整，也已經有不錯的系統整合度。

但是如果最後目標是：

- 跑 RTOS
- 做更大型的遊戲平台
- 嘗試 DOOM

那目前還不能算「系統架構完整」，因為還缺少特權、例外、中斷、裝置平台這些基礎設施。

## 2. What Is Still Missing

### 2.1 For RTOS

RTOS 最核心的需求不是乘除，而是「控制系統」。

目前最明顯的缺口：

- CSR 架構未完整
  - 需要至少補 `mstatus`, `mie`, `mip`, `mtvec`, `mepc`, `mcause`, `mscratch`
- trap / exception 機制未完整
  - 需要支援 `ecall`, `ebreak`, illegal instruction, misaligned access, memory fault
- interrupt controller / timer 不完整
  - 需要至少有 machine timer interrupt
  - 建議做 `mtime` / `mtimecmp`
- privilege model 不完整
  - 最少先完成 machine mode trap flow
- atomic / synchronization 能力不足
  - 後續如果要做更完整 RTOS 或 lock，建議補 A extension，或至少先定義單核 critical section 方法

### 2.2 For DOOM

DOOM 的主要障礙不是 ALU，而是平台週邊與軟體介面。

目前最明顯的缺口：

- 輸入裝置不足
  - 建議補 PS/2 keyboard
  - 如果要更完整可補 PS/2 mouse
- 儲存裝置不足
  - DOOM 需要載入 WAD / asset
  - 建議補 SD card or SPI flash file loading
- 音效輸出不足
  - 至少要有 PWM / simple audio path
- 軟體平台不足
  - 需要較穩定的 libc 子集、memory allocator、timer API、input API
- framebuffer / graphics API 可再強化
  - page flip
  - block copy / blit
  - 8-bit indexed color path

## 3. Suggested Architecture Extension Priority

不建議一開始就往 Linux / MMU / S-mode 衝。那是另一個量級。

比較務實的優先順序如下。

### Phase 1: Make It RTOS-Ready

目標：先讓系統具備基本作業系統控制能力。

建議項目：

1. CSR 最小集合
   - `mstatus`
   - `mie`
   - `mip`
   - `mtvec`
   - `mepc`
   - `mcause`
   - `mscratch`
2. trap / exception flow
   - illegal instruction
   - `ecall`
   - `ebreak`
   - load/store misaligned
   - memory access fault
3. machine timer
   - `mtime`
   - `mtimecmp`
   - timer interrupt
4. software-visible interrupt API
5. simple trap handler test programs

完成這一階段後，可以開始評估：

- FreeRTOS port
- cooperative / preemptive scheduler
- task switch

### Phase 2: Make It DOOM-Ready

目標：把平台補到能支撐大型裸機遊戲。

建議項目：

1. PS/2 keyboard driver
2. SD card / SPI storage driver
3. simple filesystem loader or raw asset loader
4. audio output
5. graphics API abstraction
6. profiling / frame timing tools

### Phase 3: Performance And Robustness

目標：讓大型程式與遊戲跑得更穩、更快。

建議項目：

- branch predictor 升級
  - BTB
  - optional RAS
- cache optimization
  - non-blocking behavior
  - write buffer
  - better flush / fence behavior
- memory performance tooling
- optional DMA-like copy engine for VGA / framebuffer work

## 4. Recommended Final Direction

如果你們的最終展示想要「看起來很完整」，最合理的路線是：

### Route A: RTOS First

適合想強調 CPU / OS / architecture 能力。

優點：

- 技術完整度高
- 比較符合 CPU 專題的深度
- 可以展示 scheduler, timer interrupt, context switch

缺點：

- 視覺效果不一定最直觀

### Route B: DOOM-Platform First

適合想強調成果展示與互動效果。

優點：

- 展示效果強
- 成果容易被理解

缺點：

- 會更依賴裝置驅動與資產載入
- 比較容易被軟體平台問題卡住

### Best Practical Recommendation

最建議的路線是：

1. 先把 RTOS 所需的 machine trap / timer 做好
2. 再補 PS/2 + storage + audio
3. 最後再挑戰 DOOM 或類似的大型應用

原因：

- 這樣會先把架構基本盤補完整
- 後面做大型應用時，除錯能力也會更好

## 5. Suggested Team Split

因為你們是分工開發，建議不要用「一人做 CPU、一人做軟體」這種過粗分法。

比較好的切法是依照系統邊界拆。

### Option A: 2-Person Split

#### Person A: Core And Privileged Control

負責：

- pipeline control
- CSR
- trap / exception
- interrupt flow
- timer / machine-mode support
- verification for core control path

主要檔案範圍：

- `ID.v`
- `EX.v`
- `hazard_unit.v`
- `icache_pipeline_top.v`
- 新增 CSR / timer / trap modules
- mul/div / exception related TB

交付成果：

- `ecall` / exception 可工作
- timer interrupt 可進 trap handler
- context switch 所需暫存器流程可驗證

#### Person B: Platform And Runtime

負責：

- UART boot flow
- VGA subsystem
- PS/2 / SD / audio driver
- game / demo / runtime support
- build scripts and board bring-up

主要檔案範圍：

- `uart_bootloader.v`
- `vga_subsystem.v`
- `board_top_vga.v`
- `game/`
- `tools/`
- 新增 peripheral modules

交付成果：

- keyboard input
- asset loading
- graphical demo / game framework
- board-level validation

### Option B: 3-Person Split

如果是 3 人，分工會更漂亮。

#### Person A: Core ISA And Privileged Architecture

負責：

- RV32I/M correctness
- CSR
- trap / exception
- interrupt semantics
- ISA-level verification

#### Person B: Memory System And Performance

負責：

- I$
- D$
- L2
- branch predictor
- memory consistency / flush / fence behavior
- performance benchmark and stress TB

#### Person C: Platform And Software

負責：

- UART boot
- VGA
- keyboard / storage / audio
- bare-metal runtime
- RTOS port or DOOM platform port

## 6. Suggested Deliverable Matrix

| Area | Minimum Deliverable | Better Deliverable | Stretch Goal |
|---|---|---|---|
| Core control | trap + exception | timer interrupt | full RTOS-ready machine mode |
| Memory system | stable I$/D$/L2 | better branch prediction | partial non-blocking cache |
| Platform I/O | UART + VGA | PS/2 + SD | audio + game-friendly runtime |
| Software | bare-metal demos | FreeRTOS bring-up | DOOM-like application |

## 7. Suggested Milestones

### Milestone 1

- trap entry works
- timer interrupt works
- simple exception test passes

### Milestone 2

- context switch demo works
- simple scheduler demo works
- UART + VGA still stable under interrupt

### Milestone 3

- keyboard input works
- storage load works
- larger application can load assets

### Milestone 4

- DOOM-like rendering demo or actual DOOM port attempt

## 8. Final Conclusion

結論很直接：

- 你現在的 CPU 架構已經有相當完整的「裸機系統平台骨架」
- 但如果目標是 RTOS 或 DOOM，還不能算完全完整
- 下一步最值得做的不是再堆 ALU 功能，而是補上：
  - privileged control
  - trap / interrupt
  - timer
  - input / storage / audio platform

如果只能選一個最重要的下一步：

**先完成 machine-mode trap + timer interrupt。**

這會讓你們整個專案從「能跑 demo 的 CPU」進化成「可承載系統軟體的平台」。
