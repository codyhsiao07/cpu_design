    .section .text.start, "ax"
    .align 2
    .globl _start

_start:
    la   sp, __stack_top

    .option push
    .option norelax
    la   gp, __global_pointer$
    .option pop

    la   t0, __bss_start
    la   t1, __bss_end
    li   t2, 0
1:
    bgeu t0, t1, 2f
    sw   t2, 0(t0)
    addi t0, t0, 4
    j    1b

2:
    la   t0, freertos_risc_v_trap_handler
    csrw mtvec, t0

    call main
    mv   s0, a0
3:
    j    3b
