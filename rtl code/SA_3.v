`timescale 1ns / 1ps
module SA_3(
    input wire                          clk,
    input wire                          rst_n,
    input wire signed [255:0]           data_in,//32通道*8bit输入数据
    input wire signed [8191:0]          weight, //32个*32通道*8bit权重拼接
    output wire signed [1023:0]          data_out//32*32bit输出拼接
);

genvar k;
//实例化32个SA_channel_3
generate
for(k = 0;k < 32;k =  k+ 1)begin: array_loop
    SA_channel_3    channel(
        .clk            (clk),
        .rst_n          (rst_n),
        .data_in        (data_in),
        .data_out       (data_out[32*k + 31:32*k]),
        .weight         (weight[256*k + 255:256*k])
    );
end    
endgenerate   
    
endmodule
