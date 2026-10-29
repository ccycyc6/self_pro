`timescale 1ns/1ps
// ARES simulation SoC: one ARES-L RV32IM core with its instruction cache and
// one miniTensor accelerator, a cacheless memory subsystem (Boot ROM, 192 KiB
// scratchpad, DDR3 model) and UART/GPIO/CLINT.  The configuration is aimed at
// the packed-INT8 YOLO detector; board pins and video are intentionally absent.
module ares_soc #(
  parameter logic [31:0] RESET_PC      = 32'h0000_0000,
  parameter              DDR_FILE      = "",
  parameter int unsigned L1_BYTES      = 8192,
  parameter int unsigned SCRATCH_WORDS = 12288,
  parameter int unsigned ROM_WORDS     = 16384,
  parameter int unsigned DDR_WORDS     = 2048
) (
  input  logic        clk,
  input  logic        rst,

  input  logic        uart_rx,
  output logic        uart_tx,
  input  logic [31:0] gpio_in,
  output logic [31:0] gpio_out,
  output logic [31:0] gpio_dir,

  // Camera thumbnail window (B7)
  output logic [10:0] cam_addr,
  output logic        cam_bank,
  input  logic [15:0] cam_data,
  input  logic [31:0] cam_frame,
  input  logic [31:0] cam_wrcnt,

  output logic        mt_irq,
  output logic        dbg_halt,
  output logic [31:0] dbg_pc,
  output logic        dbg_commit,
  output logic [31:0] dbg_pc_f,
  output logic        dbg_ifid_valid,
  output logic        dbg_idex_valid,
  output logic        dbg_exmem_valid,
  output logic        dbg_memwb_valid,
  output logic        dbg_if_pending
);
  import ares_pkg::*;

  logic        l2_req_valid, l2_req_ready, l2_req_write;
  logic [31:0] l2_req_addr;
  logic [127:0] l2_req_wdata, l2_rsp_rdata;
  logic [15:0] l2_req_wstrb;
  logic        l2_rsp_valid, l2_rsp_ready;

  logic        ddr_req_valid, ddr_req_ready, ddr_req_write;
  logic [31:0] ddr_req_addr;
  logic [127:0] ddr_req_wdata;
  logic [15:0] ddr_req_wstrb;
  logic        ddr_rsp_valid, ddr_rsp_ready;
  logic [127:0] ddr_rsp_rdata;

  logic        mmio_req_valid, mmio_req_ready, mmio_req_write;
  logic [31:0] mmio_req_addr, mmio_req_wdata;
  logic [3:0]  mmio_req_wstrb;
  logic        mmio_rsp_valid, mmio_rsp_ready;
  logic [31:0] mmio_rsp_rdata;

  logic        irq_timer, irq_soft;

  ares_core_complex #(
    .RESET_PC(RESET_PC),
    .L1_BYTES(L1_BYTES)
  ) u_core_complex (
    .clk, .rst,
    .l2_req_valid, .l2_req_ready, .l2_req_write, .l2_req_addr,
    .l2_req_wdata, .l2_req_wstrb, .l2_rsp_valid, .l2_rsp_ready, .l2_rsp_rdata,
    .irq_timer, .irq_soft, .mt_irq,
    .dbg_pc, .dbg_instr(), .dbg_commit, .dbg_halt,
    .dbg_pc_f, .dbg_ifid_valid, .dbg_idex_valid, .dbg_exmem_valid,
    .dbg_memwb_valid, .dbg_if_pending
  );

  ares_l2 #(
    .SCRATCH_WORDS(SCRATCH_WORDS),
    .ROM_WORDS(ROM_WORDS)
  ) u_l2 (
    .clk, .rst,
    .req_valid(l2_req_valid), .req_ready(l2_req_ready),
    .req_write(l2_req_write), .req_addr(l2_req_addr),
    .req_wdata(l2_req_wdata), .req_wstrb(l2_req_wstrb),
    .rsp_valid(l2_rsp_valid), .rsp_ready(l2_rsp_ready), .rsp_rdata(l2_rsp_rdata),
    .ddr_req_valid, .ddr_req_ready, .ddr_req_write, .ddr_req_addr,
    .ddr_req_wdata, .ddr_req_wstrb, .ddr_rsp_valid, .ddr_rsp_ready, .ddr_rsp_rdata,
    .mmio_req_valid, .mmio_req_ready, .mmio_req_write, .mmio_req_addr,
    .mmio_req_wdata, .mmio_req_wstrb, .mmio_rsp_valid, .mmio_rsp_ready, .mmio_rsp_rdata
  );

`ifdef ARES_NO_DDR
  // Bring-up builds that do not use external memory answer DDR accesses with
  // zeros after one cycle, keeping the L2 decode identical.  Spelled out in
  // full because the ADS preparer cannot expand the first implicit .port of a
  // list that starts right after an `endif.
  ddr_stub u_ddr (
    .clk, .rst,
    .req_valid(ddr_req_valid), .req_ready(ddr_req_ready), .req_write(ddr_req_write),
    .req_addr(ddr_req_addr), .req_wdata(ddr_req_wdata), .req_wstrb(ddr_req_wstrb),
    .rsp_valid(ddr_rsp_valid), .rsp_ready(ddr_rsp_ready), .rsp_rdata(ddr_rsp_rdata)
  );
`elsif ARES_BRAM
  // B3: the same beat protocol, backed by on-chip block RAM instead of DDR3.
  ddr_bram #(.WORDS(DDR_WORDS)) u_ddr (
    .clk, .rst,
    .req_valid(ddr_req_valid), .req_ready(ddr_req_ready), .req_write(ddr_req_write),
    .req_addr(ddr_req_addr), .req_wdata(ddr_req_wdata), .req_wstrb(ddr_req_wstrb),
    .rsp_valid(ddr_rsp_valid), .rsp_ready(ddr_rsp_ready), .rsp_rdata(ddr_rsp_rdata)
  );
`else
  ddr3_model #(.DDR_FILE(DDR_FILE)) u_ddr (
    .clk, .rst,
    .req_valid(ddr_req_valid), .req_ready(ddr_req_ready), .req_write(ddr_req_write),
    .req_addr(ddr_req_addr), .req_wdata(ddr_req_wdata), .req_wstrb(ddr_req_wstrb),
    .rsp_valid(ddr_rsp_valid), .rsp_ready(ddr_rsp_ready), .rsp_rdata(ddr_rsp_rdata)
  );
`endif

  ares_mmio_bus u_mmio (
    .clk, .rst,
    .req_valid(mmio_req_valid), .req_ready(mmio_req_ready), .req_write(mmio_req_write),
    .req_addr(mmio_req_addr), .req_wdata(mmio_req_wdata), .req_wstrb(mmio_req_wstrb),
    .rsp_valid(mmio_rsp_valid), .rsp_ready(mmio_rsp_ready), .rsp_rdata(mmio_rsp_rdata),
    .timer_irq(irq_timer), .soft_irq(irq_soft),
    .uart_tx, .uart_rx, .gpio_in, .gpio_out, .gpio_dir,
    .cam_addr, .cam_bank, .cam_data, .cam_frame, .cam_wrcnt
  );
endmodule
