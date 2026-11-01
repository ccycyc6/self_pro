// ---------------------------------------------------------------------------
// ARES video subsystem v1 - shared constants
//
// Verilog-2001 only.  This header is included by every new video module and by
// the PDS/Vivado file lists.  It must stay free of SystemVerilog constructs.
//
// Frozen by docs/video_subsystem_v1_design.md.
// ---------------------------------------------------------------------------
`ifndef VIDEO_DEFS_VH
`define VIDEO_DEFS_VH

// --------------------------------------------------------------- geometry
`define VIDEO_H_ACT        12'd1280
`define VIDEO_V_ACT        12'd720
`define VIDEO_PIX_BITS     16

// 720p30 timing (matches legacy sync_vg.v)
`define VIDEO_H_TOTAL      12'd1650
`define VIDEO_H_SYNC       12'd40
`define VIDEO_H_BP         12'd220
`define VIDEO_H_FP         12'd110
`define VIDEO_V_TOTAL      12'd750
`define VIDEO_V_SYNC       12'd5
`define VIDEO_V_BP         12'd20
`define VIDEO_V_FP         12'd5

// ---------------------------------------------------------------- clocks
`define VIDEO_CLK_SYS_HZ   27000000
`define VIDEO_CLK_PIX_HZ   37125000
`define VIDEO_CLK_CFG_HZ   10000000
`define VIDEO_CLK_CAM_HZ   24750000
`define VIDEO_CLK_DDR_HZ   125000000

// ------------------------------------------------------- bring-up stages
`define VIDEO_STAGE_PATTERN  2'd0
`define VIDEO_STAGE_CAPTURE  2'd1
`define VIDEO_STAGE_FRAMEBUF 2'd2
`define VIDEO_STAGE_BIST     2'd3

// Override from the PDS/Verilator command line with +define+VIDEO_STAGE_SEL=2.
`ifndef VIDEO_STAGE_SEL
`define VIDEO_STAGE_SEL `VIDEO_STAGE_CAPTURE
`endif

// -------------------------------------------------------------- patterns
`define VIDEO_PAT_OFF        2'd0
`define VIDEO_PAT_BAR        2'd1
`define VIDEO_PAT_CHECKER    2'd2
`define VIDEO_PAT_MOVING_BOX 2'd3

// ----------------------------------------------------------- frame buffer
// Byte addresses.  FB_BASE1 = FB_BASE0 + 16 MiB (legacy frame bit 22).
`define VIDEO_FB_BASE0_BYTE  28'h0100_0000
`define VIDEO_FB_BASE1_BYTE  28'h0110_0000
`define VIDEO_FB_SPAN_BYTE   28'h0200_0000   // reserve 32 MiB

// Byte -> legacy address unit.  Default 2 (32-bit words); BIST confirms.
`ifndef VIDEO_FB_ADDR_SHIFT
`define VIDEO_FB_ADDR_SHIFT  2
`endif

`define VIDEO_FB_STRIDE      32'd2560       // 1280 * 2 bytes
`define VIDEO_FB_WIDTH       12'd1280
`define VIDEO_FB_HEIGHT      12'd720

// ------------------------------------------------------------- DDR3 BIST
`define VIDEO_BIST_BYTES     32'h0040_0000   // quick test: first 4 MiB
`define VIDEO_BIST_BURST     4'd15           // 16-beat bursts
`define VIDEO_BIST_BEAT_BYTES 32

// --------------------------------------------------------------- status
`define VIDEO_ST_PLL_LOCK       0
`define VIDEO_ST_DDR_INIT_DONE  1
`define VIDEO_ST_HDMI_INIT_DONE 2
`define VIDEO_ST_CAM_INIT_DONE  3
`define VIDEO_ST_FRAME_WR_DONE  4
`define VIDEO_ST_FRAME_DROP     5
`define VIDEO_ST_FIFO_OVERFLOW  6
`define VIDEO_ST_BIST_DONE      7
`define VIDEO_ST_BIST_ERROR     8
`define VIDEO_ST_BIST_ERR_SHIFT 16            // [31:16] error count low bits

// ---------------------------------------------------------------- UART
`define VIDEO_UART_DIV       16'd234          // 115200 @ 27 MHz
`define VIDEO_UART_PERIOD    24'd13_500_000   // ~0.5 s at 27 MHz

// --------------------------------------------------------------- LED map
`define VIDEO_LED_HEARTBEAT  0
`define VIDEO_LED_PLL        1
`define VIDEO_LED_DDR        2
`define VIDEO_LED_HDMI       3
`define VIDEO_LED_CAM        4
`define VIDEO_LED_FRAME      5
`define VIDEO_LED_DROP       6
`define VIDEO_LED_ERROR      7

`endif // VIDEO_DEFS_VH
