#ifndef MINITENSOR_MT_H
#define MINITENSOR_MT_H

#include <stdint.h>

/* -----------------------------------------------------------------------------
 * miniTensor MMIO control interface.
 *
 * The accelerator is driven through a small MMIO register window; the hardware
 * adapter (rtl/soc/mt/mt_cvxif_shim.sv) synthesises the CV-X-IF
 * issue -> register -> commit -> result transaction for each command.
 *
 * The scratch window is the L2 scratchpad at 0x1000_0000.  The CPU data path
 * is uncached in this simulation configuration, so the accelerator DMA and the
 * CPU observe the same bytes with no cache maintenance.
 * -------------------------------------------------------------------------- */

#define MT_BASE        0xE0000000u
#define MT_INSTR       (MT_BASE + 0x00u)
#define MT_RS1         (MT_BASE + 0x04u)
#define MT_RS2         (MT_BASE + 0x08u)
#define MT_KICK        (MT_BASE + 0x0Cu)
#define MT_STATUS      (MT_BASE + 0x10u)
#define MT_RESULT      (MT_BASE + 0x14u)
#define MT_BSTEP       (MT_BASE + 0x18u)   /* burst row steps: a|b<<8|c<<16 */

#define MT_MMIO32(address) (*(volatile uint32_t *)(uintptr_t)(address))

/* MT_STATUS bits.  A read taken while BUSY is clear consumes all of them, so a
 * mid-batch poll cannot lose an error reported by an earlier command. */
#define MT_ST_BUSY       (1u << 0)   /* queue non-empty or a command in flight */
#define MT_ST_DONE       (1u << 1)   /* queue drained, last command finished   */
#define MT_ST_ERR        (1u << 2)   /* operand rejected after commit */
#define MT_ST_ACCEPT_ERR (1u << 3)   /* unsupported funct7/funct3 */
#define MT_ST_KICK_ERR   (1u << 4)   /* kick dropped: queue was full */

/* Scratch buffer: 64 KiB at 0x1000_0000 (L2 scratchpad). */
#define MT_BUF_BASE    0x10000000u
#define MT_BUF_SIZE    0x00010000u

/* Generous poll bound so a hardware fault cannot wedge the firmware. */
#define MT_POLL_LIMIT  2000000u

#define MT_OPCODE      0x0Bu   /* custom-0 = 7'b0001011 */

/* Only funct7/funct3/rd are interpreted by the accelerator; the rs1/rs2 fields
 * of the instruction word are irrelevant because the operand values travel on
 * the CV-X-IF register channel. */
static inline uint32_t mt_enc(uint32_t funct7, uint32_t funct3, uint32_t rd)
{
    return (funct7 << 25) | ((funct3 & 0x7u) << 12) |
           ((rd & 0x1Fu) << 7) | MT_OPCODE;
}

#define MT_LOAD      mt_enc(0x03u, 0x0u, 0u)   /* 0000011: mem -> UB      */
#define MT_STORE     mt_enc(0x04u, 0x0u, 0u)   /* 0000100: UB  -> mem     */
#define MT_VEC_ADD8  mt_enc(0x02u, 0x0u, 0u)   /* 0000010 funct3=000      */
#define MT_VEC_MAX8  mt_enc(0x02u, 0x1u, 0u)   /* 0000010 funct3=001      */
#define MT_VEC_RELU8 mt_enc(0x02u, 0x2u, 0u)   /* 0000010 funct3=010      */
#define MT_GEMM      mt_enc(0x05u, 0x0u, 0u)   /* 0000101: 4x4x4 INT8     */

/* Burst form of any instruction: the rd field tells the shim how many times to
 * issue it, adding MT_BSTEP between issues.  rd is otherwise unused. */
#define MT_BURST(instr, n) ((instr) | ((((uint32_t)(n)) & 0x1Fu) << 7))
#define MT_GEMM_BURST(n)   MT_BURST(MT_GEMM, (n))

/* Two-dimensional GEMM burst: nu tile columns x nj output groups, all in one
 * push.  The shim steps the A row and the C row per column, and the weight row
 * per group.  nu/nj ride in the spare upper bytes of rs1. */
/* The shape rides in the instruction's unused rs1/rs2 fields (5 bits each) so
 * that the rs1/rs2 operands the tensor validates stay clean -- it rejects a
 * GEMM whose rs1[31:16] is not zero. */
#define MT_GEMM2D(nu, nj) (mt_enc(0x09u, 0x0u, 0u) | \
                           ((((uint32_t)(nj)) & 0x1Fu) << 20) | \
                           ((((uint32_t)(nu)) & 0x1Fu) << 15))

/* Row steps for the next burst: a and b live in rs1's two bytes, c in rs2's
 * low byte. */
#define MT_SET_STEPS(a, b, c) \
    MT_MMIO32(MT_BSTEP) = ((uint32_t)(a) & 0xFFu) | \
                          (((uint32_t)(b) & 0xFFu) << 8) | \
                          (((uint32_t)(c) & 0xFFu) << 16)

