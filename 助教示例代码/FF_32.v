`timescale 1ns / 1ps
//32位寄存器
module FF_32(
    input   wire    [31:0]      data_in,
    input   wire                clk,
    input   wire                rst_n,
    output  reg     [31:0]      data_out
);
    
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)
        data_out    <=  32'b0;
    else
        data_out    <=  data_in;
end 
endmodule
