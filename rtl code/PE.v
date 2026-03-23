`timescale 1ns / 1ps

module PE(
input wire                          clk,
input wire                          rst_n,
input wire signed [7:0]             data_in,//输入数据（来自上游）
output wire signed [7:0]            data_out,//输出数据（传向下游）
input wire signed [7:0]             weight,
output wire signed [31:0]           temp_product
);
 
reg  signed [7:0]               data_in_buffer;//寄存输入数据

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        data_in_buffer <= 8'b00000000;
    else
        data_in_buffer <= data_in;
end 
 
assign temp_product = $signed(data_in_buffer) * $signed(weight);
assign data_out = data_in_buffer;//寄存后的数据传递给下一个PE

endmodule