/* Same, with the fourth step used by the two-dimensional burst: the C row
 * advance between output groups inside one tile column. */
#define MT_SET_STEPS4(a, b, c, d) \
    MT_MMIO32(MT_BSTEP) = ((uint32_t)(a) & 0xFFu) | \
                          (((uint32_t)(b) & 0xFFu) << 8) | \
                          (((uint32_t)(c) & 0xFFu) << 16) | \
                          (((uint32_t)(d) & 0xFFu) << 24)
#define MT_EPILOGUE  mt_enc(0x06u, 0x0u, 0u)   /* 0000110: requant+pack   */

/* rs2 for MT_LOAD / MT_STORE: [7:0] UB start row, [15:8] row count (never 0). */
#define MT_ROWS(row, count) (((row) & 0xFFu) | (((count) & 0xFFu) << 8))

/* MT_GEMM rs1: [7:0] A row, [15:8] B row.  rs2: [7:0] C row (uses C..C+3),
 * [8] accumulate.  C must be <= 252. */
#define MT_GEMM_RS1(a_row, b_row) (((a_row) & 0xFFu) | (((b_row) & 0xFFu) << 8))
#define MT_GEMM_RS2(c_row, acc)   (((c_row) & 0xFFu) | (((acc) & 0x1u) << 8))

/* MT_EPILOGUE rs1: [7:0] C row, [15:8] bias row.  rs2: [7:0] out row,
 * [15:8] config row. */
#define MT_EPI_RS1(c_row, bias_row) (((c_row) & 0xFFu) | (((bias_row) & 0xFFu) << 8))
#define MT_EPI_RS2(out_row, cfg_row) (((out_row) & 0xFFu) | (((cfg_row) & 0xFFu) << 8))

/* MT_VECTOR rs1: [7:0] A row, [15:8] B row.  rs2: [7:0] destination row.
 * RELU8 is unary and reads the A row. */
#define MT_VEC_RS1(a_row, b_row) (((a_row) & 0xFFu) | (((b_row) & 0xFFu) << 8))
#define MT_VEC_RS2(dst_row)      ((dst_row) & 0xFFu)

/* Epilogue config row (little endian, first 32 bits are enough):
 *   [15:0]  signed multiplier
 *   [20:16] arithmetic right shift
 *   [28:21] signed zero point
 *   [29]    ReLU enable */
#define MT_CFG(multiplier, shift, zero_point, relu)                     \
    (((uint32_t)(multiplier) & 0xFFFFu) |                               \
     (((uint32_t)(shift) & 0x1Fu) << 16) |                              \
     (((uint32_t)(zero_point) & 0xFFu) << 21) |                         \
     (((relu) ? 1u : 0u) << 29))

/* 64-bit machine cycle counter (CONFIG_HAS_CSR_MCYCLE exposes mcycle/mcycleh). */
static inline uint32_t mt_rd_mcycle(void)
{
    uint32_t value;

    __asm__ volatile("csrr %0, 0xB00" : "=r"(value));
    return value;
}

/* Command queue depth implemented in mt_cvxif_shim.sv.  Each MMIO write costs
 * a few cycles while a status read costs more, so queueing several commands and
 * polling once per batch removes most of the per-command host overhead.  The
 * driver keeps one slot free so a push can never be dropped. */
#define MT_FIFO_DEPTH   64u
#ifdef MT_BATCH_ONE
#define MT_BATCH        1u
#else
#define MT_BATCH        (MT_FIFO_DEPTH - 1u)
#endif

/* Queue a command without waiting for it.  Drains automatically every
 * MT_BATCH commands.  Returns 0, or negative on error/timeout.
 *
 * Inline on purpose: the convoy loops push tens of thousands of commands and a
 * real call costs more than the four stores it wraps. */
extern uint32_t mt_queued;

int mt_drain(void);

static inline int mt_push(uint32_t instr, uint32_t rs1, uint32_t rs2)
{
    MT_MMIO32(MT_INSTR) = instr;
    MT_MMIO32(MT_RS1)   = rs1;
    MT_MMIO32(MT_RS2)   = rs2;
    MT_MMIO32(MT_KICK)  = 1u;

    if (++mt_queued >= MT_BATCH)
    {
        return mt_drain();
    }
    return 0;
}

/* Issue one command and wait for completion.
 * Returns 0 on success, negative on error/timeout. */
int mt_exec(uint32_t instr, uint32_t rs1, uint32_t rs2);
int mt_exec_st(uint32_t instr, uint32_t rs1, uint32_t rs2, uint32_t *status_out);

int  mt_probe(void);
void mt_reset_status(void);

/* Convenience wrappers */
int mt_load(uint32_t mem_addr, uint32_t ub_row, uint32_t rows);
int mt_store(uint32_t mem_addr, uint32_t ub_row, uint32_t rows);

#endif /* MINITENSOR_MT_H */