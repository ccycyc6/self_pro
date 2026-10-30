`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// cam_cap - 32x32 thumbnail of the camera picture.
//
// Crop: x in [320,960), y in [40,680) of the 1280x720 stream, then 20:1 on both
// axes, so each cell is exactly 20x20 display pixels.
//
// Each cell AVERAGES 16 samples (4x4, every 5th pixel/line).  Point sampling
// was the reason small, distant objects vanished: a 30-pixel object covers less
// than two cells, and one sample per cell usually landed on the background.
//
// Output word {bank, addr[10:0], rgb565[15:0]} goes into a small asynchronous
// FIFO (PDS would not infer a true dual-port RAM for the pixel/SoC boundary).
// ---------------------------------------------------------------------------
module cam_cap (
    input  wire        pixel_clk,
    input  wire        pixel_rst,
    input  wire        pixel_de,
    input  wire [15:0] pixel_rgb565,
    input  wire        pixel_vsync,

    output reg         wr_en,
    output reg  [27:0] wr_data,
    output reg         frame_tog,
    output reg  [31:0] wr_cnt,
    output reg  [23:0] dbg
);
    reg        de_d;
    reg [11:0] pix;
    reg [11:0] ln;
    reg [4:0]  cnt20;        // pixel phase inside a cell
    reg [4:0]  l20;          // line phase inside a cell
    reg        line_ok;
    reg [4:0]  gx, gy, gy_cur;
    reg        vsync_d;
    reg        wr_bank;

    // 4x4 sample accumulation
    reg [8:0]  acc_r, acc_b;
    reg [9:0]  acc_g;
    reg [3:0]  nacc;

    wire de_rise = pixel_de && !de_d;
    wire in_x    = (pix >= 12'd320) && (pix < 12'd960);

    // sample every fifth pixel and every fifth line inside the crop
    wire xsub = (xph_ok(cnt20));
    wire ysub = (xph_ok(l20));

    function automatic xph_ok(input [4:0] ph);
        xph_ok = (ph == 5'd0) || (ph == 5'd5) || (ph == 5'd10) || (ph == 5'd15);
    endfunction

    wire [4:0] s_r = pixel_rgb565[15:11];
    wire [5:0] s_g = pixel_rgb565[10:5];
    wire [4:0] s_b = pixel_rgb565[4:0];

    // Running sum including the sample arriving this cycle, then /16 by taking
    // the bits above the low four.
    wire [8:0]  sum_r = acc_r + {4'd0, s_r};
    wire [9:0]  sum_g = acc_g + {4'd0, s_g};
    wire [8:0]  sum_b = acc_b + {4'd0, s_b};
    wire [4:0]  avg_r = sum_r[8:4];
    wire [5:0]  avg_g = sum_g[9:4];
    wire [4:0]  avg_b = sum_b[8:4];

    always @(posedge pixel_clk) begin
        if (pixel_rst) begin
            de_d   <= 1'b0;
            pix    <= 12'd0;
            ln     <= 12'd0;
            cnt20  <= 5'd0;
            l20    <= 5'd0;
            line_ok <= 1'b0;
            gx     <= 5'd0;
            gy     <= 5'd0;
            gy_cur <= 5'd0;
            vsync_d <= 1'b0;
            wr_bank <= 1'b0;
            wr_en  <= 1'b0;
            wr_data <= 28'd0;
            frame_tog <= 1'b0;
            wr_cnt <= 32'd0;
            dbg    <= 24'd0;
            acc_r  <= 9'd0;
            acc_g  <= 10'd0;
            acc_b  <= 9'd0;
            nacc   <= 4'd0;
        end else begin
            de_d  <= pixel_de;
            wr_en <= 1'b0;
            dbg   <= {ln[11:0], pix[11:0]};

            // ------------------------------------------------ start of line
            if (de_rise) begin
                pix   <= 12'd0;
                gx    <= 5'd0;
                cnt20 <= 5'd0;
                nacc  <= 4'd0;
                acc_r <= 9'd0;
                acc_g <= 10'd0;
                acc_b <= 9'd0;

                if (ln == 12'd719) ln <= 12'd0;
                else               ln <= ln + 12'd1;

                if ((ln >= 12'd40) && (ln < 12'd680) && (l20 == 5'd0)) begin
                    line_ok <= 1'b1;
                    gy_cur  <= gy;
                    if (gy == 5'd31) gy <= 5'd0;
                    else             gy <= gy + 5'd1;
                end else begin
                    line_ok <= 1'b0;
                end

                if ((ln >= 12'd40) && (ln < 12'd680)) begin
                    if (l20 == 5'd19) l20 <= 5'd0;
                    else              l20 <= l20 + 5'd1;
                end else begin
                    l20 <= 5'd0;
                end
            end else if (pixel_de) begin
                // -------------------------------------------- one pixel in
                pix <= pix + 12'd1;

                if (in_x) begin
                    if (line_ok && xsub && ysub) begin
                        acc_r <= acc_r + {4'd0, s_r};
                        acc_g <= acc_g + {4'd0, s_g};
                        acc_b <= acc_b + {4'd0, s_b};

                        if (nacc == 4'd15) begin
                            wr_en   <= 1'b1;
                            wr_data <= {wr_bank, gy_cur, gx,
                                        avg_r, avg_g, avg_b};
                            wr_cnt  <= wr_cnt + 32'd1;
                            nacc    <= 4'd0;
                        end else begin
                            nacc <= nacc + 4'd1;
                        end
                    end

                    if (cnt20 == 5'd0) begin
                        cnt20 <= 5'd19;
                        if (line_ok) begin
                            if (gx == 5'd31) gx <= 5'd0;
                            else             gx <= gx + 5'd1;
                        end
                    end else begin
                        cnt20 <= cnt20 - 5'd1;
                    end
                end else begin
                    cnt20 <= 5'd0;
                end
            end

            // ------------------------------------------------------ frame end
            vsync_d <= pixel_vsync;
            if (pixel_vsync && !vsync_d) begin
                ln       <= 12'd0;
                l20      <= 5'd0;
                gy       <= 5'd0;
                line_ok  <= 1'b0;
                nacc     <= 4'd0;
                acc_r    <= 9'd0;
                acc_g    <= 10'd0;
                acc_b    <= 9'd0;
                wr_bank  <= ~wr_bank;
                frame_tog <= ~frame_tog;
            end
        end
    end
endmodule
