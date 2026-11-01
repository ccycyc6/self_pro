#include "ares_soc.h"

/* B4 application: this is not in the bitstream.  It is uploaded over the UART
 * into the on-chip memory at 0x8000_0000 and started by the loader. */
int main(void)
{
    uart_init(234u);

    printf("\n");
    printf("B4: hello from loaded firmware @0x80000000\n");
    printf("B4: mcycle=%u\n", (unsigned)ares_rd_mcycle64());

    for (;;) {
        __asm__ volatile("nop");
    }
    return 0;
}
