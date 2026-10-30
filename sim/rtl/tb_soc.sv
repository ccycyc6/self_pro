`timescale 1ns/1ps
module tb_soc;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk; // 100 MHz model

  logic uart_tx, uart_rx = 1'b1;
  logic [31:0] gpio_in = 32'd0, gpio_out, gpio_dir;
  logic mt_irq, dbg_halt, dbg_commit;
  logic [10:0] cam_addr;
  logic [10:0] cam2_addr;
  logic        cam_bank;
  logic [15:0] cam_data = 16'd0;
  logic [31:0] cam_frame = 32'd0;
  logic [31:0] cam_wrcnt = 32'd0;
  logic [23:0] cam_dbg = 24'd0;
  logic [191:0] osd_boxes;
  logic         osd_tog;
  logic [39:0]  osd_text;
  logic [31:0] dbg_pc, dbg_pc_f;
  logic dbg_ifid_valid, dbg_idex_valid, dbg_exmem_valid, dbg_memwb_valid, dbg_if_pending;

  ares_soc #(
    .RESET_PC(32'h0000_0000),
    .DDR_FILE("")
  ) u_soc (
    .clk, .rst,
    .uart_rx, .uart_tx,
    .gpio_in, .gpio_out, .gpio_dir,
    .cam_addr, .cam_bank, .cam_data, .cam_frame, .cam_wrcnt, .cam_dbg,
    .cam2_addr, .cam2_data(16'd0), .cam2_frame(32'd0),
    .osd_boxes, .osd_tog, .osd_text,
    .mt_irq, .dbg_halt, .dbg_pc, .dbg_commit,
    .dbg_pc_f, .dbg_ifid_valid, .dbg_idex_valid, .dbg_exmem_valid,
    .dbg_memwb_valid, .dbg_if_pending
  );

  // UART receiver: 8N1, divisor 8 -> 80 ns per bit at 100 MHz.
  int uart_chars = 0;
  int uart_fd;
  initial uart_fd = $fopen("build/uart.log", "w");
  initial begin
    @(negedge rst); // discard the reset-time line state
    forever begin
      @(negedge uart_tx);
      #120; // 1.5 bit times
      begin
        logic [7:0] ch;
        for (int i = 0; i < 8; i++) begin
          ch[i] = uart_tx;
          #80;
        end
        uart_chars++;
        $write("%c", ch);
        $fwrite(uart_fd, "%c", ch);
        $fflush(uart_fd);
      end
    end
  end

  initial begin
    repeat (20) @(negedge clk);
    rst = 0;
    $display("\n[TB] ARES-S1 SoC reset released");
  end

  initial begin
    #2_000_000_000; // 2 s simulated
    $display("\n[TB] TIMEOUT: pc=%08x pf=%08x ifid=%b idex=%b exmem=%b memwb=%b halt=%b",
             dbg_pc, dbg_pc_f, dbg_ifid_valid, dbg_idex_valid,
             dbg_exmem_valid, dbg_memwb_valid, dbg_halt);
    $fclose(uart_fd);
    $finish;
  end

  always @(posedge clk) begin
    if (dbg_halt) begin
      repeat (10) @(posedge clk);
      $display("\n[TB] core halted, pc=%08x", dbg_pc);
      $fclose(uart_fd);
      $finish;
    end
  end
endmodule
