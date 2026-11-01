# rtl/video — 视频子系统（S2 已验证）

> 状态：**S2 摄像头 → DDR3 双缓冲 → HDMI 已完成并上板验证**
> （`picture8.jpg`，画面干净、无横条/抖动）。
> 目标板：盘古 200Pro+ / `PG2L200H-6IFBB676`。
> DDR3：官方 200Pro 2_9 IP，1000 Mbps，`DEVICE_100H_EN=false`，原始 DQ 顺序。
> 设计说明：`docs/video_subsystem_v1_design.md`；
> 调试记录：`fpga/pango/S2_DEBUG.md`。

---

## 1. 目录

```text
rtl/video/
├── video_defs.vh           参数/状态位/地址
├── video_fb_top.v          S2 顶层：摄像头 → DDR3 双缓冲 → HDMI
├── video_fb_status.v       S2 状态 UART/LED（M/N/V/L/X）
├── video_capture_wrap.v    OV5640 SCCB + DVP 8→16
├── video_dvp_rgb565.v      DVP 字节配对 + 3 级流水 + HREF 相位复位
├── video_hdmi_wrap.v       sync_vg + 图案 mux + MS7210（720p30，USE_EXT_DE）
├── video_pattern_gen.v     彩条/棋盘/移动块
├── video_clk_reset.v       PLL + 每域复位 + phy_rstn
├── video_ip_pll.v          GTP_GPLL 薄封装（27→37.125/10/24.75）
└── legacy/                 vendor framebuf/HDMI/I2C/相机表（S2 实际使用）
```

`legacy/` 里 S2 实际使用的模块：

```text
fram_buf.v / wr_buf.v / rd_buf.v / wr_ctrl.v / rd_ctrl.v
wr_cmd_trans.v / wr_rd_ctrl_top.v
wr_fram_buf.v / rd_fram_buf.v / ipm2l_sdpram_v1_10_{wr,rd}_fram_buf.v
sync_vg.v / ms7210_ctl.v / iic_dri.v / i2c_com.v / reg_config.v
power_on_delay.v
```

S0/S1/双测/BIST/仿真/测试文件已移出仓库；需要时从
`~/code/tmp/video-pruned/` 或 `~/code/tmp/` 取回。

---

## 2. 入口

| 入口 | 顶层 | 流程 |
| --- | --- | --- |
| S2 摄像头→DDR3→HDMI | `video_fb_top.v` | `fpga/pango/flow_video_fb.tcl`（官方 2_9，1000 Mbps，vendor DRM，seed 5） |

DDR3 BIST 的 `video_bist_top`/`flow_bist.tcl` 已移出仓库；需要时从
`video-pruned/` 取回。

---

## 3. 时钟 / 复位

| 域 | 时钟 | 复位 |
| --- | --- | --- |
| sys | `clk_27m` | `rst_sys` |
| pix | `clk_pix` 37.125 | `rst_pix` |
| cfg | `clk_cfg` 10 | `rst_cfg` |
| cam | `clk_cam` 24.75 | `rst_cam` |
| vin | `pixel_clk` 42 | `pixel_rst`（`~cam_init_done`） |
| ddr | `ddr_core_clk` 125 | `ddr_rstn` / `ddr_init_done` |

所有新代码复位 **同步、高有效**；legacy 边界取反成低有效。
`clk_pix` 37.125 = 27 × 11/8，HDMI 720p30。

---

## 4. 构建

```bat
cd fpga\pango
D:\PDS_2022.2-SP6.4\bin\pds_shell.exe -file flow_video_fb.tcl -project_name video_fb
```

产物：

```text
fpga\pango\generate_bitstream\video_fb_top.sbit
```

烧写：

```bat
cd D:\PDS_2022.2-SP6.4\bin
cdt_cfg.exe -file C:\...\fpga\pango\program.tcl ^
  -args "{C:\...\fpga\pango\generate_bitstream\video_fb_top.sbit}"
```

期望状态：

```text
S2 P=1 D=1 H=1 C=1 F=1 B=1 R=1 E=1 G=1 M=... N=...
```

`D=1` DDR3 init；`B/R/E/G=1` framebuf 正常；`M≈N` 读回与摄像头一致。

---

## 5. 接口要点

- `video_fb_top` 端口与 `fpga/pango/video_top.fdc` 对齐；
- DDR3 引脚只出现在 `official_ddr3.fdc`；IP 实例名必须是 `I_ips_ddr_top`；
- 参考时钟端口叫 `ref_clk_p/ref_clk_n`；
- framebuf 读侧直接接 `sync_vg.de_re`/`vs_out`，不加 `fb_init_done` 闸门；
- `axi_wlast` 接 IP 的 `axi_wusero_last`；
- 当前 S2 使用 `video_dvp_rgb565`（HREF 复位字节相位），不使用
  `legacy/cmos_8_16bit.v`；
- 当前 S2 使用 vendor `wr_fram_buf`/`rd_fram_buf` + SDPRAM，不使用推断
  `video_dpram`。

---

## 6. 已验证配置

```text
DDR3: 官方 2_9, 1000 Mbps, DEVICE_100H_EN=false, 原始 DQ
Framebuf: vendor wr_fram_buf/rd_fram_buf + ipm2l_sdpram
Camera: video_dvp_rgb565, 2.5 V/LVCMOS25 (J24=2V5, J13 已修正)
HDMI: USE_EXT_DE=1, MS7210 720p30
时序: 无读闸门, 无 set_input_delay/set_output_delay
PnR: seed 5
状态: D=1 B=1 H=1 C=1 F=1, M≈N
```

---

## 7. 下一步

1. 接 SoC（视频流 / 寄存器 / AXI）；
2. 如需更高刷新率，再评估 720p60；
3. 改 RTL 后先确认 DDR3 `D=1`，再确认 S2 `B=1/M≈N`。
