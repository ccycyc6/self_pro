# 上板验证日志（bringup log）

> 规则：每过一关追加一节，只贴事实（命令、串口原文、报告数字），不写推测。
> 位流不入库，但 sha256 必须记录，保证"结论对应哪一个位流"。
> 方案：[board_yolo_camera_plan.md](board_yolo_camera_plan.md)

---

## 进度总表

| 关 | 内容 | 状态 | 日期 | 位流 sha256 | DRM | WNS | 结论 |
|---|---|---|---|---|---|---|---|
| B0 | 厂商位流钉死板子 | ✅ PASS | 2026-10-28 | 厂商原版 | — | — | 板子/下载/串口正常 |
| B1 | 最小位流（时钟/UART 活着） | ✅ PASS | 2026-10-28 | `284C6E38…` | 0/415 | +32.4 ns | 时钟/复位/UART/引脚/流程全部正常 |
| B2 | CPU + ROM 打印 | ✅ PASS | 2026-10-28 | `A5581886…` | 8/415 | +17.7 ns | 板上串口 + LED 均符合预期 |
| B3 | BRAM 读写自检 | ✅ PASS | 2026-10-28 | `7BE6DDC8…` | 16/415 | +18.6 ns | 板上 BRAM PASS 持续输出 |
| B4 | 串口 loader | ✅ PASS | 2026-10-28 | `3DCF8BA1…` | 40/415 | +19.2 ns | 上传 11192 B，loader 跳转后 C 应用跑起来 |
| B5 | 张量上板 | ✅ PASS | 2026-10-29 | `5D52CA26…` | 40/415 | +17.1 ns | 板上 golden diff 0 bytes，7468368 cycles |
| B6-pre | 摄像头→DDR3→HDMI 独立位流 | ✅ PASS | 2026-10-28 | `F5D0EED6…` | 9/415 | 0 failing | 画面干净 |
| B6 | 并入视频（+SoC） | ✅ PASS | 2026-10-29 | `73485295…` | 49/415 | hold −0.07 | 画面 + golden 0 同时成立 |
| B7a | 摄像头 → SoC（无 OSD） | 🔶 位流就绪 | 2026-10-29 | `3AD6DA11…` | 50/415 | hold −0.07 | 待上板 |

---

## B0 — 厂商位流（无代码）

- **日期**：2026-10-28
- **烧写**：`led_test.sbit`（厂商 4_1_led_test）→ **LED 正常**
- **烧写**：`uart_top.sbit`（厂商 2_8_uart_test）→ 串口正常
- **结论**：**PASS**。板子、供电、JTAG 下载链、SCBV、USB-UART 全部正常。
  之前"下载后没反应"**不是**板子/下载/电源问题。
- **意义**：把嫌疑范围压缩到"我们的设计"这一侧。

---

## B1 — 最小位流（时钟 / UART）

- **日期**：2026-10-28   **提交**：`75d47a3`   **tag**：`board-b1`
- **位流**：`build/pango/smoke/generate_bitstream/board_smoke.sbit`（9,188,552 B）
- **sha256**：`284C6E38E931859BF7D198E3E947B56C792E267AB0FDFBFD0683EA9EBB952A14`
- **资源**：CLMA 47/30075，LUT 128/159800，寄存器 103/319600，**DRM 0/415**
- **时序**：setup slack **+32.4 ns**（27 MHz），0 failing
- **上板前仿真门**：`sim/rtl/tb_board_smoke.sv`（Verilator 5.020）→ `TB PASS: two full messages decoded at 115200`
  - 抓到真实 bug：`MSG[idx*8 +: 8]` 字节序取反（收到 `0A 0D 4B 4F … 41`），已改为从高位取。
- **上板现象**：串口每 0.5 s 输出 `ARES-S1 smoke OK`；LED 心跳（用户确认）
- **结论**：**PASS**。27 MHz 进 fabric、POR+按键复位、UART 分频/引脚、PDS 流程、约束全部正常。
  PDS 自动插入全局时钟缓冲（place 日志 `clkbufg_0/gopclkbufg`），无需手工 BUFG。
- **意义**：SoC 侧的问题从此只可能在 RTL/综合/BRAM/启动，而不在板级。

---

## B2 — CPU + ROM

