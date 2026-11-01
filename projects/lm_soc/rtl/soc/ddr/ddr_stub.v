// ---------------------------------------------------------------------------
// ddr_stub - placeholder for the DDR3 port when the stage does not use DDR.
//
// The simulation SoC drives a behavioural DDR3 model; the FPGA bring-up stages
// B2/B3 do not need external memory at all, so they compile with ARES_NO_DDR
// and this module answers every access with zeros after one cycle.  That keeps
// the L2 state machine and the address decode identical to the real build.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps
module ddr_stub (
    input  wire         clk,
    input  wire         rst,
    input  wire         req_valid,
    output wire         req_ready,
    input  wire         req_write,
    input  wire [31:0]  req_addr,
    input  wire [127:0] req_wdata,
    input  wire [15:0]  req_wstrb,
    output wire         rsp_valid,
    input  wire         rsp_ready,
    output wire [127:0] rsp_rdata
);
    reg busy;

    always @(posedge clk) begin
        if (rst)                         busy <= 1'b0;
        else if (req_valid && req_ready) busy <= 1'b1;
        else if (rsp_valid && rsp_ready) busy <= 1'b0;
    end

    assign req_ready = ~busy;
    assign rsp_valid = busy;
    assign rsp_rdata = 128'd0;

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = &{1'b0, req_write, req_addr, req_wdata, req_wstrb};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
