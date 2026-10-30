\`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// stereo_cap - 320x240 luma image for one eye of the stereo pair.
//
// 32x32 is far too coarse for disparity: with a 60 degree lens a 32-cell-wide
// image has f = 27 px, so at 2 m the whole parallax is 0.8 px.  At 320 cells
// wide f = 275 px and the parallax is 9.6 px, which is what makes depth (and
// therefore height) possible at all.
//
// Crop: x in [320,960), y in [80,560)  -> 640x480, then 2:1 on both axes.
// Luma only (one byte per pixel): the matcher does not need colour, and this
// keeps the buffer at 75 KB per eye instead of 150 KB.
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
    localparam [11:0] CROP_W = 12'd640;   // x span
    localparam [11:0] CROP_H = 12'd480;   // y span

    reg        de_d;
    reg [11:0] x_cnt;      // pixel index inside the crop
    reg [11:0] y_cnt;      // line index inside the crop
    reg        ph;         // 0 = first pixel/line of a cell pair
    reg        acc_line;   // this line contributes a row
    reg [8:0]  row;        // 0..239
    reg [8:0]  col;        // 0..319
    reg        vsync_d;

    wire de_rise = pixel_de && !de_d;

    wire [7:0] r8 = {pixel_rgb565[15:11], 3'b000};
    wire [7:0] g8 = {pixel_rgb565[10:5],  2'b00};
    wire [7:0] b8 = {pixel_rgb565[4:0],   3'b000};
    wire [15:0] lum16 = 16'd77 * {8'd0, r8} + 16'd151 * {8'd0, g8}
                      + 16'd28 * {8'd0, b8};
    wire [7:0]  luma  = lum16[15:8];

    always @(posedge pixel_clk) begin
        if (pixel_rst) begin
            de_d      <= 1'b0;
            x_cnt     <= 12'd0;
            y_cnt     <= 12'd0;
            ph        <= 1'b0;
            acc_line  <= 1'b0;
            row       <= 9'd0;
            col       <= 9'd0;
            vsync_d   <= 1'b0;
            wr_en     <= 1'b0;
            wr_addr   <= 17'd0;
            wr_data   <= 8'd0;
            frame_tog <= 1'b0;
            wr_cnt    <= 32'd0;
        end else begin
            de_d  <= pixel_de;
            wr_en <= 1'b0;

            if (de_rise) begin
                // ---------------------------------------------- line start
                x_cnt <= 12'd0;
                ph    <= 1'b0;
                col   <= 9'd0;

                if (y_cnt < CROP_H) begin
                    acc_line <= ~acc_line;      // take every second line
                    if (y_cnt == CROP_H - 12'd1) begin
                        y_cnt <= 12'd0;
                        row   <= 9'd0;
                    end else begin
                        y_cnt <= y_cnt + 12'd1;
                        if (acc_line) row <= row + 9'd1;
                    end
                end else begin
                    acc_line <= 1'b0;
                end
            end else if (pixel_de) begin
                x_cnt <= x_cnt + 12'd1;
                ph    <= ~ph;

                // every second pixel of every second line becomes a cell
                if (!ph && acc_line && (x_cnt < CROP_W)) begin
                    wr_en   <= 1'b1;
                    wr_addr <= {row, col};
                    wr_data <= luma;
                    wr_cnt  <= wr_cnt + 32'd1;
                    if (col == 9'd319) col <= 9'd0;
                    else               col <= col + 9'd1;
                end
            end

            vsync_d <= pixel_vsync;
            if (pixel_vsync && !vsync_d) begin
                y_cnt     <= 12'd0;
                row       <= 9'd0;
                col       <= 9'd0;
                ph        <= 1'b0;
                acc_line  <= 1'b0;
                frame_tog <= ~frame_tog;
            end
        end
    end
endmodule
