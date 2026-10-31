`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// video_pip - draws camera 2 as an inset over the HDMI picture.
//
// The 320x240 image is scaled 2x into the rectangle (X0,Y0)-(X1,Y1).
//
// Latency bookkeeping (this is where the first version was wrong): the frame
// memory has a registered read, so a byte takes TWO cycles to come back:
//   t     : address of pixel (x,y) is presented
//   t+1   : mem_data valid
//   t+2   : img_q valid
// The video is therefore delayed by two pixels as well, and the inset flag is
// taken from the position two cycles back.
// ---------------------------------------------------------------------------
module video_pip #(
    // 1:1 inset in the bottom-right corner: 320x240 of a 1280x720 frame.
    parameter integer X0  = 960,
    parameter integer Y0  = 480,
    parameter integer X1  = 1280,
    parameter integer Y1  = 720,
    parameter integer SFT = 0        // 0 = 1:1, 1 = 2x zoom
) (
    input  wire        pix_clk,
    input  wire        rst,

    input  wire [11:0] x,
    input  wire [11:0] y,
    input  wire        de,
    input  wire [23:0] rgb_in,

    output wire [23:0] rgb_out,

    output wire [16:0] mem_addr,
    input  wire [7:0]  mem_data
);
    wire in_rect = (x >= X0) && (x < X1) && (y >= Y0) && (y < Y1);
    wire [11:0] sx = (x - X0) >> SFT;
    wire [11:0] sy = (y - Y0) >> SFT;

    assign mem_addr = (sy * 12'd320) + sx;

    reg        de_d1, de_d2;
    reg        in_d1, in_d2;
    reg [7:0]  img_d1, img_d2;
    reg [23:0] rgb_d1, rgb_d2;

    always @(posedge pix_clk) begin
        if (rst) begin
            de_d1 <= 1'b0; de_d2 <= 1'b0;
            in_d1 <= 1'b0; in_d2 <= 1'b0;
            img_d1 <= 8'd0; img_d2 <= 8'd0;
            rgb_d1 <= 24'd0; rgb_d2 <= 24'd0;
        end else begin
            de_d1  <= de;
            in_d1  <= in_rect;
            img_d1 <= mem_data;
            rgb_d1 <= rgb_in;

            de_d2  <= de_d1;
            in_d2  <= in_d1;
            img_d2 <= img_d1;
            rgb_d2 <= rgb_d1;
        end
    end

    // The memory model (and the BRAM) registers on the same edge as img_d1, so
    // img_d1 already carries the byte for the pixel whose video is in rgb_d2.
    // Using img_d2 here costs one more pixel and shifts the inset by one.
    wire       draw = de_d2 && in_d2;
    wire [7:0] g    = img_d1;

    assign rgb_out = draw ? {g, g, g} : rgb_d2;
endmodule
