`timescale 1ns / 1ps
module SA_channel_3(
    input   wire                            clk,
    input   wire                            rst_n,
    input   wire  signed  [255:0]           data_in,//32*8bit
    input   wire  signed  [255:0]           weight,//32*8bit
    output  wire signed   [31:0]            data_out
);
    
wire    signed  [18*32-1:0] temp_sum_l1;   
wire    signed  [8*32-1:0]  temp_sum_l2; 
wire    signed  [4*32-1:0]  temp_sum_l3; 
wire    signed  [2*32-1:0]  temp_sum_l4;  
//测试线
wire    signed  [7:0]   weight0;
wire    signed  [7:0]   weight1;
wire    signed  [7:0]   data0;
wire    signed  [7:0]   data1;
wire    signed  [31:0]  pp0;
wire    signed  [31:0]  pp1;
assign  weight0     =   weight[7:0];  
assign  weight1     =   weight[15:8];
assign  data0       =   data_in[7:0];  
assign  data1       =   data_in[15:8];  
assign  pp0         =   $signed(data0)*$signed(weight0);  
assign  pp1         =   $signed(data1)*$signed(weight1);    
//第一级：32个乘法，每两个乘积相加，得到16个部分和
assign    temp_sum_l1[0*32+31:0*32]   =   $signed(data_in[0*8+7:0*8])*$signed(weight[0*8+7:0*8]) +  $signed(data_in[1*8+7:1*8])*$signed(weight[1*8+7:1*8]);
assign    temp_sum_l1[1*32+31:1*32]   =   $signed(data_in[2*8+7:2*8])*$signed(weight[2*8+7:2*8]) +  $signed(data_in[3*8+7:3*8])*$signed(weight[3*8+7:3*8]);
assign    temp_sum_l1[2*32+31:2*32]   =   $signed(data_in[4*8+7:4*8])*$signed(weight[4*8+7:4*8]) +  $signed(data_in[5*8+7:5*8])*$signed(weight[5*8+7:5*8]);
assign    temp_sum_l1[3*32+31:3*32]   =   $signed(data_in[6*8+7:6*8])*$signed(weight[6*8+7:6*8]) +  $signed(data_in[7*8+7:7*8])*$signed(weight[7*8+7:7*8]);
assign    temp_sum_l1[4*32+31:4*32]   =   $signed(data_in[8*8+7:8*8])*$signed(weight[8*8+7:8*8]) +  $signed(data_in[9*8+7:9*8])*$signed(weight[9*8+7:9*8]);
assign    temp_sum_l1[5*32+31:5*32]   =   $signed(data_in[10*8+7:10*8])*$signed(weight[10*8+7:10*8]) +  $signed(data_in[11*8+7:11*8])*$signed(weight[11*8+7:11*8]);
assign    temp_sum_l1[6*32+31:6*32]   =   $signed(data_in[12*8+7:12*8])*$signed(weight[12*8+7:12*8]) +  $signed(data_in[13*8+7:13*8])*$signed(weight[13*8+7:13*8]);
assign    temp_sum_l1[7*32+31:7*32]   =   $signed(data_in[14*8+7:14*8])*$signed(weight[14*8+7:14*8]) +  $signed(data_in[15*8+7:15*8])*$signed(weight[15*8+7:15*8]);
assign    temp_sum_l1[8*32+31:8*32]   =   $signed(data_in[16*8+7:16*8])*$signed(weight[16*8+7:16*8]) +  $signed(data_in[17*8+7:17*8])*$signed(weight[17*8+7:17*8]);
assign    temp_sum_l1[9*32+31:9*32]   =   $signed(data_in[18*8+7:18*8])*$signed(weight[18*8+7:18*8]) +  $signed(data_in[19*8+7:19*8])*$signed(weight[19*8+7:19*8]);
assign    temp_sum_l1[10*32+31:10*32]   =   $signed(data_in[20*8+7:20*8])*$signed(weight[20*8+7:20*8]) +  $signed(data_in[21*8+7:21*8])*$signed(weight[21*8+7:21*8]);
assign    temp_sum_l1[11*32+31:11*32]   =   $signed(data_in[22*8+7:22*8])*$signed(weight[22*8+7:22*8]) +  $signed(data_in[23*8+7:23*8])*$signed(weight[23*8+7:23*8]);
assign    temp_sum_l1[12*32+31:12*32]   =   $signed(data_in[24*8+7:24*8])*$signed(weight[24*8+7:24*8]) +  $signed(data_in[25*8+7:25*8])*$signed(weight[25*8+7:25*8]);
assign    temp_sum_l1[13*32+31:13*32]   =   $signed(data_in[26*8+7:26*8])*$signed(weight[26*8+7:26*8]) +  $signed(data_in[27*8+7:27*8])*$signed(weight[27*8+7:27*8]);
assign    temp_sum_l1[14*32+31:14*32]   =   $signed(data_in[28*8+7:28*8])*$signed(weight[28*8+7:28*8]) +  $signed(data_in[29*8+7:29*8])*$signed(weight[29*8+7:29*8]);
assign    temp_sum_l1[15*32+31:15*32]   =   $signed(data_in[30*8+7:30*8])*$signed(weight[30*8+7:30*8]) +  $signed(data_in[31*8+7:31*8])*$signed(weight[31*8+7:31*8]);
//寄存部分和
wire signed  [31:0]  adderTreeReg1    [17:0];
FF_32    treeBuffer0_0(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l1[0*32+31:0*32]),.data_out(adderTreeReg1[0]));
FF_32    treeBuffer0_1(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l1[1*32+31:1*32]),.data_out(adderTreeReg1[1]));
FF_32    treeBuffer0_2(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l1[2*32+31:2*32]),.data_out(adderTreeReg1[2]));
FF_32    treeBuffer0_3(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l1[3*32+31:3*32]),.data_out(adderTreeReg1[3]));
FF_32    treeBuffer0_4(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l1[4*32+31:4*32]),.data_out(adderTreeReg1[4]));
FF_32    treeBuffer0_5(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l1[5*32+31:5*32]),.data_out(adderTreeReg1[5]));
FF_32    treeBuffer0_6(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l1[6*32+31:6*32]),.data_out(adderTreeReg1[6]));
FF_32    treeBuffer0_7(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l1[7*32+31:7*32]),.data_out(adderTreeReg1[7]));
FF_32    treeBuffer0_8(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l1[8*32+31:8*32]),.data_out(adderTreeReg1[8]));
FF_32    treeBuffer0_9(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l1[9*32+31:9*32]),.data_out(adderTreeReg1[9]));
FF_32    treeBuffer0_10(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l1[10*32+31:10*32]),.data_out(adderTreeReg1[10]));
FF_32    treeBuffer0_11(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l1[11*32+31:11*32]),.data_out(adderTreeReg1[11]));
FF_32    treeBuffer0_12(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l1[12*32+31:12*32]),.data_out(adderTreeReg1[12]));
FF_32    treeBuffer0_13(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l1[13*32+31:13*32]),.data_out(adderTreeReg1[13]));
FF_32    treeBuffer0_14(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l1[14*32+31:14*32]),.data_out(adderTreeReg1[14]));
FF_32    treeBuffer0_15(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l1[15*32+31:15*32]),.data_out(adderTreeReg1[15]));
FF_32    treeBuffer0_16(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l1[16*32+31:16*32]),.data_out(adderTreeReg1[16]));
FF_32    treeBuffer0_17(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l1[17*32+31:17*32]),.data_out(adderTreeReg1[17]));
//第二级：将16个部分和两两相加，得到8个部分和
assign    temp_sum_l2[0*32+31:0*32]   =   $signed(adderTreeReg1[0]) +  $signed(adderTreeReg1[1]);
assign    temp_sum_l2[1*32+31:1*32]   =   $signed(adderTreeReg1[2]) +  $signed(adderTreeReg1[3]);
assign    temp_sum_l2[2*32+31:2*32]   =   $signed(adderTreeReg1[4]) +  $signed(adderTreeReg1[5]);
assign    temp_sum_l2[3*32+31:3*32]   =   $signed(adderTreeReg1[6]) +  $signed(adderTreeReg1[7]);
assign    temp_sum_l2[4*32+31:4*32]   =   $signed(adderTreeReg1[8]) +  $signed(adderTreeReg1[9]);
assign    temp_sum_l2[5*32+31:5*32]   =   $signed(adderTreeReg1[10]) +  $signed(adderTreeReg1[11]);
assign    temp_sum_l2[6*32+31:6*32]   =   $signed(adderTreeReg1[12]) +  $signed(adderTreeReg1[13]);
assign    temp_sum_l2[7*32+31:7*32]   =   $signed(adderTreeReg1[14]) +  $signed(adderTreeReg1[15]);

wire signed  [31:0]  adderTreeReg2    [7:0];
FF_32    treeBuffer1_0(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l2[0*32+31:0*32]),.data_out(adderTreeReg2[0]));
FF_32    treeBuffer1_1(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l2[1*32+31:1*32]),.data_out(adderTreeReg2[1]));
FF_32    treeBuffer1_2(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l2[2*32+31:2*32]),.data_out(adderTreeReg2[2]));
FF_32    treeBuffer1_3(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l2[3*32+31:3*32]),.data_out(adderTreeReg2[3]));
FF_32    treeBuffer1_4(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l2[4*32+31:4*32]),.data_out(adderTreeReg2[4]));
FF_32    treeBuffer1_5(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l2[5*32+31:5*32]),.data_out(adderTreeReg2[5]));
FF_32    treeBuffer1_6(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l2[6*32+31:6*32]),.data_out(adderTreeReg2[6]));
FF_32    treeBuffer1_7(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l2[7*32+31:7*32]),.data_out(adderTreeReg2[7]));
//第三级：将8个部分和两两相加，得到4个部分和
assign    temp_sum_l3[0*32+31:0*32]   =   $signed(adderTreeReg2[0]) +  $signed(adderTreeReg2[1]);
assign    temp_sum_l3[1*32+31:1*32]   =   $signed(adderTreeReg2[2]) +  $signed(adderTreeReg2[3]);
assign    temp_sum_l3[2*32+31:2*32]   =   $signed(adderTreeReg2[4]) +  $signed(adderTreeReg2[5]);
assign    temp_sum_l3[3*32+31:3*32]   =   $signed(adderTreeReg2[6]) +  $signed(adderTreeReg2[7]);

wire signed  [31:0]  adderTreeReg3    [3:0];
FF_32    treeBuffer2_0(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l3[0*32+31:0*32]),.data_out(adderTreeReg3[0]));
FF_32    treeBuffer2_1(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l3[1*32+31:1*32]),.data_out(adderTreeReg3[1]));
FF_32    treeBuffer2_2(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l3[2*32+31:2*32]),.data_out(adderTreeReg3[2]));
FF_32    treeBuffer2_3(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l3[3*32+31:3*32]),.data_out(adderTreeReg3[3]));
//第四级：将4个部分和两两相加，得到2个部分和
assign    temp_sum_l4[0*32+31:0*32]   =   $signed(adderTreeReg3[0]) +  $signed(adderTreeReg3[1]);
assign    temp_sum_l4[1*32+31:1*32]   =   $signed(adderTreeReg3[2]) +  $signed(adderTreeReg3[3]);
wire signed  [31:0]  adderTreeReg4    [1:0];
FF_32    treeBuffer3_0(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l4[0*32+31:0*32]),.data_out(adderTreeReg4[0]));
FF_32    treeBuffer3_1(.clk(clk),.rst_n(rst_n),.data_in(temp_sum_l4[1*32+31:1*32]),.data_out(adderTreeReg4[1]));
//第五级：将最后两个部分和相加，得到最终输出
assign data_out = $signed(adderTreeReg4[0]) + $signed(adderTreeReg4[1]);
endmodule
