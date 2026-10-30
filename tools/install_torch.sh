#!/bin/bash
# Install CPU PyTorch for training, without sudo: everything goes into the user
# site (~/.local).  Ubuntu marks the system Python as externally managed (PEP
# 668), hence --break-system-packages; nothing outside ~/.local is touched.
set -e
cd /tmp
if ! python3 -m pip --version >/dev/null 2>&1; then
    echo "installing pip ..."
    curl -sS https://bootstrap.pypa.io/get-pip.py -o get-pip.py
    python3 get-pip.py --user --quiet --break-system-packages
fi
echo "installing torch (cpu) ..."
python3 -m pip install --user --quiet --break-system-packages torch \
    --index-url https://download.pytorch.org/whl/cpu
python3 -c "import torch; print('torch', torch.__version__)"
