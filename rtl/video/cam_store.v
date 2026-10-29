`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// cam_store - drains the camera FIFO into a single-clock block RAM and serves
// the SoC read port.  Both sides run on clk_27m, so the RAM is a plain
// one-write/one-read memory that every toolchain infers the same way.
// ---------------------------------------------------------------------------
module cam_store (
    input  wire        clk,
    input  wire        rst,

    // FIFO side (clk_27m)
    input  wire [26:0] fifo_data,
    input  wire        fifo_empty,
    output wire        fifo_rd_en,

    // SoC read port (clk_27m)
    input  wire [10:0] rd_addr,
    input  wire        rd_bank,
    output reg  [15:0] rd_data
);
    reg [15:0] mem [0:2047];

    wire        wr_bank = fifo_data[27];
    wire [10:0] wr_addr = fifo_data[26:16];
    wire [15:0] wr_data = fifo_data[15:0];

    assign fifo_rd_en = !fifo_empty;

    always @(posedge clk) begin
        if (fifo_rd_en) mem[{wr_bank, wr_addr}] <= wr_data;
    end

    always @(posedge clk) begin
        rd_data <= mem[{rd_bank, rd_addr}];
    end
endmodule
