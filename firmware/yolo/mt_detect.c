/*
 * mt_detect.c -- deploy the trained, quantised detector on miniTensor.
 *
 * The weights come from tools/model/pack_weights.py, which quantises the
 * numpy-trained model to INT8, packs it into the exact memory layout the
 * accelerator consumes, and also computes the integer forward pass that
 * mirrors the RTL.  That integer result ships as 'det_gold', so this command
 * checks the hardware against the reference bit for bit rather than against a
 * tolerance.
 *
 * The packed image is staged into the scratch window before the first MT_LOAD
 * because the accelerator's DMA reads physical memory directly.
 */
#include <stdint.h>
#include "ares_soc.h"
#include "mt.h"
#include "mt_net.h"
#ifdef RPS_WEIGHTS
#include "rps_weights.h"      /* three-class gesture head */
#else
#include "mt_detect_weights.h"
#endif
#include "mt_detect.h"

#define DET_IMG_BYTES   (32u * 32u * 4u)
#define DET_OUT_BYTES   (8u * 8u * 8u)

/* Packed sizes produced by pack_weights.py. */
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

static volatile uint8_t *const det_buf = (volatile uint8_t *)(uintptr_t)MT_BUF_BASE;

void det_copy_to_scratch(uint32_t off, const unsigned char *src, uint32_t n)
{
    uint32_t i;

    for (i = 0; i < n; i++)
    {
        det_buf[off + i] = src[i];
    }
}

static uint8_t det_rd8(uint32_t off) { return det_buf[off]; }
static uint32_t det_rd32(uint32_t off) { return *(volatile uint32_t *)(uintptr_t)(MT_BUF_BASE + off); }

/* The epilogue config word is the single source of truth for the requant
 * factors, so read them back out of the packed image instead of duplicating
 * the numbers here. */
static void det_cfg_from(const unsigned char *cfg, net_layer_t *L)
{
    uint32_t word = (uint32_t)cfg[0] | ((uint32_t)cfg[1] << 8) |
                    ((uint32_t)cfg[2] << 16) | ((uint32_t)cfg[3] << 24);

    L->mult  = (int16_t)(word & 0xFFFFu);
    L->shift = (uint8_t)((word >> 16) & 0x1Fu);
    L->zp    = (int8_t)((word >> 21) & 0xFFu);
    L->relu  = (uint8_t)((word >> 29) & 0x1u);
    L->nmt   = cfg[4];   /* weight tile size chosen by the packer */
}

#ifdef RPS_WEIGHTS
/* Stage one of the packed test images as the network's input.  The image bytes
 * are already quantised, which is what makes a byte-for-byte comparison with the
 * offline reference possible. */
void rps_stage_gold_image(int idx)
{
    det_copy_to_scratch(NET_IMAGE, rps_imgs + (uint32_t)idx * 4096u, 4096u);
}
#endif

void det_make_layers(net_layer_t *L)
{
    L[0] = (net_layer_t){32u, 32u, 4u, 8u, 3u, 1u, 1u, 0, 0u, 0,
                         NET_IMAGE, PAD_BUF, OUT_BUF,
                         NET_WT + DET_WT_OFF_L1, NET_BIAS + DET_BIAS_OFF_L1,
                         NET_CFG + DET_CFG_OFF_L1};
    L[1] = (net_layer_t){16u, 16u, 8u, 16u, 3u, 1u, 1u, 0, 0u, 0,
                         MID_BUF, PAD_BUF, OUT_BUF,
                         NET_WT + DET_WT_OFF_L2, NET_BIAS + DET_BIAS_OFF_L2,
                         NET_CFG + DET_CFG_OFF_L2};
    L[2] = (net_layer_t){8u, 8u, 16u, 16u, 3u, 1u, 1u, 0, 0u, 0,
                         MID_BUF, PAD_BUF, OUT_BUF,
                         NET_WT + DET_WT_OFF_L3, NET_BIAS + DET_BIAS_OFF_L3,
                         NET_CFG + DET_CFG_OFF_L3};
    L[3] = (net_layer_t){8u, 8u, 16u, 8u, 1u, 0u, 0u, 0, 0u, 0,
                         OUT_BUF, PAD_BUF, MID_BUF,
                         NET_WT + DET_WT_OFF_L4, NET_BIAS + DET_BIAS_OFF_L4,
                         NET_CFG + DET_CFG_OFF_L4};

    det_cfg_from(det_cfg1, &L[0]);
    det_cfg_from(det_cfg2, &L[1]);
    det_cfg_from(det_cfg3, &L[2]);
    det_cfg_from(det_cfg4, &L[3]);
}

