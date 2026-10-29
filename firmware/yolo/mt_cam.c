/*
 * mt_cam.c -- live camera demo.
 *
 * Two things run on the same 32x32 thumbnail:
 *
 *   1. a brightest-block tracker (pure C, roughly a millisecond): it finds the
 *      brightest 80x80 region of the picture and draws the green box there.
 *      This is what the audience sees, and its behaviour is obvious: the box
 *      sits on the brightest spot.
 *
 *   2. the INT8 detector on the accelerator, every DET_EVERY frames: it shows
 *      that the camera pixels really do reach miniTensor and that its answer
 *      comes back through the same memory.  Its box would be meaningless on a
 *      real scene (the model was fitted on synthetic white squares), so it is
 *      printed rather than drawn.
 */
#include <stdint.h>
#include "ares_soc.h"
#include "mt.h"
#include "mt_net.h"
#include "mt_detect.h"
#include "mt_detect_weights.h"

#define CAM_PIX_BASE 0xD0002000u
#define CAM_FRAME    0xD0003000u
#define CAM_WRCNT    0xD0003004u
#define CAM_DBG      0xD0003008u
#define OSD_BOX_BASE 0xD0004000u     /* x0, y0, x1, y1, commit */

/* Run the accelerator once every this many frames.  Each run costs ~268 ms,
 * so this is the knob between "smooth green box" and "frequent detector
 * output": 3 gives roughly 11 box updates/s and a detector line every 0.27 s. */
#define DET_EVERY 3

/* Crop the thumbnail below this block average (relative to the frame mean)
 * counts as "nothing bright in view". */
#define TRACK_MARGIN 8u

#define DET_WT_OFF_L1   0x0000u
#define DET_WT_OFF_L2   0x0120u
#define DET_WT_OFF_L3   0x05A0u
#define DET_WT_OFF_L4   0x0EA0u
#define DET_BIAS_OFF_L1 0x000u
#define DET_BIAS_OFF_L2 0x080u
#define DET_BIAS_OFF_L3 0x180u
#define DET_BIAS_OFF_L4 0x280u
#define DET_CFG_OFF_L1  0x00u
#define DET_CFG_OFF_L2  0x10u
#define DET_CFG_OFF_L3  0x20u
#define DET_CFG_OFF_L4  0x30u

#ifdef CAM_DEBUG
static volatile uint32_t cam_raw[4];
#endif

static volatile uint8_t *const buf8 = (volatile uint8_t *)(uintptr_t)MT_BUF_BASE;

static uint8_t rd8(uint32_t off) { return buf8[off]; }

/* One 32x32 RGB565 thumbnail -> NET_IMAGE, 4-channel layout, channel 0 = luma. */
static uint32_t cam_grab(uint8_t *dst)
{
    uint32_t frame;

    for (;;) {
        uint32_t f0 = ARES_MMIO32(CAM_FRAME);
        uint32_t i;

        for (i = 0; i < 1024u; i++) {
            (void)ARES_MMIO32(CAM_PIX_BASE + i * 4u);
            uint32_t p = ARES_MMIO32(CAM_PIX_BASE + i * 4u);
#ifdef CAM_DEBUG
            if (i < 4u) cam_raw[i] = p;
#endif
            p &= 0xFFFFu;

            uint32_t r = ((p >> 11) & 0x1Fu) << 3;
            uint32_t g = ((p >> 5) & 0x3Fu) << 2;
            uint32_t b = (p & 0x1Fu) << 3;
            uint32_t y = (r * 77u + g * 151u + b * 28u) >> 8;

            dst[i * 4u + 0u] = (uint8_t)y;
            dst[i * 4u + 1u] = 0;
            dst[i * 4u + 2u] = 0;
            dst[i * 4u + 3u] = 0;
        }

        frame = ARES_MMIO32(CAM_FRAME);
        if (frame == f0) return frame;
    }
}

/* Brightest 4x4 block of the thumbnail (one eighth of the crop on each axis),
 * plus the frame mean for the "is anything actually bright" test. */
static void track_bright(const uint8_t *img, int *bx, int *by,
                         uint32_t *bavg, uint32_t *mean)
{
    uint32_t total = 0, best = 0;
    int i, j, yy, xx;

    for (i = 0; i < 1024; i++) total += img[i * 4u];
    *mean = total / 1024u;

    *bx = 0; *by = 0; *bavg = 0;

    for (j = 0; j < 8; j++) {
        for (i = 0; i < 8; i++) {
            uint32_t acc = 0;
            for (yy = 0; yy < 4; yy++)
                for (xx = 0; xx < 4; xx++)
                    acc += img[((uint32_t)(j * 4 + yy) * 32u +
                                (uint32_t)(i * 4 + xx)) * 4u];
            if (acc > best) {
                best  = acc;
                *bx   = i;
                *by   = j;
                *bavg = acc / 16u;
            }
        }
    }
}

