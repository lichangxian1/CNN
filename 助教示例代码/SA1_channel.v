module SA1_channel(
    input wire clk,
    input wire rst_n,
    input wire signed [55:0] data_in, //7*8bit输入数据，按行脉动进入
    input wire signed [615:0] weight, //11*7*8bit权重
    output wire signed [31:0] data_out
);

genvar i,j;
wire signed     [615:0]         data_temp   ;//用于P之间传递的脉动数据，宽度与weight相同
wire signed     [2463:0]        partial_product_temp    ;//所有PE的乘积结果，32*77
//加法树各级部分和信号
wire signed     [32*5*7-1:0]    partial_product_temp_l2; 
wire signed     [32*3*7-1:0]    partial_product_temp_l3; 
wire signed     [32*7-1:0]      partial_product_temp_l4; 
wire signed     [32*3-1:0]      partial_product_temp_l5; 
wire signed     [32*2-1:0]      partial_product_temp_l6; 
//生成11行7列的PE阵列
generate
for(i = 0;i < 11;i = i + 1)begin:row_loop
    for(j = 0;j < 7;j = j + 1)begin:col_loop
        if(i == 10)begin//最后一行 PE输入数据直接来自data_in
            PE  array_pe(
                .clk            (clk),
                .rst_n          (rst_n),
                .weight         (weight[(i*7+j)*8 + 7:(i*7+j)*8]),
                .data_in        (data_in[j*8 + 7:j*8]),
                .data_out       (data_temp[(i*7+j)*8 + 7 : (i*7+j)*8]),
                .temp_product   (partial_product_temp[(i*7+j)*32+31:(i*7+j)*32])  
            );
        end
        else begin
            PE  array_pe(
                .clk            (clk),
                .rst_n          (rst_n),
                .weight         (weight[(i*7+j)*8 + 7:(i*7+j)*8]),
                .data_in        (data_temp[(i*7+j+7)*8 + 7 : (i*7+j+7)*8]),
                .data_out       (data_temp[(i*7+j)*8 + 7 : (i*7+j)*8]),
                .temp_product   (partial_product_temp[(i*7+j)*32+31:(i*7+j)*32])  
            );
        end
    end
end
endgenerate

