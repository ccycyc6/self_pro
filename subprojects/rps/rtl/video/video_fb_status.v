// ---------------------------------------------------------------------------
// video_fb_status - LEDs + 115200 status UART for video_fb_top (S2)
//
// Line, once per ~0.5 s:
//   S2 P=1 D=1 H=1 C=1 F=1 B=1 V=000000B1 L=0001F2C8 X=09BE3D0E
//
//   P pll_lock            D ddr_init_done       H hdmi_init_done
//   C cam_init_done       F capture frame activity
//   B framebuf first frame written
//   V/L/X capture vsync / line / pixel counters (hex)
//
// All values are latched when a line starts.
// ---------------------------------------------------------------------------
`include "video_defs.vh"

module video_fb_status (
    input  wire        clk_27m,
    input  wire        rst_sys,

    input  wire        pll_lock,
    input  wire        ddr_init_done,
    input  wire        hdmi_init_done,
    input  wire        cam_init_done,
    input  wire        frame_activity,
    input  wire        fb_init_done,
    input  wire        read_data_nonzero,
    input  wire        rd_en_seen,
    input  wire        vout_de_seen,
    input  wire [15:0] cam_center_pix,
    input  wire [15:0] fb_center_pix,

    input  wire [31:0] cap_vsync_cnt,
    input  wire [31:0] cap_line_cnt,
    input  wire [31:0] cap_pixel_cnt,

    output wire [7:0]  led,
    output wire        uart_tx
);

    // ------------------------------------------------------------- LEDs
    reg [23:0] beat;
    always @(posedge clk_27m) begin
        if (rst_sys) beat <= 24'd0;
        else         beat <= beat + 24'd1;
    end

    assign led[0] = beat[23];
    assign led[1] = pll_lock;
    assign led[2] = ddr_init_done;
    assign led[3] = hdmi_init_done;
    assign led[4] = cam_init_done;
    assign led[5] = frame_activity;
    assign led[6] = 1'b0;
    assign led[7] = fb_init_done;

    // ------------------------------------------------------------- UART
    localparam [2:0] ST_GAP   = 3'd0;
    localparam [2:0] ST_LOAD  = 3'd1;
    localparam [2:0] ST_START = 3'd2;
    localparam [2:0] ST_DATA  = 3'd3;
    localparam [2:0] ST_STOP  = 3'd4;

    // phase 0 = "S2 " tag, 1..14 = fields, 15 = CR, 16 = LF
    localparam [4:0] PH_CR = 5'd15;
    localparam [4:0] PH_LF = 5'd16;

    reg [2:0]  state;
    reg [15:0] div;
    reg [2:0]  bit_idx;
    reg [9:0]  shifter;
    reg [23:0] gap;
    reg        tx;

    reg [4:0]  phase;
    reg [3:0]  field_idx;
    reg [3:0]  sub;
    reg [1:0]  tag_idx;

    reg        lat_pll;
    reg        lat_ddr;
    reg        lat_hdmi;
    reg        lat_cam;
    reg        lat_frame;
    reg        lat_fb;
    reg        lat_rdnz;
    reg        lat_rden;
    reg        lat_vde;
    reg [15:0] lat_campix;
    reg [15:0] lat_fbpix;
    reg [31:0] lat_v;
    reg [31:0] lat_l;
    reg [31:0] lat_x;

    wire tick = (div == (`VIDEO_UART_DIV - 16'd1));

    /* verilator lint_off UNUSEDSIGNAL */
    function [7:0] hex_ascii;
        input [31:0] v;
        begin
            if (v[3:0] < 4'd10) hex_ascii = 8'h30 + {4'd0, v[3:0]};
            else                hex_ascii = 8'h37 + {4'd0, v[3:0]}; // 'A' - 10
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // --------------------------------------------------- field descriptors
    reg [7:0]  label0;
    reg [31:0] field_val;
    reg [4:0]  field_len;

    always @(*) begin
        label0    = 8'h50;              // 'P'
        field_val = 32'd0;
        field_len = 5'd1;
        case (field_idx)
            4'd0: begin label0 = 8'h50; field_val = {31'd0, lat_pll};  end
            4'd1: begin label0 = 8'h44; field_val = {31'd0, lat_ddr};  end
            4'd2: begin label0 = 8'h48; field_val = {31'd0, lat_hdmi}; end
            4'd3: begin label0 = 8'h43; field_val = {31'd0, lat_cam};  end
            4'd4: begin label0 = 8'h46; field_val = {31'd0, lat_frame};end
            4'd5: begin label0 = 8'h42; field_val = {31'd0, lat_fb};   end
            4'd6: begin label0 = 8'h52; field_val = {31'd0, lat_rdnz}; end
            4'd7: begin label0 = 8'h45; field_val = {31'd0, lat_rden}; end
            4'd8: begin label0 = 8'h47; field_val = {31'd0, lat_vde};  end
            4'd9: begin label0 = 8'h4D; field_val = {16'd0, lat_campix}; field_len = 5'd4; end
            4'd10: begin label0 = 8'h4E; field_val = {16'd0, lat_fbpix};  field_len = 5'd4; end
            4'd11: begin label0 = 8'h56; field_val = lat_v; field_len = 5'd8; end
            4'd12: begin label0 = 8'h4C; field_val = lat_l; field_len = 5'd8; end
            default: begin
                label0    = 8'h58;      // 'X' pixel counter
                field_val = lat_x;
                field_len = 5'd8;
            end
        endcase
    end

    wire [4:0]  sub5     = {1'b0, sub};
    wire [4:0]  last_sub = field_len + 5'd2;
    wire [3:0]  nib_idx  = field_len[3:0] - 4'd1 - (sub - 4'd2);
    wire [5:0]  nib_shift = {nib_idx, 2'b00};

    reg [7:0] msg_byte;
    always @(*) begin
        msg_byte = 8'h20;
        if (phase == 5'd0) begin
            case (tag_idx)
                2'd0:    msg_byte = 8'h53; // S
                2'd1:    msg_byte = 8'h32; // 2
                default: msg_byte = 8'h20; // ' '
            endcase
        end else if (phase <= 5'd14) begin
            if (sub == 4'd0)                       msg_byte = label0;
            else if (sub == 4'd1)                  msg_byte = 8'h3D; // '='
            else if (sub5 < last_sub)              msg_byte = hex_ascii(field_val >> nib_shift);
            else                                   msg_byte = 8'h20;
        end else if (phase == PH_CR) begin
            msg_byte = 8'h0D;
        end else begin
            msg_byte = 8'h0A;
        end
    end

    always @(posedge clk_27m) begin
        if (rst_sys) begin
            state   <= ST_GAP;
            div     <= 16'd0;
            bit_idx <= 3'd0;
            shifter <= 10'h3FF;
            gap     <= 24'd0;
            tx      <= 1'b1;
            phase   <= 5'd0;
            field_idx <= 4'd0;
            sub     <= 4'd0;
            tag_idx <= 2'd0;
            lat_pll   <= 1'b0;
            lat_ddr   <= 1'b0;
            lat_hdmi  <= 1'b0;
            lat_cam   <= 1'b0;
            lat_frame <= 1'b0;
            lat_fb    <= 1'b0;
            lat_rdnz  <= 1'b0;
            lat_rden  <= 1'b0;
            lat_vde   <= 1'b0;
            lat_campix <= 16'd0;
            lat_fbpix  <= 16'd0;
            lat_v     <= 32'd0;
            lat_l     <= 32'd0;
            lat_x     <= 32'd0;
        end else begin
            if (tick) div <= 16'd0;
            else      div <= div + 16'd1;

            case (state)
                ST_GAP: begin
                    tx <= 1'b1;
                    if (gap == `VIDEO_UART_PERIOD) begin
                        gap   <= 24'd0;
                        div   <= 16'd0;
                        lat_pll   <= pll_lock;
                        lat_ddr   <= ddr_init_done;
                        lat_hdmi  <= hdmi_init_done;
                        lat_cam   <= cam_init_done;
                        lat_frame <= frame_activity;
                        lat_fb    <= fb_init_done;
                        lat_rdnz  <= read_data_nonzero;
                        lat_rden  <= rd_en_seen;
                        lat_vde   <= vout_de_seen;
                        lat_campix <= cam_center_pix;
                        lat_fbpix  <= fb_center_pix;
                        lat_v     <= cap_vsync_cnt;
                        lat_l     <= cap_line_cnt;
                        lat_x     <= cap_pixel_cnt;
                        phase     <= 5'd0;
                        tag_idx   <= 2'd0;
                        field_idx <= 4'd0;
                        sub       <= 4'd0;
                        state     <= ST_LOAD;
                    end else begin
                        gap <= gap + 24'd1;
                    end
                end

                ST_LOAD: begin
                    tx      <= 1'b1;
                    shifter <= {1'b1, msg_byte, 1'b0};
                    div     <= 16'd0;
                    state   <= ST_START;
                end

                ST_START: begin
                    if (tick) begin
                        tx      <= shifter[0];
                        shifter <= {1'b1, shifter[9:1]};
                        bit_idx <= 3'd0;
                        state   <= ST_DATA;
                    end
                end

                ST_DATA: begin
                    if (tick) begin
                        tx      <= shifter[0];
                        shifter <= {1'b1, shifter[9:1]};
                        if (bit_idx == 3'd7) state <= ST_STOP;
                        else                 bit_idx <= bit_idx + 3'd1;
                    end
                end

                ST_STOP: begin
                    if (tick) begin
                        tx <= 1'b1;
                        if (phase == 5'd0) begin
                            if (tag_idx == 2'd2) begin
                                tag_idx   <= 2'd0;
                                field_idx <= 4'd0;
                                sub       <= 4'd0;
                                phase     <= 5'd1;
                            end else begin
                                tag_idx <= tag_idx + 2'd1;
                            end
                            state <= ST_LOAD;
                        end else if (phase <= 5'd14) begin
                            if (sub5 >= last_sub) begin
                                if (field_idx == 4'd13) begin
                                    phase <= PH_CR;
                                end else begin
                                    field_idx <= field_idx + 4'd1;
                                    sub       <= 4'd0;
                                end
                            end else begin
                                sub <= sub + 4'd1;
                            end
                            state <= ST_LOAD;
                        end else if (phase == PH_CR) begin
                            phase <= PH_LF;
                            state <= ST_LOAD;
                        end else begin
                            phase <= 5'd0;
                            gap   <= 24'd0;
                            state <= ST_GAP;
                        end
                    end
                end

                default: state <= ST_GAP;
            endcase
        end
    end

    assign uart_tx = tx;

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
