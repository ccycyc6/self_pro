`timescale 1ns/1ps
// Memory subsystem for the simulation SoC: Boot ROM, 192 KiB scratchpad,
// DDR3 model and the 32-bit MMIO bus.  There is deliberately no L2 cache in
// this configuration: the core data path is uncached, the instruction cache
// lives next to the core, and the miniTensor DMA works directly on the
// scratchpad.  One request is in flight at a time.
module ares_l2 #(
  parameter int unsigned SCRATCH_WORDS = 12288, // 192 KiB / 16 B
  parameter int unsigned ROM_WORDS     = 16384  // 64 KiB / 4 B
) (
  input  logic          clk,
  input  logic          rst,

  input  logic          req_valid,
  output logic          req_ready,
  input  logic          req_write,
  input  logic [31:0]   req_addr,
  input  logic [127:0]  req_wdata,
  input  logic [15:0]   req_wstrb,
  output logic          rsp_valid,
  input  logic          rsp_ready,
  output logic [127:0]  rsp_rdata,

  // DDR3 model (16-byte beats).
  output logic         ddr_req_valid,
  input  logic         ddr_req_ready,
  output logic         ddr_req_write,
  output logic [31:0]  ddr_req_addr,
  output logic [127:0] ddr_req_wdata,
  output logic [15:0]  ddr_req_wstrb,
  input  logic         ddr_rsp_valid,
  output logic         ddr_rsp_ready,
  input  logic [127:0] ddr_rsp_rdata,

  // 32-bit MMIO bus.
  output logic         mmio_req_valid,
  input  logic         mmio_req_ready,
  output logic         mmio_req_write,
  output logic [31:0]  mmio_req_addr,
  output logic [31:0]  mmio_req_wdata,
  output logic [3:0]   mmio_req_wstrb,
  input  logic         mmio_rsp_valid,
  output logic         mmio_rsp_ready,
  input  logic [31:0]  mmio_rsp_rdata
);
  import ares_pkg::*;

  logic [127:0] sp_mem [0:SCRATCH_WORDS-1];

`ifdef ARES_BOOT_ROM
  // FPGA build: the boot ROM is a generated combinational table.  It has no
  // initial contents at all, so it cannot depend on how a tool treats memory
  // initialisation or $readmemh paths.
  wire [127:0] rom_line;

  boot_rom u_boot_rom (
    .idx  (req_addr[15:4]),
    .data (rom_line)
  );
