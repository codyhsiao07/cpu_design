// Minimal startup for RV32I bare-metal tests.
// - Set stack pointer
// - Call main
// - Move return value to x8 (s0/fp) for TB observability
// - Spin forever

    .section .text.start
    .globl _start
_start:
    la   sp, __stack_top
    la   gp, __global_pointer$
    call main
    addi x8, a0, 0
1:
    jal  x0, 1b
