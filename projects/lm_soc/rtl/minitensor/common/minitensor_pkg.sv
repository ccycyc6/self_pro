`timescale 1ns/1ps

package minitensor_pkg;
  // ---------------------------------------------------------------------------
  // Flat CV-X-IF bundle.
  //
  // The upstream core_v_xif is a SystemVerilog interface, which Pango ADS
  // cannot parse, and the miniTensor only ever uses the issue / register /
  // commit / result channels.  Carrying the two directions as packed structs
  // keeps the port list short and is understood by every toolchain.
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic        issue_valid;
    logic [31:0] issue_instr;
    logic [3:0]  issue_id;
    logic        issue_hartid;

    logic        register_valid;
    logic [3:0]  register_id;
    logic        register_hartid;
    logic [31:0] register_rs0;
    logic [31:0] register_rs1;
    logic [1:0]  register_rs_valid;

    logic        commit_valid;
    logic [3:0]  commit_id;
    logic        commit_hartid;
    logic        commit_kill;

    logic        result_ready;
  } xif_req_t;

  typedef struct packed {
    // 1-bit fields are plain logic, not logic[0:0]: ADS rejects a part-select
    // of a struct member (Flow-0189), and xif_rsp.x[0] is exactly that.
    logic        issue_ready;
    logic        issue_accept;
    logic        issue_writeback;
    logic [1:0]  issue_register_read;

    logic        register_ready;

    logic        result_valid;
    logic [31:0] result_data;
    logic [4:0]  result_rd;
    logic        result_we;
    logic        result_err;
  } xif_rsp_t;

  // Command classes and top-level sequencer states live in the package so the
  // controller and the datapath can share them without a second definition.
  typedef enum logic [2:0] {
    OP_LOAD, OP_STORE, OP_VECTOR, OP_TENSOR, OP_EPILOGUE
  } op_t;

  typedef enum logic [3:0] {
    S_IDLE, S_WAIT_COMMIT, S_DISPATCH,
    S_DMA_START, S_DMA_WAIT,
    S_VEC_READ_A, S_VEC_LOAD_A, S_VEC_READ_B, S_VEC_LOAD_B,
    S_VEC_COMMAND, S_VEC_WAIT,
    S_TENSOR_START, S_TENSOR_WAIT,
    S_EPILOGUE_START, S_EPILOGUE_WAIT,
    S_RESULT
  } state_t;

  localparam logic [6:0] MT_CUSTOM0_OPCODE = 7'b0001011;
  localparam logic [6:0] MT_LOAD_FUNCT7 = 7'b0000011;
  localparam logic [2:0] MT_LOAD_FUNCT3 = 3'b000;
  localparam logic [6:0] MT_STORE_FUNCT7 = 7'b0000100;
  localparam logic [2:0] MT_STORE_FUNCT3 = 3'b000;

  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic is_minitensor_load(input logic [31:0] instr);
    is_minitensor_load =
        (instr[6:0] == MT_CUSTOM0_OPCODE) &&
        (instr[31:25] == MT_LOAD_FUNCT7) &&
        (instr[14:12] == MT_LOAD_FUNCT3);
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic is_minitensor_store(input logic [31:0] instr);
    is_minitensor_store =
        (instr[6:0] == MT_CUSTOM0_OPCODE) &&
        (instr[31:25] == MT_STORE_FUNCT7) &&
        (instr[14:12] == MT_STORE_FUNCT3);
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  function automatic logic [31:0] make_minitensor_load(
      input logic [4:0] rd,
      input logic [4:0] src_reg,
      input logic [4:0] dst_reg);
    make_minitensor_load = {
      MT_LOAD_FUNCT7,
      dst_reg,
      src_reg,
      MT_LOAD_FUNCT3,
      rd,
      MT_CUSTOM0_OPCODE
    };
  endfunction

  function automatic logic [31:0] make_minitensor_store(
      input logic [4:0] rd,
      input logic [4:0] dst_reg,
      input logic [4:0] src_reg);
    make_minitensor_store = {
      MT_STORE_FUNCT7,
      src_reg,
      dst_reg,
      MT_STORE_FUNCT3,
      rd,
      MT_CUSTOM0_OPCODE
    };
  endfunction
endpackage
