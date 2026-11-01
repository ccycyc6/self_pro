`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// ares_dmem -- uncached 32-bit data path for the ARES-L core.
//
// The core has no data cache in the simulation-only configuration: every load
// and store is issued as one 32-bit transaction on the cluster bypass port.
// Accesses that target the cached DDR window (0x8000_0000..0xBFFF_FFFF) are
// translated to the uncached alias (0x4000_0000..0x7FFF_FFFF) so that the
// accelerator DMA and the CPU always observe the same physical memory.  This
// removes the cache-coherence corner cases from the YOLO path and keeps the
// memory model small enough to reason about before board integration.
//
// The interface timing matches ares_l1d: one-cycle request handshake, one-cycle
// response pulse.  FENCE has nothing to flush, so it completes immediately.
// -----------------------------------------------------------------------------
module ares_dmem #(
  parameter logic [31:0] CACHE_BASE = 32'h8000_0000,
  parameter logic [31:0] CACHE_SIZE = 32'h4000_0000,
  parameter logic [31:0] UNC_BASE   = 32'h4000_0000
) (
  input  logic        clk,
  input  logic        rst,

  // Core data port.
  input  logic        cpu_req_valid,
  output logic        cpu_req_ready,
  input  logic        cpu_req_write,
  input  logic [31:0] cpu_req_addr,
  input  logic [31:0] cpu_req_wdata,
  input  logic [3:0]  cpu_req_wstrb,
  output logic        cpu_rsp_valid,
  output logic [31:0] cpu_rsp_rdata,

  // Cluster bypass / MMIO port.
  output logic        req_valid,
  input  logic        req_ready,
  output logic        req_write,
  output logic [31:0] req_addr,
  output logic [31:0] req_wdata,
  output logic [3:0]  req_wstrb,
  input  logic        rsp_valid,
  output logic        rsp_ready,
  input  logic [31:0] rsp_rdata,

  input  logic        flush_req,
  output logic        flush_done
);
  typedef enum logic [1:0] {D_IDLE, D_REQ, D_WAIT, D_RESP} state_t;
  state_t state_q;

  logic [31:0] addr_q, wdata_q;
  logic [3:0]  wstrb_q;
  logic        write_q;
  logic [31:0] rsp_data_q;

  wire [31:0] xlate_addr = (cpu_req_addr >= CACHE_BASE) &&
                           (cpu_req_addr < (CACHE_BASE + CACHE_SIZE))
                           ? (cpu_req_addr - (CACHE_BASE - UNC_BASE))
                           : cpu_req_addr;

  assign cpu_req_ready = (state_q == D_IDLE);
  assign cpu_rsp_valid = (state_q == D_RESP);
  assign cpu_rsp_rdata = rsp_data_q;

  assign req_valid = (state_q == D_REQ);
  assign req_write = write_q;
  assign req_addr  = addr_q;
  assign req_wdata = wdata_q;
  assign req_wstrb = wstrb_q;
  assign rsp_ready = (state_q == D_WAIT);

  assign flush_done = flush_req;

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q    <= D_IDLE;
      addr_q     <= 32'd0;
      wdata_q    <= 32'd0;
      wstrb_q    <= 4'd0;
      write_q    <= 1'b0;
      rsp_data_q <= 32'd0;
    end else begin
      case (state_q)
        D_IDLE: begin
          if (cpu_req_valid && cpu_req_ready) begin
            addr_q  <= xlate_addr;
            wdata_q <= cpu_req_wdata;
            wstrb_q <= cpu_req_wstrb;
            write_q <= cpu_req_write;
            state_q <= D_REQ;
          end
        end
        D_REQ: if (req_ready) state_q <= D_WAIT;
        D_WAIT: begin
          if (rsp_valid) begin
            rsp_data_q <= rsp_rdata;
            state_q <= D_RESP;
          end
        end
        D_RESP: state_q <= D_IDLE;
        default: state_q <= D_IDLE;
      endcase
    end
  end
endmodule
