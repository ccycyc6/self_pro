// ---------------------------------------------------------------------------
// video_clk_reset - PLL + per-domain reset + MS7210 power-on reset
//
// Verilog-2001.  Reset policy: asynchronous assert, synchronous release.
// The top-level reset is the board button C22 (active low); each domain gets
// its own active-high reset.  phy_rstn is active low and is released 1 ms
// after the PLL locks, matching the vendor power_on_delay/MS72xx sequence.
// ---------------------------------------------------------------------------
`include "video_defs.vh"

module video_clk_reset (
    input  wire clk_27m,
    input  wire rst_n,
    output wire clk_pix,
    output wire clk_cfg,
    output wire clk_cam,
    output wire pll_lock,
    output wire rst_sys,
    output wire rst_pix,
    output wire rst_cfg,
    output wire rst_cam,
    output wire phy_rstn
);

    wire pll_lock_i;

    video_ip_pll u_pll (
        .clkin1  (clk_27m),
        .clkout0 (clk_pix),
        .clkout1 (clk_cfg),
        .clkout2 (clk_cam),
        .lock    (pll_lock_i)
    );

    assign pll_lock = pll_lock_i;

    // Hold every domain in reset until the board reset is released and the
    // PLL has locked.  The reset synchronizer adds the sync release.
    wire rst_src_n = rst_n & pll_lock_i;

    video_reset_sync u_rst_sys (
        .clk      (clk_27m),
        .rst_in_n (rst_src_n),
        .rst_out  (rst_sys)
    );

    video_reset_sync u_rst_pix (
        .clk      (clk_pix),
        .rst_in_n (rst_src_n),
        .rst_out  (rst_pix)
    );

    video_reset_sync u_rst_cfg (
        .clk      (clk_cfg),
        .rst_in_n (rst_src_n),
        .rst_out  (rst_cfg)
    );

    video_reset_sync u_rst_cam (
        .clk      (clk_cam),
        .rst_in_n (rst_src_n),
        .rst_out  (rst_cam)
    );

    // 1 ms at 10 MHz = 10000 cycles.
    reg [13:0] phy_cnt;
    always @(posedge clk_cfg or negedge rst_src_n) begin
        if (!rst_src_n) begin
            phy_cnt <= 14'd0;
        end else if (phy_cnt != 14'd10000) begin
            phy_cnt <= phy_cnt + 14'd1;
        end
    end

    assign phy_rstn = (phy_cnt == 14'd10000) ? 1'b1 : 1'b0;

endmodule


// ---------------------------------------------------------------------------
// Async assert / sync release reset synchronizer.
// rst_in_n low  -> rst_out high (reset asserted)
// rst_in_n high -> rst_out low after two clocks
// ---------------------------------------------------------------------------
module video_reset_sync (
    input  wire clk,
    input  wire rst_in_n,
    output reg  rst_out
);

    reg [1:0] sync_q;

    always @(posedge clk or negedge rst_in_n) begin
        if (!rst_in_n) begin
            sync_q  <= 2'b00;
            rst_out <= 1'b1;
        end else begin
            sync_q  <= {sync_q[0], 1'b1};
            rst_out <= ~sync_q[1];
        end
    end

endmodule
