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

int trk_patch(const trk_t *t, uint8_t *out32, int *edge)
{
    int x0, y0, bw, bh, i, j, side, ox, oy;
    uint32_t bg = 0;

    if (t->w <= 0 || t->h <= 0) return 0;

    /* Exactly what the green box covers, plus a small margin, letterboxed to a
     * square so the aspect ratio is preserved.  No heuristics about where the
     * arm comes from: the box is what the viewer sees and what was recorded, so
     * training and inference see the same thing. */
    x0 = (t->cx - t->w / 2) * 10;
    y0 = ((t->cy - t->h / 2) * 15) / 2;
    bw = t->w * 10;
    bh = (t->h * 15) / 2;

    x0 -= bw / 10;                 /* 10% margin around the box */
    y0 -= bh / 10;

    side = (bw > bh) ? bw : bh;
    if (side < 16) side = 16;
    ox = x0 + bw / 2 - side / 2;
    oy = y0 + bh / 2 - side / 2;

    if (edge)
        *edge = (ox < 0) || (oy < 0) || (ox + side > TRK_W) || (oy + side > 240);

    {
        int px = ox + side + 2, py = oy + side / 2;
        int ok = 1;

        if (px > TRK_W - 1) px = ox - 2;
        if (px < 0 || px > TRK_W - 1) ok = 0;
        if (py < 0) py = 0;
        if (py > 239) py = 239;
        if (ok) bg = ARES_MMIO32(TRK_L_BASE + (uint32_t)(py * TRK_W + px) * 4u) & 0xFFu;
    }

    for (j = 0; j < 32; j++) {
        int sy = oy + (j * side) / 32;
        for (i = 0; i < 32; i++) {
            int sx = ox + (i * side) / 32;
            uint8_t v;

            if (sx < 0 || sy < 0 || sx > TRK_W - 1 || sy > 239)
                v = (uint8_t)bg;
            else
                v = (uint8_t)(ARES_MMIO32(TRK_L_BASE +
                        (uint32_t)(sy * TRK_W + sx) * 4u) & 0xFFu);
            out32[j * 32 + i] = v;
        }
    }
    return 1;
}

