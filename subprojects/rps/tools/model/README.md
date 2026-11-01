# YOLO model tools

The simulation runs the packed INT8 detector that is committed as
`firmware/yolo/mt_detect_weights.h`.  These scripts regenerate it.

```bash
python3 tools/model/train_detector.py   # writes tools/model/detector_float.npz
python3 tools/model/pack_weights.py     # writes firmware/yolo/mt_detect_weights.h
```

Both scripts only need NumPy.  `pack_weights.py` quantises the float model,
packs the weights/bias/config rows into the layout consumed by
`firmware/yolo/mt_net.c`, and computes the integer golden used by the
detector's bit-exact check.

Topology: 32x32x4 input, 3x3 conv 4->8, 2x2 pool, 3x3 conv 8->16, 2x2 pool,
3x3 conv 16->16, 1x1 head 16->8 (4 box + 1 object + 1 class, padded to 8).
