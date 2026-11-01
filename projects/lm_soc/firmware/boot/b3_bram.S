# ---------------------------------------------------------------------------
# b3_bram.S - B3: prove the memory path (BRAM behind the DDR port).
#
# Exercises, in this order:
#   1. 2048 word stores at 0x8000_0000 then read-back compare
#   2. a byte store (wstrb lane 1) in the middle of a written word
#   3. a halfword store (wstrb lanes 2-3)
# Prints "BRAM PASS mcycle=XXXXXXXX" (or a failure record) once a second.
# Still no stack: puts()/puthex8() are leaf routines.
# ---------------------------------------------------------------------------
    .section .text.init
    .globl _start

_start:
    lui     t0, 0xD0000             # UART base
    li      t1, 234
    sw      t1, 12(t0)              # BAUD

    li      s0, 0x80000000          # memory window
    li      s2, 2048                # 2048 words = 8 KiB

    # ---------------------------------------------------- 1. word writes
    li      s1, 0
wloop:
    slli    t3, s1, 2
    add     t3, s0, t3
    li      t4, 0x5A5A5A5A
    xor     t4, t4, s1
    sw      t4, 0(t3)
    addi    s1, s1, 1
    blt     s1, s2, wloop

    # ------------------------------------------------ 2. word read/compare
    li      s1, 0
rloop:
    slli    t3, s1, 2
    add     t3, s0, t3
    lw      t4, 0(t3)
    li      t5, 0x5A5A5A5A
    xor     t5, t5, s1
    bne     t4, t5, failw
    addi    s1, s1, 1
    blt     s1, s2, rloop

    # ------------------------------------------------------ 3. byte strobe
    li      t3, 0x80004000
    li      t4, 0x12345678
    sw      t4, 0(t3)
    li      t4, 0xAA
    sb      t4, 1(t3)
    lw      t5, 0(t3)
    li      t6, 0x1234AA78
    bne     t5, t6, failb

    # -------------------------------------------------- 4. halfword strobe
    li      t3, 0x80004004
    li      t4, 0xFFFFFFFF
    sw      t4, 0(t3)
    li      t4, 0x1234
    sh      t4, 2(t3)
    lw      t5, 0(t3)
    li      t6, 0x1234FFFF
    bne     t5, t6, failh

    li      s6, 1
    j       hb

failw:
    li      s6, 0
    mv      s3, t3
    mv      s4, t4
    mv      s5, t5
    j       report_fail
failb:
    li      s6, 0
    mv      s3, t3
    mv      s4, t5
    mv      s5, t6
    j       report_fail
failh:
    li      s6, 0
    mv      s3, t3
    mv      s4, t5
    mv      s5, t6
    j       report_fail

report_fail:
    la      a0, f_addr
    jal     ra, puts
    mv      a0, s3
    jal     ra, puthex8
    la      a0, f_got
    jal     ra, puts
    mv      a0, s4
    jal     ra, puthex8
    la      a0, f_exp
    jal     ra, puts
    mv      a0, s5
    jal     ra, puthex8
    la      a0, crlf
    jal     ra, puts

# ------------------------------------------------------- heartbeat / result
hb:
    beqz    s6, hb_fail
    la      a0, s_pass
    j       hb_print
hb_fail:
    la      a0, s_fail
hb_print:
    jal     ra, puts
    csrr    a0, 0xB00
    jal     ra, puthex8
    la      a0, crlf
    jal     ra, puts

    li      t2, 0x200000
hbdly:
    addi    t2, t2, -1
    bnez    t2, hbdly
    j       hb

# ---------------------------------------------------------------- puts(a0)
puts:
    lbu     t3, 0(a0)
    beqz    t3, puts_done
puts_wait:
    lw      t4, 4(t0)
    andi    t4, t4, 1
    beqz    t4, puts_wait
    sw      t3, 0(t0)
    addi    a0, a0, 1
    j       puts
puts_done:
    ret

# ------------------------------------------------------------- puthex8(a0)
puthex8:
    li      t5, 8
    li      t6, 28
ph_loop:
    srl     t3, a0, t6
    andi    t3, t3, 15
    li      t4, 10
    blt     t3, t4, ph_dec
    addi    t3, t3, 39
ph_dec:
    addi    t3, t3, 48
ph_wait:
    lw      t4, 4(t0)
    andi    t4, t4, 1
    beqz    t4, ph_wait
    sw      t3, 0(t0)
    addi    t6, t6, -4
    addi    t5, t5, -1
    bnez    t5, ph_loop
    ret

    .section .rodata
s_pass: .asciz "BRAM PASS mcycle="
s_fail: .asciz "BRAM FAIL mcycle="
f_addr: .asciz "  addr="
f_got:  .asciz " got="
f_exp:  .asciz " exp="
crlf:   .byte 13, 10, 0
        .align 2
