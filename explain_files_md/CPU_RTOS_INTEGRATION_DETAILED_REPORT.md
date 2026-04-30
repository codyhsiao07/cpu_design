# CPU / RTOS Integration Detailed Report

## 1. Purpose

This document explains, in one place, how the current CPU and RTOS integration works in this project.

The target reader is:

- someone who understands Verilog hardware and pipeline control
- but has not yet worked through a full RTOS software bring-up

The goal is to answer these questions clearly:

- Which files are involved in the RTOS path?
- Which parts belong to hardware, which parts belong to software, and which parts are the bridge between them?
- How does a `.mem` image actually contain FreeRTOS plus the game plus the porting code?
- How does control flow move from reset, to `main()`, to the scheduler, to timer interrupts, to context switches, and back into tasks?
- How is an old bare-metal VGA game converted into an RTOS task?

This report focuses on the **RTOS-relevant path**, not every file in the whole CPU repository.

## 2. High-Level Picture

The current system is not "installing an RTOS" like Windows installs a kernel on a disk.

Instead, the system works like a typical embedded firmware build:

1. The FPGA bitstream contains the hardware system:
   - CPU
   - caches
   - CSR/trap logic
   - machine timer interrupt source
   - UART MMIO
   - VGA MMIO/framebuffer path
   - DDR interface
2. The software image contains:
   - startup code
   - trap entry/exit runtime
   - board support code
   - FreeRTOS port layer
   - FreeRTOS kernel source
   - the application
   - the game engine
3. All of the software above is compiled and linked into **one single firmware image**.
4. That binary is converted to `.mem` and sent into DDR.
5. The CPU starts from DDR and executes that unified image.

So the correct mental model is:

```text
bitstream = hardware platform
.mem      = software firmware image
```

The RTOS kernel is **inside the `.mem` image**, not inside the bitstream.

## 3. Layered Architecture

The current RTOS stack can be viewed as:

```text
Application / Game Layer
  -> freertos_snake_demo.c
  -> Snake_vga.c / vga_fb.c / games_shared_ui.c

FreeRTOS Kernel Layer
  -> tasks.c
  -> list.c
  -> queue.c

FreeRTOS Port / BSP / Trap Layer
  -> port.c
  -> portmacro.h
  -> trap.c
  -> trap_entry.S
  -> rtos_bsp.c

CPU Architectural Support
  -> ID.v (CSR/ecall/ebreak/mret decode)
  -> CSR.v
  -> machine_irq_sources.v
  -> icache_pipeline_top.v

Platform / Hardware
  -> UART MMIO
  -> timer MMIO
  -> VGA path
  -> DDR
  -> board_top_vga
```

## 4. File-by-File Role Summary

### 4.1 Build and memory layout files

`tools/link_ddr.ld`

- Defines the link address.
- Places the whole image in DDR at `0x80000000`.
- Defines where `.text`, `.data`, `.bss`, and `__stack_top` live.
- Makes `_start` the program entry.

Key points:

- `ENTRY(_start)`
- `DDR (rwx) : ORIGIN = 0x80000000, LENGTH = 512K`
- `.text.start` is placed first, so `_start` is at the beginning of the image.

`tools/crt0.S`

- Minimal startup runtime.
- Loads `sp` and `gp`.
- Clears `.bss`.
- Calls `main()`.
- If `main()` returns, spins forever.

This file is the first software code executed after reset/boot.

`tools/build_freertos_demo.ps1`

- The generic FreeRTOS build script.
- Locates the RISC-V toolchain.
- Locates the FreeRTOS kernel source tree in the downloaded `FreeRTOS-LTS`.
- Invokes one gcc link command that compiles and links all required objects together.
- Converts ELF to BIN and BIN to `.mem`.

Important fact:

- This script is where software files are actually gathered into a single image.
- The files do **not** need to `#include` each other directly to be part of the same firmware.
- They are collected together at **link time**.

`tools/build_freertos_snake_demo.ps1`

- A thin wrapper on top of `build_freertos_demo.ps1`.
- Replaces the generic queue demo with the RTOS Snake application.
- Adds the VGA Snake game engine and its support files.
- Adds compile-time defines such as `SNAKE_NO_STANDALONE_MAIN`.

### 4.2 Hardware-side RTOS support files

`ID.v`

- Decodes `CSRRW`, `CSRRS`, `CSRRC`.
- Decodes `ecall`, `ebreak`, `mret`.
- Detects illegal instruction and illegal CSR access.
- Produces the control signals that later let the pipeline drive the CSR block and trap logic.

