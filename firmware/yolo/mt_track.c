/* Motion detection and tracking on a 32x32 grid.
 *
 * The camera is the only sensor: a frame difference finds movement, connected
 * components turn it into regions, and a nearest-centre association gives each
 * region an identity that survives across frames.  Everything here is integer
 * arithmetic on 1024 bytes.
 */
#include "mt_track.h"
#include "ares_soc.h"

#define TRK_L_BASE 0xD0100000u     /* stereo window, camera 1 */
#define TRK_W      320

static uint8_t mask[TRK_GRID * TRK_GRID];
static trk_t   tracks[TRK_MAX];
static int     thr = 12;

static int16_t stack[TRK_GRID * TRK_GRID];

typedef struct {
    int cx, cy;
    int x0, y0, x1, y1;
} blob_t;

static blob_t blobs[TRK_MAX];

void trk_set_threshold(int t)
{
    if (t < 1) t = 1;
    if (t > 200) t = 200;
    thr = t;
}

void trk_grab(uint8_t *dst)
{
    int cx, cy, k;

    for (cy = 0; cy < TRK_GRID; cy++) {
        int y0 = (cy * 15) / 2;                 /* 240 / 32 = 7.5 rows per cell */
        for (cx = 0; cx < TRK_GRID; cx++) {
            int x0 = cx * 10;                   /* 320 / 32 = 10 columns */
            uint32_t s = 0;

            for (k = 0; k < 4; k++) {
                int x = x0 + ((k & 1) ? 7 : 2);
                int y = y0 + ((k & 2) ? 5 : 2);
                if (x > TRK_W - 1) x = TRK_W - 1;
                if (y > 239) y = 239;
                s += ARES_MMIO32(TRK_L_BASE + (uint32_t)(y * TRK_W + x) * 4u) & 0xFFu;
            }
            dst[cy * TRK_GRID + cx] = (uint8_t)(s / 4u);
        }
    }
}

static int build_mask(const uint8_t *prev, const uint8_t *cur)
{
    int i, n = 0;

    for (i = 0; i < TRK_GRID * TRK_GRID; i++) {
        int d = (int)cur[i] - (int)prev[i];
        if (d < 0) d = -d;
        mask[i] = (d > thr) ? 1 : 0;
        n += mask[i];
    }
    return n;
}

/* 8-connected components, small ones dropped as noise */
static int find_blobs(void)
{
    static uint8_t seen[TRK_GRID * TRK_GRID];
    int i, nb = 0;

    for (i = 0; i < TRK_GRID * TRK_GRID; i++) seen[i] = 0;

    for (i = 0; i < TRK_GRID * TRK_GRID && nb < TRK_MAX; i++) {
        int sp = 0, area = 0, sx = 0, sy = 0;
        int x0 = TRK_GRID, y0 = TRK_GRID, x1 = 0, y1 = 0;

        if (seen[i] || !mask[i]) continue;

        stack[sp++] = (int16_t)i;
        seen[i] = 1;
        while (sp > 0) {
            int c = stack[--sp];
            int cx = c % TRK_GRID, cy = c / TRK_GRID;
            int dy, dx;

            area++;
            sx += cx;
            sy += cy;
            if (cx < x0) x0 = cx;
            if (cx > x1) x1 = cx;
            if (cy < y0) y0 = cy;
            if (cy > y1) y1 = cy;

            for (dy = -1; dy <= 1; dy++)
                for (dx = -1; dx <= 1; dx++) {
                    int nx = cx + dx, ny = cy + dy, ni;
                    if (nx < 0 || ny < 0 || nx >= TRK_GRID || ny >= TRK_GRID) continue;
                    ni = ny * TRK_GRID + nx;
                    if (!seen[ni] && mask[ni]) {
                        seen[ni] = 1;
                        stack[sp++] = (int16_t)ni;
                    }
                }
        }

        if (area < 3) continue;      /* noise */

        blobs[nb].cx = sx / area;
        blobs[nb].cy = sy / area;
        blobs[nb].x0 = x0;
        blobs[nb].y0 = y0;
        blobs[nb].x1 = x1;
        blobs[nb].y1 = y1;
        nb++;
    }
    return nb;
}

int trk_step(const uint8_t *prev, const uint8_t *cur, trk_t *out, int max_out)
{
    int nb, i, j, n = 0;

    build_mask(prev, cur);
    nb = find_blobs();

    /* age the existing tracks first: anything not re-matched this frame loses a
     * point, and a track that misses too often is dropped */
    for (i = 0; i < TRK_MAX; i++) {
        if (tracks[i].used) tracks[i].misses++;
    }

    for (i = 0; i < nb; i++) {
        int best = -1, bestd = 8 * 8;      /* association radius: 8 cells */

        for (j = 0; j < TRK_MAX; j++) {
            int dx, dy, d2;
            if (!tracks[j].used) continue;
            dx = tracks[j].cx - blobs[i].cx;
            dy = tracks[j].cy - blobs[i].cy;
            d2 = dx * dx + dy * dy;
            if (d2 < bestd) { bestd = d2; best = j; }
        }

        if (best < 0) {
            for (j = 0; j < TRK_MAX; j++) if (!tracks[j].used) { best = j; break; }
            if (best < 0) continue;                        /* table full */
            tracks[best].used = 1;
            tracks[best].confirmed = 0;
            tracks[best].cx = blobs[i].cx;
            tracks[best].cy = blobs[i].cy;
            tracks[best].w = blobs[i].x1 - blobs[i].x0 + 1;
            tracks[best].h = blobs[i].y1 - blobs[i].y0 + 1;
            tracks[best].hits = 1;
        } else {
            /* exponential smoothing keeps the box from twitching */
            tracks[best].cx = (3 * tracks[best].cx + blobs[i].cx) / 4;
            tracks[best].cy = (3 * tracks[best].cy + blobs[i].cy) / 4;
            tracks[best].w = (3 * tracks[best].w + (blobs[i].x1 - blobs[i].x0 + 1)) / 4;
            tracks[best].h = (3 * tracks[best].h + (blobs[i].y1 - blobs[i].y0 + 1)) / 4;
            tracks[best].hits++;
        }
        tracks[best].misses = 0;
        if (tracks[best].hits >= 3) tracks[best].confirmed = 1;
    }

    for (i = 0; i < TRK_MAX; i++) {
        if (!tracks[i].used) continue;
        if (tracks[i].misses > 5) { tracks[i].used = 0; continue; }
        if (tracks[i].confirmed && n < max_out) out[n++] = tracks[i];
    }
    return n;
}
