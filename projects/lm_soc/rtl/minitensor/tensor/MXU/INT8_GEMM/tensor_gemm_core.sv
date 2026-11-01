`timescale 1ns/1ps

// Non-pipelined 4x4 signed INT8 GEMM. A and B are row-major packed tiles;
// the sixteen signed INT32 results remain stable until result_ready.
module tensor_gemm_core (
  input  logic clk,
  input  logic rst,
  input  logic cmd_valid,
  output logic cmd_ready,
  input  logic [tensor_pkg::TENSOR_TILE_WIDTH-1:0] cmd_a_tile,
  input  logic [tensor_pkg::TENSOR_TILE_WIDTH-1:0] cmd_b_tile,
  input  logic [tensor_pkg::TENSOR_RESULT_WIDTH-1:0] cmd_acc_init,
  output logic result_valid,
  input  logic result_ready,
  output logic [tensor_pkg::TENSOR_RESULT_WIDTH-1:0] result_data
);
  localparam int unsigned RUN_CYCLES = 10;

  typedef enum logic [1:0] {S_IDLE, S_RUN, S_RESULT} state_t;
  state_t state_q;
  logic [tensor_pkg::TENSOR_TILE_WIDTH-1:0] a_tile_q, b_tile_q;
  logic [tensor_pkg::TENSOR_RESULT_WIDTH-1:0] acc_init_q;
  logic [3:0] cycle_q;
  logic [tensor_pkg::TENSOR_RESULT_WIDTH-1:0] array_result;
  logic [tensor_pkg::TENSOR_RESULT_WIDTH-1:0] array_acc_init;

  wire cmd_fire = cmd_valid && cmd_ready;
  wire result_fire = result_valid && result_ready;

  assign cmd_ready = (state_q == S_IDLE);
  assign result_valid = (state_q == S_RESULT);
  assign result_data = array_result;
  assign array_acc_init = cmd_fire ? cmd_acc_init : acc_init_q;

  tensor_systolic_array u_array (
    .clk,
    .rst,
    .clear(cmd_fire),
    .step(state_q == S_RUN),
    .acc_init(array_acc_init),
    .cycle_index(cycle_q),
    .a_tile(a_tile_q),
    .b_tile(b_tile_q),
    .result(array_result)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= S_IDLE;
      a_tile_q <= '0;
      b_tile_q <= '0;
      acc_init_q <= '0;
      cycle_q <= '0;
    end else begin
      case (state_q)
        S_IDLE: begin
          if (cmd_fire) begin
            a_tile_q <= cmd_a_tile;
            b_tile_q <= cmd_b_tile;
            acc_init_q <= cmd_acc_init;
            cycle_q <= '0;
            state_q <= S_RUN;
          end
        end
        S_RUN: begin
          if (cycle_q == 4'(RUN_CYCLES - 1)) begin
            state_q <= S_RESULT;
          end else begin
            cycle_q <= cycle_q + 1'b1;
          end
        end
        S_RESULT: begin
          if (result_fire)
            state_q <= S_IDLE;
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end
endmodule
