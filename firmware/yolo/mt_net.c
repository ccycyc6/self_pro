/*
 * mt_net.c -- a small YOLO-shaped detection network on the miniTensor tile engine.
 *
 * Topology (single class, single anchor, anchor-free decode):
 *
 *   input 32x32x4
 *     conv 3x3  4->8   pad 1, ReLU      32x32x8
 *     maxpool 2x2                        16x16x8
 *     conv 3x3  8->16  pad 1, ReLU      16x16x16
 *     maxpool 2x2                         8x8x16
 *     conv 3x3 16->16  pad 1, ReLU        8x8x16
 *     head 1x1 16->8   (4 box + 1 obj + 1 cls, padded to 8)
 *
 * ---------------------------------------------------------------------------
 * Why A is the activations and B is the weights
 * ---------------------------------------------------------------------------
 * MT_GEMM computes C[i][j] = sum_k A[i][k]*B[k][j], with A and B each packed into
 * one 16-byte UB row (A row-major: byte 4i+k, B row-major: byte 4k+j).
 *
 * Choosing i = spatial position, j = output channel, k = input channel gives
 * A[i][k] = x[spatial i][input channel k].  Storing activations as NHWC grouped
 * by 4 channels puts channel k of spatial position i at byte 4i+k -- exactly the
 * A row layout -- and 4 consecutive spatial positions are 16 contiguous bytes.
 * So the activation operand is ONE linear MT_LOAD, with no im2col pass at all.
 *
 * The B (weight) rows are tiny -- (C/4)*(C_out/4)*k*k of them -- and stay
 * resident in the UB for the whole layer.
 *
 * The CPU only builds a zero-padded copy of the previous layer's output, and the
 * accelerator itself already emits the [group][h][w][4] layout, so no repacking
 * is needed anywhere.
 */
#include <stdint.h>
#include "mt.h"
#include "mt_net.h"

static void    net_wr8(uint32_t addr, uint8_t v)  { *(volatile uint8_t *)(uintptr_t)addr = v; }
static uint8_t net_rd8(uint32_t addr)             { return *(volatile uint8_t *)(uintptr_t)addr; }

void net_pad(const net_layer_t *L)
{
    uint32_t ng = L->c_in / 4u, H = L->h, W = L->w;
    uint32_t PH = H + (2u * L->pad);
    /* SW is the source buffer's row stride; only its first W pixels are valid.
     * WP is the padded row stride of the pad buffer.  Both default to W, which
     * reproduces the unpadded behaviour exactly. */
    uint32_t SW = L->src_w ? L->src_w : W;
    uint32_t WP = L->wpad ? L->wpad : W;
    uint32_t B = L->base ? L->base : MT_BUF_BASE;
    uint32_t kx, g, h, wo;

    /* One 32-bit word per pixel: the layout is 4 channels per position, so a
     * pixel is exactly one word.  The previous version copied it a byte at a
     * time through volatile pointers with the bounds test inside the inner
     * loop, which cost more than the convolutional layers themselves. */
    for (kx = 0; kx < L->k; kx++)
    {
        int32_t shift = (int32_t)kx - (int32_t)L->pad;

        for (g = 0; g < ng; g++)
        {
            volatile uint32_t *dst = (volatile uint32_t *)(uintptr_t)
                (B + L->pad_off + (((kx * ng) + g) * PH * WP) * 4u);
            const volatile uint32_t *src = (const volatile uint32_t *)(uintptr_t)
                (B + L->src_off + (g * H * SW) * 4u);

            for (h = 0; h < PH; h++)
            {
                int32_t sh = (int32_t)h - (int32_t)L->pad;

                if (sh < 0 || sh >= (int32_t)H)
                {
                    for (wo = 0; wo < WP; wo++) dst[wo] = 0u;
                }
                else
                {
                    const volatile uint32_t *srow = src + ((uint32_t)sh * SW);
                    /* Split the row into [zeros][copy][zeros] so the copy loop
                     * has no per-pixel branch. */
                    int32_t first = (shift >= 0) ? 0 : -shift;
                    int32_t last  = (int32_t)W - shift;

                    if (first < 0) first = 0;
                    if (last > (int32_t)WP) last = (int32_t)WP;

                    for (wo = 0; wo < (uint32_t)first; wo++) dst[wo] = 0u;
                    for (wo = (uint32_t)first; wo < (uint32_t)last; wo++)
                        dst[wo] = srow[(int32_t)wo + shift];
                    for (wo = (uint32_t)last; wo < WP; wo++) dst[wo] = 0u;
                }
                dst += WP;
            }
        }
    }
}

