`timescale 1ns/1ps
// 8 KiB, 2-way set-associative instruction cache, 32-byte lines.
module ares_l1i #(
  parameter int unsigned SIZE_BYTES = 8192,
  parameter int unsigned LINE_BYTES = 32,
  parameter int unsigned WAYS       = 2
) (
  input  logic         clk,
  input  logic         rst,

  // CPU fetch port: one 32-bit word per request.
  input  logic         cpu_req_valid,
  output logic         cpu_req_ready,
  input  logic [31:0]  cpu_req_addr,
  output logic         cpu_rsp_valid,
  output logic [31:0]  cpu_rsp_data,

  // L2 refill port: 16-byte beats.
  output logic         l2_req_valid,
  input  logic         l2_req_ready,
  output logic         l2_req_write,
  output logic [31:0]  l2_req_addr,
  output logic [127:0] l2_req_wdata,
  output logic [15:0]  l2_req_wstrb,
  input  logic         l2_rsp_valid,
  output logic         l2_rsp_ready,
  input  logic [127:0] l2_rsp_rdata,

  input  logic         invalidate,
  output logic         invalidate_done,
  output logic         busy
);
  localparam int unsigned SETS        = SIZE_BYTES / (WAYS * LINE_BYTES);
  localparam int unsigned OFFSET_BITS = $clog2(LINE_BYTES);
  localparam int unsigned INDEX_BITS  = $clog2(SETS);
  localparam int unsigned TAG_BITS    = 32 - OFFSET_BITS - INDEX_BITS;
  localparam int unsigned LINE_BITS   = LINE_BYTES * 8;
  localparam int unsigned BEATS       = LINE_BYTES / 16;

  logic [TAG_BITS-1:0] tag_q   [0:WAYS-1][0:SETS-1];
  logic                valid_q [0:WAYS-1][0:SETS-1];
  (* PAP_RAM_STYLE = "BLOCK" *) logic [LINE_BITS-1:0] data_q [0:WAYS-1][0:SETS-1];
  logic                lru_q   [0:SETS-1]; // 1 = way 0 is LRU

  typedef enum logic [3:0] {
    ST_IDLE,
    ST_LOOKUP,
    ST_RESP,
    ST_MISS0,
    ST_MISS0_WAIT,
    ST_MISS1,
    ST_MISS1_WAIT,
    ST_FILL,
    ST_INV
  } state_t;
  state_t state_q;

  logic [31:0] req_addr_q;
  logic [TAG_BITS-1:0] req_tag_q;
  logic [INDEX_BITS-1:0] req_set_q;
  logic [OFFSET_BITS-1:0] req_off_q;
  logic [31:0] rsp_data_q;
  logic        rsp_valid_q;

  logic [LINE_BITS-1:0] rd_line_q [0:WAYS-1];
  logic [LINE_BITS-1:0] refill_q;
  logic [127:0] refill_lo_q, refill_hi_q;
  logic [1:0] miss_beat_q;

  logic [INDEX_BITS-1:0] inv_idx_q;
  logic inv_active_q;
  logic inv_done_q;
  logic [31:0] line_base_q;

  function automatic logic [31:0] line_base(input logic [31:0] a);
    line_base = {a[31:OFFSET_BITS], {OFFSET_BITS{1'b0}}};
  endfunction

  assign cpu_req_ready = (state_q == ST_IDLE) && !inv_active_q && !inv_done_q;
  assign cpu_rsp_valid = rsp_valid_q;
  assign cpu_rsp_data  = rsp_data_q;
  assign busy = (state_q != ST_IDLE) || inv_active_q;
  assign l2_rsp_ready = (state_q == ST_MISS0_WAIT) || (state_q == ST_MISS1_WAIT);
  assign l2_req_write = 1'b0;
  assign l2_req_wdata = 128'd0;
  assign l2_req_wstrb = 16'd0;

  wire [TAG_BITS-1:0] tag_f = req_addr_q[31:OFFSET_BITS+INDEX_BITS];
  wire [INDEX_BITS-1:0] set_f = req_addr_q[OFFSET_BITS +: INDEX_BITS];
  wire [OFFSET_BITS-1:0] off_f = req_addr_q[OFFSET_BITS-1:0];

  logic hit0, hit1, hit;
  logic [1:0] hit_way;
  always_comb begin
    hit0 = valid_q[0][set_f] && (tag_q[0][set_f] == tag_f);
    hit1 = valid_q[1][set_f] && (tag_q[1][set_f] == tag_f);
    hit  = hit0 || hit1;
    hit_way = hit0 ? 2'd0 : 2'd1;
  end

  logic [LINE_BITS-1:0] hit_line;
  always_comb begin
    hit_line = hit0 ? rd_line_q[0] : rd_line_q[1];
  end

  logic [31:0] word_from_line;
  always_comb begin
    word_from_line = hit_line[req_addr_q[4:2]*32 +: 32];
  end

  // Replacement: prefer an invalid way, otherwise the LRU way.
  logic [1:0] victim_way;
  always_comb begin
    if (!valid_q[0][set_f])      victim_way = 2'd0;
    else if (!valid_q[1][set_f]) victim_way = 2'd1;
    else                          victim_way = lru_q[set_f] ? 2'd0 : 2'd1;
  end

  integer i_stuck_cnt;
  always_ff @(posedge clk) begin
    if (rst) i_stuck_cnt <= 0;
    else if (state_q != ST_IDLE) begin
      i_stuck_cnt <= i_stuck_cnt + 1;
      if (i_stuck_cnt == 2000) begin
        
      end
    end else i_stuck_cnt <= 0;
  end

  // Tag/valid/LRU arrays are initialised once instead of on every reset:
  // ADS rejects a variable driven by both blocking and non-blocking
  // assignments, while Verilator rejects non-blocking assignment to an array
  // inside a for loop, so no reset loop is portable.  A warm reset therefore
  // leaves stale lines marked valid; firmware that rewrites memory must issue
  // fence.i (the loader does), which sweeps every valid bit.
  integer iw, is;
  initial begin
    for (iw = 0; iw < WAYS; iw = iw + 1) begin
      rd_line_q[iw] = '0;
      for (is = 0; is < SETS; is = is + 1) begin
        tag_q[iw][is]   = '0;
        valid_q[iw][is] = 1'b0;
      end
    end
    for (is = 0; is < SETS; is = is + 1) lru_q[is] = 1'b0;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= ST_IDLE;
      rsp_valid_q <= 1'b0;
      rsp_data_q <= 32'd0;
      req_addr_q <= 32'd0;
      refill_lo_q <= 128'd0;
      refill_hi_q <= 128'd0;
      inv_idx_q <= '0;
      inv_active_q <= 1'b0;
      inv_done_q <= 1'b0;
      line_base_q <= 32'd0;
    end else begin
      rsp_valid_q <= 1'b0;

      // Invalidate sweep has priority over normal requests.
      if (inv_active_q) begin
        // WAYS is fixed at 2; unrolled because Verilator rejects a
        // non-blocking assignment to an array inside a for loop.
        valid_q[0][inv_idx_q] <= 1'b0;
        valid_q[1][inv_idx_q] <= 1'b0;
        if (inv_idx_q == '0) begin
          inv_active_q <= 1'b0;
          inv_done_q <= 1'b1;
        end else begin
          inv_idx_q <= inv_idx_q - 1'b1;
        end
      end else if (inv_done_q) begin
        inv_done_q <= 1'b0;
      end

      case (state_q)
        ST_IDLE: begin
          if (cpu_req_valid && cpu_req_ready) begin
            req_addr_q <= cpu_req_addr;
            req_tag_q  <= cpu_req_addr[31:OFFSET_BITS+INDEX_BITS];
            req_set_q  <= cpu_req_addr[OFFSET_BITS +: INDEX_BITS];
            req_off_q  <= cpu_req_addr[OFFSET_BITS-1:0];
            line_base_q <= line_base(cpu_req_addr);
            // Unrolled for the same reason as the invalidate sweep above.
            rd_line_q[0] <= data_q[0][cpu_req_addr[OFFSET_BITS +: INDEX_BITS]];
            rd_line_q[1] <= data_q[1][cpu_req_addr[OFFSET_BITS +: INDEX_BITS]];
            state_q <= ST_LOOKUP;
          end else if (invalidate && !inv_active_q) begin
            inv_idx_q <= INDEX_BITS'(SETS - 1);
            inv_active_q <= 1'b1;
            inv_done_q <= 1'b0;
          end
        end
        ST_LOOKUP: begin
          if (hit) begin
            rsp_data_q  <= word_from_line;
            rsp_valid_q <= 1'b1;
            lru_q[req_set_q] <= (hit_way == 2'd0) ? 1'b0 : 1'b1; // other way is LRU
            state_q <= ST_RESP;
          end else begin
            state_q <= ST_MISS0;
          end
        end
        ST_RESP: state_q <= ST_IDLE;
        ST_MISS0: begin
          if (l2_req_valid && l2_req_ready) state_q <= ST_MISS0_WAIT;
        end
        ST_MISS0_WAIT: begin
          if (l2_rsp_valid) begin
            refill_lo_q <= l2_rsp_rdata;
            state_q <= ST_MISS1;
          end
        end
        ST_MISS1: begin
          if (l2_req_valid && l2_req_ready) state_q <= ST_MISS1_WAIT;
        end
        ST_MISS1_WAIT: begin
          if (l2_rsp_valid) begin
            refill_hi_q <= l2_rsp_rdata;
            state_q <= ST_FILL;
          end
        end
        ST_FILL: begin
          refill_q = {refill_hi_q, refill_lo_q};
          data_q[victim_way][req_set_q] <= refill_q;
          tag_q[victim_way][req_set_q]  <= req_tag_q;
          valid_q[victim_way][req_set_q] <= 1'b1;
          lru_q[req_set_q] <= (victim_way == 2'd0) ? 1'b0 : 1'b1;
          rsp_data_q  <= refill_q[req_addr_q[4:2]*32 +: 32];
          rsp_valid_q <= 1'b1;
          state_q <= ST_RESP;
        end
        default: state_q <= ST_IDLE;
      endcase
    end
  end

  assign l2_req_valid = (state_q == ST_MISS0) || (state_q == ST_MISS1);
  assign l2_req_addr  = (state_q == ST_MISS0) ? line_base_q : (line_base_q + 32'd16);
  assign invalidate_done = inv_done_q;
endmodule