Without this file, the CPU could not recognize the instructions needed by the RTOS runtime.

`CSR.v`

- Implements the machine CSR block:
  - `mstatus`
  - `mie`
  - `mtvec`
  - `mscratch`
  - `mepc`
  - `mcause`
  - `mip`
- Handles:
  - normal CSR writes
  - `trap_enter`
  - `mret_exec`
- Tracks current privilege mode.

This is the architectural state that FreeRTOS relies on for trap/interrupt handling.

`machine_irq_sources.v`

- Implements the interrupt sources used by the RTOS port:
  - software interrupt source
  - timer interrupt source
  - external interrupt source
- Contains `mtime` and `mtimecmp`.
- Produces:
  - pending bits
  - `irq_request_o`
  - `irq_cause_o`

This is the hardware timer and pending-source generator that makes preemptive scheduling possible.

`icache_pipeline_top.v`

- Instantiates the CSR block and the IRQ source block.
- Chooses when an interrupt or exception is actually taken.
- Creates the trap redirect to `mtvec`.
- Creates the `mret` redirect to `mepc`.
- Snapshots the architectural PC that becomes the trap `mepc`.

This is the main hardware integration point between the CPU pipeline and the RTOS-relevant control path.

### 4.3 Software-side RTOS bridge files

`OS/trap.h`

- Defines `struct trap_frame`.
- This is the ABI contract between:
  - assembly trap entry/exit
  - C trap dispatcher
  - FreeRTOS port

Everything about context save/restore is organized around this structure.

`OS/trap_entry.S`

- The real trap entry point written to `mtvec`.
- Saves all GPRs and key CSRs into a `trap_frame`.
- Switches to a dedicated ISR stack.
- Calls `trap_dispatch()`.
- Restores whichever trap frame `trap_dispatch()` returns.
- Ends with `mret`.

This is the core assembly bridge between CPU hardware trap behavior and the RTOS C code.

`OS/trap.c`

- Initializes `mtvec`.
- Provides `trap_dispatch()`.
- Splits traps into:
  - interrupt path
  - exception path
- Uses weak hooks:
  - `trap_on_interrupt()`
  - `trap_on_exception()`

These weak hooks are later overridden by the FreeRTOS port.

`OS/rtos_bsp.h` and `OS/rtos_bsp.c`

- Provide minimal board support helpers around interrupt enable/disable.
- Wrap `mstatus.MIE` access in simple C functions.

This is a small BSP, not a full driver framework.

`OS/freertos/portmacro.h`

- Defines the CPU-dependent FreeRTOS macros.
- Tells FreeRTOS:
  - stack type
  - alignment
  - how to `yield`
  - how to enter/leave critical sections
  - how to mask interrupts in ISR context

One especially important line is:

```c
#define portYIELD() __asm__ volatile ( "ecall" )
```

This means that a FreeRTOS yield becomes a machine `ecall` instruction on this CPU.

`OS/freertos/port.c`

- Implements the actual FreeRTOS CPU port.
- Provides:
  - `pxPortInitialiseStack()`
  - `xPortStartScheduler()`
  - timer setup
  - interrupt handler glue
  - exception handler glue for `ecall`
- Converts FreeRTOS scheduler decisions into actual trap-frame switching.

This file is the most important software bridge between the generic FreeRTOS kernel and this specific CPU.

### 4.4 FreeRTOS kernel source files currently used

These are not written by us. They are taken from:

`C:\Users\a0968\Downloads\FreeRTOSv202406.04-LTS\FreeRTOS-LTS\FreeRTOS\FreeRTOS-Kernel`

Currently used kernel `.c` files:

- `tasks.c`
- `list.c`
- `queue.c`

Their roles are:

`tasks.c`

- task creation
- ready list management
- delayed list management
- scheduler start
- tick processing
- task switching decisions

`list.c`

- generic linked-list container used internally by the scheduler
- ready lists and delay lists depend on it

`queue.c`

- queues
- queue send/receive
- block/unblock of tasks waiting on queues

### 4.5 Application and game files

`OS/freertos/freertos_demo.c`

- A clean RTOS proof demo.
- Uses:
  - heartbeat task
  - producer task
  - consumer task
  - static queue
- This file is a stronger "RTOS proof" than a game because it clearly shows queue send/receive and blocking behavior.

`OS/freertos/freertos_snake_demo.c`

- The RTOS game application.
- Creates:
  - input task
  - game task
  - heartbeat task
  - idle task memory hook
