`timescale 1ns/1ps

// Minimal vector instruction controller connected to the local VRF.
// One command is in flight; VRF state changes only on result handshake.
module vpu_vector_controller #(
  parameter int unsigned NUM_REGS = 32,
  parameter int unsigned VLEN = 128,
  parameter int unsigned ADDR_WIDTH = $clog2(NUM_REGS)
) (
  input logic clk,
  input logic rst,
  input logic cmd_valid,
  output logic cmd_ready,
  input logic [31:0] cmd_instr,
  input logic [3:0] cmd_id,
  input logic cmd_kill,
  output logic result_valid,
  input logic result_ready,
  output logic [3:0] result_id,
  output logic [VLEN-1:0] result_data,
  output logic [4:0] result_vd,
  input logic load_valid,
  output logic load_ready,
  input logic [ADDR_WIDTH-1:0] load_addr,
  input logic [VLEN-1:0] load_data,
  input logic [VLEN/8-1:0] load_be
);
  import vpu_pkg::*;

  typedef enum logic [1:0] { S_IDLE, S_EXEC, S_RESULT } state_t;
  state_t state_q;
  logic [1:0] op_q;
  logic [3:0] id_q;
  logic [4:0] vd_q, vs1_q, vs2_q;
  logic [VLEN-1:0] result_q;
  logic [VLEN-1:0] vrf_rs1, vrf_rs2;
  logic [VLEN-1:0] alu_result;

  wire instr_supported = is_vector_instruction(cmd_instr);
  wire cmd_fire = cmd_valid && cmd_ready && instr_supported;
  wire load_fire = load_valid && load_ready;
  wire result_fire = result_valid && result_ready && !cmd_kill;

  // Advertise readiness only for a decodable instruction.  This keeps the
  // CV-X-IF-style handshake from accepting an unsupported custom encoding.
  assign cmd_ready = (state_q == S_IDLE) && !load_valid && instr_supported;
  // The sideband VRF load has priority if it is presented together with a
  // command.  This gives each producer a deterministic handshake outcome.
  assign load_ready = (state_q == S_IDLE);
  assign result_valid = (state_q == S_RESULT) && !cmd_kill;
  assign result_id = id_q;
  assign result_data = result_q;
  assign result_vd = vd_q;

  vpu_vector_regfile #(
    .NUM_REGS(NUM_REGS), .VLEN(VLEN), .ADDR_WIDTH(ADDR_WIDTH)
  ) vrf (
    .clk(clk), .rst(rst),
    .rd0_en(state_q != S_IDLE), .rd0_addr(vs1_q), .rd0_data(vrf_rs1),
    .rd1_en(state_q != S_IDLE), .rd1_addr(vs2_q), .rd1_data(vrf_rs2),
    .wr_en(load_fire || result_fire),
    .wr_addr(load_fire ? load_addr : vd_q),
    .wr_data(load_fire ? load_data : result_q),
    .wr_be(load_fire ? load_be : {VLEN/8{1'b1}})
  );

  vpu_vector_alu #(.VLEN(VLEN)) alu (
    .op(op_q), .a(vrf_rs1), .b(vrf_rs2), .result(alu_result)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= S_IDLE;
      op_q <= VPU_VEC_OP_INVALID;
      id_q <= '0;
      vd_q <= '0;
      vs1_q <= '0;
      vs2_q <= '0;
      result_q <= '0;
    end else begin
      case (state_q)
        S_IDLE: begin
          if (load_fire) begin
            state_q <= S_IDLE;
          end else if (cmd_fire) begin
            op_q <= decode_vector_op(cmd_instr);
            id_q <= cmd_id;
            vd_q <= cmd_instr[11:7];
            vs1_q <= cmd_instr[19:15];
            vs2_q <= cmd_instr[24:20];
            state_q <= S_EXEC;
          end
        end
        S_EXEC: begin
          if (cmd_kill) begin
            state_q <= S_IDLE;
          end else begin
            result_q <= alu_result;
            state_q <= S_RESULT;
          end
        end
        S_RESULT: begin
          if (cmd_kill || result_fire)
            state_q <= S_IDLE;
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end
endmodule
