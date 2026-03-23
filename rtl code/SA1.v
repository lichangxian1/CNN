module SA1(
    input wire clk,
    input wire rst_n,
    input wire signed [56-1:0] data_in,   //7*8bit输入数据
    input wire signed [32*616-1:0] weight,  //32*11*7*8bit权重拼接
    output wire signed [32*32-1:0] data_out //32*32bit输出拼接
);

    genvar i;
    //实例化32个SA1_channel
    generate
        for (i = 0; i < 32; i = i + 1) begin : sa1_channels
            SA1_channel u_SA1_channel (
                .clk(clk),
                .rst_n(rst_n),
                .data_in(data_in),   //输入数据广播到所有通道   
                .weight(weight[i*616 +615: i*616]),   
                .data_out(data_out[i*32 +31: i*32])    
            );
        end
    endgenerate

endmodule
