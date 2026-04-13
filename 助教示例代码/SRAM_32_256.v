`timescale 1ns / 1ps
//一个深度32、位宽256位的SRAM封装
module SRAM_32_256(
        Q,
			  CLK,
			  CEN,
			  WEN,
			  A,
			  D);

  parameter	Bits = 256;     //总位宽
  parameter	Word_Depth = 32;
  parameter	Add_Width = 5;  // 地址宽度

  output [Bits-1:0]      	Q;//读数据输出
  input		   		CLK;
  input		   		CEN;
  input		   		WEN;
  input	[Add_Width-1:0] 	A;
  input	[Bits-1:0] 		    D;//写数据输入
  
  //调试用的测试线
  wire [7:0]    sram_in;
  wire  [7:0]   sram_out;
  assign    sram_in = D[7:0];
  assign    sram_out = Q[7:0];
  //实例化低128位SRAM宏单元
  S018V3EBCDSP_X8Y4D128_PR      sram_LB(
  .Q                (Q[127:0]),
  .CLK              (CLK),
  .CEN              (CEN),
  .WEN              (WEN),
  .A                (A),
  .D                (D[127:0])
  );
  //实例化高128位SRAM宏单元
  S018V3EBCDSP_X8Y4D128_PR      sram_MB(
  .Q                (Q[255:128]),
  .CLK              (CLK),
  .CEN              (CEN),
  .WEN              (WEN),
  .A                (A),
  .D                (D[255:128])
  );
  
endmodule
