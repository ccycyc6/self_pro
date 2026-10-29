// ---------------------------------------------------------------------------
// mt_cluster_stub - port-compatible stand-in for mt_cluster.
//
// Used by the FPGA bring-up stages before the miniTensor is ported
// (compile with ARES_NO_MT).  It never issues a memory request, never raises
// an interrupt and always reports an idle/zero status, so the arbiter and the
// MMIO decode in ares_core_complex keep exactly the same shape as with the
// real cluster.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps
module mt_cluster_stub (
    input  wire         clk,
    input  wire         rst,

    input  wire         reg_wr_en,
    input  wire [2:0]   reg_wr_idx,
    input  wire [31:0]  reg_wr_data,
    input  wire         status_rd,
    output wire [31:0]  status,
    output wire [31:0]  result_data,

    output wire         l2_req_valid,
    input  wire         l2_req_ready,
    output wire         l2_req_write,
    output wire [31:0]  l2_req_addr,
    output wire [127:0] l2_req_wdata,
    output wire [15:0]  l2_req_wstrb,
    input  wire         l2_rsp_valid,
    output wire         l2_rsp_ready,
    input  wire [127:0] l2_rsp_rdata,

    output wire         mt_irq,

    output wire [31:0]  perf_dma,
    output wire [31:0]  perf_mma
);
    assign perf_dma = 32'd0;
    assign perf_mma = 32'd0;

    assign l2_req_valid = 1'b0;
    assign l2_req_write = 1'b0;
    assign l2_req_addr  = 32'd0;
    assign l2_req_wdata = 128'd0;
    assign l2_req_wstrb = 16'd0;
    assign l2_rsp_ready = 1'b1;

    assign status       = 32'd0;
    assign result_data  = 32'd0;
    assign mt_irq       = 1'b0;

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = &{1'b0, clk, rst, reg_wr_en, reg_wr_idx, reg_wr_data,
                    status_rd, l2_req_ready, l2_rsp_valid, l2_rsp_rdata};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
