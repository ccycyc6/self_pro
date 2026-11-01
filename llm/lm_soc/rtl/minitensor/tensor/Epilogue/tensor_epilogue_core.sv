`timescale 1ns/1ps

// INT32 bias + fixed-point requantization + optional ReLU for one 4x4 tile.
// Config row format: [15:0] signed multiplier, [20:16] right shift,
// [28:21] signed zero point, [29] ReLU enable.
/* verilator lint_off UNUSEDSIGNAL */
module tensor_epilogue_core (
  input  logic [511:0] c_data,
  input  logic [511:0] bias_data,
  input  logic [127:0] config_data,
  output logic [127:0] output_data
);
  logic signed [15:0] multiplier;
  logic [4:0] shift_amount;
  logic signed [7:0] zero_point;
  logic relu_enable;
  logic signed [47:0] scaled_value;
  logic signed [47:0] shifted_value;
  logic signed [47:0] quantized_value;
  logic signed [47:0] zero_point_value;
  logic signed [32:0] sum_value;
  logic signed [31:0] c_value, bias_value;
  integer i;

  always_comb begin
    multiplier = $signed(config_data[15:0]);
    shift_amount = config_data[20:16];
    zero_point = $signed(config_data[28:21]);
    zero_point_value = {{40{zero_point[7]}}, zero_point};
    relu_enable = config_data[29];
    output_data = '0;
    for (i = 0; i < 16; i = i + 1) begin
      c_value = $signed(c_data[32*i +: 32]);
      bias_value = $signed(bias_data[32*i +: 32]);
      sum_value = $signed(c_value) + $signed(bias_value);
      scaled_value = sum_value * $signed(multiplier);
      shifted_value = scaled_value >>> shift_amount;
      quantized_value = shifted_value + zero_point_value;
      if (relu_enable && (quantized_value < 0))
        quantized_value = 0;
      if (quantized_value > 127)
        output_data[8*i +: 8] = 8'h7f;
      else if (quantized_value < -128)
        output_data[8*i +: 8] = 8'h80;
      else
        output_data[8*i +: 8] = quantized_value[7:0];
    end
  end
endmodule
/* verilator lint_on UNUSEDSIGNAL */
