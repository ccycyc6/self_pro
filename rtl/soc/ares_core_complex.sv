`timescale 1ns/1ps
// Single ARES-L core complex: core, instruction cache, uncached data path,
// one miniTensor accelerator and the port arbiter that drives the memory
// subsystem.  The core is hart 0; there is no SMP/cluster machinery.
module ares_core_complex #(
  parameter logic [31:0] RESET_PC = 32'h0000_0000,
  parameter int unsigned L1_BYTES = 8192
) (
  input  logic         clk,
  input  logic         rst,

  // Memory port.
  output logic         l2_req_valid,
  input  logic         l2_req_ready,
  output logic         l2_req_write,
  output logic [31:0]  l2_req_addr,
  output logic [127:0] l2_req_wdata,
  output logic [15:0]  l2_req_wstrb,
  input  logic         l2_rsp_valid,
  output logic         l2_rsp_ready,
  input  logic [127:0] l2_rsp_rdata,

  input  logic         irq_timer,
  input  logic         irq_soft,
  output logic         mt_irq,

  output logic [31:0]  dbg_pc,
  output logic [31:0]  dbg_instr,
  output logic         dbg_commit,
  output logic         dbg_halt,
  output logic [31:0]  dbg_pc_f,
  output logic         dbg_ifid_valid,
  output logic         dbg_idex_valid,
  output logic         dbg_exmem_valid,
  output logic         dbg_memwb_valid,
  output logic         dbg_if_pending
);
  import ares_pkg::*;

  // ------------------------------------------------------------ core ports
  logic        imem_req_valid, imem_req_ready;
  logic [31:0] imem_req_addr, imem_rsp_data;
  logic        imem_rsp_valid;

  logic        dmem_req_valid, dmem_req_ready, dmem_req_write;
  logic [31:0] dmem_req_addr, dmem_req_wdata, dmem_rsp_rdata;
  logic [3:0]  dmem_req_wstrb;
  logic        dmem_rsp_valid;

  logic        dcache_flush_req, dcache_flush_done;
  logic        icache_invalidate, icache_invalidate_done;

  ares_l_core #(.RESET_PC(RESET_PC), .HARTID(4'd0)) u_core (
    .clk, .rst,
    .imem_req_valid, .imem_req_ready, .imem_req_addr, .imem_rsp_valid, .imem_rsp_data,
    .dmem_req_valid, .dmem_req_ready, .dmem_req_write, .dmem_req_addr,
    .dmem_req_wdata, .dmem_req_wstrb, .dmem_rsp_valid, .dmem_rsp_rdata,
    .irq_timer, .irq_soft, .irq_ext(mt_irq),
    .dcache_flush_req, .dcache_flush_done,
    .icache_invalidate, .icache_invalidate_done,
    .dbg_pc, .dbg_instr, .dbg_commit, .dbg_halt,
    .dbg_pc_f, .dbg_ifid_valid, .dbg_idex_valid,
    .dbg_exmem_valid, .dbg_memwb_valid,
    .dbg_if_pending, .dbg_exmem_addr(), .dbg_exmem_size(),
    .dbg_mem_rsp_data(), .dbg_mem_result(), .dbg_memwb_result()
  );

  // ----------------------------------------------------------- instruction
  logic        i_l2_req_valid, i_l2_req_ready, i_l2_req_write, i_l2_rsp_valid, i_l2_rsp_ready;
  logic [31:0] i_l2_req_addr;
  logic [127:0] i_l2_req_wdata, i_l2_rsp_rdata;
  logic [15:0] i_l2_req_wstrb;

  ares_l1i #(.SIZE_BYTES(L1_BYTES)) u_l1i (
    .clk, .rst,
    .cpu_req_valid(imem_req_valid), .cpu_req_ready(imem_req_ready),
    .cpu_req_addr(imem_req_addr), .cpu_rsp_valid(imem_rsp_valid), .cpu_rsp_data(imem_rsp_data),
    .l2_req_valid(i_l2_req_valid), .l2_req_ready(i_l2_req_ready),
    .l2_req_write(i_l2_req_write), .l2_req_addr(i_l2_req_addr),
    .l2_req_wdata(i_l2_req_wdata), .l2_req_wstrb(i_l2_req_wstrb),
    .l2_rsp_valid(i_l2_rsp_valid), .l2_rsp_ready(i_l2_rsp_ready), .l2_rsp_rdata(i_l2_rsp_rdata),
    .invalidate(icache_invalidate), .invalidate_done(icache_invalidate_done), .busy()
  );

  // ------------------------------------------------------------- data path
  logic        b_req_valid, b_req_ready, b_req_write, b_rsp_valid, b_rsp_ready;
  logic [31:0] b_req_addr, b_req_wdata, b_rsp_rdata;
  logic [3:0]  b_req_wstrb;

  // Simulation configuration: no data cache.  Every load/store is a single
  // uncached transaction, so the core and the miniTensor DMA share one
  // physical view of memory without any cache maintenance.
  ares_dmem u_dmem (
    .clk, .rst,
    .cpu_req_valid(dmem_req_valid), .cpu_req_ready(dmem_req_ready),
    .cpu_req_write(dmem_req_write), .cpu_req_addr(dmem_req_addr),
    .cpu_req_wdata(dmem_req_wdata), .cpu_req_wstrb(dmem_req_wstrb),
    .cpu_rsp_valid(dmem_rsp_valid), .cpu_rsp_rdata(dmem_rsp_rdata),
    .req_valid(b_req_valid), .req_ready(b_req_ready),
    .req_write(b_req_write), .req_addr(b_req_addr),
    .req_wdata(b_req_wdata), .req_wstrb(b_req_wstrb),
    .rsp_valid(b_rsp_valid), .rsp_ready(b_rsp_ready), .rsp_rdata(b_rsp_rdata),
    .flush_req(dcache_flush_req), .flush_done(dcache_flush_done)
  );

  // ----------------------------------------------------------- miniTensor
  logic        mt_l2_req_valid, mt_l2_req_ready, mt_l2_req_write, mt_l2_rsp_valid, mt_l2_rsp_ready;
  logic [31:0] mt_l2_req_addr;
  logic [127:0] mt_l2_req_wdata, mt_l2_rsp_rdata;
  logic [15:0] mt_l2_req_wstrb;

  logic        mt_reg_wr_en;
  logic [2:0]  mt_reg_wr_idx;
  logic [31:0] mt_reg_wr_data;
  logic        mt_status_rd;
  logic [31:0] mt_status, mt_result;
  logic [31:0] mt_perf_dma, mt_perf_mma;

`ifdef ARES_NO_MT
  // Bring-up builds replace the accelerator with a port-compatible stub.
  // The two instantiations are spelled out in full on purpose: the ADS
  // port preparer only expands an implicit .port when the previous token is
  // '(' or ',', which is not true after an `endif.
  mt_cluster_stub u_mt (
    .clk, .rst,
    .reg_wr_en(mt_reg_wr_en), .reg_wr_idx(mt_reg_wr_idx), .reg_wr_data(mt_reg_wr_data),
    .status_rd(mt_status_rd), .status(mt_status), .result_data(mt_result),
    .l2_req_valid(mt_l2_req_valid), .l2_req_ready(mt_l2_req_ready),
    .l2_req_write(mt_l2_req_write), .l2_req_addr(mt_l2_req_addr),
    .l2_req_wdata(mt_l2_req_wdata), .l2_req_wstrb(mt_l2_req_wstrb),
    .l2_rsp_valid(mt_l2_rsp_valid), .l2_rsp_ready(mt_l2_rsp_ready), .l2_rsp_rdata(mt_l2_rsp_rdata),
    .mt_irq(mt_irq),
    .perf_dma(mt_perf_dma), .perf_mma(mt_perf_mma)
  );
