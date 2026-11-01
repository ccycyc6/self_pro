// ---------------------------------------------------------------------------
// board_smoke - first-stage board test for Pangu 200Pro+ (PG2L200H-6IFBB676)
//
// Purpose: answer ONE question before any SoC/BRAM/DDR3 code is added --
// "does our own bitstream come alive on this board, and is the UART alive?"
//
//   led[0]  free-running counter bit   -> 27 MHz reaches the fabric
//                                         (this path deliberately has NO reset)
//   led[1]  reset released             -> POR + button chain works
//   led[2]  UART busy                  -> bytes are actually shifting out
//   led[3]  inter-message gap          -> message scheduler advanced
//   uart_tx "ARES-S1 smoke OK" every ~0.5 s, 115200 8N1
//
// Ports and pins match fpga/pango/board_pins.fdc, copied from the vendor
// 4_1_led_test demo (led/clk/rstn) and the S2 video_top.fdc (uart_tx), i.e.
// the pinouts that are already proven on this exact board.
//
// No SystemVerilog: this file must stay inside the Pango ADS subset.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module board_smoke #(
    parameter integer CLK_HZ = 27000000,
    parameter integer BAUD   = 115200,
    parameter integer GAP    = 13500000          // 0.5 s at 27 MHz
) (
    input  wire       clk_27m,                   // D18, 27 MHz oscillator
    input  wire       rst_n,                     // C22, active low button
    output wire       uart_tx,                   // C24
    output wire [7:0] led
);

    localparam integer DIV     = CLK_HZ / BAUD;  // 234 -> 115384 baud (-0.16%)
    localparam integer MSG_LEN = 18;

    // ------------------------------------------------------------ clock alive
    // No reset: if this bit moves, the clock really is running.
    reg [25:0] free_cnt;
    always @(posedge clk_27m) begin
        free_cnt <= free_cnt + 26'd1;
    end

    // ---------------------------------------------------------------- reset
    // Power-on delay plus button, released synchronously.
    reg [1:0]  rst_sync;
    reg [15:0] por_cnt;
    reg        por_done;

    always @(posedge clk_27m or negedge rst_n) begin
        if (!rst_n) begin
            rst_sync <= 2'b00;
            por_cnt  <= 16'd0;
            por_done <= 1'b0;
        end else begin
            rst_sync <= {rst_sync[0], 1'b1};
            if (!por_done) begin
                if (por_cnt == 16'hFFFF) por_done <= 1'b1;
                else                     por_cnt  <= por_cnt + 16'd1;
            end
        end
    end

    wire rst = ~(rst_sync[1] & por_done);

    // -------------------------------------------------------------- message
    // "ARES-S1 smoke OK\r\n"
    localparam [143:0] MSG = {
        8'h41, 8'h52, 8'h45, 8'h53, 8'h2D, 8'h53, 8'h31, 8'h20,
        8'h73, 8'h6D, 8'h6F, 8'h6B, 8'h65, 8'h20, 8'h4F, 8'h4B,
        8'h0D, 8'h0A
    };

    reg  [4:0] msg_idx;
    wire [4:0] msg_sel = (msg_idx < MSG_LEN) ? msg_idx : 5'd0;
    // MSG is written in reading order, so byte 0 ("A") sits in the MSBs and
    // the select has to count down from the top.
    wire [4:0] msg_bit = (MSG_LEN - 1) - msg_sel;
    wire [7:0] tx_data = MSG[msg_bit*8 +: 8];

    // ------------------------------------------------------- UART transmitter
    reg [15:0] baud_cnt;
    reg [3:0]  bit_idx;
    reg [7:0]  shifter;
    reg        tx_busy;
    reg        tx_line;

    wire baud_tick = (baud_cnt == DIV - 1);
    wire tx_start  = !tx_busy && (msg_idx < MSG_LEN);

    always @(posedge clk_27m) begin
        if (rst) begin
            baud_cnt <= 16'd0;
            bit_idx  <= 4'd0;
            shifter  <= 8'd0;
            tx_busy  <= 1'b0;
            tx_line  <= 1'b1;
        end else if (!tx_busy) begin
            tx_line <= 1'b1;
            if (tx_start) begin
                tx_line  <= 1'b0;                // start bit
                shifter  <= tx_data;
                bit_idx  <= 4'd0;
                baud_cnt <= 16'd0;
                tx_busy  <= 1'b1;
            end
        end else if (baud_tick) begin
            baud_cnt <= 16'd0;
            if (bit_idx == 4'd8) begin
                tx_line <= 1'b1;                 // stop bit
                bit_idx <= 4'd9;
            end else if (bit_idx == 4'd9) begin
                tx_busy <= 1'b0;
            end else begin
                tx_line <= shifter[0];
                shifter <= {1'b1, shifter[7:1]};
                bit_idx <= bit_idx + 4'd1;
            end
        end else begin
            baud_cnt <= baud_cnt + 16'd1;
        end
    end

    // ----------------------------------------------------------- scheduler
    reg [24:0] gap_cnt;

    always @(posedge clk_27m) begin
        if (rst) begin
            msg_idx <= 5'd0;
            gap_cnt <= 25'd0;
        end else if (tx_start) begin
            msg_idx <= msg_idx + 5'd1;
        end else if (!tx_busy && (msg_idx >= MSG_LEN)) begin
            if (gap_cnt == GAP - 1) begin
                gap_cnt <= 25'd0;
                msg_idx <= 5'd0;
            end else begin
                gap_cnt <= gap_cnt + 25'd1;
            end
        end
    end

    // ---------------------------------------------------------------- outputs
    assign led[0]   = free_cnt[24];
    assign led[1]   = ~rst;
    assign led[2]   = tx_busy;
    assign led[3]   = (msg_idx >= MSG_LEN);
    assign led[7:4] = 4'b0000;

    assign uart_tx  = tx_line;

endmodule
