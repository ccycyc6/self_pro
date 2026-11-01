# 石头剪刀布手势识别 —— 子项目入口
#
# 共享的构建脚本仍在仓库根目录的 tools/ 下；这里只是把它们按这个项目的
# 流程串起来，避免每次都要回忆一遍命令。

SHELL := /bin/bash
ROOT  := $(abspath ../..)
PY    := python3
PORT  ?= COM9
BIT   ?= build/release/s3h_video_fb_top.sbit

.PHONY: help flash build watch check dataset train pack capture clean

help:
	@echo "make flash    烧位流并编译上传固件"
	@echo "make build    只编译固件（带 RPS_WEIGHTS）"
	@echo "make watch    实时打印串口输出"
	@echo "make check    用打包后的 INT8 模型跑一遍数据集"
	@echo "make capture  串口采集三个手势（每类单独一段）"
	@echo "make dataset  合并采集结果 -> data/dataset.npz"
	@echo "make train    torch 训练"
	@echo "make pack     量化打包 -> firmware/yolo/rps_weights.h"

build:
	cd $(ROOT) && EXTRA_DEFS='-DRPS_WEIGHTS' bash tools/build_cam_board.sh

flash:
	cd $(ROOT) && powershell -ExecutionPolicy Bypass -File tools/program_board.ps1 -Bitstream $(BIT)
	cd $(ROOT) && powershell -ExecutionPolicy Bypass -File tools/upload.ps1 -Port $(PORT) -File build/fw/cam_board.bin -ListenSeconds 5

watch:
	cd $(ROOT) && powershell -ExecutionPolicy Bypass -File subprojects/rps/scripts/watch_serial.ps1 -Port $(PORT)

check:
	$(PY) ml/pack_rps.py 2>&1 | grep -E "all 287|labels"

capture:
	@echo "依次录制：石头（10 秒）-> 布 -> 剪刀，每段单独一个文件"
	cd $(ROOT) && powershell -ExecutionPolicy Bypass -File subprojects/rps/ml/capture.ps1 -Seconds 10 -Out build/rps_rock.bin
	cd $(ROOT) && powershell -ExecutionPolicy Bypass -File subprojects/rps/ml/capture.ps1 -Seconds 10 -Out build/rps_paper.bin
	cd $(ROOT) && powershell -ExecutionPolicy Bypass -File subprojects/rps/ml/capture.ps1 -Seconds 10 -Out build/rps_scissors.bin
	$(PY) ml/parse_capture.py $(ROOT)/build/rps_rock.bin
	$(PY) ml/parse_capture.py $(ROOT)/build/rps_paper.bin
	$(PY) ml/parse_capture.py $(ROOT)/build/rps_scissors.bin

dataset:
	$(PY) ml/build_dataset.py

train:
	$(PY) ml/train_rps.py

pack:
	$(PY) ml/pack_rps.py

clean:
	rm -f $(ROOT)/build/rps_*.bin $(ROOT)/build/rps_*.npz
