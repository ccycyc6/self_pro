`timescale 1ns/1ps
module ares_gpio (
  input  logic        clk,
  input  logic        rst,
  input  logic        req_valid,
  output logic        req_ready,
  input  logic        req_write,
  input  logic [31:0] req_addr,
  input  logic [31:0] req_wdata,
  input  logic [3:0]  req_wstrb,
  output logic        rsp_valid,
  input  logic        rsp_ready,
  output logic [31:0] rsp_rdata,
  input  logic [31:0] gpio_in,
  output logic [31:0] gpio_out,
  output logic [31:0] gpio_dir,
  output logic        gpio_irq
);
  logic [31:0] out_q, dir_q, irq_en_q, irq_status_q;
  logic [31:0] in_sync_q;

  assign req_ready = 1'b1;
  assign rsp_valid = req_valid;
  assign gpio_out = out_q;
  assign gpio_dir = dir_q;
  assign gpio_irq = |(irq_status_q & irq_en_q);

  always_comb begin
    case (req_addr[7:0])
      8'h00: rsp_rdata = in_sync_q;
      8'h04: rsp_rdata = out_q;
      8'h08: rsp_rdata = dir_q;
      8'h0C: rsp_rdata = irq_en_q;
      8'h10: rsp_rdata = irq_status_q;
      default: rsp_rdata = 32'd0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      out_q <= 32'd0;
      dir_q <= 32'd0;
      irq_en_q <= 32'd0;
      irq_status_q <= 32'd0;
      in_sync_q <= 32'd0;
    end else begin
      in_sync_q <= gpio_in;
      irq_status_q <= irq_status_q | (gpio_in ^ in_sync_q);

      if (req_valid && req_ready) begin
        if (req_write) begin
          case (req_addr[7:0])
            8'h04: out_q <= req_wdata;
            8'h08: dir_q <= req_wdata;
            8'h0C: irq_en_q <= req_wdata;
            8'h10: irq_status_q <= 32'd0;
            default: ;
          endcase
        end else if (req_addr[7:0] == 8'h10) begin
          irq_status_q <= 32'd0;
        end
      end
    end
  end
endmodule
