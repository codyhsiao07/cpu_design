# RTOS Smoke Bring-Up

This tree is the active RTOS software path for the RV32 core.

It intentionally keeps only the project-specific pieces:

- `config/FreeRTOSConfig.h`
- `src/startup.S`
- `src/main.c`
- `src/uart.c`
- `src/freertos_hooks.c`
- `src/minilibc.c`
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
