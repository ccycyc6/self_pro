# ---------------------------------------------------------------------------
# b2_hello.S - smallest possible "the CPU is alive" program.
#
# No stack, no C runtime, no RAM: it runs entirely out of the boot ROM at 0x0
# and only touches the UART at 0xD000_0000.  Every character is sent by
# polling the status register, so a failure can only come from the core, the
# bus or the UART -- never from memory.
#
#   "B2 OK mcycle=XXXXXXXX\r\n"  every ~1 s, byte order per the UART spec:
#   TX  0x00 write / STATUS 0x04 bit0 = tx ready / BAUD 0x0C
# ---------------------------------------------------------------------------
    .section .text.init
    .globl _start

_start:
    lui     t0, 0xD0000             # UART base
    li      t1, 234                 # 27 MHz / 115200
    sw      t1, 12(t0)              # BAUD
    li      s0, 0                   # heartbeat counter

loop:
    la      a0, msg
    jal     ra, puts
    csrr    a0, 0xB00               # mcycle
    jal     ra, puthex8
    la      a0, crlf
    jal     ra, puts

    li      t2, 0x200000            # ~1 s at 27 MHz
delay:
    addi    t2, t2, -1
    bnez    t2, delay
    addi    s0, s0, 1
    j       loop

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
    addi    t3, t3, 39              # 'a' - 10 - '0'
ph_dec:
    addi    t3, t3, 48              # '0'
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
msg:
    .asciz  "B2 OK mcycle="
crlf:
    .byte   13, 10, 0
    .align  2
