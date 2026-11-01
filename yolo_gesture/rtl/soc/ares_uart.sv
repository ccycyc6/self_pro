`timescale 1ns/1ps
// Simple 8N1 UART with a 32-bit register interface.
module ares_uart (
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

  output logic        uart_tx,
  input  logic        uart_rx,
  output logic        uart_irq
);
  logic [31:0] ctrl_q;
  logic [15:0] baud_q;

  // TX
  logic        tx_busy_q;
  logic [9:0]  tx_shift_q;   // start + 8 data + stop
  logic [3:0]  tx_bit_q;
  logic [15:0] tx_div_q;
  logic        tx_done_q;

  // RX
  logic        rx_sync0_q, rx_sync1_q, rx_prev_q;
  logic        rx_busy_q;
  logic        rx_first_q;   // next sample is the first data bit (1.5 bit times)
  logic [3:0]  rx_bit_q;
  logic [15:0] rx_div_q;
  logic [7:0]  rx_shift_q;
  logic [7:0]  rx_data_q;
  logic        rx_valid_q;

  // RX sample period: 1.5 bit times for the first sample (middle of d0),
  // then one bit time per sample.
  wire [15:0] rx_baud   = (baud_q == 16'd0) ? 16'd1 : baud_q;
  wire [15:0] rx_period = rx_first_q ? (rx_baud + (rx_baud >> 1)) : rx_baud;

  assign uart_tx = tx_busy_q ? tx_shift_q[0] : 1'b1;
  assign uart_irq = (rx_valid_q && ctrl_q[1]) || (tx_done_q && ctrl_q[2]);
  assign req_ready = 1'b1;
  assign rsp_valid = req_valid;

  always_comb begin
    rsp_rdata = 32'd0;
    case (req_addr[7:0])
      8'h00: rsp_rdata = {24'd0, rx_data_q};
      8'h04: rsp_rdata = {29'd0, tx_busy_q, rx_valid_q, ~tx_busy_q};
      8'h08: rsp_rdata = ctrl_q;
      8'h0C: rsp_rdata = {16'd0, baud_q};
      8'h10: rsp_rdata = {24'd0, rx_data_q};
      8'h14: rsp_rdata = 32'h5541_5254; // 'UART'
      default: rsp_rdata = 32'd0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      ctrl_q <= 32'h0000_0003; // enable, rx irq
      baud_q <= 16'd868;
      tx_busy_q <= 1'b0;
      tx_shift_q <= 10'h3FF;
      tx_bit_q <= 4'd0;
      tx_div_q <= 16'd0;
      tx_done_q <= 1'b0;
      rx_sync0_q <= 1'b1;
      rx_sync1_q <= 1'b1;
      rx_prev_q <= 1'b1;
      rx_busy_q <= 1'b0;
      rx_first_q <= 1'b1;
      rx_bit_q <= 4'd0;
      rx_div_q <= 16'd0;
      rx_shift_q <= 8'd0;
      rx_data_q <= 8'd0;
      rx_valid_q <= 1'b0;
    end else begin
      tx_done_q <= 1'b0;

      // ------------------------------------------------------------- TX
      if (tx_busy_q) begin
        if (tx_div_q >= (baud_q == 16'd0 ? 16'd1 : baud_q) - 16'd1) begin
          tx_div_q <= 16'd0;
          if (tx_bit_q == 4'd9) begin
            tx_busy_q <= 1'b0;
            tx_done_q <= 1'b1;
          end else begin
            tx_bit_q <= tx_bit_q + 4'd1;
            tx_shift_q <= {1'b1, tx_shift_q[9:1]};
          end
        end else begin
          tx_div_q <= tx_div_q + 16'd1;
        end
      end

      // ------------------------------------------------------------- RX
      rx_sync0_q <= uart_rx;
      rx_sync1_q <= rx_sync0_q;
      rx_prev_q <= rx_sync1_q;
      // Sample in the middle of every bit: the first sample lands 1.5 bit
      // times after the start edge (middle of d0), then one per bit, and the
      // ninth sample is the stop bit.  The previous version sampled at 0.5
      // bit and stored the start bit as d0, so every received byte was
      // shifted by one position -- nothing used RX until the B4 loader.
      if (!rx_busy_q && rx_prev_q && !rx_sync1_q) begin
        rx_busy_q  <= 1'b1;
        rx_first_q <= 1'b1;
        rx_bit_q   <= 4'd0;
        rx_div_q   <= 16'd0;
        rx_shift_q <= 8'd0;
      end else if (rx_busy_q) begin
        if (rx_div_q >= rx_period - 16'd1) begin
          rx_div_q   <= 16'd0;
          rx_first_q <= 1'b0;
          if (rx_bit_q < 4'd8) begin
            rx_shift_q[rx_bit_q[2:0]] <= rx_sync1_q;
            rx_bit_q <= rx_bit_q + 4'd1;
          end else begin
            rx_busy_q <= 1'b0;
            rx_data_q <= rx_shift_q;
            rx_valid_q <= 1'b1;
          end
        end else begin
          rx_div_q <= rx_div_q + 16'd1;
        end
      end

      // -------------------------------------------------------- register writes
      if (req_valid && req_ready && req_write) begin
        case (req_addr[7:0])
          8'h00: if (!tx_busy_q) begin
            tx_shift_q <= {1'b1, req_wdata[7:0], 1'b0};
            tx_busy_q <= 1'b1;
            tx_bit_q <= 4'd0;
            tx_div_q <= 16'd0;
          end
          8'h08: ctrl_q <= req_wdata;
          8'h0C: baud_q <= req_wdata[15:0];
          8'h14: ; // scratch
          default: ;
        endcase
      end
      // Reading RX data clears the ready flag.
      if (req_valid && req_ready && !req_write &&
          ((req_addr[7:0] == 8'h00) || (req_addr[7:0] == 8'h10))) begin
        rx_valid_q <= 1'b0;
      end
    end
  end
endmodule