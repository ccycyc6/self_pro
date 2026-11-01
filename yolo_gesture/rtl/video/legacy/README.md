# rtl/video/legacy — 官方 RTL 原样保留

> 来源：官方 200Pro 资料包里的 `8_MES-FMC-LPC-IO/2_Demo/HDMI_DDR3_OV5640_100h`
> （100H 核心板 + 同一张 FMC 相机卡）。S2 在 200Pro+ 上复用这份 vendor
> framebuf/HDMI/I2C RTL，只替换了 DDR3 IP（官方 2_9，1000 Mbps）和板级顶层。
>
> 规则：**不改 vendor 逻辑**。保留原始版权头和文件名；必要时加英文来源注释。
> 官方代码是 active-low reset、Verilog-2001；wrapper 边界统一转成项目约定
> （同步、高有效）。

---

## 1. 文件清单

| 文件 | S2 用法 |
| --- | --- |
| `fram_buf.v` | 双缓冲顶层（`wr_buf`/`rd_buf`/`wr_rd_ctrl_top` + AXI） |
| `wr_buf.v` / `rd_buf.v` | 写/读行缓冲、帧位、DDR3 突发 |
| `wr_ctrl.v` / `rd_ctrl.v` / `wr_cmd_trans.v` / `wr_rd_ctrl_top.v` | vendor 读写控制 |
| `wr_fram_buf.v` / `rd_fram_buf.v` | **vendor DRM 封装**（`GTP_DRM36K_E1` SDPRAM） |
| `ipm2l_sdpram_v1_10_wr_fram_buf.v` / `..._rd_fram_buf.v` | 上面两个封装的 DRM 原语 |
| `sync_vg.v` | HDMI 720p30 时序（`vs_out/hs_out/de_out/de_re`） |
| `ms7210_ctl.v` / `iic_dri.v` | HDMI TX 初始化 |
| `reg_config.v` / `i2c_com.v` | OV5640 SCCB 寄存器表 |
| `power_on_delay.v` | 上电延时 |
| `cmos_8_16bit.v` | vendor 旧 DVP 8→16（**仅对照**；S2 用 `video_dvp_rgb565`） |

`rtl/video/alt/video_dpram.v` 是推断 RAM 替代，**只用于仿真**；当前 S2 综合流程
使用 `wr_fram_buf.v`/`rd_fram_buf.v` + `ipm2l_sdpram_v1_10_*.v`，不要同时加入
（同名模块）。

---

## 2. 已知行为（不要“顺手修”）

| 模块 | 行为 | S2 处理 |
| --- | --- | --- |
| `wr_buf.v` | 帧位 `bit22`，两 buffer 当前地址单位下 16 MB 间距；行触发 `x_cnt > H_NUM-20` | 接受；`H_NUM=1280` |
| `rd_buf.v` | 只发 **719 行**读请求 | 接受；底部可能一行黑边 |
| `wr_ctrl.v` / `rd_ctrl.v` | `awsize/arsize=3'b110`，但 DDR3 IP 没有 size 端口 | 不接，死逻辑 |
| `fram_buf.v` | `read_ready=1'b1`，读侧无反压 | 接受 |
| `fram_buf.v` `axi_wlast` | vendor 顶层接 IP 的 `axi_wusero_last`，不是 framebuf 自己产生 | **S2 顶层已接 `axi_wusero_last`** |
| `cmos_8_16bit.v` | 传感器 0x4300=0x60 是 RGB565 sequence 0，`pdata_o[15:11]=B,[10:5]=G,[4:0]=R`（BGR565）；`de_o` 比 href 晚 3 个 pclk | vendor 保留作对照；S2 用 `video_dvp_rgb565`，在 `!de_i` 清相位，`video_capture_wrap` 的 `RGB_SWAP=1` 转成 `{R,G,B}` |
| `reg_config.v` | 357 条寄存器，SCCB 约 10 kHz，初始化约 1.5 s | 仓库保持原厂表；构建工程里的彩条补丁（`356: 0x503D80`）不提交 |
| `ms7210_ctl.v` | 49 条写 + 320 ms 等待；`init_over` 在 `STA_RD` 置高 | 只用 TX；`iic_dri` 400 kHz |
| `power_on_delay.v` | 端口叫 `clk_50M`，实际接 27 MHz；`camera_pwnd` 未用 | 接受，接 `clk_27m` |

---

## 3. 编码与 lint

- 源文件含 GBK/UTF-8 混合中文注释，**不要整体重新编码**；只加英文来源注释。
- 官方代码可能触发 Verilator `-Wall` 警告；在 `legacy/` 单独 lint，或用文件级
  `/* verilator lint_off ... */`，不要把时序逻辑改成“lint 干净”的写法。
- `cmos_8_16bit.v` 依赖 Pango 原语 `GTP_IOCLKDIV_E2`；Verilator 用
  `rtl/video/sim/GTP_IOCLKDIV_E2.v` 行为模型。
- S2 当前用 `video_dvp_rgb565`，不是 `cmos_8_16bit`；后者只作为
  “如果摄像头横条仍在”的对照方案保留。
