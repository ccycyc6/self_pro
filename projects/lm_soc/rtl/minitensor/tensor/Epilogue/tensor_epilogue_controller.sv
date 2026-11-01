`timescale 1ns/1ps

// Reads four C rows, four bias rows, and one quantization-config row from UB,
// then writes one packed INT8 output row.
module tensor_epilogue_controller #(
  parameter int unsigned UB_ADDR_WIDTH = 8
) (
  input  logic clk,
  input  logic rst,
  input  logic cmd_valid,
  output logic cmd_ready,
  input  logic [UB_ADDR_WIDTH-1:0] cmd_c_addr,
  input  logic [UB_ADDR_WIDTH-1:0] cmd_bias_addr,
  input  logic [UB_ADDR_WIDTH-1:0] cmd_config_addr,
  input  logic [UB_ADDR_WIDTH-1:0] cmd_output_addr,
  output logic busy,
  output logic done,
  output logic ub_rd_en,
  output logic [UB_ADDR_WIDTH-1:0] ub_rd_addr,
  input  logic ub_rd_valid,
  input  logic [127:0] ub_rd_data,
  output logic ub_wr_en,
  output logic [UB_ADDR_WIDTH-1:0] ub_wr_addr,
  output logic [127:0] ub_wr_data,
  output logic [15:0] ub_wr_be
);
  typedef enum logic [3:0] {
    S_IDLE, S_READ_C, S_WAIT_C, S_READ_B, S_WAIT_B,
    S_READ_CFG, S_WAIT_CFG, S_WRITE, S_DONE
  } state_t;
  state_t state_q;
  logic [UB_ADDR_WIDTH-1:0] c_addr_q, bias_addr_q, config_addr_q, output_addr_q;
  logic [1:0] row_q;
  logic [511:0] c_data_q, bias_data_q;
  logic [127:0] config_data_q, output_data;

  tensor_epilogue_core u_core (
    .c_data(c_data_q), .bias_data(bias_data_q),
    .config_data(config_data_q), .output_data
  );

  assign cmd_ready = (state_q == S_IDLE);
  assign busy = (state_q != S_IDLE);
  assign done = (state_q == S_DONE);
  assign ub_rd_en = (state_q == S_READ_C) || (state_q == S_READ_B) ||
      (state_q == S_READ_CFG);
  assign ub_rd_addr = (state_q == S_READ_C) ? c_addr_q + UB_ADDR_WIDTH'(row_q) :
      ((state_q == S_READ_B) ? bias_addr_q + UB_ADDR_WIDTH'(row_q) : config_addr_q);
  assign ub_wr_en = (state_q == S_WRITE);
  assign ub_wr_addr = output_addr_q;
  assign ub_wr_data = output_data;
  assign ub_wr_be = '1;

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= S_IDLE;
      c_addr_q <= '0;
      bias_addr_q <= '0;
      config_addr_q <= '0;
      output_addr_q <= '0;
      row_q <= '0;
      c_data_q <= '0;
      bias_data_q <= '0;
      config_data_q <= '0;
    end else begin
      case (state_q)
        S_IDLE: if (cmd_valid && cmd_ready) begin
          c_addr_q <= cmd_c_addr;
          bias_addr_q <= cmd_bias_addr;
          config_addr_q <= cmd_config_addr;
          output_addr_q <= cmd_output_addr;
          row_q <= '0;
          state_q <= S_READ_C;
        end
        S_READ_C: state_q <= S_WAIT_C;
        S_WAIT_C: if (ub_rd_valid) begin
          c_data_q[128*row_q +: 128] <= ub_rd_data;
          if (row_q == 2'd3) begin row_q <= '0; state_q <= S_READ_B; end
          else begin row_q <= row_q + 1'b1; state_q <= S_READ_C; end
        end
        S_READ_B: state_q <= S_WAIT_B;
        S_WAIT_B: if (ub_rd_valid) begin
          bias_data_q[128*row_q +: 128] <= ub_rd_data;
          if (row_q == 2'd3) begin row_q <= '0; state_q <= S_READ_CFG; end
          else begin row_q <= row_q + 1'b1; state_q <= S_READ_B; end
        end
        S_READ_CFG: state_q <= S_WAIT_CFG;
        S_WAIT_CFG: if (ub_rd_valid) begin
          config_data_q <= ub_rd_data;
          state_q <= S_WRITE;
        end
        S_WRITE: state_q <= S_DONE;
        S_DONE: state_q <= S_IDLE;
        default: state_q <= S_IDLE;
      endcase
    end
  end
endmodule