- Uses:
  - `xQueueCreateStatic`
  - `xTaskCreateStatic`
  - `vTaskStartScheduler`
  - `xQueueSend`
  - `xQueueReceive`
  - `vTaskDelay`
  - `xTaskGetTickCount`

`game/Snake_vga.c`

- Original VGA Snake game engine.
- Was refactored so it can still be compiled standalone or can be driven from RTOS tasks.

`game/Snake_vga.h`

- Declares the reusable game API:
  - `snake_game_init`
  - `snake_game_handle_input_char`
  - `snake_game_update_tick`
  - `snake_game_render_if_needed`
  - `snake_game_shutdown`
  - state getter functions

`game/games_shared_ui.c`

- Provides UART/game input helper functions used by the Snake RTOS app.

`game/vga_fb.c`

- Provides the VGA framebuffer operations used by the Snake game engine.

## 5. Exact Build Composition

The current RTOS Snake image is built like this:

```text
tools/crt0.S
OS/trap.c
OS/rtos_bsp.c
OS/freertos/freertos_libc.c
OS/freertos/port.c
FreeRTOS-Kernel/list.c
FreeRTOS-Kernel/queue.c
FreeRTOS-Kernel/tasks.c
OS/freertos/freertos_snake_demo.c
game/Snake_vga.c
game/games_shared_ui.c
game/vga_fb.c
OS/trap_entry.S
```

All of those are compiled and linked into one ELF.

Then:

```text
ELF -> BIN -> MEM
```

That `.mem` is what gets sent to the board.

This means the following statement is correct:

> The RTOS kernel, the port, the trap runtime, the application, and the game are all inside the same software image.

## 6. Why the Files Do Not Need to `#include` Each Other

This point often confuses hardware-oriented readers.

In C/C/assembly firmware integration, there are three different kinds of connection:

### 6.1 Header-level connection

Example:

- `freertos_snake_demo.c` includes `FreeRTOS.h`, `task.h`, `queue.h`

This gives:

- type declarations
- function prototypes
- macros

But it does **not** insert implementation code into the source file.

### 6.2 Link-time symbol connection

Example:

- `freertos_snake_demo.c` calls `xTaskCreateStatic()`
- the actual implementation is in FreeRTOS `tasks.c`

The compiler emits an external symbol reference.
The linker later resolves it because `tasks.c` is in the same final build.

This is how most of the RTOS software pieces are connected.

### 6.3 Hardware control-transfer connection

Example:

- `trap_init()` writes the address of `trap_entry` into `mtvec`
- when an interrupt occurs, hardware jumps there

That is not a C function call relationship.
It is a CPU architectural control-transfer relationship.

This is why assembly trap code and CSR logic can be "connected" even without ordinary C calls.

## 7. End-to-End Runtime Flow

### 7.1 Power-on / program start

1. The bitstream is already loaded into FPGA.
2. The `.mem` is sent into DDR by the UART loader.
3. The CPU fetches from `0x80000000`.
4. `_start` in `crt0.S` runs.
5. `crt0.S` sets `sp`, sets `gp`, clears `.bss`, calls `main()`.

### 7.2 `main()` in the RTOS Snake application

In `freertos_snake_demo.c`, `main()`:

1. Creates the input queue using `xQueueCreateStatic`.
2. Creates three static tasks using `xTaskCreateStatic`.
3. Provides static memory for the idle task through `vApplicationGetIdleTaskMemory`.
4. Calls `vTaskStartScheduler()`.

Important architecture detail:

- static allocation is used because `configSUPPORT_STATIC_ALLOCATION = 1`
- dynamic allocation is disabled because `configSUPPORT_DYNAMIC_ALLOCATION = 0`

So all stacks and task control blocks are preallocated in global arrays.

### 7.3 How task creation works

When `xTaskCreateStatic()` is called:

1. The app asks FreeRTOS kernel `tasks.c` to create a task.
2. The kernel allocates/initializes the task control block using the supplied static memory.
3. The kernel calls the CPU port hook `pxPortInitialiseStack()`.
4. `pxPortInitialiseStack()` builds a synthetic initial `trap_frame` on the task's stack.

This frame is the initial context that the task will "resume" into.

The important fields written by `pxPortInitialiseStack()` are:

- `mepc = task entry function`
- `a0 = task parameter`
- `ra = prvTaskExitError`
- `orig_sp = top of stack`
- `mstatus = value suitable for later `mret``

