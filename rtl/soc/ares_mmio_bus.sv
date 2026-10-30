`timescale 1ns/1ps
// 32-bit MMIO bus for the simulation SoC: CLINT, UART and GPIO.
// Every peripheral completes in one request/response pair.
module ares_mmio_bus (
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

  output logic        timer_irq,
  output logic        soft_irq,

  output logic        uart_tx,
  input  logic        uart_rx,
  input  logic [31:0] gpio_in,
  output logic [31:0] gpio_out,
  output logic [31:0] gpio_dir,

  // Camera thumbnail window (B7): 0xD000_2000 + i*4 reads pixel i,
  // 0xD000_3000 reads the completed-frame counter.
  output logic [10:0] cam_addr,
  // Second camera thumbnail (same layout, different window)
  output logic [10:0] cam2_addr,
  input  logic [15:0] cam2_data,
  input  logic [31:0] cam2_frame,
  output logic        cam_bank,
  input  logic [15:0] cam_data,
  input  logic [31:0] cam_frame,
  input  logic [31:0] cam_wrcnt,
  input  logic [23:0] cam_dbg,

  // Detector box for the OSD (0xD000_4000 + n*4, write only)
  // Four boxes, 48 bits each: {x1, y1, x0, y0}.  A box is drawn while x1 > x0,
  // so the driver hides one by writing zeros.
  output logic [191:0] osd_boxes,
  output logic         osd_tog,

  // On-screen text: 8 glyph indices, written as 8 words at 0xD000_5000.
  output logic [39:0] osd_text
);
  import ares_pkg::*;

  typedef enum logic [2:0] {M_IDLE, M_RESP, M_CAM, M_CAM2, M_CAM2R} state_t;
  state_t state_q;
  logic [31:0] rsp_data_q;

  wire sel_clint  = (req_addr[31:16] == 16'h0001);
  wire sel_uart   = (req_addr[31:16] == 16'hD000) && (req_addr[15:12] == 4'h0);
  wire sel_gpio   = (req_addr[31:16] == 16'hD000) && (req_addr[15:12] == 4'h1);
  wire sel_cam    = (req_addr[31:16] == 16'hD000) && (req_addr[15:12] == 4'h2);
  wire sel_camctl = (req_addr[31:16] == 16'hD000) && (req_addr[15:12] == 4'h3);
  // 0xD000_6000 : camera 2 thumbnail (read), 0x6008 : its frame counter
  wire sel_cam2   = (req_addr[31:16] == 16'hD000) && (req_addr[15:12] == 4'h6);
  wire sel_osd    = (req_addr[31:16] == 16'hD000) && (req_addr[15:12] == 4'h4);
  wire sel_text   = (req_addr[31:16] == 16'hD000) && (req_addr[15:12] == 4'h5);

  // 0xD000_4000 + box*0x10 + word*4 : box coordinates (word 0..3 = x0,y0,x1,y1)
  // 0xD000_4040                     : commit (flips the OSD toggle)
  wire [1:0] box_idx  = req_addr[5:4];
  wire [1:0] box_word = req_addr[3:2];

  // ------------------------------------------------------------- OSD mailbox
  // 0x4000..0x400C hold the box, 0x4010 commits it (bit 0 = visible) by
  // flipping a toggle that the pixel clock domain synchronises.
  always_ff @(posedge clk) begin
    if (rst) begin
      osd_boxes <= 192'd0;
      osd_tog   <= 1'b0;
    end else if (periph_req && req_write && sel_osd) begin
      if (req_addr[7:6] == 2'b01) begin
        // 0x4040: commit -- flip the toggle the pixel domain synchronises
        osd_tog <= ~osd_tog;
      end else begin
        case ({box_idx, box_word})
          4'd0:  osd_boxes[11:0]   <= req_wdata[11:0];   // box0 x0
          4'd1:  osd_boxes[23:12]  <= req_wdata[11:0];   // box0 y0
          4'd2:  osd_boxes[35:24]  <= req_wdata[11:0];   // box0 x1
          4'd3:  osd_boxes[47:36]  <= req_wdata[11:0];   // box0 y1
          4'd4:  osd_boxes[59:48]  <= req_wdata[11:0];
          4'd5:  osd_boxes[71:60]  <= req_wdata[11:0];
          4'd6:  osd_boxes[83:72]  <= req_wdata[11:0];
          4'd7:  osd_boxes[95:84]  <= req_wdata[11:0];
          4'd8:  osd_boxes[107:96] <= req_wdata[11:0];
          4'd9:  osd_boxes[119:108] <= req_wdata[11:0];
          4'd10: osd_boxes[131:120] <= req_wdata[11:0];
          4'd11: osd_boxes[143:132] <= req_wdata[11:0];
          4'd12: osd_boxes[155:144] <= req_wdata[11:0];
          4'd13: osd_boxes[167:156] <= req_wdata[11:0];
          4'd14: osd_boxes[179:168] <= req_wdata[11:0];
          default: osd_boxes[191:180] <= req_wdata[11:0];
        endcase
      end
    end else if (periph_req && req_write && sel_text) begin
      case (req_addr[4:2])
        3'd0: osd_text[4:0]   <= req_wdata[4:0];
        3'd1: osd_text[9:5]   <= req_wdata[4:0];
        3'd2: osd_text[14:10] <= req_wdata[4:0];
        3'd3: osd_text[19:15] <= req_wdata[4:0];
        3'd4: osd_text[24:20] <= req_wdata[4:0];
        3'd5: osd_text[29:25] <= req_wdata[4:0];
        3'd6: osd_text[34:30] <= req_wdata[4:0];
        default: osd_text[39:35] <= req_wdata[4:0];
      endcase
    end
  end

  // The camera thumbnail lives in a block RAM on the SoC clock, so its read
  // takes one cycle: M_CAM is that extra cycle.
  logic [10:0] cam_addr_q;
  logic [10:0] cam2_addr_q;
  assign cam_addr  = cam_addr_q;
  assign cam2_addr = cam2_addr_q;
  assign cam_bank = ~cam_frame[0];   // the frame that just finished
  wire periph_req = (state_q == M_IDLE) && req_valid;

  assign req_ready = (state_q == M_IDLE);
  assign rsp_valid = (state_q == M_RESP);
  assign rsp_rdata = rsp_data_q;

  logic [31:0] clint_rdata, uart_rdata, gpio_rdata;
  logic [0:0] clint_soft, clint_timer;

  ares_clint #(.HART_COUNT(1)) u_clint (
    .clk, .rst,
    .req_valid(periph_req && sel_clint), .req_ready(),
    .req_write(req_write), .req_addr(req_addr - CLINT_BASE),
    .req_wdata(req_wdata), .req_wstrb(req_wstrb),
    .rsp_valid(), .rsp_ready(1'b1), .rsp_rdata(clint_rdata),
    .soft_irq(clint_soft), .timer_irq(clint_timer)
  );

  ares_uart u_uart (
    .clk, .rst,
    .req_valid(periph_req && sel_uart), .req_ready(),
    .req_write(req_write), .req_addr(req_addr - MMIO_BASE),
    .req_wdata(req_wdata), .req_wstrb(req_wstrb),
    .rsp_valid(), .rsp_ready(1'b1), .rsp_rdata(uart_rdata),
    .uart_tx, .uart_rx, .uart_irq()
  );

  ares_gpio u_gpio (
    .clk, .rst,
    .req_valid(periph_req && sel_gpio), .req_ready(),
    .req_write(req_write), .req_addr(req_addr - 32'hD000_1000),
    .req_wdata(req_wdata), .req_wstrb(req_wstrb),
    .rsp_valid(), .rsp_ready(1'b1), .rsp_rdata(gpio_rdata),
    .gpio_in, .gpio_out, .gpio_dir, .gpio_irq()
  );

  assign timer_irq = clint_timer[0];
  assign soft_irq  = clint_soft[0];

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= M_IDLE;
      rsp_data_q <= 32'd0;
    end else begin
      case (state_q)
        M_IDLE: begin
          if (req_valid && req_ready) begin
            if (sel_cam && !req_write) begin
              cam_addr_q <= req_addr[11:2];
              state_q <= M_CAM;
            end else if (sel_cam2 && !req_write && (req_addr[3:2] == 2'd0)) begin
              cam2_addr_q <= req_addr[11:2];
              state_q <= M_CAM2R;
            end else begin
              if (sel_clint) rsp_data_q <= clint_rdata;
              else if (sel_uart) rsp_data_q <= uart_rdata;
              else if (sel_gpio) rsp_data_q <= gpio_rdata;
              else if (sel_cam2) begin
                rsp_data_q <= (req_addr[3:2] == 2'd2) ? cam2_frame : 32'd0;
              end
              else if (sel_camctl) begin
                case (req_addr[3:2])
                  2'd0: rsp_data_q <= cam_frame;
                  2'd1: rsp_data_q <= cam_wrcnt;
                  2'd2: rsp_data_q <= {8'd0, cam_dbg};
                  default: rsp_data_q <= 32'd0;
                endcase
              end
              else rsp_data_q <= 32'd0;
              state_q <= M_RESP;
            end
          end
        end
        M_CAM: begin
          // The thumbnail RAM is read with one cycle of latency; the address
          // register was written on the transition into this state, so wait
          // one more cycle before latching the data.
          state_q <= M_CAM2;
        end
        M_CAM2: begin
          rsp_data_q <= {16'd0, cam_data};
          state_q <= M_RESP;
        end
        M_CAM2R: begin
          rsp_data_q <= {16'd0, cam2_data};
          state_q <= M_RESP;
        end
        M_RESP: if (rsp_ready) state_q <= M_IDLE;
        default: state_q <= M_IDLE;
      endcase
    end
  end
endmodule