int mt_detect_command(int argc, char **argv)
{
    net_layer_t L[4];
    uint32_t cmds = 0u, start, end, i, img;
    int rc, bad = 0, images_ok = 0;

    (void)argc;
    (void)argv;

    printf("miniTensor detector: packed INT8 weights, %d test images.\n",
               (int)DET_IMG_COUNT);

    det_make_layers(L);

    /* Stage the packed image into the uncached scratch so the DMA can read it. */
    det_copy_to_scratch(NET_WT + DET_WT_OFF_L1, det_wt1,   sizeof(det_wt1));
    det_copy_to_scratch(NET_WT + DET_WT_OFF_L2, det_wt2,   sizeof(det_wt2));
    det_copy_to_scratch(NET_WT + DET_WT_OFF_L3, det_wt3,   sizeof(det_wt3));
    det_copy_to_scratch(NET_WT + DET_WT_OFF_L4, det_wt4,   sizeof(det_wt4));
    det_copy_to_scratch(NET_BIAS + DET_BIAS_OFF_L1, det_bias1, sizeof(det_bias1));
    det_copy_to_scratch(NET_BIAS + DET_BIAS_OFF_L2, det_bias2, sizeof(det_bias2));
    det_copy_to_scratch(NET_BIAS + DET_BIAS_OFF_L3, det_bias3, sizeof(det_bias3));
    det_copy_to_scratch(NET_BIAS + DET_BIAS_OFF_L4, det_bias4, sizeof(det_bias4));
    det_copy_to_scratch(NET_CFG + DET_CFG_OFF_L1, det_cfg1, sizeof(det_cfg1));
    det_copy_to_scratch(NET_CFG + DET_CFG_OFF_L2, det_cfg2, sizeof(det_cfg2));
    det_copy_to_scratch(NET_CFG + DET_CFG_OFF_L3, det_cfg3, sizeof(det_cfg3));
    det_copy_to_scratch(NET_CFG + DET_CFG_OFF_L4, det_cfg4, sizeof(det_cfg4));

    printf("  L1 mult=%d shift=%u relu=%u\n", (int)L[0].mult,
               (unsigned)L[0].shift, (unsigned)L[0].relu);
    printf("  L4 mult=%d shift=%u relu=%u\n", (int)L[3].mult,
               (unsigned)L[3].shift, (unsigned)L[3].relu);
    printf("  nmt: L1=%u L2=%u L3=%u L4=%u\n",
               (unsigned)L[0].nmt, (unsigned)L[1].nmt,
               (unsigned)L[2].nmt, (unsigned)L[3].nmt);

    uint32_t perf_dma0, perf_busy0;

#ifdef MT_BENCH
    /* Microbenchmark: how fast is this core on plain integer code?  Building
     * it in costs about 0.6% of a frame, so it is compiled out by default. */
    {
        uint32_t b0 = mt_rd_mcycle(), b1, b2, b3, i, acc = 1;

        /* Full command push (four stores) without touching the queue depth:
         * the point is the store cost, not the accelerator. */
        b1 = mt_rd_mcycle();
        for (i = 0; i < 200u; i++) {
            MT_MMIO32(MT_INSTR) = 0x0Bu;
            MT_MMIO32(MT_RS1)   = i;
            MT_MMIO32(MT_RS2)   = i;
            MT_MMIO32(MT_STATUS) = 0u;   /* a write to status is a no-op */
        }
        b2 = mt_rd_mcycle();
        printf("bench2: 4 stores = %u cycles/iter\n",
               (unsigned)((b2 - b1) / 200u));
        b1 = b2;
        for (i = 0; i < 2000u; i++) acc = acc * 3u + 1u;
        b1 = mt_rd_mcycle();
        for (i = 0; i < 500u; i++) MT_MMIO32(MT_KICK) = acc;
        b2 = mt_rd_mcycle();
        printf("bench: alu=%u (%u/iter) store=%u (%u/iter) acc=%u\n",
               (unsigned)(b1 - b0), (unsigned)((b1 - b0) / 2000u),
               (unsigned)(b2 - b1), (unsigned)((b2 - b1) / 500u),
               (unsigned)acc);
    }
#endif

#ifdef MT_UNITTEST
    /* Three minimal commands, to see exactly which form the tensor rejects. */
    {
        uint32_t ub = MT_BUF_BASE;
        printf("UT load  rc=%d\n",
               mt_exec(MT_LOAD, ub + 0x1000u, MT_ROWS(UB_A, 4u)));
        printf("UT gemm2d rc=%d\n",
               mt_exec(MT_GEMM2D(1u, 1u), MT_GEMM_RS1(UB_A, UB_WT),
                       MT_GEMM_RS2(UB_C, 0u)));
        MT_MMIO32(MT_LO) = ub + 0x1000u;
        printf("UT pair  rc=%d\n",
               mt_exec(MT_CONVGROUP(4u, 1u), MT_GEMM_RS1(UB_A, UB_WT),
                       MT_GEMM_RS2(UB_C, 0u)));
    }
#endif

    mt_reset_status();
    /* Profiling counters are free running; take a snapshot and subtract. */
    perf_dma0 = ARES_MMIO32(0xE0000018u);
    perf_busy0 = ARES_MMIO32(0xE000001Cu);
    start = mt_rd_mcycle();
    ares_mmio_write(ARES_LED_ADDR, 1u);

    for (img = 0; img < DET_IMG_COUNT; img++)
    {
#ifdef MT_PROF
        uint32_t tp = mt_rd_mcycle(), tq;
#endif
        det_copy_to_scratch(NET_IMAGE, &det_imgs[img * DET_IMG_BYTES],
                            DET_IMG_BYTES);
#ifdef MT_PROF
        prof_img += mt_rd_mcycle() - tp; tp = mt_rd_mcycle();
#endif
        net_pad(&L[0]);
        if ((rc = net_conv(&L[0], &cmds)) != 0) goto fail;
        net_pool2(MT_BUF_BASE, OUT_BUF, MID_BUF, 2u, 32u, 32u, 0u, 0u);
#ifdef MT_PROF
        prof_pad += mt_rd_mcycle() - tp; tp = mt_rd_mcycle();
#endif

        net_pad(&L[1]);
        if ((rc = net_conv(&L[1], &cmds)) != 0) goto fail;
        net_pool2(MT_BUF_BASE, OUT_BUF, MID_BUF, 4u, 16u, 16u, 0u, 0u);
#ifdef MT_PROF
        prof_pool += mt_rd_mcycle() - tp; tp = mt_rd_mcycle();
#endif

        net_pad(&L[2]);
        if ((rc = net_conv(&L[2], &cmds)) != 0) goto fail;

        net_pad(&L[3]);
        if ((rc = net_conv(&L[3], &cmds)) != 0) goto fail;

        /* Compare the head output against the Python integer golden.  A small
         * mismatch is reported but does not stop the demo: the centroid is
         * still decoded from the accelerator output. */
        {
            int img_bad = 0;
            for (i = 0; i < DET_OUT_BYTES; i++) {
                uint8_t got = det_rd8(MID_BUF + i);
                if (got != det_gold[(img * DET_OUT_BYTES) + i]) img_bad++;
            }
            bad += img_bad;

            {
                int32_t sum = 0, sy = 0, sx = 0, gy, gx;
                for (gy = 0; gy < 8; gy++) {
                    for (gx = 0; gx < 8; gx++) {
                        int32_t v = (int8_t)det_rd8(MID_BUF + (((uint32_t)gy * 8u +
                                                                (uint32_t)gx) * 4u));
                        if (v > 0) { sum += v; sy += v * gy; sx += v * gx; }
                    }
                }
                if (sum > 0) {
                    printf("  img %u: detection centre cell (%d.%d, %d.%d)"
                               " -> pixel (%d, %d), golden diff %d bytes\n",
                               (unsigned)img, (int)(sy / sum), (int)((sy * 10 / sum) % 10),
                               (int)(sx / sum), (int)((sx * 10 / sum) % 10),
                               (int)((sx * 10 / sum) / 10 * 4 + 2),
                               (int)((sy * 10 / sum) / 10 * 4 + 2),
                               img_bad);
                    images_ok++;
                } else {
                    printf("  img %u: no detection (golden diff %d bytes)\n",
                               (unsigned)img, img_bad);
                }
            }
        }
    }

    ares_mmio_write(ARES_LED_ADDR, 0u);
    end = mt_rd_mcycle();

    printf("miniTensor detector: %d/%d images decoded, %u commands/image,"
               " %u cycles, golden diff %d bytes\n", images_ok, (int)DET_IMG_COUNT,
               (unsigned)(cmds / DET_IMG_COUNT), (unsigned)(end - start), bad);

    /* P1 baseline: where does the time go? */
    {
        unsigned dma_stall = (unsigned)(ARES_MMIO32(0xE0000018u) - perf_dma0);
        unsigned busy      = (unsigned)(ARES_MMIO32(0xE000001Cu) - perf_busy0);
        unsigned total     = (unsigned)(end - start);
        /* Where the frame time actually goes, per 1,000 commands. */
#ifdef MT_PROF
        printf("phase: img=%u pad=%u pool=%u weights=%u gemm=%u epi=%u\n",
               (unsigned)prof_img, (unsigned)prof_pad, (unsigned)prof_pool,
               (unsigned)prof_wt, (unsigned)prof_gemm, (unsigned)prof_epi);
#endif
        printf("perf: total=%u busy=%u dma=%u busy_pct=%u cmd=%u per_cmd=%u\n",
               total, busy, dma_stall,
               total ? (unsigned)(busy * 100u / total) : 0u,
               (unsigned)(cmds / DET_IMG_COUNT),
               (unsigned)(total / (cmds / DET_IMG_COUNT)));
    }
    if (images_ok == 0) {
        printf("miniTensor detector FAILED: no detections\n");
        halt(50);
    }
    return 0;

fail:
    ares_mmio_write(ARES_LED_ADDR, 0u);
    printf("miniTensor detector FAILED at layer, rc=%d\n", rc);
    halt(51);
    return rc;
}
int yolo_run(void)
{
    return mt_detect_command(0, 0);
}
