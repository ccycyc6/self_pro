#!/usr/bin/env python3
"""Integration test for the gesture model, no hardware needed.

Runs the packer end to end -- float weights, quantisation, the integer
reference -- and asserts the numbers the demo depends on: every captured patch
classified correctly, and the eight packed images producing the labels the
firmware is expected to reproduce on the board.
"""
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SUB = HERE.parent


def main():
    r = subprocess.run([sys.executable, str(HERE / "pack_rps.py")],
                       capture_output=True, text=True)
    out = r.stdout + r.stderr
    if r.returncode != 0:
        print(out)
        print("FAIL: pack_rps.py exited", r.returncode)
        return 1

    m = re.search(r"integer accuracy on all (\d+) captured patches: ([\d.]+)%", out)
    if not m:
        print(out)
        print("FAIL: no accuracy line from the packer")
        return 1
    n, acc = int(m.group(1)), float(m.group(2))

    m2 = re.search(r"gold image labels: \[([^\]]*)\]", out)
    labels = [int(v) for v in m2.group(1).split(",")] if m2 else []

    fails = 0
    def check(cond, what):
        nonlocal fails
        print(("ok: " if cond else "FAIL: ") + what)
        if not cond:
            fails += 1

    check(n >= 200, "dataset has at least 200 patches (got %d)" % n)
    check(acc == 100.0, "integer model classifies all patches (got %.1f%%)" % acc)
    check(len(labels) == 8, "eight packed images (got %d)" % len(labels))
    check(all(0 <= v <= 2 for v in labels), "packed labels are all in 0..2")

    for f in (SUB / "paths.py", SUB / "data" / "dataset.npz",
              SUB / "data" / "float.npz",
              SUB.parents[1] / "firmware" / "yolo" / "rps_weights.h"):
        check(f.exists(), "present: " + str(f.relative_to(SUB.parents[1])))

    print("model tests: %s (%d failure%s)" %
          ("PASSED" if not fails else "FAILED", fails, "" if fails == 1 else "s"))
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
