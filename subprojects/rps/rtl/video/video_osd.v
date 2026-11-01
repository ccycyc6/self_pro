`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// video_osd - draws up to four detector boxes plus a short numeric readout.
//
// Everything arrives from the SoC on clk_27m and is latched in the pixel clock
// domain behind one toggle, so nothing flickers while the values are unchanged.
//
//   boxes : 4 x 48 bits {x1, y1, x0, y0}; a box is drawn while x1 > x0
//   text  : 8 glyphs from video_font, 2x scale, bottom left
// ---------------------------------------------------------------------------
module video_osd (
    input  wire         pix_clk,
    input  wire         pix_rst,

    input  wire [11:0]  x,
    input  wire [11:0]  y,
    input  wire         de,

    input  wire [191:0] boxes,
    input  wire         box_tog,
    input  wire [39:0]  text_chars,

    input  wire [7:0]   r_in,
    input  wire [7:0]   g_in,
    input  wire [7:0]   b_in,
    output wire [7:0]   r_out,
    output wire [7:0]   g_out,
    output wire [7:0]   b_out
);
    reg [2:0]   tog_s;
    reg [191:0] bx_q;
    reg [39:0]  txt_q;

    always @(posedge pix_clk) begin
        if (pix_rst) begin
            tog_s <= 3'd0;
            bx_q  <= 192'd0;
            txt_q <= 40'd0;
        end else begin
            tog_s <= {tog_s[1:0], box_tog};
            if (tog_s[2] ^ tog_s[1]) begin
                bx_q  <= boxes;
                txt_q <= text_chars;
            end
        end
    end

    // ------------------------------------------------------------- the boxes
    function automatic edge_hit(input [191:0] b, input integer i,
                                input [11:0] px, input [11:0] py);
        reg [11:0] x0, y0, x1, y1;
        begin
            x0 = b[i*48 + 11 -: 12];
            y0 = b[i*48 + 23 -: 12];
            x1 = b[i*48 + 35 -: 12];
            y1 = b[i*48 + 47 -: 12];
            edge_hit = (x1 > x0) && (y1 > y0) &&
                       (px >= x0) && (px < x1) &&
                       (py >= y0) && (py < y1) &&
                       ((px == x0) || (px == x1 - 12'd1) ||
                        (py == y0) || (py == y1 - 12'd1));
        end
    endfunction

    wire draw_box = de &&
                    (edge_hit(bx_q, 0, x, y) || edge_hit(bx_q, 1, x, y) ||
                     edge_hit(bx_q, 2, x, y) || edge_hit(bx_q, 3, x, y));

    // -------------------------------------------------------------- the text
    localparam [11:0] TX0 = 12'd40;
    localparam [11:0] TY0 = 12'd640;

    wire [11:0] tx = x - TX0;
    wire [11:0] ty = y - TY0;
    wire in_text = de && (x >= TX0) && (x < TX0 + 12'd128) &&
                        (y >= TY0) && (y < TY0 + 12'd16);

    reg [4:0] ch;
    always @(*) begin
        case (tx[6:4])
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
        .row (ty[3:1]),
        .bits(glyph_row)
    );

    wire draw_text = in_text &&
                     (((glyph_row >> (3'd7 - tx[3:1])) & 8'h01) != 8'h00);

    assign r_out = draw_box ? 8'h00 : (draw_text ? 8'hFF : r_in);
    assign g_out = draw_box ? 8'hFF : (draw_text ? 8'hFF : g_in);
    assign b_out = draw_box ? 8'h00 : (draw_text ? 8'hFF : b_in);
endmodule