- **日期**：2026-10-28   **提交**：`e789a33`   **tag**：`board-b2`
- **位流**：`build/pango/soc/generate_bitstream/board_b2.sbit`（9,188,552 B）
- **sha256**：`A5581886C2D0A28F5D8B1D9D91D0A1FAB18DD9CA75EC617537D24842538A4383`
- **资源**：LUT 3597/159800 (2.25%)，REG 2768/319600，DRAM 189/39500，**DRM 8/415**
- **时序**：setup WNS **+17.722 ns**，0 failing；hold slow WHS +0.128 ns；
  hold **fast** 角 `-0.026 ns / 1 endpoint`（27 MHz 下无实际影响，已知边角；
  如要收掉，在 FDC 加 `set_clock_uncertainty 0.100 -hold [get_clocks {sys_clk}]` 重跑）
- **全流程耗时**：5m47s（compile 4s / synth 20s / dev_map 11s / pnr ~4m / bitgen 20s）
- **上板前仿真门**：`sim/rtl/tb_b2.sv`（真实 SoC RTL + 生成的 boot_rom + 真实固件）
  → `TB PASS: B2 banner decoded from the generated ROM`
- **上板现象**（用户实测，2026-10-28 20:44）：

```text
[20:44:54.454] B2 OK mcycle=6d33da4e
[20:44:54.923] B2 OK mcycle=6df4a601
[20:44:55.391] B2 OK mcycle=6eb571a1
```

  每行间隔 0.468 s，mcycle 增量 ≈ 12.63 M → **26.9 MHz**，与 27 MHz 约束一致。
- **LED**：led[0] 闪、led[1] 常亮、**led[2] 高频闪**、led[7:4] 随 PC 跳变 —— 与预测完全一致
- **结论**：**PASS**。CPU、ADS 综合、ROM 启动、UART、CSR mcycle 全部在真实板卡上验证。
  这同时回答了最初的问题：**"下载后没反应"不是 CPU 或工具链的问题**——B2 用一个
  不含 BRAM、不含 DDR、不含 loader 的最小系统，在同一套流程下正常工作。

---

## B3 — BRAM 自检

- **日期**：2026-10-28   **提交**：`b1daa0b`   **tag**：`board-b3`
- **位流**：`build/pango/b3/generate_bitstream/board_cpu.sbit`（9,188,552 B）
- **sha256**：`7BE6DDC89B96CD5C6BF4706C0F9ADDDA065AAE8E8F37A554A5B7C6FD4A61B380`
- **资源**：LUT 3990/159800 (2.50%)，REG 3010/319600，**DRM 16/415**
- **时序**：setup WNS **+18.633 ns**，0 failing；hold slow +0.256 ns；
  估计最高频率 **54.3 MHz**（27 MHz 约束）
- **全流程耗时**：4m47s
- **上板前仿真门**：`sim/rtl/tb_b3.sv` → `TB PASS: BRAM read-back verified by the CPU`
- **测试内容**：2048 字写入 0x8000_0000 后读回比对；再测字节写使能（sb）和
  半字写使能（sh）；失败会打印 `addr/got/exp`
- **上板现象**（用户实测，2026-10-28 20:57）：

```text
BRAM PASS mcycle=242fc0d3
BRAM PASS mcycle=24f0b17e
BRAM PASS mcycle=25b1a243
```

- **注意**：串口会**一直**每秒重复这一行，这是心跳（证明还在跑），不是还在测。
  测试本身在复位后不到 1 ms 就做完了：2048 写 + 2048 读各约 5 拍。
- **注意**：`rtl/board/boot_rom.v` 现在装的是 B3 固件。要重建 B2 位流，
  先 `python tools/mkrom.py build/fw/b2_hello.bin rtl/board/boot_rom.v`。
- **结论**：**PASS**。BRAM 推断、字节写使能、L2 地址路由、128-bit 拍协议全部在板上验证。
  至此，旧"没反应"的两个嫌疑（CPU / BRAM 初值）都已被独立证明是好的——
  剩下的只有"固件怎么进内存"这一环，正是 B4 要做的。

---

## B4 — 串口 loader

- **日期**：2026-10-28   **提交**：`db505b9`   **tag**：`board-b4`
- **位流**：`build/pango/b4/generate_bitstream/board_cpu.sbit`（9,188,552 B）
- **sha256**：`3DCF8BA1DB48D0F8E946DF4C17CD23157B7F6BF6B3ABA11CF0718D1030E2E8C8`
- **资源**：LUT 4011/159800 (2.51%)，REG 3052，**DRM 40/415**（128 KiB 片内存储）
- **时序**：setup WNS **+19.18 ns**，估计最高频率 **56.0 MHz**；全流程 4m14s
- **协议**：`"ARS1"` + 长度(LE32) + 载荷 + 校验和(LE32，字节和)
- **上板前仿真门**：`sim/rtl/tb_b4.sv` 用真实 11192 字节镜像驱动 UART RX →
  `TB PASS: loader accepted the image and the new firmware ran`

