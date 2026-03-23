`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2025/05/24 10:36:42
// Design Name: 
// Module Name: sramBuffer1
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module sramBuffer1(
  input       wire    [255:0]                 data_in,//输入数据，32通道×8bit
  input       wire                            clk,
  input       wire                            rst_n,
  input       wire                            enable,
  input       wire    [5:0]                   raddr,//读地址
  output      wire    [767:0]                 data_out//输出数据，三个256位拼接
);
wire [255:0]    Q1,Q2,Q3,Q4;//四个SRAM的读数据输出
wire            cen_temp1,cen_temp2,cen_temp3,cen_temp4;
wire            wen_temp1,wen_temp2,wen_temp3,wen_temp4;
reg             CEN1,CEN2,CEN3,CEN4;
reg             WEN1,WEN2,WEN3,WEN4;
reg  [4:0]      A1,A2,A3,A4;
reg  [255:0]    data_in_buffer;//输入数据寄存器
reg     [6:0]   cnt;//内部计数器，用于控制写入时序

//测试线
wire [7:0] testpoint1;
wire [7:0] testpoint2;
wire [7:0] testpoint3;
wire [7:0] testpoint4;
assign testpoint1 = data_out[7:0];
assign testpoint2 = data_out[15:8];
assign testpoint3 = data_out[256+7:256];
assign testpoint4 = data_out[512+7:512];


//在下降沿寄存data_in
always@(negedge clk or negedge rst_n) begin
  if(!rst_n)
    data_in_buffer <=  255'b0;
  else
    data_in_buffer <= data_in;
end

always@(posedge clk or negedge rst_n) begin
  if(!rst_n)
    cnt <=  7'b0;
  else if(enable)
    cnt <=  cnt + 1;
  else if(cnt == 7'd79)
    cnt <= 0;
  else
    cnt <= cnt;
end

//ARRAY1控制逻辑
//写入条件：enable有效且cnt在0~19
//读出条件：读地址raddr在0~19且cnt>=51
assign cen_temp1 = !(enable && cnt>=0 && cnt<=19 || raddr>=0 && raddr<=19 && cnt>=51);//片选信号拉低
always@(negedge clk or negedge rst_n) begin
  if(!rst_n)
    CEN1 <=  1;
  else
    CEN1 <= cen_temp1;
end

assign wen_temp1 = !(enable && cnt>=0 && cnt<=19);//写使能信号拉低
always@(negedge clk or negedge rst_n) begin
  if(!rst_n)
    WEN1 <=  1;
  else
    WEN1 <= wen_temp1;
end

always@(negedge clk or negedge rst_n) begin
  if(!rst_n)
    A1 <=  5'b0;
  else if(!CEN1 && !WEN1)
    A1 <=  cnt;//写操作：地址取cnt
  else if(!CEN1 && WEN1)
    A1 <=  raddr;//读操作：地址取raddr
  else
    A1 <=  5'b0;
end

//ARRAY2控制逻辑
//写入条件：enable有效且cnt在20~39
//读出条件：raddr在0~39且cnt>=51
assign cen_temp2 = !(enable && cnt>=20 && cnt<=39 || raddr>=0 && raddr<=39 && cnt>=51);//片选信号拉低
always@(negedge clk or negedge rst_n) begin
  if(!rst_n)
    CEN2 <=  1;
  else
    CEN2 <= cen_temp2;
end
assign wen_temp2 = !(enable && cnt>=20 && cnt<=39);//写使能信号拉低
always@(negedge clk or negedge rst_n) begin
  if(!rst_n)
    WEN2 <=  1;
  else
    WEN2 <= wen_temp2;
end
always@(negedge clk or negedge rst_n) begin
  if(!rst_n)
    A2 <=  5'b0;
  else if(!CEN2 && !WEN2)
    A2 <=  cnt-20; //写操作地址
  else if(!CEN2 && WEN2)
    A2 <=  raddr%20;//读操作地址
  else
    A2 <=  5'b0;
end

//ARRAY3控制逻辑
//写入条件：enable有效且cnt在40~49
//读出条件：raddr在0~9且cnt>=50，或raddr在20~29
assign cen_temp3 = !(enable && cnt>=40 && cnt<=49 || raddr>=0 && raddr<=9 && cnt>=50 || raddr>=20 && raddr<=29);
always@(negedge clk or negedge rst_n) begin
  if(!rst_n)
    CEN3 <=  1;
  else
    CEN3 <= cen_temp3;
end
assign wen_temp3 = !(enable && cnt>=40 && cnt<=49);
always@(negedge clk or negedge rst_n) begin
  if(!rst_n)
    WEN3 <=  1;
  else
    WEN3 <= wen_temp3;
end
always@(negedge clk or negedge rst_n) begin
  if(!rst_n)
    A3 <=  5'b0;
  else if(!CEN3 && !WEN3)
    A3 <=  cnt - 40;
  else if(!CEN3 && WEN3)
    A3 <=  raddr%20;
  else
    A3 <=  5'b0;
end

//ARRAY4控制逻辑
//写入条件：enable有效且cnt在50~59
//读出条件：raddr在10~19或30~39
assign cen_temp4 = !(enable && cnt>=50 && cnt<=59 || raddr>=10 && raddr<=19 || raddr>=30 && raddr<=39);
always@(negedge clk or negedge rst_n) begin
  if(!rst_n)
    CEN4 <=  1;
  else
    CEN4 <= cen_temp4;
end
assign wen_temp4 = !(enable && cnt>=50 && cnt<=59);
always@(negedge clk or negedge rst_n) begin
  if(!rst_n)
    WEN4 <=  1;
  else
    WEN4 <= wen_temp4;
end
always@(negedge clk or negedge rst_n) begin
  if(!rst_n)
    A4 <=  5'b0;
  else if(!CEN4 && !WEN4)
    A4 <=  cnt - 50;
  else if(!CEN4 && WEN4)
    A4 <=  raddr%20 - 10;
  else
    A4 <=  5'b0;
end

//第四列数据缓存使用两个寄存器构成深度为2的移位寄存器链，因为最后一列数据输入后只需要延迟两个周期就被读出
reg [255:0]     col4_data1;
reg [255:0]     col4_data2;
always @(posedge clk or negedge rst_n) begin
  if(!rst_n)
    col4_data1    <=  256'b0;
  else
    col4_data1    <=  data_in;
end  
always @(posedge clk or negedge rst_n) begin
  if(!rst_n)
    col4_data2    <=  256'b0;
  else
    col4_data2    <=  col4_data1;
end 
//根据raddr范围，选择三个数据源拼接成768位输出
assign data_out = 
(raddr>=1 && raddr<=10)? {Q3,Q2,Q1}:
(raddr>=11 && raddr<=20)?{Q4,Q2,Q1}:
(raddr>=21 && raddr<=30)?{col4_data2,Q3,Q2}:
(raddr>=31 && raddr<=39 || (raddr == 0))?{col4_data2,Q4,Q2}:
768'b0;

//实例化四个256位宽、32深度的SRAM
SRAM_32_256     ARRAY1(
  .Q                (Q1),
  .CLK              (clk),
  .CEN              (CEN1),
  .WEN              (WEN1),
  .A                (A1),
  .D                (data_in_buffer)
);

SRAM_32_256     ARRAY2(
  .Q                (Q2),
  .CLK              (clk),
  .CEN              (CEN2),
  .WEN              (WEN2),
  .A                (A2),
  .D                (data_in_buffer)
);

SRAM_32_256     ARRAY3(
  .Q                (Q3),
  .CLK              (clk),
  .CEN              (CEN3),
  .WEN              (WEN3),
  .A                (A3),
  .D                (data_in_buffer)
);

SRAM_32_256     ARRAY4(
  .Q                (Q4),
  .CLK              (clk),
  .CEN              (CEN4),
  .WEN              (WEN4),
  .A                (A4),
  .D                (data_in_buffer)
);

endmodule
