/* Host test for firmware/yolo/stereo.c.
 *
 * Generates the same synthetic pair as tools/stereo/sim_stereo.py (textured
 * person on a textured wall, fractional disparity) and checks the C matcher,
 * so the board only ever runs code that already produced the right numbers.
 *
 *   gcc -O2 -I firmware/yolo tools/stereo/test_stereo.c firmware/yolo/stereo.c -o build/test_stereo
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "stereo.h"

static unsigned char L[ST_W * ST_H], R[ST_W * ST_H];

static unsigned rnd_state = 12345u;
static int rnd(int n)
{
    rnd_state = rnd_state * 1103515245u + 12345u;
    return (int)((rnd_state >> 16) % (unsigned)n);
}

/* draw a textured person rectangle at the given depth */
static void render(float z, float *out_dtrue, int *out_top, int *out_bot)
{
    int i, x, y;
    float d = ST_F_PX * (ST_BASELINE_MM / 1000.0f) / z;
    float v = 1.72f * ST_F_PX / z;
    int top = (int)(ST_H / 2 - v / 2), bot = (int)(ST_H / 2 + v / 2);
    int tx, ty;

    if (top < 0) top = 0;
    if (bot > ST_H - 1) bot = ST_H - 1;

    /* texture: 6x6 blocks of noise, shared by both eyes */
    static int blobs[64][64];
    for (ty = 0; ty < 64; ty++)
        for (tx = 0; tx < 64; tx++) blobs[ty][tx] = rnd(29);

    for (y = 0; y < ST_H; y++) {
        for (x = 0; x < ST_W; x++) {
            int wall = 190 + (int)(12.0 * sinf(x / 9.0f)) + rnd(7) - 3;
            int inside = (y >= top && y < bot && x >= 60 && x < 200);
            int body = 90 + (blobs[(y / 6) % 64][(x / 6) % 64] - 14) * 2;
            L[y * ST_W + x] = (unsigned char)(inside ? body : wall);
        }
    }
    /* right view: shift the left image left by d (bilinear) */
    for (y = 0; y < ST_H; y++) {
        for (x = 0; x < ST_W; x++) {
            float xs = x + d;
            int x0 = (int)floorf(xs), x1 = x0 + 1;
            float fx = xs - x0;
            if (x0 < 0) x0 = 0;
            if (x1 > ST_W - 1) x1 = ST_W - 1;
            if (x0 > ST_W - 1) x0 = ST_W - 1;
            R[y * ST_W + x] = (unsigned char)(L[y * ST_W + x0] * (1 - fx)
                                              + L[y * ST_W + x1] * fx + 0.5f);
        }
    }
    *out_dtrue = d;
    *out_top = top;
    *out_bot = bot;
}

int main(void)
{
    float z;

    printf("%6s %8s %8s %10s %10s %9s\n",
           "Z(m)", "d_true", "d_q4/4", "Z_est(mm)", "err(cm)", "h_est(cm)");

    for (z = 1.5f; z <= 4.01f; z += 0.5f) {
        float dtrue;
        int top, bot, n;
        int32_t dq4, zmm;
        uint32_t hmm;

        render(z, &dtrue, &top, &bot);
        dq4 = st_match_box(L, R, 64, top, 200, bot, &n);
        zmm = dq4 > 0 ? (int32_t)st_depth_mm(dq4) : 0;
        hmm = st_height_mm((uint32_t)zmm, bot - top);

        printf("%6.1f %8.2f %8.2f %10d %10.1f %9.1f   (blocks %d)\n",
               z, dtrue, dq4 / 4.0f, zmm, (zmm / 10.0f) - z * 100.0f,
               hmm / 10.0f, n);
    }
    return 0;
}