#ifdef MT_PROF
/* Phase timers, compiled out by default. */
uint32_t prof_wt, prof_gemm, prof_epi, prof_tile;
uint32_t prof_img, prof_pad, prof_pool;
#define PROF_NOW() mt_rd_mcycle()
#define PROF_ACC(v, t0) do { v += mt_rd_mcycle() - (t0); (t0) = mt_rd_mcycle(); } while (0)
#endif

int net_conv(const net_layer_t *L, uint32_t *cmds)
{
    uint32_t ng = L->c_in / 4u, nm = L->c_out / 4u;
    uint32_t H = L->h, W = L->w;
    /* Compute and store at the padded width; the consumer reads only W of it. */
    uint32_t WP = L->wpad ? L->wpad : W;
    uint32_t PH = H + (2u * L->pad);
    uint32_t ntiles = WP / 4u;
    uint32_t kk = L->k * L->k;
    uint32_t k  = L->k;
    uint32_t ntap = kk * ng;
    uint32_t ntiles4 = ntiles * 4u;
    uint32_t B = L->base ? L->base : MT_BUF_BASE;
    uint32_t nmt = L->nmt ? L->nmt : nm;   /* output groups per weight tile */
    uint32_t ho, t, q, mt, j, i, tile, t0;
    uint32_t count = 0u;
    int rc;


    /* GEMM bursts walk the output groups inside a tile: the A and B rows step
     * by one, the C row by a whole tile column.  Written once per layer. */
    /* A row stays put for the whole run (it is the activation row for this
     * tile column); only the weight row and the C row advance. */
    /* NOTE: the steps are re-armed per tap below, because the epilogue switches
     * them to its own pattern -- leaving the last one armed silently corrupts
     * the next row's GEMMs. */

    if ((rc = mt_push(MT_LOAD, B + L->cfg_off,
                      MT_ROWS(UB_CFG, L->leaky ? 2u : 1u))) != 0) return rc;
    count++;

    for (mt = 0, tile = 0u; mt < nm; mt += nmt, tile++)
    {
        uint32_t nl   = nm - mt;                       /* groups left        */
        uint32_t njt  = (nl < nmt) ? nl : nmt;         /* groups in this tile */
        /* Every tile occupies a full ntap*nmt row slot, so the base advances
         * by the TILE index -- using the group index here skips slots. */
        uint32_t wbase = L->wt_off + (tile * ntap * nmt * 16u);
        /* Taps are finished in chunks that fit UB_WT.  A layer with 32 input
         * groups and 3x3 taps needs 288 weight rows while UB_WT holds 144, so
         * one tile is impossible for it; splitting over taps keeps the weights
         * resident while that row's GEMMs run, and costs no extra DMA because
         * each tap's weight row is still fetched exactly once. */
        uint32_t na = MT_UB_WT_ROWS / njt;             /* taps per chunk     */
        uint32_t tc, nq;

        if (na == 0u)
        {
            return -6;      /* not even one output group fits UB_WT */
        }
        if (na > ntap) { na = ntap; }

        /* The bias for a run of groups is contiguous (4 rows per group). */
        if ((rc = mt_push(MT_LOAD, B + L->bias_off + (mt * 64u),
                          MT_ROWS(UB_BIAS, njt * 4u))) != 0) return rc;
        count++;

        for (ho = 0; ho < H; ho++)
        {
            uint32_t hrow = ho * ntiles;

#ifdef MT_PROF
            uint32_t prof_t0 = PROF_NOW();
#endif
            for (tc = 0; tc < ntap; tc += na)
            {
                nq = (ntap - tc) < na ? (ntap - tc) : na;

                /* Taps [tc, tc+nq) of every group in the tile are contiguous in
                 * the packed blob: row = q*nmt + j. */
                for (i = 0; i < (nq * njt); i += 8u)
                {
                    uint32_t n = ((nq * njt) - i) < 8u ? ((nq * njt) - i) : 8u;

                    if ((rc = mt_push(MT_LOAD,
                                      B + wbase + (((tc * njt) + i) * 16u),
                                      MT_ROWS(UB_WT + i, n))) != 0) return rc;
                    count++;
                }

#ifdef MT_PROF
                PROF_ACC(prof_wt, prof_t0);
#endif
                /* q (the tap) is the outer loop on purpose: decoding a tap
                 * index into (g, ky, kx) costs two divisions, and with t on
                 * the outside that decode ran once per (tap, tile) pair --
                 * up to 16x more often than needed.  The command order changes
                 * but not the set of commands, and every LOAD still precedes
                 * the GEMMs that consume it. */
                for (q = tc; q < tc + nq; q++)
                {
                    uint32_t g   = q / kk;
                    uint32_t rem = q % kk;
                    uint32_t ky  = rem / k;
                    uint32_t kx  = rem % k;
                    uint32_t qbase = (((((kx * ng) + g) * PH) + ky) * ntiles) + hrow;
                    uint32_t wb = UB_WT + ((q - tc) * njt);

                    /* Re-arm the GEMM steps: per column the A row advances by
                     * one and the C row by four; per output group the weight
                     * row by one. */
                    MT_SET_STEPS4(1u, 1u, 4u, ntiles4);

                    /* UB_A holds four activation rows and consecutive tiles are
                     * contiguous in memory, so one DMA brings in four tiles'
                     * worth of A.  That removes three quarters of the LOADs
                     * without touching the GEMM sequence. */
                    for (t = 0; t < ntiles; t += 4u)
                    {
                        uint32_t n = ((ntiles - t) < 4u) ? (ntiles - t) : 4u;
                        uint32_t a_addr = L->pad_off + 16u * (qbase + t);
                        uint32_t crow0 = UB_C + (t * 4u);
                        uint32_t rs1 = MT_GEMM_RS1(UB_A, wb);
                        uint32_t rs2 = MT_GEMM_RS2(crow0,
                                                   (tc == 0u && q == tc)
                                                       ? 0u : 1u);

                        if ((rc = mt_push(MT_LOAD, B + a_addr,
                                          MT_ROWS(UB_A, n))) != 0) return rc;
                        count++;

                        /* One push covers the whole u x j grid of this tile
                         * group: the shim walks the columns (A row +1, C row
                         * +4) and the output groups inside a column (weight
                         * row +1). */
                        if ((rc = mt_push(MT_GEMM2D(n, njt), rs1, rs2)) != 0)
                            return rc;
                        count++;
                    }
                }
            }

#ifdef MT_PROF
                PROF_ACC(prof_gemm, prof_t0);
#endif
        /* The epilogue runs once the whole row's GEMMs are queued.  It stays
         * inside the ho loop: UB_OUT holds one output row. */
        for (j = 0; j < njt; j++)
        {
            uint32_t crow = UB_C + (j * ntiles4);

                /* UB_OUT and UB_SKIP have 8 rows each, so an output row is
                 * finished in chunks of at most 8 tiles.  W up to 32 fits in
                 * one chunk; wider layers need several -- tiny-yolov3's stem is
                 * 64 wide, i.e. 16 tiles.  Without this the second epilogue's
                 * destination runs past the end of the UB row space and wraps
                 * back into the weight rows, corrupting the layer. */
                for (t0 = 0; t0 < ntiles; t0 += 8u)
                {
                    uint32_t n = (ntiles - t0) < 8u ? (ntiles - t0) : 8u;
                    uint32_t off16 = t0 * 16u;

                    /* One epilogue per chunk: the C row advances by one tile
                     * column (4 rows), the output row by one. */
                    MT_SET_STEPS(4u, 0u, 1u);
                    if ((rc = mt_push(MT_BURST(MT_EPILOGUE, n),
                                      MT_EPI_RS1(crow + (t0 * 4u),
                                                 UB_BIAS + (j * 4u)),
                                      MT_EPI_RS2(UB_OUT, UB_CFG))) != 0)
                    {
                        return rc;
                    }
                    count++;

                    /* LeakyReLU as max(x, a*x), using the second config row.
                     * The second epilogue writes to UB_SKIP, which is still
                     * free here (the residual loads it later). */
                    if (L->leaky != 0u)
                    {
                        MT_SET_STEPS(4u, 0u, 1u);
                        if ((rc = mt_push(MT_BURST(MT_EPILOGUE, n),
                                          MT_EPI_RS1(crow + (t0 * 4u),
                                                     UB_BIAS + (j * 4u)),
                                          MT_EPI_RS2(UB_SKIP, UB_CFG + 1u))) != 0)
                        {
                            return rc;
                        }
                        count++;

                        MT_SET_STEPS(1u, 1u, 1u);
                        if ((rc = mt_push(MT_BURST(MT_VEC_MAX8, n),
                                          MT_VEC_RS1(UB_OUT, UB_SKIP),
                                          MT_VEC_RS2(UB_OUT))) != 0)
                        {
                            return rc;
                        }
                        count++;
                    }

                    /* Residual: bring in the matching skip rows and combine
                     * them with the vector unit. */
                    if (L->skip != 0u)
                    {
                        uint32_t sbase = L->skip_off +
                                         ((((mt + j) * H) + ho) * WP * 4u) + off16;

                        if ((rc = mt_push(MT_LOAD, B + sbase,
                                          MT_ROWS(UB_SKIP, n))) != 0) return rc;
                        count++;
                        MT_SET_STEPS(1u, 1u, 1u);
                        if ((rc = mt_push(MT_BURST(MT_VEC_ADD8, n),
                                          MT_VEC_RS1(UB_OUT, UB_SKIP),
                                          MT_VEC_RS2(UB_OUT))) != 0)
                        {
                            return rc;
                        }
                        count++;
                        if (L->skip == 2u)
                        {
                            MT_SET_STEPS(1u, 1u, 1u);
                            if ((rc = mt_push(MT_BURST(MT_VEC_RELU8, n),
                                              MT_VEC_RS1(UB_OUT, UB_OUT),
                                              MT_VEC_RS2(UB_OUT))) != 0)
                            {
                                return rc;
                            }
                            count++;
                        }
                    }

                    if ((rc = mt_push(MT_STORE,
                                      B + L->out_off +
                                          ((((mt + j) * H) + ho) * WP * 4u) + off16,
                                      MT_ROWS(UB_OUT, n))) != 0) return rc;
                    count++;
                }
#ifdef MT_PROF
            PROF_ACC(prof_epi, prof_t0);
#endif
            }
        }
    }

    *cmds += count;

    /* Commands are queued without per-command polling, so the layer only has to
     * wait once here -- before the caller inspects the output buffer. */
    return mt_drain();
}

