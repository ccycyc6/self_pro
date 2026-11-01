`timescale 1ns/1ps

// Single-outstanding bidirectional DMA between uncached memory and the UB.
// A command is either memory-to-UB (cmd_write=0) or UB-to-memory (cmd_write=1).
module vpu_dma #(
  parameter int unsigned DATA_WIDTH = 128,
  parameter int unsigned UB_ADDR_WIDTH = 8,
  parameter int unsigned COUNT_WIDTH = 8
) (
  input  logic                         clk,
  input  logic                         rst,
  input  logic                         cmd_valid,
  output logic                         cmd_ready,
  input  logic                         cmd_write,
  input  logic [31:0]                  cmd_mem_addr,
  input  logic [UB_ADDR_WIDTH-1:0]     cmd_ub_addr,
  input  logic [COUNT_WIDTH-1:0]       cmd_tile_count,
  output logic                         busy,
  output logic                         done,

  output logic                         mem_rd_valid,
  input  logic                         mem_rd_ready,
  output logic [31:0]                  mem_rd_addr,
  input  logic                         mem_rsp_valid,
  output logic                         mem_rsp_ready,
  input  logic [DATA_WIDTH-1:0]        mem_rsp_data,

  output logic                         mem_wr_valid,
  input  logic                         mem_wr_ready,
  output logic [31:0]                  mem_wr_addr,
  output logic [DATA_WIDTH-1:0]        mem_wr_data,
  output logic [DATA_WIDTH/8-1:0]      mem_wr_be,

  output logic                         ub_wr_en,
  output logic [UB_ADDR_WIDTH-1:0]     ub_wr_addr,
  output logic [DATA_WIDTH-1:0]        ub_wr_data,
  output logic [DATA_WIDTH/8-1:0]      ub_wr_be,
  output logic                         ub_rd_en,
  output logic [UB_ADDR_WIDTH-1:0]     ub_rd_addr,
  input  logic                         ub_rd_valid,
  input  logic [DATA_WIDTH-1:0]        ub_rd_data
);
  localparam int unsigned BYTE_COUNT = DATA_WIDTH / 8;

  typedef enum logic [2:0] {
    S_IDLE,
    S_LOAD_REQUEST,
    S_LOAD_RESPONSE,
    S_STORE_UB_REQUEST,
    S_STORE_UB_WAIT,
    S_STORE_MEM_REQUEST
  } state_t;

  state_t state_q;
  logic [31:0] mem_addr_q;
  logic [UB_ADDR_WIDTH-1:0] ub_addr_q;
  logic [COUNT_WIDTH-1:0] remaining_q;
  logic [DATA_WIDTH-1:0] store_data_q;
  logic done_q;

  wire cmd_fire = cmd_valid && cmd_ready;
  wire mem_rd_fire = mem_rd_valid && mem_rd_ready;
  wire mem_rsp_fire = mem_rsp_valid && mem_rsp_ready;
  wire mem_wr_fire = mem_wr_valid && mem_wr_ready;

  initial begin
    if (DATA_WIDTH == 0 || DATA_WIDTH % 8 != 0)
      $fatal(1, "vpu_dma DATA_WIDTH must be a positive multiple of 8");
    if (COUNT_WIDTH == 0)
      $fatal(1, "vpu_dma COUNT_WIDTH must be positive");
  end

  assign cmd_ready = (state_q == S_IDLE) && (cmd_tile_count != '0);
  assign busy = (state_q != S_IDLE);
  assign done = done_q;

  assign mem_rd_valid = (state_q == S_LOAD_REQUEST);
  assign mem_rd_addr = mem_addr_q;
  assign mem_rsp_ready = (state_q == S_LOAD_RESPONSE);

  assign mem_wr_valid = (state_q == S_STORE_MEM_REQUEST);
  assign mem_wr_addr = mem_addr_q;
  assign mem_wr_data = store_data_q;
  assign mem_wr_be = '1;

  assign ub_wr_en = mem_rsp_fire;
  assign ub_wr_addr = ub_addr_q;
  assign ub_wr_data = mem_rsp_data;
  assign ub_wr_be = '1;
  assign ub_rd_en = (state_q == S_STORE_UB_REQUEST);
  assign ub_rd_addr = ub_addr_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= S_IDLE;
      mem_addr_q <= '0;
      ub_addr_q <= '0;
      remaining_q <= '0;
      store_data_q <= '0;
      done_q <= 1'b0;
    end else begin
      done_q <= 1'b0;
      case (state_q)
        S_IDLE: begin
          if (cmd_fire) begin
            mem_addr_q <= cmd_mem_addr;
            ub_addr_q <= cmd_ub_addr;
            remaining_q <= cmd_tile_count;
            state_q <= cmd_write ? S_STORE_UB_REQUEST : S_LOAD_REQUEST;
          end
        end
        S_LOAD_REQUEST: begin
          if (mem_rd_fire)
            state_q <= S_LOAD_RESPONSE;
        end
        S_LOAD_RESPONSE: begin
          if (mem_rsp_fire) begin
            if (remaining_q == COUNT_WIDTH'(1)) begin
              remaining_q <= '0;
              state_q <= S_IDLE;
              done_q <= 1'b1;
            end else begin
              mem_addr_q <= mem_addr_q + BYTE_COUNT;
              ub_addr_q <= ub_addr_q + 1'b1;
              remaining_q <= remaining_q - 1'b1;
              state_q <= S_LOAD_REQUEST;
            end
          end
        end
        S_STORE_UB_REQUEST: state_q <= S_STORE_UB_WAIT;
        S_STORE_UB_WAIT: begin
          if (ub_rd_valid) begin
            store_data_q <= ub_rd_data;
            state_q <= S_STORE_MEM_REQUEST;
          end
        end
        S_STORE_MEM_REQUEST: begin
          if (mem_wr_fire) begin
            if (remaining_q == COUNT_WIDTH'(1)) begin
              remaining_q <= '0;
              state_q <= S_IDLE;
              done_q <= 1'b1;
            end else begin
              mem_addr_q <= mem_addr_q + BYTE_COUNT;
              ub_addr_q <= ub_addr_q + 1'b1;
              remaining_q <= remaining_q - 1'b1;
              state_q <= S_STORE_UB_REQUEST;
            end
          end
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end
endmodule
