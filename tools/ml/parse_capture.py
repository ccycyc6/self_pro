#!/usr/bin/env python3
"""Parse a capture from tools/ml/capture.ps1 into an npz dataset.

Frame layout (see the firmware): A5 5A id <1024 bytes> csum.
The length is fixed, so the parser scans for the header and checks the checksum;
anything that fails is dropped as a resync.
"""
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
W = H = 32
N = W * H


def parse(data: bytes):
    patches, ids, bad = [], [], 0
    i = 0
    while i + 3 + N + 1 <= len(data):
        if data[i] != 0xA5 or data[i + 1] != 0x5A:
            i += 1
            continue
        tid = data[i + 2]
        body = data[i + 3:i + 3 + N]
        csum = data[i + 3 + N]
        if (sum(body) & 0xFF) != csum:
            bad += 1
            i += 1
            continue
        patches.append(np.frombuffer(body, dtype=np.uint8).reshape(H, W))
        ids.append(tid)
        i += 3 + N + 1
    return patches, ids, bad


def preview(patch):
    ramp = " .:-=+*#%@"
    out = []
    for y in range(0, H, 2):
        out.append("".join(ramp[min(len(ramp) - 1, patch[y, x] * len(ramp) // 256)]
                           for x in range(0, W, 1)))
    return "\n".join(out)


def main():
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "build/capture.bin"
    data = src.read_bytes()
    patches, ids, bad = parse(data)
    print(f"{len(data)} bytes -> {len(patches)} patches, {bad} bad frames")
    if not patches:
        return 1

    x = np.stack(patches)
    y = np.array(ids, dtype=np.int64)
    out = src.with_suffix(".npz")
    np.savez_compressed(out, x=x, id=y)
    print(f"wrote {out}  x={x.shape}  ids={np.bincount(y).tolist()}")
    print("first patch:")
    print(preview(x[0]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
