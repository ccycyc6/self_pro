# 板子操作手册（自动/远程可用）

> 验证时间：2026-10-30 01:40，由 agent 实际执行通过（烧写 → 上传 → 读串口全链路）

## 0. 前提

| 项 | 要求 |
|---|---|
| JTAG 服务 | `D:\PDS_2022.2-SP6.4\bin\cdt_js.exe -port 65420` 必须常驻（开机自启或手动启动） |
| 串口 | COM9（Silicon Labs CP210x），115200 8N1 |
| 串口独占 | **必须先关掉 sscom / PuTTY / 带 `-Follow` 的上传进程**，否则报“访问被拒绝” |
| 工作目录 | 任意；下面所有路径都用绝对路径 |

## 1. 烧位流（JTAG）

```powershell
& "D:\PDS_2022.2-SP6.4\bin\cdt_cfg.exe" `
  -file "E:/qs/5-stage-baseline/fpga/pango/program.tcl" `
  -args "{E:/qs/5-stage-baseline/build/pango/b7b/generate_bitstream/video_fb_top.sbit}"
```

**必须用正斜杠**。反斜杠会被 PowerShell 吃成转义，Tcl 收到
`E:qs-stage-baselineuildpango...`，然后报 `FileSystem-0020`。

成功标志：

```
The done bit is 1
COMMAND[Program] execute successfully, takes 8.1 secs.
```

耗时约 10 秒（9 MB 位流）。烧完设计立即启动，**loader 横幅只打印一次**，
几秒后再开串口就看不到了——但这不影响上传（loader 一直在轮询等待）。

## 2. 上传固件并看输出

```powershell
powershell -ExecutionPolicy Bypass -File tools\upload.ps1 `
  -Port COM9 -File build\fw\cam_board.bin
```

- 默认：上传后监听 15 秒；
- `-Follow`：上传后持续打印，直到 Ctrl+C（**这个会占住串口**，用完记得关）。

## 3. 纯粹读串口（不烧不传）

```powershell
$sp = New-Object System.IO.Ports.SerialPort("COM9",115200,"None",8,"One")
$sp.Open(); $sp.DiscardInBuffer()
$end = (Get-Date).AddSeconds(3)
while ((Get-Date) -lt $end) { $sp.ReadExisting(); Start-Sleep -Milliseconds 40 }
$sp.Close()
```

## 4. 常见故障

| 现象 | 原因 | 处理 |
|---|---|---|
| `对端口"COM9"的访问被拒绝` | 别的进程占着串口 | `Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"` 找 `-Follow` 会话；sscom 用 `CloseMainWindow()` 关 |
| `couldn't read file fpga/pango/program_run.tcl` | `-file` 传了相对路径 | 换成绝对路径 |
| `FileSystem-0020` | `-args` 里是反斜杠 | 换正斜杠 |
| `cdt_cfg` 连不上 | `cdt_js` 没在跑 | 启动 `cdt_js.exe -port 65420` |
| 烧完无输出、上传也失败 | 板子没上电 / USB 线掉了 | 检查电源与 CP210x |

## 5. 复位键注意

C22 复位键会把 PLL 和 DDR3 IP 一起重启，DDR3 重新校准可能失败导致**黑屏**。
需要复位时优先用 **JTAG 重新烧写**（等价于一次干净的配置）或断电重启。
## 6. JTAG 服务起不来：端口被 Windows 保留（2026-10-30 确认）

现象：

    cdt_js : Cannot create listening port: Socket bind error
    cdt_cfg: E: CdtCommon-0402: Fail to connect to server ...
             The connection was refused by the peer

原因不是驱动、不是线、不是 PDS 装坏，而是 **Windows 把 65389-65488 这段 TCP 端口
保留给了 Hyper-V/WSL**，默认的 65420 正好落在里面：

    netsh int ipv4 show excludedportrange protocol=tcp
      65389  65488
      65289  65388
      ...

**解决办法（不需要管理员权限）**：让 cdt_js 和 cdt_cfg 都用保留区之外的端口，例如 60000。

    cdt_js.exe  -port 60000
    set CDT_JS_PORT=60000
    cdt_cfg.exe -file fpga\pango\program.tcl -args {<bitstream>}

`fpga/pango/program.tcl` 已改成读 `CDT_JS_PORT`（缺省仍是 65420），
现成脚本：

    powershell -ExecutionPolicy Bypass -File tools\program_board.ps1 ^
        -Bitstream build\pango\p1c\generate_bitstream\video_fb_top.sbit

它会自动在 60000 起服务、烧写、检查 done bit（实测 8 秒完成）。

**如果还想让 PDS IDE 里的下载按钮能用**，两个办法：

1. 管理员执行 `net stop winnat` 释放保留段（之后 IDE 用 65420 即可，重启后可能复发）；
2. 在 IDE 的连接设置里把 JTAG Server 端口改成 60000。
## 7. 上传固件的前提：loader 必须正在运行（2026-10-30 实测）

板子启动后 **loader 只跑一次**（打印一行横幅、等你发镜像）。一旦上传成功并跳转到
固件，loader 就不在了；之后再发镜像**不会有任何回应**（固件不会去读串口）。

所以"改固件"的正确流程是：

    JTAG 重新烧写（等价于复位） → 立刻上传 → 固件接管

不要指望连续上传两次。日志里出现过"上传没反应"，原因就是这个。

## 8. "JTAG 链上没有器件" ≠ 线坏了

症状组合：

| USB 设备 | JTAG 扫描 | 含义 |
|---|---|---|
| 有 CP210x、有 FTDI | 找到 cable，但 no devices | **FPGA 板没上电**（12 V 没开/掉了），或 10 pin 排线松 |
| 什么都没有 | 失败 | USB 线掉了 |

FTDI 是 USB 供电的，所以"cable 能列出来"不代表板子有电。
遇到这种情况先看板子的电源指示灯。
