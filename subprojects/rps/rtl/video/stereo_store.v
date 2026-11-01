`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// stereo_store - 320x240 byte image behind the SoC read window.
//
// Single-clock RAM with one write (FIFO drain) and one registered read (CPU
// window).  No double buffering: a torn frame costs at most one bad match.
// ---------------------------------------------------------------------------
module stereo_store (
    input  wire        clk,
    input  wire [16:0] wr_addr,
    input  wire [7:0]  wr_data,
    input  wire        wr_en,
    input  wire [16:0] rd_addr,
    output reg  [7:0]  rd_data
);
    reg [7:0] mem [0:76800-1];

    always @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
        rd_data <= mem[rd_addr];
    end
endmodule
