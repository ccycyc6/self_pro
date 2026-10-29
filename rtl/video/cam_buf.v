`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// cam_buf - dual-clock frame store for the 32x32 camera thumbnail.
//
// two banks of 1024 x 16-bit RGB565 (4 KiB each).  The capture side writes on
// the camera pixel clock, the SoC reads on clk_27m; a true dual-port block RAM
// is the only structure that can do both without a CDC handshake per sample.
// ---------------------------------------------------------------------------
module cam_buf (
    // capture side (pixel clock)
    input  wire        wr_clk,
    input  wire        wr_en,
    input  wire [10:0] wr_addr,
    input  wire        wr_bank,
    input  wire [15:0] wr_data,
    // SoC side (clk_27m)
    input  wire        rd_clk,
    input  wire [10:0] rd_addr,
    input  wire        rd_bank,
    output reg  [15:0] rd_data
);
    reg [15:0] mem [0:2047];

    always @(posedge wr_clk) begin
        if (wr_en) mem[{wr_bank, wr_addr}] <= wr_data;
    end

    always @(posedge rd_clk) begin
        rd_data <= mem[{rd_bank, rd_addr}];
    end
endmodule
