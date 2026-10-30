#!/usr/bin/env python3
"""Train the detector properly: full backprop in numpy, no framework needed.

The model has to keep the topology the accelerator implements:

    conv3x3 4->8  pad1 ReLU   32x32x4
    maxpool 2x2               16x16x8
    conv3x3 8->16 pad1 ReLU   16x16x16
    maxpool 2x2                8x8x16
    conv3x3 16->16 pad1 [+ReLU] 8x8x16
    conv1x1 16->8             (obj, w, h, pad) per cell

Unlike the original script (fixed random features + least-squares head) every
weight here is trained by gradient descent, which is what the colour task needs:
the earlier experiments showed a linear head over random filters bottoms out at
~2.8 px / 60 %.

Writes tools/model/detector_bp.npz in the same layout as detector_float.npz so
pack_weights.py can consume it unchanged.
"""
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
H = W = 32
C_IN = 4
BOX = 12
GRID = 8
CELL = H // GRID
rng = np.random.default_rng(20261030)

TARGET_RGB = (1.00, 0.12, 0.12)
DISTRACTORS = [(0.95, 0.95, 0.95), (0.60, 0.60, 0.60), (0.25, 0.25, 0.25),
               (0.10, 0.20, 1.00), (0.15, 0.90, 0.20)]


def put(x, i, top, left, rgb, size):
    x[i, top:top + size, left:left + size, 0] = rgb[0]
    x[i, top:top + size, left:left + size, 1] = rgb[1]
    x[i, top:top + size, left:left + size, 2] = rgb[2]


def make_batch(n):
    # Values in 0..255: the firmware feeds raw 8-bit RGB bytes, and the packer
    # derives the input scale from these images, so the two must agree.
    x = np.zeros((n, H, W, C_IN), np.float32)
    y = np.zeros((n, GRID, GRID, 3), np.float32)
    for i in range(n):
        top = int(rng.integers(0, H - BOX + 1))
        left = int(rng.integers(0, W - BOX + 1))
        put(x, i, top, left, TARGET_RGB, BOX)
        for _ in range(3):
            dt = int(rng.integers(0, H - BOX + 1))
            dl = int(rng.integers(0, W - BOX + 1))
            if abs(dt - top) < BOX + 2 and abs(dl - left) < BOX + 2:
                continue
            put(x, i, dt, dl, DISTRACTORS[int(rng.integers(0, len(DISTRACTORS)))], BOX)
        for cy in range(GRID):
            for cx in range(GRID):
                r0, c0 = cy * CELL, cx * CELL
                dh = max(0, min(top + BOX, r0 + CELL) - max(top, r0))
                dw = max(0, min(left + BOX, c0 + CELL) - max(left, c0))
                y[i, cy, cx, 0] = 1.0 if (dh * dw) >= (CELL * CELL) // 2 else 0.0
        y[i, :, :, 1] = BOX / H
        y[i, :, :, 2] = BOX / W
    return x, y


# ---------------------------------------------------------------- primitives
def conv_fwd(x, w, b):
    n, h, ww, c = x.shape
    o = w.shape[0]
    xp = np.pad(x, ((0, 0), (1, 1), (1, 1), (0, 0)))
    out = np.zeros((n, h, ww, o), np.float32)
    for ky in range(3):
        for kx in range(3):
            out += xp[:, ky:ky + h, kx:kx + ww, :] @ w[:, :, ky, kx].T
    out += b
    return out


def conv_bwd(dout, x, w):
    n, h, ww, c = x.shape
    o = w.shape[0]
    xp = np.pad(x, ((0, 0), (1, 1), (1, 1), (0, 0)))
    dw = np.zeros_like(w)
    dxp = np.zeros_like(xp)
    for ky in range(3):
        for kx in range(3):
            dw[:, :, ky, kx] = np.tensordot(dout, xp[:, ky:ky + h, kx:kx + ww, :],
                                            axes=([0, 1, 2], [0, 1, 2]))
            dxp[:, ky:ky + h, kx:kx + ww, :] += dout @ w[:, :, ky, kx]
    db = dout.sum(axis=(0, 1, 2))
    return dxp[:, 1:1 + h, 1:1 + ww, :], dw, db


