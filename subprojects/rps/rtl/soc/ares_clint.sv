`timescale 1ns/1ps
// CLINT: software interrupts, 64-bit mtime and per-hart mtimecmp.
module ares_clint #(
  parameter int unsigned HART_COUNT = 1
) (
  input  logic        clk,
  input  logic        rst,

  input  logic        req_valid,
  output logic        req_ready,
  input  logic        req_write,
  input  logic [31:0] req_addr,   // offset from CLINT base
  input  logic [31:0] req_wdata,
  input  logic [3:0]  req_wstrb,
  output logic        rsp_valid,
  input  logic        rsp_ready,
  output logic [31:0] rsp_rdata,

  output logic [HART_COUNT-1:0] soft_irq,
  output logic [HART_COUNT-1:0] timer_irq
);
  logic [31:0] msip [0:HART_COUNT-1];
  logic [63:0] mtimecmp [0:HART_COUNT-1];
  logic [63:0] mtime_q;

  integer i;
  always_ff @(posedge clk) begin
    if (rst) begin
      mtime_q <= 64'd0;
      for (i = 0; i < HART_COUNT; i = i + 1) begin
        msip[i] <= 32'd0;
        mtimecmp[i] <= 64'hFFFF_FFFF_FFFF_FFFF;
      end
    end else begin
      mtime_q <= mtime_q + 64'd1;

      if (req_valid && req_ready && req_write) begin
        if (req_addr < 32'h0000_4000) begin
          for (i = 0; i < HART_COUNT; i = i + 1) begin
            if (req_addr == 32'(i * 4)) begin
              if (req_wstrb[0]) msip[i][0] <= req_wdata[0];
            end
          end
        end else if (req_addr >= 32'h0000_4000 && req_addr < 32'h0000_8000) begin
          for (i = 0; i < HART_COUNT; i = i + 1) begin
            if (req_addr == 32'(32'h4000 + i * 8)) begin
              mtimecmp[i][31:0] <= req_wdata;
            end
            if (req_addr == 32'(32'h4004 + i * 8)) begin
              mtimecmp[i][63:32] <= req_wdata;
            end
          end
        end else if (req_addr == 32'h0000_BFF8) begin
          mtime_q[31:0] <= req_wdata;
        end else if (req_addr == 32'h0000_BFFC) begin
          mtime_q[63:32] <= req_wdata;
        end
      end
    end
  end

  always_comb begin
    rsp_rdata = 32'd0;
    if (req_addr < 32'h0000_4000) begin
      for (int unsigned h = 0; h < HART_COUNT; h++) begin
        if (req_addr == 32'(h * 4)) rsp_rdata = msip[h];
      end
    end else if (req_addr >= 32'h0000_4000 && req_addr < 32'h0000_8000) begin
      for (int unsigned h = 0; h < HART_COUNT; h++) begin
        if (req_addr == 32'(32'h4000 + h * 8)) rsp_rdata = mtimecmp[h][31:0];
        if (req_addr == 32'(32'h4004 + h * 8)) rsp_rdata = mtimecmp[h][63:32];
      end
    end else if (req_addr == 32'h0000_BFF8) begin
      rsp_rdata = mtime_q[31:0];
    end else if (req_addr == 32'h0000_BFFC) begin
      rsp_rdata = mtime_q[63:32];
    end
  end

  assign req_ready = 1'b1;
  assign rsp_valid = req_valid;

  always_comb begin
    for (int unsigned h = 0; h < HART_COUNT; h++) begin
      soft_irq[h]  = msip[h][0];
      timer_irq[h] = (mtime_q >= mtimecmp[h]);
    end
  end
endmodule
