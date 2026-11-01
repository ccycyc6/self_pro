/* Stereo block matching for the height pipeline.
 *
 * Pure functions over two byte images, so the same code runs on the board and
 * under gcc in tools/stereo/test_stereo.c.  Integer only: the RV32IM core has no
 * FPU.
 *
 * Disparity is carried in quarter pixels (Q4).  At 320 wide, f = 275 px and
 * B = 70 mm, one whole pixel at 2 m is 34 cm of depth, so sub-pixel matters:
 * a parabola through the SAD minimum recovers roughly a quarter pixel.
 */
#include "stereo.h"

static uint32_t isqrt32(uint32_t v)
{
    uint32_t r = 0, bit = 1u << 30;

    while (bit > v) bit >>= 2;
    while (bit) {
        if (v >= r + bit) {
            v -= r + bit;
            r = (r >> 1) + bit;
        } else {
            r >>= 1;
        }
        bit >>= 2;
    }
    return r;
}

uint32_t st_depth_mm(const int32_t d_q4)
{
    /* Z = f * B / d, with d in Q4 -> Z_mm = f * B * 4 / d_q4 (f in px, B in mm) */
    if (d_q4 <= 0) return 0;
    return (uint32_t)(((uint32_t)ST_F_PX * ST_BASELINE_MM * 4u) / (uint32_t)d_q4);
}

uint32_t st_height_mm(uint32_t depth_mm, int32_t v_px)
{
    if (v_px <= 0 || depth_mm == 0) return 0;
    /* height = Z * v / f */
    return (uint32_t)(((uint64_t)depth_mm * (uint32_t)v_px) / ST_F_PX);
}

static uint32_t sad_block(const uint8_t *l, const uint8_t *r, int lw)
{
    uint32_t s = 0;
    int i, j;

    for (j = 0; j < ST_BLOCK; j++) {
        const uint8_t *lp = l + j * lw;
        const uint8_t *rp = r + j * lw;
        for (i = 0; i < ST_BLOCK; i++) {
            int d = (int)lp[i] - (int)rp[i];
            s += (uint32_t)(d < 0 ? -d : d);
        }
    }
    return s;
}

int32_t st_match_block(const uint8_t *left, const uint8_t *right,
                       int x, int y, int32_t *out_cost)
{
    uint32_t cost[ST_DMAX + 1];
    uint32_t lo = 255u * ST_BLOCK * ST_BLOCK, hi = 0;
    int d, best = 0, nd = 0;

    for (d = 0; d <= ST_DMAX; d++) {
        if (x - d < 0) break;
        cost[d] = sad_block(left + (uint32_t)y * ST_W + (uint32_t)x,
                            right + (uint32_t)y * ST_W + (uint32_t)(x - d),
                            ST_W);
        if (cost[d] < cost[best]) best = d;
        if (cost[d] < lo) lo = cost[d];
        if (cost[d] > hi) hi = cost[d];
        nd = d + 1;
    }

    if (nd < 3) return -1;
    /* A flat block (no texture) matches everywhere; refuse it rather than
     * report a bogus depth. */
    if (hi - lo < 6u * ST_BLOCK * ST_BLOCK) return -1;
    if (lo > 40u * ST_BLOCK * ST_BLOCK) return -1;

    if (out_cost) *out_cost = (int32_t)cost[best];

    {
        int32_t off_q4 = 0;
        if (best > 0 && best < nd - 1) {
            int32_t s0 = (int32_t)cost[best - 1];
            int32_t s1 = (int32_t)cost[best];
            int32_t s2 = (int32_t)cost[best + 1];
            int32_t den = 2 * (s0 - 2 * s1 + s2);
            if (den != 0) {
                int32_t off = ((s0 - s2) * 4) / den;   /* quarter pixels */
                if (off > 2) off = 2;
                if (off < -2) off = -2;
                off_q4 = off;
            }
        }
        return best * 4 + off_q4;
    }
}

static int cmpq4(const void *a, const void *b)
{
    int32_t x = *(const int32_t *)a, y = *(const int32_t *)b;
    return (x > y) - (x < y);
}

int32_t st_match_box(const uint8_t *left, const uint8_t *right,
                     int x0, int y0, int x1, int y1, int *count)
{
    int32_t vals[64];
    int n = 0, x, y;

    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > ST_W - ST_BLOCK) x1 = ST_W - ST_BLOCK;
    if (y1 > ST_H - ST_BLOCK) y1 = ST_H - ST_BLOCK;

    for (y = y0; y + ST_BLOCK <= y1 && n < 64; y += ST_BLOCK) {
        for (x = x0; x + ST_BLOCK <= x1 && n < 64; x += ST_BLOCK) {
            int32_t d = st_match_block(left, right, x, y, 0);
            if (d >= 0) vals[n++] = d;
        }
    }
    if (count) *count = n;
    if (n == 0) return -1;

    /* insertion sort: n <= 64 */
    {
        int i, j;
        for (i = 1; i < n; i++) {
            int32_t v = vals[i];
            for (j = i - 1; j >= 0 && vals[j] > v; j--) vals[j + 1] = vals[j];
            vals[j + 1] = v;
        }
    }
    return vals[n / 2];
}

/* ---------------------------------------------------------------- ROI path
 * The right window starts ST_DMAX pixels left of the left window, so pixel
 * (x - d) lives at r[(x - d) + ST_DMAX].
 */
