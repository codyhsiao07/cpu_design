# RTOS VGA Demo Notes

## Known-good path

- `rtos_smoke.mem` passes on hardware, so FreeRTOS tick interrupt, `vTaskDelay()`, queues, and context switching are working.
- The VGA RTOS demo works when it follows the same scheduler path:
  - use the stock FreeRTOS RISC-V `portASM.S`
  - keep `mtime/mtimecmp` enabled
  - use `vTaskDelay()` inside tasks
  - draw through the existing `game/vga_fb.c` API

## What went wrong

Earlier VGA demo attempts were unstable because they diverged from the proven smoke path:

- The demo used a custom 32-bit framebuffer helper instead of the project VGA helper. Existing VGA programs use `vga_fb_fill_rect4()`, which writes the framebuffer as 16-bit packed 4-pixel words.
- The demo temporarily disabled `mtime` and relied on cooperative `taskYIELD()`. That path did not behave like the verified `rtos_smoke` workload.
- Several debug helpers, large unused buffers, and temporary scheduler trace hooks made the failure harder to isolate.

## Current demo shape

`OS/rtos/src/main_vga_demo.c` is intentionally small:

- three FreeRTOS tasks: left, middle, right
- each task updates only its own VGA panel
- each task logs a frame counter over UART every four frames
- all task switching is driven by `vTaskDelay()`

Expected UART pattern:

```text
[VGA] task=L start
[VGA] task=M start
[VGA] task=R start
[VGA] tick=... task=L frame=...
[VGA] tick=... task=M frame=...
[VGA] tick=... task=R frame=...
```
