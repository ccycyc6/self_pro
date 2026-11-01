`timescale 1ns/1ps

// Local vector register file for future vector instructions.
//
// Reads are combinational to keep the unit convenient for a decoupled VPU
// datapath. Writes occur on the rising edge and support byte granularity,
// which is useful for packed INT8 results and masked updates.
module vpu_vector_regfile #(
  parameter int unsigned NUM_REGS = 32,
  parameter int unsigned VLEN = 128,
  parameter int unsigned ADDR_WIDTH = $clog2(NUM_REGS)
) (
  input logic clk,
  input logic rst,
  input logic rd0_en,
  input logic [ADDR_WIDTH-1:0] rd0_addr,
  output logic [VLEN-1:0] rd0_data,
  input logic rd1_en,
  input logic [ADDR_WIDTH-1:0] rd1_addr,
  output logic [VLEN-1:0] rd1_data,
  input logic wr_en,
  input logic [ADDR_WIDTH-1:0] wr_addr,
  input logic [VLEN-1:0] wr_data,
  input logic [VLEN/8-1:0] wr_be
);
  logic [VLEN-1:0] regs [0:NUM_REGS-1];
  // NUM_REGS always fits in ADDR_WIDTH+1 bits (ADDR_WIDTH = $clog2(NUM_REGS)).
  localparam logic [ADDR_WIDTH:0] NUM_REGS_LIMIT = NUM_REGS;
  wire rd0_addr_valid = {1'b0, rd0_addr} < NUM_REGS_LIMIT;
  wire rd1_addr_valid = {1'b0, rd1_addr} < NUM_REGS_LIMIT;
  wire wr_addr_valid = {1'b0, wr_addr} < NUM_REGS_LIMIT;
  integer i;

  always_ff @(posedge clk) begin
    if (rst) begin
      for (i = 0; i < NUM_REGS; i = i + 1)
        regs[i] <= '0;
    end else if (wr_en && wr_addr_valid) begin
      for (i = 0; i < VLEN/8; i = i + 1)
        if (wr_be[i]) regs[wr_addr][8*i +: 8] <= wr_data[8*i +: 8];
    end
  end

  always_comb begin
    rd0_data = (rd0_en && rd0_addr_valid) ? regs[rd0_addr] : '0;
    rd1_data = (rd1_en && rd1_addr_valid) ? regs[rd1_addr] : '0;
  end
endmodule
