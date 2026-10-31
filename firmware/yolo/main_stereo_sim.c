// Simulation entry point for the stereo window path.
//
// The testbench fills the two 320x240 frame memories with a textured pair whose
// right eye is the left one shifted by 9 pixels, so a correct chain answers
// 9.00 px.  This runs in seconds, which is the whole point: address, decode and
// read-timing mistakes are caught here instead of costing a 12 minute bitstream.
#include <stdint.h>
#include "ares_soc.h"
#include "stereo.h"

extern void uart_init(uint32_t baud_div);

#define ST_L_BASE 0xD0100000u
#define ST_R_BASE 0xD0150000u

#define ROI_X0 96
#define ROI_Y0 60
#define ROI_W  48
#define ROI_H  32

static uint8_t roi_l[ROI_W * ROI_H];
static uint8_t roi_r[(ROI_W + ST_DMAX) * ROI_H];

static void read_roi(uint32_t base, int x0, int y0, int w, int h, uint8_t *dst)
{
    int x, y;

    for (y = 0; y < h; y++)
        for (x = 0; x < w; x++) {
            uint32_t addr = base + (uint32_t)((y0 + y) * ST_W + (x0 + x)) * 4u;
            dst[y * w + x] = (uint8_t)(ARES_MMIO32(addr) & 0xFFu);
        }
}

int main(void)
{
    int n = 0;
    int32_t d;
    uint32_t z;

    uart_init(UART_DIV);
    printf("first pixels: l=%u r=%u\n",
           (unsigned)(ARES_MMIO32(ST_L_BASE) & 0xFFu),
           (unsigned)(ARES_MMIO32(ST_R_BASE) & 0xFFu));

    read_roi(ST_L_BASE, ROI_X0, ROI_Y0, ROI_W, ROI_H, roi_l);
    read_roi(ST_R_BASE, ROI_X0 - ST_DMAX, ROI_Y0, ROI_W + ST_DMAX, ROI_H, roi_r);

    printf("roi l0=%u l1=%u r0=%u r1=%u\n",
           (unsigned)roi_l[0], (unsigned)roi_l[1],
           (unsigned)roi_r[0], (unsigned)roi_r[1]);

    d = st_match_roi(roi_l, ROI_W, roi_r, ROI_W + ST_DMAX, 0, 0, ROI_W, ROI_H, &n);
    z = d > 0 ? st_depth_mm(d) : 0u;
    printf("disparity q4=%d blocks=%d z_mm=%u\n", (int)d, n, (unsigned)z);

    if (d >= 32 && d <= 40 && n > 0) printf("STEREO SIM PASSED\n");
    else                             printf("STEREO SIM FAILED\n");
    return 0;
}
