#!/bin/bash
# Build the YOLO detector for the board: 0x8000_0000, UART 115200 @27 MHz.
# The image is uploaded through the B4 loader, not baked into the bitstream.
set -e
cd "$(dirname "$0")/.."

CC=riscv64-unknown-elf-gcc
OBJCOPY=riscv64-unknown-elf-objcopy
SIZE=riscv64-unknown-elf-size

CFLAGS="-march=rv32im_zicsr_zifencei -mabi=ilp32 -O2 -ffreestanding -fno-builtin  -nostdlib -nostartfiles -mno-relax -msmall-data-limit=0  -Ifirmware -Ifirmware/common -Ifirmware/yolo -DUART_DIV=234 -DDET_IMG_COUNT=1"

mkdir -p build/fw
rm -f build/fw/yolo_*.o

for f in firmware/common/start.S firmware/common/runtime.c \
         firmware/yolo/mt.c firmware/yolo/mt_net.c \
         firmware/yolo/mt_detect.c firmware/yolo/main.c; do
    $CC $CFLAGS -c "$f" -o "build/fw/yolo_$(basename "$f").o"
done

$CC -march=rv32im_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles -mno-relax \
    -T firmware/common/linker.ld build/fw/yolo_*.o -lgcc -o build/fw/yolo_board.elf
$OBJCOPY -O binary build/fw/yolo_board.elf build/fw/yolo_board.bin
$SIZE build/fw/yolo_board.elf
ls -l build/fw/yolo_board.bin