So a task does not start through a normal C call.
It starts by restoring a crafted machine context and returning into it with `mret`.

### 7.4 Starting the scheduler

`vTaskStartScheduler()` is implemented by FreeRTOS kernel `tasks.c`.

Its important jobs are:

1. create the idle task
2. perform scheduler initialization
3. call the port hook `xPortStartScheduler()`

Then `xPortStartScheduler()` in `port.c` does CPU-specific setup:

1. `trap_init()`
2. `vPortSetupTimerInterrupt()`
3. enable `mie.MTIE`
4. find the first task's stack frame
5. `trap_resume_frame(first_frame)`

At this point, control leaves ordinary C flow and enters the architectural restore path.

### 7.5 First task entry

`trap_resume_frame()` is in `trap_entry.S`.

It:

1. loads the saved `mepc` from the chosen task frame
2. loads the saved `mstatus`
3. restores all saved GPRs
4. restores `sp`
5. executes `mret`

`mret` then transfers control to the task function whose address was stored in `mepc`.

This is why the first task appears to "start" without being called like a normal function.

## 8. Timer Interrupt and Preemptive Scheduling

### 8.1 Hardware side

`machine_irq_sources.v` increments `mtime` every cycle.

When:

```text
mtime >= mtimecmp
```

the timer pending bit becomes true.

If:

- `mstatus.MIE = 1`
- `mie.MTIE = 1`

then `irq_request_o` is asserted with cause `7`.

### 8.2 CPU top-level side

`icache_pipeline_top.v` receives the IRQ request and eventually decides whether it can take the interrupt on a safe boundary.

It then:

1. sets trap redirect target to `mtvec`
2. sets `trap_enter`
3. writes:
   - trap cause
   - trap PC
   - interrupt flag
4. redirects execution into the trap handler

### 8.3 Trap entry side

When the interrupt is taken, the CPU jumps to `trap_entry`.

`trap_entry.S`:

1. allocates space for a `trap_frame` on the current task stack
2. saves all GPRs
3. reads `mepc`, `mstatus`, `mcause`, `mscratch`
4. switches to a dedicated ISR stack
5. calls `trap_dispatch(frame)`

### 8.4 C dispatch side

`trap_dispatch()` in `trap.c` checks `mcause`.

If interrupt bit is set:

- it calls `trap_on_interrupt(frame)`

In the RTOS port, `trap_on_interrupt()` in `port.c` does:

1. save the current trap frame pointer into `pxCurrentTCB`
2. program the next `mtimecmp`
3. call `xTaskIncrementTick()`
4. if a context switch is needed, call `vTaskSwitchContext()`
5. return the next task's frame pointer

### 8.5 Return to a task

`trap_entry.S` receives the frame pointer returned by `trap_dispatch()`.

That frame pointer may be:

- the same task
- a different task chosen by the scheduler

Then `trap_resume_frame()` restores that chosen context and performs `mret`.

That is the actual context switch.

## 9. `yield` Path via `ecall`

FreeRTOS also needs a software-driven context switch path.

This is implemented by:

```c
#define portYIELD() __asm__ volatile ( "ecall" )
```

in `portmacro.h`.

The flow is:

1. task calls an API that yields
2. `ecall` is executed
3. CPU decodes it as a SYSTEM instruction
4. the trap path is entered
5. `trap_on_exception()` in `port.c` sees machine `ecall`
6. it increments `mepc` by 4 so execution resumes after the `ecall`
7. it saves the current frame into `pxCurrentTCB`
8. it calls `vTaskSwitchContext()`
9. it returns the next task's frame
10. `trap_resume_frame()` restores the selected task

So both:

- preemptive switch
- cooperative switch

share the same trap-frame restore mechanism.

The difference is only the source:

- timer IRQ for preemption
- `ecall` for explicit yield

## 10. Queue Path

The queue demo and the RTOS Snake input path both rely on FreeRTOS queue primitives.

### 10.1 Creation

`xQueueCreateStatic()`

- allocates queue state from user-provided static memory
- no heap is used

### 10.2 Send

`xQueueSend()`

- implemented in `queue.c` through `xQueueGenericSend()`
- if space exists, data is copied into the queue
- if the queue is full and waiting is allowed, the task may block

### 10.3 Receive

`xQueueReceive()`

- implemented in `queue.c`
- if an item exists, it is copied out
- if empty and a wait time is allowed, the task may block

The blocked/unblocked behavior is not written by us.
It is part of the FreeRTOS kernel.

