#!/bin/bash
# Build the camera detector for the board: 0x8000_0000, UART 115200 @27 MHz.
# Same runtime as the offline detector, but the image comes from the live
# 32x32 thumbnail window instead of the packed test images.
set -e
cd "$(dirname "$0")/.."

CC=riscv64-unknown-elf-gcc
OBJCOPY=riscv64-unknown-elf-objcopy
SIZE=riscv64-unknown-elf-size

CFLAGS="-march=rv32im_zicsr_zifencei -mabi=ilp32 -O2 -ffreestanding -fno-builtin \
 -nostdlib -nostartfiles -mno-relax -msmall-data-limit=0 \
 -Ifirmware -Ifirmware/common -Ifirmware/yolo -DUART_DIV=234 -DDET_IMG_COUNT=1"

# CAM_DEBUG=1 adds a min/max/mean line and an 8x8 ASCII view of the thumbnail.
if [ "${CAM_DEBUG:-0}" != "0" ]; then
    CFLAGS="$CFLAGS -DCAM_DEBUG"
    OUT=cam_board_dbg
else
    OUT=cam_board
fi

# EXTRA_DEFS="-DCAM_DUMP" adds experiment-only code paths.
if [ -n "${EXTRA_DEFS:-}" ]; then
    CFLAGS="$CFLAGS $EXTRA_DEFS"
fi

mkdir -p build/fw
rm -f build/fw/cam_*.o

for f in firmware/common/start.S firmware/common/runtime.c \
         firmware/yolo/mt.c firmware/yolo/mt_net.c \
         firmware/yolo/mt_detect.c firmware/yolo/mt_cam.c \
         firmware/yolo/main_cam.c; do
    $CC $CFLAGS -c "$f" -o "build/fw/cam_$(basename "$f").o"
done

$CC -march=rv32im_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles -mno-relax \
    -T firmware/common/linker.ld build/fw/cam_*.o -lgcc -o "build/fw/$OUT.elf"
$OBJCOPY -O binary "build/fw/$OUT.elf" "build/fw/$OUT.bin"
$SIZE "build/fw/$OUT.elf"
ls -l "build/fw/$OUT.bin"
