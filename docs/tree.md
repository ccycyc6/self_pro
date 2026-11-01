# 目录结构

> 2026-11-01。`build/` 里的东西随时可删；其余都是长期资产。

```
5-stage-baseline/
├── rtl/                      硬件（SystemVerilog，PDS 前由 pango_prep 改写）
│   ├── core/  cache/  common/     CPU、缓存、地址映射
│   ├── soc/                      SoC 顶层、MMIO 外设、UART/GPIO/CLINT
│   ├── minitensor/               INT8 张量加速器
│   └── video/                    相机与像素通路（采集、画中画、OSD）
├── fpga/pango/               PDS 工程：flow_full.tcl、引脚约束、DDR3 IP
├── firmware/
│   ├── boot/  common/            启动 ROM、runtime、链接脚本
│   ├── tests/                    冒烟测试
│   └── yolo/                     相机应用与加速器驱动（共享）
│       ├── mt_cam.c              主程序：取景、分类、串口输出
│       ├── mt_track.c            运动检测与跟踪
│       ├── mt_detect.c           推理序列（含 rps_forward，已用 golden 验证）
│       ├── mt_net.c  mt.c        加速器驱动
│       └── rps_weights.h  rps_params.h   由子项目打包生成（勿手改）
├── sim/rtl/                  Verilator 测试台（SoC、画中画、采集）
├── tools/                    共享工具
│   ├── pango_prep.py             SV→V 改写（PDS 前必须跑）
│   ├── build_pango.ps1           一条命令：prep → PDS → sha256
│   ├── program_board.ps1         烧位流
│   ├── upload.ps1                上传固件
│   ├── build_cam_board.sh        编译固件
│   ├── mkfont.py  mkrom.py       字模、启动 ROM
│   └── model/                    检测器权重打包与训练（历史）
├── subprojects/
│   └── rps/                  ★ 石头剪刀布手势识别（独立子项目）
│       ├── README.md             目标、指标、快速开始、已知限制
│       ├── Makefile              flash / watch / check / capture / train / pack
│       ├── ml/                   采集、聚类、可视化、训练、打包、跟踪器单测
│       ├── scripts/watch_serial.ps1
│       ├── data/                 数据集与训练好的模型（随仓库保存）
│       └── docs/results.md       完整记录：踩过的坑、验证数字、归档产物
├── docs/                     平台文档
│   ├── goals.md                  目标演进
│   ├── tree.md                   本文件
│   ├── board_runbook.md          板上操作手册
│   ├── advanced_plan.md          性能/加速器技术记录
│   ├── plan_fx.md                画质增强方案（未实施）
│   ├── plan_track.md             跟踪方案（已并入 rps）
│   ├── stereo_plan.md            双目测距（已弃用）
│   ├── bringup_log.md            早期 bring-up 记录
│   ├── board_yolo_camera_plan.md
│   └── camera_hw_checklist.md
└── build/                    产物（可删）
    ├── release/              归档位流：s3h（当前）、p3a（单相机）
    ├── fw/cam_board.bin      当前固件
    ├── pango/s3h/ p3a/       构建树
    └── logs/                 工具日志
```

## 常用命令

```bash
make yolo                     # SoC 仿真 + 检测器（golden diff 0）
make stereo-sim               # 双目窗口链路
make track-test               # 跟踪器单测（5 项）

bash tools/build_cam_board.sh                         # 普通固件
EXTRA_DEFS='-DRPS_WEIGHTS' bash tools/build_cam_board.sh   # 手势识别固件

powershell tools/build_pango.ps1 -Name x1             # 位流（自动 prep）
powershell tools/program_board.ps1 -Bitstream <sbit>
powershell tools/upload.ps1 -Port COM9 -File build/fw/cam_board.bin
```

手势识别相关的一切都在 `subprojects/rps/`，从那里的 README 开始看。

## 三条铁律

1. 改 RTL 后先跑 `make stereo-sim` / `make yolo`，再综合；
2. PDS 前必须跑 `pango_prep.py`（用 `build_pango.ps1` 就不会漏）；
3. 上传固件前必须复位（loader 只在启动时跑一次）。
