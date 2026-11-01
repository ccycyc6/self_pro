#include "mt.h"

/* Read MT_STATUS until the adapter is idle.  The final read (taken while BUSY
 * is clear) consumes the sticky flags and is the one whose value we report. */
static int mt_poll(uint32_t *status_out)
{
    uint32_t status;
    uint32_t guard = 0u;

    do
    {
        status = MT_MMIO32(MT_STATUS);
        if (++guard > MT_POLL_LIMIT)
        {
            return -1;
        }
    } while ((status & MT_ST_BUSY) != 0u);

    if (status_out != 0)
    {
        *status_out = status;
    }

    return 0;
}

/* Commands queued since the last drain (shared with the inline pusher). */
uint32_t mt_queued;

int mt_drain(void)
{
    uint32_t status;

    if (mt_queued == 0u)
    {
        return 0;   /* nothing outstanding */
    }
    mt_queued = 0u;

    if (mt_poll(&status) != 0)
    {
        return -2;   /* timeout */
    }

    if ((status & (MT_ST_ERR | MT_ST_ACCEPT_ERR | MT_ST_KICK_ERR)) != 0u)
    {
        printf("mt: status=0x%08x\n", (unsigned)status);
        return -3;
    }

    if ((status & MT_ST_DONE) == 0u)
    {
        return -4;   /* drained without a result: protocol violation */
    }

    return 0;
}



int mt_exec(uint32_t instr, uint32_t rs1, uint32_t rs2)
{
    int rc = mt_push(instr, rs1, rs2);

    if (rc != 0)
    {
        return rc;
    }
    if (mt_queued == 0u)
    {
        return 0;   /* the push itself drained this batch */
    }
    return mt_drain();
}

int mt_exec_st(uint32_t instr, uint32_t rs1, uint32_t rs2, uint32_t *status_out)
{
    int rc = mt_exec(instr, rs1, rs2);

    if (status_out != 0)
    {
        *status_out = MT_MMIO32(MT_STATUS);
    }
    return rc;
}

int mt_load(uint32_t mem_addr, uint32_t ub_row, uint32_t rows)
{
    return mt_exec(MT_LOAD, mem_addr, MT_ROWS(ub_row, rows));
}

int mt_store(uint32_t mem_addr, uint32_t ub_row, uint32_t rows)
{
    return mt_exec(MT_STORE, mem_addr, MT_ROWS(ub_row, rows));
}

/* Read back the sticky status once without issuing a command. */
int mt_probe(void)
{
    uint32_t status;

    status = MT_MMIO32(MT_STATUS);

    if ((status & (MT_ST_ERR | MT_ST_ACCEPT_ERR)) != 0u)
    {
        return -1;
    }

    return (int)(status & MT_ST_DONE);
}

void mt_reset_status(void)
{
    mt_queued = 0u;
    (void)MT_MMIO32(MT_STATUS);
}