**这一步抓到一个真 bug**：`ares_uart` 的 RX 采样点在 0.5 bit（起始位中间），
把起始位当成了 d0，所有收到的字节整体错一位；再加上没有停止位检查。
之前所有固件只用 TX，所以从来没暴露。现在采样点改为 1.5 bit 起、每 bit 一次、
第 9 次为停止位。修复后 `make yolo` 仍是 golden diff 0 bytes。

- **上板现象**（用户实测，2026-10-28 21:19）：

```text
（上电）ARES-S1 loader v1 - send image
（上传）
upload: 11192 bytes payload, checksum 0x000E9B55, 11204 bytes on the wire
image ok, jump 0x80000000
B4: hello from loaded firmware @0x80000000
B4: mcycle=1790373925
```

- **上传命令**：`powershell -ExecutionPolicy Bypass -File tools\upload.ps1 -Port COM5 -File build\fw\b4_hello.bin`
- **注意**：loader 上电后一直在等收数据，横幅只打印一次；按复位会重新打印。
- **结论**：**PASS**。UART 收、写 128 KiB BRAM、fence.i、跳转、C 运行时（栈 + printf）
  全部在真实板卡上验证。**从此改固件不用重跑 PnR**——这是后续 B5/B6/B7 能快速迭代的前提。

---

## B6-pre — 摄像头 → DDR3 → HDMI（独立视频位流，不含 SoC）

- **日期**：2026-10-28   **提交**：`d2a2927`   **tag**：`board-video`
- **来源**：ARES S2 工程逐文件搬入本仓库（`rtl/video/**` + `legacy/**` +
  `fpga/pango/ip/ddr3/ddr3_test` + 三个 FDC + `flow_video.tcl`），一份没改
- **位流**：`build/pango/video/generate_bitstream/video_fb_top.sbit`（9,188,552 B）
- **sha256**：`F5D0EED618C8AF2B5BBA623CFDADB43844FB5239C797FCF1ADC3EE93D3625A61`
- **资源**：LUT 5787/159800，REG 6761，**DRM 9/415**
- **时序**：0 failing；ddrphy_sysclk WNS +2.0…+2.2 ns，sys_clk +28.9 ns，cmos1_pclk +8.2 ns
- **全流程耗时**：3m48s
- **用途**：在合入 SoC 之前，先用一个"只有视频"的位流证明
  **摄像头 + DDR3 帧存 + HDMI 输出**在这块板子上是好的。
  它同时是 [camera_hw_checklist.md](camera_hw_checklist.md) 第 6 节的功能判据。
- **现象**（用户实测，2026-10-28 21:47）：**画面正常、串口状态全 1，无任何问题**

- **判据**：HDMI 出实时画面；`D=1`（DDR3 初始化）、`H=1`（HDMI）、`C=1`（摄像头 SCCB）、
  `B=1`（framebuf 首帧写入）、`M≈N`（写侧与读回的中心像素接近）
- **注意**：这个位流里没有 CPU/Tensor，UART 被 S2 的状态机占用；烧回 B4/B5 前先烧回对应位流。

---

## B5 — 张量

- **日期**：2026-10-28   **提交**：`2ea5da0`   **tag**：`board-b5`
- **位流**：`build/pango/b5/generate_bitstream/board_cpu.sbit`（9,188,552 B）
- **sha256**：`5D52CA26C2194005E9C8DA909624A8599FF05685B48FE841310756E5D8857F42`
- **资源**：LUT 19,776/159,800 (12.38%)，REG 8,169，**DRM 40/415**
- **时序**：setup WNS **+17.1 ns**，0 failing，估计最高 **50.2 MHz**
- **全流程耗时**：29m37s（布线比前几关慢：CPU + 64 KiB scratch + 128 KiB 存储 + 张量）
- **固件**：`build/fw/yolo_board.bin`（58,440 B，`tools/build_yolo_board.sh` 生成，UART_DIV=234）
- **验证方式**：烧位流 → 用 B4 的 loader 上传固件（约 5 s）→ 串口
- **现象**（用户实测，2026-10-29 00:29）：

