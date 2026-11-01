# ---------------------------------------------------------------------------
# loader.S - B4: UART boot loader.
#
# Runs from the on-chip ROM at 0x0 and receives an image into 0x8000_0000:
#
#   "ARS1"            4 bytes magic
#   length            4 bytes, little endian, 1 .. 128 KiB
#   payload           length bytes
#   checksum          4 bytes, little endian, sum of payload bytes
#
# On success it prints a line, executes fence.i (sweeps the stale I-cache
# lines a warm reset may have left behind) and jumps to 0x8000_0000.
# No stack: getc/puts/puthex8 are leaf routines.
# ---------------------------------------------------------------------------
    .section .text.init
    .globl _start

_start:
    lui     t0, 0xD0000             # UART base
    li      t1, 234                 # 27 MHz / 115200
    sw      t1, 12(t0)

    la      a0, m_ready
    jal     ra, puts

    # ---------------------------------------------------------- magic
    li      s2, 0
    li      s3, 4
magic_loop:
    jal     ra, getc
    slli    s2, s2, 8
    or      s2, s2, a0
    addi    s3, s3, -1
    bnez    s3, magic_loop
    li      t1, 0x41525331          # "ARS1"
    bne     s2, t1, bad

    # --------------------------------------------------------- length
    li      s4, 0
    li      s5, 0
    li      s3, 4
len_loop:
    jal     ra, getc
    sll     a0, a0, s5
    or      s4, s4, a0
    addi    s5, s5, 8
    addi    s3, s3, -1
    bnez    s3, len_loop
    beqz    s4, bad
    li      t1, 0x20000             # 128 KiB
    bgtu    s4, t1, bad

    # -------------------------------------------------------- payload
    li      s6, 0x80000000
    mv      s7, s4
    li      s0, 0                   # running sum
pay_loop:
    jal     ra, getc
    sb      a0, 0(s6)
    add     s0, s0, a0
    addi    s6, s6, 1
    addi    s7, s7, -1
    bnez    s7, pay_loop

    # ------------------------------------------------------- checksum
    li      s8, 0
    li      s5, 0
    li      s3, 4
sum_loop:
    jal     ra, getc
    sll     a0, a0, s5
    or      s8, s8, a0
    addi    s5, s5, 8
    addi    s3, s3, -1
    bnez    s3, sum_loop

    bne     s0, s8, bad_sum

    la      a0, m_ok
    jal     ra, puts

    fence.i
    li      t1, 0x80000000
    jalr    x0, 0(t1)

# ------------------------------------------------------------------ errors
bad_sum:
    la      a0, m_sum
    jal     ra, puts
    mv      a0, s0
    jal     ra, puthex8
    la      a0, m_exp
    jal     ra, puts
    mv      a0, s8
    jal     ra, puthex8
    la      a0, crlf
    jal     ra, puts
    j       bad
bad:
    la      a0, m_bad
    jal     ra, puts
    j       bad

# -------------------------------------------------------------------- I/O
getc:
    lw      t3, 4(t0)
    andi    t3, t3, 2               # rx_valid
    beqz    t3, getc
    lw      a0, 0(t0)               # reading also clears rx_valid
    andi    a0, a0, 255
    ret

puts:
    lbu     t3, 0(a0)
    beqz    t3, puts_done
puts_wait:
    lw      t4, 4(t0)
    andi    t4, t4, 1               # tx ready
    beqz    t4, puts_wait
    sw      t3, 0(t0)
    addi    a0, a0, 1
    j       puts
puts_done:
    ret

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
m_ready: .asciz "ARES-S1 loader v1 - send image\r\n"
m_ok:    .asciz "image ok, jump 0x80000000\r\n"
m_bad:   .asciz "LOADER ERROR\r\n"
m_sum:   .asciz "checksum mismatch got="
m_exp:   .asciz " exp="
crlf:    .byte 13, 10, 0
         .align 2