def pool_fwd(x):
    """2x2 max pool; the window index (a*2+b) is kept for the backward pass.

    numpy's argmax takes one axis, so the window is flattened into the last
    dimension rather than reduced over a tuple of axes.
    """
    n, h, ww, c = x.shape
    xr = x.reshape(n, h // 2, 2, ww // 2, 2, c)
    xr4 = xr.transpose(0, 1, 3, 5, 2, 4).reshape(n, h // 2, ww // 2, c, 4)
    idx = xr4.argmax(axis=4)
    return xr4.max(axis=4), idx


def pool_bwd(dout, idx, shape):
    n, h, ww, c = shape
    dx4 = np.zeros((n, h // 2, ww // 2, c, 4), np.float32)
    for k in range(4):
        dx4[:, :, :, :, k] = dout * (idx == k)
    dx = dx4.reshape(n, h // 2, ww // 2, c, 2, 2).transpose(0, 1, 4, 2, 5, 3)
    return dx.reshape(shape)


def conv1_fwd(x, w, b):
    return x @ w.T + b


# ------------------------------------------------------------------ training
def init():
    return [
        dict(w=(rng.standard_normal((8, C_IN, 3, 3)) * 0.6).astype(np.float32),
             b=np.zeros(8, np.float32)),
        dict(w=(rng.standard_normal((16, 8, 3, 3)) * 0.4).astype(np.float32),
             b=np.zeros(16, np.float32)),
        dict(w=(rng.standard_normal((16, 16, 3, 3)) * 0.3).astype(np.float32),
             b=np.zeros(16, np.float32)),
        dict(w=(rng.standard_normal((8, 16)) * 0.3).astype(np.float32),
             b=np.zeros(8, np.float32)),
    ]


def forward(P, x):
    a1 = conv_fwd(x, P[0]['w'], P[0]['b']); r1 = np.maximum(a1, 0)
    p1, i1 = pool_fwd(r1)
    a2 = conv_fwd(p1, P[1]['w'], P[1]['b']); r2 = np.maximum(a2, 0)
    p2, i2 = pool_fwd(r2)
    a3 = conv_fwd(p2, P[2]['w'], P[2]['b']); r3 = np.maximum(a3, 0)
    out = conv1_fwd(r3, P[3]['w'], P[3]['b'])
    return out, (x, r1, i1, p1, r2, i2, p2, r3)


def backward(P, cache, dout):
    x, r1, i1, p1, r2, i2, p2, r3 = cache
    g = [dict() for _ in range(4)]
    g[3]['w'] = np.tensordot(dout, r3, axes=([0, 1, 2], [0, 1, 2]))
    g[3]['b'] = dout.sum(axis=(0, 1, 2))
    d3 = dout @ P[3]['w']
    d3 = d3 * (r3 > 0)
    d_p2, g[2]['w'], g[2]['b'] = conv_bwd(d3, p2, P[2]['w'])
    d2 = pool_bwd(d_p2, i2, r2.shape) * (r2 > 0)
    d_p1, g[1]['w'], g[1]['b'] = conv_bwd(d2, p1, P[1]['w'])
    d1 = pool_bwd(d_p1, i1, r1.shape) * (r1 > 0)
    _, g[0]['w'], g[0]['b'] = conv_bwd(d1, x, P[0]['w'])
    return g


def centroid_error(out, y):
    gy, gx = np.mgrid[0:GRID, 0:GRID]
    errs = []
    for i in range(out.shape[0]):
        wt = np.maximum(out[i, :, :, 0], 0.0)
        t = y[i, :, :, 0]
        if wt.sum() < 1e-6 or t.sum() < 1e-6:
            errs.append(99.0)
            continue
        cy = (gy * wt).sum() / wt.sum()
        cx = (gx * wt).sum() / wt.sum()
        ty = (gy * t).sum() / t.sum()
        tx = (gx * t).sum() / t.sum()
        errs.append(np.hypot(cy - ty, cx - tx) * CELL)
    e = np.array(errs)
    return e.mean(), (e <= 3.0).mean() * 100.0


def main():
    print("generating data ...")
    xtr, ytr = make_batch(1500)
    xte, yte = make_batch(200)

    P = init()
    m = [{k: np.zeros_like(v) for k, v in p.items()} for p in P]
    v = [{k: np.zeros_like(vv) for k, vv in p.items()} for p in P]
    lr, b1, b2, eps = 2e-3, 0.9, 0.999, 1e-8
    t = 0

    for epoch in range(30):
        order = rng.permutation(len(xtr))
        tot = 0.0
        for s in range(0, len(xtr), 32):
            idx = order[s:s + 32]
            xb, yb = xtr[idx], ytr[idx]
            out, cache = forward(P, xb)
            # obj channel weighted heavily; w/h lightly
            d = np.zeros_like(out)
            d[:, :, :, 0] = 2.0 * (out[:, :, :, 0] - yb[:, :, :, 0]) / (out[:, :, :, 0].size)
            d[:, :, :, 1] = 0.2 * (out[:, :, :, 1] - yb[:, :, :, 1]) / (out[:, :, :, 1].size)
            d[:, :, :, 2] = 0.2 * (out[:, :, :, 2] - yb[:, :, :, 2]) / (out[:, :, :, 2].size)
            tot += float(((out[:, :, :, 0] - yb[:, :, :, 0]) ** 2).mean())
            g = backward(P, cache, d)
            t += 1
            for l in range(4):
                for k in 'wb':
                    gr = g[l][k]
                    m[l][k] = b1 * m[l][k] + (1 - b1) * gr
                    v[l][k] = b2 * v[l][k] + (1 - b2) * gr * gr
                    mh = m[l][k] / (1 - b1 ** t)
                    vh = v[l][k] / (1 - b2 ** t)
                    P[l][k] -= lr * mh / (np.sqrt(vh) + eps)
        if epoch % 5 == 4 or epoch == 0:
            out, _ = forward(P, xte)
            mae, hit = centroid_error(out, yte)
            print("epoch %2d  objMSE %.4f  test %.2f px  within3 %.0f%%"
                  % (epoch, tot / max(1, len(xtr) // 32), mae, hit))

    out, _ = forward(P, xte)
    mae, hit = centroid_error(out, yte)
    print("final: %.2f px, within 3px %.0f%%" % (mae, hit))

    # The board feeds raw 8-bit RGB bytes, so the first layer absorbs the 255x
    # scale instead of asking the firmware to normalise: w1/255 with 0..255
    # inputs is the same function as w1 with 0..1 inputs, and the calibration
    # images below are exported in the same units the hardware will see.
    np.savez(ROOT / "tools/model/detector_bp.npz",
             w1=P[0]['w'] / 255.0, b1=P[0]['b'],
             w2=P[1]['w'], b2=P[1]['b'],
             w3=P[2]['w'], b3=P[2]['b'], wh=P[3]['w'], bh=P[3]['b'],
             l3_relu=np.int32(1), xte=xte[:8] * 255.0, yte=yte[:8])
    print("wrote tools/model/detector_bp.npz")


if __name__ == "__main__":
    main()
