#!/usr/bin/env python3
"""Group captured patches into k clusters and print each cluster's centre.

Training data comes from a recording where the user performed the gestures in
turn, but the stream itself has no labels.  Rather than ask for a few hundred
clicks, cluster first and let the user name each cluster once (k names instead
of n labels).

Patches are normalised per image (zero mean, unit variance) before clustering so
the groups follow shape rather than brightness.
"""
import sys
from pathlib import Path

import numpy as np

RAMP = " .:-=+*#%@"


def norm(x):
    f = x.reshape(len(x), -1).astype(np.float32)
    f = f - f.mean(axis=1, keepdims=True)
    f = f / (f.std(axis=1, keepdims=True) + 1e-6)
    return f


def kmeans(x, k, iters=60, seed=3):
    rng = np.random.default_rng(seed)
    c = x[rng.choice(len(x), k, replace=False)]
    for _ in range(iters):
        d = ((x[:, None, :] - c[None, :, :]) ** 2).sum(axis=2)
        lab = d.argmin(axis=1)
        for j in range(k):
            if (lab == j).any():
                c[j] = x[lab == j].mean(axis=0)
    return lab, c


def show(vec):
    img = vec.reshape(32, 32)
    lo, hi = img.min(), img.max()
    out = []
    for y in range(0, 32, 2):
        row = ""
        for x in range(32):
            v = (img[y, x] - lo) / (hi - lo + 1e-6)
            row += RAMP[min(len(RAMP) - 1, int(v * len(RAMP)))]
        out.append(row)
    return "\n".join(out)


def main():
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("build/rps_round1.npz")
    k = int(sys.argv[2]) if len(sys.argv) > 2 else 3
    d = np.load(src)
    x = d["x"]
    f = norm(x)
    lab, c = kmeans(f, k)

    print(f"{len(x)} patches -> {k} clusters")
    for j in range(k):
        n = int((lab == j).sum())
        print(f"\n--- cluster {j}: {n} patches ---")
        print(show(c[j]))
        idx = np.where(lab == j)[0][:1]
        if len(idx):
            print(f"(example index {idx[0]})")

    out = src.with_name(src.stem + "_labels.npz")
    np.savez_compressed(out, x=x, label=lab)
    print(f"\nwrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
