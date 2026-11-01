#!/usr/bin/env python3
"""Train the rock/paper/scissors classifier on the captured patches.

Topology is fixed by the accelerator: conv3x3 4->8, pool, conv3x3 8->16, pool,
conv3x3 16->16, conv1x1 16->8.  Only three of the eight head channels are used
for the classes; the rest stay zero, which costs nothing.

The patch arrives as one luma byte per pixel and is fed to all three colour
channels (the engine works on 4-channel groups), exactly as the firmware does.
"""
import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

SUB = Path(__file__).resolve().parents[1]
ROOT = SUB.parents[1]
CLASSES = ["rock", "paper", "scissors"]


def to_input(x):
    """(N,32,32) uint8 -> (N,4,32,32) float in 0..1, luma replicated."""
    f = x.astype(np.float32) / 255.0
    out = np.zeros((len(x), 4, 32, 32), np.float32)
    out[:, 0] = f
    out[:, 1] = f
    out[:, 2] = f
    return torch.from_numpy(out)


def augment(batch):
    """Rotation, flip, shift, brightness and erase.  A hand can arrive from any
    side and at any tilt, so the classifier has to see those before it is used."""
    b = batch.clone()

    # small rotations
    ang = (torch.rand(len(b)) * 40 - 20) * np.pi / 180.0
    cos, sin = torch.cos(ang), torch.sin(ang)
    theta = torch.zeros(len(b), 2, 3)
    theta[:, 0, 0] = cos
    theta[:, 0, 1] = -sin
    theta[:, 1, 0] = sin
    theta[:, 1, 1] = cos
    grid = F.affine_grid(theta, b.shape, align_corners=False)
    b = F.grid_sample(b, grid, align_corners=False, padding_mode="border")

    # horizontal flip
    flip = torch.rand(len(b)) < 0.5
    b[flip] = torch.flip(b[flip], dims=[3])

    # small shift
    sh = (torch.rand(len(b), 2) * 4 - 2).round().int()
    for i in range(len(b)):
        b[i] = torch.roll(b[i], shifts=(int(sh[i, 0]), int(sh[i, 1])), dims=(1, 2))

    # brightness / contrast
    gain = 0.8 + torch.rand(len(b), 1, 1, 1) * 0.4
    bias = (torch.rand(len(b), 1, 1, 1) - 0.5) * 0.2
    b = (b * gain + bias).clamp(0, 1)

    # random erase
    for i in range(len(b)):
        if torch.rand(()) < 0.3:
            h = int(torch.randint(4, 10, (1,)))
            w = int(torch.randint(4, 10, (1,)))
            y = int(torch.randint(0, 32 - h, (1,)))
            x = int(torch.randint(0, 32 - w, (1,)))
            b[i, :, y:y + h, x:x + w] = 0.0
    return b


class Net(nn.Module):
    def __init__(self, nclass=3):
        super().__init__()
        self.c1 = nn.Conv2d(4, 8, 3, padding=1, bias=True)
        self.c2 = nn.Conv2d(8, 16, 3, padding=1, bias=True)
        self.c3 = nn.Conv2d(16, 16, 3, padding=1, bias=True)
        self.hd = nn.Conv2d(16, 8, 1, bias=True)
        self.nclass = nclass

    def forward(self, x):
        x = F.max_pool2d(F.relu(self.c1(x)), 2)
        x = F.max_pool2d(F.relu(self.c2(x)), 2)
        x = F.relu(self.c3(x))
        x = self.hd(x)
        x = F.adaptive_avg_pool2d(x, 1).flatten(1)
        return x[:, :self.nclass]


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        return 0

    d = np.load(SUB / "data" / "dataset.npz")
    x, y = d["x"], d["y"]
    rng = np.random.default_rng(11)
    tr, te = [], []
    for c in range(len(CLASSES)):
        idx = np.where(y == c)[0]
        rng.shuffle(idx)
        cut = int(len(idx) * 0.7)
        tr.append(idx[:cut])
        te.append(idx[cut:])
    tr = np.concatenate(tr)
    te = np.concatenate(te)

    xtr = to_input(x[tr]); ytr = torch.from_numpy(y[tr])
    xte = to_input(x[te]); yte = torch.from_numpy(y[te])

    torch.manual_seed(4)
    net = Net()
    opt = torch.optim.Adam(net.parameters(), lr=2e-3)
    best = 0.0

    for epoch in range(120):
        net.train()
        perm = torch.randperm(len(xtr))
        total = 0.0
        for s in range(0, len(xtr), 32):
            idx = perm[s:s + 32]
            xb = augment(xtr[idx])
            out = net(xb)
            loss = F.cross_entropy(out, ytr[idx])
            opt.zero_grad()
            loss.backward()
            opt.step()
            total += float(loss) * len(idx)
        if epoch % 20 == 19 or epoch == 0:
            net.eval()
            with torch.no_grad():
                acc = (net(xte).argmax(1) == yte).float().mean().item()
                acc_aug = (net(augment(xte)).argmax(1) == yte).float().mean().item()
            print(f"epoch {epoch:3d}  loss {total / len(xtr):.4f}  "
                  f"test {acc * 100:5.1f}%  augmented-test {acc_aug * 100:5.1f}%")
            if acc_aug > best:
                best = acc_aug
                torch.save(net.state_dict(), SUB / "data" / "model.pt")

    net.load_state_dict(torch.load(SUB / "data" / "model.pt"))
    net.eval()
    with torch.no_grad():
        pred = net(xte).argmax(1).numpy()
    print("\nconfusion (rows = truth, cols = prediction):")
    cm = np.zeros((3, 3), int)
    for t, p in zip(yte.numpy(), pred):
        cm[t, p] += 1
    print(cm)

    sd = {k: v.detach().numpy().astype(np.float32) for k, v in net.state_dict().items()}
    np.savez(SUB / "data" / "float.npz",
             w1=sd["c1.weight"], b1=sd["c1.bias"],
             w2=sd["c2.weight"], b2=sd["c2.bias"],
             w3=sd["c3.weight"], b3=sd["c3.bias"],
             wh=sd["hd.weight"].reshape(8, 16), bh=sd["hd.bias"],
             xte=x[:8] * 1.0, yte=y[:8])
    print("wrote", SUB / "data" / "float.npz")
    return 0


if __name__ == "__main__":
    sys.exit(main())
