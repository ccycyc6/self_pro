// ---------------------------------------------------------------------------
// video_fb_top - standalone camera -> DDR3 double buffer -> HDMI (S2)
//
//   OV5640 DVP (J2, CMOS1/CMOS2) -> video_capture_wrap
//     -> legacy fram_buf (vendor double buffer + native AXI master)
//     -> Pango HMIC_S DDR3 IP (I_ips_ddr_top, 600 Mbps)
//     -> video_hdmi_wrap (720p30) -> MS7210 HDMI
//
// No SoC is involved.  The DDR3 IP instance MUST be named I_ips_ddr_top: the
// IP constraint file uses that absolute path.
//
// The framebuf runs its write side on the camera pixel clock and its read side
// on the 37.125 MHz HDMI pixel clock; fram_buf contains the async FIFOs.
// ---------------------------------------------------------------------------
`include "video_defs.vh"

module video_fb_top #(
    parameter integer CAM_SEL = 0,                      // 0=CMOS1, 1=CMOS2
    parameter integer INJECT_PATTERN = 0                // 1 = write test bars instead of camera
) (
    input  wire        clk_27m,
    input  wire        rst_n,

    // ---------------------------------------------------------- OV5640 CMOS1
    output wire        cmos1_reset,
    inout  wire        cmos1_scl,
    inout  wire        cmos1_sda,
    input  wire        cmos1_pclk,
    input  wire        cmos1_vsync,
    input  wire        cmos1_href,
    input  wire [7:0]  cmos1_data,

    // ---------------------------------------------------------- OV5640 CMOS2
    output wire        cmos2_reset,
    inout  wire        cmos2_scl,
    inout  wire        cmos2_sda,
    input  wire        cmos2_pclk,
    input  wire        cmos2_vsync,
    input  wire        cmos2_href,
    input  wire [7:0]  cmos2_data,

    // ------------------------------------------------- DDR3 reference/device
    input  wire        ref_clk_p,
    input  wire        ref_clk_n,
    output wire        mem_rst_n,
    output wire        mem_ck,
    output wire        mem_ck_n,
    output wire        mem_cke,
    output wire        mem_cs_n,
    output wire        mem_ras_n,
    output wire        mem_cas_n,
    output wire        mem_we_n,
    output wire        mem_odt,
    output wire [14:0] mem_a,
    output wire [2:0]  mem_ba,
    inout  wire [3:0]  mem_dqs,
    inout  wire [3:0]  mem_dqs_n,
    inout  wire [31:0] mem_dq,
    output wire [3:0]  mem_dm,

    // ------------------------------------------------------ HDMI TX (MS7210)
    output wire        pix_clk,
    output wire        de_out,
    output wire        hs_out,
    output wire        vs_out,
    output wire [7:0]  r_out,
    output wire [7:0]  g_out,
    output wire [7:0]  b_out,
    output wire        rstn_out,
    output wire        iic_tx_scl,
    inout  wire        iic_tx_sda,

    // ---------------------------------------------------------- board status
    output wire [7:0]  led,
    output wire        uart_tx,
    input  wire        uart_rx        // B24, used by the SoC boot loader
);

    // ------------------------------------------------------- clock / reset
    wire clk_pix;
    wire clk_cfg;
    wire clk_cam;
    wire pll_lock;
    wire rst_sys;
    wire rst_pix;
    wire rst_cfg;
    wire rst_cam;
    wire phy_rstn;

    video_clk_reset u_clk_reset (
        .clk_27m  (clk_27m),
        .rst_n    (rst_n),
        .clk_pix  (clk_pix),
        .clk_cfg  (clk_cfg),
        .clk_cam  (clk_cam),
        .pll_lock (pll_lock),
        .rst_sys  (rst_sys),
        .rst_pix  (rst_pix),
        .rst_cfg  (rst_cfg),
        .rst_cam  (rst_cam),
        .phy_rstn (phy_rstn)
    );

    assign pix_clk  = clk_pix;
    assign rstn_out = phy_rstn;

    // ------------------------------------------------------------ HDMI TX
    wire        hdmi_init_done;
    wire        hdmi_rd_en;
    wire        hdmi_rd_vsync;
    wire [11:0] hdmi_x_act;
    wire [11:0] hdmi_y_act;
    wire [15:0] fb_rgb565;
    wire        fb_vout_de;

    video_hdmi_wrap #(
        .USE_EXT_DE     (1)
    ) u_hdmi (
        .pix_clk        (clk_pix),
        .pix_rst        (rst_pix),
        .cfg_clk        (clk_cfg),
        .cfg_rst        (rst_cfg),
        .phy_rstn       (phy_rstn),
        .vout_rgb565    (fb_rgb565),
        .ext_de         (fb_vout_de),
        .pattern_mode   (`VIDEO_PAT_OFF),
        .rd_en          (hdmi_rd_en),
        .rd_vsync       (hdmi_rd_vsync),
        .x_act          (hdmi_x_act),
        .y_act          (hdmi_y_act),
        .de_out         (de_out),
        .hs_out         (hs_out),
        .vs_out         (vs_out),
        .r_out          (r_out),
        .g_out          (g_out),
        .b_out          (b_out),
        .hdmi_init_done (hdmi_init_done),
        .iic_scl        (iic_tx_scl),
        .iic_sda        (iic_tx_sda)
    );

    // ------------------------------------------------------- camera capture
    wire        cam_reset;
    wire        cam_init_done;
    wire        pixel_clk_io;
    wire        pixel_clk;
    wire        pixel_rst;
    wire        pixel_vsync;
    wire        pixel_de;
    wire [15:0] pixel_rgb565;
    wire [31:0] cap_vsync_cnt;
    wire [31:0] cap_line_cnt;
    wire [31:0] cap_pixel_cnt;
    wire [31:0] cap_pclk_cnt;

    // pixel_clk_io is a regional clock from the DVP divider.  The framebuf
    // has loads in many clock regions, so promote it to a global clock.
    GTP_CLKBUFG u_pixel_clk_bufg (
        .CLKIN  (pixel_clk_io),
        .CLKOUT (pixel_clk)
    );

    generate
        if (CAM_SEL == 0) begin : g_cam1
            video_capture_wrap u_capture (
                .clk_27m      (clk_27m),
                .clk_cam      (clk_cam),
                .rst_sys      (rst_sys),
                .cam_reset    (cam_reset),
                .cam_scl      (cmos1_scl),
                .cam_sda      (cmos1_sda),
                .cam_pclk     (cmos1_pclk),
                .cam_vsync    (cmos1_vsync),
                .cam_href     (cmos1_href),
                .cam_data     (cmos1_data),
                .pixel_clk    (pixel_clk_io),
                .pixel_rst    (pixel_rst),
                .pixel_vsync  (pixel_vsync),
                .pixel_de     (pixel_de),
                .pixel_rgb565 (pixel_rgb565),
                .cam_init_done(cam_init_done),
                .dbg_vsync_cnt(cap_vsync_cnt),
                .dbg_line_cnt (cap_line_cnt),
                .dbg_pixel_cnt(cap_pixel_cnt),
                .dbg_pclk_cnt (cap_pclk_cnt)
            );
            assign cmos1_reset = cam_reset;
            assign cmos2_reset = 1'b1;
            assign cmos2_scl   = 1'bz;
            assign cmos2_sda   = 1'bz;
        end else begin : g_cam2
            video_capture_wrap u_capture (
                .clk_27m      (clk_27m),
                .clk_cam      (clk_cam),
                .rst_sys      (rst_sys),
                .cam_reset    (cam_reset),
                .cam_scl      (cmos2_scl),
                .cam_sda      (cmos2_sda),
                .cam_pclk     (cmos2_pclk),
                .cam_vsync    (cmos2_vsync),
                .cam_href     (cmos2_href),
                .cam_data     (cmos2_data),
                .pixel_clk    (pixel_clk_io),
                .pixel_rst    (pixel_rst),
                .pixel_vsync  (pixel_vsync),
                .pixel_de     (pixel_de),
                .pixel_rgb565 (pixel_rgb565),
                .cam_init_done(cam_init_done),
                .dbg_vsync_cnt(cap_vsync_cnt),
                .dbg_line_cnt (cap_line_cnt),
                .dbg_pixel_cnt(cap_pixel_cnt),
                .dbg_pclk_cnt (cap_pclk_cnt)
            );
            assign cmos2_reset = cam_reset;
            assign cmos1_reset = 1'b1;
            assign cmos1_scl   = 1'bz;
            assign cmos1_sda   = 1'bz;
        end
    endgenerate

    // ------------------------------------------------ write-side pattern inject
    reg [11:0] cap_x;
    reg [11:0] cap_y;
    always @(posedge pixel_clk) begin
        if (pixel_rst || pixel_vsync) begin
            cap_x <= 12'd0;
            cap_y <= 12'd0;
        end else if (pixel_de) begin
            if (cap_x == 12'd1279) begin
                cap_x <= 12'd0;
                cap_y <= cap_y + 12'd1;
            end else begin
                cap_x <= cap_x + 12'd1;
            end
        end
    end

    // 4 vertical bars: red / green / blue / white.
    wire [15:0] inj_rgb = (cap_x < 12'd320) ? 16'hF800 :
                          (cap_x < 12'd640) ? 16'h07E0 :
                          (cap_x < 12'd960) ? 16'h001F :
                                              16'hFFFF;
    wire [15:0] fb_wr_rgb = (INJECT_PATTERN != 0) ? inj_rgb : pixel_rgb565;

    // ------------------------------------------------------ DDR3 reference
    wire ref_clk_125m;

    GTP_INBUFGDS u_refclk_buf (
        .O  (ref_clk_125m),
        .I  (ref_clk_p),
        .IB (ref_clk_n)
    );

    // ------------------------------------------------------------ DDR3 IP
    wire        ddr_core_clk;
    wire        ddr_init_done;
    wire        ddr_pll_lock;
    wire        ddr_phy_pll_lock;
    wire        ddr_gpll_lock;
    wire        ddr_rst_gpll_lock;
    wire        ddr_cpd_lock;
    wire        ddr_init_fail;
    wire        ddr_align_error;
    wire [33:0] ddr_debug_calib_ctrl;
    wire [67:0] ddr_dbg_slice_status;

    wire [27:0]  fb_awaddr;
    wire [3:0]   fb_awid;
    wire [3:0]   fb_awlen;
    wire [2:0]   fb_awsize;
    wire [1:0]   fb_awburst;
    wire         fb_awvalid;
    wire         fb_awready;
    wire [255:0] fb_wdata;
    wire [31:0]  fb_wstrb;
    wire         fb_wlast;
    wire         fb_wvalid;
    wire         fb_wready;
    wire         fb_bready;
    wire [27:0]  fb_araddr;
    wire [3:0]   fb_arid;
    wire [3:0]   fb_arlen;
    wire [2:0]   fb_arsize;
    wire [1:0]   fb_arburst;
    wire         fb_arvalid;
    wire         fb_arready;
    wire         fb_rready;
    wire [255:0] fb_rdata;
    wire         fb_rvalid;
    wire         fb_rlast;
    wire [3:0]   fb_rid;

    // ------------------------------------------------ DDR3 init retry
    // The PHY calibration on this board is marginal with some placements.
    // If dbg_ddrphy_init_fail asserts, pulse the debug PHY reset and retry.
    reg [1:0]  ddr_fail_sync;
    reg [2:0]  retry_state;
    reg [19:0] retry_cnt;
    reg [1:0]  retry_tries;
    reg        dbg_phy_rst_n;

    localparam [2:0] RT_IDLE = 3'd0;
    localparam [2:0] RT_LOW  = 3'd1;
    localparam [2:0] RT_WAIT = 3'd2;

    always @(posedge clk_27m) begin
        if (rst_sys) begin
            ddr_fail_sync <= 2'b00;
            retry_state   <= RT_IDLE;
            retry_cnt     <= 20'd0;
            retry_tries   <= 2'd0;
            dbg_phy_rst_n <= 1'b1;
        end else begin
            ddr_fail_sync <= {ddr_fail_sync[0], ddr_init_fail};
            case (retry_state)
                RT_IDLE: begin
                    dbg_phy_rst_n <= 1'b1;
                    if (ddr_fail_sync[1] && !ddr_init_sync[1] &&
                        (retry_tries < 2'd3)) begin
                        dbg_phy_rst_n <= 1'b0;
                        retry_cnt     <= 20'd0;
                        retry_state   <= RT_LOW;
                    end
                end
                RT_LOW: begin
                    if (retry_cnt == 20'd100000) begin
                        retry_cnt     <= 20'd0;
                        dbg_phy_rst_n <= 1'b1;
                        retry_state   <= RT_WAIT;
                    end else begin
                        retry_cnt <= retry_cnt + 20'd1;
                    end
                end
                RT_WAIT: begin
                    if (retry_cnt == 20'd270000) begin
                        retry_cnt   <= 20'd0;
                        retry_tries <= retry_tries + 2'd1;
                        retry_state <= RT_IDLE;
                    end else begin
                        retry_cnt <= retry_cnt + 20'd1;
                    end
                end
                default: retry_state <= RT_IDLE;
            endcase
        end
    end

    // The vendor framebuf ties axi_wvalid to axi_wready and may drive AXI
    // during DDR3 calibration.  Hold all AXI valids low until init completes.
    wire fb_awvalid_g = fb_awvalid & ddr_init_done;
    wire fb_wvalid_g  = fb_wvalid  & ddr_init_done;
    wire fb_arvalid_g = fb_arvalid & ddr_init_done;

    ddr3_test I_ips_ddr_top (
        .ref_clk                (ref_clk_125m),
        .resetn                 (phy_rstn),
        .core_clk               (ddr_core_clk),
        .pll_lock               (ddr_pll_lock),
        .phy_pll_lock           (ddr_phy_pll_lock),
        .gpll_lock              (ddr_gpll_lock),
        .rst_gpll_lock          (ddr_rst_gpll_lock),
        .ddrphy_cpd_lock        (ddr_cpd_lock),
        .ddr_init_done          (ddr_init_done),

        .axi_awaddr             (fb_awaddr),
        .axi_awuser_ap          (1'b0),
        .axi_awuser_id          (4'd0),
        .axi_awlen              (fb_awlen),
        .axi_awready            (fb_awready),
        .axi_awvalid            (fb_awvalid_g),

        .axi_wdata              (fb_wdata),
        .axi_wstrb              (fb_wstrb),
        .axi_wready             (fb_wready),
        .axi_wusero_id          (),
        .axi_wusero_last        (fb_wlast),

        .axi_araddr             (fb_araddr),
        .axi_aruser_ap          (1'b0),
        .axi_aruser_id          (4'd0),
        .axi_arlen              (fb_arlen),
        .axi_arready            (fb_arready),
        .axi_arvalid            (fb_arvalid_g),

        .axi_rdata              (fb_rdata),
        .axi_rid                (),
        .axi_rlast              (fb_rlast),
        .axi_rvalid             (fb_rvalid),

        .apb_clk                (1'b0),
        .apb_rst_n              (1'b1),
        .apb_sel                (1'b0),
        .apb_enable             (1'b0),
        .apb_addr               (8'd0),
        .apb_write              (1'b0),
        .apb_ready              (),
        .apb_wdata              (16'd0),
        .apb_rdata              (),

        .mem_cs_n               (mem_cs_n),
        .mem_rst_n              (mem_rst_n),
        .mem_ck                 (mem_ck),
        .mem_ck_n               (mem_ck_n),
        .mem_cke                (mem_cke),
        .mem_ras_n              (mem_ras_n),
        .mem_cas_n              (mem_cas_n),
        .mem_we_n               (mem_we_n),
        .mem_odt                (mem_odt),
        .mem_a                  (mem_a),
        .mem_ba                 (mem_ba),
        .mem_dqs                (mem_dqs),
        .mem_dqs_n              (mem_dqs_n),
        .mem_dq                 (mem_dq),
        .mem_dm                 (mem_dm),

        .dbg_gate_start             (1'b0),
        .dbg_cpd_start              (1'b0),
        .dbg_ddrphy_rst_n           (dbg_phy_rst_n),
        .dbg_gpll_scan_rst          (1'b0),
        .samp_position_dyn_adj      (1'b0),
        .init_samp_position_even    (32'd0),
        .init_samp_position_odd     (32'd0),
        .wrcal_position_dyn_adj     (1'b0),
        .init_wrcal_position        (32'd0),
        .force_read_clk_ctrl        (1'b0),
        .init_slip_step             (16'd0),
        .init_read_clk_ctrl         (12'd0),
        .debug_calib_ctrl           (ddr_debug_calib_ctrl),
        .dbg_slice_status           (ddr_dbg_slice_status),
        .dbg_slice_state            (),
        .debug_data                 (),
        .dbg_dll_upd_state          (),
        .debug_gpll_dps_phase       (),
        .dbg_rst_dps_state          (),
        .dbg_tran_err_rst_cnt       (),
        .dbg_ddrphy_init_fail       (ddr_init_fail),
        .debug_cpd_offset_adj       (1'b0),
        .debug_cpd_offset_dir       (1'b0),
        .debug_cpd_offset           (10'd0),
        .debug_dps_cnt_dir0         (),
        .debug_dps_cnt_dir1         (),
        .ck_dly_en                  (1'b0),
        .init_ck_dly_step           (8'd0),
        .ck_dly_set_bin             (),
        .align_error                (ddr_align_error),
        .debug_rst_state            (),
        .debug_cpd_state            ()
    );

    // -------------------------------------------------------- frame buffer
    wire        fb_init_done;

    // The vendor hdmi_ddr_ov5640_top drives rd_en=de_re / rd_fsync=vs_o
    // directly and does not gate the read side with init_done.  The first
    // displayed frame can contain junk until the first write frame completes;
    // after that the double buffer in fram_buf takes over.

    fram_buf #(
        .MEM_ROW_WIDTH    (15),
        .MEM_COLUMN_WIDTH (10),
        .MEM_BANK_WIDTH   (3),
        .MEM_DQ_WIDTH     (32),
        .H_NUM            (12'd1280),
        .V_NUM            (12'd720),
        .PIX_WIDTH        (16)
    ) u_fb (
        .vin_clk     (pixel_clk),
        .wr_fsync    (pixel_vsync),
        .wr_en       (pixel_de),
        .wr_data     (fb_wr_rgb),
        .init_done   (fb_init_done),

        .ddr_clk     (ddr_core_clk),
        .ddr_rstn    (ddr_init_done),

        .vout_clk    (clk_pix),
        .rd_fsync    (hdmi_rd_vsync),
        .rd_en       (hdmi_rd_en),
        .vout_de     (fb_vout_de),
        .vout_data   (fb_rgb565),

        .axi_awaddr  (fb_awaddr),
        .axi_awid    (fb_awid),
        .axi_awlen   (fb_awlen),
        .axi_awsize  (fb_awsize),
        .axi_awburst (fb_awburst),
        .axi_awready (fb_awready),
        .axi_awvalid (fb_awvalid),

        .axi_wdata   (fb_wdata),
        .axi_wstrb   (fb_wstrb),
        .axi_wlast   (fb_wlast),
        .axi_wvalid  (fb_wvalid),
        .axi_wready  (fb_wready),
        .axi_bid     (4'd0),

        .axi_araddr  (fb_araddr),
        .axi_arid    (fb_arid),
        .axi_arlen   (fb_arlen),
        .axi_arsize  (fb_arsize),
        .axi_arburst (fb_arburst),
        .axi_arvalid (fb_arvalid),
        .axi_arready (fb_arready),

        .axi_rready  (fb_rready),
        .axi_rdata   (fb_rdata),
        .axi_rvalid  (fb_rvalid),
        .axi_rlast   (fb_rlast),
        .axi_rid     (fb_rid)
    );

    // Center-pixel samples: camera write side and framebuf read side.
    reg [15:0] cam_center;
    reg [15:0] fb_center;

    always @(posedge pixel_clk) begin
        if (pixel_de && (cap_x == 12'd640) && (cap_y == 12'd360))
            cam_center <= pixel_rgb565;
    end

    always @(posedge clk_pix) begin
        if (fb_vout_de && (hdmi_x_act == 12'd640) && (hdmi_y_act == 12'd360))
            fb_center <= fb_rgb565;
    end

    // Read-side diagnostics (clk_pix domain, sticky).
    reg        fb_rd_nonzero;
    reg        fb_rd_en_seen;
    reg        fb_vout_de_seen;

    always @(posedge clk_pix) begin
        if (rst_pix) begin
            fb_rd_nonzero   <= 1'b0;
            fb_rd_en_seen   <= 1'b0;
            fb_vout_de_seen <= 1'b0;
        end else begin
            if (hdmi_rd_en) fb_rd_en_seen <= 1'b1;
            if (fb_vout_de) fb_vout_de_seen <= 1'b1;
            if (hdmi_rd_en && (fb_rgb565 != 16'd0)) fb_rd_nonzero <= 1'b1;
        end
    end

    // ------------------------------------------------------------- status
    reg [1:0]  cam_init_sync;
    reg [1:0]  ddr_init_sync;
    reg [1:0]  fb_init_sync;
    reg [1:0]  rdnz_sync, rden_sync, vde_sync;
    reg [15:0] cam_center_s1, cam_center_s2;
    reg [15:0] fb_center_s1,  fb_center_s2;
    reg [31:0] cap_vsync_s1, cap_vsync_s2;
    reg [31:0] cap_line_s1,  cap_line_s2;
    reg [31:0] cap_pixel_s1, cap_pixel_s2;

    always @(posedge clk_27m) begin
        cam_init_sync <= {cam_init_sync[0], cam_init_done};
        ddr_init_sync <= {ddr_init_sync[0], ddr_init_done};
        fb_init_sync  <= {fb_init_sync[0],  fb_init_done};
        rdnz_sync     <= {rdnz_sync[0], fb_rd_nonzero};
        rden_sync     <= {rden_sync[0], fb_rd_en_seen};
        vde_sync      <= {vde_sync[0],  fb_vout_de_seen};
        cam_center_s1 <= cam_center;
        cam_center_s2 <= cam_center_s1;
        fb_center_s1  <= fb_center;
        fb_center_s2  <= fb_center_s1;
        cap_vsync_s1  <= cap_vsync_cnt;
        cap_vsync_s2  <= cap_vsync_s1;
        cap_line_s1   <= cap_line_cnt;
        cap_line_s2   <= cap_line_s1;
        cap_pixel_s1  <= cap_pixel_cnt;
        cap_pixel_s2  <= cap_pixel_s1;
    end

    // ------------------------------------------------------ camera thumbnail
    // The window belongs to the SoC instance below; when BOARD_SOC is not
    // defined nothing reads it, which is fine (the RAM is just unused).
    wire        cam_wr_en, cam_tog;
    wire [27:0] cam_wr_word;
    wire [31:0] cam_wr_cnt;
    wire [23:0] cam_dbg_pix;
    wire [10:0] cam_rd_addr;
    wire        cam_rd_bank;
    wire [15:0] cam_rd_data;
    wire [31:0] cam_frame_w;
    wire        cam_fifo_empty, cam_fifo_rd_en;
    wire [27:0] cam_fifo_word;

    cam_cap u_cam_cap (
        .pixel_clk    (pixel_clk_io),
        .pixel_rst    (pixel_rst),
        .pixel_de     (pixel_de),
        .pixel_rgb565 (pixel_rgb565),
        .pixel_vsync  (pixel_vsync),
        .wr_en        (cam_wr_en),
        .wr_data      (cam_wr_word),
        .frame_tog    (cam_tog),
        .wr_cnt       (cam_wr_cnt),
        .dbg          (cam_dbg_pix)
    );

    cam_fifo #(
        .WIDTH(28),
        .AW   (5),
        .DEPTH(32)
    ) u_cam_fifo (
        .wr_clk  (pixel_clk_io),
        .wr_rst  (pixel_rst),
        .wr_en   (cam_wr_en),
        .wr_data (cam_wr_word),
        .full    (),
        .rd_clk  (clk_27m),
        .rd_rst  (rst_sys),
        .rd_en   (cam_fifo_rd_en),
        .rd_data (cam_fifo_word),
        .empty   (cam_fifo_empty)
    );

    cam_store u_cam_store (
        .clk         (clk_27m),
        .rst         (rst_sys),
        .fifo_data   (cam_fifo_word),
        .fifo_empty  (cam_fifo_empty),
        .fifo_rd_en  (cam_fifo_rd_en),
        .rd_addr     (cam_rd_addr),
        .rd_bank     (cam_rd_bank),
        .rd_data     (cam_rd_data)
    );

    // Completed-frame counter on the SoC clock (toggle synchroniser).
    reg [2:0]  cam_tog_sync;
    reg [31:0] cam_frame_q;

    always @(posedge clk_27m or negedge rst_n) begin
        if (!rst_n) begin
            cam_tog_sync <= 3'd0;
            cam_frame_q  <= 32'd0;
        end else begin
            cam_tog_sync <= {cam_tog_sync[1:0], cam_tog};
            if (cam_tog_sync[2] ^ cam_tog_sync[1])
                cam_frame_q <= cam_frame_q + 32'd1;
        end
    end

    assign cam_frame_w = cam_frame_q;

    // Debug: how many samples the capture has written (2FF, count only).
    reg [31:0] cam_wrcnt_s1, cam_wrcnt_s2;
    reg [23:0] cam_dbg_s1, cam_dbg_s2;
    always @(posedge clk_27m) begin
        if (rst_sys) begin
            cam_wrcnt_s1 <= 32'd0;
            cam_wrcnt_s2 <= 32'd0;
            cam_dbg_s1   <= 24'd0;
            cam_dbg_s2   <= 24'd0;
        end else begin
            cam_wrcnt_s1 <= cam_wr_cnt;
            cam_wrcnt_s2 <= cam_wrcnt_s1;
            cam_dbg_s1   <= cam_dbg_pix;
            cam_dbg_s2   <= cam_dbg_s1;
        end
    end

    video_fb_status u_status (
        .clk_27m        (clk_27m),
        .rst_sys        (rst_sys),
        .pll_lock       (pll_lock),
        .ddr_init_done  (ddr_init_sync[1]),
        .hdmi_init_done (hdmi_init_done),
        .cam_init_done  (cam_init_sync[1]),
        .frame_activity (cap_vsync_s2[5]),
        .fb_init_done   (fb_init_sync[1]),
        .read_data_nonzero (rdnz_sync[1]),
        .rd_en_seen        (rden_sync[1]),
        .vout_de_seen      (vde_sync[1]),
        .cam_center_pix    (cam_center_s2),
        .fb_center_pix     (fb_center_s2),
        .cap_vsync_cnt  (cap_vsync_s2),
        .cap_line_cnt   (cap_line_s2),
        .cap_pixel_cnt  (cap_pixel_s2),
        .led            (led),
        .uart_tx        (v_status_uart)
    );

    wire v_status_uart;

`ifdef BOARD_SOC
    // ---------------------------------------------------------------- SoC
    // The SoC shares clk_27m and owns the UART; the video status keeps the
    // LEDs.  The DDR3 IP stays where it is (inside this module) so the proven
    // constraint files with their absolute I_ips_ddr_top paths keep working.
    reg [1:0]  soc_rst_sync;
    reg [15:0] soc_por_cnt;
    reg        soc_por_done;

    always @(posedge clk_27m or negedge rst_n) begin
        if (!rst_n) begin
            soc_rst_sync <= 2'b00;
            soc_por_cnt  <= 16'd0;
            soc_por_done <= 1'b0;
        end else begin
            soc_rst_sync <= {soc_rst_sync[0], 1'b1};
            if (!soc_por_done) begin
                if (soc_por_cnt == 16'hFFFF) soc_por_done <= 1'b1;
                else                         soc_por_cnt  <= soc_por_cnt + 16'd1;
            end
        end
    end

    wire soc_rst = ~(soc_rst_sync[1] & soc_por_done);

    wire        soc_uart_tx;
    wire [31:0] soc_dbg_pc;
    wire        soc_dbg_commit;
    wire        soc_dbg_halt;

    ares_soc #(
        .RESET_PC      (32'h0000_0000),
        .L1_BYTES      (2048),
        .SCRATCH_WORDS (4096),
        .ROM_WORDS     (4096),
        .DDR_WORDS     (8192)
    ) u_soc (
        .clk             (clk_27m),
        .rst             (soc_rst),
        .uart_rx         (uart_rx),
        .uart_tx         (soc_uart_tx),
        .gpio_in         (32'd0),
        .gpio_out        (),
        .gpio_dir        (),
        .cam_addr        (cam_rd_addr),
        .cam_bank        (cam_rd_bank),
        .cam_data        (cam_rd_data),
        .cam_frame       (cam_frame_w),
        .cam_wrcnt       (cam_wrcnt_s2),
        .cam_dbg         (cam_dbg_s2),
        .mt_irq          (),
        .dbg_halt        (soc_dbg_halt),
        .dbg_pc          (soc_dbg_pc),
        .dbg_commit      (soc_dbg_commit),
        .dbg_pc_f        (),
        .dbg_ifid_valid  (),
        .dbg_idex_valid  (),
        .dbg_exmem_valid (),
        .dbg_memwb_valid (),
        .dbg_if_pending  ()
    );

    assign uart_tx = soc_uart_tx;
`else
    assign uart_tx = v_status_uart;
`endif

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_ok = &{1'b0,
        fb_awid, fb_awsize, fb_awburst, fb_wlast, fb_bready,
        fb_arid, fb_arsize, fb_arburst, fb_rready, fb_rid, fb_vout_de,
        cap_pclk_cnt, hdmi_x_act, hdmi_y_act,
        ddr_debug_calib_ctrl, ddr_dbg_slice_status,
        ddr_pll_lock, ddr_phy_pll_lock, ddr_gpll_lock, ddr_rst_gpll_lock,
        ddr_cpd_lock, ddr_init_fail, ddr_align_error,
        cmos1_pclk, cmos1_vsync, cmos1_href, cmos1_data,
        cmos2_pclk, cmos2_vsync, cmos2_href, cmos2_data,
        cmos1_scl, cmos1_sda, cmos2_scl, cmos2_sda,
        iic_tx_sda, CAM_SEL};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
