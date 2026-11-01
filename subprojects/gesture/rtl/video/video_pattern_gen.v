// ---------------------------------------------------------------------------
// video_pattern_gen - color bar / checker / moving box
//
// Combinational RGB565 generator.  The caller registers the result on the
// pixel clock together with DE/HS/VS.
// ---------------------------------------------------------------------------
`include "video_defs.vh"

module video_pattern_gen (
    input  wire        clk,
    input  wire        rst,
    input  wire        de,
    input  wire [11:0] x,
    input  wire [11:0] y,
    input  wire [1:0]  mode,
    input  wire [31:0] frame_cnt,
    output wire [15:0] rgb565
);

    reg [15:0] rgb;

    // The generator is combinational; clk/rst are kept in the contract so the
    // caller can swap in a registered implementation without changing ports.
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, clk, rst, frame_cnt[31:8]};
    /* verilator lint_on UNUSEDSIGNAL */

    // 160 px wide box, moving 4 px per frame.
    wire [11:0] box_x = 12'd160 + {2'b00, frame_cnt[7:0], 2'b00};
    wire [11:0] box_y = 12'd280;

    always @(*) begin
        rgb = 16'h0000;
        if (de) begin
            case (mode)
                `VIDEO_PAT_BAR: begin
                    if      (x < 12'd160)  rgb = 16'hFFFF; // white
                    else if (x < 12'd320)  rgb = 16'hFFE0; // yellow
                    else if (x < 12'd480)  rgb = 16'h07FF; // cyan
                    else if (x < 12'd640)  rgb = 16'h07E0; // green
                    else if (x < 12'd800)  rgb = 16'hF81F; // magenta
                    else if (x < 12'd960)  rgb = 16'hF800; // red
                    else if (x < 12'd1120) rgb = 16'h001F; // blue
                    else                   rgb = 16'h0000; // black
                end
                `VIDEO_PAT_CHECKER: begin
                    rgb = (x[6] ^ y[6]) ? 16'hFFFF : 16'h0000;
                end
                `VIDEO_PAT_MOVING_BOX: begin
                    if ((x >= box_x) && (x < box_x + 12'd160) &&
                        (y >= box_y) && (y < box_y + 12'd120)) begin
                        rgb = 16'hFFFF;
                    end else begin
                        rgb = 16'h001F;
                    end
                end
                default: rgb = 16'h0000;
            endcase
        end
    end

    assign rgb565 = rgb;

endmodule
