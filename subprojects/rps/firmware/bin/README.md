# Prebuilt release images

## cam_tracker_v1.bin (64,960 B)

Live camera demo for the B7b bitstream:

  * tracks the brightest 80x80 block of the centre 640x640 crop and draws it
    as a green box on the HDMI output;
  * runs the INT8 detector on the miniTensor accelerator every third frame and
    prints its answer on the UART.

sha256  C52FFCD4DA2FC5319282C0D5F51E8295DB1340640349F90E89A919DDEA7CAC98

Flash `build/pango/b7b/generate_bitstream/video_fb_top.sbit`
(sha256 8CE41766CC81F6680C3C47ED0E5A9F3381D37CB8ACF7AE85DACCEDD911CC1E17),
power-cycle the board (the reset button restarts the DDR3 IP and can leave the
picture black), then:

    powershell -ExecutionPolicy Bypass -File tools\upload.ps1 ^
        -Port COM9 -File firmware\bin\cam_tracker_v1.bin -Follow

Rebuild from source with `bash tools/build_cam_board.sh`
(`CAM_DEBUG=1` adds the thumbnail statistics and the 8x8 ASCII view).
