# 盘古 200Pro+ 摄像头 YOLO 上板方案（v2 · SoC 侧从零重建）

> 目标板：盘古 200Pro+ / `PG2L200H-6IFBB676`，PDS 2022.2-SP6.4（只能 `synthesize -ads`）
> 视频底座：ARES 里"修改引脚后"的 S2 demo（摄像头 → DDR3 → HDMI，已上板）
> 本版相对 v1 的修正：**不再假设任何历史板级流程可用**；SoC 从未在板上跑起来，本文把它当"未解决故障"处理。

---

## 0. 前提与边界

| 事项 | 状态 | 本方案的处置 |
|---|---|---|
| 摄像头 / DDR3 / HDMI | **已解决**（ARES 修改引脚后的 S2 demo） | 原样搬，一行不改，不再投入时间 |
| SoC 在板上跑起来 | **未解决，原因未知** | 本文的全部重点：逐级点亮 + 故障树 |
| 历史板级流程（9086853） | 不可用 | 不引用其代码；只借用"ADS 改写规则"这类知识 |
| ADS 能否吃下这套 SV | **未知** | 用 B2 做最小可证伪实验，而不是等整个 SoC 上板时才发现 |

**核心原则**：每个位流只回答一个问题；每个问题的答案必须是"肉眼可见/串口可见"的；答不出来就停在那一步，不往下走。

---

## 1. 目标成品

一块位流：**720p 实时画面 + 检测框 + 串口日志 + 按键/LED**。

| 项 | 规格 |
|---|---|
| 显示 | HDMI 720p30，摄像头实时 + 绿色检测框（20×20 像素网格） |
| 智能 | 32×32×1 INT8 检测器（v1）→ 64×64×3（v2），miniTensor 执行，CPU 调度 |
| 交互 | 串口 115200：每帧结果 + 耗时；按键：直通/检测/冻结 |
| 性能 | 检测 3–4 次/秒 @27 MHz（推理 7.3M cycles） |
| 资源 | DRM < 300/415，LUT < 40%，WNS > 0 |

**不做**：完整 tiny-yolov3、张量直连 DDR3、多核、RTOS、30 fps。

---

## 2. 引脚事实表（只写有依据的）

| 信号 | 引脚 | 依据 | 验证状态 |
|---|---|---|---|
| `clk_27m` | D18 | 200Pro 硬件手册；S2 `video_top.fdc` | ✅ 已验证（S2 PLL 锁定 P=1） |
| `ref_clk` 125 MHz | N3/N2 | 官方 2_9 FDC | ✅ 已验证（DDR3 D=1） |
| `uart_tx` | C24 | 2_8_uart_test.fdc；S2 | ✅ 已验证（S2 状态行） |
| `uart_rx` | B24 | 2_8_uart_test.fdc | ⚠️ 未单独验证 |
| `rst_n` | C22 | 硬件手册 | ⚠️ 未单独验证 |
| `led[7:0]` | B17/C17/A18/A17/… | `video_top.fdc`（源自 100H demo） | ❌ **未验证** |
| 摄像头/HDMI/DDR3 | 见 `video_top.fdc` / `official_ddr3.fdc` | ARES 修改后引脚 | ✅ 已验证 |

**结论**：B1 的判据**以串口为准**，LED 只作辅助——因为 LED 引脚从没被单独确认过。

---

## 3. "下载后没反应"的故障树

```
DONE 灯不亮
└─ 配置失败 → 电源 / JTAG / SCBV / 位流与器件不匹配

DONE 亮，但什么都看不到
├─【B0】烧厂商 4_1_led_test.sbit → 也不闪
│         ⇒ 板子 / 线 / 电源 / 下载器（与我们的设计无关）
└─【B0】厂商位流正常，我们的 B1 不亮
          ⇒ 我们的：时钟 BUFG / 引脚约束 / 顶层 / 复位

B1 亮了，但串口无输出
├─【B0】厂商 2_8_uart_test.sbit 能打印 ⇒ 我们的 UART 分频/极性/引脚
└─ 厂商也不能 ⇒ USB-UART 驱动 / 线序 / 波特率 / COM 口

B1 全过，B2（CPU）不打印
└─ ⇒ 复位向量 / ROM 内容 / 源码风格不被 ADS 接受 / CPU 卡在取指

B2 过，B3（BRAM）失败
└─ ⇒ BRAM 推断失败 或 L2 地址路由错

B3 过，B4（loader）失败
└─ ⇒ 串口协议 / `fence.i` / 跳转 / 栈
```

**每一行都对应一次"只改一个变量"的复测**，不允许跳步猜。

---

## 4. 架构（目标形态）

