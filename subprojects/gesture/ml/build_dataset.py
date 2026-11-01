#!/usr/bin/env python3
"""Merge the per-gesture captures into one labelled dataset and measure how
separable the three classes are before any training is committed to.

Each capture is a single gesture, so the label is certain -- no clustering
guesswork.  The separability check is 3-NN on normalised pixels with a held-out
split: if that is near chance the CNN will not save us either, and this is the
moment to find out.
"""
import sys
from pathlib import Path

from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import paths

CLASSES = ["rock", "paper", "scissors"]


def load(name):
    path = paths.CAPTURES[name]
    if not path.exists():
        msg = ("missing " + path.name + ": record the three gestures first\n"
               "  make -C subprojects/gesture capture\n"
               "  (each gesture in its own pass, so the labels are certain)")
        raise SystemExit(msg)
    return np.load(path)["x"]


def norm(x):
    f = x.reshape(len(x), -1).astype(np.float32)
    f = f - f.mean(axis=1, keepdims=True)
    return f / (f.std(axis=1, keepdims=True) + 1e-6)


def knn_accuracy(xtr, ytr, xte, yte, k=3):
    d = ((xte[:, None, :] - xtr[None, :, :]) ** 2).sum(axis=2)
    idx = np.argsort(d, axis=1)[:, :k]
    votes = ytr[idx]
    pred = np.array([np.bincount(v, minlength=len(CLASSES)).argmax() for v in votes])
    return (pred == yte).mean(), pred


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        return 0

    xs, ys = [], []
    for i, name in enumerate(CLASSES):
        x = load(name)
        xs.append(x)
        ys.append(np.full(len(x), i, dtype=np.int64))
        print(f"{name:9s} {len(x):4d} frames")

    x = np.concatenate(xs)
    y = np.concatenate(ys)

    np.savez_compressed(paths.DATASET, x=x, y=y)
    print(f"dataset: {x.shape} -> build/rps_dataset.npz")

    # held-out split, stratified
    rng = np.random.default_rng(7)
    tr, te = [], []
    for c in range(len(CLASSES)):
        idx = np.where(y == c)[0]
        rng.shuffle(idx)
        cut = int(len(idx) * 0.7)
        tr.append(idx[:cut])
        te.append(idx[cut:])
    tr = np.concatenate(tr)
    te = np.concatenate(te)

    f = norm(x)
    acc, pred = knn_accuracy(f[tr], y[tr], f[te], y[te])
    print(f"3-NN held-out accuracy: {acc * 100:.1f}%  (chance = 33.3%)")
    for c, name in enumerate(CLASSES):
        m = y[te] == c
        if m.any():
            print(f"  {name:9s} recall {(pred[m] == c).mean() * 100:5.1f}%"
                  f"  ({m.sum()} test frames)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
