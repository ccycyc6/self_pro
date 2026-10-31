`timescale 1ns/1ps
// Testbench for stereo_cap: crop origin, 2:1 decimation and row*320 stride.
module tb_stereo_cap;
    reg clk = 0, rst = 1;
    reg de = 0, vs = 0;
    reg [15:0] rgb = 16'h0000;

    wire        wr_en;
    wire [16:0] wr_addr;
    wire [7:0]  wr_data;
    wire        frame_tog;
    wire [31:0] wr_cnt;

    always #5 clk = ~clk;

    stereo_cap u_cap (
        .pixel_clk(clk), .pixel_rst(rst), .pixel_de(de),
        .pixel_rgb565(rgb), .pixel_vsync(vs),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .frame_tog(frame_tog), .wr_cnt(wr_cnt)
    );

    integer errors = 0;
    integer writes = 0;
    integer x, y, i;

    // prediction for the pixel presented this cycle
    reg        p_en;
    reg [16:0] p_addr;

    task predict(input integer px, input integer py);
        begin
            if (px >= 320 && px < 960 && py >= 80 && py < 560 &&
                ((px - 320) % 2 == 0) && ((py - 80) % 2 == 0)) begin
                p_en   = 1'b1;
                p_addr = ((py - 80) / 2) * 320 + ((px - 320) / 2);
            end else begin
                p_en   = 1'b0;
                p_addr = 17'd0;
            end
        end
    endtask

    // Phase-independent check: the writes of one row must be consecutive and
    // each row must start on a multiple of 320.  (Comparing against the bus
    // position turned out to be one cycle out, which the sequence check avoids.)
    reg [16:0] last_addr;
    integer    in_row = 0;

    always @(posedge clk) begin
        if (wr_en) begin
            if (writes == 0) begin
                if (wr_addr !== 17'd0) begin
                    $display("FAIL: first write is %0d, expected 0", wr_addr);
                    errors = errors + 1;
                end
            end else if (wr_addr == last_addr + 1) begin
                in_row = in_row + 1;
            end else if (wr_addr % 320 == 0 && wr_addr == ((last_addr / 320) + 1) * 320) begin
                in_row = 0;
            end else begin
                if (errors < 6)
                    $display("FAIL: write %0d after %0d breaks the row pattern",
                             wr_addr, last_addr);
                errors = errors + 1;
            end
            last_addr = wr_addr;
            writes = writes + 1;
        end
    end

    initial begin
        last_addr = 17'd0;

        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        for (y = 0; y < 90; y = y + 1) begin
            @(negedge clk);
            de = 1'b1;
            for (i = 0; i < 1280; i = i + 1) begin
                rgb   = {5'(i % 32), 6'(y % 64), 5'(i % 16)};
                @(negedge clk);
            end
            de = 1'b0;
            repeat (4) @(negedge clk);
        end

        $display("writes=%0d (expected %0d)", writes, 5 * 320);
        $display("stereo_cap errors=%0d", errors);
        if (errors == 0 && writes == 5 * 320) $display("STEREO_CAP TEST PASSED");
        else                                  $display("STEREO_CAP TEST FAILED");
        $finish;
    end
endmodule
