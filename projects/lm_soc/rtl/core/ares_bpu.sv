`timescale 1ns/1ps
// 256-entry 2-bit BHT + 64-entry direct-mapped BTB.
module ares_bpu (
  input  logic        clk,
  input  logic        rst,
  input  logic [31:0] fetch_pc,
  output logic        pred_taken,
  output logic [31:0] pred_target,

  input  logic        update_en,
  input  logic [31:0] update_pc,
  input  logic        update_taken,
  input  logic [31:0] update_target,
  input  logic        update_is_jal,
  input  logic        update_is_jalr,
  input  logic        update_is_cond
);
  logic [1:0] bht [0:255];
  logic       btb_valid [0:63];
  logic [23:0] btb_tag  [0:63];
  logic [31:0] btb_target [0:63];
  logic       btb_jal [0:63];

  wire [7:0]  bht_idx = fetch_pc[9:2];
  wire [5:0]  btb_idx = fetch_pc[7:2];
  wire [23:0] btb_tag_f = fetch_pc[31:8];

  wire btb_hit = btb_valid[btb_idx] && (btb_tag[btb_idx] == btb_tag_f);
  wire bht_taken = bht[bht_idx][1];

  assign pred_taken  = btb_hit && (btb_jal[btb_idx] || bht_taken);
  assign pred_target = btb_target[btb_idx];

  wire [7:0]  upd_bht_idx = update_pc[9:2];
  wire [5:0]  upd_btb_idx = update_pc[7:2];
  wire [23:0] upd_btb_tag = update_pc[31:8];

  // Saturating 2-bit counter update.
  logic [1:0] bht_new;
  always_comb begin
    if (update_taken) begin
      bht_new = (bht[upd_bht_idx] == 2'b11) ? 2'b11 : bht[upd_bht_idx] + 2'b01;
    end else begin
      bht_new = (bht[upd_bht_idx] == 2'b00) ? 2'b00 : bht[upd_bht_idx] - 2'b01;
    end
  end

  // Tables are initialised once, not on every reset.  Two reasons:
  //  - ADS rejects a variable driven by both blocking and non-blocking
  //    assignments in one always block, and Verilator rejects non-blocking
  //    assignment to an array inside a for loop, so a reset loop cannot be
  //    written portably;
  //  - the tables are only a performance hint (the core always verifies a
  //    prediction), so they do not need to be cleared by a warm reset.
  integer i;
  initial begin
    for (i = 0; i < 256; i = i + 1) bht[i] = 2'b01;
    for (i = 0; i < 64; i = i + 1) begin
      btb_valid[i]  = 1'b0;
      btb_tag[i]    = 24'd0;
      btb_target[i] = 32'd0;
      btb_jal[i]    = 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst && update_en) begin
      if (update_is_cond) begin
        bht[upd_bht_idx] <= bht_new;
      end
      if (update_taken && (update_is_jal || update_is_cond || update_is_jalr)) begin
        btb_valid[upd_btb_idx]  <= 1'b1;
        btb_tag[upd_btb_idx]    <= upd_btb_tag;
        btb_target[upd_btb_idx] <= update_target;
        btb_jal[upd_btb_idx]    <= update_is_jal;
      end
    end
  end
endmodule
