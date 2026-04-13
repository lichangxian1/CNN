`timescale 1ns/1ps


module sram_32x32(
                          Q,
			  CLK,
			  CEN,
			  WEN,
			  A,
			  D);

  parameter	Bits = 32;     //总位宽
  parameter	Word_Depth = 32;
  parameter	Add_Width = 5;  // 地址宽度

  output [Bits-1:0]      	Q;//读数据输出
  input		   		CLK;
  input		   		CEN;
  input		   		WEN;
  input	[Add_Width-1:0] 	A;
  input	[Bits-1:0] 		    D;//写数据输入


S018V3EBCDSP_X8Y4D32_PR sram_inst(
  .Q                (Q[Bits-1:0]),
  .CLK              (CLK),
  .CEN              (CEN),
  .WEN              (WEN),
  .A                (A),
  .D                (D[Bits-1:0])
)  
endmodule