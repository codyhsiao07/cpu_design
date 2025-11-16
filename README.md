# RV32I Core + Cache + UART (Basys3-Ready)

This repository contains a five-stage RV32I pipeline with instruction/data caches, a parameterized SRAM model, a simple memory-mapped UART, and FPGA glue for the Digilent Basys3 board. All RTL is Verilog‑2001 with positional port connections to satisfy lab constraints.

## Quick Start
1. **Build your program** → produce a `$readmemh`-compatible file (e.g. `program.mem`) with addresses starting at `0x0000_0000` and total size < 225 KiB.
2. **Hook the top** → instantiate `top_rv32i` or `basys3_top` with `.SRAM_INIT_FILE("program.mem")`. Simulation benches can override the same parameter.
3. **Vivado flow** → use `basys3_top.v` as the FPGA entry point and `led.xdc` for constraints (100 MHz clock on W5, BTN_C reset, USB‑UART pins A18/B18, LEDs).
4. **UART console** → connect to the Basys3 USB serial port at 115200/8N1. Writes to `0x1000_0000` become UART TX bytes; STATUS at `0x1000_0004` bit0 reports `tx_ready`.
5. **LEDs** → LD0–LD14 show the most recent write-back value (`wb_wdata[14:0]`), LD15 mirrors `mem_access_err`. BTN_C provides reset—press once to restart firmware.

## Top-Level Builds
- `basys3_top.v` – FPGA wrapper (clock, reset, UART, LEDs). Parameter `SRAM_INIT_FILE` points to the program hex.
- `top_rv32i.v` – Minimal wrapper around `rv32i_core_mem_top` with configurable BRAM init file, UART baud, and MMIO window.
- `rv32i_core_mem_top.v` – Full pipeline + caches + UART bridge. Exposes write-back taps and memory error flag for observability.

## Pipeline & MMIO Highlights
- Classic IF/ID/EX/MEM/WB with forwarding (`forward_unit.v`) and hazard control (`hazard_unit.v`).
- `MEM_top.v` + `MEM_bridge.v` glue the MEM stage to caches and SRAM. The bridge also decodes a UART MMIO region (`0x1000_0000..0x1000_00FF`).
- `uart_mmio.v` – lightweight transmit-side UART; STATUS bit0 indicates `tx_ready`, DATA register puts bytes on the USB‑UART TX pin.
- `sram_test_final.v` – SRAM model with macro-driven test programs (`SRAM_TB_*` defines). `SRAM_TB_UART_SMOKE` now emits ASCII “PASS” and sets x4=17 to satisfy the main TB.

## Testbenches
- `final_top_tb.v` – main top-level TB. Supports plusargs, UART byte tracing, and PASS/FAIL checks (x4==17). Use `+define+SRAM_TB_UART_SMOKE` to run the UART smoke program quickly.
- `MEM_top_full_tb.v`, `temp/MEM_top_tb.v`, `temp/tb_mem.v` – standalone benches for the MEM/cache subsystem with directed scenarios (alignment, region protection, error handling).

## Notes & Tips
- Most modules use positional ports—double-check ordering when instantiating.
- When swapping BRAM images, update the `SRAM_INIT_FILE` parameter and add the `.mem` to your Vivado project as a Memory Initialization File.
- UART RX is currently a stub (held high). Only TX is implemented; receiving can be added later inside `uart_mmio.v` if needed.
- LED[15] lights up when `mem_access_err` is asserted (alignment faults, illegal region, etc.). In a healthy run this LED stays off.

## Typical Basys3 Run
1. Generate `program.mem` (e.g. `riscv32-unknown-elf-objcopy -O verilog program.elf program.mem`).
2. In `basys3_top.v`, instantiate `top_rv32i #(.SRAM_INIT_FILE("program.mem"))`.
3. Vivado → add all RTL + hex + `led.xdc`, synthesize, implement, bitstream.
4. Program Basys3; open a serial terminal at 115200/8N1 to observe UART output and watch LEDs for quick debugging.

Enjoy hacking on the core! PRs for full UART RX, deeper BRAM loaders, or additional FPGA wrappers are welcome.
