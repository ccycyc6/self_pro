# ---------------------------------------------------------------------------
# JTAG download onto the Pangu 200Pro+.
#
#   D:\PDS_2022.2-SP6.4\bin\cdt_js.exe -port <port>        (start once)
#   D:\PDS_2022.2-SP6.4\bin\cdt_cfg.exe -file fpga\pango\program.tcl ^
#       -args {<absolute path>\video_fb_top.sbit}
#
# The port defaults to 65420 (what PDS uses), but this machine has the Windows
# excluded TCP range 65389-65488 reserved by Hyper-V/WSL, which contains 65420:
# cdt_js then dies with "Socket bind error" and cdt_cfg reports "connection
# refused".  Set CDT_JS_PORT to a free port for BOTH ends.
# ---------------------------------------------------------------------------
set jsport 65420
if {[info exists ::env(CDT_JS_PORT)]} { set jsport $::env(CDT_JS_PORT) }

puts "program: connecting to 127.0.0.1:$jsport"
cfg_connect -ip 127.0.0.1 -port $jsport
cfg_scan_chain
cfg_assign_file -file E:/qs/5-stage-baseline/subprojects/gesture/bitstreams/s3h_video_fb_top.sbit -device_index 0
cfg_program -device_index 0
cfg_disconnect
cfg_close
