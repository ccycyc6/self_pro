`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// cam_cap - 32x32 thumbnail of the camera picture.
//
// Crop: x in [320,960), y in [40,680) of the 1280x720 stream, then decimate
// 20:1 on both axes.  Each cell is therefore exactly 20x20 display pixels,
// which is what makes the OSD box trivial to place later.
//
// Writes alternate between two banks every frame; frame_tog flips on vsync and
// is synchronised in the SoC clock domain (see ares_cam_if).
// ---------------------------------------------------------------------------
module cam_cap (
    input  wire        pixel_clk,
    input  wire        pixel_rst,
    input  wire        pixel_de,
    input  wire [15:0] pixel_rgb565,
    input  wire        pixel_vsync,

    output reg         wr_en,
    output reg  [10:0] wr_addr,
    output reg         wr_bank,
    output reg  [15:0] wr_data,

    output reg         frame_tog
);
    localparam integer X0 = 320;
    localparam integer Y0 = 40;

    reg [10:0] x_cnt;      // 0..1279
    reg [9:0]  y_cnt;      // 0..719
    reg [10:0] gx, gy;     // 0..31
    reg [4:0]  xph, yph;   // 0..19 phase inside a cell

    wire in_x = (x_cnt >= X0) && (x_cnt < X0 + 640);
    wire in_y = (y_cnt >= Y0) && (y_cnt < Y0 + 640);

    wire sample = pixel_de && in_x && in_y && (xph == 5'd0) && (yph == 5'd0);

    always @(posedge pixel_clk) begin
        if (pixel_rst) begin
            x_cnt <= 11'd0;
            y_cnt <= 10'd0;
            gx    <= 11'd0;
            gy    <= 11'd0;
            xph   <= 5'd0;
            yph   <= 5'd0;
            wr_en <= 1'b0;
            wr_addr <= 11'd0;
            wr_data <= 16'd0;
            wr_bank <= 1'b0;
            frame_tog <= 1'b0;
        end else begin
            wr_en <= 1'b0;

            if (pixel_de) begin
                // -------------------------------------------------- write
                if (sample) begin
                    wr_en   <= 1'b1;
                    wr_addr <= {gy[4:0], gx[4:0]};
                    wr_data <= pixel_rgb565;
                end

                // -------------------------------------------------- x phase
                if (in_x) begin
                    if (xph == 5'd19) begin
                        xph <= 5'd0;
                        if (gx == 11'd31) gx <= 11'd0;
                        else              gx <= gx + 11'd1;
                    end else begin
                        xph <= xph + 5'd1;
                    end
                end else begin
                    xph <= 5'd0;
                    gx  <= 11'd0;
                end

                if (x_cnt == 11'd1279) x_cnt <= 11'd0;
                else                   x_cnt <= x_cnt + 11'd1;
            end

            // ------------------------------------------------------ line end
            if (!pixel_de && (x_cnt != 11'd0)) begin
                // one pulse at the end of every active line
                x_cnt <= 11'd0;
                if (y_cnt == 10'd719) y_cnt <= 10'd0;
                else                  y_cnt <= y_cnt + 10'd1;

                if (in_y) begin
                    if (yph == 5'd19) begin
                        yph <= 5'd0;
                        if (gy == 11'd31) gy <= 11'd0;
                        else              gy <= gy + 11'd1;
                    end else begin
                        yph <= yph + 5'd1;
                    end
                end else begin
                    yph <= 5'd0;
                    gy  <= 11'd0;
                end
            end

            // ------------------------------------------------------ frame end
            if (pixel_vsync) begin
                x_cnt <= 11'd0;
                y_cnt <= 10'd0;
                gx    <= 11'd0;
                gy    <= 11'd0;
                xph   <= 5'd0;
                yph   <= 5'd0;
            end
        end
    end

    // ------------------------------------------------------------ bank swap
    reg vsync_d;
    always @(posedge pixel_clk) begin
        if (pixel_rst) begin
            vsync_d   <= 1'b0;
            frame_tog <= 1'b0;
        end else begin
            vsync_d <= pixel_vsync;
            if (pixel_vsync && !vsync_d) begin
                wr_bank   <= ~wr_bank;
                frame_tog <= ~frame_tog;
            end
        end
    end
endmodule
