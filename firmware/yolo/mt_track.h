#ifndef MT_TRACK_H
#define MT_TRACK_H

#include <stdint.h>

/* Motion tracking on a 32x32 grid of the camera picture.
 *
 * Detection is a frame difference; the tracker's job is to give each moving
 * region a stable identity across frames, which is what the raw per-frame
 * components do not have.  No model, no calibration: motion is the strongest
 * signal the camera has.
 */
#define TRK_GRID   32
#define TRK_MAX    8

typedef struct {
    int used;
    int confirmed;      /* seen enough frames to be reported */
    int cx, cy;         /* smoothed centre, in grid cells */
    int w, h;           /* smoothed size, in grid cells */
    int hits, misses;
} trk_t;

/* Build the 32x32 luma grid by averaging four samples per cell.  That is 4096
 * bus reads (about 20k cycles), against 76800 for the full image. */
void trk_grab(uint8_t *dst);

/* Feed the previous and current grids through the tracker.  Returns the number
 * of confirmed tracks; the list is in out[0..n-1]. */
int trk_step(const uint8_t *prev, const uint8_t *cur, trk_t *out, int max_out);

/* Motion threshold in luma counts (default 12). */
void trk_set_threshold(int t);

#endif
