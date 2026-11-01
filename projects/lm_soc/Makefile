# CPU + miniTensor + UART —— 独立项目骨架
#
# 与主仓库的区别：这里没有相机、没有画中画、没有 OSD、没有 DDR3 视频通路，
# 只有 CPU、miniTensor、UART、GPIO、CLINT 和一块 BRAM。
SHELL := /bin/bash
PY    ?= python3
PORT  ?= COM9

ARCH    := -march=rv32im_zicsr_zifencei -mabi=ilp32
CFLAGS  := $(ARCH) -O2 -ffreestanding -fno-builtin -nostdlib -nostartfiles \
           -mno-relax -msmall-data-limit=0 \
           -Ifirmware -Ifirmware/common -Ifirmware/app -DUART_DIV=234 -DDET_IMG_COUNT=1
LDFLAGS := $(ARCH) -nostdlib -nostartfiles -mno-relax -T firmware/common/linker.ld

APP_SRC := firmware/common/start.S firmware/common/runtime.c \
           firmware/app/mt.c firmware/app/mt_net.c firmware/app/mt_detect.c \
           firmware/app/main.c

.PHONY: help fw check-sim bitstream bitstream-fast clean

help:
	@echo "  make fw              编译固件 -> build/fw/lm.bin"
	@echo "  make bitstream       综合+P&R+位流（stage b5 = CPU + miniTensor，约 8 分钟）"
	@echo "  make bitstream-fast  只做到 dev_map（快速检查 RTL 是否完整，约 2 分钟）"
	@echo "  make clean           删除本项目的构建目录"

fw:
	mkdir -p build/fw
	rm -f build/fw/*.o
	for f in $(APP_SRC); do \
	  $(CC) $(CFLAGS) -c $$f -o build/fw/$$(basename $$f).o; \
	done
	$(CC) $(LDFLAGS) build/fw/*.o -lgcc -o build/fw/lm.elf
	$(OBJCOPY) -O binary build/fw/lm.elf build/fw/lm.bin
	ls -l build/fw/lm.bin

bitstream:
	powershell -ExecutionPolicy Bypass -File tools/build_soc.ps1 -Stage b5

bitstream-fast:
	powershell -ExecutionPolicy Bypass -File tools/build_soc.ps1 -Stage b5 -NoPnr

clean:
	rm -rf build