static void publish_box(int gx, int gy, int visible)
{
    uint32_t x0 = (uint32_t)(320 + gx * 80);
    uint32_t y0 = (uint32_t)(40 + gy * 80);

    ares_mmio_write(OSD_BOX_BASE + 0u, x0);
    ares_mmio_write(OSD_BOX_BASE + 4u, y0);
    ares_mmio_write(OSD_BOX_BASE + 8u, x0 + 80u);
    ares_mmio_write(OSD_BOX_BASE + 12u, y0 + 80u);
    ares_mmio_write(OSD_BOX_BASE + 16u, visible ? 1u : 0u);
}

static void run_detector(net_layer_t *L, uint32_t frame, uint32_t *cmds)
{
    int32_t sum = 0, sy = 0, sx = 0;
    int gy, gx;
    uint32_t start = mt_rd_mcycle();

    net_pad(&L[0]);
    if (net_conv(&L[0], cmds) != 0) { printf("layer1 error\n"); return; }
    net_pool2(MT_BUF_BASE, OUT_BUF, MID_BUF, 2u, 32u, 32u, 0u, 0u);

    net_pad(&L[1]);
    if (net_conv(&L[1], cmds) != 0) { printf("layer2 error\n"); return; }
    net_pool2(MT_BUF_BASE, OUT_BUF, MID_BUF, 4u, 16u, 16u, 0u, 0u);

    net_pad(&L[2]);
    if (net_conv(&L[2], cmds) != 0) { printf("layer3 error\n"); return; }

    net_pad(&L[3]);
    if (net_conv(&L[3], cmds) != 0) { printf("layer4 error\n"); return; }

    for (gy = 0; gy < 8; gy++) {
        for (gx = 0; gx < 8; gx++) {
            int32_t v = (int8_t)rd8(MID_BUF + (((uint32_t)gy * 8u +
                                                (uint32_t)gx) * 4u));
            if (v > 0) { sum += v; sy += v * gy; sx += v * gx; }
        }
    }

    if (sum > 0)
        printf("  net: cell=(%d,%d) t=%u\n",
               (int)((sx * 10) / sum) / 10, (int)((sy * 10) / sum) / 10,
               (unsigned)(mt_rd_mcycle() - start));
    else
        printf("  net: no detection t=%u\n", (unsigned)(mt_rd_mcycle() - start));
}

int yolo_camera_run(void)
{
    net_layer_t L[4];
    static uint8_t img[4096];
    uint32_t frame, cmds = 0, n = 0;

    det_make_layers(L);

    det_copy_to_scratch(NET_WT + DET_WT_OFF_L1, det_wt1, sizeof(det_wt1));
    det_copy_to_scratch(NET_WT + DET_WT_OFF_L2, det_wt2, sizeof(det_wt2));
    det_copy_to_scratch(NET_WT + DET_WT_OFF_L3, det_wt3, sizeof(det_wt3));
    det_copy_to_scratch(NET_WT + DET_WT_OFF_L4, det_wt4, sizeof(det_wt4));
    det_copy_to_scratch(NET_BIAS + DET_BIAS_OFF_L1, det_bias1, sizeof(det_bias1));
    det_copy_to_scratch(NET_BIAS + DET_BIAS_OFF_L2, det_bias2, sizeof(det_bias2));
    det_copy_to_scratch(NET_BIAS + DET_BIAS_OFF_L3, det_bias3, sizeof(det_bias3));
    det_copy_to_scratch(NET_BIAS + DET_BIAS_OFF_L4, det_bias4, sizeof(det_bias4));
    det_copy_to_scratch(NET_CFG + DET_CFG_OFF_L1, det_cfg1, sizeof(det_cfg1));
    det_copy_to_scratch(NET_CFG + DET_CFG_OFF_L2, det_cfg2, sizeof(det_cfg2));
    det_copy_to_scratch(NET_CFG + DET_CFG_OFF_L3, det_cfg3, sizeof(det_cfg3));
    det_copy_to_scratch(NET_CFG + DET_CFG_OFF_L4, det_cfg4, sizeof(det_cfg4));

    printf("tracking the brightest 80x80 block, accelerator every %d frames\n",
           DET_EVERY);
    ares_mmio_write(ARES_LED_ADDR, 1u);

    for (;;) {
        int bx, by;
        uint32_t bavg, mean;

        frame = cam_grab(img);
        track_bright(img, &bx, &by, &bavg, &mean);

        if (bavg > mean + TRACK_MARGIN) {
            publish_box(bx, by, 1);
            printf("f=%u bright=(%d,%d) box=(%d,%d)-(%d,%d) luma=%u/%u\n",
                   (unsigned)frame, bx, by,
                   320 + bx * 80, 40 + by * 80,
                   320 + bx * 80 + 80, 40 + by * 80 + 80,
                   (unsigned)bavg, (unsigned)mean);
        } else {
            publish_box(bx, by, 0);
            printf("f=%u no target luma=%u/%u\n",
                   (unsigned)frame, (unsigned)bavg, (unsigned)mean);
        }

        det_copy_to_scratch(NET_IMAGE, img, 4096u);
        if ((n++ % DET_EVERY) == 0u) run_detector(L, frame, &cmds);
    }
    return 0;
}
