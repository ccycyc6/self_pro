# 石头剪刀布手势识别 —— 自包含工程
#
# 这个目录里带着跑起来所需要的一切：rtl/、fpga/、firmware/、tools/、位流。
# 不需要主仓库的任何东西（它只是恰好住在主仓库的 subprojects/ 下）。
SHELL := /bin/bash
HERE  := $(CURDIR)
PY    ?= python3
PORT  ?= COM9
BIT   ?= bitstreams/s3h_video_fb_top.sbit
FW    ?= build/fw/cam_board.bin

.PHONY: help test repro fw bitstream flash watch check capture dataset train pack clean

help:
	@echo "  make test        模型集成测试 + 跟踪器单测（不需要硬件）"
	@echo "  make repro       数据集->训练->打包->校验->编译（不需要硬件）"
	@echo "  make fw          编译固件 -> $(FW)"
	@echo "  make bitstream   从头综合位流（约 12 分钟，通常不需要）"
	@echo "  make flash       烧位流 + 上传固件"
	@echo "  make watch       实时打印串口输出"
	@echo "  make check       用打包后的 INT8 模型跑一遍数据集"
	@echo "  make capture     采集三个手势（每类单独一段）"
	@echo "  make dataset     合并采集 -> data/dataset.npz"
	@echo "  make train       torch 训练"
	@echo "  make pack        量化打包 -> firmware/yolo/rps_weights.h"

test:
	$(PY) ml/test_model.py
	mkdir -p build
	gcc -O2 -I firmware/common -I firmware/yolo ml/test_track.c firmware/yolo/mt_track.c -o build/test_track
	./build/test_track

repro: train pack check fw
	@echo ""
	@echo "reproduced: dataset -> train -> pack -> check -> firmware"
	@ls -l $(FW)

fw:
	EXTRA_DEFS='-DRPS_WEIGHTS' bash tools/build_cam_board.sh

bitstream:
	powershell -ExecutionPolicy Bypass -File tools/build_pango.ps1 -Name rps

flash:
	powershell -ExecutionPolicy Bypass -File tools/program_board.ps1 -Bitstream $(BIT)
	powershell -ExecutionPolicy Bypass -File tools/upload.ps1 -Port $(PORT) -File $(FW) -ListenSeconds 5

watch:
	powershell -ExecutionPolicy Bypass -File scripts/watch_serial.ps1 -Port $(PORT)

check:
	$(PY) ml/pack_rps.py 2>&1 | grep -E "integer accuracy|gold image labels"

capture:
	@echo "依次录制：石头 -> 布 -> 剪刀，每段单独一个文件"
	powershell -ExecutionPolicy Bypass -File ml/capture.ps1 -Seconds 10 -Out build/rps_rock.bin
	powershell -ExecutionPolicy Bypass -File ml/capture.ps1 -Seconds 10 -Out build/rps_paper.bin
	powershell -ExecutionPolicy Bypass -File ml/capture.ps1 -Seconds 10 -Out build/rps_scissors.bin
	$(PY) ml/parse_capture.py build/rps_rock.bin
	$(PY) ml/parse_capture.py build/rps_paper.bin
	$(PY) ml/parse_capture.py build/rps_scissors.bin

dataset:
	$(PY) ml/build_dataset.py

train:
	$(PY) ml/train_rps.py

pack:
	$(PY) ml/pack_rps.py

clean:
	rm -rf build
