# 目录结构说明

> 生成于 2026-11-01，基线 `s3h`。只描述**会长期保留**的东西；
> `build/` 下的构建产物随时可删。

```
5-stage-baseline/
├── rtl/                 硬件设计（SystemVerilog，ADS 前由 pango_prep 改写）
│   ├── core/            RV32IM 五级流水线 CPU
│   ├── cache/           I-cache
│   ├── common/          ares_pkg（地址映射）、总线定义
│   ├── soc/             SoC 顶层、L2、MMIO 外设、UART/GPIO/CLINT
│   │   ├── ares_soc.sv          SoC 顶层（CPU + L2 + MMIO）
│   │   ├── ares_mmio_bus.sv     外设译码：相机窗口、OSD、stereo 窗口
│   │   └── ares_core_complex.sv CPU 侧总线与 MMIO 判定
│   ├── minitensor/      张量加速器（4×4 INT8 阵列、命令队列、DMA）
│   └── video/           视频通路（S2 厂商工程改写）
│       ├── video_fb_top.v       视频顶层（720p + 双相机 + OSD）
│       ├── video_capture_wrap.v 单相机 DVP 采集 + I2C 初始化
│       ├── cam_cap.v            32×32 缩略图（检测用）
│       ├── stereo_cap.v         320×240 灰度（测距用）
│       ├── stereo_store.v / pip_buf.v / video_pip.v   画中画
│       ├── video_osd.v + video_font.v  4 个框 + 8 个七段数字
│       └── legacy/              厂商原始模块（DDR3/Hdmi/I2C 等）
├── fpga/pango/          PDS 工程
│   ├── flow_full.tcl    完整流程（compile→synth→p&r→bitstream）
│   ├── video_top.fdc    引脚与时序约束
│   └── ip/              DDR3 等 IP
├── firmware/
│   ├── boot/            boot ROM loader
│   ├── common/          start.S、runtime.c（printf/uart）、ares_soc.h
│   └── yolo/            相机与加速器固件
│       ├── mt_cam.c         相机主程序（测距/物体/诊断，当前主线）
│       ├── stereo.c/.h      块匹配（纯函数，主机可测）
│       ├── mt.c / mt_net.c  miniTensor 驱动与卷积/池化
│       ├── mt_detect.c      离线检测器 + 基准/单元测试
│       └── mt_detect_weights.h  打包后的 INT8 权重（pack_weights 生成）
├── sim/                 Verilator 仿真
│   ├── rtl/tb_soc.sv            SoC 级测试台（跑真实固件，含 stereo 窗口模型）
│   ├── rtl/tb_pip.sv           画中画叠加
│   ├── rtl/tb_stereo_cap.sv    320×240 采集地址/裁剪
│   └── tools/bin2hex.py
├── tools/
│   ├── pango_prep.py            SV→V-2001 改写（**PDS 前必须跑**）
│   ├── build_pango.ps1          一条命令：prep → PDS → 报 sha256
│   ├── program_board.ps1        烧位流（自动找 2025/2022 的 cdt_js）
│   ├── upload.ps1               通过 boot loader 上传固件
│   ├── build_cam_board.sh       编译相机固件
│   ├── mkfont.py                七段字模生成器
│   ├── model/                   torch/numpy 训练与量化打包
│   └── stereo/                  sim_stereo.py（离线模型）、test_stereo.c（主机测试）
├── docs/
│   ├── goals.md              目标清单（G0…G7）与状态
│   ├── plan_fx.md            视觉增强 + 运动检测实施计划（当前）
│   ├── advanced_plan.md      性能/加速器/多目标的完整技术记录
│   ├── board_runbook.md      板上操作手册（烧写/上传/故障表）
│   └── stereo_plan.md        双目测距规划（历史）
└── build/                构建产物（可删）
    ├── release/         归档的位流（s3h、p3a）
    ├── fw/cam_board.bin 当前固件
    ├── pango/s3h/       当前位流工程（含 sha）
    └── uart.log         仿真串口输出
```

## 常用命令

```bash
make yolo          # SoC 仿真 + 离线检测器（golden diff 0）
make stereo-sim    # 双目窗口链路（期望 disparity 9.00 px）
make sim           # 只构建 Verilator 模型

bash tools/build_cam_board.sh          # 编译相机固件
powershell tools/build_pango.ps1 -Name x1   # 构建位流（自动 prep）
powershell tools/program_board.ps1 -Bitstream <sbit>
powershell tools/upload.ps1 -Port COM9 -File build/fw/cam_board.bin
```

## 三条铁律

1. **改 RTL 后必须 `make stereo-sim` / `make yolo` 全绿再综合**；
2. **PDS 前必须 `pango_prep.py`**（否则编译的是上次的 RTL）——用 `build_pango.ps1` 就不会漏；
3. **固件上传前必须复位**（JTAG 重烧），因为 loader 只在启动时跑一次。
