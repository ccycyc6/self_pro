# 石头剪刀布手势识别（子项目）

在盘古 200Pro+（PG2L200H）上，用一枚 OV5640 + miniTensor 四层 INT8 卷积网络
做**单手手势实时识别**。

```
cam1 (720p) ──► 取中心 640x480 ──► 2:1 降采样到 320x240 ──► 0xD010_0000
                                                              │
固件：固定取景区 11x9 格 ──► letterbox 32x32 ──► INT8 量化 ──► 加速器四层网络
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

## 快速开始

```bash
# 1. 编译并烧写（位流已归档，通常不用重建）
powershell tools/program_board.ps1 -Bitstream build/release/s3h_video_fb_top.sbit
EXTRA_DEFS='-DRPS_WEIGHTS' bash tools/build_cam_board.sh
powershell tools/upload.ps1 -Port COM9 -File build/fw/cam_board.bin

# 2. 看结果
powershell subprojects/rps/scripts/watch_serial.ps1
```

或者在本目录：

```bash
make flash     # 烧位流 + 编译上传固件
make watch     # 实时看串口
make check     # 用打包后的 INT8 模型跑一遍数据集，应打印 100%
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
| `ml/` | 采集、聚类、可视化、训练、量化打包、跟踪器单测 |
| `scripts/` | 串口监视 |
| `data/` | 数据集与训练好的模型（随仓库保存） |
| `docs/results.md` | 完整记录：踩过的五个坑、验证数字、归档产物 |

## 依赖的共享部分（不在本目录）

| 部分 | 位置 |
|---|---|
| 固件应用与权重 | `firmware/yolo/mt_cam.c`、`rps_weights.h`、`rps_params.h` |
| 跟踪与补丁裁切 | `firmware/yolo/mt_track.c` |
| 推理（已验证的序列） | `firmware/yolo/mt_detect.c` 的 `rps_forward` |
| 加速器驱动 | `firmware/yolo/mt_net.c`、`mt.c` |
| 位流构建 / 烧写 / 上传 | `tools/build_pango.ps1`、`program_board.ps1`、`upload.ps1` |
| 相机与像素通路 | `rtl/video/` |

## 已知限制

- **单手**，一次只识别一个手势（双手与胜负判定做过但按要求移除）；
- 手必须**大致填满取景框**，太远或太偏会让分数变弱；
- **剪刀**的裕度天生只有 6 左右（该通道标准差 0.8，网络靠其他两类变低来判剪刀），
  所以门限是 4 而不是 8；
- 取景框位置写死在 `mt_cam.c` 的 `ROI_CX/ROI_CY/ROI_W/ROI_H`，改完只需重编固件。
