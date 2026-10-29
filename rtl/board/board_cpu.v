// ---------------------------------------------------------------------------
// board_cpu - bring-up top for the CPU stages (B2/B3/B4).
//
// One top, one pinout; the stage is selected by the PDS compile defines:
//   B2  ARES_NO_MT ARES_NO_DDR ARES_BOOT_ROM   CPU + ROM + UART, no memory
//   B3  ARES_NO_MT ARES_BRAM   ARES_BOOT_ROM   + BRAM behind the DDR port
//
// Observability while the CPU is suspect:
//   led[0]  free-running clock bit (no reset)
//   led[1]  reset released
//   led[2]  dbg_commit   -> the core is retiring instructions
//   led[3]  dbg_halt     -> the core took a fatal trap
//   led[7:4] dbg_pc[7:4] -> the PC is moving
//
// Verilog-2001 on purpose; the SoC itself is SystemVerilog and goes through
// tools/pango_prep.py.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps
module board_cpu #(
    parameter integer DDR_WORDS = 8192       // 128-bit lines = 128 KiB
                                             // matches __stack_top = 0x8002_0000
) (
    input  wire       clk_27m,      // D18
    input  wire       rst_n,        // C22
    input  wire       uart_rx,      // B24
    output wire       uart_tx,      // C24
    output wire [7:0] led
);

    // ------------------------------------------------------- clock liveness
    reg [25:0] free_cnt;
    always @(posedge clk_27m) begin
        free_cnt <= free_cnt + 26'd1;
    end

    // ---------------------------------------------------------------- reset
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

    // ------------------------------------------------------------------ SoC
    wire        soc_uart_tx;
    wire [31:0] dbg_pc;
    wire        dbg_commit;
    wire        dbg_halt;

    ares_soc #(
        .RESET_PC      (32'h0000_0000),
        .L1_BYTES      (2048),
        .SCRATCH_WORDS (4096),
        .ROM_WORDS     (4096),
        .DDR_WORDS     (DDR_WORDS)
    ) u_soc (
        .clk             (clk_27m),
        .rst             (rst),
        .uart_rx         (uart_rx),
        .uart_tx         (soc_uart_tx),
        .gpio_in         (32'd0),
        .gpio_out        (),
        .gpio_dir        (),
        .cam_addr        (),
        .cam_bank        (1'b0),
        .cam_data        (16'd0),
        .cam_frame       (32'd0),
        .cam_wrcnt       (32'd0),
        .mt_irq          (),
        .dbg_halt        (dbg_halt),
        .dbg_pc          (dbg_pc),
        .dbg_commit      (dbg_commit),
        .dbg_pc_f        (),
        .dbg_ifid_valid  (),
        .dbg_idex_valid  (),
        .dbg_exmem_valid (),
        .dbg_memwb_valid (),
        .dbg_if_pending  ()
    );

    assign uart_tx = soc_uart_tx;

    assign led[0]   = free_cnt[24];
    assign led[1]   = ~rst;
    assign led[2]   = dbg_commit;
    assign led[3]   = dbg_halt;
    assign led[7:4] = dbg_pc[7:4];

endmodule
