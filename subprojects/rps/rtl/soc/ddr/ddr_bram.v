// ---------------------------------------------------------------------------
// ddr_bram - the "external memory" port backed by on-chip block RAM.
//
// B3 uses it to prove the memory path on its own: the CPU writes a pattern and
// reads it back through the same L2 decode and the same 128-bit beat protocol
// that the real DDR3 path will use, but with no DDR3 IP, no PHY and no
// calibration in the loop.
//
// Byte strobes are written as 16 explicit byte enables instead of a loop: a
// non-blocking partial write inside a for loop is rejected by Verilator, and a
// loop over a dynamic part-select is rejected by ADS.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps
module ddr_bram #(
    parameter integer WORDS = 2048,          // 128-bit lines -> WORDS*16 bytes
    // Derived from WORDS: passing only WORDS must still index the whole array,
    // otherwise the stack at 0x8002_0000 would alias onto the code.
    parameter integer IDXW  = $clog2(WORDS)
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         req_valid,
    output wire         req_ready,
    input  wire         req_write,
    input  wire [31:0]  req_addr,
    input  wire [127:0] req_wdata,
    input  wire [15:0]  req_wstrb,
    output wire         rsp_valid,
    input  wire         rsp_ready,
    output wire [127:0] rsp_rdata
);
    reg [127:0] mem [0:WORDS-1];

    wire [IDXW-1:0] idx = req_addr[IDXW+3:4];

    reg         rsp_valid_q;
    reg [127:0] rsp_q;

    assign req_ready = ~rsp_valid_q;
    assign rsp_valid = rsp_valid_q;
    assign rsp_rdata = rsp_q;

    always @(posedge clk) begin
        if (rst) begin
            rsp_valid_q <= 1'b0;
            rsp_q       <= 128'd0;
        end else if (req_valid && req_ready) begin
            rsp_valid_q <= 1'b1;
            if (req_write) begin
                if (req_wstrb[0])  mem[idx][7:0]    <= req_wdata[7:0];
                if (req_wstrb[1])  mem[idx][15:8]   <= req_wdata[15:8];
                if (req_wstrb[2])  mem[idx][23:16]  <= req_wdata[23:16];
                if (req_wstrb[3])  mem[idx][31:24]  <= req_wdata[31:24];
                if (req_wstrb[4])  mem[idx][39:32]  <= req_wdata[39:32];
                if (req_wstrb[5])  mem[idx][47:40]  <= req_wdata[47:40];
                if (req_wstrb[6])  mem[idx][55:48]  <= req_wdata[55:48];
                if (req_wstrb[7])  mem[idx][63:56]  <= req_wdata[63:56];
                if (req_wstrb[8])  mem[idx][71:64]  <= req_wdata[71:64];
                if (req_wstrb[9])  mem[idx][79:72]  <= req_wdata[79:72];
                if (req_wstrb[10]) mem[idx][87:80]  <= req_wdata[87:80];
                if (req_wstrb[11]) mem[idx][95:88]  <= req_wdata[95:88];
                if (req_wstrb[12]) mem[idx][103:96] <= req_wdata[103:96];
                if (req_wstrb[13]) mem[idx][111:104] <= req_wdata[111:104];
                if (req_wstrb[14]) mem[idx][119:112] <= req_wdata[119:112];
                if (req_wstrb[15]) mem[idx][127:120] <= req_wdata[127:120];
                rsp_q <= 128'd0;
            end else begin
                rsp_q <= mem[idx];
            end
        end else if (rsp_valid_q && rsp_ready) begin
            rsp_valid_q <= 1'b0;
        end
    end
endmodule
