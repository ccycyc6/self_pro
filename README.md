# ARES-S1: single-core RISC-V SoC with miniTensor YOLO acceleration

Simulation-only configuration: **one ARES-L RV32IM core + one miniTensor
accelerator**, built to run the packed INT8 YOLO detector.  There is no board
top, FPGA flow, bitstream, video/HDMI or multi-hart/SMP code in this tree; those
can be added later as a separate board adaptation.

## Configuration

- **Core**: ARES-L 5-stage in-order RV32IM, 2-way 8 KiB L1I, BHT + BTB branch
  prediction, M-mode CSR/traps, machine timer/software/external interrupts.
- **Data path**: uncached by design.  Every load/store is one 32-bit
  transaction; cached DDR addresses are translated to the uncached alias.  This
  keeps the CPU and the accelerator DMA on one physical view of memory.
- **Accelerator**: one miniTensor (4x4 INT8 GEMM, vector unit, epilogue) driven
  by a CV-X-IF MMIO shim and a 128-bit DMA bridge.
- **Memory**: Boot ROM trampoline, 192 KiB scratchpad, 32 MiB behavioural DDR3
  model, simple one-request memory router (no L2 cache).
- **Peripherals**: UART (console), GPIO (LED/debug), CLINT.
- **Software**: bare-metal runtime and the packed INT8 YOLO detector.

## Quick start

Prerequisites: Verilator 5+, `riscv64-unknown-elf-gcc` with the RV32IM
multilib, Python 3.  On Windows, run the same commands from WSL.

```bash
make lint     # Verilator lint
make sim      # build the Verilator simulator
make yolo     # build and run the YOLO detector (fails if the golden check fails)
make clean
```

Useful knobs:

```bash
make yolo DET_IMG_COUNT=8   # run the first 8 packed test images
make yolo VERILATOR=verilator-5.0
```

UART output is captured in `build/uart.log`.  The testbench loads the firmware
image with `+DDR=build/yolo/yolo.hex`.

## Current result

```
ARES-S1 YOLO detector / miniTensor INT8
one ARES-L RV32IM core + one miniTensor
miniTensor detector: packed INT8 weights, 1 test images.
  img 0: detection centre cell (1.7, 1.4) -> pixel (6, 6), golden diff 0 bytes
miniTensor detector: 1/1 images decoded, 17184 commands/image, ... cycles, golden diff 0 bytes
YOLO run returned 0
```

The detector executes the complete graph (3 convolutions + head) on the
accelerator and matches the integer golden **bit for bit**.  The default
single-image run is about 7.3 M model cycles at the 100 MHz simulation clock;
`make yolo DET_IMG_COUNT=8` decodes all eight packed test images with a
zero-byte golden diff (about 58 M cycles).

## Memory map

| Base | Size | Region |
|---|---:|---|
| 0x0000_0000 | 64 KiB | Boot ROM (trampoline to DDR) |
| 0x0001_0000 | 64 KiB | CLINT (mtime / mtimecmp / msip) |
| 0x1000_0000 | 192 KiB | L2 scratchpad (miniTensor windows + frames) |
| 0x4000_0000 | 1 GiB | DDR3 uncached alias |
| 0x8000_0000 | 1 GiB | DDR3 cached alias (instruction fetch) |
| 0xD000_0000 | 64 KiB | UART / GPIO |
| 0xE000_0000 | 4 KiB | miniTensor registers |

## Directory

```
rtl/common/        package + memory map
rtl/core/          ARES-L core, CSR, BPU, mul/div, regfile
rtl/cache/         L1 instruction cache + uncached data path
rtl/soc/           SoC top, core complex, memory router, CLINT, UART, GPIO
rtl/soc/mt/        CV-X-IF shim, DMA bridge, miniTensor wrapper
rtl/soc/ddr/       behavioural DDR3 model
rtl/minitensor/    miniTensor RTL
firmware/common/   startup, linker, runtime, platform header
firmware/yolo/     miniTensor driver, conv engine, packed detector
sim/rtl/           Verilator SoC testbench
sim/tools/         firmware image converter
tools/model/       NumPy training/quantisation/packing tools
```

## Detector and model tools

The deployed weights are committed as `firmware/yolo/mt_detect_weights.h`.
To regenerate them:

```bash
python3 tools/model/train_detector.py   # float model -> detector_float.npz
python3 tools/model/pack_weights.py     # quantise + pack + integer golden
```

Topology: 32x32x4 input, 3x3 conv 4->8, 2x2 max pool, 3x3 conv 8->16, 2x2 max
pool, 3x3 conv 16->16, 1x1 head 16->8 (4 box + 1 object + 1 class, padded to 8).
The detector is single-class, single-anchor and anchor-free; the firmware
decodes the head's centroid for the demo.

## Design notes

- **No data cache.**  The earlier cached data path silently returned stale
  zeros for large `.rodata` reads; the YOLO golden comparison exposed it.  A
  single uncached 32-bit path is smaller, coherent with the DMA, and fast enough
  for this simulation.  `rtl/cache/ares_dmem.sv` also translates cached DDR
  addresses to the uncached alias.
- **No L2 cache.**  The L1I cache is enough for instruction locality; data and
  accelerator traffic go straight to the scratchpad/DDR router.  This removes
  cache-coherence and eviction corner cases from the accelerator path.
- **One tensor.**  The miniTensor is attached to the single core complex via
  the local MMIO window and the CV-X-IF shim; the DMA port shares the core's
  memory router.

## Known limitations

- Simulation only: no pins, constraints, PLL/DDR PHY, HDMI or bitstream.
- No A extension (AMO/LR/SC); single hart, no PLIC/mailbox/SMP.
- Memory router handles one request at a time (blocking).
- The image source is the packed 32x32 test set in firmware; a camera/video
  front end is intentionally not included.
- The detector is a small 32x32 model, not a full tiny-YOLO graph.


## 子项目

| 项目 | 说明 |
|---|---|
| [石头剪刀布手势识别](subprojects/rps/README.md) | 单手手势实时识别：固定取景框 + 32×32 INT8 分类器，串口每秒输出结果 |
