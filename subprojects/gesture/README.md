# 石头剪刀布手势识别（子项目）

在盘古 200Pro+（PG2L200H）上，用一枚 OV5640 + miniTensor 四层 INT8 卷积网络
做**单手手势实时识别**。

```
cam1 (720p) ──► 取中心 640x480 ──► 2:1 降采样到 320x240 ──► 0xD010_0000
                                                              │
固件：固定取景区 13x11 格 ──► letterbox 32x32 ──► INT8 量化 ──► 加速器四层网络
                                                              │
                          每帧 argmax + 裕度门限(4) + 连续 3 帧一致
                                                              │
                                                        串口 1 Hz 输出
```

## 现在能做什么

屏幕中央偏左有一个取景框，把手掌放进去，串口每秒打印一行：

```
hand: rock     scores  11 -15   0  margin 11  shown rock
hand: paper    scores -31  26   8  margin 41  shown paper
hand: scissors scores  -2  -4   4  margin  6  shown scissors
hand: none     (window 148..164, no contrast)
```

- 框里没有对比度（没手）时**不猜**，直接报 `none`
- 换手势后 3 帧（约 0.2 秒）内更新
- 屏幕上不显示任何数字

## 指标

| 项 | 结果 |
|---|---|
| 数据集 | 石头 68 / 布 109 / 剪刀 110 = **287 帧**（每类单独录制，标签确定） |
| 3-NN 留出集（最简分类器） | **100%**（随机 33%） |
| 四层网络浮点 | 干净 100%、增强后 **92%** |
| 打包后 INT8（全部 287 帧） | **100%** |
| 板端 8 张打包图像 | **8/8 与离线一致** |
| 端到端延迟 | 约 0.2 秒（3 帧一致才更新） |

## 环境

| 需要 | 版本 | 用途 |
|---|---|---|
| Python | 3.10+ | 采集解析、训练、打包 |
| numpy / torch | 见 `requirements.txt` | `pip install -r requirements.txt` |
| WSL（Ubuntu） | 任意 | 跑 Python 与 gcc 单测 |
| riscv64-unknown-elf-gcc | 随工具链 | 编译固件 |
| PDS 2025.2 | `D:\Pango\...` | 只有重建位流才需要 |

版本号在 `VERSION`，变更在 `CHANGELOG.md`。

## 快速开始

```bash
# 1. 编译并烧写（位流已归档，通常不用重建）
powershell tools/program_board.ps1 -Bitstream bitstreams/s3h_video_fb_top.sbit
EXTRA_DEFS='-DRPS_WEIGHTS' bash tools/build_cam_board.sh
powershell tools/upload.ps1 -Port COM9 -File build/fw/cam_board.bin

# 2. 看结果
powershell subprojects/gesture/scripts/watch_serial.ps1
```

或者在本目录：

```bash
make test      # 模型集成测试 + 跟踪器单测（不需要硬件）
make repro     # 从 data/dataset.npz 重新训练→打包→校验→编译
make flash     # 烧位流 + 编译上传固件
make watch     # 实时看串口
make check     # 用打包后的 INT8 模型跑一遍数据集
```

## 自检（跑完应看到这些数字）

```
$ make test
ok: dataset has at least 200 patches (got 287)
ok: integer model classifies all patches (got 100.0%)
ok: eight packed images (got 8)
model tests: PASSED (0 failures)
track tests: PASSED (0 failures)

$ make repro
epoch 119  loss 0.2150  test 100.0%  augmented-test  92.0%
integer accuracy on all 287 captured patches: 100.0%
gold image labels: [2, 2, 2, 2, 2, 1, 1, 1]
 70772 bytes  build/fw/cam_board.bin
```

## 重新采数据 / 训练

```bash
make capture            # 提示你依次录三个手势（每类单独一段，标签确定）
make dataset            # 合并成 data/dataset.npz
make train              # torch 训练（含旋转/翻转/亮度/遮挡增强）
make pack               # 量化打包 -> firmware/yolo/rps_weights.h
make flash              # 重新烧固件
```

## 目录

| 路径 | 内容 |
|---|---|
| `paths.py` | 全部路径的唯一来源（脚本不再自己算仓库根） |
| `ml/` | 采集、聚类、可视化、训练、量化打包、模型与跟踪器测试 |
| `scripts/` | 串口监视 |
| `data/` | 数据集与训练好的模型（随仓库保存） |
| `docs/results.md` | 完整记录：踩过的五个坑、验证数字、归档产物 |

## 目录：自带全套

| 部分 | 位置 |
|---|---|
| 硬件：CPU、SoC、加速器、相机通路 | `rtl/` |
| PDS 工程与引脚约束 | `fpga/` |
| 固件全集（含生成的权重头） | `firmware/` |
| 源转换、综合、烧写、上传 | `tools/` |
| 位流与已编译固件 | `bitstreams/` |
| 模型、数据、采集脚本 | `ml/`、`data/`、`scripts/` |

**这个目录不依赖主仓库**：把它单独拷给别人，装好环境（WSL + riscv 工具链 +
PDS 2025.2 + Python 依赖）就能从零重建、烧写、跑起来。

```bash
make bitstream   # 从 rtl/ 重新综合出位流（约 12 分钟；通常直接用 bitstreams/ 里的）
make fw          # 编译固件
make flash       # 烧写 + 上传
make watch       # 看识别结果
```

> 注意：`rtl/`、`fpga/`、`firmware/` 是主仓库的**快照**，便于整套交付。
> 若两边都改，以主仓库为准；这份拷贝的目的是"能独立跑"，不是并行维护。

## 已知限制

- **单手**，一次只识别一个手势（双手与胜负判定做过但按要求移除）；
- 手必须**大致填满取景框**，太远或太偏会让分数变弱；
- **剪刀**的裕度天生只有 6 左右（该通道标准差 0.8，网络靠其他两类变低来判剪刀），
  所以门限是 4 而不是 8；
- 取景框位置写死在 `mt_cam.c` 的 `ROI_CX/ROI_CY/ROI_W/ROI_H`，改完只需重编固件。
