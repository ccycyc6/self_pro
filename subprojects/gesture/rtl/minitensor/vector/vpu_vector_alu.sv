`timescale 1ns/1ps

// 128-bit packed INT8 vector ALU: sixteen independent byte lanes.
module vpu_vector_alu #(
  parameter int unsigned VLEN = 128
) (
  input logic [1:0] op,
  input logic [VLEN-1:0] a,
  input logic [VLEN-1:0] b,
  output logic [VLEN-1:0] result
);
  import vpu_pkg::*;
  integer i;
  logic signed [7:0] as, bs;

  always_comb begin
    result = '0;
    for (i = 0; i < VLEN/8; i = i + 1) begin
      as = a[8*i +: 8];
      bs = b[8*i +: 8];
      case (op)
        VPU_VEC_OP_ADD8:  result[8*i +: 8] = a[8*i +: 8] + b[8*i +: 8];
        VPU_VEC_OP_MAX8:  result[8*i +: 8] = (as > bs) ? as : bs;
        VPU_VEC_OP_RELU8: result[8*i +: 8] = (as > 0) ? as : 8'h00;
        default:          result[8*i +: 8] = 8'h00;
      endcase
    end
  end
endmodule
