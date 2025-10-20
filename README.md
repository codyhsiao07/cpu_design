# RV32I Core and Cache System

## Overview
This repository contains a five-stage RV32I processor core plus an integrated instruction/data cache subsystem, reusable SRAM model, and a collection of self-checking testbenches. Most source files are written in Verilog-2001 with positional port connections to match course or lab constraints.

## Top-Level Builds
- `final_top.v` - Minimal wrapper that instantiates `rv32i_core_mem_top` with positional ports. Intended as the chip-level integration point that exposes write-back and memory error observability.
- `rv32i_core_mem_top.v` - Primary core build. Wires the IF/ID/EX/MEM/WB pipeline with caches and the memory bridge (`mem_cache_top`) so both instruction and data paths go through the cache/SRAM subsystem. Exposes commit and memory error signals for verification.
- `temp/top.v` - Earlier `rv32i_core_top` version that drives bare IMEM/DMEM handshake ports (no caches). Useful for simpler memory models.

## Pipeline Stages
- `IF.v` - Program counter (`pc`) block with stall and redirect handling for instruction fetch.
- `ID.v` - Register file (`regfile`) and decode logic (`id_stage`) that produce operands, immediates, and control signals.
- `EX.v` - Execute stage (`ex_stage`) implementing the ALU, branch/jump target calculation, and redirect request generation.
- `MEM.v` - Memory stage (`mem_stage`) that aligns load/store accesses, tracks outstanding transactions, and handshakes with the data cache bridge.
- `WB.v` - Write-back stage (`wb_stage`) that finalizes register writes and provides optional forwarding taps.

## Pipeline Registers
- `IFID_register.v` - `if_id_reg`, the IF/ID pipeline register with stall/flush behavior and an injected NOP on flush.
- `IDEX_register.v` - `id_ex_reg`, latching ID outputs (operands, control bits, and qualifiers) into the EX stage.
- `EXMEM_register.v` - `ex_mem_reg`, transferring EX results and control to MEM while handling stalls and flushes.
- `MEMWB_register.v` - `mem_wb`, the MEM/WB register with a built-in write-back mux and stall/flush handling.

## Hazard and Control Helpers
- `forward_unit.v` - Selects between original register values, MEM-stage data, and WB-stage data to feed the EX operands, giving priority to freshest results.
- `hazard_unit.v` - Central hazard detector that manages load-use bubbles, generic RAW hazards without forwarding, MEM back-pressure, and IF fetch stalls.
- `bp_static_nt.v` - Static not-taken branch predictor used for observability (PC still follows sequential fetch, but mispredict pulses are tracked).

## Cache and Memory Subsystem
- `icache.v` - 16 KB, 4-way set-associative instruction cache with pseudo-LRU replacement. Presents a simple fetch/stall interface and reads from combinational backing memory.
- `dcache.v` - 32 KB, 2-way data cache with write-back/write-allocate policy, a tiny store buffer, and a cache-line refill interface toward SRAM.
- `MEM_bridge.v` - `cache_bridge_mem` wrapper that links `mem_stage` word-level transactions to the cache/SRAM complex, including out-of-range detection and error flagging.
- `MEM_top.v` - `mem_cache_top` integration: glues `mem_stage`, `cache_bridge_mem`, and `top_cache_sram`, tracks alignment faults, and exposes error pulses to the core.
- `mem_guard.v` - Simple combinational guard that enforces region protections (TEXT/DATA/STACK) and strobe masking before requests reach the caches.
- `top_cache.v` - `top_cache_sram`, a top-level that connects `icache` and `dcache` to a unified SRAM, instantiating `mem_guard` and ferrying cache-line traffic.
- `sram_2mb.v` - Parameterized 2 MiB dual-port SRAM model (instruction combinational port plus cache-line data port). Default address window starts at `0x8000_0000` for standalone sims.
- `sram_test_final.v` - Alternate copy of `sram_2mb` with default base address `0x0000_0000`, used in course deliverables that expect a zero-based memory map.

## Testbenches
- `temp/final_top_tb.v` - `tb_top_rv32i_inline`, a simple top-level core testbench that checks write-back activity and halts when register x4 reaches the programmed pass signature.
- `MEM_top_full_tb.v` - `tb_mem_edge_final`, a wide-coverage `mem_cache_top` testbench with directed cases for alignment, region protection, store/load ordering, and timeouts.
- `temp/MEM_top_tb.v` - `tb_mem_cache_top`, earlier self-checking bench for `mem_cache_top` focusing on basic load/store flows and error paths.
- `temp/tb_mem.v` - `tb_mem_full`, another variant that shares the same device-under-test but uses explicit parameter overrides and helper tasks for scenario scripting.
- `tp_cache_top.v` - `tb_top_cache_sram_final`, drives `top_cache_sram` directly with fetch and data traffic to exercise guard behavior and cache refill paths.
- `replaced_and_store_file/teststorage.v` - Archived copy of `tb_top_cache_sram_final`, retained for reference alongside newer benches.

## Additional Design Utilities
- `replaced_and_store_file/cpu_store_guard.v` - Prior CPU-side guard module that blocked TEXT writes before they reached the data cache.
- `replaced_and_store_file/sram_guard.v` - Legacy wrapper (`sram_2mb_guard`) providing stricter write filtering around `sram_2mb`.
- `replaced_and_store_file/top_cache_sram.v` - Earlier revision of `top_cache_sram` with optional memory initialization support.

## Notes
- `.gitattributes` sets text normalization for the repository.
- Many modules rely on positional port connections to satisfy toolchain restrictions; keep the ordering in sync when reusing blocks.
- When swapping between SRAM models, ensure the base address matches the program image you load into simulation.
