#!/usr/bin/env python3
"""Offline model of the stereo -> depth -> height chain.

The board is not available right now, so the geometry and the matching
algorithm are developed and validated here first.  Everything below mirrors
what the firmware will do, with the same constants:

    Z = f * B / d          f in pixels (320-wide crop), B in metres
    height = Z * (v_px / f)  v_px = silhouette height in pixels

Run:  python3 tools/stereo/sim_stereo.py
"""
import numpy as np

# ---- camera geometry (filled in from the kit's schematic / calibration) -----
IMG_W, IMG_H = 320, 240          # stereo working resolution
F_PX = 275.0                     # ~60 deg HFOV at 320 wide: f = 320/2/tan(30)
BASELINE = 0.070                 # metres between the two lens centres
PERSON_H = 1.72                  # metres, ground truth for the test


def shift_h(img, d):
    """Shift an image left by d (fractional) pixels, bilinear."""
    h, w = img.shape
    xs = np.arange(w) + d
    x0 = np.floor(xs).astype(int)
    x1 = x0 + 1
    fx = xs - x0
    x0 = np.clip(x0, 0, w - 1)
    x1 = np.clip(x1, 0, w - 1)
    out = img[:, x0] * (1 - fx)[None, :] + img[:, x1] * fx[None, :]
    return out


def render(z_obj, z_bg=6.0, subject_h=1.72, noise=2.0, seed=1):
    """Synthetic stereo pair: a person-sized rectangle at z_obj on a flat wall.

    Returns (left, right, top_row, bot_row, true_disparity).
    """
    rng = np.random.default_rng(seed)
    d_obj = F_PX * BASELINE / z_obj
    d_bg = F_PX * BASELINE / z_bg

    # The person's pixel height follows from the pinhole model.
    v_px = PERSON_H * F_PX / z_obj
    top = int(round(IMG_H / 2 - v_px / 2))
    bot = int(round(IMG_H / 2 + v_px / 2))
    top = max(0, min(IMG_H - 1, top))
    bot = max(top + 4, min(IMG_H, bot))

    # A flat rectangle cannot be matched -- a uniform patch gives the same SAD
    # at every disparity (the aperture problem).  Real scenes have texture, so
    # both the wall and the person get some.
    wall = 200.0 + 12.0 * np.sin(np.arange(IMG_W) / 9.0)[None, :] \
                   + rng.normal(0, 3.0, (IMG_H, IMG_W))
    blobs = rng.normal(0, 1.0, (IMG_H // 6 + 2, IMG_W // 6 + 2))
    blobs = np.kron(blobs, np.ones((6, 6)))[:IMG_H, :IMG_W] * 14.0
    body = 90.0 + blobs

    # The right view is the left view shifted by d_obj pixels *with bilinear
    # interpolation* -- an integer shift would erase the sub-pixel information
    # and make every sub-pixel estimator look useless.
    left = wall.copy()
    left[top:bot, 60:200] = body[top:bot, 60:200]
    left += rng.normal(0, noise, left.shape)
    right = shift_h(left, d_obj)
    return (np.clip(left, 0, 255), np.clip(right, 0, 255), top, bot, d_obj)


def sad_match(left, right, rows, cols, dmax=24, block=8):
    """Block matching with parabolic sub-pixel refinement.

    Integer disparity is far too coarse: at 2 m one pixel is 34 cm.  Fitting a
    parabola through the SAD minimum and its two neighbours recovers roughly a
    quarter pixel, which is the difference between a usable and a useless
    height estimate.
    """
    out = np.zeros((len(rows), len(cols)), np.float32)
    for i, r in enumerate(rows):
        for j, c in enumerate(cols):
            lb = left[r:r + block, c:c + block]
            curve = []
            for d in range(dmax + 1):
                if c - d < 0:
                    break
                rb = right[r:r + block, c - d:c - d + block]
                if rb.shape != lb.shape:
                    break
                curve.append(np.abs(lb - rb).sum())
            if not curve:
                continue
            k = int(np.argmin(curve))
            if 0 < k < len(curve) - 1:
                s0, s1, s2 = curve[k - 1], curve[k], curve[k + 1]
                den = 2.0 * (s0 - 2.0 * s1 + s2)
                off = 0.0 if abs(den) < 1e-6 else (s0 - s2) / den
                off = max(-0.5, min(0.5, off))
            else:
                off = 0.0
            out[i, j] = k + off
    return out


def depth_from_disparity(d):
    return F_PX * BASELINE / max(d, 1e-6)


def main():
    print("f = %.1f px,  B = %.0f mm" % (F_PX, BASELINE * 1000))
    print("%6s %8s %8s %10s %10s %9s" %
          ("Z(m)", "d_px", "d_est", "Z_est(m)", "err(cm)", "h_est(cm)"))

    for z in (1.0, 1.5, 2.0, 2.5, 3.0, 4.0):
        left, right, top, bot, d_true = render(z)
        # ROI: the person's box, in 8x8 blocks (that is what the firmware sees)
        r0 = (top // 8) * 8
        r1 = min(IMG_H - 8, (bot // 8) * 8)
        rows = list(range(r0, r1 + 1, 8))
        cols = list(range(64, 200, 8))
        dm = sad_match(left, right, rows, cols)
        d_med = float(np.median(dm))
        z_est = depth_from_disparity(d_med)

        v_px = bot - top
        h_est = z_est * v_px / F_PX
        print("%6.1f %8.2f %8.2f %10.2f %10.1f %9.1f" %
              (z, d_true, d_med, z_est, (z_est - z) * 100, h_est * 100))

    print()
    print("A disparity of one pixel at 2 m is %.1f cm of depth error."
          % ((F_PX * BASELINE / 7.0 - F_PX * BASELINE / 8.0) * 100))


if __name__ == "__main__":
    main()