void trk_fit(trk_t *t, const uint8_t *grid)
{
    static uint8_t seen[TRK_GRID * TRK_GRID];
    int wx0, wy0, wx1, wy1, x, y, i;
    uint32_t sum = 0;
    int n = 0, mean, thr;
    int best_area = 0, bx0 = 0, by0 = 0, bx1 = 0, by1 = 0;

    wx0 = t->cx - 9; if (wx0 < 0) wx0 = 0;
    wy0 = t->cy - 9; if (wy0 < 0) wy0 = 0;
    wx1 = t->cx + 9; if (wx1 > TRK_GRID - 1) wx1 = TRK_GRID - 1;
    wy1 = t->cy + 9; if (wy1 > TRK_GRID - 1) wy1 = TRK_GRID - 1;

    /* The threshold comes from the WHOLE grid, not from the search window.
     * Taking it from the window was a positive feedback loop: a slightly
     * smaller box meant a window filled with hand, a lower mean, a lower
     * threshold, and a smaller box again, until the box collapsed onto the
     * darkest patch.  The wall dominates the frame, so the grid mean is a
     * stable background estimate. */
    for (y = 0; y < TRK_GRID; y++)
        for (x = 0; x < TRK_GRID; x++) {
            sum += grid[y * TRK_GRID + x];
            n++;
        }
    for (y = wy0; y <= wy1; y++)
        for (x = wx0; x <= wx1; x++)
            seen[y * TRK_GRID + x] = 0;
    if (n == 0) return;
    mean = (int)(sum / (uint32_t)n);

    /* a hand in front of a bright wall is clearly darker than the wall */
    thr = mean - 18;
    if (thr < 30) thr = 30;

    for (y = wy0; y <= wy1; y++)
        for (x = wx0; x <= wx1; x++) {
            int idx = y * TRK_GRID + x;
            int sp = 0, area = 0;
            int x0 = TRK_GRID, y0 = TRK_GRID, x1 = 0, y1 = 0;

            if (seen[idx] || (int)grid[idx] > thr) continue;

            stack[sp++] = (int16_t)idx;
            seen[idx] = 1;
            while (sp > 0) {
                int c2 = stack[--sp];
                int cx = c2 % TRK_GRID, cy = c2 / TRK_GRID;
                int dy, dx;

                area++;
                if (cx < x0) x0 = cx;
                if (cx > x1) x1 = cx;
                if (cy < y0) y0 = cy;
                if (cy > y1) y1 = cy;

                for (dy = -1; dy <= 1; dy++)
                    for (dx = -1; dx <= 1; dx++) {
                        int nx = cx + dx, ny = cy + dy, ni;
                        if (nx < wx0 || ny < wy0 || nx > wx1 || ny > wy1) continue;
                        ni = ny * TRK_GRID + nx;
                        if (!seen[ni] && (int)grid[ni] <= thr) {
                            seen[ni] = 1;
                            stack[sp++] = (int16_t)ni;
                        }
                    }
            }

            if (area > best_area) {
                best_area = area;
                bx0 = x0; by0 = y0; bx1 = x1; by1 = y1;
            }
        }

    if (best_area < 3) return;                 /* nothing solid found */

    /* Smooth the refit.  Taking the blob's bounding box straight every frame
     * made the box breathe by 30% from frame to frame, and because the
     * classifier's input is normalised by the box size, the hand kept changing
     * apparent size and the classes jumped with it. */
    {
        int ncx = (bx0 + bx1) / 2, ncy = (by0 + by1) / 2;
        int nw = bx1 - bx0 + 1, nh = by1 - by0 + 1;

        /* A refit that suddenly reports half the size is a partial detection
         * (the hand half out of the window, or a pale sleeve), not a smaller
         * hand; keep the previous box instead of following it down. */
        if (nw * 2 < t->w || nh * 2 < t->h) return;

        t->cx = (t->cx * 2 + ncx) / 3;
        t->cy = (t->cy * 2 + ncy) / 3;
        t->w  = (t->w * 2 + nw) / 3;
        t->h  = (t->h * 2 + nh) / 3;
    }
    (void)i;
}

void trk_reset(void)
{
    int i;

    for (i = 0; i < TRK_MAX; i++) tracks[i].used = 0;
}

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

/* Fingers and a palm arrive as separate components; left alone they become two
 * tracks that fight over the same hand.  Merge blobs whose centres are closer
 * than MERGE_DIST cells, keeping the union bounding box. */
#define MERGE_DIST 5

static int merge_blobs(int nb)
{
    int i, j, changed = 1;

    while (changed) {
        changed = 0;
        for (i = 0; i < nb; i++)
            for (j = i + 1; j < nb; j++) {
                int dx = blobs[i].cx - blobs[j].cx;
                int dy = blobs[i].cy - blobs[j].cy;

                if (dx * dx + dy * dy > MERGE_DIST * MERGE_DIST) continue;

                blobs[i].cx = (blobs[i].cx + blobs[j].cx) / 2;
                blobs[i].cy = (blobs[i].cy + blobs[j].cy) / 2;
                if (blobs[j].x0 < blobs[i].x0) blobs[i].x0 = blobs[j].x0;
                if (blobs[j].y0 < blobs[i].y0) blobs[i].y0 = blobs[j].y0;
                if (blobs[j].x1 > blobs[i].x1) blobs[i].x1 = blobs[j].x1;
                if (blobs[j].y1 > blobs[i].y1) blobs[i].y1 = blobs[j].y1;

                blobs[j] = blobs[nb - 1];
                nb--;
                changed = 1;
                break;
            }
        if (changed) continue;
    }
    return nb;
}

/* Acquire without motion: a hand held still produces no frame difference at
 * all, and the tracker would never see it.  Look for the largest region that is
 * clearly darker than the background across the whole grid and start a track
 * from it, already confirmed.  Motion still wins when something moves, because
 * the difference image is sharper. */