void net_pool_k(uint32_t base, uint32_t src_off, uint32_t dst_off, uint32_t g_count,
                uint32_t h, uint32_t w, uint32_t k, uint32_t stride,
                uint32_t sw, uint32_t dw)
{
    /* Output extent for a k x k window with the given stride.  Only stride 1
     * and 2 are used (stride 2/k 2 is the usual downsample; the stride-1 test
     * pool shrinks by one).  The division is written out as shifts on purpose:
     * the pooling path stays free of the multi-cycle DIV unit. */
    uint32_t oh, ow;
    uint32_t g, oy, ox, ky, kx;

    if (stride == 1u) { oh = h - k + 1u; ow = w - k + 1u; }
    else              { oh = ((h - k) >> 1) + 1u; ow = ((w - k) >> 1) + 1u; }

    if (sw == 0u) { sw = w; }        /* source row stride                */
    if (dw == 0u) { dw = ow; }       /* destination row stride, padded   */

    for (g = 0; g < g_count; g++)
    {
        volatile uint32_t *drow = (volatile uint32_t *)(uintptr_t)
            (base + dst_off + (g * oh * dw) * 4u);

        for (oy = 0; oy < oh; oy++)
        {
            const volatile uint32_t *s0 = (const volatile uint32_t *)(uintptr_t)
                (base + src_off + (((g * h) + (oy * stride)) * sw) * 4u);

            for (ox = 0; ox < dw; ox++)
            {
                /* The four channels of a pixel share one 32-bit word, so the
                 * whole pixel is fetched once and the maximum is taken per
                 * byte lane.  The old version walked c in an outer loop and
                 * recomputed the full address four times per output. */
                uint32_t out = 0u;

                if (ox < ow)
                {
                    int32_t b0 = -128, b1 = -128, b2 = -128, b3 = -128;

                    for (ky = 0; ky < k; ky++)
                    {
                        const volatile uint32_t *srow =
                            s0 + (ky * sw) + (ox * stride);

                        for (kx = 0; kx < k; kx++)
                        {
                            uint32_t v  = srow[kx];
                            int32_t  v0 = (int8_t)(v);
                            int32_t  v1 = (int8_t)(v >> 8);
                            int32_t  v2 = (int8_t)(v >> 16);
                            int32_t  v3 = (int8_t)(v >> 24);

                            if (v0 > b0) b0 = v0;
                            if (v1 > b1) b1 = v1;
                            if (v2 > b2) b2 = v2;
                            if (v3 > b3) b3 = v3;
                        }
                    }
                    out = ((uint32_t)b0 & 0xFFu) |
                          (((uint32_t)b1 & 0xFFu) << 8) |
                          (((uint32_t)b2 & 0xFFu) << 16) |
                          (((uint32_t)b3 & 0xFFu) << 24);
                }
                drow[ox] = out;
            }
            drow += dw;
        }
    }
}


