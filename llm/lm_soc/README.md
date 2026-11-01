# CPU + miniTensor + UART —— 新项目骨架

从主仓库裁剪出来的**最小可运行硬件**，用途是**在这块板子上部署一个小型语言模型**
（或任何不需要相机的推理任务）。

## 里面有什么

| 部分 | 内容 |
|---|---|
| CPU | RV32IM 五级流水线、I-cache、CSR、MUL/DIV（`rtl/core`, `rtl/cache`） |
| SoC | L2、MMIO 总线、UART、GPIO、CLINT、BRAM/DDR 存根（`rtl/soc`） |
| 加速器 | miniTensor：4×4 INT8 阵列、命令队列、DMA、统一缓冲（`rtl/minitensor`） |
| 板级顶层 | `rtl/board/board_cpu.v`（stage b5 = CPU + miniTensor） |
| 固件 | 启动 ROM、runtime（`printf`/`uart_puts`）、加速器驱动、检测器 demo |
| 工具 | `pango_prep.py`、`build_soc.ps1`、`program_board.ps1`、`upload.ps1` |

**没有**：相机、画中画、OSD、DDR3 视频通路、HDMI——那些留在主仓库。

## 为什么是这套

部署语言模型需要三样东西，这里都齐了：

1. **算力**：miniTensor 的 INT8 阵列（矩阵-向量就是 1×1 卷积）；
2. **内存**：BRAM（32 KiB scratch）+ 可选 DDR；
3. **交互**：UART 收发 + `printf`，这是模型输出和调试的唯一通道。

## 快速开始

```bash
make fw               # 编译固件 -> build/fw/lm.bin
make bitstream-fast   # 只做 dev_map，快速确认 RTL 完整（约 2 分钟）
make bitstream        # 完整位流（约 8 分钟）
```

烧写与上传（与本仓库同样的顺序：**先位流，后固件**）：

```powershell
powershell -ExecutionPolicy Bypass -File tools/program_board.ps1 -Bitstream build/pango/soc/prj_tasks/pnr_1/generate_bitstream/board_cpu.sbit
powershell -ExecutionPolicy Bypass -File tools/upload.ps1 -Port COM9 -File build/fw/lm.bin
```

## 烧进去之后能干什么

现有固件（`firmware/app/main.c`）就是加速器自检：把打包好的测试图像跑一遍四层网络，
通过串口打印每层的耗时和结果。这是新模型的**起点模板**。

## 往语言模型推进的最小路径

1. **先量算力**：现有网络 745K MAC / 1.1M 周期 ≈ 0.7 MAC/cycle（27 MHz 下约 18 MMAC/s）。
   语言模型每 token 的 MAC 数 = 2 × 参数量。1M 参数的 GRU 约 2M MAC/token → 约 9 token/s；
   10 万参数的小模型约 100 token/s。**先按这个估，再决定模型多大**；
2. **权重要能放下**：scratch 只有 32 KiB，1M 参数（INT8 = 1 MB）放不下，需要从 BRAM/DDR
   流式加载，或者把模型压到 30K 参数以内；
3. **矩阵-向量而不是卷积**：`net_conv` 支持 1×1 卷积，正好是 GEMV，不用改 RTL；
4. **分词器放 CPU**：简单查表（词表几十个 → 几十个字节），不需要加速器；
5. **串口协议**：输入一句话 → 逐 token 输出，`runtime.c` 的 `printf` 够用。

## 目录

```
projects/lm_soc/
├── rtl/core  rtl/cache  rtl/common  rtl/soc  rtl/minitensor  rtl/board
├── fpga/pango/flow_soc.tcl      stage b2..b5 的综合流程
├── fpga/pango/board_pins.fdc    引脚约束
├── firmware/boot  firmware/common  firmware/app
├── tools/pango_prep.py  build_soc.ps1  program_board.ps1  upload.ps1
└── Makefile
```

## 注意

- 这套 RTL 与主仓库**同源但独立**：改这里不会影响主仓库，反之亦然；
- `flow_soc.tcl` 的 `root` 是本项目根目录，因此 `build/` 也在本目录下；
- 要用相机/HDMI，回主仓库；这里保持最小，综合时间才短。
