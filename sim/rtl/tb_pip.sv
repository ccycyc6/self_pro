`timescale 1ns/1ps
// Testbench for video_pip + pip_buf (runs under verilator --binary).
//
// Drives a 1280x720 raster with a recognisable pattern, puts a known image in
// the inset memory, and checks: outside the rect the picture passes through
// unchanged (one pixel late), inside it the memory byte appears as grey.
module tb_pip;
    reg clk = 0, rst = 1;
    reg [11:0] x = 0, y = 0;
    reg        de = 0;
    reg [23:0] rgb_in = 24'h000000;

    wire [23:0] rgb_out;
    wire [16:0] mem_addr;
    reg  [7:0]  mem_data = 8'd0;

    always #5 clk = ~clk;

    video_pip u_pip (
        .pix_clk(clk), .rst(rst),
        .x(x), .y(y), .de(de), .rgb_in(rgb_in),
        .rgb_out(rgb_out), .mem_addr(mem_addr), .mem_data(mem_data)
    );

    integer errors = 0, checks = 0;
    integer px, py;

    // memory model: byte = (addr * 7) & 0xFF
    always @(posedge clk) mem_data <= ((mem_addr * 7) & 8'hFF);

    task check_point(input integer cx, input integer cy);
        begin
            // present the pixel, then let the two-cycle latency pass
            @(negedge clk);
            x = cx; y = cy; de = 1'b1;
            rgb_in = {cx[7:0], cy[7:0], 8'h5A};

            @(posedge clk); #1;       // t+1: memory data valid
            @(posedge clk); #1;       // t+2: img_q valid, video delayed by 2

            checks = checks + 1;
            if (cx >= 960 && cx < 1280 && cy >= 480 && cy < 720) begin
                if (rgb_out[7:0] !== {(((cy - 480) * 320 + (cx - 960)) * 7) & 8'hFF}) begin
                    $display("FAIL inside (%0d,%0d): got %02x want %02x", cx, cy,
                             rgb_out[7:0],
                             (((cy - 480) * 320 + (cx - 960)) * 7) & 8'hFF);
                    errors = errors + 1;
                end
            end else begin
                if (rgb_out !== {cx[7:0], cy[7:0], 8'h5A}) begin
                    $display("FAIL outside (%0d,%0d): got %06x want %06x", cx, cy,
                             rgb_out, {cx[7:0], cy[7:0], 8'h5A});
                    errors = errors + 1;
                end
            end
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst = 0;
        repeat (2) @(posedge clk);

        check_point(100, 100);      // outside
        check_point(959, 600);      // outside, just left of the rect
        check_point(960, 480);      // inside, top-left corner
        check_point(961, 481);      // inside, one pixel in
        check_point(1279, 719);     // inside, bottom-right corner
        check_point(1279, 479);     // outside, one row above
        check_point(959, 719);      // outside, one column left
        check_point(300, 719);      // outside, bottom left

        $display("pip checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("PIP TEST PASSED");
        else             $display("PIP TEST FAILED");
        $finish;
    end
endmodule
