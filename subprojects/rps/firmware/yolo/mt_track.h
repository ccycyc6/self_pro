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
    int held;           /* frames kept alive without motion */
} trk_t;

/* A confirmed track survives this many motion-free frames: a rock/paper/
 * scissors pose is held still, and a motion-driven track would vanish. */
#define TRK_HOLD_FRAMES 60

/* Resample a track's box (with margin) into a 32x32 luma patch.  Because the
 * source region is the box itself, a hand at any distance fills the patch the
 * same way, which is what a classifier needs.  Returns 0 if the box is empty. */
/* Letterboxed: the box is fitted into a square canvas by its longer side and
 * centred, so a hand pointing up and the same hand pointing sideways keep their
 * shape instead of being stretched into a square.  edge is set when the source
 * square runs off the picture (the hand is entering from a side). */
int trk_patch(const trk_t *t, uint8_t *out32, int *edge);

/* Refit a track's box to the whole object instead of just its moving edge.
 * Motion only shows where the hand moved, so the box ends up smaller than the
 * hand; this looks at the still picture around the track, keeps the cells that
 * are clearly darker than their surroundings and takes the largest blob. */
void trk_fit(trk_t *t, const uint8_t *grid);

/* Build the 32x32 luma grid by averaging four samples per cell.  That is 4096
 * bus reads (about 20k cycles), against 76800 for the full image. */
void trk_grab(uint8_t *dst);

/* Feed the previous and current grids through the tracker.  Returns the number
 * of confirmed tracks; the list is in out[0..n-1]. */
int trk_step(const uint8_t *prev, const uint8_t *cur, trk_t *out, int max_out);

/* Motion threshold in luma counts (default 12). */
void trk_set_threshold(int t);

/* Forget every track.  The table is static, so a test (or a scene change) needs
 * a way to start clean. */
void trk_reset(void);

#endif