static int acquire_from_brightness(const uint8_t *grid)
{
    static uint8_t seen[TRK_GRID * TRK_GRID];
    uint32_t sum = 0;
    int i, x, y, mean, thr;
    int best_area = 0, bx0 = 0, by0 = 0, bx1 = 0, by1 = 0;

    for (i = 0; i < TRK_GRID * TRK_GRID; i++) sum += grid[i];
    mean = (int)(sum / (TRK_GRID * TRK_GRID));
    thr = mean - 18;
    if (thr < 30) thr = 30;

    for (i = 0; i < TRK_GRID * TRK_GRID; i++) seen[i] = 0;

    for (i = 0; i < TRK_GRID * TRK_GRID; i++) {
        int sp = 0, area = 0;
        int x0 = TRK_GRID, y0 = TRK_GRID, x1 = 0, y1 = 0;

        if (seen[i] || (int)grid[i] > thr) continue;

        stack[sp++] = (int16_t)i;
        seen[i] = 1;
        while (sp > 0) {
            int c2 = stack[--sp];
            int cx = c2 % TRK_GRID, cy = c2 / TRK_GRID;
            int dy, dx;

            area++;
            if (cx < x0) x0 = cx;
            if (cx > x1) x1 = cx;
            if (cy < y0) y0 = cy;
            if (cy > y1) y1 = cy;

            for (dy = -1; dy <= 1; dy++)
                for (dx = -1; dx <= 1; dx++) {
                    int nx = cx + dx, ny = cy + dy, ni;
                    if (nx < 0 || ny < 0 || nx >= TRK_GRID || ny >= TRK_GRID) continue;
                    ni = ny * TRK_GRID + nx;
                    if (!seen[ni] && (int)grid[ni] <= thr) {
                        seen[ni] = 1;
                        stack[sp++] = (int16_t)ni;
                    }
                }
        }

        if (area > best_area) {
            best_area = area;
            bx0 = x0; by0 = y0; bx1 = x1; by1 = y1;
        }
    }

    (void)x; (void)y;
    if (best_area < 8) return -1;

    for (i = 0; i < TRK_MAX; i++)
        if (!tracks[i].used) {
            tracks[i].used = 1;
            tracks[i].confirmed = 1;
            tracks[i].cx = (bx0 + bx1) / 2;
            tracks[i].cy = (by0 + by1) / 2;
            tracks[i].w = bx1 - bx0 + 1;
            tracks[i].h = by1 - by0 + 1;
            tracks[i].hits = 3;
            tracks[i].misses = 0;
            tracks[i].held = 0;
            return i;
        }
    return -1;
}

int trk_step(const uint8_t *prev, const uint8_t *cur, trk_t *out, int max_out)
{
    int nb, i, j, n = 0;

    build_mask(prev, cur);
    nb = find_blobs();
    nb = merge_blobs(nb);

    /* age the existing tracks first: anything not re-matched this frame loses a
     * point, and a track that misses too often is dropped */
    for (i = 0; i < TRK_MAX; i++) {
        if (tracks[i].used) tracks[i].misses++;
    }

    for (i = 0; i < nb; i++) {
        int best = -1, bestd = 12 * 12;    /* association radius: 12 cells, a
                                            * hand can cross the frame quickly */

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

    /* nothing moving and nothing tracked: look at the picture instead */
    {
        int any = 0;

        for (i = 0; i < TRK_MAX; i++) if (tracks[i].used) any = 1;
        if (!any) acquire_from_brightness(cur);
    }

    for (i = 0; i < TRK_MAX; i++) {
        if (!tracks[i].used) continue;

        if (tracks[i].misses == 0) {
            tracks[i].held = 0;
        } else if (tracks[i].confirmed) {
            /* still showing the same thing: keep the box, the pose is held */
            tracks[i].held++;
            if (tracks[i].held > TRK_HOLD_FRAMES) { tracks[i].used = 0; continue; }
        } else if (tracks[i].misses > 5) {
            tracks[i].used = 0;
            continue;
        }

        if (tracks[i].confirmed && n < max_out) out[n++] = tracks[i];
    }
    return n;
}
