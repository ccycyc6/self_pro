`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// video_osd - draws the detector box and a short numeric readout on the HDMI
// output.
//
// Both layers arrive from the SoC on clk_27m and are latched in the pixel clock
// domain behind a toggle, so nothing flickers while the values are unchanged.
//
//   box  : green outline, 1 px
//   text : 8 glyphs from video_font, 2x scale, bottom left
// ---------------------------------------------------------------------------
module video_osd (
    input  wire        pix_clk,
    input  wire        pix_rst,

    input  wire [11:0] x,
    input  wire [11:0] y,
    input  wire        de,

    // SoC side (clk_27m)
    input  wire [11:0] box_x0,
    input  wire [11:0] box_y0,
    input  wire [11:0] box_x1,
    input  wire [11:0] box_y1,
    input  wire        box_valid,
    input  wire        box_tog,
    input  wire [39:0] text_chars,   // 8 x 5-bit glyph index

    input  wire [7:0]  r_in,
    input  wire [7:0]  g_in,
    input  wire [7:0]  b_in,
    output wire [7:0]  r_out,
    output wire [7:0]  g_out,
    output wire [7:0]  b_out
);
    reg [2:0]  tog_s;
    reg [11:0] x0_q, y0_q, x1_q, y1_q;
    reg        v_q;
    reg [39:0] txt_q;

    always @(posedge pix_clk) begin
        if (pix_rst) begin
            tog_s <= 3'd0;
            x0_q  <= 12'd0;
            y0_q  <= 12'd0;
            x1_q  <= 12'd0;
            y1_q  <= 12'd0;
            v_q   <= 1'b0;
            txt_q <= 40'd0;
        end else begin
            tog_s <= {tog_s[1:0], box_tog};
            if (tog_s[2] ^ tog_s[1]) begin
                x0_q  <= box_x0;
                y0_q  <= box_y0;
                x1_q  <= box_x1;
                y1_q  <= box_y1;
                v_q   <= box_valid;
                txt_q <= text_chars;
            end
        end
    end

    // --------------------------------------------------------------- the box
    wire inside_x = (x >= x0_q) && (x < x1_q);
    wire inside_y = (y >= y0_q) && (y < y1_q);
    wire on_edge  = (x == x0_q) || (x == x1_q - 12'd1) ||
                    (y == y0_q) || (y == y1_q - 12'd1);
    wire draw_box = v_q && de && inside_x && inside_y && on_edge;

    // -------------------------------------------------------------- the text
    // 8 glyphs of 16x16 pixels at (40, 640): a power-of-two cell keeps the
    // indexing to shifts, which is what makes this cheap.
    localparam [11:0] TX0 = 12'd40;
    localparam [11:0] TY0 = 12'd640;

    wire [11:0] tx = x - TX0;
    wire [11:0] ty = y - TY0;
    wire in_text = de && (x >= TX0) && (x < TX0 + 12'd128) &&
                        (y >= TY0) && (y < TY0 + 12'd16);

    wire [2:0] ci = tx[6:4];
    wire [2:0] gx = tx[3:1];
    wire [2:0] gy = ty[3:1];

    reg [4:0] ch;
    always @(*) begin
        case (ci)
            3'd0: ch = txt_q[4:0];
            3'd1: ch = txt_q[9:5];
            3'd2: ch = txt_q[14:10];
            3'd3: ch = txt_q[19:15];
            3'd4: ch = txt_q[24:20];
            3'd5: ch = txt_q[29:25];
            3'd6: ch = txt_q[34:30];
            default: ch = txt_q[39:35];
        endcase
    end

    wire [7:0] glyph_row;
    video_font u_font (
        .ch  (ch),
        .row (gy),
        .bits(glyph_row)
    );

    wire draw_text = in_text &&
                     (((glyph_row >> (3'd7 - gx)) & 8'h01) != 8'h00);

    assign r_out = draw_box ? 8'h00 : (draw_text ? 8'hFF : r_in);
    assign g_out = draw_box ? 8'hFF : (draw_text ? 8'hFF : g_in);
    assign b_out = draw_box ? 8'h00 : (draw_text ? 8'hFF : b_in);
endmodule
