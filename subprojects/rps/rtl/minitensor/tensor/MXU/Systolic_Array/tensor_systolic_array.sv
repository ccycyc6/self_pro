`timescale 1ns/1ps

// Fixed 4x4 output-stationary array. The controller supplies a cycle index;
// this block skews row-major A and B tiles onto the array boundaries.
module tensor_systolic_array (
  input  logic clk,
  input  logic rst,
  input  logic clear,
  input  logic step,
  input  logic [tensor_pkg::TENSOR_RESULT_WIDTH-1:0] acc_init,
  input  logic [3:0] cycle_index,
  input  logic [tensor_pkg::TENSOR_TILE_WIDTH-1:0] a_tile,
  input  logic [tensor_pkg::TENSOR_TILE_WIDTH-1:0] b_tile,
  output logic [tensor_pkg::TENSOR_RESULT_WIDTH-1:0] result
);
  localparam int unsigned DIM = tensor_pkg::TENSOR_DIM;

  logic signed [7:0] a_boundary [0:DIM-1];
  logic signed [7:0] b_boundary [0:DIM-1];
  logic signed [7:0] a_in [0:DIM-1][0:DIM-1];
  logic signed [7:0] b_in [0:DIM-1][0:DIM-1];
  logic signed [7:0] a_pipe [0:DIM-1][0:DIM-1];
  logic signed [7:0] b_pipe [0:DIM-1][0:DIM-1];
  logic signed [31:0] acc [0:DIM-1][0:DIM-1];
  integer row, col, k_index;

  always_comb begin
    for (row = 0; row < DIM; row = row + 1) begin
      a_boundary[row] = '0;
      k_index = integer'(cycle_index) - row;
      if ((k_index >= 0) && (k_index < DIM))
        a_boundary[row] = a_tile[8 * (row * DIM + k_index) +: 8];
    end
    for (col = 0; col < DIM; col = col + 1) begin
      b_boundary[col] = '0;
      k_index = integer'(cycle_index) - col;
      if ((k_index >= 0) && (k_index < DIM))
        b_boundary[col] = b_tile[8 * (k_index * DIM + col) +: 8];
    end
  end

  generate
    for (genvar r = 0; r < DIM; r = r + 1) begin : gen_rows
      for (genvar c = 0; c < DIM; c = c + 1) begin : gen_cols
        if (c == 0) begin : gen_a_boundary
          always_comb a_in[r][c] = a_boundary[r];
        end else begin : gen_a_neighbor
          always_comb a_in[r][c] = a_pipe[r][c-1];
        end
        if (r == 0) begin : gen_b_boundary
          always_comb b_in[r][c] = b_boundary[c];
        end else begin : gen_b_neighbor
          always_comb b_in[r][c] = b_pipe[r-1][c];
        end

        tensor_pe u_pe (
          .clk,
          .rst,
          .clear,
          .step,
          .acc_init(acc_init[32 * (r * DIM + c) +: 32]),
          .a_in(a_in[r][c]),
          .b_in(b_in[r][c]),
          .a_out(a_pipe[r][c]),
          .b_out(b_pipe[r][c]),
          .acc_out(acc[r][c])
        );

        always_comb result[32 * (r * DIM + c) +: 32] = acc[r][c];
      end
    end
  endgenerate
endmodule
