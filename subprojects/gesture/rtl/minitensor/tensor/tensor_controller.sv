`timescale 1ns/1ps

// Moves one 4x4 INT8 A tile and one B tile from the synchronous UB into the
// GEMM core, then writes four 128-bit rows of signed INT32 results back.
module tensor_controller #(
  parameter int unsigned UB_ADDR_WIDTH = 8
) (
  input  logic clk,
  input  logic rst,
  input  logic cmd_valid,
  output logic cmd_ready,
  input  logic [UB_ADDR_WIDTH-1:0] cmd_a_addr,
  input  logic [UB_ADDR_WIDTH-1:0] cmd_b_addr,
  input  logic [UB_ADDR_WIDTH-1:0] cmd_c_addr,
  input  logic cmd_accumulate,
  output logic busy,
  output logic done,

  output logic ub_rd_en,
  output logic [UB_ADDR_WIDTH-1:0] ub_rd_addr,
  input  logic ub_rd_valid,
  input  logic [tensor_pkg::TENSOR_TILE_WIDTH-1:0] ub_rd_data,
  output logic ub_wr_en,
  output logic [UB_ADDR_WIDTH-1:0] ub_wr_addr,
  output logic [tensor_pkg::TENSOR_TILE_WIDTH-1:0] ub_wr_data,
  output logic [15:0] ub_wr_be
);
  typedef enum logic [3:0] {
    S_IDLE,
    S_READ_A,
    S_WAIT_A,
    S_READ_B,
    S_WAIT_B,
    S_READ_C,
    S_WAIT_C,
    S_CORE_START,
    S_CORE_WAIT,
    S_WRITE,
    S_DONE
  } state_t;

  state_t state_q;
  logic [UB_ADDR_WIDTH-1:0] a_addr_q, b_addr_q, c_addr_q;
  logic accumulate_q;
  logic [tensor_pkg::TENSOR_TILE_WIDTH-1:0] a_tile_q, b_tile_q;
  logic [tensor_pkg::TENSOR_RESULT_WIDTH-1:0] acc_init_q;
  logic [1:0] c_read_index_q;
  logic [tensor_pkg::TENSOR_RESULT_WIDTH-1:0] result_q;
  logic [1:0] write_index_q;
  logic core_cmd_valid, core_cmd_ready;
  logic core_result_valid, core_result_ready;
  logic [tensor_pkg::TENSOR_RESULT_WIDTH-1:0] core_result_data;

  wire cmd_fire = cmd_valid && cmd_ready;
  wire core_cmd_fire = core_cmd_valid && core_cmd_ready;
  wire core_result_fire = core_result_valid && core_result_ready;

  assign cmd_ready = (state_q == S_IDLE);
  assign busy = (state_q != S_IDLE);
  assign done = (state_q == S_DONE);
  assign ub_rd_en = (state_q == S_READ_A) || (state_q == S_READ_B) ||
      (state_q == S_READ_C);
  assign ub_rd_addr = (state_q == S_READ_A) ? a_addr_q :
      ((state_q == S_READ_B) ? b_addr_q : c_addr_q + UB_ADDR_WIDTH'(c_read_index_q));
  assign ub_wr_en = (state_q == S_WRITE);
  assign ub_wr_addr = c_addr_q + UB_ADDR_WIDTH'(write_index_q);
  assign ub_wr_data = result_q[128 * write_index_q +: 128];
  assign ub_wr_be = '1;
  assign core_cmd_valid = (state_q == S_CORE_START);
  assign core_result_ready = (state_q == S_CORE_WAIT);

  tensor_gemm_core u_gemm_core (
    .clk,
    .rst,
    .cmd_valid(core_cmd_valid),
    .cmd_ready(core_cmd_ready),
    .cmd_a_tile(a_tile_q),
    .cmd_b_tile(b_tile_q),
    .cmd_acc_init(acc_init_q),
    .result_valid(core_result_valid),
    .result_ready(core_result_ready),
    .result_data(core_result_data)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= S_IDLE;
      a_addr_q <= '0;
      b_addr_q <= '0;
      c_addr_q <= '0;
      accumulate_q <= 1'b0;
      a_tile_q <= '0;
      b_tile_q <= '0;
      acc_init_q <= '0;
      c_read_index_q <= '0;
      result_q <= '0;
      write_index_q <= '0;
    end else begin
      case (state_q)
        S_IDLE: begin
          if (cmd_fire) begin
            a_addr_q <= cmd_a_addr;
            b_addr_q <= cmd_b_addr;
            c_addr_q <= cmd_c_addr;
            accumulate_q <= cmd_accumulate;
            acc_init_q <= '0;
            c_read_index_q <= '0;
            state_q <= S_READ_A;
          end
        end
        S_READ_A: state_q <= S_WAIT_A;
        S_WAIT_A: begin
          if (ub_rd_valid) begin
            a_tile_q <= ub_rd_data;
            state_q <= S_READ_B;
          end
        end
        S_READ_B: state_q <= S_WAIT_B;
        S_WAIT_B: begin
          if (ub_rd_valid) begin
            b_tile_q <= ub_rd_data;
            if (accumulate_q)
              state_q <= S_READ_C;
            else
              state_q <= S_CORE_START;
          end
        end
        S_READ_C: state_q <= S_WAIT_C;
        S_WAIT_C: begin
          if (ub_rd_valid) begin
            acc_init_q[128 * c_read_index_q +: 128] <= ub_rd_data;
            if (c_read_index_q == 2'd3) begin
              c_read_index_q <= '0;
              state_q <= S_CORE_START;
            end else begin
              c_read_index_q <= c_read_index_q + 1'b1;
              state_q <= S_READ_C;
            end
          end
        end
        S_CORE_START: begin
          if (core_cmd_fire)
            state_q <= S_CORE_WAIT;
        end
        S_CORE_WAIT: begin
          if (core_result_fire) begin
            result_q <= core_result_data;
            write_index_q <= '0;
            state_q <= S_WRITE;
          end
        end
        S_WRITE: begin
          if (write_index_q == 2'd3) begin
            state_q <= S_DONE;
          end else begin
            write_index_q <= write_index_q + 1'b1;
          end
        end
        S_DONE: state_q <= S_IDLE;
        default: state_q <= S_IDLE;
      endcase
    end
  end
endmodule
