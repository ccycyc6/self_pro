`timescale 1ns/1ps
// Behavioral DDR3 model: 32 MiB, 16-byte beats, two-cycle response.
module ddr3_model #(
  parameter int unsigned WORDS = 8388608, // 32 MiB / 4 B
  parameter              DDR_FILE = ""
) (
  input  logic         clk,
  input  logic         rst,
  input  logic         req_valid,
  output logic         req_ready,
  input  logic         req_write,
  input  logic [31:0]  req_addr,
  input  logic [127:0] req_wdata,
  input  logic [15:0]  req_wstrb,
  output logic         rsp_valid,
  input  logic         rsp_ready,
  output logic [127:0] rsp_rdata
);
  logic [31:0] mem [0:WORDS-1];

  integer init_i;
  string ddr_file;
  initial begin
    for (init_i = 0; init_i < WORDS; init_i = init_i + 1) mem[init_i] = 32'd0;
    if ($value$plusargs("DDR=%s", ddr_file))
      $readmemh(ddr_file, mem);
    else if (DDR_FILE != "")
      $readmemh(DDR_FILE, mem);
  end

  typedef enum logic [1:0] {D_IDLE, D_RSP} state_t;
  state_t state_q;
  logic [127:0] rsp_data_q;
  logic [31:0]  base_q;
  logic [31:0]  old_w, nw_w;   // hoisted: ADS rejects declarations in unnamed blocks

  assign req_ready = (state_q == D_IDLE);
  assign rsp_valid = (state_q == D_RSP);
  assign rsp_rdata = rsp_data_q;

  function automatic logic [31:0] word_at(input logic [31:0] a);
    word_at = mem[a[24:2]];
  endfunction

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= D_IDLE;
      rsp_data_q <= 128'd0;
      base_q <= 32'd0;
    end else begin
      case (state_q)
        D_IDLE: begin
          if (req_valid && req_ready) begin
            base_q <= req_addr;
            if (req_write) begin
              for (int unsigned i = 0; i < 4; i++) begin
                if (req_wstrb[4*i +: 4] != 4'd0) begin
                  old_w = word_at(req_addr + i*4);
                  nw_w = old_w;
                  for (int unsigned b = 0; b < 4; b++) begin
                    if (req_wstrb[4*i + b]) nw_w[b*8 +: 8] = req_wdata[32*i + b*8 +: 8];
                  end
                  mem[req_addr[24:2] + i] <= nw_w;
                end
              end
              rsp_data_q <= 128'd0;
            end else begin
              rsp_data_q <= {word_at(req_addr + 12), word_at(req_addr + 8),
                             word_at(req_addr + 4),  word_at(req_addr)};
            end
            state_q <= D_RSP;
          end
        end
        D_RSP: if (rsp_ready) state_q <= D_IDLE;
        default: state_q <= D_IDLE;
      endcase
    end
  end
endmodule