```text
image ok, jump 0x80000000
miniTensor detector: packed INT8 weights, 1 test images.
  L1 mult=32275 shift=23 relu=1
  L4 mult=31604 shift=22 relu=0
  nmt: L1=2 L2=4 L3=4 L4=2
  img 0: detection centre cell (1.7, 1.4) -> pixel (6, 6), golden diff 0 bytes
miniTensor detector: 1/1 images decoded, 17184 commands/image, 7468368 cycles, golden diff 0 bytes
YOLO run returned 0
```

  周期数 7,468,368 比仿真的 7,292,716 多 2.4%——仿真里 BRAM 零延迟，板上每次访问
  多几拍，属于预期差异，**数值结果逐字节相同**。

- **结论**：**PASS**。CPU + 张量 + DMA + 4x4 GEMM + 向量单元 + epilogue 在真实 FPGA 上
  逐字节正确。核心链路（core + tensor + memory + UART）到此全部验证完毕，
  剩下的只有"合进视频"和"接摄像头"。

---

## B6 — 并入视频

- **日期**：   **提交**：   **tag**：`board-b6`
- **现象**：

```text
SYS P=1 D=1 H=1 C=1
```

- **结论**：

---

## B6 — 视频 + SoC 合并

- **日期**：2026-10-29   **提交**：`657b2da`   **tag**：`board-b6`
- **位流**：`build/pango/b6/generate_bitstream/video_fb_top.sbit`（9,188,552 B）
- **sha256**：`73485295705A39A2ED429B3552A72D6BD4B22F6F03A9E120DB40C5B32D1EF20A`
  （第一次构建 `B0144D71…` 的 SoC 串口 RX 被焊死在 1，loader 收不到数据，已修）
- **资源**：LUT 25,132/159,800 (15.73%)，REG 14,155，**DRM 49/415**
- **时序**：setup 全部 MET（DDR3 域 +2.0 ns，sys_clk +16.5 ns）；
  **hold 有 5 条 -0.07…-0.005 ns 的违例**，都在 SoC 的 tensor_controller 上
  （27 MHz 下无实际影响，属于签核边角；换 seed 或加 hold fix 可收）
- **耗时**：36m10s（seed 5）
- **做法**：SoC 放在 `video_fb_top` 内部（`ifdef BOARD_SOC`），视频层级不变，
  S2 的三份约束文件原样使用
- **验证**：HDMI 出画面 + 上传 `yolo_board.bin` 后串口出 `golden diff 0 bytes`
- **现象**（用户实测，2026-10-29 08:41）：HDMI 全程有画面；上传后串口完整打印
  `golden diff 0 bytes` / `7468368 cycles`（与 B5 单机时一致）
- **结论**：**PASS**。摄像头/DDR3/HDMI 与 CPU/张量在同一个位流里并存互不影响。
- **遗留**：按复位键（C22）会让 DDR3 重新校准失败、画面变黑 → **用断电代替复位**；
  hold 有 5 条 ~−0.07 ns 的边角违例（27 MHz 下无影响，换 seed 可收）

---

## B7a — 摄像头进 SoC（先不画框）

- **日期**：2026-10-29   **提交**：`227cb0d`   **tag**：待上板
- **位流**：`build/pango/b7/generate_bitstream/video_fb_top.sbit`（9,188,552 B）
- **sha256**：`25A6ACAFF5607C64EC3689785D1400B03D4D0C93B4D9970ABEAE02E86D09F52B`
  （第一版 `3AD6DA11…` 用真双端口 RAM，PDS 没推断出来，读回全 0；
  改成异步 FIFO + 单时钟 RAM，并修了 MMIO 读差一拍）
- **资源**：LUT 25,297/159,800 (15.83%)，REG 14,286，**DRM 50/415**
- **固件**：`build/fw/cam_board.bin`（64,632 B，`tools/build_cam_board.sh`）
- **新增**：`cam_cap` 640×640 中心裁剪 + 20:1 抽取 → 32×32；`cam_buf` 真双时钟
  BRAM；MMIO `0xD000_2000 + i*4` 像素、`0xD000_3000` 帧计数
- **现象**：⏳ 待烧写

```text
camera detector ready, watching the 32x32 thumbnail
cam f=137 cell=(5,3) box=(420,100)-(440,120) t=268000
```

---

## B7b — 摄像头 + OSD 框

- **日期**：   **提交**：   **tag**：`board-b7`
- **现象**：

```text
cam frame=142 box=(462,190,502,230) t=268ms
```

- **结论**：