```
 OV5640 ─DVP─► video_capture_wrap ─┬─► fram_buf ─► DDR3 IP ─► fram_buf ─► video_hdmi_wrap ─► MS7210 ─► HDMI
   (42 MHz)                        │   (1000 Mbps, S2 原样)              ▲
                                   │                                     │ OSD 叠框（pix 域）
                                   └─► cam_cap (640×640 → 32×32)         │
                                         │ 双时钟 BRAM 2×4 KiB           │
                                         ▼                               │
                        MMIO 0xD000_2000 ─► SoC @27 MHz ────────────────┘
                                            CPU + L1I + miniTensor
                                            BRAM: 64K 固件 + 48K scratch + 4K UB
                                            UART 115200 ◄── 串口加载器
```

| 域 | 频率 | 覆盖 | 复位 |
|---|---|---|---|
| `clk_sys` | 27 MHz（`GTP_CLKBUFG` 后） | SoC、UART、LED、MMIO | POR + 按键同步 |
| `pixel_clk` | 42 MHz | DVP、framebuf 写、cam_cap 写 | S2 原有 |
| `clk_pix` | 37.125 MHz | framebuf 读、HDMI、OSD | S2 原有 |
| `ddr_core_clk` | IP 输出 | DDR3 | `ddr_init_done` |

跨域只有三处：cam_cap 双时钟 BRAM、帧计数 toggle+2FF、OSD 坐标邮箱 +2FF。

地址映射只在现状上加两个窗口：`0xD000_2000`（摄像头帧）、`0xD000_3000`（OSD 邮箱）。

---

## 5. 逐级点亮 B0–B8

```
B0 厂商基线 ─► B1 我们的最小位流 ─► B2 CPU+ROM ─► B3 BRAM ─► B4 loader
  (0.5h)          (0.5d)                (1d)          (0.5d)      (0.5d)
                                                              ─► B5 张量 ─► B6 并入视频 ─► B7 摄像头+框 ─► B8 模型
                                                                  (2–4d)      (3–5d)          (3–5d)        (5–10d)
```

### B0 — 先用厂商位流把板子钉死（0.5 小时）

**为什么先做**：在所有自研代码之前，先证明"板子 + 下载器 + 串口 + 位流格式"是好的。这一步失败，后面全是白做。

**动作**
1. 烧厂商 LED demo：
   `F:\BaiduNetdiskDownload\200pro\2_Demo\4_1_led_test\4_1_led_test\5_1_led_test\generate_bitstream\led_test.sbit`
2. 再烧厂商 UART demo：
   `F:\BaiduNetdiskDownload\200pro\2_Demo\2_8_uart_test\2_8_uart_test\generate_bitstream\uart_top.sbit`

**判据**
- LED demo：LED 有变化；DONE 灯亮；
- UART demo：串口有输出。

**失败动作**：检查电源、JTAG 链、SCBV、COM 口/线序；**在 B0 通过之前不写一行 RTL**。

**提交**：无代码，只在 `docs/bringup_log.md` 记结果。

---

### B1 — 我们的流程能出"活着的位流"（0.5 天）

**目的**：证明"我们的 PDS 流程 + 我们的约束 + 我们的顶层"能产生一个真正在跑的位流。**不含 CPU、不含 BRAM、不含 DDR3、不含 `$readmemh`。**

**改动**
- `rtl/board/board_smoke.v`：
  - `clk_27m` 直接用（与厂商 4_1_led_test 一致；PDS 会自动插全局时钟缓冲，place 日志里能看到 `clkbufg_0/gopclkbufg`。只有日志里没插时才手工 `GTP_CLKBUFG`）；
  - **LED 用无复位计数器**（`always @(posedge clk) cnt <= cnt + 1; assign led[0] = cnt[22];`）——这样 LED 闪 = 时钟活着，与复位无关；
  - 复位只作用于 UART；UART 每 0.5 s 发一行 `ARES-S1 smoke OK`；
  - `led[1]` = 复位已释放。
- `fpga/pango/flow_smoke.tcl`、`board_pins.fdc`。

**判据**
- 串口每 0.5 s 一行 `ARES-S1 smoke OK`（主判据）；
- `led[0]` 闪（辅助，用于反证"时钟是否进 fabric"）。

**关键设计**：LED 那条路**不经过复位**。如果串口没输出但 LED 在闪，说明"时钟活着、复位或 UART 有问题"；如果两个都没有，说明"时钟没进 fabric 或位流没配置"。这条区分是 B1 的全部价值。