`else
  logic [31:0]  rom_mem [0:ROM_WORDS-1];

  initial begin
    // Boot ROM trampoline: lui x1, 0x80000 ; jalr x0, 0(x1)
    rom_mem[0] = 32'h8000_00b7;
    rom_mem[1] = 32'h0000_8067;
  end
`endif


  typedef enum logic [2:0] {
    S_IDLE, S_RESP, S_MMIO_REQ, S_MMIO_WAIT, S_DDR_REQ, S_DDR_WAIT
  } state_t;
  state_t state_q;

  logic        write_q;
  logic [31:0] addr_q;
  logic [127:0] wdata_q;
  logic [15:0]  wstrb_q;
  logic [127:0] rsp_data_q;
  logic [127:0] sp_tmp;

  wire is_rom     = (addr_q < ROM_SIZE);
  wire is_scratch = (addr_q >= SCRATCH_BASE) && (addr_q < (SCRATCH_BASE + SCRATCH_SIZE));
  wire is_mmio    = ((addr_q >= CLINT_BASE) && (addr_q < (CLINT_BASE + 32'h1_0000))) ||
                    ((addr_q >= MMIO_BASE) && (addr_q < (MMIO_BASE + MMIO_SIZE)));
  wire is_ddr_unc = (addr_q >= DDR_UNC_BASE) && (addr_q < (DDR_UNC_BASE + DDR_UNC_SIZE));
  wire is_ddr_c   = (addr_q >= DDR_BASE) && (addr_q < (DDR_BASE + DDR_SIZE));

  wire [31:0] ddr_phys_addr = is_ddr_unc ? (DDR_BASE + (addr_q - DDR_UNC_BASE)) : addr_q;

  assign req_ready = (state_q == S_IDLE);
  assign rsp_valid = (state_q == S_RESP);
  assign rsp_rdata = rsp_data_q;

  assign ddr_req_valid = (state_q == S_DDR_REQ);
  assign ddr_req_write = write_q;
  assign ddr_req_addr  = {ddr_phys_addr[31:4], 4'b0};
  assign ddr_req_wdata = wdata_q;
  assign ddr_req_wstrb = wstrb_q;
  assign ddr_rsp_ready = (state_q == S_DDR_WAIT);

  assign mmio_req_valid = (state_q == S_MMIO_REQ);
  assign mmio_req_write = write_q;
  assign mmio_req_addr  = {addr_q[31:2], 2'b00};
  assign mmio_req_wdata = wdata_q[31:0];
  assign mmio_req_wstrb = wstrb_q[3:0];
  assign mmio_rsp_ready = (state_q == S_MMIO_WAIT);

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q    <= S_IDLE;
      write_q    <= 1'b0;
      addr_q     <= 32'd0;
      wdata_q    <= 128'd0;
      wstrb_q    <= 16'd0;
      rsp_data_q <= 128'd0;
    end else begin
      case (state_q)
        S_IDLE: begin
          if (req_valid && req_ready) begin
            write_q <= req_write;
            addr_q  <= req_addr;
            wdata_q <= req_wdata;
            wstrb_q <= req_wstrb;

            if (req_addr < ROM_SIZE) begin
`ifdef ARES_BOOT_ROM
              rsp_data_q <= rom_line;
`else
              rsp_data_q <= {rom_mem[req_addr[15:2] + 3],
                             rom_mem[req_addr[15:2] + 2],
                             rom_mem[req_addr[15:2] + 1],
                             rom_mem[req_addr[15:2]]};
`endif
              state_q <= S_RESP;
            end else if ((req_addr >= SCRATCH_BASE) &&
                         (req_addr < (SCRATCH_BASE + SCRATCH_SIZE))) begin
              if (req_write) begin
                sp_tmp = sp_mem[(req_addr - SCRATCH_BASE) >> 4];
                for (int unsigned b = 0; b < 16; b++) begin
                  if (req_wstrb[b]) sp_tmp[b*8 +: 8] = req_wdata[b*8 +: 8];
                end
                sp_mem[(req_addr - SCRATCH_BASE) >> 4] <= sp_tmp;
                rsp_data_q <= sp_tmp;
              end else begin
                rsp_data_q <= sp_mem[(req_addr - SCRATCH_BASE) >> 4];
              end
              state_q <= S_RESP;
            end else if (((req_addr >= CLINT_BASE) &&
                          (req_addr < (CLINT_BASE + 32'h1_0000))) ||
                         ((req_addr >= MMIO_BASE) &&
                          (req_addr < (MMIO_BASE + MMIO_SIZE)))) begin
              state_q <= S_MMIO_REQ;
            end else if ((req_addr >= DDR_UNC_BASE) &&
                         (req_addr < (DDR_UNC_BASE + DDR_UNC_SIZE))) begin
              state_q <= S_DDR_REQ;
            end else if ((req_addr >= DDR_BASE) &&
                         (req_addr < (DDR_BASE + DDR_SIZE))) begin
              state_q <= S_DDR_REQ;
            end else begin
              rsp_data_q <= 128'd0;
              state_q <= S_RESP;
            end
          end
        end
        S_MMIO_REQ: if (mmio_req_ready) state_q <= S_MMIO_WAIT;
        S_MMIO_WAIT: begin
          if (mmio_rsp_valid) begin
            rsp_data_q <= 128'd0;
            rsp_data_q[addr_q[3:2]*32 +: 32] <= mmio_rsp_rdata;
            state_q <= S_RESP;
          end
        end
        S_DDR_REQ: if (ddr_req_ready) state_q <= S_DDR_WAIT;
        S_DDR_WAIT: begin
          if (ddr_rsp_valid) begin
            rsp_data_q <= ddr_rsp_rdata;
            state_q <= S_RESP;
          end
        end
        S_RESP: if (rsp_ready) state_q <= S_IDLE;
        default: state_q <= S_IDLE;
      endcase
    end
  end
endmodule
