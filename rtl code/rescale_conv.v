module rescale_conv (
    input wire                  clk,
    input wire                  rst_n,
    input  wire signed [31:0]   data_in,   //32位累加结果
    output reg  signed [7:0]    data_out   //8位量化输出
);
    reg signed [47:0] shifted;
    reg signed [7:0] result;
    reg signed  [47:0]  temp1,temp2;
    wire signed [47:0]  temp3;
    wire signed [47:0] scaled1,scaled2;
    //乘法转换为移位加
    assign scaled1 = (data_in<<6)+(data_in<<5)+(data_in<<3);
    assign scaled2 = (data_in<<2)+(data_in<<1)+data_in;
    //第一级流水线寄存部分积
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            temp1 <= 47'b0;
        else
            temp1 <= scaled1;
    end
    always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        temp2 <= 47'b0;
    else
        temp2 <= scaled2;
    end
    //将两个部分积相加，得到完整的乘积
    assign temp3 = temp1 + temp2;
    //右移14位并进行饱和处理
    always @(*) begin
        shifted = temp3 >>> 6'd14; 
        if (shifted > 127)
            result = 127;
        else if (shifted < -128)
            result = -128;
        else
            result = shifted[7:0];//直接截取低8位
        data_out = result;
    end
endmodule
