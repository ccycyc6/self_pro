/* Host test for the motion tracker: feeds synthetic 32x32 grids and checks the
 * properties the demo needs -- one identity per moving object, merging of
 * fragments, and the track being dropped when the object leaves.
 *
 *   gcc -O2 -I firmware/common -I firmware/yolo \
 *       tools/ml/test_track.c firmware/yolo/mt_track.c -o build/test_track
 */
#include <stdio.h>
#include <string.h>
#include "mt_track.h"

static uint8_t a[TRK_GRID * TRK_GRID], b[TRK_GRID * TRK_GRID];

static void fill_square(uint8_t *g, int cx, int cy, int r)
{
    int x, y;
    memset(g, 100, TRK_GRID * TRK_GRID);
    for (y = cy - r; y <= cy + r; y++)
        for (x = cx - r; x <= cx + r; x++)
            if (x >= 0 && y >= 0 && x < TRK_GRID && y < TRK_GRID) g[y * TRK_GRID + x] = 160;
}

static int fails;
static void check(int cond, const char *what)
{
    if (!cond) { printf("FAIL: %s\n", what); fails++; }
    else printf("ok: %s\n", what);
}

int main(void)
{
    trk_t list[4];
    int n, i, f;

    /* A track is only reported after TRK_CONFIRM hits, so every scenario below
     * warms up for a few frames before it is judged. */

    /* 1. a square moving right, 2 cells per frame, keeps one identity */
    fill_square(a, 6, 10, 2);
    {
        int stable = 1, movers = 0;
        for (f = 0; f < 12; f++) {
            fill_square(b, 6 + 2 * f, 10, 2);
            n = trk_step(a, b, list, 4);
            if (f >= 3) {
                if (n != 1) stable = 0;
                else movers = list[0].cx;
            }
            memcpy(a, b, sizeof(a));
        }
        check(stable, "one track while a square moves");
        check(movers >= 20, "the track follows the square");
    }

    /* 2. two squares far apart -> two tracks */
    {
        int x, y;
        memset(a, 100, sizeof(a));
        for (y = 4; y <= 8; y++) for (x = 4; x <= 8; x++) a[y * TRK_GRID + x] = 160;
        for (y = 20; y <= 24; y++) for (x = 22; x <= 26; x++) a[y * TRK_GRID + x] = 160;
        memset(b, 100, sizeof(b));
        for (y = 4; y <= 8; y++) for (x = 8; x <= 12; x++) b[y * TRK_GRID + x] = 160;
        for (y = 20; y <= 24; y++) for (x = 26; x <= 30; x++) b[y * TRK_GRID + x] = 160;
        for (f = 0; f < 6; f++) n = trk_step(a, b, list, 4);
        check(n == 2, "two separate objects give two tracks");
    }

    /* 3. two fragments close together are one object */
    {
        int x, y;
        memset(a, 100, sizeof(a));
        for (y = 10; y <= 14; y++) for (x = 10; x <= 14; x++) a[y * TRK_GRID + x] = 160;
        memset(b, 100, sizeof(b));
        for (y = 10; y <= 14; y++) for (x = 10; x <= 13; x++) b[y * TRK_GRID + x] = 160;
        for (y = 10; y <= 14; y++) for (x = 16; x <= 18; x++) b[y * TRK_GRID + x] = 160;
        for (f = 0; f < 6; f++) n = trk_step(a, b, list, 4);
        check(n == 1, "fragments of one object merge into one track");
    }

    /* 4. the object leaves: the track disappears after the miss limit */
    {
        fill_square(a, 10, 12, 3);
        for (f = 0; f < 4; f++) {            /* make it move, so a track exists */
            fill_square(b, 10 + f, 12, 3);
            trk_step(a, b, list, 4);
            memcpy(a, b, sizeof(a));
        }
        /* the object leaves: one frame of change, then a still scene */
        memset(b, 100, sizeof(b));
        trk_step(a, b, list, 4);
        memcpy(a, b, sizeof(a));
        for (f = 0; f < 8; f++) n = trk_step(a, b, list, 4);
        check(n == 0, "the track is dropped when the object leaves");
    }

    printf("track tests: %s (%d failure%s)\n",
           fails ? "FAILED" : "PASSED", fails, fails == 1 ? "" : "s");
    return fails ? 1 : 0;
}
