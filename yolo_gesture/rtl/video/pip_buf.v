`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// pip_buf - 320x240 byte frame for the picture-in-picture inset.
//
// Written from the camera's stream through an asynchronous FIFO and read back
// on the HDMI pixel clock, so the inset lives entirely in the pixel domain and
// nothing crosses clock domains inside the memory.
// ---------------------------------------------------------------------------
module pip_buf (
    input  wire        pix_clk,
    input  wire        rst,

    // fill side (pixel clock, from the async FIFO)
    input  wire [24:0] fifo_data,     // {addr[16:0], luma[7:0]}
    input  wire        fifo_empty,
    output wire        fifo_rd_en,

    // display side (same clock)
    input  wire [16:0] rd_addr,
    output reg  [7:0]  rd_data
);
    reg [7:0] mem [0:76800-1];

    always @(posedge pix_clk) begin
        if (!fifo_empty)
            mem[fifo_data[24:8]] <= fifo_data[7:0];
        rd_data <= mem[rd_addr];
    end

    assign fifo_rd_en = !fifo_empty;
endmodule
