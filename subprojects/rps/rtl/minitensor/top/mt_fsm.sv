`timescale 1ns/1ps
import minitensor_pkg::*;
import tensor_pkg::*;

// ---------------------------------------------------------------------------
// mt_fsm - miniTensor top-level command sequencer.
//
// Split out of mini_tensor_top because Pango ADS aborts with an internal error
// (Flow-0189) on the single-module form; the split keeps the controller and the
// datapath small enough for the front end.  Behaviour is unchanged.
//
// One committed command at a time:
//   issue (accept) -> register (operands) -> commit -> dispatch -> operation
//   -> result handshake -> idle
// ---------------------------------------------------------------------------
module mt_fsm #(
  parameter int unsigned UB_ADDR_WIDTH = 8,
  parameter int unsigned COUNT_WIDTH   = 8
) (
  input  logic clk,
  input  logic rst,

  // CV-X-IF issue / commit side (already decoded by the datapath)
  input  logic        issue_fire,
  input  logic [3:0]  issue_id,
  input  logic        issue_hartid,
  input  logic [4:0]  issue_rd,
  input  logic [2:0]  issue_funct3,
  input  logic        issue_load,
  input  logic        issue_store,
  input  logic        issue_tensor,
  input  logic        issue_epilogue,
  input  logic        register_fire,
  input  logic        register_match,
  input  logic        register_operands_valid,
  input  logic [31:0] reg_rs0,
  input  logic [31:0] reg_rs1,
  input  logic        commit_fire,
  input  logic        kill_fire,
  input  logic        operands_valid,
  input  logic        result_taken,

  // submodule handshakes
  input  logic        dma_cmd_ready,
  input  logic        dma_done,
  input  logic        tensor_cmd_ready,
  input  logic        tensor_done,
  input  logic        ep_cmd_ready,
  input  logic        ep_done,
  input  logic        vector_cmd_ready,
  input  logic        vector_load_valid,
  input  logic        vector_load_ready,
  input  logic        vector_result_fire,

  // sequencer state and operand registers
  output state_t      state_q,
  output op_t         op_q,
  output logic [3:0]  id_q,
  output logic        hartid_q,
  output logic [4:0]  rd_q,
  output logic [31:0] mem_addr_q,
  output logic [UB_ADDR_WIDTH-1:0] ub_base_q,
  output logic [COUNT_WIDTH-1:0]   tile_count_q,
  output logic [UB_ADDR_WIDTH-1:0] vec_src_a_q,
  output logic [UB_ADDR_WIDTH-1:0] vec_src_b_q,
  output logic [UB_ADDR_WIDTH-1:0] vec_dst_q,
  output logic [2:0]  vec_funct3_q,
  output logic        tensor_accumulate_q,
  output logic [UB_ADDR_WIDTH-1:0] ep_config_addr_q,
  output logic [31:0] rs1_q,
  output logic [31:0] rs2_q,
  output logic        register_seen_q,
  output logic        committed_q,
  output logic        command_err_q,

  // strobes that depend only on the state
  output logic        dma_cmd_valid,
  output logic        dma_cmd_write,
  output logic        tensor_cmd_valid,
  output logic        ep_cmd_valid,
  output logic        vector_cmd_valid
);
  assign dma_cmd_valid    = (state_q == S_DMA_START);
  assign dma_cmd_write    = (op_q == OP_STORE);
  assign tensor_cmd_valid = (state_q == S_TENSOR_START);
  assign ep_cmd_valid     = (state_q == S_EPILOGUE_START);
  assign vector_cmd_valid = (state_q == S_VEC_COMMAND);

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= S_IDLE;
      op_q <= OP_LOAD;
      id_q <= '0;
      hartid_q <= '0;
      rd_q <= '0;
      mem_addr_q <= '0;
      ub_base_q <= '0;
      tile_count_q <= '0;
      vec_src_a_q <= '0;
      vec_src_b_q <= '0;
      vec_dst_q <= '0;
      vec_funct3_q <= '0;
      tensor_accumulate_q <= 1'b0;
      ep_config_addr_q <= '0;
      rs1_q <= '0;
      rs2_q <= '0;
      register_seen_q <= 1'b0;
      committed_q <= 1'b0;
      command_err_q <= 1'b0;
    end else begin
      case (state_q)
        S_IDLE: begin
          if (issue_fire) begin
            id_q <= issue_id;
            hartid_q <= issue_hartid;
            rd_q <= issue_rd;
            op_q <= issue_load ? OP_LOAD :
                (issue_store ? OP_STORE :
                (issue_tensor ? OP_TENSOR :
                (issue_epilogue ? OP_EPILOGUE : OP_VECTOR)));
            vec_funct3_q <= issue_funct3;
            register_seen_q <= 1'b0;
            committed_q <= 1'b0;
            command_err_q <= 1'b0;
            state_q <= S_WAIT_COMMIT;
          end
        end
        S_WAIT_COMMIT: begin
          if (register_fire) begin
            rs1_q <= reg_rs0;
            rs2_q <= reg_rs1;
            mem_addr_q <= reg_rs0;
            ub_base_q <= reg_rs1[UB_ADDR_WIDTH-1:0];
            tile_count_q <= reg_rs1[15:8];
            vec_src_a_q <= reg_rs0[UB_ADDR_WIDTH-1:0];
            vec_src_b_q <= reg_rs0[2*UB_ADDR_WIDTH-1 : UB_ADDR_WIDTH];
            vec_dst_q <= reg_rs1[UB_ADDR_WIDTH-1:0];
            tensor_accumulate_q <= reg_rs1[TENSOR_GEMM_ACCUMULATE_BIT];
            ep_config_addr_q <= reg_rs1[15:8];
            register_seen_q <= 1'b1;
            if (!register_match || !register_operands_valid)
              command_err_q <= 1'b1;
          end
          if (commit_fire)
            committed_q <= 1'b1;

          if (kill_fire) begin
            state_q <= S_IDLE;
            register_seen_q <= 1'b0;
            committed_q <= 1'b0;
          end else if ((register_seen_q || register_fire) &&
                       (committed_q || commit_fire)) begin
            state_q <= S_DISPATCH;
          end
        end
        S_DISPATCH: begin
          if (command_err_q || !operands_valid) begin
            command_err_q <= 1'b1;
            state_q <= S_RESULT;
          end else if (op_q == OP_VECTOR) begin
            state_q <= S_VEC_READ_A;
          end else if (op_q == OP_TENSOR) begin
            state_q <= S_TENSOR_START;
          end else if (op_q == OP_EPILOGUE) begin
            state_q <= S_EPILOGUE_START;
          end else begin
            state_q <= S_DMA_START;
          end
        end
        S_DMA_START: begin
          if (dma_cmd_valid && dma_cmd_ready)
            state_q <= S_DMA_WAIT;
        end
        S_DMA_WAIT: begin
          if (dma_done)
            state_q <= S_RESULT;
        end
        S_VEC_READ_A: state_q <= S_VEC_LOAD_A;
        S_VEC_LOAD_A: begin
          if (vector_load_valid && vector_load_ready)
            state_q <= S_VEC_READ_B;
        end
        S_VEC_READ_B: state_q <= S_VEC_LOAD_B;
        S_VEC_LOAD_B: begin
          if (vector_load_valid && vector_load_ready)
            state_q <= S_VEC_COMMAND;
        end
        S_VEC_COMMAND: begin
          if (vector_cmd_valid && vector_cmd_ready)
            state_q <= S_VEC_WAIT;
        end
        S_VEC_WAIT: begin
          if (vector_result_fire)
            state_q <= S_RESULT;
        end
        S_TENSOR_START: begin
          if (tensor_cmd_valid && tensor_cmd_ready)
            state_q <= S_TENSOR_WAIT;
        end
        S_TENSOR_WAIT: begin
          if (tensor_done)
            state_q <= S_RESULT;
        end
        S_EPILOGUE_START: begin
          if (ep_cmd_valid && ep_cmd_ready)
            state_q <= S_EPILOGUE_WAIT;
        end
        S_EPILOGUE_WAIT: begin
          if (ep_done)
            state_q <= S_RESULT;
        end
        S_RESULT: begin
          if (result_taken)
            state_q <= S_IDLE;
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end
endmodule