void net_pool2(uint32_t base, uint32_t src_off, uint32_t dst_off, uint32_t g_count,
               uint32_t h, uint32_t w, uint32_t sw, uint32_t dw)
{
    net_pool_k(base, src_off, dst_off, g_count, h, w, 2u, 2u, sw, dw);
}

void net_pool_k_same(uint32_t base, uint32_t src_off, uint32_t dst_off,
                     uint32_t g_count, uint32_t h, uint32_t w, uint32_t k,
                     uint32_t stride, uint32_t sw, uint32_t dw)
{
    /* ONNX SAME_UPPER: out = ceil(in/stride), padding only at the
     * bottom/right.  Skipping the out-of-range taps is exactly a -inf pad for
     * a max pool.  Stride is 1 or 2, and the shift keeps DIV out of the path
     * for the same reason net_pool_k does. */
    uint32_t oh, ow;
    uint32_t g, oy, ox, c;

    if (stride == 1u) { oh = h; ow = w; }
    else              { oh = (h + 1u) >> 1; ow = (w + 1u) >> 1; }

    if (sw == 0u) { sw = w; }
    if (dw == 0u) { dw = ow; }

    for (g = 0; g < g_count; g++)
    for (oy = 0; oy < oh; oy++)
    for (ox = 0; ox < dw; ox++)
    for (c = 0; c < 4u; c++)
    {
        uint8_t out = 0u;

        if (ox < ow)
        {
            int32_t best = -128;
            uint32_t ky, kx;

            for (ky = 0; ky < k; ky++)
            {
                uint32_t iy = (oy * stride) + ky;

                if (iy >= h) { continue; }
                for (kx = 0; kx < k; kx++)
                {
                    uint32_t ix = (ox * stride) + kx;
                    int8_t v;

                    if (ix >= w) { continue; }
                    v = (int8_t)net_rd8(base + src_off
                        + (((((g * h) + iy) * sw) + ix) * 4u) + c);
                    if (v > best) { best = v; }
                }
            }
            out = (uint8_t)best;
        }
        net_wr8(base + dst_off + (((((g * oh) + oy) * dw) + ox) * 4u) + c, out);
    }
}

void net_upsample2(uint32_t base, uint32_t src_off, uint32_t dst_off, uint32_t g_count,
                   uint32_t h, uint32_t w, uint32_t sw, uint32_t dw)
{
    /* Resize(nearest, floor, asymmetric): every source pixel becomes a 2x2
     * block, so out[2y+dy][2x+dx] = src[y][x]. */
    uint32_t oh = 2u * h, ow = 2u * w;
    uint32_t g, oy, ox, c;

    if (sw == 0u) { sw = w; }
    if (dw == 0u) { dw = ow; }

    for (g = 0; g < g_count; g++)
    for (oy = 0; oy < oh; oy++)
    for (ox = 0; ox < dw; ox++)
    for (c = 0; c < 4u; c++)
    {
        uint8_t v = 0u;

        if (ox < ow)
        {
            uint32_t sy = oy >> 1, sx = ox >> 1;

            v = net_rd8(base + src_off + (((((g * h) + sy) * sw) + sx) * 4u) + c);
        }
        net_wr8(base + dst_off + (((((g * oh) + oy) * dw) + ox) * 4u) + c, v);
    }
}

void net_concat2(uint32_t base, uint32_t dst_off,
                 uint32_t src1_off, uint32_t g1, uint32_t src2_off, uint32_t g2,
                 uint32_t h, uint32_t w)
{
    /* Both sources and the destination are contiguous [g][h][w][4] runs, so a
     * concat is two block copies; no per-pixel work is needed. */
    uint32_t run = h * w * 4u;
    uint32_t i;

    for (i = 0; i < g1 * run; i++)
    {
        net_wr8(base + dst_off + i, net_rd8(base + src1_off + i));
    }
    for (i = 0; i < g2 * run; i++)
    {
        net_wr8(base + dst_off + (g1 * run) + i, net_rd8(base + src2_off + i));
    }
}