**失败动作**
- 都不动 → 时钟/BUFG/SCBV；与 B0 对比；
- LED 闪、串口无 → UART 分频（27 MHz/115200=234）、TX 引脚、极性；
- 串口有、LED 不 → LED 引脚（`video_top.fdc` 那组没验证过），换引脚或放弃 LED 作为判据。

**提交**：`board(b1): minimal smoke bitstream — clock/UART alive`

---

### B2 — CPU 最小系统（1 天，**最关键的一关**）

**目的**：只回答一个问题——**ADS 综合出来的 CPU 能不能在板上取指、执行、写 UART**。

**关键设计：不碰 BRAM、不碰栈、不碰链接脚本。**

- 程序是一段**纯汇编、只用寄存器、不用栈**的循环，直接放在 ROM（`0x0000_0000`），复位向量就指向它；
- ROM 用 `tools/mkrom.py` 生成 `case` 常量（**不用 `$readmemh`**），≤ 2 KiB；
- 程序内容：反复往 UART 写 `"B2 OK\r\n"`，中间夹一段算术自检（乘除、分支、CSR `mcycle`）。
- SoC 参数：`ROM_WORDS` 小、`SCRATCH_WORDS` 最小、张量 `ARES_NO_MT`、无视频。

**判据**：串口出现 `B2 OK` 和 `mcycle` 递增。

**失败动作**
- 完全无输出 → 先回 B1（确认流程活着），再查复位向量、L1I 取指、ROM 内容；
- 输出乱码 → UART 分频/极性；
- 输出一两行后停 → CPU 卡在某个指令（用 PDS 在线调试器看 PC，或缩小程序二分）。

**为什么这一关最值钱**：它把"CPU 能不能跑"和"BRAM/loader/链接脚本"彻底解耦。之前"没反应"如果是 BRAM 初值问题，B2 会正常打印，故障立刻定位。

**提交**：`board(b2): CPU executes from on-chip ROM, UART prints`

---

### B3 — BRAM 通路（0.5 天）

**目的**：证明 `0x8000_0000` 的 BRAM 能写能读，且 L2 路由正确。

**改动**：在 B2 的程序里加一段：写 `0x8000_0000` 起 4 KiB 图案 → 读回比较 → 打印 `BRAM PASS/FAIL + 首错地址`。

**判据**：`BRAM PASS (4096 bytes)`。

**失败动作**：全 FAIL → 检查 BRAM 写使能/字节选通/地址位宽；部分错 → 地址别名（ADS 拆分宽存储器时的位宽问题）。

**提交**：`board(b3): BRAM write/read self-test passes`

---

### B4 — 串口 loader（0.5 天）

**目的**：从此固件不烧进位流，改一行 10 秒重灌。

**改动**
- `firmware/boot/loader.S`：sp → 收 magic `ARS1` → 长度 → 数据写 `0x8000_0000` → 校验和 → `fence.i` → `jalr`；
- `tools/upload.py`；`firmware/tests/hello.c`（带 `printf` 和 `mcycle`）。

**判据**：上电 `loader v1` → 下载 → `hello from RV32IM, mcycle=…`；复位可重复。

**提交**：`board(b4): UART boot loader, firmware no longer baked into bitstream`

---

### B5 — 张量上板（2–4 天）

**改动**
- 仿真里先把 `core_v_xif` 拍平成 packed struct 端口包（`mini_tensor_top` / `mt_cvxif_shim` / `mt_cluster` 三处），**单独提交**，`make yolo` golden 仍为 0；
- `pango_prep.py` 纳入 `rtl/minitensor/`；
- 固件：`mt_gemm` 自检 → 完整 `yolo`（内置测试图，不接摄像头）。

**判据**：`miniTensor self-check OK`；`golden diff 0 bytes`；cycles 与仿真差 <20%。

**提交**：`board(b5): miniTensor on FPGA, golden diff 0 bytes`

---

### B6 — 并入视频（3–5 天）

**改动**：搬 ARES 的 `rtl/video/**`（含 `legacy/`）、`ip/ddr3/ddr3_test`、`official_ddr3.fdc`、`video_top.fdc`；`ares_s1_board.sv` 加 `BOARD_VIDEO`；UART 归 SoC；S2 状态映射到 LED。

**判据**：HDMI 出图；`D=1`；SoC 仍打印；DRM ≤ 350；WNS > 0。

**提交**：`board(b6): integrate S2 video + SoC in one bitstream`

---

### B7 — 摄像头进 SoC + OSD（3–5 天，成品）

**改动**：`cam_cap.v`、`video_osd.v`、MMIO 两个窗口、固件 `det_grab_camera()`。

**判据**：画面出框并跟随；串口 `cam frame=142 box=(…) t=268ms`；连续 10 分钟不死。

