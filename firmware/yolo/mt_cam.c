/*
 * mt_cam.c -- run the packed INT8 detector on the live 32x32 camera thumbnail.
 *
 * The thumbnail comes from cam_cap in the video pipeline:
 *   0xD000_2000 + i*4   pixel i, 0..1023, RGB565 in the low half
 *   0xD000_3000         completed-frame counter
 * The SoC reads it twice (before and after the copy) and retries if a new
 * frame landed in between, so a moving scene cannot tear the input.
 */
#include <stdint.h>
#include "ares_soc.h"
#include "mt.h"
#include "mt_net.h"
#include "mt_detect.h"
#include "mt_detect_weights.h"

#define CAM_PIX_BASE 0xD0002000u
#define CAM_FRAME    0xD0003000u

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
            uint32_t p = ARES_MMIO32(CAM_PIX_BASE + i * 4u) & 0xFFFFu;
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

int yolo_camera_run(void)
{
    net_layer_t L[4];
    uint8_t img[4096];
    uint32_t frame, cmds = 0, start, end;

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

    printf("camera detector ready, watching the 32x32 thumbnail\n");
    ares_mmio_write(ARES_LED_ADDR, 1u);

    for (;;) {
        int32_t sum = 0, sy = 0, sx = 0;
        int gy, gx;

        frame = cam_grab(img);
        det_copy_to_scratch(NET_IMAGE, img, 4096u);

        start = mt_rd_mcycle();

        net_pad(&L[0]);
        if (net_conv(&L[0], &cmds) != 0) { printf("layer1 error\n"); continue; }
        net_pool2(MT_BUF_BASE, OUT_BUF, MID_BUF, 2u, 32u, 32u, 0u, 0u);

        net_pad(&L[1]);
        if (net_conv(&L[1], &cmds) != 0) { printf("layer2 error\n"); continue; }
        net_pool2(MT_BUF_BASE, OUT_BUF, MID_BUF, 4u, 16u, 16u, 0u, 0u);

        net_pad(&L[2]);
        if (net_conv(&L[2], &cmds) != 0) { printf("layer3 error\n"); continue; }

        net_pad(&L[3]);
        if (net_conv(&L[3], &cmds) != 0) { printf("layer4 error\n"); continue; }

        end = mt_rd_mcycle();

        for (gy = 0; gy < 8; gy++) {
            for (gx = 0; gx < 8; gx++) {
                int32_t v = (int8_t)rd8(MID_BUF + (((uint32_t)gy * 8u +
                                                    (uint32_t)gx) * 4u));
                if (v > 0) { sum += v; sy += v * gy; sx += v * gx; }
            }
        }

        if (sum > 0) {
            int cx = (int)((sx * 10) / sum) / 10;
            int cy = (int)((sy * 10) / sum) / 10;
            printf("cam f=%u cell=(%d,%d) box=(%d,%d)-(%d,%d) t=%u\n",
                   (unsigned)frame, cx, cy,
                   320 + cx * 20, 40 + cy * 20,
                   320 + cx * 20 + 20, 40 + cy * 20 + 20,
                   (unsigned)(end - start));
        } else {
            printf("cam f=%u no detection\n", (unsigned)frame);
        }
    }
    return 0;
}
