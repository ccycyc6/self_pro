`timescale 1ns/1ps
// Machine-mode CSR file.  The core commits traps and MRET here.
module ares_csr (
  input  logic        clk,
  input  logic        rst,
  input  logic [3:0]  hartid,

  input  logic [11:0] addr,
  input  logic [31:0] wdata,
  input  ares_pkg::csr_op_t op,
  input  logic        wr_en,
  output logic [31:0] rdata,

  input  logic        trap_en,
  input  logic [31:0] trap_cause,
  input  logic [31:0] trap_tval,
  input  logic [31:0] trap_epc,
  output logic [31:0] trap_vector,

  input  logic        mret_en,
  output logic [31:0] mret_epc,

  input  logic        irq_timer,
  input  logic        irq_soft,
  input  logic        irq_ext,
  output logic        irq_pending,

  input  logic        instret_inc,
  input  logic        cycle_inc,
  output logic [63:0] mcycle_o
);
  logic [31:0] mstatus_q, misa_q, mie_q, mtvec_q, mscratch_q;
  logic [31:0] mepc_q, mcause_q, mtval_q, mip_q;
  logic [31:0] mcycle_l_q, mcycle_h_q, minstret_l_q, minstret_h_q;
  logic [31:0] mcountinhibit_q;

  wire mstatus_mie = mstatus_q[3];

  assign trap_vector = {mtvec_q[31:2], 2'b00};
  assign mret_epc    = mepc_q;
  assign mcycle_o    = {mcycle_h_q, mcycle_l_q};

  // IRQ pending is a level: MIE && corresponding MIE bit && MIP bit.
  assign irq_pending = mstatus_mie && (
      (mie_q[3]  && mip_q[3])  ||
      (mie_q[7]  && mip_q[7])  ||
      (mie_q[11] && mip_q[11]));

  // ---------------------------------------------------------------- read mux
  always_comb begin
    case (addr)
      12'h300: rdata = mstatus_q;
      12'h301: rdata = misa_q;
      12'h304: rdata = mie_q;
      12'h305: rdata = mtvec_q;
      12'h340: rdata = mscratch_q;
      12'h341: rdata = mepc_q;
      12'h342: rdata = mcause_q;
      12'h343: rdata = mtval_q;
      12'h344: rdata = mip_q;
      12'hF14: rdata = {28'd0, hartid};
      12'hB00: rdata = mcycle_l_q;
      12'hB80: rdata = mcycle_h_q;
      12'hB02: rdata = minstret_l_q;
      12'hB82: rdata = minstret_h_q;
      12'h320: rdata = mcountinhibit_q;
      default: rdata = 32'd0;
    endcase
  end

  // --------------------------------------------------------------- write data
  logic [31:0] csr_old, csr_new;
  always_comb begin
    csr_old = rdata;
    case (op)
      ares_pkg::CSR_RW, ares_pkg::CSR_RWI: csr_new = wdata;
      ares_pkg::CSR_RS, ares_pkg::CSR_RSI: csr_new = csr_old | wdata;
      ares_pkg::CSR_RC, ares_pkg::CSR_RCI: csr_new = csr_old & ~wdata;
      default: csr_new = csr_old;
    endcase
  end

  task automatic write_csr(input logic [11:0] a, input logic [31:0] v);
    begin
      case (a)
        12'h300: mstatus_q <= {v[31:13], 2'b00, v[10:8], v[7], v[6:4], v[3], v[2:0]};
        12'h304: mie_q <= v & 32'h0000_0888;
        12'h305: mtvec_q <= {v[31:2], 2'b00};
        12'h340: mscratch_q <= v;
        12'h341: mepc_q <= {v[31:2], 2'b00};
        12'h342: mcause_q <= v;
        12'h343: mtval_q <= v;
        12'h344: mip_q <= v & 32'h0000_0888;
        12'hB00: mcycle_l_q <= v;
        12'hB80: mcycle_h_q <= v;
        12'hB02: minstret_l_q <= v;
        12'hB82: minstret_h_q <= v;
        12'h320: mcountinhibit_q <= v & 32'h0000_0005;
        default: ;
      endcase
    end
  endtask

  always_ff @(posedge clk) begin
    if (rst) begin
      mstatus_q     <= 32'h0000_0000;
      misa_q        <= 32'h4000_1100; // RV32IM
      mie_q         <= 32'h0000_0000;
      mtvec_q       <= 32'h0000_0000;
      mscratch_q    <= 32'h0000_0000;
      mepc_q        <= 32'h0000_0000;
      mcause_q      <= 32'h0000_0000;
      mtval_q       <= 32'h0000_0000;
      mip_q         <= 32'h0000_0000;
      mcycle_l_q    <= 32'h0000_0000;
      mcycle_h_q    <= 32'h0000_0000;
      minstret_l_q  <= 32'h0000_0000;
      minstret_h_q  <= 32'h0000_0000;
      mcountinhibit_q <= 32'h0000_0000;
    end else begin
      // Cycle and instruction counters
      if (cycle_inc && !mcountinhibit_q[0]) begin
        if (mcycle_l_q == 32'hFFFF_FFFF) begin
          mcycle_l_q <= 32'h0000_0000;
          mcycle_h_q <= mcycle_h_q + 32'd1;
        end else begin
          mcycle_l_q <= mcycle_l_q + 32'd1;
        end
      end
      if (instret_inc && !mcountinhibit_q[2]) begin
        if (minstret_l_q == 32'hFFFF_FFFF) begin
          minstret_l_q <= 32'h0000_0000;
          minstret_h_q <= minstret_h_q + 32'd1;
        end else begin
          minstret_l_q <= minstret_l_q + 32'd1;
        end
      end

      // Update MIP from interrupt sources every cycle.
      mip_q[3]  <= irq_soft;
      mip_q[7]  <= irq_timer;
      mip_q[11] <= irq_ext;

      if (trap_en) begin
        mepc_q   <= {trap_epc[31:2], 2'b00};
        mcause_q <= trap_cause;
        mtval_q  <= trap_tval;
        mstatus_q[7]  <= mstatus_q[3]; // MPIE
        mstatus_q[3]  <= 1'b0;         // MIE
        mstatus_q[12:11] <= 2'b11;     // MPP = M
      end else if (mret_en) begin
        mstatus_q[3]  <= mstatus_q[7]; // MIE = MPIE
        mstatus_q[7]  <= 1'b1;         // MPIE = 1
        mstatus_q[12:11] <= 2'b00;     // MPP = U
      end else if (wr_en) begin
        write_csr(addr, csr_new);
      end
    end
  end
endmodule
