`timescale 1ns/1ps
// 32 x 32-bit register file: two asynchronous read ports, one synchronous
// write port.  x0 is hard-wired to zero.
module ares_regfile (
  input  logic        clk,
  input  logic [4:0]  rs1,
  input  logic [4:0]  rs2,
  output logic [31:0] rdata1,
  output logic [31:0] rdata2,
  input  logic        we,
  input  logic [4:0]  rd,
  input  logic [31:0] wdata
);
  logic [31:0] regs [1:31];

  /* verilator lint_off UNUSEDSIGNAL */
  always_ff @(posedge clk) begin
    if (we && (rd != 5'd0)) begin
      regs[rd] <= wdata;
    end
  end
  /* verilator lint_on UNUSEDSIGNAL */

  assign rdata1 = (rs1 == 5'd0) ? 32'd0 : regs[rs1];
  assign rdata2 = (rs2 == 5'd0) ? 32'd0 : regs[rs2];
endmodule
