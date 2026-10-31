#!/usr/bin/env python3
"""Write a PNG montage of clustered patches so a human can name each cluster.

Pure python on purpose: the tool has to run in the same WSL image as the rest of
the pipeline, which has numpy but no PIL.
"""
import struct
import sys
import zlib
from pathlib import Path

import numpy as np


def write_png(path, img):
    """img: HxW uint8 grayscale."""
    h, w = img.shape
    raw = b"".join(b"\x00" + img[y].tobytes() for y in range(h))

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
    Path(path).write_bytes(png)


def upscale(a, k):
    return np.kron(a, np.ones((k, k), dtype=np.uint8))


def main():
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("build/rps_round1_labels.npz")
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("build/clusters.png")
    per_row = 6
    k = 4

    d = np.load(src)
    x, lab = d["x"], d["label"]
    classes = np.unique(lab)
    rows = []
    for c in classes:
        idx = np.where(lab == c)[0][:per_row]
        tiles = []
        for i in idx:
            tiles.append(upscale(x[i], k))
        while len(tiles) < per_row:
            tiles.append(np.zeros((32 * k, 32 * k), np.uint8))
        rows.append(np.concatenate(tiles, axis=1))
        # a separator line between classes
        rows.append(np.full((6, per_row * 32 * k), 255, np.uint8))

    write_png(out, np.concatenate(rows, axis=0))
    print(f"wrote {out}  ({len(classes)} rows, {per_row} examples each)")


if __name__ == "__main__":
    main()
