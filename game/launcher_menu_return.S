    .section .text
    .globl launcher_menu_return_entry
    .globl launcher_menu_soft_reset_entry
launcher_menu_return_entry:
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
    .option push
    .option norelax
    la   t0, launcher_menu_reentry
    .option pop
    jalr x0, 0(t0)

launcher_menu_soft_reset_entry:
    la   sp, __stack_top
    la   gp, __global_pointer$
    la   t0, __bss_start
    la   t1, __bss_end
    li   t2, 0
3:
    bgeu t0, t1, 4f
    sw   t2, 0(t0)
    addi t0, t0, 4
    jal  x0, 3b
4:
    .option push
    .option norelax
    la   t0, launcher_menu_soft_reset
    .option pop
    jalr x0, 0(t0)
