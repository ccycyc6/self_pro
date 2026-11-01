#!/bin/bash
# Build the firmware for this project: CPU + miniTensor + UART, no camera.
set -e
cd "$(dirname "$0")/.."

OUT=${OUT:-lm}
CROSS=${CROSS:-riscv64-unknown-elf-}
CC=${CROSS}gcc
OBJCOPY=${CROSS}objcopy

CFLAGS="-march=rv32im_zicsr_zifencei -mabi=ilp32 -O2 -ffreestanding -fno-builtin \
 -nostdlib -nostartfiles -mno-relax -msmall-data-limit=0 \
 -Ifirmware -Ifirmware/common -Ifirmware/app -DUART_DIV=234 -DDET_IMG_COUNT=1"

mkdir -p build/fw
rm -f build/fw/*.o
for f in firmware/common/start.S firmware/common/runtime.c \
         firmware/app/mt.c firmware/app/mt_net.c \
         firmware/app/mt_detect.c firmware/app/main.c; do
    $CC $CFLAGS -c "$f" -o "build/fw/$(basename "$f").o"
done
$CC -march=rv32im_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles -mno-relax \
    -T firmware/common/linker.ld build/fw/*.o -lgcc -o "build/fw/$OUT.elf"
$OBJCOPY -O binary "build/fw/$OUT.elf" "build/fw/$OUT.bin"
ls -l "build/fw/$OUT.bin"
