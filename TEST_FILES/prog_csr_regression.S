/* Full-pipeline reserved SYSTEM trap and M-to-U interrupt regression.
 * TEST=0 EXPECT_RD=8 EXPECT_VAL=c5a0c0de
 */
.section .text.start
.globl _start
_start:
    la t0, handler
    csrw mtvec, t0
    li s1, 0
    li s2, 0
    .word 0x00004073
    .word 0x00104073
    .word 0x30204073
    li t0, 3
    bne s1, t0, fail
    li s2, 1
    li t0, 8
    csrw mie, t0
    li t0, 0x40000018
    li t1, 1
    sw t1, 0(t0)
    la t0, user_loop
    csrw mepc, t0
    csrw mstatus, zero          /* MPP=U, MPIE=0, MIE=0 */
    mret
user_loop:
    j user_loop                /* Machine IRQ must still preempt U mode. */
.balign 4
handler:
    csrr t0, mcause
    bnez s2, interrupt
    li t1, 2
    bne t0, t1, fail
    addi s1, s1, 1
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    mret
interrupt:
    li t1, 0x80000003
    bne t0, t1, fail
    csrr t0, mstatus
    li t1, 0x1800
    and t2, t0, t1
    bnez t2, fail              /* Trap saved U in MPP. */
    li t0, 0x40000018
    sw zero, 0(t0)
    csrw mie, zero
    csrs mstatus, t1           /* Return to M. */
    la t0, success
    csrw mepc, t0
    mret
success:
    lui s0, 0xc5a0c
    addi s0, s0, 0xde
1:  j 1b
fail:
    lui s0, 0xbad00
    addi s0, s0, 1
2:  j 2b