`else
  mt_cluster u_mt (
    .clk, .rst,
    .reg_wr_en(mt_reg_wr_en), .reg_wr_idx(mt_reg_wr_idx), .reg_wr_data(mt_reg_wr_data),
    .status_rd(mt_status_rd), .status(mt_status), .result_data(mt_result),
    .l2_req_valid(mt_l2_req_valid), .l2_req_ready(mt_l2_req_ready),
    .l2_req_write(mt_l2_req_write), .l2_req_addr(mt_l2_req_addr),
    .l2_req_wdata(mt_l2_req_wdata), .l2_req_wstrb(mt_l2_req_wstrb),
    .l2_rsp_valid(mt_l2_rsp_valid), .l2_rsp_ready(mt_l2_rsp_ready), .l2_rsp_rdata(mt_l2_rsp_rdata),
    .mt_irq(mt_irq),
    .perf_dma(mt_perf_dma), .perf_mma(mt_perf_mma)
  );
`endif

  // --------------------------------------------------- bypass / local MMIO
  typedef enum logic [2:0] {
    B_IDLE, B_MT_RESP, B_L2_REQ, B_L2_WAIT, B_L2_RESP
  } bstate_t;
  bstate_t bstate_q;

  logic [31:0] b_addr_q, b_wdata_q, b_rsp_data_q;
  logic [3:0]  b_wstrb_q;
  logic        b_write_q;
  logic [1:0]  b_lane_q;

  logic        b_l2_req_valid, b_l2_req_ready, b_l2_req_write;
  logic [31:0] b_l2_req_addr;
  logic [127:0] b_l2_req_wdata;
  logic [15:0] b_l2_req_wstrb;
  logic        b_l2_rsp_valid, b_l2_rsp_ready;
  logic [127:0] b_l2_rsp_rdata;

  wire mt_local = (b_req_addr[31:12] == MT_BASE[31:12]);
  wire [2:0] mt_idx = b_req_addr[4:2];

  assign b_req_ready = (bstate_q == B_IDLE);
  assign b_rsp_valid = (bstate_q == B_MT_RESP) || (bstate_q == B_L2_RESP);
  assign b_rsp_rdata = b_rsp_data_q;

  assign mt_reg_wr_en = (bstate_q == B_IDLE) && b_req_valid && b_req_ready &&
                        b_req_write && mt_local;
  assign mt_reg_wr_idx = mt_idx;
  assign mt_reg_wr_data = b_req_wdata;
  assign mt_status_rd = (bstate_q == B_IDLE) && b_req_valid && b_req_ready &&
                        !b_req_write && mt_local && (mt_idx == 3'd4);


  assign b_l2_req_valid = (bstate_q == B_L2_REQ);
  assign b_l2_req_write = b_write_q;

  wire b_is_mmio = ((b_addr_q[31:16] == 16'h0001) ||
                    (b_addr_q[31:16] == 16'hD000));
  assign b_l2_req_addr = b_is_mmio ? {b_addr_q[31:2], 2'b00} : {b_addr_q[31:4], 4'b0};
  assign b_l2_rsp_ready = (bstate_q == B_L2_WAIT);

  always_comb begin
    b_l2_req_wdata = 128'd0;
    b_l2_req_wstrb = 16'd0;
    if (b_is_mmio) begin
      b_l2_req_wdata[31:0] = b_wdata_q;
      b_l2_req_wstrb[3:0] = b_wstrb_q;
    end else begin
      b_l2_req_wdata[b_lane_q*32 +: 32] = b_wdata_q;
      for (int unsigned i = 0; i < 4; i++) begin
        b_l2_req_wstrb[b_lane_q*4 + i] = b_wstrb_q[i];
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      bstate_q <= B_IDLE;
      b_addr_q <= 32'd0;
      b_wdata_q <= 32'd0;
      b_wstrb_q <= 4'd0;
      b_write_q <= 1'b0;
      b_lane_q <= 2'd0;
      b_rsp_data_q <= 32'd0;
    end else begin
      case (bstate_q)
        B_IDLE: begin
          if (b_req_valid && b_req_ready) begin
            b_addr_q <= b_req_addr;
            b_wdata_q <= b_req_wdata;
            b_wstrb_q <= b_req_wstrb;
            b_write_q <= b_req_write;
            b_lane_q <= b_req_addr[3:2];
            if (mt_local) begin
              bstate_q <= B_MT_RESP;
              case (mt_idx)
                3'd4: b_rsp_data_q <= mt_status;
                3'd5: b_rsp_data_q <= mt_result;
                3'd6: b_rsp_data_q <= mt_perf_dma;
                3'd7: b_rsp_data_q <= mt_perf_mma;
                default: b_rsp_data_q <= 32'd0;
              endcase
            end else begin
              bstate_q <= B_L2_REQ;
            end
          end
        end
        B_MT_RESP: if (b_rsp_ready) bstate_q <= B_IDLE;
        B_L2_REQ: if (b_l2_req_ready) bstate_q <= B_L2_WAIT;
        B_L2_WAIT: begin
          if (b_l2_rsp_valid) begin
            b_rsp_data_q <= b_l2_rsp_rdata[b_lane_q*32 +: 32];
            bstate_q <= B_L2_RESP;
          end
        end
        B_L2_RESP: if (b_rsp_ready) bstate_q <= B_IDLE;
        default: bstate_q <= B_IDLE;
      endcase
    end
  end

  // -------------------------------------------------------------- mem mux
  // Three masters: 0 = instruction cache, 1 = miniTensor DMA, 2 = data/MMIO.
  logic [2:0]        m_req_valid, m_req_ready, m_req_write;
  logic [2:0][31:0]  m_req_addr;
  logic [2:0][127:0] m_req_wdata;
  logic [2:0][15:0]  m_req_wstrb;
  logic [2:0]        m_rsp_valid, m_rsp_ready;
  logic [2:0][127:0] m_rsp_rdata;

  assign m_req_valid[0] = i_l2_req_valid;
  assign m_req_write[0] = i_l2_req_write;
  assign m_req_addr[0]  = i_l2_req_addr;
  assign m_req_wdata[0] = i_l2_req_wdata;
  assign m_req_wstrb[0] = i_l2_req_wstrb;
  assign i_l2_req_ready = m_req_ready[0];
  assign i_l2_rsp_valid = m_rsp_valid[0];
  assign i_l2_rsp_rdata = m_rsp_rdata[0];
  assign m_rsp_ready[0] = i_l2_rsp_ready;

  assign m_req_valid[1] = mt_l2_req_valid;
  assign m_req_write[1] = mt_l2_req_write;
  assign m_req_addr[1]  = mt_l2_req_addr;
  assign m_req_wdata[1] = mt_l2_req_wdata;
  assign m_req_wstrb[1] = mt_l2_req_wstrb;
  assign mt_l2_req_ready = m_req_ready[1];
  assign mt_l2_rsp_valid = m_rsp_valid[1];
  assign mt_l2_rsp_rdata = m_rsp_rdata[1];
  assign m_rsp_ready[1] = mt_l2_rsp_ready;

  assign m_req_valid[2] = b_l2_req_valid;
  assign m_req_write[2] = b_l2_req_write;
  assign m_req_addr[2]  = b_l2_req_addr;
  assign m_req_wdata[2] = b_l2_req_wdata;
  assign m_req_wstrb[2] = b_l2_req_wstrb;
  assign b_l2_req_ready = m_req_ready[2];
  assign b_l2_rsp_valid = m_rsp_valid[2];
  assign b_l2_rsp_rdata = m_rsp_rdata[2];
  assign m_rsp_ready[2] = b_l2_rsp_ready;

  typedef enum logic [1:0] {A_IDLE, A_WAIT} astate_t;
  astate_t astate_q;
  logic [1:0] owner_q;

  always_comb begin
    m_req_ready = 3'b000;
    if (astate_q == A_IDLE) begin
      if (m_req_valid[1]) m_req_ready[1] = l2_req_ready;
      else if (m_req_valid[2]) m_req_ready[2] = l2_req_ready;
      else if (m_req_valid[0]) m_req_ready[0] = l2_req_ready;
    end
  end

  always_comb begin
    l2_req_valid = 1'b0;
    l2_req_write = 1'b0;
    l2_req_addr  = 32'd0;
    l2_req_wdata = 128'd0;
    l2_req_wstrb = 16'd0;
    if (astate_q == A_IDLE) begin
      if (m_req_valid[1]) begin
        l2_req_valid = m_req_valid[1]; l2_req_write = m_req_write[1];
        l2_req_addr = m_req_addr[1]; l2_req_wdata = m_req_wdata[1]; l2_req_wstrb = m_req_wstrb[1];
      end else if (m_req_valid[2]) begin
        l2_req_valid = m_req_valid[2]; l2_req_write = m_req_write[2];
        l2_req_addr = m_req_addr[2]; l2_req_wdata = m_req_wdata[2]; l2_req_wstrb = m_req_wstrb[2];
      end else if (m_req_valid[0]) begin
        l2_req_valid = m_req_valid[0]; l2_req_write = m_req_write[0];
        l2_req_addr = m_req_addr[0]; l2_req_wdata = m_req_wdata[0]; l2_req_wstrb = m_req_wstrb[0];
      end
    end
  end

  always_comb begin
    m_rsp_valid = 3'b000;
    m_rsp_rdata = '0;
    l2_rsp_ready = 1'b0;
    if (astate_q == A_WAIT) begin
      m_rsp_valid[owner_q] = l2_rsp_valid;
      m_rsp_rdata[owner_q] = l2_rsp_rdata;
      l2_rsp_ready = m_rsp_ready[owner_q];
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      astate_q <= A_IDLE;
      owner_q <= 2'd0;
    end else begin
      case (astate_q)
        A_IDLE: begin
          if (l2_req_valid && l2_req_ready) begin
            astate_q <= A_WAIT;
            if (m_req_valid[1]) owner_q <= 2'd1;
            else if (m_req_valid[2]) owner_q <= 2'd2;
            else owner_q <= 2'd0;
          end
        end
        A_WAIT: begin
          if (l2_rsp_valid && l2_rsp_ready) astate_q <= A_IDLE;
        end
        default: astate_q <= A_IDLE;
      endcase
    end
  end
endmodule
