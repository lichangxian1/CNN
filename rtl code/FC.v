`timescale 1ns / 1ps
module FC(
    input wire                          clk,
    input wire                          rst_n,
    input wire                          enable,
    input wire signed [255:0]           data_in, //32*8bit
    input wire signed [4607:0]          weight,  //32*144bit
    input wire signed [63:0]            data_out //2*32bit两个通道的结果
);

genvar k;
wire signed [31:0] output_temp_0 [31:0];//通道0的部分和
wire signed [31:0] output_temp_1 [31:0];//通道1的部分和

generate
    for(k = 0;k < 32;k = k + 1)begin:pe_loop
        if(k == 0)begin
            FC_PE       pe(
                .clk        (clk),
                .rst_n      (rst_n),
                .enable     (enable),
                .data_in    (data_in[8*k+7:8*k]),
                .weight     (weight[144*k+143:144*k]),
                .temp_out_0 (output_temp_0[k]),
                .temp_out_1 (output_temp_1[k])
            );
        end
        else begin
            FC_PE       pe(
                .clk        (clk),
                .rst_n      (rst_n),
                .enable     (enable),
                .data_in    (data_in[8*k+7:8*k]),
                .weight     (weight[144*k+143:144*k]),
                .temp_out_0 (output_temp_0[k]),
                .temp_out_1 (output_temp_1[k])
            );
        end
    end
endgenerate
//加法树：将32个PE的通道0部分和累加成32位结果
wire signed [31:0] add_0_0 [15:0];
wire signed [31:0] add_1_0 [15:0];
wire signed [31:0] add_0_1 [7:0];
wire signed [31:0] add_1_1 [7:0];
wire signed [31:0] add_0_2 [3:0];
wire signed [31:0] add_1_2 [3:0];
wire signed [31:0] add_0_3 [1:0];
wire signed [31:0] add_1_3 [1:0];

wire signed [31:0] addR_0_0 [15:0];
wire signed [31:0] addR_1_0 [15:0];
wire signed [31:0] addR_0_1 [7:0];
wire signed [31:0] addR_1_1 [7:0];
wire signed [31:0] addR_0_2 [3:0];
wire signed [31:0] addR_1_2 [3:0];
wire signed [31:0] addR_0_3 [1:0];
wire signed [31:0] addR_1_3 [1:0];
//第一级：32个输入两两相加，得到16个部分和
assign  add_0_0[0]  =   $signed(output_temp_0[0]) + $signed(output_temp_0[1]);
assign  add_0_0[1]  =   $signed(output_temp_0[2]) + $signed(output_temp_0[3]);
assign  add_0_0[2]  =   $signed(output_temp_0[4]) + $signed(output_temp_0[5]);
assign  add_0_0[3]  =   $signed(output_temp_0[6]) + $signed(output_temp_0[7]);
assign  add_0_0[4]  =   $signed(output_temp_0[8]) + $signed(output_temp_0[9]);
assign  add_0_0[5]  =   $signed(output_temp_0[10]) + $signed(output_temp_0[11]);
assign  add_0_0[6]  =   $signed(output_temp_0[12]) + $signed(output_temp_0[13]);
assign  add_0_0[7]  =   $signed(output_temp_0[14]) + $signed(output_temp_0[15]);
assign  add_0_0[8]  =   $signed(output_temp_0[16]) + $signed(output_temp_0[17]);
assign  add_0_0[9]  =   $signed(output_temp_0[18]) + $signed(output_temp_0[19]);
assign  add_0_0[10]  =   $signed(output_temp_0[20]) + $signed(output_temp_0[21]);
assign  add_0_0[11]  =   $signed(output_temp_0[22]) + $signed(output_temp_0[23]);
assign  add_0_0[12]  =   $signed(output_temp_0[24]) + $signed(output_temp_0[25]);
assign  add_0_0[13]  =   $signed(output_temp_0[26]) + $signed(output_temp_0[27]);
assign  add_0_0[14]  =   $signed(output_temp_0[28]) + $signed(output_temp_0[29]);
assign  add_0_0[15]  =   $signed(output_temp_0[30]) + $signed(output_temp_0[31]);
FF_32    treeBuffer_0_01(.clk(clk),.rst_n(rst_n),.data_in(add_0_0[0]),.data_out(addR_0_0[0]));
FF_32    treeBuffer_0_02(.clk(clk),.rst_n(rst_n),.data_in(add_0_0[1]),.data_out(addR_0_0[1]));
FF_32    treeBuffer_0_03(.clk(clk),.rst_n(rst_n),.data_in(add_0_0[2]),.data_out(addR_0_0[2]));
FF_32    treeBuffer_0_04(.clk(clk),.rst_n(rst_n),.data_in(add_0_0[3]),.data_out(addR_0_0[3]));
FF_32    treeBuffer_0_05(.clk(clk),.rst_n(rst_n),.data_in(add_0_0[4]),.data_out(addR_0_0[4]));
FF_32    treeBuffer_0_06(.clk(clk),.rst_n(rst_n),.data_in(add_0_0[5]),.data_out(addR_0_0[5]));
FF_32    treeBuffer_0_07(.clk(clk),.rst_n(rst_n),.data_in(add_0_0[6]),.data_out(addR_0_0[6]));
FF_32    treeBuffer_0_08(.clk(clk),.rst_n(rst_n),.data_in(add_0_0[7]),.data_out(addR_0_0[7]));
FF_32    treeBuffer_0_09(.clk(clk),.rst_n(rst_n),.data_in(add_0_0[8]),.data_out(addR_0_0[8]));
FF_32    treeBuffer_0_010(.clk(clk),.rst_n(rst_n),.data_in(add_0_0[9]),.data_out(addR_0_0[9]));
FF_32    treeBuffer_0_011(.clk(clk),.rst_n(rst_n),.data_in(add_0_0[10]),.data_out(addR_0_0[10]));
FF_32    treeBuffer_0_012(.clk(clk),.rst_n(rst_n),.data_in(add_0_0[11]),.data_out(addR_0_0[11]));
FF_32    treeBuffer_0_013(.clk(clk),.rst_n(rst_n),.data_in(add_0_0[12]),.data_out(addR_0_0[12]));
FF_32    treeBuffer_0_014(.clk(clk),.rst_n(rst_n),.data_in(add_0_0[13]),.data_out(addR_0_0[13]));
FF_32    treeBuffer_0_015(.clk(clk),.rst_n(rst_n),.data_in(add_0_0[14]),.data_out(addR_0_0[14]));
FF_32    treeBuffer_0_016(.clk(clk),.rst_n(rst_n),.data_in(add_0_0[15]),.data_out(addR_0_0[15]));

//第二级得到8个部分和
assign add_0_1[0]    =   $signed(addR_0_0[0]) + $signed(addR_0_0[1]);
assign add_0_1[1]    =   $signed(addR_0_0[2]) + $signed(addR_0_0[3]);
assign add_0_1[2]    =   $signed(addR_0_0[4]) + $signed(addR_0_0[5]);
assign add_0_1[3]    =   $signed(addR_0_0[6]) + $signed(addR_0_0[7]);
assign add_0_1[4]    =   $signed(addR_0_0[8]) + $signed(addR_0_0[9]);
assign add_0_1[5]    =   $signed(addR_0_0[10]) + $signed(addR_0_0[11]);
assign add_0_1[6]    =   $signed(addR_0_0[12]) + $signed(addR_0_0[13]);
assign add_0_1[7]    =   $signed(addR_0_0[14]) + $signed(addR_0_0[15]);
FF_32    treeBuffer_0_11(.clk(clk),.rst_n(rst_n),.data_in(add_0_1[0]),.data_out(addR_0_1[0]));
FF_32    treeBuffer_0_12(.clk(clk),.rst_n(rst_n),.data_in(add_0_1[1]),.data_out(addR_0_1[1]));
FF_32    treeBuffer_0_13(.clk(clk),.rst_n(rst_n),.data_in(add_0_1[2]),.data_out(addR_0_1[2]));
FF_32    treeBuffer_0_14(.clk(clk),.rst_n(rst_n),.data_in(add_0_1[3]),.data_out(addR_0_1[3]));
FF_32    treeBuffer_0_15(.clk(clk),.rst_n(rst_n),.data_in(add_0_1[4]),.data_out(addR_0_1[4]));
FF_32    treeBuffer_0_16(.clk(clk),.rst_n(rst_n),.data_in(add_0_1[5]),.data_out(addR_0_1[5]));
FF_32    treeBuffer_0_17(.clk(clk),.rst_n(rst_n),.data_in(add_0_1[6]),.data_out(addR_0_1[6]));
FF_32    treeBuffer_0_18(.clk(clk),.rst_n(rst_n),.data_in(add_0_1[7]),.data_out(addR_0_1[7]));
//第三级得到4个部分和
assign add_0_2[0]    =   $signed(addR_0_1[0]) + $signed(addR_0_1[1]);
assign add_0_2[1]    =   $signed(addR_0_1[2]) + $signed(addR_0_1[3]);
assign add_0_2[2]    =   $signed(addR_0_1[4]) + $signed(addR_0_1[5]);
assign add_0_2[3]    =   $signed(addR_0_1[6]) + $signed(addR_0_1[7]);
FF_32    treeBuffer_0_21(.clk(clk),.rst_n(rst_n),.data_in(add_0_2[0]),.data_out(addR_0_2[0]));
FF_32    treeBuffer_0_22(.clk(clk),.rst_n(rst_n),.data_in(add_0_2[1]),.data_out(addR_0_2[1]));
FF_32    treeBuffer_0_23(.clk(clk),.rst_n(rst_n),.data_in(add_0_2[2]),.data_out(addR_0_2[2]));
FF_32    treeBuffer_0_24(.clk(clk),.rst_n(rst_n),.data_in(add_0_2[3]),.data_out(addR_0_2[3]));
//第四级得到2个部分和
assign add_0_3[0]    =   $signed(addR_0_2[0]) + $signed(addR_0_2[1]);
assign add_0_3[1]    =   $signed(addR_0_2[2]) + $signed(addR_0_2[3]);
FF_32    treeBuffer_0_31(.clk(clk),.rst_n(rst_n),.data_in(add_0_3[0]),.data_out(addR_0_3[0]));
FF_32    treeBuffer_0_32(.clk(clk),.rst_n(rst_n),.data_in(add_0_3[1]),.data_out(addR_0_3[1]));

//加法树：将32个PE的通道1部分和累加成32位结果，结构与通道0完全相同
assign  add_1_0[0]  =   $signed(output_temp_1[0]) + $signed(output_temp_1[1]);
assign  add_1_0[1]  =   $signed(output_temp_1[2]) + $signed(output_temp_1[3]);
assign  add_1_0[2]  =   $signed(output_temp_1[4]) + $signed(output_temp_1[5]);
assign  add_1_0[3]  =   $signed(output_temp_1[6]) + $signed(output_temp_1[7]);
assign  add_1_0[4]  =   $signed(output_temp_1[8]) + $signed(output_temp_1[9]);
assign  add_1_0[5]  =   $signed(output_temp_1[10]) + $signed(output_temp_1[11]);
assign  add_1_0[6]  =   $signed(output_temp_1[12]) + $signed(output_temp_1[13]);
assign  add_1_0[7]  =   $signed(output_temp_1[14]) + $signed(output_temp_1[15]);
assign  add_1_0[8]  =   $signed(output_temp_1[16]) + $signed(output_temp_1[17]);
assign  add_1_0[9]  =   $signed(output_temp_1[18]) + $signed(output_temp_1[19]);
assign  add_1_0[10]  =   $signed(output_temp_1[20]) + $signed(output_temp_1[21]);
assign  add_1_0[11]  =   $signed(output_temp_1[22]) + $signed(output_temp_1[23]);
assign  add_1_0[12]  =   $signed(output_temp_1[24]) + $signed(output_temp_1[25]);
assign  add_1_0[13]  =   $signed(output_temp_1[26]) + $signed(output_temp_1[27]);
assign  add_1_0[14]  =   $signed(output_temp_1[28]) + $signed(output_temp_1[29]);
assign  add_1_0[15]  =   $signed(output_temp_1[30]) + $signed(output_temp_1[31]);
FF_32    treeBuffer_1_01(.clk(clk),.rst_n(rst_n),.data_in(add_1_0[0]),.data_out(addR_1_0[0]));
FF_32    treeBuffer_1_02(.clk(clk),.rst_n(rst_n),.data_in(add_1_0[1]),.data_out(addR_1_0[1]));
FF_32    treeBuffer_1_03(.clk(clk),.rst_n(rst_n),.data_in(add_1_0[2]),.data_out(addR_1_0[2]));
FF_32    treeBuffer_1_04(.clk(clk),.rst_n(rst_n),.data_in(add_1_0[3]),.data_out(addR_1_0[3]));
FF_32    treeBuffer_1_05(.clk(clk),.rst_n(rst_n),.data_in(add_1_0[4]),.data_out(addR_1_0[4]));
FF_32    treeBuffer_1_06(.clk(clk),.rst_n(rst_n),.data_in(add_1_0[5]),.data_out(addR_1_0[5]));
FF_32    treeBuffer_1_07(.clk(clk),.rst_n(rst_n),.data_in(add_1_0[6]),.data_out(addR_1_0[6]));
FF_32    treeBuffer_1_08(.clk(clk),.rst_n(rst_n),.data_in(add_1_0[7]),.data_out(addR_1_0[7]));
FF_32    treeBuffer_1_09(.clk(clk),.rst_n(rst_n),.data_in(add_1_0[8]),.data_out(addR_1_0[8]));
FF_32    treeBuffer_1_010(.clk(clk),.rst_n(rst_n),.data_in(add_1_0[9]),.data_out(addR_1_0[9]));
FF_32    treeBuffer_1_011(.clk(clk),.rst_n(rst_n),.data_in(add_1_0[10]),.data_out(addR_1_0[10]));
FF_32    treeBuffer_1_012(.clk(clk),.rst_n(rst_n),.data_in(add_1_0[11]),.data_out(addR_1_0[11]));
FF_32    treeBuffer_1_013(.clk(clk),.rst_n(rst_n),.data_in(add_1_0[12]),.data_out(addR_1_0[12]));
FF_32    treeBuffer_1_014(.clk(clk),.rst_n(rst_n),.data_in(add_1_0[13]),.data_out(addR_1_0[13]));
FF_32    treeBuffer_1_015(.clk(clk),.rst_n(rst_n),.data_in(add_1_0[14]),.data_out(addR_1_0[14]));
FF_32    treeBuffer_1_016(.clk(clk),.rst_n(rst_n),.data_in(add_1_0[15]),.data_out(addR_1_0[15]));

assign add_1_1[0]    =   $signed(addR_1_0[0]) + $signed(addR_1_0[1]);
assign add_1_1[1]    =   $signed(addR_1_0[2]) + $signed(addR_1_0[3]);
assign add_1_1[2]    =   $signed(addR_1_0[4]) + $signed(addR_1_0[5]);
assign add_1_1[3]    =   $signed(addR_1_0[6]) + $signed(addR_1_0[7]);
assign add_1_1[4]    =   $signed(addR_1_0[8]) + $signed(addR_1_0[9]);
assign add_1_1[5]    =   $signed(addR_1_0[10]) + $signed(addR_1_0[11]);
assign add_1_1[6]    =   $signed(addR_1_0[12]) + $signed(addR_1_0[13]);
assign add_1_1[7]    =   $signed(addR_1_0[14]) + $signed(addR_1_0[15]);
FF_32    treeBuffer_1_11(.clk(clk),.rst_n(rst_n),.data_in(add_1_1[0]),.data_out(addR_1_1[0]));
FF_32    treeBuffer_1_12(.clk(clk),.rst_n(rst_n),.data_in(add_1_1[1]),.data_out(addR_1_1[1]));
FF_32    treeBuffer_1_13(.clk(clk),.rst_n(rst_n),.data_in(add_1_1[2]),.data_out(addR_1_1[2]));
FF_32    treeBuffer_1_14(.clk(clk),.rst_n(rst_n),.data_in(add_1_1[3]),.data_out(addR_1_1[3]));
FF_32    treeBuffer_1_15(.clk(clk),.rst_n(rst_n),.data_in(add_1_1[4]),.data_out(addR_1_1[4]));
FF_32    treeBuffer_1_16(.clk(clk),.rst_n(rst_n),.data_in(add_1_1[5]),.data_out(addR_1_1[5]));
FF_32    treeBuffer_1_17(.clk(clk),.rst_n(rst_n),.data_in(add_1_1[6]),.data_out(addR_1_1[6]));
FF_32    treeBuffer_1_18(.clk(clk),.rst_n(rst_n),.data_in(add_1_1[7]),.data_out(addR_1_1[7]));

assign add_1_2[0]    =   $signed(addR_1_1[0]) + $signed(addR_1_1[1]);
assign add_1_2[1]    =   $signed(addR_1_1[2]) + $signed(addR_1_1[3]);
assign add_1_2[2]    =   $signed(addR_1_1[4]) + $signed(addR_1_1[5]);
assign add_1_2[3]    =   $signed(addR_1_1[6]) + $signed(addR_1_1[7]);
FF_32    treeBuffer_1_21(.clk(clk),.rst_n(rst_n),.data_in(add_1_2[0]),.data_out(addR_1_2[0]));
FF_32    treeBuffer_1_22(.clk(clk),.rst_n(rst_n),.data_in(add_1_2[1]),.data_out(addR_1_2[1]));
FF_32    treeBuffer_1_23(.clk(clk),.rst_n(rst_n),.data_in(add_1_2[2]),.data_out(addR_1_2[2]));
FF_32    treeBuffer_1_24(.clk(clk),.rst_n(rst_n),.data_in(add_1_2[3]),.data_out(addR_1_2[3]));

assign add_1_3[0]    =   $signed(addR_1_2[0]) + $signed(addR_1_2[1]);
assign add_1_3[1]    =   $signed(addR_1_2[2]) + $signed(addR_1_2[3]);
FF_32    treeBuffer_1_31(.clk(clk),.rst_n(rst_n),.data_in(add_1_3[0]),.data_out(addR_1_3[0]));
FF_32    treeBuffer_1_32(.clk(clk),.rst_n(rst_n),.data_in(add_1_3[1]),.data_out(addR_1_3[1]));

assign data_out[31:0] = $signed(addR_0_3[0]) + $signed(addR_0_3[1]); //通道0结果
assign data_out[63:32] = $signed(addR_1_3[0]) + $signed(addR_1_3[1]); //通道1结果

endmodule
