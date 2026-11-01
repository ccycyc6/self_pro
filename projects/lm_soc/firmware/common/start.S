    .section .text.init
    .globl _start
_start:
    la      sp, __stack_top
    la      gp, __global_pointer$
    la      t0, trap_handler
    csrw    mtvec, t0

    la      t0, __bss_start
    la      t1, __bss_end
1:
    bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:
    call    main
    li      a0, 0
    ebreak
3:
    j       3b
