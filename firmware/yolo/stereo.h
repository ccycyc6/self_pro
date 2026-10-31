#ifndef STEREO_H
#define STEREO_H

#include <stdint.h>

/* Stereo geometry.  f is in pixels for the 320x240 luma image; B is the
 * baseline in millimetres (measured on the double-DVP module bracket). */
#define ST_W        320
#define ST_H        240
#define ST_F_PX     275
#define ST_BASELINE_MM 70

#define ST_BLOCK    8
#define ST_DMAX     24
#define ST_MIN_COST 1

/* Depth in millimetres for a (sub-pixel) disparity.  Returns 0 when the
 * disparity is not usable. */
uint32_t st_depth_mm(const int32_t d_q4);

/* Height in millimetres from depth and the subject's pixel height. */
uint32_t st_height_mm(uint32_t depth_mm, int32_t v_px);

/* Matches one block: left block at (x,y), searching right image over 0..dmax.
 * Returns disparity in quarter pixels (Q4), or -1 when the block has too little
 * texture to be trusted.  out_cost may be NULL. */
int32_t st_match_block(const uint8_t *left, const uint8_t *right,
                       int x, int y, int32_t *out_cost);

/* Median disparity (Q4) over a grid of blocks inside a box.  count receives the
 * number of blocks that produced a usable value. */
int32_t st_match_box(const uint8_t *left, const uint8_t *right,
                     int x0, int y0, int x1, int y1, int *count);

/* Same, but on a region of interest copied out of the 320x240 frame: the left
 * window starts at the ROI origin, and the right window starts ST_DMAX pixels
 * earlier so every (x - d) is inside it.  This is what the firmware uses -- it
 * cannot afford to read the whole frame through the MMIO window. */
int32_t st_match_roi(const uint8_t *left, int lw,
                     const uint8_t *right, int rw,
                     int x0, int y0, int x1, int y1, int *count);

/* Same with a block stride, so a few blocks can be spread over a wide region
 * instead of clustering on one patch of wall. */
int32_t st_match_roi_step(const uint8_t *left, int lw,
                          const uint8_t *right, int rw,
                          int x0, int y0, int x1, int y1, int step,
                          int *count);

/* Diagnostics: the SAD curve of one block.  Returns the number of entries
 * written (min(dmax, n) + 1) and the min/max through the pointers. */
int st_block_curve(const uint8_t *left, int lw, const uint8_t *right, int rw,
                   int x, int y, uint32_t *cost, int n,
                   uint32_t *lo, uint32_t *hi);

#endif
