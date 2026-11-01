`timescale 1ns/1ps

// Single-clock local SRAM used as the DMA/compute tile staging buffer.
// Reads are synchronous and return rd_valid one cycle after rd_en is sampled.
module unified_buffer #(
  parameter int unsigned DATA_WIDTH = 128,
  parameter int unsigned DEPTH = 256,
  parameter int unsigned ADDR_WIDTH = $clog2(DEPTH)
) (
  input  logic                  clk,
  input  logic                  rst,
  input  logic                  wr_en,
  input  logic [ADDR_WIDTH-1:0] wr_addr,
  input  logic [DATA_WIDTH-1:0] wr_data,
  input  logic [DATA_WIDTH/8-1:0] wr_be,
  input  logic                  rd_en,
  input  logic [ADDR_WIDTH-1:0] rd_addr,
  output logic                  rd_valid,
  output logic [DATA_WIDTH-1:0] rd_data
);
  localparam int unsigned BYTE_COUNT = DATA_WIDTH / 8;
  // DEPTH always fits in ADDR_WIDTH+1 bits (ADDR_WIDTH = $clog2(DEPTH)), so a
  // plain assignment is the same value and stays inside the ADS subset: the
  // preparer only rewrites sized casts whose width is a literal number.
  localparam logic [ADDR_WIDTH:0] DEPTH_LIMIT = DEPTH;

  logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];
  wire wr_addr_valid = {1'b0, wr_addr} < DEPTH_LIMIT;
  wire rd_addr_valid = {1'b0, rd_addr} < DEPTH_LIMIT;
  integer i;

  initial begin
    if (DATA_WIDTH == 0 || DATA_WIDTH % 8 != 0)
      $fatal(1, "unified_buffer DATA_WIDTH must be a positive multiple of 8");
    if (DEPTH < 2)
      $fatal(1, "unified_buffer DEPTH must be at least 2");
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      rd_valid <= 1'b0;
      rd_data <= '0;
    end else begin
      rd_valid <= rd_en;
      if (rd_en)
        rd_data <= rd_addr_valid ? mem[rd_addr] : '0;

      if (wr_en && wr_addr_valid) begin
        for (i = 0; i < BYTE_COUNT; i = i + 1)
          if (wr_be[i])
            mem[wr_addr][8*i +: 8] <= wr_data[8*i +: 8];
      end
    end
  end
endmodule
