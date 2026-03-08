    .section .text
    .globl main

main:
    lui   s0, 0x40000
    addi  s1, s0, 4
    li    s2, 85

tx_wait:
    lw    t0, 0(s1)
    andi  t0, t0, 1
    beqz  t0, tx_wait

    sw    s2, 0(s0)
    j     tx_wait
