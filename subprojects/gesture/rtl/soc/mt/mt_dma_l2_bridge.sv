`timescale 1ns/1ps
// miniTensor 128-bit DMA port -> cluster L2 master.
// Both reads and writes consume the L2 response so the cluster arbiter can
// return to idle after the write handshake.
module mt_dma_l2_bridge (
  input  logic         clk,
  input  logic         rst,

  input  logic         mem_rd_valid,
  output logic         mem_rd_ready,
  input  logic [31:0]  mem_rd_addr,
  output logic         mem_rsp_valid,
  input  logic         mem_rsp_ready,
  output logic [127:0] mem_rsp_data,

  input  logic         mem_wr_valid,
  output logic         mem_wr_ready,
  input  logic [31:0]  mem_wr_addr,
  input  logic [127:0] mem_wr_data,
  input  logic [15:0]  mem_wr_be,

  output logic         l2_req_valid,
  input  logic         l2_req_ready,
  output logic         l2_req_write,
  output logic [31:0]  l2_req_addr,
  output logic [127:0] l2_req_wdata,
  output logic [15:0]  l2_req_wstrb,
  input  logic         l2_rsp_valid,
  output logic         l2_rsp_ready,
  input  logic [127:0] l2_rsp_rdata
);
  typedef enum logic [2:0] {
    D_IDLE, D_RD_REQ, D_RD_WAIT, D_RD_RESP, D_WR_REQ, D_WR_RESP
  } state_t;
  state_t state_q;

  logic [31:0]  rd_addr_q;
  logic [127:0] rsp_data_q;

  assign l2_req_valid = (state_q == D_RD_REQ) || (state_q == D_WR_REQ);
  assign l2_req_write = (state_q == D_WR_REQ);
  assign l2_req_addr  = (state_q == D_WR_REQ) ? mem_wr_addr : rd_addr_q;
  assign l2_req_wdata = mem_wr_data;
  assign l2_req_wstrb = mem_wr_be;

  assign mem_rd_ready  = (state_q == D_IDLE) && !mem_wr_valid;
  assign mem_wr_ready  = (state_q == D_WR_REQ) && l2_req_ready;
  assign mem_rsp_valid = (state_q == D_RD_RESP);
  assign mem_rsp_data  = rsp_data_q;
  assign l2_rsp_ready  = (state_q == D_RD_WAIT) || (state_q == D_WR_RESP);

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= D_IDLE;
      rd_addr_q <= 32'd0;
      rsp_data_q <= 128'd0;
    end else begin
      case (state_q)
        D_IDLE: begin
          if (mem_rd_valid) begin
            rd_addr_q <= mem_rd_addr;
            state_q <= D_RD_REQ;
          end else if (mem_wr_valid) begin
            state_q <= D_WR_REQ;
          end
        end
        D_RD_REQ: if (l2_req_ready) state_q <= D_RD_WAIT;
        D_RD_WAIT: begin
          if (l2_rsp_valid) begin
            rsp_data_q <= l2_rsp_rdata;
            state_q <= D_RD_RESP;
          end
        end
        D_RD_RESP: if (mem_rsp_ready) state_q <= D_IDLE;
        D_WR_REQ: if (l2_req_ready) state_q <= D_WR_RESP;
        D_WR_RESP: if (l2_rsp_valid) state_q <= D_IDLE;
        default: state_q <= D_IDLE;
      endcase
    end
  end
endmodule
