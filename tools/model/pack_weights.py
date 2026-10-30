#!/usr/bin/env python3
"""Quantise the trained detector and pack it into the miniTensor memory layout.

Quantisation scheme
-------------------
Symmetric per-tensor INT8, zero point 0:

    activations   x_q = round(x_float / s_x),  s_x = max|x| / 127
    weights       w_q = round(w / s_w),        s_w = max|w| / 127
    accumulator   acc = sum x_q * w_q                        (INT32)
    output        y_q = clamp((acc + b_q) * mult >> shift)   (INT8)

with b_q the bias expressed in accumulator units and (mult, shift) the epilogue
fixed-point factor:

    mult / 2**shift  =  s_x_in * s_w / s_x_out

shift is chosen as large as possible while keeping mult inside the epilogue's
signed 16-bit field, so the requantisation keeps maximum precision.

pack_weights.py also computes the *integer* forward pass that mirrors the RTL
exactly; that is the golden the hardware must reproduce bit for bit.

Emits mt_detect_weights.h for the firmware plus a human-readable summary.
"""
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]

H = W = 32
C_IN = 4
GRID = 8

# Same descriptor table as mt_net.c / mt_detect.c.
LAYERS = [
    dict(h=32, w=32, c_in=4,  c_out=8,  k=3, pad=1, relu=1),
    dict(h=16, w=16, c_in=8,  c_out=16, k=3, pad=1, relu=1),
    dict(h=8,  w=8,  c_in=16, c_out=16, k=3, pad=1, relu=1),
    dict(h=8,  w=8,  c_in=16, c_out=8,  k=1, pad=0, relu=0),
]

MULT_MAX = 32767   # signed 16-bit field in the epilogue config word
SHIFT_MAX = 31     # 5-bit field


def quant(x, bits=8):
    """Symmetric per-tensor quantisation.  Returns (q, scale)."""
    m = float(np.max(np.abs(x)))
    if m < 1e-12:
        return np.zeros_like(x, dtype=np.int32), 1.0
    s = m / ((1 << (bits - 1)) - 1)
    return np.round(x / s).astype(np.int32), s


def conv_float(x, w, b, pad):
    """x [H,W,Cin], w [Cout,Cin,k,k], b [Cout] -> [H,W,Cout]."""
    h, ww, _ = x.shape
    k = w.shape[2]
    xp = np.pad(x, ((pad, pad), (pad, pad), (0, 0)))
    out = np.zeros((h, ww, w.shape[0]), dtype=np.float64)
    for ky in range(k):
        for kx in range(k):
            out += np.einsum('hwc,oc->hwo', xp[ky:ky + h, kx:kx + ww, :],
                             w[:, :, ky, kx])
    return out + b


