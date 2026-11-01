# ---------------------------------------------------------------------------
# flow_smoke.tcl - first-stage board smoke test (PG2L200H-6IFBB676)
#
# Top: rtl/board/board_smoke.v  (27 MHz -> UART heartbeat + LED, no CPU)
#
# Run from a scratch build directory so PDS does not pollute the source tree:
#
#   cd build\pango\smoke
#   D:\PDS_2022.2-SP6.4\bin\pds_shell.exe -file E:\qs\5-stage-baseline\fpga\pango\flow_smoke.tcl -project_name smoke
#
# Set do_pnr to 0 for a fast resource/parse check (compile+synth+dev_map only).
# ---------------------------------------------------------------------------
set do_pnr 1

set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here ".." ".."]]

puts "smoke: here   = $here"
puts "smoke: root   = $root"
puts "smoke: workdir= [pwd]"

set_arch -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6

add_constraint [file join $here "board_pins.fdc"]

add_design [file join $root "rtl" "board" "board_smoke.v"]

compile -top_module board_smoke

synthesize -ads

dev_map

if {$do_pnr} {
    pnr
    report_timing -max_path 20
    gen_bit_stream -create_bit true
}
