# ---------------------------------------------------------------------------
# flow_soc.tcl - CPU bring-up stages (B2 / B3 / B4 / B5), no video.
#
# Top: rtl/board/board_cpu.v  (Verilog-2001)
#      calls ares_soc, which is SystemVerilog and is pre-converted by
#      tools/pango_prep.py into build/pango/syn/rtl/**/*.v
#
#   ARES_STAGE=b2  CPU + ROM + UART, no memory model
#   ARES_STAGE=b3  + BRAM behind the DDR port (self-test)
#   ARES_STAGE=b4  same as b3, boot loader firmware
#   ARES_STAGE=b5  + miniTensor (MMIO shim + accelerator)
#
# Environment:
#   ARES_STAGE   b2 (default) | b3 | b4 | b5
#   ARES_NO_PNR  1  -> stop after dev_map (fast check)
# ---------------------------------------------------------------------------
set stage "b2"
if {[info exists ::env(ARES_STAGE)]} { set stage $::env(ARES_STAGE) }

set do_pnr 1
if {[info exists ::env(ARES_NO_PNR)]} { set do_pnr 0 }

set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here ".." ".."]]
set syn  [file join $root "build" "pango" "syn" "rtl"]

puts "soc: stage=$stage"
puts "soc: workdir=[pwd]"

set_arch -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6
add_constraint [file join $here "board_pins.fdc"]

proc walk {dir} {
  set out {}
  foreach f [lsort [glob -nocomplain -directory $dir *]] {
    if {[file isdirectory $f]} { set out [concat $out [walk $f]] } \
    elseif {[string match "*.v" $f]} { lappend out $f }
  }
  return $out
}

# ---------------------------------------------------------------------------
if {$stage eq "b5"} {
    set defs "ARES_BRAM ARES_BOOT_ROM ARES_FPGA"
    set pkgs [list common/ares_pkg.v minitensor/common/minitensor_pkg.v \
              minitensor/tensor/tensor_pkg.v minitensor/vector/vpu_pkg.v]
    foreach p $pkgs { add_design [file join $syn $p] }
    foreach f [walk $syn] {
        set skip 0
        foreach p $pkgs { if {[string match "*/$p" $f]} { set skip 1 } }
        if {!$skip} { add_design $f }
    }
} else {
    if {$stage eq "b3" || $stage eq "b4"} {
        set defs "ARES_NO_MT ARES_BRAM ARES_BOOT_ROM ARES_FPGA"
    } else {
        set defs "ARES_NO_MT ARES_NO_DDR ARES_BOOT_ROM ARES_FPGA"
    }
    add_design [file join $syn "common" "ares_pkg.v"]
    foreach f [list \
        "core/ares_regfile.v" "core/ares_muldiv.v" "core/ares_bpu.v" \
        "core/ares_csr.v" "core/ares_l_core.v" \
        "cache/ares_l1i.v" "cache/ares_dmem.v" \
        "soc/ares_clint.v" "soc/ares_uart.v" "soc/ares_gpio.v" \
        "soc/ares_mmio_bus.v" "soc/ares_l2.v" "soc/ares_core_complex.v" \
        "soc/ares_soc.v" ] {
        add_design [file join $syn $f]
    }
    add_design [file join $root "rtl" "soc" "mt"  "mt_cluster_stub.v"]
}

add_design [file join $root "rtl" "soc" "ddr" "ddr_stub.v"]
add_design [file join $root "rtl" "soc" "ddr" "ddr_bram.v"]
add_design [file join $root "rtl" "board" "boot_rom.v"]
add_design [file join $root "rtl" "board" "board_cpu.v"]

compile -top_module board_cpu -system_verilog -compiler_directives $defs

synthesize -ads
dev_map

if {$do_pnr} {
    pnr
    report_timing -max_path 20
    gen_bit_stream -create_bit true
}
