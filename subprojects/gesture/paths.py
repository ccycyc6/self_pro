"""Every path this project touches, in one place.

The tools used to compute the repository root themselves with
Path(__file__).parents[N], which turns into a silent bug the moment a file
moves -- and moving files is exactly what happened when this became a
sub-project.  Import from here instead.
"""
from pathlib import Path

# subprojects/gesture/paths.py -> subprojects/gesture -> subprojects -> repo root
SUB = Path(__file__).resolve().parent
ROOT = SUB.parents[1]

BUILD = ROOT / "build"
DATA = SUB / "data"
DOCS = SUB / "docs"
# This sub-project can be used two ways: nested inside the main repository, or
# handed over as a standalone tree.  When it carries its own firmware/ (the
# standalone case) the generated headers go there; otherwise they go to the
# repository's own copy.
_LOCAL_FW = SUB / "firmware" / "yolo"
FIRMWARE_YOLO = _LOCAL_FW if _LOCAL_FW.is_dir() else ROOT / "firmware" / "yolo"

DATASET = DATA / "dataset.npz"
FLOAT_WEIGHTS = DATA / "float.npz"
TORCH_MODEL = DATA / "model.pt"

WEIGHTS_H = FIRMWARE_YOLO / "rps_weights.h"
PARAMS_H = FIRMWARE_YOLO / "rps_params.h"

# the three captures the dataset is merged from, one gesture per file
CAPTURES = {name: BUILD / ("rps_" + name + ".npz") for name in ("rock", "paper", "scissors")}

CLASSES = ["rock", "paper", "scissors"]
