`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// stereo_cap - 320x240 luma image from one camera.
//
// The 32x32 thumbnails cannot measure parallax (f = 27 px, so 2 m of distance
// is under one pixel of disparity).  This module crops the centre 640x480 of
// the 1280x720 stream and decimates 2:1 on both axes: f = 275 px, and 2 m
// becomes a 9.6 pixel disparity.
//
// Addressing is row * 320 + col, the layout the readers and the CPU use.
// Getting this wrong (row * 256, and a crop anchored at 0,0 instead of the
// centre) is what made the first inset look like diagonal stripes.
// ---------------------------------------------------------------------------
module stereo_cap (
    input  wire        pixel_clk,
    input  wire        pixel_rst,
    input  wire        pixel_de,
    input  wire [15:0] pixel_rgb565,
    input  wire        pixel_vsync,

    output reg         wr_en,
    output reg  [16:0] wr_addr,
    output reg  [7:0]  wr_data,
    output reg         frame_tog,
    output reg  [31:0] wr_cnt
);
    localparam [11:0] X0 = 12'd320;   // crop origin in the 1280 wide frame
    localparam [11:0] Y0 = 12'd80;    // and in the 720 line frame
    localparam [11:0] CW = 12'd640;   // crop size
    localparam [11:0] CH = 12'd480;

    reg        de_d;
    reg [11:0] x_cnt;                 // 0..1279 visible pixels
    reg [11:0] y_cnt;                 // 0..719 visible lines
    reg        phase_x, phase_y;      // 2:1 decimation
    reg        vsync_d;

    wire de_rise = pixel_de && !de_d;

    wire [4:0] r5 = pixel_rgb565[15:11];
    wire [5:0] g6 = pixel_rgb565[10:5];
    wire [4:0] b5 = pixel_rgb565[4:0];

    // (r8 + 2*g8 + b8)/4 with 8-bit channels cancels the expansion:
    // = 2*(r5 + g6 + b5), no multipliers.
    wire [7:0] r2 = {2'b00, r5, 1'b0};
    wire [7:0] g2 = {1'b0, g6, 1'b0};
    wire [7:0] b2 = {2'b00, b5, 1'b0};
    wire [7:0] luma = r2 + g2 + b2;

    wire in_crop_x = (x_cnt >= X0) && (x_cnt < X0 + CW);
    wire in_crop_y = (y_cnt >= Y0) && (y_cnt < Y0 + CH);

    wire [16:0] col = (x_cnt - X0) >> 1;             // 0..319
    wire [16:0] row = (y_cnt - Y0) >> 1;             // 0..239
    wire [16:0] addr = row * 17'd320 + col;

    always @(posedge pixel_clk) begin
        if (pixel_rst) begin
            de_d    <= 1'b0;
            x_cnt   <= 12'd0;
            y_cnt   <= 12'd0;
            phase_x <= 1'b0;
            phase_y <= 1'b0;
            vsync_d <= 1'b0;
            wr_en   <= 1'b0;
            wr_addr <= 17'd0;
            wr_data <= 8'd0;
            frame_tog <= 1'b0;
            wr_cnt  <= 32'd0;
        end else begin
            de_d  <= pixel_de;
            wr_en <= 1'b0;

            if (de_rise) begin
                x_cnt   <= 12'd0;
                phase_x <= 1'b0;
                if (y_cnt == 12'd719) y_cnt <= 12'd0;
                else                  y_cnt <= y_cnt + 12'd1;
                phase_y <= ~phase_y;
            end else if (pixel_de) begin
                x_cnt <= x_cnt + 12'd1;
                phase_x <= ~phase_x;

                // every second pixel of every second line inside the crop
                if (!phase_x && phase_y && in_crop_x && in_crop_y) begin
                    wr_en   <= 1'b1;
                    wr_addr <= addr;
                    wr_data <= luma;
                    wr_cnt  <= wr_cnt + 32'd1;
                end
            end

            vsync_d <= pixel_vsync;
            if (pixel_vsync && !vsync_d) begin
                y_cnt     <= 12'd0;
                phase_y   <= 1'b0;
                frame_tog <= ~frame_tog;
            end
        end
    end
endmodule
