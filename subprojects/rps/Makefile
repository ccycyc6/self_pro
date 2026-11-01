# 石头剪刀布手势识别 —— 子项目入口
#
# 共享的构建脚本仍在仓库根目录的 tools/ 下；这里只负责把它们按这个项目的
# 流程串起来。所有路径都由 paths.py 给出，脚本本身不再自己算仓库根。

SHELL := /bin/bash
ROOT  := $(abspath ../..)
PY    ?= python3
PORT  ?= COM9
BIT   ?= ../../bitstreams/s3h_video_fb_top.sbit

.PHONY: help test repro build flash watch check capture dataset train pack clean

help:
	@echo "  make test        模型集成测试 + 跟踪器单测（不需要硬件）"
	@echo "  make repro       从数据集重新训练→打包→校验→编译（不需要硬件）"
	@echo "  make build       只编译固件（带 RPS_WEIGHTS）"
	@echo "  make flash       烧位流并上传固件"
	@echo "  make watch       实时打印串口输出"
	@echo "  make check       用打包后的 INT8 模型跑一遍数据集"
	@echo "  make capture     采集三个手势（每类单独一段，标签确定）"
	@echo "  make dataset     合并采集结果 -> data/dataset.npz"
	@echo "  make train       torch 训练"
	@echo "  make pack        量化打包 -> firmware/yolo/rps_weights.h"
	@echo "  make clean       删除构建中间产物"

test:
	$(PY) ml/test_model.py
	cd $(ROOT) && $(MAKE) --no-print-directory track-test

# 从随仓库保存的数据集重新训练、打包、校验、编译。capture/dataset 只在需要新数据时才跑。
repro: train pack check build
	@echo ""
	@echo "reproduced: 数据集 -> 训练 -> 打包 -> 校验 -> 固件"
	@ls -l $(ROOT)/build/fw/cam_board.bin

build:
	cd $(ROOT) && EXTRA_DEFS='-DRPS_WEIGHTS' bash tools/build_cam_board.sh

flash:
	cd $(ROOT) && powershell -ExecutionPolicy Bypass -File tools/program_board.ps1 -Bitstream $(BIT)
	cd $(ROOT) && powershell -ExecutionPolicy Bypass -File tools/upload.ps1 -Port $(PORT) -File build/fw/cam_board.bin -ListenSeconds 5

watch:
	cd $(ROOT) && powershell -ExecutionPolicy Bypass -File subprojects/rps/scripts/watch_serial.ps1 -Port $(PORT)

check:
	$(PY) ml/pack_rps.py 2>&1 | grep -E "integer accuracy|gold image labels"

capture:
	@echo "依次录制：石头 -> 布 -> 剪刀，每段单独一个文件"
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
	rm -f $(ROOT)/build/rps_*.bin $(ROOT)/build/rps_*.npz $(ROOT)/build/test_track
