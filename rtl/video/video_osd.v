`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// video_osd - draws the detector box on the HDMI output.
//
// The box arrives from the SoC on clk_27m (four coordinates plus a toggle that
// flips on every commit); the pixel side synchronises that toggle and latches
// the coordinates, so the overlay is stable while the box is unchanged.
//
// Border only: a filled rectangle would hide the object being detected.
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

    always @(posedge pix_clk) begin
        if (pix_rst) begin
            tog_s <= 3'd0;
            x0_q  <= 12'd0;
            y0_q  <= 12'd0;
            x1_q  <= 12'd0;
            y1_q  <= 12'd0;
            v_q   <= 1'b0;
        end else begin
            tog_s <= {tog_s[1:0], box_tog};
            if (tog_s[2] ^ tog_s[1]) begin
                x0_q <= box_x0;
                y0_q <= box_y0;
                x1_q <= box_x1;
                y1_q <= box_y1;
                v_q  <= box_valid;
            end
        end
    end

    wire inside_x = (x >= x0_q) && (x < x1_q);
    wire inside_y = (y >= y0_q) && (y < y1_q);
    wire on_edge  = (x == x0_q) || (x == x1_q - 12'd1) ||
                    (y == y0_q) || (y == y1_q - 12'd1);
    wire draw = v_q && de && inside_x && inside_y && on_edge;

    assign r_out = draw ? 8'h00 : r_in;
    assign g_out = draw ? 8'hff : g_in;
    assign b_out = draw ? 8'h00 : b_in;
endmodule
