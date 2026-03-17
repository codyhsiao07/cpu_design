// Startup for slot-based standalone game images.
// - Set stack/gp
// - Clear bss
// - Run slot pre-main hook
// - Call the original game's main
// - Run slot post-main hook (jumps back to launcher menu)

    .section .text.start
    .globl _start
_start:
    la   sp, __stack_top
    la   gp, __global_pointer$
    la   t0, __bss_start
    la   t1, __bss_end
    li   t2, 0
1:
    bgeu t0, t1, 2f
    sw   t2, 0(t0)
    addi t0, t0, 4
    jal  x0, 1b
2:
    call launcher_slot_before_main
    call main
    call launcher_slot_after_main
3:
    jal  x0, 3b
