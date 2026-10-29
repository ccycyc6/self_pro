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
