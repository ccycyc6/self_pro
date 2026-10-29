`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// mt_cmd_fifo - command queue for the miniTensor MMIO shim.
//
// One entry is a whole command (see mt_cvxif_shim for the field layout), so the
// data path is a single wide word rather than three parallel arrays.  DEPTH is
// a parameter but the count is a plain integer, so no parameterised port widths
// are involved (Pango ADS handles this shape reliably).
// ---------------------------------------------------------------------------
module mt_cmd_fifo #(
  parameter integer DEPTH = 8,
  parameter integer WIDTH = 128
) (
  input  logic             clk,
  input  logic             rst,

  input  logic             push,
  input  logic [WIDTH-1:0] push_data,

  input  logic             pop,

  output logic [WIDTH-1:0] head_data,
  output logic             empty,
  output logic             full,
  output logic [31:0]      count
);
  localparam integer PTR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1;

  logic [WIDTH-1:0] mem [0:DEPTH-1];
  logic [PTR_W-1:0] head_q, tail_q;
  integer           count_q;

  assign head_data = mem[head_q];
  assign empty     = (count_q == 0);
  assign full      = (count_q == DEPTH);
  assign count     = count_q[31:0];

  always_ff @(posedge clk) begin
    if (rst) begin
      head_q  <= '0;
      tail_q  <= '0;
      count_q <= 0;
    end else begin
      if (push) begin
        mem[tail_q] <= push_data;
        tail_q      <= tail_q + 1'b1;
      end
      if (pop)
        head_q <= head_q + 1'b1;
      if (push && !pop)
        count_q <= count_q + 1;
      else if (!push && pop)
        count_q <= count_q - 1;
    end
  end
endmodule