This is important when explaining to a teacher:

> The queue behavior is not a homemade mailbox. It is the official FreeRTOS queue subsystem running on the custom CPU port.

## 11. RTOS Snake Integration

The Snake game was not left as one big bare-metal `main()`.

It was split into a reusable game engine API:

- `snake_game_init()`
- `snake_game_handle_input_char()`
- `snake_game_update_tick()`
- `snake_game_render_if_needed()`
- `snake_game_shutdown()`
- getter functions for debug/heartbeat

Then the RTOS application wraps that engine with three tasks.

### 11.1 Input task

Purpose:

- read UART/game input nonblocking
- enqueue input events into the FreeRTOS input queue

RTOS role:

- demonstrates input as a separate schedulable unit
- uses queue send instead of directly mutating game state

### 11.2 Game task

Purpose:

- consume queued inputs
- update game logic
- render VGA frame

RTOS role:

- the actual game loop is now a task
- it sleeps with `vTaskDelay`
- it is no longer the whole system

### 11.3 Heartbeat task

Purpose:

- periodically report:
  - RTOS tick count
  - queue depth
  - score
  - length
  - speed
  - game state

RTOS role:

- demonstrates periodic task scheduling
- provides visibility into the system while VGA runs

## 12. Why This Is a Real RTOS Integration, Not Just a Fancy Loop

The system is genuinely using the RTOS kernel because:

- task objects are created by `xTaskCreateStatic()` from FreeRTOS `tasks.c`
- scheduler startup is handled by `vTaskStartScheduler()` from FreeRTOS `tasks.c`
- tick advancement is handled by `xTaskIncrementTick()` from FreeRTOS `tasks.c`
- task choice is handled by `vTaskSwitchContext()` from FreeRTOS `tasks.c`
- task communication uses `xQueueCreateStatic()`, `xQueueSend()`, `xQueueReceive()` from FreeRTOS `queue.c`
- task block/unblock behavior comes from the FreeRTOS kernel lists and queue subsystem

What we implemented ourselves is **not the scheduler itself**.

What we implemented is:

- the architectural port
- the trap runtime
- the board support
- the game/application

That is exactly what a CPU/RTOS bring-up is supposed to do.

## 13. Important Instructions Explained

This section is written for readers who are stronger in hardware than in low-level firmware.

### 13.1 Instructions used in startup and trap code

`la rd, symbol`

- pseudo-instruction
- loads the address of a symbol into a register
- used for:
  - stack top
  - global pointer
  - ISR stack top

`sw rs, offset(base)`

- store register to memory
- used heavily in `trap_entry.S` to save the current context into the trap frame

`lw rd, offset(base)`

- load register from memory
- used in `trap_resume_frame()` to restore context from the chosen trap frame

`csrr rd, csr`

- read CSR into a register
- used to read:
  - `mepc`
  - `mstatus`
  - `mcause`
  - `mscratch`

`csrw csr, rs`

- write register into CSR
- used to restore:
  - `mepc`
  - `mstatus`
  - `mscratch`

`csrs csr, rs`

- set CSR bits
- used to enable interrupts by setting specific bits in `mstatus` or `mie`

`csrc csr, rs`

- clear CSR bits
- used to disable interrupts or mask them in ISR critical sections

`ecall`

- synchronous exception
- used here as the software yield instruction
- FreeRTOS uses it when it wants to trigger a context switch through the trap path

`mret`

- return from machine-mode trap
- the key instruction that leaves the trap handler and resumes a chosen task context

### 13.2 Why `mret` is so important

This CPU port starts tasks and resumes tasks using `mret`, not ordinary C calls.

That means:

- the RTOS does not call a task function directly to "switch" to it
- instead, it restores a machine context where:
  - `mepc = task entry`
  - `sp = task stack`
  - registers are set to the saved state
- then `mret` makes the CPU continue from that architectural state

This is the heart of task switching.

## 14. Control and File Relationship Graph

The most useful relationship diagram is this:

```text
build_freertos_snake_demo.ps1
  -> build_freertos_demo.ps1
      -> gcc links:
         crt0.S
         trap.c
         rtos_bsp.c
         port.c
         trap_entry.S
         FreeRTOS tasks.c/list.c/queue.c
         freertos_snake_demo.c
         Snake_vga.c
         games_shared_ui.c
         vga_fb.c
      -> ELF
      -> BIN
      -> MEM

MEM loaded to DDR
  -> CPU starts at _start
  -> crt0.S calls main
  -> freertos_snake_demo.c creates queue/tasks
  -> FreeRTOS tasks.c starts scheduler
  -> port.c configures trap + timer
  -> trap_resume_frame() enters first task
  -> timer IRQ / ecall
  -> trap_entry.S saves context
  -> trap.c dispatches
  -> port.c chooses next frame
  -> trap_resume_frame() restores selected task
```

The most important hardware relationship diagram is this:

```text
ID.v
  -> decodes CSR / ecall / ebreak / mret / illegal

CSR.v
  -> stores mtvec / mepc / mcause / mstatus / mie / mip

machine_irq_sources.v
  -> generates timer/software/external interrupt requests

icache_pipeline_top.v
  -> instantiates CSR.v and machine_irq_sources.v
  -> decides when trap/interrupt is taken
  -> redirects PC to mtvec or mepc

trap_entry.S / trap.c / port.c
  -> use those hardware facilities at software level
```

## 15. Which Part Is Kernel, Which Part Is Port, Which Part Is Application

This distinction should be made explicitly in a report or oral defense.

### Kernel

- `tasks.c`
- `list.c`
- `queue.c`

Owned by FreeRTOS.
These files implement RTOS policies and core services.

### Port / Glue / BSP

- `port.c`
- `portmacro.h`
- `trap_entry.S`
- `trap.c`
- `rtos_bsp.c`

Written for this CPU/platform.
These files are the adaptation layer that makes the generic kernel usable on this CPU.

### Application

- `freertos_demo.c`
- `freertos_snake_demo.c`

These files use RTOS services.

### Game Engine

- `Snake_vga.c`
- `Snake_vga.h`
- `games_shared_ui.c`
- `vga_fb.c`

These files implement the game itself and the VGA/UI support.

## 16. What the Current RTOS Setup Does and Does Not Yet Include

### Currently included and working

- preemptive scheduling
- timer tick
- machine-mode trap entry/exit
- `ecall`-based yield
- static task creation
- static queue
- RTOS queue demo
- RTOS Snake demo with VGA and UART heartbeat

### Not the focus of the current image

- dynamic allocation / `heap_4.c`
- mutex/semaphore/event-groups demos
- software timers
- a full POSIX-like environment
- process isolation
- user-mode task separation

This is a **minimal but real FreeRTOS port**, not a full desktop OS environment.

## 17. The One-Sentence Correct Description

If you need one precise sentence for a teacher:

> I compiled the FreeRTOS kernel source together with my CPU-specific trap/port layer, startup code, BSP, application, and VGA game engine into one firmware image; the CPU uses CSR/trap/timer hardware to let the FreeRTOS scheduler drive preemptive task switching on my custom RV32 platform.

## 18. The Slightly Longer Oral Defense Version

If asked "How exactly are CPU and RTOS connected?", a good answer is:

> The hardware side provides CSR state, `mtvec/mepc/mcause`, machine timer interrupt generation, and pipeline trap redirect logic. The software side provides `crt0`, trap entry/exit assembly, a C trap dispatcher, and a FreeRTOS port that implements stack initialization, scheduler start, timer-tick handling, and `ecall`-based yield. The FreeRTOS kernel itself is linked in as source files such as `tasks.c`, `list.c`, and `queue.c`. The application then creates tasks and queues through the official FreeRTOS API, and the selected task context is restored with `mret`.

## 19. Recommended Reading Order

For a hardware person reading the code for the first time, this order is recommended:

1. `tools/link_ddr.ld`
2. `tools/crt0.S`
3. `OS/trap.h`
4. `OS/trap_entry.S`
5. `OS/trap.c`
6. `OS/freertos/portmacro.h`
7. `OS/freertos/port.c`
8. `OS/freertos/FreeRTOSConfig.h`
9. `OS/freertos/freertos_demo.c`
10. `OS/freertos/freertos_snake_demo.c`
11. `game/Snake_vga.h`
12. `machine_irq_sources.v`
13. `CSR.v`
14. `icache_pipeline_top.v`

That reading order matches the actual control flow reasonably well.

## 20. Final Summary

The system works because the following three layers are all present at once:

- hardware architectural support for traps, CSRs, and timer interrupts
- software glue code that converts trap events into FreeRTOS context management
- the FreeRTOS kernel itself, linked into the same firmware image as the application and game

The key conceptual point is:

> The RTOS is not an external service. It is compiled into the firmware image, and it runs because the custom CPU now provides the exact trap/interrupt mechanisms that the port layer needs.

