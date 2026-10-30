`timescale 1ns/1ps
// Port types come from the package, so the import has to precede the module.
import minitensor_pkg::*;

// -----------------------------------------------------------------------------
// mt_cvxif_shim -- MMIO -> CV-X-IF master adapter for miniTensor.
//
// Sits between the SoC 32-bit MMIO bridge and mini_tensor_top's CV-X-IF slave
// port.  The CPU programs MT_INSTR / MT_RS1 / MT_RS2 and pulses
// MT_KICK; this FSM synthesises the CV-X-IF
//     issue -> register -> commit -> result
// transaction for each queued command.
//
// Register map (byte offsets from the MMIO base; whole-word accesses only)
//   0x00  MT_INSTR   W   32-bit custom-0 instruction word
//   0x04  MT_RS1     W   value delivered as register.rs[0]
//   0x08  MT_RS2     W   value delivered as register.rs[1]
//   0x0C  MT_KICK    W   write 1 to queue the current INSTR/RS1/RS2 tuple
//   0x10  MT_STATUS  R   bit0 busy, bit1 done, bit2 err, bit3 accept_err,
//                        bit4 kick_err;  a read while not busy clears the flags
//   0x14  MT_RESULT  R   result.data (miniTensor returns 0 today)
//
// Why a FIFO: an MMIO write is cheap but a status read costs more, so a
// per-command poll costs more than the command itself.  With a queue the
// software pushes commands back-to-back and polls once per batch.
//
// Two properties of mini_tensor_top drive the sequencer:
//   * issue_ready is only high in S_IDLE, so one command is in flight at a time
//     (the queue is what keeps the accelerator busy across commands);
//   * commit is sampled only in S_WAIT_COMMIT, and the FSM advances only when
//     register_seen and committed are both set (mini_tensor_top.sv:451-452).
//     A one-cycle commit pulse that lands before the register beat is silently
//     dropped and the command hangs forever with no timeout.  commit_valid is
//     therefore held from REGISTER_TO_COMMIT until the result arrives; once
//     committed_q is latched the extra cycles are ignored, so this is safe.
// -----------------------------------------------------------------------------
module mt_cvxif_shim #(
    parameter int unsigned ISSUE_TO_REGISTER  = 2,
    parameter int unsigned REGISTER_TO_COMMIT = 3,
    parameter int unsigned FIFO_DEPTH         = 64
) (
    input  logic        clk,
    input  logic        rst,           // synchronous, active high

    // MMIO register port (CPU clock domain, driven by perip_bridge)
    input  logic        reg_wr_en,
    input  logic [2:0]  reg_wr_idx,    // perip_addr[4:2]
    input  logic [31:0] reg_wr_data,
    input  logic        status_rd,     // CPU is reading MT_STATUS this cycle
    output logic [31:0] status,
    output logic [31:0] result_data,

    // CV-X-IF master (flat structs -- Pango ADS cannot parse an interface)
    output xif_req_t xif_req,
    input  xif_rsp_t xif_rsp
);

  localparam logic [2:0] IDX_INSTR = 3'd0;
  localparam logic [2:0] IDX_RS1   = 3'd1;
  localparam logic [2:0] IDX_RS2   = 3'd2;
  localparam logic [2:0] IDX_KICK  = 3'd3;
  localparam logic [2:0] IDX_BSTEP = 3'd6;   // burst row steps, write-only
  localparam logic [2:0] IDX_LO    = 3'd7;   // paired LOAD address, write-only
  // 3'd4 = MT_STATUS and 3'd5 = MT_RESULT are read-only.

  // A command may carry a repeat count in the instruction's rd field: the shim
  // then issues count GEMMs back to back, adding the staged row steps between
  // them.  That turns the driver's inner loop (three commands per output group)
  // into one push.


  typedef enum logic [2:0] {
    S_IDLE,
    S_ISSUE,
    S_REG_WAIT,
    S_REGISTER,
    S_COMMIT_WAIT,
    S_WAIT_RESULT
  } state_t;

  state_t      state_q;
  // Execution registers, latched from the queue at pop time and driven onto the
  // CV-X-IF channels.
  logic [31:0] instr_q, rs1_q, rs2_q;
  // Software staging registers.  These MUST be separate from the execution
  // registers: the software writes a new command while the queue is still
  // draining, so a pop happening in the same cycle as a staging write would
  // otherwise clobber it and enqueue a stale instruction.
  logic [31:0] stg_instr_q, stg_rs1_q, stg_rs2_q;
  logic [3:0]  id_q;
  logic [7:0]  wait_q;

  // Burst support: row steps staged per layer, repeat counter per command.
  logic [7:0]  stg_a_step, stg_b_step, stg_c_step, stg_d_step;  // IDX_BSTEP
  logic [7:0]  rep_q;                                // repeats left - 1
  logic [7:0]  rep_stg;                              // repeats of the next push
  logic [7:0]  a_step_q, b_step_q, c_step_q, d_step_q; // latched with the command

  // Two-dimensional burst (GEMM2D): the convolution inner loop is a u x j grid
  // -- u walks the tile columns (A row +1, C row +4), j walks the output groups
  // inside a tile column (weight row +1, C row fixed).  Flat bursts cannot
  // express that, so a second pair of counters lives here.
  logic        is2d_q;
  logic [7:0]  u_q, j_q, nj_q;
  logic [31:0] rs1_u_q, rs2_u_q;

  // Paired command (0x0A): issue a LOAD from stg_lo first, then run the 2D grid.
  logic [31:0] stg_lo_q;
  logic        lo_first_q;

  logic [31:0] result_data_q;
  logic        done_q, err_q, accept_err_q, kick_err_q;

  // ---------------------------------------------------------------------------
  // Command queue (mt_cmd_fifo owns the storage; this module only sequences)
  // ---------------------------------------------------------------------------
  wire         fifo_full, fifo_empty;
  wire [31:0]  fifo_count;
  wire [167:0] fifo_head;
  wire         fifo_push, fifo_pop;
  wire [167:0] fifo_push_data;

  // Entry layout, MSB first: {rep, c_step, b_step, a_step, rs2, rs1, instr}
  wire [31:0] fifo_head_instr = fifo_head[31:0];
  wire [31:0] fifo_head_rs1   = fifo_head[63:32];
  wire [31:0] fifo_head_rs2   = fifo_head[95:64];
  wire [31:0] fifo_head_lo    = fifo_head[127:96];
  wire [7:0]  fifo_head_a     = fifo_head[135:128];
  wire [7:0]  fifo_head_b     = fifo_head[143:136];
  wire [7:0]  fifo_head_c     = fifo_head[151:144];
  wire [7:0]  fifo_head_d     = fifo_head[159:152];
  wire [7:0]  fifo_head_rep   = fifo_head[167:160];

  assign fifo_push_data = {rep_stg, stg_d_step, stg_c_step, stg_b_step, stg_a_step,
                           stg_lo_q, stg_rs2_q, stg_rs1_q, stg_instr_q};

  wire kick = reg_wr_en && (reg_wr_idx == IDX_KICK) && reg_wr_data[0];

  assign fifo_push = kick && !fifo_full;
  assign fifo_pop  = (state_q == S_IDLE) && !fifo_empty;
  assign busy      = !fifo_empty || (state_q != S_IDLE);

  mt_cmd_fifo #(
    .DEPTH(FIFO_DEPTH),
    .WIDTH(168)
  ) u_cmd_fifo (
    .clk,
    .rst,
    .push(fifo_push),
    .push_data(fifo_push_data),
    .pop(fifo_pop),
    .head_data(fifo_head),
    .empty(fifo_empty),
    .full(fifo_full),
    .count(fifo_count)
  );

  // GEMM2D: funct7 0x09, nu in rs1[23:16], nj in rs1[31:24]; the rows keep
  // their usual bytes.  Any other instruction with a non-zero rd field is a
  // flat burst.
  wire        is2d_stg = (stg_instr_q[31:25] == 7'h09);
  wire        is2d_head = (fifo_head_instr[31:25] == 7'h09);
  wire        is_pair_head = (fifo_head_instr[31:25] == 7'h0A);
  assign rep_stg = is2d_stg ? 8'd0 : stg_instr_q[11:7];

  assign status      = {27'd0, kick_err_q, accept_err_q, err_q, done_q, busy};
  assign result_data = result_data_q;

  // ---------------------------------------------------------------------------
  // CV-X-IF master drive
  // ---------------------------------------------------------------------------
  // Continuous assignment, not always_comb: driving a packed-struct output
  // from a procedural block makes ADS abort with Flow-0189 in this module.
  assign xif_req.issue_valid      = (state_q == S_ISSUE);
  assign xif_req.issue_instr      = instr_q;
  assign xif_req.issue_id         = id_q;
  assign xif_req.register_valid   = (state_q == S_REGISTER);
  assign xif_req.register_id      = id_q;
  assign xif_req.register_rs0     = rs1_q;
  assign xif_req.register_rs1     = rs2_q;
  assign xif_req.register_rs_valid = 2'b11;
  // Held, not pulsed -- see the header comment.
  assign xif_req.commit_valid     = (state_q == S_COMMIT_WAIT) || (state_q == S_WAIT_RESULT);
  assign xif_req.commit_id        = id_q;
  assign xif_req.commit_kill      = 1'b0;
  assign xif_req.result_ready     = (state_q == S_WAIT_RESULT);

  // ---------------------------------------------------------------------------
  // Register file and control FSM
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      state_q      <= S_IDLE;
      instr_q      <= 32'd0;
      rs1_q        <= 32'd0;
      rs2_q        <= 32'd0;
      stg_instr_q  <= 32'd0;
      stg_rs1_q    <= 32'd0;
      stg_rs2_q    <= 32'd0;
      id_q         <= 4'd0;
      wait_q       <= 8'd0;
      result_data_q <= 32'd0;
      done_q       <= 1'b0;
      err_q        <= 1'b0;
      accept_err_q <= 1'b0;
      kick_err_q   <= 1'b0;
      rep_q        <= 8'd0;
      is2d_q       <= 1'b0;
      lo_first_q   <= 1'b0;
      stg_lo_q     <= 32'd0;
      u_q          <= 8'd0;
      j_q          <= 8'd0;
      nj_q         <= 8'd1;
      rs1_u_q      <= 32'd0;
      rs2_u_q      <= 32'd0;
      a_step_q     <= 8'd0;
      b_step_q     <= 8'd0;
      c_step_q     <= 8'd0;
      stg_a_step   <= 8'd0;
      stg_b_step   <= 8'd0;
      stg_c_step   <= 8'd0;
      stg_d_step   <= 8'd0;
      d_step_q     <= 8'd0;
    end else begin
      if (reg_wr_en) begin
        case (reg_wr_idx)
          IDX_INSTR: stg_instr_q <= reg_wr_data;
          IDX_RS1:   stg_rs1_q   <= reg_wr_data;
          IDX_RS2:   stg_rs2_q   <= reg_wr_data;
          IDX_BSTEP: begin
            stg_a_step <= reg_wr_data[7:0];
            stg_b_step <= reg_wr_data[15:8];
            stg_c_step <= reg_wr_data[23:16];
            stg_d_step <= reg_wr_data[31:24];
          end
          IDX_LO:    stg_lo_q <= reg_wr_data;
          default:   ;  // KICK is consumed below
        endcase
      end

      // Enqueue the staged operands.  A full queue drops the kick and flags it
      // rather than stalling the peripheral bus, which would lock up the LSU
      // store path.  Note that on the very cycle a kick is accepted the staging
      // registers may also be written, so the push must read their current
      // values (non-blocking assignment does exactly that).
      if (kick && fifo_full) begin
        kick_err_q <= 1'b1;
      end

      // A status read only consumes the flags once the queue has drained, so a
      // mid-batch poll cannot lose an error reported by an earlier command.
      if (status_rd && !busy) begin
        done_q       <= 1'b0;
        err_q        <= 1'b0;
        accept_err_q <= 1'b0;
        kick_err_q   <= 1'b0;
      end

      case (state_q)
        S_IDLE: begin
          if (!fifo_empty) begin
            // Macros are translated here: the tensor only ever sees the plain
            // instructions it already validates.
            instr_q  <= is_pair_head ? {7'h03, 25'h0B}
                     : (is2d_head ? {7'h05, fifo_head_instr[24:0]}
                                  : fifo_head_instr);
            rs1_q    <= is_pair_head ? fifo_head_lo : fifo_head_rs1;
            // MT_ROWS(row, count): row in the low byte, count in the high one.
            rs2_q    <= is_pair_head
                        ? (32'd236 | ({24'd0, fifo_head_instr[19:15]} << 8))
                        : fifo_head_rs2;
            lo_first_q <= is_pair_head;
            a_step_q <= fifo_head_a;
            b_step_q <= fifo_head_b;
            c_step_q <= fifo_head_c;
            d_step_q <= fifo_head_d;
            // rep is the number of issues, rep_q counts the ones still to do.
            rep_q    <= (fifo_head_rep == 8'd0) ? 8'd0 : (fifo_head_rep - 8'd1);

            // Shape: nu in the instruction's rs1 field, nj in its rs2 field.
            is2d_q  <= (fifo_head_instr[31:25] == 7'h09) ||
                       (fifo_head_instr[31:25] == 7'h0A);
            u_q     <= ({3'd0, fifo_head_instr[19:15]} == 8'd0) ? 8'd0
                      : ({3'd0, fifo_head_instr[19:15]} - 8'd1);
            nj_q    <= ({3'd0, fifo_head_instr[24:20]} == 8'd0) ? 8'd1
                      : {3'd0, fifo_head_instr[24:20]};
            j_q     <= ({3'd0, fifo_head_instr[24:20]} == 8'd0) ? 8'd0
                      : ({3'd0, fifo_head_instr[24:20]} - 8'd1);
            rs1_u_q <= fifo_head_rs1;
            rs2_u_q <= fifo_head_rs2;
            id_q     <= id_q + 4'd1;
            state_q  <= S_ISSUE;
          end
        end

        S_ISSUE: begin
          if (xif_req.issue_valid && xif_rsp.issue_ready) begin
            if (xif_rsp.issue_accept) begin
              wait_q  <= ISSUE_TO_REGISTER[7:0];
              state_q <= S_REG_WAIT;
            end else begin
              // Unsupported funct7/funct3: miniTensor never enters its FSM and
              // will never raise result_valid, so report and move on.
              accept_err_q <= 1'b1;
              state_q      <= S_IDLE;
            end
          end
        end

        S_REG_WAIT: begin
          if (wait_q == 8'd0) state_q <= S_REGISTER;
          else                wait_q <= wait_q - 8'd1;
        end

        S_REGISTER: begin
          if (xif_req.register_valid && xif_rsp.register_ready) begin
            wait_q  <= REGISTER_TO_COMMIT[7:0];
            state_q <= S_COMMIT_WAIT;
          end
        end

        S_COMMIT_WAIT: begin
          if (wait_q == 8'd0) state_q <= S_WAIT_RESULT;
          else                wait_q <= wait_q - 8'd1;
        end

        S_WAIT_RESULT: begin
          if (xif_rsp.result_valid && xif_req.result_ready) begin
            err_q         <= err_q | xif_rsp.result_err;
            result_data_q <= xif_rsp.result_data;

            if (lo_first_q) begin
              // The paired command's LOAD has landed; run the grid now.
              lo_first_q <= 1'b0;
              instr_q    <= {7'h05, 25'h0B};
              rs1_q      <= rs1_u_q;
              rs2_q      <= rs2_u_q;
              id_q       <= id_q + 4'd1;
              state_q    <= S_ISSUE;
            end else if (is2d_q && (j_q != 8'd0)) begin
              // Inner step: next output group.  The weight row advances by
              // b_step and the C row by d_step (one output group's worth of
              // columns), which is what the scalar loop did per group.
              j_q     <= j_q - 8'd1;
              rs1_q   <= rs1_q + {b_step_q, 8'd0};
              rs2_q   <= rs2_q + {24'd0, d_step_q};
              id_q    <= id_q + 4'd1;
              state_q <= S_ISSUE;
            end else if (is2d_q && (u_q != 8'd0)) begin
              // Outer step: next tile column, A row +a_step, C row +c_step.
              u_q     <= u_q - 8'd1;
              j_q     <= (nj_q == 8'd0) ? 8'd0 : (nj_q - 8'd1);
              rs1_u_q <= rs1_u_q + {8'd0, a_step_q};
              rs2_u_q <= rs2_u_q + {24'd0, c_step_q};
              rs1_q   <= rs1_u_q + {8'd0, a_step_q};
              rs2_q   <= rs2_u_q + {24'd0, c_step_q};
              id_q    <= id_q + 4'd1;
              state_q <= S_ISSUE;
            end else if (!is2d_q && (rep_q != 8'd0)) begin
              // Flat burst: issue the same instruction again with the rows moved on.
              rep_q   <= rep_q - 8'd1;
              rs1_q   <= rs1_q + {b_step_q, a_step_q};
              rs2_q   <= rs2_q + {24'd0, c_step_q};
              id_q    <= id_q + 4'd1;
              state_q <= S_ISSUE;
            end else begin
              // Only the final command of a drained queue raises DONE.
              if (fifo_empty) done_q <= 1'b1;
              state_q <= S_IDLE;
            end
          end
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule
