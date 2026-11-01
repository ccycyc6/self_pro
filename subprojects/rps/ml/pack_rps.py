#!/usr/bin/env python3
"""Pack the trained rock/paper/scissors classifier for the accelerator.

Same quantisation scheme as pack_weights.py (per-layer scales, INT8 weights,
epilogue mult/shift), but the head now carries three class scores instead of
the detector's object map, and the quality metric is classification accuracy on
the integer model rather than a centroid error.

Emits firmware/yolo/rps_weights.h with the same symbol names the firmware
already uses (det_wtN / det_biasN / det_cfgN), so the runtime path is unchanged.
"""
import sys
from pathlib import Path

import numpy as np

SUB = Path(__file__).resolve().parents[1]
ROOT = SUB.parents[1]
sys.path.insert(0, str(ROOT / "tools" / "model"))

import pack_weights as pw   # reuse the row packing and cfg builder

CLASSES = ["rock", "paper", "scissors"]


def carr(name, data):
    body = ",".join(str(int(v)) for v in np.asarray(data).reshape(-1))
    return "static const unsigned char %s[%d] = {%s};\n" % \
        (name, np.asarray(data).size, body)


def expand(x):
    """(N,32,32) uint8 luma -> (N,32,32,4) float in 0..1, replicated.

    The network was trained on 0..1 inputs; feeding 0..255 makes every float
    score meaningless (and the calibration ranges wrong by 255x), which is what
    made the first packing look broken when the quantiser was fine.
    """
    f = x.astype(np.float32) / 255.0
    out = np.zeros((len(x), 32, 32, 4), np.float32)
    out[:, :, :, 0] = f
    out[:, :, :, 1] = f
    out[:, :, :, 2] = f
    return out


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        return 0

    d = np.load(SUB / "data" / "float.npz")
    w = [d["w1"], d["w2"], d["w3"]]
    b = [d["b1"], d["b2"], d["b3"]]
    wh = d["wh"]
    bh = d["bh"]

    ds = np.load(SUB / "data" / "dataset.npz")
    x = ds["x"]
    y = ds["y"]
    rng = np.random.default_rng(5)
    idx = rng.choice(len(x), min(120, len(x)), replace=False)
    xcal = expand(x[idx])
    ycal = y[idx]

    # calibration: activation ranges on the calibration set
    mx = [0.0, 0.0, 0.0, 0.0]
    head_w = wh.reshape(8, 16, 1, 1)
    for i in range(len(xcal)):
        a = xcal[i]
        for li in range(3):
            L = pw.LAYERS[li]
            a = pw.conv_float(a, w[li], b[li], L["pad"])
            if L["relu"]:
                a = np.maximum(a, 0.0)
            mx[li] = max(mx[li], float(np.max(np.abs(a))))
            if li < 2:
                a = pw.pool2(a)
        o = pw.conv_float(a, head_w, bh, 0)
        mx[3] = max(mx[3], float(np.max(np.abs(o))))

    # Widen the margin between classes.  The head output is quantised with a
    # step proportional to its maximum, and the differences between class
    # scores were only a couple of steps wide.  Dividing the head by its own
    # maximum leaves argmax untouched (it is a positive scale) but makes those
    # differences span the whole int8 range.
    # NOTE: normalising the head by its maximum was tried and made the class
    # means smaller (they are an average over the map, so they shrink with the
    # scale) while the quantiser's step shrinks by the same factor -- a wash, but
    # it left the differences at 2-8 LSBs.  Leaving the head as trained keeps
    # them at ~30 LSBs.

    mx0 = max(float(np.max(np.abs(xcal))), 1e-6)
    s_in = [mx0 / 127.0] + [m / 127.0 for m in mx]

    packed = []
    for li, L in enumerate(pw.LAYERS):
        ww = [w[0], w[1], w[2], head_w][li]
        bb = [b[0], b[1], b[2], bh][li]
        wq, s_w = pw.quant(ww)
        s_x_in, s_x_out = s_in[li], s_in[li + 1]
        ratio = s_x_in * s_w / s_x_out
        shift = 0
        while shift < pw.SHIFT_MAX and ratio * (1 << (shift + 1)) <= pw.MULT_MAX:
            shift += 1
        mult = max(1, min(pw.MULT_MAX, int(round(ratio * (1 << shift)))))
        bq = np.round(bb / (s_x_in * s_w)).astype(np.int32)
        nmt = pw.choose_nmt(L)
        wt, bias, cfg = pw.to_rows(wq, L, mult, shift, bq, 0, L["relu"], nmt)
        packed.append(dict(wt=wt, bias=bias, cfg=cfg, bias_q=bq, nmt=nmt,
                           mult=mult, shift=shift, zp=0, relu=L["relu"]))
        print(f"L{li + 1}: s_in={s_x_in:.5f} s_w={s_w:.5f} s_out={s_x_out:.5f} "
              f"mult={mult} shift={shift} nmt={nmt}")

    # integer model, classification accuracy
    ok = 0
    conf = np.zeros((3, 3), int)
    for i in range(len(xcal)):
        flat = np.round(xcal[i] / s_in[0]).astype(np.int32)
        flat = np.clip(flat, -128, 127)
        raw = (flat.reshape(-1) & 0xFF).astype(np.uint8)
        out = pw.int_forward(raw, packed)
        # Head layout: two groups of four channels, each an 8x8 map.  Channel c
        # lives in group c//4, lane c%4; the classifier averages the map, which
        # is the global average pooling the network was trained with.
        scores = []
        for c in range(3):
            g, lane = c // 4, c % 4
            block = out[g * 256:(g + 1) * 256].reshape(8, 8, 4)
            scores.append(int(np.mean(block[:, :, lane].astype(np.int8))))
        scores = np.array(scores, np.int32)
        pred = int(np.argmax(scores))
        conf[int(ycal[i]), pred] += 1
        ok += int(pred == int(ycal[i]))

    print(f"\ninteger model accuracy on {len(xcal)} calibration patches: "
          f"{ok / len(xcal) * 100:.1f}%")
    print("confusion (rows truth, cols prediction):")
    print(conf)

    # full check on every captured patch, with the same packed layers the
    # firmware gets: this is the number that matters, not the 120-sample one
    ok_all = 0
    conf_all = np.zeros((3, 3), int)
    for i in range(len(x)):
        flat = np.clip(np.round(expand(x[i:i + 1])[0] / s_in[0]), -128, 127).astype(np.int32)
        raw = (flat.reshape(-1) & 0xFF).astype(np.uint8)
        out = pw.int_forward(raw, packed)
        sc = []
        for c in range(3):
            g, lane = c // 4, c % 4
            blk = out[g * 256:(g + 1) * 256].reshape(64, 4)
            sc.append(int(np.mean(blk[:, lane].astype(np.int8))))
        pred = int(np.argmax(sc))
        conf_all[int(y[i]), pred] += 1
        ok_all += int(pred == int(y[i]))
    print(f"integer accuracy on all {len(x)} captured patches: "
          f"{ok_all / len(x) * 100:.1f}%")
    print(conf_all)

    ns = 8
    imgs = np.zeros((ns, 32 * 32 * 4), dtype=np.uint8)
    gold = np.zeros((ns, 64 * 8), dtype=np.uint8)
    for i in range(ns):
        flat = np.round(xcal[i] / s_in[0]).astype(np.int32)
        flat = np.clip(flat, -128, 127)
        imgs[i] = (flat.reshape(-1) & 0xFF).astype(np.uint8)
        gold[i] = (pw.int_forward(imgs[i], packed).reshape(-1) & 0xFF).astype(np.uint8)

    # optional: classify an external patch set with this exact packing
    if len(sys.argv) > 2 and sys.argv[1] == "--check":
        ext = np.load(ROOT / sys.argv[2])
        ex = ext["x"] if "x" in ext else ext["patch"].reshape(-1, 32, 32)
        print(f"checking {len(ex)} external patches")
        for j in range(0, len(ex), max(1, len(ex) // 6)):
            flat = np.clip(np.round(expand(ex[j:j + 1])[0] / s_in[0]), -128, 127).astype(np.int32)
            out = pw.int_forward((flat.reshape(-1) & 0xFF).astype(np.uint8), packed)
            sc = [int(np.mean(out[(c // 4) * 256:(c // 4 + 1) * 256].reshape(64, 4)[:, c % 4].astype(np.int8)))
                  for c in range(3)]
            print(f"  patch {j:3d}: scores {sc} -> class {int(np.argmax(sc))}")

    # Per-class normalisation.  The head's three channels do not have the same
    # spread: on the calibration set class 0 and 1 swing by +-30 while class 2
    # (scissors) only reaches a few counts, so an absolute margin gate rejects
    # scissors while accepting everything else.  Z-scoring each class against
    # its own mean and spread makes the margins comparable, and the constants
    # are tiny so they go into the firmware header.
    sc_all = []   # keep for diagnostics only
    for i in range(len(x)):
        flat = np.clip(np.round(expand(x[i:i + 1])[0] / s_in[0]), -128, 127).astype(np.int32)
        out = pw.int_forward((flat.reshape(-1) & 0xFF).astype(np.uint8), packed)
        sc_all.append([float(np.mean(out[(c // 4) * 256:(c // 4 + 1) * 256].reshape(64, 4)[:, c % 4].astype(np.int8)))
                       for c in range(3)])
    sc_all = np.array(sc_all)
    mean_c = sc_all.mean(axis=0)
    std_c = sc_all.std(axis=0)
    std_c = np.where(std_c < 1e-3, 1.0, std_c)
    inv_c = np.round(256.0 / std_c).astype(int)
    print("class means:", np.round(mean_c, 1).tolist())
    print("class std  :", np.round(std_c, 1).tolist())

    # Note: z-scoring per class was tried and made things worse (74.6%).  The
    # scissors channel barely responds -- mean 4.5, spread 0.8 -- so the network
    # decides scissors by the other two channels going negative, and an absolute
    # margin on scissors can only ever be about 6 counts.  The firmware gate is
    # therefore 4, not 8.

    labels = []
    for i in range(ns):
        flat = np.clip(np.round(expand(x[idx[i]:idx[i] + 1])[0] / s_in[0]), -128, 127).astype(np.int32)
        out = pw.int_forward((flat.reshape(-1) & 0xFF).astype(np.uint8), packed)
        sc = [int(np.mean(out[(c // 4) * 256:(c // 4 + 1) * 256].reshape(64, 4)[:, c % 4].astype(np.int8)))
              for c in range(3)]
        labels.append(int(np.argmax(sc)))
    print("gold image labels:", labels)

    out_path = ROOT / "firmware" / "yolo" / "rps_weights.h"
    with open(out_path, "w") as f:
        f.write("/* Auto-generated by tools/ml/pack_rps.py -- do not edit. */\n")
        f.write("#ifndef RPS_WEIGHTS_H\n#define RPS_WEIGHTS_H\n\n")
        f.write("#define RPS_CLASSES 3\n")
        # The accelerator takes int8 operands, so the firmware has to quantise
        # the patch with the same input scale the calibration used.  A Q8
        # multiplier keeps it integer: q = (pixel * mult) >> 8, clamped to 127.
        # s_in[0] maps the 0..1 float input to int8; the firmware has bytes, so
        # the extra factor of 255 belongs here.
        mult8 = int(round(256.0 / (255.0 * s_in[0])))
        f.write("#define RPS_IN_MULT %d\n" % mult8)
        # mt_detect.c names the packed test vectors det_imgs / det_gold
        f.write("#define det_imgs rps_imgs\n")
        f.write("#define det_gold rps_gold\n\n")
        for li, p in enumerate(packed):
            f.write(carr("det_wt%d" % (li + 1), p["wt"]))
            f.write(carr("det_bias%d" % (li + 1), p["bias"]))
            f.write(carr("det_cfg%d" % (li + 1), p["cfg"]))
            f.write("\n")
        f.write(carr("rps_imgs", imgs))
        f.write("\n")
        f.write(carr("rps_gold", gold))
        f.write("\n#endif\n")
    # a tiny companion header: the weight arrays are static and live in one
    # translation unit, but the camera firmware needs the input scale too
    params = ROOT / "firmware" / "yolo" / "rps_params.h"
    with open(params, "w") as f:
        f.write("/* Auto-generated by tools/ml/pack_rps.py -- do not edit. */\n")
        f.write("#ifndef RPS_PARAMS_H\n#define RPS_PARAMS_H\n\n")
        f.write("#define RPS_IN_MULT %d\n" % mult8)
        f.write("#define RPS_CLASSES 3\n\n#endif\n")
    print(f"wrote {params}")
    print(f"wrote {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