wire signed  [31:0]  adderTreeReg       [10*7 - 1:0];//用于存储列加法树各级的中间结果
wire signed  [31:0]  inputReg           [11*7 - 1:0];//寄存77个PE的乘积结果
for(i = 0;i < 7;i = i + 1)begin
//寄存每一行的乘积结果，共11行
FF_32    inputBuffer0(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp[(0*7+i)*32+31:(0*7+i)*32]),.data_out(inputReg[0*7+i]));
FF_32    inputBuffer1(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp[(1*7+i)*32+31:(1*7+i)*32]),.data_out(inputReg[1*7+i]));
FF_32    inputBuffer2(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp[(2*7+i)*32+31:(2*7+i)*32]),.data_out(inputReg[2*7+i]));
FF_32    inputBuffer3(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp[(3*7+i)*32+31:(3*7+i)*32]),.data_out(inputReg[3*7+i]));
FF_32    inputBuffer4(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp[(4*7+i)*32+31:(4*7+i)*32]),.data_out(inputReg[4*7+i]));
FF_32    inputBuffer5(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp[(5*7+i)*32+31:(5*7+i)*32]),.data_out(inputReg[5*7+i]));
FF_32    inputBuffer6(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp[(6*7+i)*32+31:(6*7+i)*32]),.data_out(inputReg[6*7+i]));
FF_32    inputBuffer7(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp[(7*7+i)*32+31:(7*7+i)*32]),.data_out(inputReg[7*7+i]));
FF_32    inputBuffer8(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp[(8*7+i)*32+31:(8*7+i)*32]),.data_out(inputReg[8*7+i]));
FF_32    inputBuffer9(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp[(9*7+i)*32+31:(9*7+i)*32]),.data_out(inputReg[9*7+i]));
FF_32    inputBuffer10(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp[(10*7+i)*32+31:(10*7+i)*32]),.data_out(inputReg[10*7+i]));
//第一级加法将相邻两乘积相加，得到5组部分和
assign partial_product_temp_l2[32*(0*7+i)+31:32*(0*7+i)] = $signed(inputReg[0*7+i]) + $signed(inputReg[1*7+i]);
assign partial_product_temp_l2[32*(1*7+i)+31:32*(1*7+i)] = $signed(inputReg[2*7+i]) + $signed(inputReg[3*7+i]);
assign partial_product_temp_l2[32*(2*7+i)+31:32*(2*7+i)] = $signed(inputReg[4*7+i]) + $signed(inputReg[5*7+i]);
assign partial_product_temp_l2[32*(3*7+i)+31:32*(3*7+i)] = $signed(inputReg[6*7+i]) + $signed(inputReg[7*7+i]);
assign partial_product_temp_l2[32*(4*7+i)+31:32*(4*7+i)] = $signed(inputReg[8*7+i]) + $signed(inputReg[9*7+i]);
//寄存第一级加法结果和第11个原始乘积
FF_32    treeBuffer0(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp_l2[32*(0*7+i)+31:32*(0*7+i)]),.data_out(adderTreeReg[0*7+i]));
FF_32    treeBuffer1(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp_l2[32*(1*7+i)+31:32*(1*7+i)]),.data_out(adderTreeReg[1*7+i]));
FF_32    treeBuffer2(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp_l2[32*(2*7+i)+31:32*(2*7+i)]),.data_out(adderTreeReg[2*7+i]));
FF_32    treeBuffer3(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp_l2[32*(3*7+i)+31:32*(3*7+i)]),.data_out(adderTreeReg[3*7+i]));
FF_32    treeBuffer4(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp_l2[32*(4*7+i)+31:32*(4*7+i)]),.data_out(adderTreeReg[4*7+i]));
FF_32    treeBuffer5(.clk(clk),.rst_n(rst_n),.data_in(inputReg[10*7+i]),.data_out(adderTreeReg[5*7+i]));
//第二级加法进一步两两相加，得到3组部分和
assign partial_product_temp_l3[32*(0*7+i)+31:32*(0*7+i)] = $signed(adderTreeReg[0*7+i]) + $signed(adderTreeReg[1*7+i]);
assign partial_product_temp_l3[32*(1*7+i)+31:32*(1*7+i)] = $signed(adderTreeReg[2*7+i]) + $signed(adderTreeReg[3*7+i]);
assign partial_product_temp_l3[32*(2*7+i)+31:32*(2*7+i)] = $signed(adderTreeReg[4*7+i]) + $signed(adderTreeReg[5*7+i]);
//寄存第二级加法结果
FF_32    treeBuffer6(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp_l3[32*(0*7+i)+31:32*(0*7+i)]),.data_out(adderTreeReg[6*7+i]));
FF_32    treeBuffer7(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp_l3[32*(1*7+i)+31:32*(1*7+i)]),.data_out(adderTreeReg[7*7+i]));
FF_32    treeBuffer8(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp_l3[32*(2*7+i)+31:32*(2*7+i)]),.data_out(adderTreeReg[8*7+i]));
//第三级加法将第二级的 3 组部分和相加得到每列的最终累加和
assign partial_product_temp_l4[32*i + 31:32*i]   = $signed(adderTreeReg[6*7+i]) + $signed(adderTreeReg[7*7+i]) + $signed(adderTreeReg[8*7+i]);
//寄存第三级结果
FF_32    treeBuffer9(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp_l4[32*i + 31:32*i]),.data_out(adderTreeReg[9*7+i]));
end

//行加法树
wire signed  [31:0]  adderTreeReg2    [5:0];//用于存储跨列加法的中间结果
//第四级将相邻两列的结果相加，共3组
assign  partial_product_temp_l5[32*0 + 31:32*0] = $signed(adderTreeReg[9*7+0]) + $signed(adderTreeReg[9*7+1]);
assign  partial_product_temp_l5[32*1 + 31:32*1] = $signed(adderTreeReg[9*7+2]) + $signed(adderTreeReg[9*7+3]);
assign  partial_product_temp_l5[32*2 + 31:32*2] = $signed(adderTreeReg[9*7+4]) + $signed(adderTreeReg[9*7+5]);
//寄存第四级结果和第7列的原始结果
FF_32    treeBuffer2_0(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp_l5[32*0 + 31:32*0]),.data_out(adderTreeReg2[0]));
FF_32    treeBuffer2_1(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp_l5[32*1 + 31:32*1]),.data_out(adderTreeReg2[1]));
FF_32    treeBuffer2_2(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp_l5[32*2 + 31:32*2]),.data_out(adderTreeReg2[2]));
FF_32    treeBuffer2_3(.clk(clk),.rst_n(rst_n),.data_in(adderTreeReg[9*7+6]),.data_out(adderTreeReg2[3]));
//第五级将第四级数据进一步两两相加
assign  partial_product_temp_l6[32*0 + 31:32*0] = $signed(adderTreeReg2[0]) + $signed(adderTreeReg2[1]);
assign  partial_product_temp_l6[32*1 + 31:32*1] = $signed(adderTreeReg2[2]) + $signed(adderTreeReg2[3]);
//寄存第五级结果
FF_32    treeBuffer2_4(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp_l6[32*0 + 31:32*0]),.data_out(adderTreeReg2[4]));
FF_32    treeBuffer2_5(.clk(clk),.rst_n(rst_n),.data_in(partial_product_temp_l6[32*1 + 31:32*1]),.data_out(adderTreeReg2[5]));
//第六级最后两个部分和相加，得到最终输出
assign  data_out = $signed(adderTreeReg2[5]) + $signed(adderTreeReg2[4]);

endmodule

