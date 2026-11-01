// ---------------------------------------------------------------------------
// video_hdmi_wrap - 720p30 timing + test pattern + RGB565->RGB888 + MS7210
//
// Pixel datapath is registered on pix_clk, matching the vendor top.  The
// framebuffer read enable is sync_vg.de_re (2 px early); rd_vsync is the
// sync_vg vs_out, not the registered output.
// ---------------------------------------------------------------------------
`include "video_defs.vh"

module video_hdmi_wrap #(
    // S2: use the framebuf's vout_de as the output DE (vendor top behaviour).
    parameter integer USE_EXT_DE = 0
) (
    input  wire        pix_clk,
    input  wire        pix_rst,
    input  wire        cfg_clk,
    input  wire        cfg_rst,
    input  wire        phy_rstn,        // active low, from video_clk_reset
    input  wire [15:0] vout_rgb565,
    input  wire        ext_de,
    input  wire [1:0]  pattern_mode,
    output wire        rd_en,
    output wire        rd_vsync,
    output wire [11:0] x_act,
    output wire [11:0] y_act,
    output wire        de_out,
    output wire        hs_out,
    output wire        vs_out,
    output wire [7:0]  r_out,
    output wire [7:0]  g_out,
    output wire [7:0]  b_out,
    output wire        hdmi_init_done,
    output wire        iic_scl,
    inout  wire        iic_sda
);

    // ------------------------------------------------------------- timing
    wire        vs;
    wire        hs;
    wire        de;
    wire        de_re;
    wire [11:0] x_cnt;
    wire [11:0] y_cnt;

    sync_vg #(
        .X_BITS  (12),
        .Y_BITS  (12),
        .V_TOTAL (`VIDEO_V_TOTAL),
        .V_FP    (`VIDEO_V_FP),
        .V_BP    (`VIDEO_V_BP),
        .V_SYNC  (`VIDEO_V_SYNC),
        .V_ACT   (`VIDEO_V_ACT),
        .H_TOTAL (`VIDEO_H_TOTAL),
        .H_FP    (`VIDEO_H_FP),
        .H_BP    (`VIDEO_H_BP),
        .H_SYNC  (`VIDEO_H_SYNC),
        .H_ACT   (`VIDEO_H_ACT),
        .HV_OFFSET(12'd0)
    ) u_sync_vg (
        .clk    (pix_clk),
        .rstn   (~pix_rst),
        .vs_out (vs),
        .hs_out (hs),
        .de_out (de),
        .de_re  (de_re),
        .x_act  (x_cnt),
        .y_act  (y_cnt)
    );

    assign x_act   = x_cnt;
    assign y_act   = y_cnt;
    assign rd_en   = de_re;
    assign rd_vsync = vs;

    // ------------------------------------------------------- pattern source
    reg         vs_d;
    reg  [31:0] frame_cnt;

    always @(posedge pix_clk) begin
        if (pix_rst) begin
            vs_d      <= 1'b0;
            frame_cnt <= 32'd0;
        end else begin
            vs_d <= vs;
            if (vs && !vs_d) begin
                frame_cnt <= frame_cnt + 32'd1;
            end
        end
    end

    wire [15:0] pattern_rgb;

    video_pattern_gen u_pattern (
        .clk       (pix_clk),
        .rst       (pix_rst),
        .de        (de),
        .x         (x_cnt),
        .y         (y_cnt),
        .mode      (pattern_mode),
        .frame_cnt (frame_cnt),
        .rgb565    (pattern_rgb)
    );

    wire de_sel = (USE_EXT_DE != 0) ? ext_de : de;

    reg [15:0] rgb_mux;
    always @(*) begin
        if (pattern_mode != `VIDEO_PAT_OFF) begin
            rgb_mux = pattern_rgb;
        end else begin
            rgb_mux = vout_rgb565;
        end
    end

    // ------------------------------------------------------ output pipeline
    reg        de_q;
    reg        hs_q;
    reg        vs_q;
    reg [7:0]  r_q;
    reg [7:0]  g_q;
    reg [7:0]  b_q;

    always @(posedge pix_clk) begin
        if (pix_rst) begin
            de_q <= 1'b0;
            hs_q <= 1'b0;
            vs_q <= 1'b0;
            r_q  <= 8'd0;
            g_q  <= 8'd0;
            b_q  <= 8'd0;
        end else begin
            de_q <= de_sel;
            hs_q <= hs;
            vs_q <= vs;
            r_q  <= {rgb_mux[15:11], 3'b000};
            g_q  <= {rgb_mux[10:5],  2'b00};
            b_q  <= {rgb_mux[4:0],   3'b000};
        end
    end

    assign de_out = de_q;
    assign hs_out = hs_q;
    assign vs_out = vs_q;
    assign r_out  = r_q;
    assign g_out  = g_q;
    assign b_out  = b_q;

    // ------------------------------------------------------- MS7210 init
`ifdef VIDEO_SIM
    // No MS7210 I2C slave model in the unit testbench: report init done so the
    // video timing/pattern checks can run.  The real FSM is used by PDS.
    assign hdmi_init_done = 1'b1;
    assign iic_scl        = 1'b1;
    assign iic_sda        = 1'bz;
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_sim = &{1'b0, cfg_clk, cfg_rst, phy_rstn};
    /* verilator lint_on UNUSEDSIGNAL */
`else
    wire        ms_rstn = phy_rstn & ~cfg_rst;

    wire        ms_trig;
    wire        ms_wr;
    wire [15:0] ms_addr;
    wire [7:0]  ms_data_in;
    wire [7:0]  ms_data_out;
    wire [7:0]  ms_device_id;
    wire        ms_busy;
    wire        ms_byte_over;

    wire        sda_in;
    wire        sda_out;
    wire        sda_out_en;

    ms7210_ctl u_ms7210 (
        .clk       (cfg_clk),
        .rstn      (ms_rstn),
        .init_over (hdmi_init_done),
        .device_id (ms_device_id),
        .iic_trig  (ms_trig),
        .w_r       (ms_wr),
        .addr      (ms_addr),
        .data_in   (ms_data_in),
        .busy      (ms_busy),
        .data_out  (ms_data_out),
        .byte_over (ms_byte_over)
    );

    iic_dri #(
        .CLK_FRE   (27'd10_000_000),
        .IIC_FREQ  (20'd400_000),
        .T_WR      (10'd1),
        .ADDR_BYTE (2'd2),
        .LEN_WIDTH (8'd3),
        .DATA_BYTE (2'd1)
    ) u_iic (
        .clk       (cfg_clk),
        .rstn      (ms_rstn),
        .device_id (8'hB2),
        .pluse     (ms_trig),
        .w_r       (ms_wr),
        .byte_len  (4'd1),
        .addr      (ms_addr),
        .data_in   (ms_data_in),
        .busy      (ms_busy),
        .byte_over (ms_byte_over),
        .data_out  (ms_data_out),
        .scl       (iic_scl),
        .sda_in    (sda_in),
        .sda_out   (sda_out),
        .sda_out_en(sda_out_en)
    );

    assign iic_sda = sda_out_en ? sda_out : 1'bz;
    assign sda_in  = iic_sda;

    // ms7210_ctl.device_id is a constant 0xB2; the I2C master uses 0xB2 directly.
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, ms_device_id};
    /* verilator lint_on UNUSEDSIGNAL */
`endif

endmodule
