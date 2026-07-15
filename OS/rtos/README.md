# RTOS Smoke Bring-Up

This tree is the active RTOS software path for the RV32 core.

It intentionally keeps only the project-specific pieces:

- `config/FreeRTOSConfig.h`
- `src/startup.S`
- `src/main.c`
- `src/uart.c`
- `src/freertos_hooks.c`
- `src/rtos_heap.c`
- `src/minilibc.c`
- `src/main_platform.c`
- `src/main_lua.c`
- `src/lua_rtos_config.h`
- `src/lua_rtos_port.c`
- `src/lua_rtos_libs.c`
- `src/lua_script_protocol.c`
- `link_ddr.ld`

The FreeRTOS kernel and official RISC-V port are used from the external LTS
checkout:

```text
C:\Users\a0968\Downloads\FreeRTOSv202406.04-LTS\FreeRTOS-LTS\FreeRTOS\FreeRTOS-Kernel
```

Build:

```powershell
powershell -ExecutionPolicy Bypass -File tools\build_rtos_smoke.ps1
```

Simulation smoke test:

```powershell
powershell -ExecutionPolicy Bypass -File tools\run_rtos_smoke_sim.ps1
```

Full platform self-test:

```powershell
powershell -ExecutionPolicy Bypass -File tools\run_rtos_platform_sim.ps1
powershell -ExecutionPolicy Bypass -File tools\run_rtos_app.ps1 -Port COM5 -App platform
```

Hardware performance analysis (RTOS Console):

```powershell
powershell -ExecutionPolicy Bypass -File tools\run_rtos_app.ps1 -Port COM5 -App console
```

Then enter `perf test 100000`, or measure an arbitrary interval with
`perf reset`, the desired commands, and `perf stop`. The 24 x 64-bit MMIO
counter ABI and C API are documented in
`explain_files_md/MMIO_PERFORMANCE_COUNTERS_GUIDE.md`.

Lua 5.4.8 REPL:

```powershell
powershell -ExecutionPolicy Bypass -File tools\run_rtos_lua_sim.ps1
powershell -ExecutionPolicy Bypass -File tools\run_rtos_app.ps1 -Port COM5 -App lua
python tools\rtos_lua_probe.py --port COM5
python tools\run_lua_script.py --port COM5 --file lua_apps\hello.lua
python tools\run_lua_script.py --port COM5 --file lua_apps\guess_number.lua --interactive --timeout-ms 600000 --instruction-limit 5000000
python tools\rtos_lua_script_probe.py --port COM5 --large-bytes 65536
python tools\rtos_lua_game_probe.py --port COM5
```

The Lua profile uses the vendored source in `third_party/lua-5.4.8` and opens
an interrupt-driven UART REPL and multiline script service after the built-in
language/RTOS self-test passes. Scripts are CRC checked and protected by stop,
timeout and instruction limits. Interactive scripts can use `rtos.read_line()`;
the RX task delivers terminal lines through a dedicated FreeRTOS queue.
See `explain_files_md/RTOS_LUA_GUIDE.md` for supported libraries and limits.

Expected UART markers:

```text
[RTOS] boot
[RTOS] scheduler
[RTOS] task=A start
[RTOS] task=B start
[RTOS] tick=... task=A queue=send ...
[RTOS] tick=... task=B queue=recv ...
RTOS_SMOKE_PASS
```
