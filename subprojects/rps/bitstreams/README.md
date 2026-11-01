# 位流归档

| 文件 | 用途 | sha256 |
|---|---|---|
| `s3h_video_fb_top.sbit` | 当前位流：720p + 双相机 + 画中画 + OSD + 加速器 | `141344AD702160D0D216C306B5E2FD8B6301998B9998E41A2B8B810AA4B08404` |
| `p3a_single_cam.sbit` | 上一版单相机 + OSD（回退用） | — |
| `firmware/rps_cam_board.bin` | 手势识别固件（与 s3h 配套，71,108 字节） | — |

烧写：

```powershell
powershell -ExecutionPolicy Bypass -File tools\program_board.ps1 -Bitstream bitstreams\s3h_video_fb_top.sbit
powershell -ExecutionPolicy Bypass -File tools\upload.ps1 -Port COM9 -File bitstreams\firmware\rps_cam_board.bin
```

**注意顺序**：位流烧写会复位板子，boot loader 只在复位后运行一次，所以必须
先烧位流、再传固件。

固件本身可以随时用 `tools/build_cam_board.sh` 重新编译，不需要重建位流——
位流里只有硬件：相机通路、画中画、OSD、加速器，没有模型。
