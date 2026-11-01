`timescale 1ns/1ps

package vpu_pkg;

  localparam logic [6:0] VPU_CUSTOM0_OPCODE = 7'b0001011;
  localparam logic [6:0] VPU_VECTOR_FUNCT7  = 7'b0000010;

  localparam logic [2:0] VPU_VECTOR_FUNCT3_ADD8  = 3'b000;
  localparam logic [2:0] VPU_VECTOR_FUNCT3_MAX8  = 3'b001;
  localparam logic [2:0] VPU_VECTOR_FUNCT3_RELU8 = 3'b010;

  localparam logic [1:0] VPU_VEC_OP_ADD8    = 2'd0;
  localparam logic [1:0] VPU_VEC_OP_MAX8    = 2'd1;
  localparam logic [1:0] VPU_VEC_OP_RELU8   = 2'd2;
  localparam logic [1:0] VPU_VEC_OP_INVALID = 2'd3;

  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic is_vector_instruction(input logic [31:0] instr);
    is_vector_instruction =
        (instr[6:0] == VPU_CUSTOM0_OPCODE) &&
        (instr[31:25] == VPU_VECTOR_FUNCT7) &&
        ((instr[14:12] == VPU_VECTOR_FUNCT3_ADD8) ||
         (instr[14:12] == VPU_VECTOR_FUNCT3_MAX8) ||
         (instr[14:12] == VPU_VECTOR_FUNCT3_RELU8));
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  function automatic logic [1:0] decode_vector_op(input logic [31:0] instr);
    if (!is_vector_instruction(instr)) begin
      decode_vector_op = VPU_VEC_OP_INVALID;
    end else if (instr[14:12] == VPU_VECTOR_FUNCT3_ADD8) begin
      decode_vector_op = VPU_VEC_OP_ADD8;
    end else if (instr[14:12] == VPU_VECTOR_FUNCT3_MAX8) begin
      decode_vector_op = VPU_VEC_OP_MAX8;
    end else begin
      decode_vector_op = VPU_VEC_OP_RELU8;
    end
  endfunction

  function automatic logic [31:0] make_vector_rtype(
      input logic [2:0] funct3,
      input logic [4:0] vd,
      input logic [4:0] vs1,
      input logic [4:0] vs2);
    make_vector_rtype = {
      VPU_VECTOR_FUNCT7,
      vs2,
      vs1,
      funct3,
      vd,
      VPU_CUSTOM0_OPCODE
    };
  endfunction

endpackage
