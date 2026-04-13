`timescale 1ns / 1ps
//8位寄存器
module FF_8(
    input   wire    [7:0]     data_in,
    input   wire                clk,
    input   wire                rst_n,
    output  reg     [7:0]     data_out
);
    
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        data_out    <=  8'b0;
    else
        data_out    <=  data_in;
end 
endmodule
