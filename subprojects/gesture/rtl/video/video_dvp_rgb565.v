// ---------------------------------------------------------------------------
// video_dvp_rgb565 - OV5640 DVP 8-bit -> RGB565, deterministic byte pairing
//
// Replaces the vendor cmos_8_16bit for our capture path.  The vendor module
// keeps its byte phase (cnt) across HREF low and only clears it on the
// /2 clock divider reset, so:
//   * a line with an odd number of captured bytes, or
//   * any extra HREF pulse / glitch in the blanking,
// flips the {first,second} byte order for the lines that follow.  On the
// board that shows up as horizontal bands of byte-swapped (green/blue/magenta)
// colour.  The Gowin OV5640 reference (Gowin_FPGA_CV ov5640_data.v) clears its
// data_flag on every HREF low; this module does the same.
//
// Everything else matches the vendor pipeline so the downstream /2 pixel-clock
// sampling phase is unchanged:
//   in-reg (video_capture_wrap) -> pair -> 3 pipeline stages -> pdata_o/de_o
//   pixel_clk = pclk / 2 via GTP_IOCLKDIV_E2, enabled on the first vsync rise
//
// Sensor output order is BGR565 (0x4300=0x60, RGB565 sequence 0); the wrapper
// normalizes it to RGB565.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps

module video_dvp_rgb565 (
    input  wire        pclk,
    input  wire        rst_n,
    input  wire        de_i,            // HREF, high during active pixels
    input  wire [7:0]  pdata_i,         // DVP byte, first byte first
    input  wire        vs_i,            // VSYNC, active high
    output wire        pixel_clk,       // pclk / 2
    output reg         de_o,
    output reg  [15:0] pdata_o
);

    // ------------------------------------------------ /2 pixel clock (vendor)
    reg vs_i_reg;
    reg enble;

    always @(posedge pclk) begin
        vs_i_reg <= vs_i;
    end

    always @(posedge pclk) begin
        if (!rst_n)
            enble <= 1'b0;
        else if (!vs_i_reg && vs_i)
            enble <= 1'b1;
    end

    GTP_IOCLKDIV_E2 #(
        .DIV_FACTOR("2")
    ) u_div (
        .CLKDIVOUT (pixel_clk),
        .CE        (1'b1),
        .CLKIN     (pclk),
        .RST_N     (enble)
    );

    // ------------------------------------------------------- byte pairing
    // phase is forced to "first byte" while HREF is low, so every line starts
    // on a byte boundary no matter what happened in the previous line.
    reg        phase;
    reg [7:0]  first_byte;
    reg [15:0] pix1;

    always @(posedge pclk) begin
        if (!rst_n) begin
            phase      <= 1'b0;
            first_byte <= 8'd0;
            pix1       <= 16'd0;
        end else if (!de_i) begin
            phase      <= 1'b0;
            first_byte <= 8'd0;
        end else begin
            if (!phase)
                first_byte <= pdata_i;
            else
                pix1       <= {first_byte, pdata_i};
            phase <= ~phase;
        end
    end

    // ------------------------------------------- DE and data pipeline (3 deep)
    reg de_i_r;
    reg de_i_r1;
    reg de_out1;

    always @(posedge pclk) begin
        de_i_r  <= de_i;
        de_i_r1 <= de_i_r;
    end

    always @(posedge pclk) begin
        if (!rst_n)
            de_out1 <= 1'b0;
        else if (!de_i_r1 && de_i_r)
            de_out1 <= 1'b1;
        else if (de_i_r1 && !de_i_r)
            de_out1 <= 1'b0;
    end

    reg [15:0] pix2;
    reg [15:0] pix3;
    reg        de_out2;
    reg        de_out3;

    always @(posedge pclk) begin
        pix2    <= pix1;
        pix3    <= pix2;
        pdata_o <= pix3;

        de_out2 <= de_out1;
        de_out3 <= de_out2;
        de_o    <= de_out3;
    end

endmodule
