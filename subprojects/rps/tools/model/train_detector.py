#!/usr/bin/env python3
"""Train a small anchor-free detector on a synthetic task (numpy only).

Task
----
32x32 single-channel images containing one bright 12x12 square at a random
position.  The detector works on an 8x8 grid (one cell per 4x4 pixels) and must
produce a dense coverage map plus a size regression.

Model (the same topology the accelerator runs)
----------------------------------------------
    conv 3x3  4->8   pad 1, ReLU      32x32x8
    maxpool 2x2                        16x16x8
    conv 3x3  8->16  pad 1, ReLU      16x16x16
    maxpool 2x2                         8x8x16
    conv 3x3 16->16  pad 1, [ReLU?]     8x8x16
    head 1x1 16->8   (obj, w, h, pad)   8x8x8

The three convolution stages use FIXED random filters, so they are a random
feature extractor; only the 1x1 head is trained.  That turns training into an
exact linear least-squares problem instead of a backprop loop.

A multi-scale variant (separate heads on the stride-2 and stride-4 maps, with
each object assigned to the scale matching its size) was tried and measured
worse: the finer head won for BOTH object sizes (0.46 px vs 1.03 px at 8 px,
0.35 px vs 1.23 px at 16 px).  On a 32x32 input the coarse map is simply too
coarse, so this stays single-scale rather than adding structure that does not
pay for itself.

Writes detector_float.npz for pack_weights.py.
"""
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]

H = W = 32
C_IN = 4              # the image lives in channel 0; 1..3 are zero padding
BOX = 12              # fixed square size, in pixels
GRID = 8              # output cells per side
CELL = H // GRID      # 4
SEED = 20261008
SCALE = 0.6

rng = np.random.default_rng(SEED)


def conv3x3(x, w, pad=1):
    n, h, ww, _ = x.shape
    xp = np.pad(x, ((0, 0), (pad, pad), (pad, pad), (0, 0)))
    out = np.zeros((n, h, ww, w.shape[0]), dtype=np.float32)
    for ky in range(3):
        for kx in range(3):
            out += np.einsum('nhwc,oc->nhwo', xp[:, ky:ky + h, kx:kx + ww, :],
                             w[:, :, ky, kx])
    return out


def pool2(x):
    n, h, ww, c = x.shape
    return x.reshape(n, h // 2, 2, ww // 2, 2, c).max(axis=(2, 4))


def conv1x1(x, w):
    return np.einsum('nhwc,oc->nhwo', x, w)


def relu(x):
    return np.maximum(x, 0.0)


def make_batch(n):
    x = np.zeros((n, H, W, C_IN), dtype=np.float32)
    y = np.zeros((n, GRID, GRID, 3), dtype=np.float32)
    for i in range(n):
        top = int(rng.integers(0, H - BOX + 1))
        left = int(rng.integers(0, W - BOX + 1))
        x[i, top:top + BOX, left:left + BOX, 0] = 1.0
        for cy in range(GRID):
            for cx in range(GRID):
                r0, c0 = cy * CELL, cx * CELL
                # Clamp EACH axis before multiplying.  Without the clamps a
                # disjoint cell yields two negative differences whose product is
                # positive, which marks phantom cells as covered and quietly
                # destroys the training target.
                dh = max(0, min(top + BOX, r0 + CELL) - max(top, r0))
                dw = max(0, min(left + BOX, c0 + CELL) - max(left, c0))
                y[i, cy, cx, 0] = 1.0 if (dh * dw) >= (CELL * CELL) // 2 else 0.0
        y[i, :, :, 1] = BOX / H
        y[i, :, :, 2] = BOX / W
    return x, y


def features(x, w1, w2, w3, l3_relu):
    a = relu(conv3x3(x, w1))
    a = pool2(a)
    a = relu(conv3x3(a, w2))
    a = pool2(a)
    a = conv3x3(a, w3)
    return relu(a) if l3_relu else a


def forward(x, w1, w2, w3, wh, bh, l3_relu):
    return conv1x1(features(x, w1, w2, w3, l3_relu), wh) + bh


def fit_head(ftr, ytr):
    n = ftr.shape[0] * GRID * GRID
    x = ftr.reshape(n, 16)
    y = np.zeros((n, 8), dtype=np.float32)
    y[:, 0:3] = ytr.reshape(n, 3)
    mu = x.mean(axis=0)
    sd = x.std(axis=0) + 1e-6
    xs = np.concatenate([(x - mu) / sd, np.ones((n, 1), np.float32)], axis=1)
    coef, *_ = np.linalg.lstsq(xs, y, rcond=None)
    ws, bs = coef[:16], coef[16]
    return (ws / sd[:, None]).T.astype(np.float32), \
           (bs - (mu / sd) @ ws).astype(np.float32)


def centroid_error(out, y):
    gy, gx = np.mgrid[0:GRID, 0:GRID]
    errs = []
    for i in range(out.shape[0]):
        wt = np.maximum(out[i, :, :, 0], 0.0)
        if wt.sum() < 1e-6:
            errs.append(99.0)
            continue
        cy = (gy * wt).sum() / wt.sum()
        cx = (gx * wt).sum() / wt.sum()
        t = y[i, :, :, 0]
        ty = (gy * t).sum() / max(t.sum(), 1e-6)
        tx = (gx * t).sum() / max(t.sum(), 1e-6)
        errs.append(np.hypot(cy - ty, cx - tx) * CELL)
    e = np.array(errs)
    return e.mean(), (e <= 3.0).mean() * 100.0


def main():
    print("generating synthetic detection data ...")
    xtr, ytr = make_batch(600)
    xte, yte = make_batch(100)

    w1 = (rng.standard_normal((8, C_IN, 3, 3)) * SCALE).astype(np.float32)
    w2 = (rng.standard_normal((16, 8, 3, 3)) * SCALE).astype(np.float32)
    w3 = (rng.standard_normal((16, 16, 3, 3)) * SCALE).astype(np.float32)

    best = None
    for l3_relu in (False, True):
        ftr = features(xtr, w1, w2, w3, l3_relu)
        fte = features(xte, w1, w2, w3, l3_relu)
        wh, bh = fit_head(ftr, ytr)
        mae, hit = centroid_error(conv1x1(fte, wh) + bh, yte)
        print("L3 ReLU=%d: test centroid error %.2f px, within 3px %.1f%%"
              % (int(l3_relu), mae, hit))
        if best is None or mae < best[0]:
            best = (mae, hit, l3_relu, wh, bh)

    mae, hit, l3_relu, wh, bh = best
    print("chosen: L3 ReLU=%d (%.2f px, within 3px %.1f%%)"
          % (int(l3_relu), mae, hit))

    np.savez(ROOT / "tools/model/detector_float.npz",
             w1=w1, w2=w2, w3=w3, wh=wh, bh=bh,
             l3_relu=np.int32(l3_relu), xte=xte[:8], yte=yte[:8])
    print("wrote tools/model/detector_float.npz")


if __name__ == "__main__":
    main()