def pool2(x):
    h, ww, c = x.shape
    return x.reshape(h // 2, 2, ww // 2, 2, c).max(axis=(1, 3))


# --------------------------------------------------------------- integer model
def choose_nmt(L):
    """Output-channel groups per weight tile.

    Mirrors what net_conv can hold: UB_WT has 144 rows and one output group
    needs k*k*ng of them, while UB_C..UB_BIAS (68 rows) must hold nmt*ntiles*4
    C rows.  Must agree with the firmware, so it is written into the packed
    config row and read back rather than recomputed there.
    """
    ng, k, nm = L['c_in'] // 4, L['k'], L['c_out'] // 4
    ntiles = L['w'] // 4
    by_wt = 144 // (k * k * ng)
    by_c = 68 // (ntiles * 4)
    return max(1, min(nm, by_wt, by_c))


def to_rows(wq, L, mult, shift, bq, zp, relu, nmt):
    """Pack one layer exactly the way net_pack_weights() does in the firmware.

    A (weight) row for (g, ky, kx, mg): byte 4*k + j holds
        w[in_ch = g*4+k][out_ch = mg*4+j][ky][kx]
    Each bias row is 16 bytes = four little-endian INT32, and the epilogue's 4x4
    C tile is indexed (spatial i, output channel j), so all four rows repeat the
    group's four channel biases.
    """
    ng, nm, k = L['c_in'] // 4, L['c_out'] // 4, L['k']
    ntap = ng * k * k
    ntile = (nm + nmt - 1) // nmt
    wt = np.zeros(ntile * ntap * nmt * 16, dtype=np.uint8)
    for ti in range(ntile):
        mg0 = ti * nmt
        for g in range(ng):
            for ky in range(k):
                for kx in range(k):
                    q = (g * k * k) + (ky * k) + kx
                    for j in range(min(nmt, nm - mg0)):
                        mg = mg0 + j
                        row = (ti * ntap * nmt) + (q * nmt) + j
                        for kk in range(4):
                            for jj in range(4):
                                ic = g * 4 + kk
                                oc = mg * 4 + jj
                                wt[row * 16 + 4 * kk + jj] = \
                                    np.uint8(wq[oc, ic, ky, kx] & 0xFF)
    bias = np.zeros(nm * 4 * 16, dtype=np.uint8)
    for mg in range(nm):
        for r in range(4):
            for j in range(4):
                v = np.int32(bq[mg * 4 + j])
                bias[mg * 64 + r * 16 + j * 4: mg * 64 + r * 16 + j * 4 + 4] = \
                    np.frombuffer(v.tobytes(), dtype=np.uint8)
    cfg = np.zeros(16, dtype=np.uint8)
    word = (int(mult) & 0xFFFF) | ((int(shift) & 0x1F) << 16) | \
           ((int(zp) & 0xFF) << 21) | ((1 if relu else 0) << 29)
    cfg[0:4] = np.frombuffer(np.uint32(word).tobytes(), dtype=np.uint8)
    cfg[4] = nmt & 0xFF          # weight tile size, read back by the firmware
    return wt, bias, cfg


def signed8(x):
    """Reinterpret a uint8 byte array as SIGNED int8.

    Getting this wrong is easy and silent: np.where(b > 127, b - 256, b) on a
    uint8 array wraps back to b, so the whole reference model would run with
    unsigned weights and saturate everywhere.
    """
    return np.asarray(x).astype(np.uint8).view(np.int8).astype(np.int32)


def to_mem(a_hwc):
    """[h][w][c] -> flat bytes in the hardware's [g][h][w][4] order."""
    h, w, c = a_hwc.shape
    ng = c // 4
    v = a_hwc.reshape(h, w, ng, 4).transpose(2, 0, 1, 3).reshape(-1)
    return (v & 0xFF).astype(np.uint8)


def from_mem(mem, h, w, c):
    """Flat [g][h][w][4] bytes -> signed [h][w][c]."""
    ng = c // 4
    v = signed8(mem).reshape(ng, h, w, 4).transpose(1, 2, 0, 3).reshape(h, w, c)
    return v


def pool_mem(mem, h, w, c):
    """2x2 max pool in memory order, matching net_pool2 (signed max)."""
    ng = c // 4
    a = signed8(mem).reshape(ng, h, w, 4)
    a = a.reshape(ng, h // 2, 2, w // 2, 2, 4).max(axis=(2, 4))
    return (a.reshape(-1) & 0xFF).astype(np.uint8)


def pad_group(xq, L):
    """Build the kx-shifted activation buffer [kx][g][h][w][4] (signed INT8)."""
    xq = signed8(xq) if np.asarray(xq).dtype == np.uint8 else np.asarray(xq, np.int32)
    ng, k, pad = L['c_in'] // 4, L['k'], L['pad']
    h, ww = L['h'], L['w']
    ph = h + 2 * pad
    out = np.zeros((k, ng, ph, ww, 4), dtype=np.int32)
    for kx in range(k):
        for g in range(ng):
            for r in range(ph):
                for c in range(ww):
                    sh = r - pad
                    sw = c + kx - pad
                    if 0 <= sh < h and 0 <= sw < ww:
                        out[kx, g, r, c, :] = xq[sh, sw, g * 4:g * 4 + 4]
    return out


def int_forward(img_q, packed, trace=None):
    """Integer reference mirroring the RTL exactly.

    When trace is a list, the first 16 bytes of every intermediate stage are
    appended as (label, bytes) so the firmware can bisect a mismatch.
    """
    mem = np.asarray(img_q, dtype=np.uint8)
    hh, ww, cc = H, W, C_IN
    acts = []
    for idx, L in enumerate(LAYERS):
        # The accumulator arrays are [h][w][c]; the *memory* is [g][h][w][4].
        # Mixing the two silently permutes channels, so convert at every step.
        buf = pad_group(from_mem(mem, hh, ww, cc), L)
        ng, nm, k = L['c_in'] // 4, L['c_out'] // 4, L['k']
        out = np.zeros((L['h'], L['w'], L['c_out']), dtype=np.int32)
        wt = packed[idx]['wt'].reshape(-1, 16)
        for ky in range(k):
            for kx in range(k):
                for g in range(ng):
                    row = ((g * k * k) + (ky * k) + kx) * nm
                    # A row: 4 spatial x 4 input channels
                    for t in range(L['w'] // 4):
                        A = buf[kx, g, :, t * 4:t * 4 + 4, :]     # [ph,4,4]
                        for mg in range(nm):
                            Bs = signed8(wt[row + mg].reshape(4, 4))   # [k][j]
                            for r in range(L['h']):
                                arow = A[r + ky]                   # [4 spatial][4 ch]
                                acc = (arow.astype(np.int32) @ Bs.astype(np.int32))
                                out[r, t * 4:t * 4 + 4, mg * 4:mg * 4 + 4] += acc
        # epilogue: requantise in groups of 4 output channels
        res = np.zeros_like(out)
        for mg in range(nm):
            bq = packed[idx]['bias_q'][mg * 4: mg * 4 + 4]
            mult, shift, zp, relu = packed[idx]['mult'], packed[idx]['shift'], \
                packed[idx]['zp'], packed[idx]['relu']
            v = (out[:, :, mg * 4:mg * 4 + 4].astype(np.int64) + bq[None, None, :]) \
                * np.int64(mult)
            v = v >> np.int64(shift)
            v = v + np.int64(zp)
            if relu:
                v = np.maximum(v, 0)
            res[:, :, mg * 4:mg * 4 + 4] = np.clip(v, -128, 127)
        mem = to_mem(res)
        hh, ww, cc = L['h'], L['w'], L['c_out']
        if trace is not None:
            trace.append(("L%d" % (idx + 1), mem))
        if idx < 2:
            # The pooling stages live outside net_conv in the firmware.
            mem = pool_mem(mem, hh, ww, cc)
            hh, ww = hh // 2, ww // 2
            if trace is not None:
                trace.append(("P%d" % (idx + 1), mem))
    return mem


def main():
    # detector_bp.npz comes from the backprop trainer (train_bp.py); the older
    # detector_float.npz (random features + least-squares head) is still read
    # when the trained one is absent.
    src = ROOT / "tools/model/detector_bp.npz"
    if not src.exists():
        src = ROOT / "tools/model/detector_float.npz"
    print("weights:", src.name)
    d = np.load(src)
    w1, w2, w3 = d['w1'], d['w2'], d['w3']
    wh, bh = d['wh'], d['bh']
    xte, yte = d['xte'], d['yte']
    conv_w = [w1, w2, w3]
    head_w = wh.reshape(8, 16, 1, 1)
    # Every convolution may carry a bias now that all weights are trained; the
    # old model had none, so the keys are optional.
    biases = [d['b1'] if 'b1' in d else np.zeros(8),
              d['b2'] if 'b2' in d else np.zeros(16),
              d['b3'] if 'b3' in d else np.zeros(16),
              bh]

    # --- calibration: float activations on the test batch -------------------
    mx = [0.0, 0.0, 0.0, 0.0]
    for i in range(xte.shape[0]):
        a = xte[i]
        for li in range(3):
            L = LAYERS[li]
            a = conv_float(a, conv_w[li], biases[li], L['pad'])
            if L['relu']:
                a = np.maximum(a, 0.0)
            mx[li] = max(mx[li], float(np.max(np.abs(a))))
            if li < 2:
                a = pool2(a)
        o = conv_float(a, head_w, bh, 0)
        mx[3] = max(mx[3], float(np.max(np.abs(o))))

    # Per-layer activation scales, measured on the calibration batch.  The input
    # scale must come from the data too: it used to be hardcoded for 0..1
    # images, which breaks as soon as the calibration set is in byte units.
    mx0 = max(float(np.max(np.abs(xte))), 1e-6)
    s_in = [mx0 / 127.0] + [m / 127.0 for m in mx]

    # --- quantise -----------------------------------------------------------
    packed = []
    for li, L in enumerate(LAYERS):
        w = [w1, w2, w3, head_w][li]
        b = biases[li]
        wq, s_w = quant(w)
        s_x_in, s_x_out = s_in[li], s_in[li + 1]
        ratio = s_x_in * s_w / s_x_out
        shift = 0
        while shift < SHIFT_MAX and ratio * (1 << (shift + 1)) <= MULT_MAX:
            shift += 1
        mult = int(round(ratio * (1 << shift)))
        mult = max(1, min(MULT_MAX, mult))
        bq = np.round(b / (s_x_in * s_w)).astype(np.int32)
        nmt = choose_nmt(L)
        wt, bias, cfg = to_rows(wq, L, mult, shift, bq, 0, L['relu'], nmt)
        packed.append(dict(wt=wt, bias=bias, cfg=cfg, bias_q=bq, nmt=nmt,
                           mult=mult, shift=shift, zp=0, relu=L['relu']))
        print("L%d: s_in=%.5f s_w=%.5f s_out=%.5f -> mult=%d shift=%d nmt=%d"
              % (li + 1, s_x_in, s_w, s_x_out, mult, shift, nmt))

    # --- integer golden -----------------------------------------------------
    ns = xte.shape[0]
    imgs = np.zeros((ns, H * W * C_IN), dtype=np.uint8)
    # Head output is [c_out_group][h][w][4] = 2 groups x 8 x 8 x 4.
    gold = np.zeros((ns, GRID * GRID * 8), dtype=np.uint8)
    for i in range(ns):
        img = np.round(xte[i, :, :, 0] / s_in[0]).astype(np.int32)
        img = np.clip(img, -128, 127).reshape(H, W, 1)
        flat = np.zeros((H, W, C_IN), dtype=np.int32)
        flat[:, :, 0] = img[:, :, 0]
        imgs[i] = (flat.reshape(-1) & 0xFF).astype(np.uint8)

        out = int_forward(imgs[i], packed)
        gold[i] = (out.reshape(-1) & 0xFF).astype(np.uint8)

    # --- quality of the quantised model ------------------------------------
    gy, gx = np.mgrid[0:GRID, 0:GRID]
    errs, hits = [], 0
    for i in range(ns):
        # Channel 0 lives in group 0, byte lane 0 of each 4-byte pixel.
        o = gold[i][:GRID * GRID * 4].reshape(GRID, GRID, 4)[:, :, 0] \
            .astype(np.int8).astype(np.float64)
        wt = np.maximum(o, 0.0)
        t = yte[i, :, :, 0]
        ty = (gy * t).sum() / max(t.sum(), 1e-6)
        tx = (gx * t).sum() / max(t.sum(), 1e-6)
        if wt.sum() < 1e-6:
            errs.append(99.0)
            continue
        cy = (gy * wt).sum() / wt.sum()
        cx = (gx * wt).sum() / wt.sum()
        e = np.hypot(cy - ty, cx - tx) * (H // GRID)
        errs.append(e)
        hits += int(e <= 3.0)
    e = np.array(errs)
    print("quantised INT8 model: mean centroid error %.2f px, within 3px %.1f%%"
          % (e.mean(), 100.0 * hits / ns))

    # --- emit the C header --------------------------------------------------
    def carr(name, data):
        body = ",".join(str(int(v)) for v in np.asarray(data).reshape(-1))
        return "static const unsigned char %s[%d] = {%s};\n" % \
               (name, np.asarray(data).size, body)

    out_path = ROOT / "firmware/yolo/mt_detect_weights.h"
    with open(out_path, "w") as f:
        f.write("/* Auto-generated by tools/model/pack_weights.py."
                "  DO NOT EDIT. */\n")
        f.write("#ifndef MT_DETECT_WEIGHTS_H\n#define MT_DETECT_WEIGHTS_H\n\n")
        f.write("#ifndef DET_IMG_COUNT\n")
        f.write("#define DET_IMG_COUNT %d\n" % ns)
        f.write("#endif\n\n")
        for li, p in enumerate(packed):
            f.write(carr("det_wt%d" % (li + 1), p['wt']))
            f.write(carr("det_bias%d" % (li + 1), p['bias']))
            f.write(carr("det_cfg%d" % (li + 1), p['cfg']))
            f.write("\n")
        f.write(carr("det_imgs", imgs))
        f.write("\n")
        f.write(carr("det_gold", gold))
        f.write("\n#endif\n")
    print("wrote firmware/yolo/mt_detect_weights.h")


if __name__ == "__main__":
    main()
