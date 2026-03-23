`timescale 1ns / 1ps
module SA_2(
    input wire                          clk,
    input wire                          rst_n,
    input wire signed [767:0]           data_in,//32*3*8bit输入数据
    input wire signed [2303:0]          weight, //32*9*8bit权重拼接
    output wire signed [1023:0]         data_out//32*32bit输出拼接
);

genvar k;
//实例化32个SA_channel_2
generate
    for(k = 0;k < 32;k = k + 1)begin:array_loop
        SA_channel_2    channel(
            .clk            (clk),
            .rst_n          (rst_n),
            .data_in        ({data_in[8*k+7+512:8*k+512],data_in[8*k+7+256:8*k+256],data_in[8*k+7:8*k]}),
            .data_out       (data_out[32*k + 31:32*k]),
            .weight         (weight[72*k + 71:72*k])
        );
    end
endgenerate

endmodule
