# 目录结构

> 2026-11-01。仓库只保留**硬件平台 + YOLO 加速器栈**，历史方案归档在 `docs/archive/`。

```
5-stage-baseline/
├── rtl/                        硬件（SystemVerilog）
│   ├── core/  cache/               RV32IM 五级流水线 + I-cache
│   ├── common/                     ares_pkg：地址映射
│   ├── soc/                        SoC 顶层、MMIO 外设、UART/GPIO/CLINT
│   ├── minitensor/                 INT8 张量加速器（4x4 阵列、命令队列、DMA）
│   └── video/                      相机采集、画中画、OSD、DDR3 通路
├── fpga/pango/                 PDS 工程：flow_full.tcl、引脚约束、DDR3 IP
├── firmware/                   固件
│   ├── boot/  common/              启动 ROM、runtime、链接脚本
│   ├── tests/                      冒烟测试
│   └── yolo/                       ★ 相机 + 加速器
│       ├── mt.c  mt.h              驱动入口、命令封装
│       ├── mt_net.c  mt_net.h      net_pad / net_conv / net_pool2
│       ├── mt_detect.c  .h         推理序列（含 rps_forward）+ golden 自检
│       ├── mt_detect_weights.h     检测器权重（打包产物）
│       ├── mt_track.c  .h          运动检测与跟踪
│       ├── stereo.c  .h            块匹配（双目/时间域）
│       ├── mt_cam.c                相机应用主程序
│       ├── main.c                  仿真用入口（make yolo）
│       ├── main_cam.c              上板入口
│       ├── main_stereo_sim.c       双目链路仿真入口
│       └── rps_weights.h  rps_params.h   手势模型（由子项目生成）
├── sim/rtl/                    Verilator 测试台（SoC、画中画、采集）
├── tools/                      构建与模型工具
│   ├── pango_prep.py               SV→V 改写（PDS 前必须跑）
│   ├── build_pango.ps1             一条命令：prep → PDS → sha256
│   ├── program_board.ps1           烧位流
│   ├── upload.ps1                  上传固件
│   ├── build_cam_board.sh          编译相机固件
│   ├── build_yolo_board.sh         编译检测器固件
│   ├── board_test.ps1              烧写 + 上传 + 抓串口 一条龙
│   ├── install_torch.sh            无 sudo 安装 CPU 版 PyTorch
│   ├── mkfont.py  mkrom.py         字模、启动 ROM
│   └── model/                      YOLO/检测器训练与量化打包（可复用于新目标）
├── bitstreams/                 位流归档（烧写用，见其 README）
├── yolo_gesture/            石头剪刀布手势识别（示例工程）
├── docs/
│   ├── tree.md                     本文件
│   ├── board_runbook.md            板上操作手册与故障表
│   ├── advanced_plan.md            性能/加速器技术记录
│   ├── goals.md                    目标演进
│   └── archive/                    已归档方案（双目测距、画质增强、跟踪规划等）
└── build/                      构建产物（自动生成，可随时删）
```

## 用这套东西做新目标

1. **网络**在第 4 层以内、输入 32×32×4、INT8 时，`tools/model/` 里的训练与
   `pack_weights.py` 可以直接复用（`yolo_gesture/ml/pack_rps.py` 是分类头的范例）；
2. **固件**改 `firmware/yolo/mt_cam.c`：取图 → 组输入 → `rps_forward` 式的推理 → 输出；
3. 只要不动 `rtl/`，**不需要重建位流**（12 分钟省下来）；
4. 动了 `rtl/` 就按 `docs/board_runbook.md` 走：`make stereo-sim`/`make yolo` 先过，
   再 `tools/build_pango.ps1`。

## 常用命令

```bash
make yolo          # SoC 仿真 + 检测器（golden diff 0）
make stereo-sim    # 双目窗口链路
make track-test    # 跟踪器单测（5 项）
make sim           # 只构建 Verilator 模型

bash tools/build_cam_board.sh                              # 相机固件
EXTRA_DEFS='-DRPS_WEIGHTS' bash tools/build_cam_board.sh    # 带手势模型
bash tools/build_yolo_board.sh                             # 检测器固件

powershell tools/build_pango.ps1 -Name x1                  # 重建位流
powershell tools/program_board.ps1 -Bitstream bitstreams\s3h_video_fb_top.sbit
powershell tools/upload.ps1 -Port COM9 -File build/fw/cam_board.bin
```

## 三条铁律

1. 改 RTL 后先跑仿真，再综合；
2. PDS 前必须跑 `pango_prep.py`（用 `build_pango.ps1` 就不会漏）；
3. 上传固件前必须复位（loader 只在启动时跑一次）。
