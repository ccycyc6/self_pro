`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// cam_cap - 32x32 thumbnail of the camera picture.
//
// Line structure is taken from the rising edge of pixel_de (start of an active
// line) rather than from blanking, so it does not depend on how long the
// blanking interval happens to be:
//   * pixel index resets at every de rising edge
//   * line index increments at every de rising edge, resets at vsync
// Sampling: x in [320,960), y in [40,680), every 20th pixel and every 20th
// line, which makes each cell exactly 20x20 display pixels.
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
    output reg  [23:0] dbg           // {line[11:0], pixel[11:0]}
);
    reg        de_d;
    reg [11:0] pix;
    reg [11:0] ln;
    reg [4:0]  cnt20;        // pixel phase inside a cell
    reg [4:0]  l20;          // line phase inside a cell
    reg        line_ok;      // this line contributes a row of cells
    reg [4:0]  gx, gy, gy_cur;
    reg        vsync_d;
    reg        wr_bank;

    // Horizontal 4:1 box filter inside each cell.  Point sampling dropped small,
    // distant objects: a 30-pixel object covers less than two cells and one
    // sample per cell usually landed on the background.  The four samples live
    // inside a single cell window, so this needs one accumulator, not per-cell
    // state.
    reg [7:0]  acc_r, acc_b;
    reg [8:0]  acc_g;

    wire de_rise = pixel_de && !de_d;
    wire in_x    = (pix >= 12'd320) && (pix < 12'd960);

    wire samp = (cnt20 == 5'd19) || (cnt20 == 5'd14) ||
                (cnt20 == 5'd9)  || (cnt20 == 5'd4);
    wire [4:0] s_r = pixel_rgb565[15:11];
    wire [5:0] s_g = pixel_rgb565[10:5];
    wire [4:0] s_b = pixel_rgb565[4:0];
    wire [7:0] sum_r = acc_r + {3'd0, s_r};
    wire [8:0] sum_g = acc_g + {3'd0, s_g};
    wire [7:0] sum_b = acc_b + {3'd0, s_b};

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
            acc_r  <= 8'd0;
            acc_g  <= 9'd0;
            acc_b  <= 8'd0;
        end else begin
            de_d  <= pixel_de;
            wr_en <= 1'b0;
            dbg   <= {ln[11:0], pix[11:0]};

            // ------------------------------------------------ start of line
            if (de_rise) begin
                pix  <= 12'd0;
                gx   <= 5'd0;
                cnt20 <= 5'd0;

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
                    if (line_ok && samp) begin
                        // four evenly spaced samples inside the cell window; the
                        // first one starts the sum, the rest add to it.
                        acc_r <= (cnt20 == 5'd19) ? {3'd0, s_r} : sum_r;
                        acc_g <= (cnt20 == 5'd19) ? {3'd0, s_g} : sum_g;
                        acc_b <= (cnt20 == 5'd19) ? {3'd0, s_b} : sum_b;
                    end

                    if (cnt20 == 5'd0) begin
                        cnt20  <= 5'd19;
                        if (line_ok) begin
                            wr_en   <= 1'b1;
                            // sum/4: R and B are 5-bit channels (sum <= 124),
                            // G is 6-bit (sum <= 252).
                            wr_data <= {wr_bank, gy_cur, gx,
                                        acc_r[6:2], acc_g[7:2], acc_b[6:2]};
                            wr_cnt  <= wr_cnt + 32'd1;
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
                wr_bank  <= ~wr_bank;
                frame_tog <= ~frame_tog;
            end
        end
    end
endmodule
