"""Every path this project touches, in one place.

The tools used to compute the repository root themselves with
Path(__file__).parents[N], which turns into a silent bug the moment a file
moves -- and moving files is exactly what happened when this became a
sub-project.  Import from here instead.
"""
from pathlib import Path

# subprojects/rps/paths.py -> subprojects/rps -> subprojects -> repo root
SUB = Path(__file__).resolve().parent
ROOT = SUB.parents[1]

BUILD = ROOT / "build"
DATA = SUB / "data"
DOCS = SUB / "docs"
FIRMWARE_YOLO = ROOT / "firmware" / "yolo"

DATASET = DATA / "dataset.npz"
FLOAT_WEIGHTS = DATA / "float.npz"
TORCH_MODEL = DATA / "model.pt"

WEIGHTS_H = FIRMWARE_YOLO / "rps_weights.h"
PARAMS_H = FIRMWARE_YOLO / "rps_params.h"

# the three captures the dataset is merged from, one gesture per file
CAPTURES = {name: BUILD / ("rps_" + name + ".npz") for name in ("rock", "paper", "scissors")}

CLASSES = ["rock", "paper", "scissors"]
