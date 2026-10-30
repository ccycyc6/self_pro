#!/usr/bin/env python3
"""Train the detector with PyTorch, keeping the accelerator's topology.

Same model as tools/model/train_bp.py (numpy backprop) but with a real training
stack: augmentation, an optimizer that works, and room to grow.  The exported
npz is exactly what pack_weights.py consumes, so the packing/quantisation path
and the RTL stay untouched.

The topology is not negotiable -- it mirrors the hardware:
    conv3x3 4->8 ReLU pool2 / conv3x3 8->16 ReLU pool2 /
    conv3x3 16->16 ReLU / conv1x1 16->8   (obj, w, h, pad per cell)
"""
from pathlib import Path
import numpy as np
import torch
import torch.nn as nn

ROOT = Path(__file__).resolve().parents[2]
H = W = 32
C_IN = 4
GRID = 8
CELL = H // GRID
SIZE_MIN, SIZE_MAX = 4, 16

TARGET_RGB = (1.00, 0.12, 0.12)
DISTRACTORS = [(0.95, 0.95, 0.95), (0.60, 0.60, 0.60), (0.25, 0.25, 0.25),
               (0.10, 0.20, 1.00), (0.15, 0.90, 0.20), (1.00, 0.75, 0.10)]


def rng_box(rng, size):
    return (int(rng.integers(0, H - size + 1)), int(rng.integers(0, W - size + 1)))


def draw(x, top, left, rgb, size):
    x[top:top + size, left:left + size, 0] = rgb[0]
    x[top:top + size, left:left + size, 1] = rgb[1]
    x[top:top + size, left:left + size, 2] = rgb[2]


def make_batch(n, rng):
    """1..3 red targets per frame, every one labelled in the object channel.

    The head answers per cell, so several targets are just several hot cells; the
    firmware picks the peaks.  Distractors keep the colour discrimination honest.
    """
    x = np.zeros((n, H, W, C_IN), np.float32)
    y = np.zeros((n, GRID, GRID, 3), np.float32)
    for i in range(n):
        ntgt = int(rng.integers(1, 4))
        boxes = []
        tries = 0
        while len(boxes) < ntgt and tries < 40:
            tries += 1
            size = int(rng.integers(SIZE_MIN, SIZE_MAX + 1))
            top, left = rng_box(rng, size)
            if any(abs(top - t) < size + 2 and abs(left - l) < size + 2
                   for t, l, _ in boxes):
                continue
            gain = float(rng.uniform(0.45, 1.0))
            draw(x[i], top, left, tuple(c * gain for c in TARGET_RGB), size)
            boxes.append((top, left, size))

        for _ in range(3):
            ds = int(rng.integers(SIZE_MIN, SIZE_MAX + 1))
            dt, dl = rng_box(rng, ds)
            if any(abs(dt - t) < ds + 2 and abs(dl - l) < ds + 2 for t, l, _ in boxes):
                continue
            col = DISTRACTORS[int(rng.integers(0, len(DISTRACTORS)))]
            draw(x[i], dt, dl, tuple(c * float(rng.uniform(0.4, 1.0)) for c in col), ds)

        for cy in range(GRID):
            for cx in range(GRID):
                r0, c0 = cy * CELL, cx * CELL
                hit = 0.0
                for top, left, size in boxes:
                    dh = max(0, min(top + size, r0 + CELL) - max(top, r0))
                    dw = max(0, min(left + size, c0 + CELL) - max(left, c0))
                    if (dh * dw) >= (CELL * CELL) // 2:
                        hit = 1.0
                y[i, cy, cx, 0] = hit
        if boxes:
            s = float(boxes[0][2])
            y[i, :, :, 1] = s / H
            y[i, :, :, 2] = s / W
    x += rng.normal(0.0, 3.0 / 255.0, x.shape).astype(np.float32)
    np.clip(x, 0.0, 1.0, out=x)
    return x, y


class Net(nn.Module):
    """The hardware topology, with a spare 1x1 head channel space of 8."""

    def __init__(self):
        super().__init__()
        self.c1 = nn.Conv2d(C_IN, 8, 3, padding=1, bias=True)
        self.c2 = nn.Conv2d(8, 16, 3, padding=1, bias=True)
        self.c3 = nn.Conv2d(16, 16, 3, padding=1, bias=True)
        self.hd = nn.Conv2d(16, 8, 1, bias=True)

    def forward(self, x):
        x = torch.relu(self.c1(x))
        x = torch.nn.functional.max_pool2d(x, 2)
        x = torch.relu(self.c2(x))
        x = torch.nn.functional.max_pool2d(x, 2)
        x = torch.relu(self.c3(x))
        return self.hd(x)


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
    torch.manual_seed(20261030)
    rng = np.random.default_rng(20261030)
    net = Net()
    opt = torch.optim.Adam(net.parameters(), lr=2e-3)
    bce = nn.BCEWithLogitsLoss()

    xte_np, yte_np = make_batch(200, rng)
    xt = torch.from_numpy(xte_np.transpose(0, 3, 1, 2))

    for step in range(1201):
        xb, yb = make_batch(32, rng)
        xb = torch.from_numpy(xb.transpose(0, 3, 1, 2))
        yb = torch.from_numpy(yb.transpose(0, 3, 1, 2))   # N,C,8,8
        out = net(xb)
        loss = bce(out[:, 0], yb[:, 0])
        loss = loss + 0.2 * torch.mean((out[:, 1:3] - yb[:, 1:3]) ** 2)
        opt.zero_grad()
        loss.backward()
        opt.step()
        if step % 100 == 0 or step == 1200:
            with torch.no_grad():
                o = net(xt).numpy().transpose(0, 2, 3, 1)
            mae, hit = centroid_error(o, yte_np)
            print("step %4d  loss %.4f  test %.2f px  within3 %.0f%%"
                  % (step, float(loss), mae, hit))

    sd = {k: v.detach().numpy().astype(np.float32) for k, v in net.state_dict().items()}
    # torch conv weights are (out, in, ky, kx) -- the same order the packer wants.
    np.savez(ROOT / "tools/model/detector_bp.npz",
             w1=sd['c1.weight'] / 255.0, b1=sd['c1.bias'],
             w2=sd['c2.weight'], b2=sd['c2.bias'],
             w3=sd['c3.weight'], b3=sd['c3.bias'],
             wh=sd['hd.weight'].reshape(8, 16), bh=sd['hd.bias'],
             l3_relu=np.int32(1), xte=xte_np[:8] * 255.0, yte=yte_np[:8])
    print("wrote tools/model/detector_bp.npz")


if __name__ == "__main__":
    main()
