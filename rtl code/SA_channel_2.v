`timescale 1ns / 1ps
module SA_channel_2(
    input   wire                    clk,
    input   wire                    rst_n,
    input   wire  signed  [23:0]    data_in,//3*8bit输入数据
    input   wire  signed  [71:0]    weight,//9*8bit权重
    output  wire signed   [31:0]    data_out
);
   
genvar i,j;
wire signed [71:0]          data_temp;//用于P之间传递的脉动数据，宽度与weight相同
wire signed [287:0]         partial_product_temp;//所有PE的乘积结果，32*9
wire signed [32*4 - 1:0]    partial_sum_temp;
//生成3行3列的PE阵列
generate
for(i = 0;i < 3;i = i + 1)begin:row_loop
    for(j = 0;j < 3;j = j + 1)begin:col_loop
        if(i == 2)begin//最后一行 PE输入数据直接来自data_in
            PE  array_pe(
                .clk            (clk),
                .rst_n          (rst_n),
                .weight         (weight[(i*3+j)*8 + 7:(i*3+j)*8]),
                .data_in        (data_in[j*8 + 7:j*8]),
                .data_out       (data_temp[(i*3+j)*8+7:(i*3+j)*8]),
                .temp_product   (partial_product_temp[(i*3+j)*32+31:(i*3+j)*32])  
            );
        end
        else begin
            PE  array_pe(
                .clk            (clk),
                .rst_n          (rst_n),
                .weight         (weight[(i*3+j)*8 + 7:(i*3+j)*8]),
                .data_in        (data_temp[(i*3+j+3)*8+7:(i*3+j+3)*8]),
                .data_out       (data_temp[(i*3+j)*8+7:(i*3+j)*8]),
                .temp_product   (partial_product_temp[(i*3+j)*32+31:(i*3+j)*32])  
            );
        end
    end
end
endgenerate
//加法树第一级寄存9个PE的乘积结果
wire signed  [31:0]  adderTreeReg1    [8:0];
FF_32    treeBuffer0_0(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp[(0*3+0)*32+31:(0*3+0)*32]),.data_out(adderTreeReg1[0]));
FF_32    treeBuffer0_1(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp[(1*3+0)*32+31:(1*3+0)*32]),.data_out(adderTreeReg1[1]));
FF_32    treeBuffer0_2(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp[(2*3+0)*32+31:(2*3+0)*32]),.data_out(adderTreeReg1[2]));
FF_32    treeBuffer0_3(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp[(0*3+1)*32+31:(0*3+1)*32]),.data_out(adderTreeReg1[3]));
FF_32    treeBuffer0_4(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp[(1*3+1)*32+31:(1*3+1)*32]),.data_out(adderTreeReg1[4]));
FF_32    treeBuffer0_5(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp[(2*3+1)*32+31:(2*3+1)*32]),.data_out(adderTreeReg1[5]));
FF_32    treeBuffer0_6(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp[(0*3+2)*32+31:(0*3+2)*32]),.data_out(adderTreeReg1[6]));
FF_32    treeBuffer0_7(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp[(1*3+2)*32+31:(1*3+2)*32]),.data_out(adderTreeReg1[7]));
FF_32    treeBuffer0_8(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp[(2*3+2)*32+31:(2*3+2)*32]),.data_out(adderTreeReg1[8]));
//将部分乘积两两相加，得到4个部分和
assign partial_sum_temp[0*32+31:32*0] = $signed(adderTreeReg1[0]) + $signed(adderTreeReg1[1]);
assign partial_sum_temp[1*32+31:32*1] = $signed(adderTreeReg1[2]) + $signed(adderTreeReg1[3]);
assign partial_sum_temp[2*32+31:32*2] = $signed(adderTreeReg1[4]) + $signed(adderTreeReg1[5]);
assign partial_sum_temp[3*32+31:32*3] = $signed(adderTreeReg1[6]) + $signed(adderTreeReg1[7]);
//寄存第二级结果和最后一个乘积
wire signed  [31:0]  adderTreeReg2    [4:0];
FF_32    treeBuffer1_0(.clk(clk),.rst_n(rst_n),.data_in(partial_sum_temp[0*32+31:32*0]),.data_out(adderTreeReg2[0]));
FF_32    treeBuffer1_1(.clk(clk),.rst_n(rst_n),.data_in(partial_sum_temp[1*32+31:32*1]),.data_out(adderTreeReg2[1]));
FF_32    treeBuffer1_2(.clk(clk),.rst_n(rst_n),.data_in(partial_sum_temp[2*32+31:32*2]),.data_out(adderTreeReg2[2]));
FF_32    treeBuffer1_3(.clk(clk),.rst_n(rst_n),.data_in(partial_sum_temp[3*32+31:32*3]),.data_out(adderTreeReg2[3]));
FF_32    treeBuffer1_4(.clk(clk),.rst_n(rst_n),.data_in(adderTreeReg1[8]),.data_out(adderTreeReg2[4]));
//第三级将第二级的5个结果组合相加
wire signed  [31:0]  adderTreeReg3    [2:0]; 
assign adderTreeReg3[0] = $signed(adderTreeReg2[0]) + $signed(adderTreeReg2[1]);
assign adderTreeReg3[1] = $signed(adderTreeReg2[2]) + $signed(adderTreeReg2[3]);
assign adderTreeReg3[2] = $signed(adderTreeReg2[4]);
//寄存第三级的3个结果
wire signed  [31:0]  adderTreeReg4    [2:0]; 
FF_32    treeBuffer2_0(.clk(clk),.rst_n(rst_n),.data_in(adderTreeReg3[0]),.data_out(adderTreeReg4[0]));
FF_32    treeBuffer2_1(.clk(clk),.rst_n(rst_n),.data_in(adderTreeReg3[1]),.data_out(adderTreeReg4[1]));
FF_32    treeBuffer2_2(.clk(clk),.rst_n(rst_n),.data_in(adderTreeReg3[2]),.data_out(adderTreeReg4[2]));
//第四级
wire signed  [31:0]  adderTreeReg5    [1:0]; 
assign adderTreeReg5[0] = $signed(adderTreeReg4[0]) + $signed(adderTreeReg4[1]);
assign adderTreeReg5[1] = $signed(adderTreeReg4[2]);
//寄存第四级的结果
wire signed  [31:0]  adderTreeReg6    [2:0]; 
FF_32    treeBuffer3_0(.clk(clk),.rst_n(rst_n),.data_in(adderTreeReg5[0]),.data_out(adderTreeReg6[0]));
FF_32    treeBuffer3_1(.clk(clk),.rst_n(rst_n),.data_in(adderTreeReg5[1]),.data_out(adderTreeReg6[1]));
//第五级最后两个部分和相加，得到最终输出
assign  data_out = $signed(adderTreeReg6[0]) + $signed(adderTreeReg6[1]);
endmodule
