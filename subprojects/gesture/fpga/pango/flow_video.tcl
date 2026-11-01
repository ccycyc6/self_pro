# ---------------------------------------------------------------------------
# S2 standalone flow: OV5640 -> DDR3 double buffer -> HDMI 720p30 (no SoC).
#
# Top: video_fb_top
#   video_clk_reset + video_ip_pll
#   video_capture_wrap + video_dvp_rgb565 (OV5640 DVP, RGB565)
#   legacy fram_buf + wr_buf/rd_buf + vendor wr_fram_buf/rd_fram_buf
#     (GTP_DRM36K_E1 SDPRAM, not the inferred video_dpram)
#   ddr3_test I_ips_ddr_top
#     official Pangu 200Pro 2_9 IP: 1000 Mbps, DEVICE_100H_EN=false
#   video_hdmi_wrap + ms7210_ctl (720p30)
#
# DDR3 constraints: official_ddr3.fdc.  It is the pin/clock/CPD/multicycle
# subset of the official 2_9 ipcore/ddr3_test/pnr/ddr_test.fdc (free_clk /
# UART / LED entries removed).  No PHY placement PCF is appended: the official
# 2_9 IP + FDC place the PHY automatically and meet timing at 1000 Mbps.
# The old 100H/600 Mbps IP + ddr3_phy_place_2255_in.pcf are in
# ip/ddr3/archive_100h_600m/ and are NOT used by this flow.
#
# Usage (Windows, from this directory):
#   D:\PDS_2022.2-SP6.4\bin\pds_shell.exe -file flow_video_fb.tcl -project_name video_fb
# ---------------------------------------------------------------------------
set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here ".." ".."]]

puts "video-fb: repo $root"

set_arch -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6

# IP constraints first: they create ddrphy_sysclk, which video_fb.fdc uses.
add_constraint [file join $here "official_ddr3.fdc"]
add_constraint [file join $here "video_top.fdc"]
add_constraint [file join $here "video_fb.fdc"]

foreach f [list \
    "video_fb_top.v" \
    "video_clk_reset.v" \
    "video_ip_pll.v" \
    "video_fb_status.v" \
    "video_hdmi_wrap.v" \
    "video_pattern_gen.v" \
    "video_capture_wrap.v" \
    "video_dvp_rgb565.v" \
    "legacy/wr_fram_buf.v" \
    "legacy/rd_fram_buf.v" \
    "legacy/ipm2l_sdpram_v1_10_wr_fram_buf.v" \
    "legacy/ipm2l_sdpram_v1_10_rd_fram_buf.v" \
    "legacy/sync_vg.v" \
    "legacy/ms7210_ctl.v" \
    "legacy/iic_dri.v" \
    "legacy/reg_config.v" \
    "legacy/i2c_com.v" \
    "legacy/power_on_delay.v" \
    "legacy/fram_buf.v" \
    "legacy/wr_buf.v" \
    "legacy/rd_buf.v" \
    "legacy/wr_ctrl.v" \
    "legacy/rd_ctrl.v" \
    "legacy/wr_cmd_trans.v" \
    "legacy/wr_rd_ctrl_top.v" ] {
    add_design [file join $root "rtl" "video" $f]
}

add_design [file join $here "ip" "ddr3" "ddr3_test" "ddr3_test.idf"]

compile -top_module video_fb_top
synthesize -ads
dev_map
pnr -seed 5
report_timing -max_path 20
gen_bit_stream -create_bit true