**提交**：`board(b7): camera tap + OSD box, end-to-end detector`

---

### B8 — 模型升级 / 提频（可选）

64×64×3 三类模型，或 SoC 提到 54 MHz。先模型后提频，不要一起改。

---

## 6. 工作流规范

### 6.1 分支、提交、标签

- `main` 只放已验证状态；工作分支 `board/bringup`，每天开工前 `git rebase main`。
- **一关一个 gate commit**，squash 后打 tag：`board-b0` … `board-b7`。
- 阶段内 WIP commit 必须能编译；**不允许把"没跑过 V 的 RTL"提交到 main**。

### 6.2 提交信息模板（四段缺一不可）

```
board(b2): CPU executes from on-chip ROM, UART prints

改动:
  - rtl/board/board_smoke.v: 增加 CPU+ROM 分支
  - rtl/board/boot_rom.v: mkrom 生成（16 words + 自检循环）
  - firmware/tests/rom_hello.S: 纯汇编，无栈

验证:
  - pds: compile/synthesize/dev_map 0 error；DRM 12/415；WNS +9.1 ns
  - board: UART "B2 OK" x N，mcycle 递增
  - 位流 sha256: 8c1e...

回滚:
  - 回 board-b1
```

### 6.3 每关 DoD

1. 有 RTL 改动时：`make lint` / `make yolo` 通过（golden 0 字节）；
2. PDS：`compile / synthesize -ads / dev_map` 0 error，资源在预算内；
3. 板上判据**原文**进 `docs/bringup_log.md` + commit；
4. 位流 sha256、资源、时序记录；
5. 打 tag，更新 `docs/bringup_log.md` 的进度表。

### 6.4 构建纪律

- 迭代只跑 `compile + synthesize + dev_map`（6–10 分钟）；**只有过闸门才跑 `pnr`**（1–3 小时）。
- 一次只改一个变量：新 RTL / 新约束 / 新时钟不同时上。
- 每个 gate 的位流留一份在 `artifacts/bN/`（不入库），随时能退回上一关。

---

## 7. 构建与产物

```powershell
# 固件
powershell -ExecutionPolicy Bypass -File tools\build_fw.ps1 -Target yolo -UartDiv 234
# SV → ADS 子集
python tools\pango_prep.py
# 三种 top
D:\PDS_2022.2-SP6.4\bin\pds_shell.exe -file fpga\pango\flow_smoke.tcl -project_name smoke
D:\PDS_2022.2-SP6.4\bin\pds_shell.exe -file fpga\pango\flow_soc.tcl   -project_name ares_s1
D:\PDS_2022.2-SP6.4\bin\pds_shell.exe -file fpga\pango\flow_full.tcl  -project_name ares_s1
# 下载
D:\PDS_2022.2-SP6.4\bin\cdt_js.exe -port 65420
D:\PDS_2022.2-SP6.4\bin\cdt_cfg.exe -file fpga\pango\program.tcl -args {<sbit>}
# 灌固件
python tools\upload.py --port COM5 --file build\fw\hello.bin
```

入库：RTL / tcl / fdc / 脚本 / 文档。不入库：`build/`、`*.sbit`、`*.adf`、报告（只把数字摘进 log）。

---

## 8. 风险

| # | 风险 | 概率 | 影响 | 对策 |
|---|---|---|---|---|
| 1 | B1 都过不了（时钟/配置） | 中 | 致命 | B0 先钉死板子；BUFG 显式实例化；对照厂商 FDC |
| 2 | ADS 吃不下 CPU | 中 | 高 | B2 用最小程序早暴露；prep 脚本 + 手改 |
| 3 | BRAM 推断失败 | 中 | 高 | B3 单独验证；必要时换 Pango 原语 IP |
| 4 | 块 RAM 超 415（B6） | 中 | 高 | 按 L1I → scratch → 固件区间 顺序砍 |
| 5 | 视频时序被拖坏 | 低 | 高 | 视频域不加逻辑；异步时钟组；seed 5 |
| 6 | 检测慢/差 | 高 | 中 | 先打通链路，再换模型 |

---

## 9. 进度表

| 关 | 状态 | 日期 | 位流 sha256 | DRM | WNS | 判据原文 |
|---|---|---|---|---|---|---|
| B0 | ☐ | | — | — | — | |
| B1 | ☐ | | | | | |
| B2 | ☐ | | | | | |
| B3 | ☐ | | | | | |
| B4 | ☐ | | | | | |
| B5 | ☐ | | | | | |
| B6 | ☐ | | | | | |
| B7 | ☐ | | | | | |
| B8 | ☐ | | | | | |
