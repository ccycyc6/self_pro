`timescale 1ns/1ps
// Multi-cycle integer multiply/divide unit.
module ares_muldiv (
  input  logic        clk,
  input  logic        rst,
  input  logic        start,
  input  ares_pkg::muldiv_op_t op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        busy,
  output logic        done,
  output logic [31:0] result
);
  logic        busy_q;
  logic        done_q;
  ares_pkg::muldiv_op_t op_q;
  logic [31:0] a_q, b_q;
  logic [31:0] result_q;

  logic [31:0] abs_a, abs_b;
  logic        neg_q, neg_r;
  logic [31:0] dividend_q, divisor_q;
  logic [31:0] quot_q, rem_q;
  logic [5:0]  count_q;
  logic        div_mode_q;

  wire a_sign = a[31];
  wire b_sign = b[31];
  wire [31:0] a_abs_w = a_sign ? (~a + 32'd1) : a;
  wire [31:0] b_abs_w = b_sign ? (~b + 32'd1) : b;

  assign busy   = busy_q;
  assign done   = done_q;
  assign result = result_q;

  // 64-bit products for the M extension high-half instructions.
  wire signed [63:0] prod_ss = $signed(a_q) * $signed(b_q);
  wire signed [63:0] prod_su = $signed(a_q) * $signed({1'b0, b_q});
  wire        [63:0] prod_uu = $unsigned(a_q) * $unsigned(b_q);

  always_ff @(posedge clk) begin
    if (rst) begin
      busy_q   <= 1'b0;
      done_q   <= 1'b0;
      op_q     <= ares_pkg::MD_NONE;
      a_q      <= 32'd0;
      b_q      <= 32'd0;
      result_q <= 32'd0;
      abs_a    <= 32'd0;
      abs_b    <= 32'd0;
      neg_q    <= 1'b0;
      neg_r    <= 1'b0;
      dividend_q <= 32'd0;
      divisor_q  <= 32'd0;
      quot_q     <= 32'd0;
      rem_q      <= 32'd0;
      count_q    <= 6'd0;
      div_mode_q <= 1'b0;
    end else begin
      done_q <= 1'b0;

      if (start && !busy_q) begin
        busy_q <= 1'b1;
        op_q   <= op;
        a_q    <= a;
        b_q    <= b;
        case (op)
          ares_pkg::MD_MUL: begin
            result_q <= a * b;
            done_q   <= 1'b1;
            busy_q   <= 1'b0;
          end
          ares_pkg::MD_MULH: begin
            result_q <= prod_ss[63:32];
            done_q   <= 1'b1;
            busy_q   <= 1'b0;
          end
          ares_pkg::MD_MULHSU: begin
            result_q <= prod_su[63:32];
            done_q   <= 1'b1;
            busy_q   <= 1'b0;
          end
          ares_pkg::MD_MULHU: begin
            result_q <= prod_uu[63:32];
            done_q   <= 1'b1;
            busy_q   <= 1'b0;
          end
          ares_pkg::MD_DIV, ares_pkg::MD_DIVU,
          ares_pkg::MD_REM, ares_pkg::MD_REMU: begin
            abs_a <= a_abs_w;
            abs_b <= b_abs_w;
            neg_q <= ((op == ares_pkg::MD_DIV) || (op == ares_pkg::MD_REM)) &&
                     (a_sign ^ b_sign);
            neg_r <= ((op == ares_pkg::MD_REM)) && a_sign;
            dividend_q <= a_abs_w;
            divisor_q  <= b_abs_w;
            quot_q     <= 32'd0;
            rem_q      <= 32'd0;
            count_q    <= 6'd32;
            div_mode_q <= ((op == ares_pkg::MD_DIV) || (op == ares_pkg::MD_DIVU));
          end
          default: begin
            result_q <= 32'd0;
            done_q   <= 1'b1;
            busy_q   <= 1'b0;
          end
        endcase
      end else if (busy_q) begin
        if (b_q == 32'd0) begin
          // RISC-V defines divide-by-zero: quotient all ones, remainder dividend.
          if (div_mode_q) result_q <= 32'hFFFF_FFFF;
          else            result_q <= a_q;
          done_q <= 1'b1;
          busy_q <= 1'b0;
        end else if (count_q == 0) begin
          if (div_mode_q) begin
            result_q <= neg_q ? (~quot_q + 32'd1) : quot_q;
          end else begin
            result_q <= neg_r ? (~rem_q + 32'd1) : rem_q;
          end
          done_q <= 1'b1;
          busy_q <= 1'b0;
        end else begin
          // Shift-subtract: bring down one dividend bit per cycle.
          if ({rem_q[30:0], dividend_q[31]} >= divisor_q) begin
            rem_q <= {rem_q[30:0], dividend_q[31]} - divisor_q;
            quot_q <= {quot_q[30:0], 1'b1};
          end else begin
            rem_q <= {rem_q[30:0], dividend_q[31]};
            quot_q <= {quot_q[30:0], 1'b0};
          end
          dividend_q <= {dividend_q[30:0], 1'b0};
          count_q <= count_q - 6'd1;
        end
      end
    end
  end
endmodule