static uint32_t sad_roi(const uint8_t *l, int lw, const uint8_t *r, int rw,
                        int x, int y, int d)
{
    uint32_t s = 0;
    int i, j;

    for (j = 0; j < ST_BLOCK; j++) {
        const uint8_t *lp = l + (uint32_t)(y + j) * (uint32_t)lw + (uint32_t)x;
        const uint8_t *rp = r + (uint32_t)(y + j) * (uint32_t)rw
                              + (uint32_t)(x + ST_DMAX - d);
        for (i = 0; i < ST_BLOCK; i++) {
            int v = (int)lp[i] - (int)rp[i];
            s += (uint32_t)(v < 0 ? -v : v);
        }
    }
    return s;
}

static int32_t match_roi_block(const uint8_t *l, int lw,
                               const uint8_t *r, int rw, int x, int y)
{
    uint32_t cost[ST_DMAX + 1];
    uint32_t lo = 255u * ST_BLOCK * ST_BLOCK, hi = 0;
    int d, best = 0, nd = 0;

    for (d = 0; d <= ST_DMAX; d++) {
        cost[d] = sad_roi(l, lw, r, rw, x, y, d);
        if (cost[d] < cost[best]) best = d;
        if (cost[d] < lo) lo = cost[d];
        if (cost[d] > hi) hi = cost[d];
        nd = d + 1;
    }
    if (nd < 3) return -1;
    if (hi - lo < 6u * ST_BLOCK * ST_BLOCK) return -1;
    if (lo > 40u * ST_BLOCK * ST_BLOCK) return -1;

    /* A clear winner beats the best cost that is at least two pixels away.
     * Without this a tie between two similar depths flips the answer from frame
     * to frame, which is exactly what the readout did. */
    {
        uint32_t second = 0xFFFFFFFFu;
        int d2;
        for (d2 = 0; d2 < nd; d2++) {
            if (d2 >= best - 1 && d2 <= best + 1) continue;
            if (cost[d2] < second) second = cost[d2];
        }
        if (second != 0xFFFFFFFFu && (uint64_t)lo * 10u > (uint64_t)second * 6u)
            return -1;
    }

    {
        int32_t off_q4 = 0;
        if (best > 0 && best < nd - 1) {
            int32_t s0 = (int32_t)cost[best - 1];
            int32_t s1 = (int32_t)cost[best];
            int32_t s2 = (int32_t)cost[best + 1];
            int32_t den = 2 * (s0 - 2 * s1 + s2);
            if (den != 0) {
                int32_t off = ((s0 - s2) * 4) / den;
                if (off > 2) off = 2;
                if (off < -2) off = -2;
                off_q4 = off;
            }
        }
        return best * 4 + off_q4;
    }
}

int32_t st_match_roi(const uint8_t *left, int lw,
                     const uint8_t *right, int rw,
                     int x0, int y0, int x1, int y1, int *count)
{
    int32_t vals[64];
    int n = 0, x, y, i, j;

    for (y = y0; y + ST_BLOCK <= y1 && n < 64; y += ST_BLOCK) {
        for (x = x0; x + ST_BLOCK <= x1 && n < 64; x += ST_BLOCK) {
            int32_t d = match_roi_block(left, lw, right, rw, x, y);
            if (d >= 0) vals[n++] = d;
        }
    }
    if (count) *count = n;
    if (n == 0) return -1;

    for (i = 1; i < n; i++) {
        int32_t v = vals[i];
        for (j = i - 1; j >= 0 && vals[j] > v; j--) vals[j + 1] = vals[j];
        vals[j + 1] = v;
    }
    return vals[n / 2];
}

int32_t st_match_roi_step(const uint8_t *left, int lw,
                          const uint8_t *right, int rw,
                          int x0, int y0, int x1, int y1, int step,
                          int *count)
{
    int32_t vals[64];
    int n = 0, x, y, i, j;

    if (step < ST_BLOCK) step = ST_BLOCK;
    for (y = y0; y + ST_BLOCK <= y1 && n < 64; y += step) {
        for (x = x0; x + ST_BLOCK <= x1 && n < 64; x += step) {
            int32_t d = match_roi_block(left, lw, right, rw, x, y);
            if (d >= 0) vals[n++] = d;
        }
    }
    if (count) *count = n;
    if (n == 0) return -1;

    for (i = 1; i < n; i++) {
        int32_t v = vals[i];
        for (j = i - 1; j >= 0 && vals[j] > v; j--) vals[j + 1] = vals[j];
        vals[j + 1] = v;
    }
    return vals[n / 2];
}

int st_block_curve(const uint8_t *left, int lw, const uint8_t *right, int rw,
                   int x, int y, uint32_t *cost, int n,
                   uint32_t *lo, uint32_t *hi)
{
    int d;
    uint32_t l = 0xFFFFFFFFu, h = 0;

    if (n > ST_DMAX + 1) n = ST_DMAX + 1;
    for (d = 0; d < n; d++) {
        cost[d] = sad_roi(left, lw, right, rw, x, y, d);
        if (cost[d] < l) l = cost[d];
        if (cost[d] > h) h = cost[d];
    }
    if (lo) *lo = l;
    if (hi) *hi = h;
    return n;
}
