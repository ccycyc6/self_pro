# ---------------------------------------------------------------------------
# flow_full.tcl - B6: verified video pipeline + SoC in one bitstream.
#
#   top: rtl/board/board_full.v
#        = video_fb_top (unchanged, S2) + ares_soc (B5)
#
# Constraints: the three files the S2 video build already proved
#   official_ddr3.fdc (IP pins/clock/CPD) -> video_top.fdc (board pins) ->
#   video_fb.fdc (pixel clock / CDC)
# No board_pins.fdc here: video_top.fdc already carries clk / rst / uart / led.
# ---------------------------------------------------------------------------
set do_pnr 1
if {[info exists ::env(ARES_NO_PNR)]} { set do_pnr 0 }

set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here ".." ".."]]
set syn  [file join $root "build" "pango" "syn" "rtl"]

puts "full: workdir=[pwd]"

set_arch -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6

# The S2 constraint files use absolute instance paths (I_ips_ddr_top,
# u_clk_reset/...) because the video top was the top level.  In this build the
# video pipeline is u_video, so the *_b6 copies carry the u_video/ prefix.
add_constraint [file join $here "official_ddr3.fdc"]
add_constraint [file join $here "video_top.fdc"]
add_constraint [file join $here "video_fb.fdc"]

proc walk {dir} {
  set out {}
  foreach f [lsort [glob -nocomplain -directory $dir *]] {
    if {[file isdirectory $f]} { set out [concat $out [walk $f]] } \
    elseif {[string match "*.v" $f]} { lappend out $f }
  }
  return $out
}

# ---- SoC (converted SystemVerilog, packages first) -------------------------
set pkgs [list common/ares_pkg.v minitensor/common/minitensor_pkg.v \
          minitensor/tensor/tensor_pkg.v minitensor/vector/vpu_pkg.v]
foreach p $pkgs { add_design [file join $syn $p] }
foreach f [walk $syn] {
    set skip 0
    foreach p $pkgs { if {[string match "*/$p" $f]} { set skip 1 } }
    if {!$skip} { add_design $f }
}

# ---- video pipeline (plain Verilog, taken from the S2 build) ---------------
foreach f [list \
    "video_fb_top.v" "video_clk_reset.v" "video_ip_pll.v" \
    "video_fb_status.v" "video_hdmi_wrap.v" "video_pattern_gen.v" \
    "video_capture_wrap.v" "video_dvp_rgb565.v" \
    "cam_cap.v" "cam_buf.v" \
    "legacy/wr_fram_buf.v" "legacy/rd_fram_buf.v" \
    "legacy/ipm2l_sdpram_v1_10_wr_fram_buf.v" \
    "legacy/ipm2l_sdpram_v1_10_rd_fram_buf.v" \
    "legacy/sync_vg.v" "legacy/ms7210_ctl.v" "legacy/iic_dri.v" \
    "legacy/reg_config.v" "legacy/i2c_com.v" "legacy/power_on_delay.v" \
    "legacy/fram_buf.v" "legacy/wr_buf.v" "legacy/rd_buf.v" \
    "legacy/wr_ctrl.v" "legacy/rd_ctrl.v" "legacy/wr_cmd_trans.v" \
    "legacy/wr_rd_ctrl_top.v" ] {
    add_design [file join $root "rtl" "video" $f]
}

# ---- DDR3 IP ---------------------------------------------------------------
add_design [file join $here "ip" "ddr3" "ddr3_test" "ddr3_test.idf"]

# ---- hand-written board-level Verilog --------------------------------------
add_design [file join $root "rtl" "soc" "ddr" "ddr_stub.v"]
add_design [file join $root "rtl" "soc" "ddr" "ddr_bram.v"]
add_design [file join $root "rtl" "board" "boot_rom.v"]

# The SoC is instantiated *inside* video_fb_top (ifdef BOARD_SOC) so that the
# DDR3 IP, the PLL and the framebuffer keep their absolute hierarchical paths
# and the proven constraint files apply unchanged.
compile -top_module video_fb_top -system_verilog \
        -compiler_directives "BOARD_SOC ARES_BRAM ARES_BOOT_ROM ARES_FPGA"

synthesize -ads
dev_map

if {$do_pnr} {
    pnr -seed 5
    report_timing -max_path 20
    gen_bit_stream -create_bit true
}
