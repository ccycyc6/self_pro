`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// cam_fifo - small asynchronous FIFO (gray pointers) for the camera thumbnail.
//
// The capture side produces only 1024 samples per frame (about 31k/s at 30 fps)
// on the 42 MHz pixel clock, so a shallow FIFO is enough to hand them to the
// 27 MHz SoC side.  This exists because a true dual-port block RAM (write on
// the pixel clock, read on clk_27m) was not inferred by PDS: reads came back
// as zero.  A single-clock RAM behind this FIFO is portable.
// ---------------------------------------------------------------------------
module cam_fifo #(
    parameter integer WIDTH = 27,
    parameter integer AW    = 5,          // 32 entries
    parameter integer DEPTH = 32
) (
    input  wire             wr_clk,
    input  wire             wr_rst,       // active high
    input  wire             wr_en,
    input  wire [WIDTH-1:0] wr_data,
    output wire             full,

    input  wire             rd_clk,
    input  wire             rd_rst,       // active high
    input  wire             rd_en,
    output wire [WIDTH-1:0] rd_data,
    output wire             empty
);
    reg [WIDTH-1:0] mem [0:DEPTH-1];

    reg [AW:0] wbin, wgray, rbin, rgray;
    reg [AW:0] rgray_w1, rgray_w2;        // read pointer, write domain
    reg [AW:0] wgray_r1, wgray_r2;        // write pointer, read domain

    wire [AW:0] wbin_nxt  = wbin + {{AW{1'b0}}, 1'b1};
    wire [AW:0] wgray_nxt = (wbin_nxt >> 1) ^ wbin_nxt;
    wire [AW:0] rbin_nxt  = rbin + {{AW{1'b0}}, 1'b1};
    wire [AW:0] rgray_nxt = (rbin_nxt >> 1) ^ rbin_nxt;

    assign full  = (wgray_nxt == {~rgray_w2[AW:AW-1], rgray_w2[AW-2:0]});
    assign empty = (rgray == wgray_r2);
    assign rd_data = mem[rbin[AW-1:0]];

    always @(posedge wr_clk) begin
        if (wr_en && !full) mem[wbin[AW-1:0]] <= wr_data;
    end

    always @(posedge wr_clk) begin
        if (wr_rst) begin
            wbin <= 0; wgray <= 0;
            rgray_w1 <= 0; rgray_w2 <= 0;
        end else begin
            if (wr_en && !full) begin
                wbin  <= wbin_nxt;
                wgray <= wgray_nxt;
            end
            rgray_w1 <= rgray;
            rgray_w2 <= rgray_w1;
        end
    end

    always @(posedge rd_clk) begin
        if (rd_rst) begin
            rbin <= 0; rgray <= 0;
            wgray_r1 <= 0; wgray_r2 <= 0;
        end else begin
            if (rd_en && !empty) begin
                rbin  <= rbin_nxt;
                rgray <= rgray_nxt;
            end
            wgray_r1 <= wgray;
            wgray_r2 <= wgray_r1;
        end
    end
endmodule
