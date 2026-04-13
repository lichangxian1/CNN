# CNN工程代码全局快照

**Root Directory:** `/cluster/home/jiut107/cnn2/CNN/cnn_accelerator`

### `rtl/cnn_controller.v`

```verilog
`timescale 1ns / 1ps

// ==========================================================================
// 模块名称: cnn_controller (全局大脑 / 调度中心)
// 功能描述: 
//   1. 控制芯片在 Conv1、Depthwise(DW)、Pointwise(PW) 三种计算模式间平滑切换。
//   2. 踩准节拍：控制 Line Buffer (行缓存) 何时滑动、何时暂停。
//   3. 地址发生器 (AGU)：生成正确的 SRAM 读写地址和权重读取地址。
// ==========================================================================

module cnn_controller (
    input  wire         clk,             // 全局时钟 (100MHz)
    input  wire         rst_n,           // 全局复位信号 (低电平有效)
    input  wire         start,           // 外部触发信号：拉高一拍表示开始处理一帧图像
    input  wire         window_valid,    // 来自 Line Buffer: 为 1 表示 3x3 或 11x7 窗口内数据已填满且合法
    
    // --- 给 MAC 阵列的控制信号 ---
    output reg  [1:0]   layer_mode,      // 告知计算阵列当前是什么模式: 00=Conv1, 01=DW, 10=PW
    
    // --- 给 Line Buffer 的控制信号 ---
    output reg          line_buf_en,     // 1: 允许窗口滑动进新数据; 0: 冻结窗口数据不动
    
    // --- 给后处理模块与外部的握手信号 ---
    output reg          mac_valid,       // 1: 告知后处理模块“当前周期的MAC输出有效，请进行 ReLU 并写回 SRAM”
    output reg          done,            // 1: 整帧网络前向推理彻底完成
    
    // --- SRAM 地址生成 (AGU) ---
    // 提示: 顶层模块 (cnn_top) 会根据 layer_mode 将这里的逻辑地址路由到具体的 Ping 或 Pong SRAM
    output reg  [1:0]   sram_route_sel,  // 0: 读Input写Pong, 1: 读Pong写Ping, 2: 读Ping写Pong
    output reg  [9:0]   act_raddr,       // 特征图 SRAM 读取地址
    output reg  [9:0]   act_waddr,       // 特征图 SRAM 写入地址
    output reg  [11:0]  weight_raddr     // 权重 SRAM 读取地址
);

    // ==========================================================================
    // 第一部分：状态机定义 (FSM States)
    // 使用独热码 (One-Hot) 或是二进制编码，这里为了易读使用二进制参数定义
    // ==========================================================================
    localparam ST_IDLE  = 3'd0; // 待机状态：等待 start 信号
    localparam ST_CONV1 = 3'd1; // 算第一层 (常规卷积)
    localparam ST_DW    = 3'd2; // 算第二层 (深度可分离卷积)
    localparam ST_PW    = 3'd3; // 算第三层 (逐点卷积)
    localparam ST_DONE  = 3'd4; // 完成状态
    
    reg [2:0] current_state, next_state;

    // ==========================================================================
    // 第二部分：核心嵌套计数器 (用于追踪当前算到了整张图的哪个位置)
    // ==========================================================================
    // spatial_cnt: 空间像素计数器。记录当前层已经算完了几个输出像素点。
    //   - 第一层输出 20x4=80 个点，所以数到 79
    //   - 第二/三层输出 18x2=36 个点，所以数到 35
    reg [6:0] spatial_cnt;  
    
    // ch_grp_cnt: 通道分组计数器。我们的阵列算力是折叠的，需要分批算通道。
    //   - 第一层：要算 32 个输出通道，但一周期只能算 4 个。所以分 8 批 (数 0~7)。
    //   - 第二层：一次能算完 32 个通道。不需要分批 (恒为 0)。
    //   - 第三层：要算 32 个通道，一次算 8 个。所以分 4 批 (数 0~3)。
    reg [3:0] ch_grp_cnt;   

    // ==========================================================================
    // 三段式状态机 段1：状态跳转时序逻辑 (打拍寄存)
    // ==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_state <= ST_IDLE;
        end else begin
            current_state <= next_state;
        end
    end

    // ==========================================================================
    // 三段式状态机 段2：次态组合逻辑 (决定什么时候跳到下一层)
    // ==========================================================================
    always @(*) begin
        next_state = current_state; // 默认保持当前状态
        
        case (current_state)
            ST_IDLE: begin
                if (start) next_state = ST_CONV1; // 接到起跑信号，进入第一层
            end
            
            ST_CONV1: begin
                // 当算完最后一个空间像素 (79) 的最后一批通道 (7) 时，跳入第二层
                if (spatial_cnt == 7'd79 && ch_grp_cnt == 4'd7 && window_valid)
                    next_state = ST_DW;
            end
            
            ST_DW: begin
                // DW 层不用分批算通道，算完最后一个空间像素 (35) 就跳入第三层
                if (spatial_cnt == 7'd35 && window_valid)
                    next_state = ST_PW;
            end
            
            ST_PW: begin
                // 算完最后一个像素 (35) 的最后一批通道 (3) 时，网络核心计算结束
                // (此处省略全连接层，直接进 DONE)
                if (spatial_cnt == 7'd35 && ch_grp_cnt == 4'd3 && window_valid) // 这里修正一个小Bug：只有在数据有效且计算完成时才跳转
                    next_state = ST_DONE;
            end
            
            ST_DONE: begin
                next_state = ST_IDLE; // 发出完成信号后回到待机
            end
            
            default: next_state = ST_IDLE;
        endcase
    end

    // ==========================================================================
    // 三段式状态机 段3：数据通路控制与地址生成 (最核心的时序逻辑)
    // 这一段决定了阵列“在此时此刻应该做什么动作”
    // ==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // --- 系统复位，所有信号清零 ---
            spatial_cnt    <= 7'd0;
            ch_grp_cnt     <= 4'd0;
            layer_mode     <= 2'b00;
            line_buf_en    <= 1'b0;
            mac_valid      <= 1'b0;
            done           <= 1'b0;
            sram_route_sel <= 2'd0;
            act_raddr      <= 10'd0;
            act_waddr      <= 10'd0;
            weight_raddr   <= 12'd0;
        end else begin
            case (current_state)
                
                // -------------------------------------------------------------
                // 【待机状态】
                // -------------------------------------------------------------
                ST_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        // 准备进入 Conv1，初始化所有指针
                        spatial_cnt    <= 7'd0;
                        ch_grp_cnt     <= 4'd0;
                        act_raddr      <= 10'd0; // 从输入图像第0个像素开始读
                        act_waddr      <= 10'd0; // 写到 Pong SRAM 第0个位置
                        weight_raddr   <= 12'd0; // 从权重头部开始读
                        line_buf_en    <= 1'b1;  // 打开行缓存，开始吸入数据填充窗口
                        sram_route_sel <= 2'd0;  // 路由: Read Input, Write Pong
                    end
                end
                
                // -------------------------------------------------------------
                // 【第一层：常规卷积】(需要复用窗口，冻结流水线)
                // -------------------------------------------------------------
                ST_CONV1: begin
                    layer_mode <= 2'b00; // 告知 MAC 阵列组合成 4棵 77进1 的大树
                    
                    if (!window_valid) begin
                        // 【情况A：窗口没填满】
                        // 数据还在行缓存里爬行，不能算。继续让它走，并继续读 SRAM
                        line_buf_en <= 1'b1; 
                        mac_valid   <= 1'b0; // 告诉后处理：现在输出的是垃圾，别存！
                        act_raddr   <= act_raddr + 1'b1; // 连续读下一个像素喂给缓存
                    end 
                    else begin
                        // 【情况B：窗口填满了，可以开算了！】
                        // 核心操作：我们要针对同一个图像窗口，换 8 批不同的卷积核来算
                        line_buf_en <= 1'b0; // 【关键】冻结行缓存！图像窗口定住不动！
                        mac_valid   <= 1'b1; // MAC 输出有效，允许写入 SRAM
                        
                        weight_raddr <= weight_raddr + 1'b1; // 权重地址不断加，取新核
                        act_waddr    <= act_waddr + 1'b1;    // 每算完一批就存入 SRAM
                        
                        if (ch_grp_cnt == 4'd7) begin
                            // 8 批通道都算完了！这个空间像素彻底搞定。
                            ch_grp_cnt  <= 4'd0;
                            spatial_cnt <= spatial_cnt + 1'b1;
                            
                            // 重新打开行缓存的门，让图像滑动到下一个像素
                            line_buf_en <= 1'b1; 
                            act_raddr   <= act_raddr + 1'b1; // 读入新像素
                            
                            // 状态切换预判：如果算完最后一个，为下一层做初始化
                            if (spatial_cnt == 7'd79) begin
                                spatial_cnt    <= 7'd0;
                                ch_grp_cnt     <= 4'd0;
                                act_raddr      <= 10'd0; // 下一层从头读 Pong
                                act_waddr      <= 10'd0; // 下一层从头写 Ping
                                sram_route_sel <= 2'd1;  // 路由: Read Pong, Write Ping
                                mac_valid      <= 1'b0;  // 切换瞬间置零
                            end
                        end else begin
                            // 还没算完 8 批，空间像素不动，通道批次 +1
                            ch_grp_cnt <= ch_grp_cnt + 1'b1;
                        end
                    end
                end
                
                // -------------------------------------------------------------
                // 【第二层：深度可分离卷积】(不需要复用窗口，流水线全开)
                // -------------------------------------------------------------
                ST_DW: begin
                    layer_mode <= 2'b01; // 告知 MAC 阵列组合成 32棵 9进1 的小树
                    
                    if (!window_valid) begin
                        line_buf_en <= 1'b1;
                        mac_valid   <= 1'b0;
                        act_raddr   <= act_raddr + 1'b1;
                    end 
                    else begin
                        // 因为阵列很大，1 个周期就能把 32 个通道全算完
                        // 所以不需要冻结窗口，一边滑一边出结果！
                        line_buf_en  <= 1'b1;  // 一直滑动
                        mac_valid    <= 1'b1;
                        
                        weight_raddr <= weight_raddr + 1'b1;
                        act_waddr    <= act_waddr + 1'b1;
                        act_raddr    <= act_raddr + 1'b1;
                        spatial_cnt  <= spatial_cnt + 1'b1;
                        
                        // 状态切换预判
                        if (spatial_cnt == 7'd35) begin
                            spatial_cnt    <= 7'd0;
                            act_raddr      <= 10'd0; // 从头读 Ping
                            act_waddr      <= 10'd0; // 从头写 Pong
                            sram_route_sel <= 2'd2;  // 路由: Read Ping, Write Pong
                            mac_valid      <= 1'b0;
                        end
                    end
                end
                
                // -------------------------------------------------------------
                // 【第三层：逐点卷积】(1x1 卷积，重回冻结逻辑)
                // -------------------------------------------------------------
                ST_PW: begin
                    layer_mode <= 2'b10; // 告知 MAC 阵列组合成 8棵 32进1 的中树
                    
                    // 1x1 卷积其实不需要 3x3 行缓存的延迟，只要读到1个点就能算。
                    // 但为了统一数据通路，我们依然使用 window_valid (此时可瞬间拉高)
                    if (window_valid) begin
                        line_buf_en <= 1'b0; // 冻结当前像素
                        mac_valid   <= 1'b1;
                        
                        weight_raddr <= weight_raddr + 1'b1;
                        act_waddr    <= act_waddr + 1'b1;
                        
                        if (ch_grp_cnt == 4'd3) begin
                            // 4 批通道算完 (4*8=32)，滑动到下一个点
                            ch_grp_cnt  <= 4'd0;
                            spatial_cnt <= spatial_cnt + 1'b1;
                            line_buf_en <= 1'b1;
                            act_raddr   <= act_raddr + 1'b1;
                            
                            if (spatial_cnt == 7'd35) begin
                                mac_valid <= 1'b0; // 结束前停止写入
                            end
                        end else begin
                            ch_grp_cnt <= ch_grp_cnt + 1'b1;
                        end
                    end else begin
                        line_buf_en <= 1'b1;
                        mac_valid   <= 1'b0;
                        act_raddr   <= act_raddr + 1'b1;
                    end
                end
                
                // -------------------------------------------------------------
                // 【完成状态】
                // -------------------------------------------------------------
                ST_DONE: begin
                    done        <= 1'b1; // 发出高电平，告诉外部“我算完了！”
                    line_buf_en <= 1'b0;
                    mac_valid   <= 1'b0;
                end
                
            endcase
        end
    end

endmodule
```

### `rtl/cnn_top.v`

```verilog

```

### `rtl/mac_array.v`

```verilog
`timescale 1ns / 1ps

module mac_array (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire [1:0]           layer_mode,   // 00: Conv1, 01: Depthwise, 10: Pointwise
    
    // 输入接口：为了兼容 Verilog-2001，将 308 个 8-bit 数据展平为一维向量
    // 308 * 8 = 2464 bits
    input  wire [2463:0]        act_in_flat,  // 广播/分配好的特征图输入
    input  wire [2463:0]        wgt_in_flat,  // 对应的权重输入
    
    // 输出接口：最多同时输出 32 个通道的 32-bit 局部累加和 (INT32)
    // 32 * 32 = 1024 bits
    output reg  [1023:0]        psum_out_flat
);

    // ==========================================
    // 0. 数据解包 (Unpacking)
    // ==========================================
    wire signed [7:0] act_in [0:307];
    wire signed [7:0] wgt_in [0:307];
    
    genvar g;
    generate
        for (g = 0; g < 308; g = g + 1) begin : unpack_loop
            assign act_in[g] = act_in_flat[g*8 +: 8];
            assign wgt_in[g] = wgt_in_flat[g*8 +: 8];
        end
    endgenerate

    // ==========================================
    // 1. 第一级流水线：308 个并行乘法器 (Stage 1)
    // ==========================================
    reg signed [15:0] mult_out [0:307];
    integer i;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 308; i = i + 1) begin
                mult_out[i] <= 16'sd0;
            end
        end else begin
            // 8-bit * 8-bit = 16-bit 带符号乘法
            // 这里打一拍，将乘法器和后续的巨型加法树的时序路径切断，完美满足 100MHz！
            for (i = 0; i < 308; i = i + 1) begin
                mult_out[i] <= $signed(act_in[i]) * $signed(wgt_in[i]);
            end
        end
    end

    // ==========================================
    // 2. 纯组合逻辑：三套模式的加法树 (Combinational)
    // ==========================================
    reg signed [31:0] sum_conv1 [0:3];  // Conv1 模式：4 个输出，每个累加 77 个点
    reg signed [31:0] sum_dw    [0:31]; // Depthwise 模式：32 个输出，每个累加 9 个点
    reg signed [31:0] sum_pw    [0:7];  // Pointwise 模式：8 个输出，每个累加 32 个点
    
    integer m, n;
    
    always @(*) begin
        // --- A. Conv1 加法树 (4 组，每组 77 个) ---
        for (m = 0; m < 4; m = m + 1) begin
            sum_conv1[m] = 32'sd0;
            for (n = 0; n < 77; n = n + 1) begin
                sum_conv1[m] = sum_conv1[m] + mult_out[m*77 + n];
            end
        end
        
        // --- B. Depthwise 加法树 (32 组，每组 9 个) ---
        for (m = 0; m < 32; m = m + 1) begin
            sum_dw[m] = 32'sd0;
            for (n = 0; n < 9; n = n + 1) begin
                sum_dw[m] = sum_dw[m] + mult_out[m*9 + n];
            end
        end
        
        // --- C. Pointwise 加法树 (8 组，每组 32 个) ---
        for (m = 0; m < 8; m = m + 1) begin
            sum_pw[m] = 32'sd0;
            for (n = 0; n < 32; n = n + 1) begin
                sum_pw[m] = sum_pw[m] + mult_out[m*32 + n];
            end
        end
    end

    // ==========================================
    // 3. 第二级流水线：模式选择与寄存输出 (Stage 2)
    // ==========================================
    integer k;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            psum_out_flat <= 1024'sd0;
        end else begin
            case (layer_mode)
                2'd0: begin // === Conv1 模式 ===
                    for (k = 0; k < 4; k = k + 1) begin
                        psum_out_flat[k*32 +: 32] <= sum_conv1[k];
                    end
                    // 闲置通道置零，节省后端翻转功耗
                    for (k = 4; k < 32; k = k + 1) begin
                        psum_out_flat[k*32 +: 32] <= 32'sd0;
                    end
                end
                
                2'd1: begin // === Depthwise 模式 ===
                    for (k = 0; k < 32; k = k + 1) begin
                        psum_out_flat[k*32 +: 32] <= sum_dw[k];
                    end
                end
                
                2'd2: begin // === Pointwise 模式 ===
                    for (k = 0; k < 8; k = k + 1) begin
                        psum_out_flat[k*32 +: 32] <= sum_pw[k];
                    end
                    for (k = 8; k < 32; k = k + 1) begin
                        psum_out_flat[k*32 +: 32] <= 32'sd0;
                    end
                end
                
                default: begin
                    psum_out_flat <= 1024'sd0;
                end
            endcase
        end
    end

endmodule
```

### `rtl/maxpool.v`

```verilog

```

### `rtl/pe.v`

```verilog

```

### `rtl/post_process.v`

```verilog

```

### `rtl/srambuffer_layer2.v`

```verilog
module line_buffer_1ch #(
    parameter WORD_WIDTH = 32 // 每个SRAM word为32-bit (4个INT8)
)(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  shift_en,  // 移位使能：当SRAM读出有效新行时拉高
    input  wire [WORD_WIDTH-1:0] din,       // 来自SRAM的数据
    
    // 输出缓存的3行数据
    output reg  [WORD_WIDTH-1:0] line_row0, 
    output reg  [WORD_WIDTH-1:0] line_row1,
    output reg  [WORD_WIDTH-1:0] line_row2
);

    // 同步时序逻辑：实现向下移位
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            line_row0 <= {WORD_WIDTH{1'b0}};
            line_row1 <= {WORD_WIDTH{1'b0}};
            line_row2 <= {WORD_WIDTH{1'b0}};
        end else if (shift_en) begin
            // 新数据进入最底层，旧数据依次向上冒泡
            line_row2 <= din;
            line_row1 <= line_row2;
            line_row0 <= line_row1;
        end
    end

endmodule
```

### `rtl/S018V3EBCDSP_X8Y4D32_PR.v`

```verilog
/*
    Copyright (c) 2026 SMIC
    Filename:      S018V3EBCDSP_X8Y4D32_PR.v
    IP code :      S018V3EBCDSP
    Version:       0.1.a
    CreateDate:    Mar 31, 2026

    Verilog Model for Single-PORT SRAM
    SMIC 0.18um V3EBCD

    Configuration: -instname S018V3EBCDSP_X8Y4D32_PR -rows 8 -bits 32 -mux 4 
    Redundancy: Off
    Bit-Write: Off
*/

/* DISCLAIMER                                                                      */
/*                                                                                 */  
/*   SMIC hereby provides the quality information to you but makes no claims,      */
/* promises or guarantees about the accuracy, completeness, or adequacy of the     */
/* information herein. The information contained herein is provided on an "AS IS"  */
/* basis without any warranty, and SMIC assumes no obligation to provide support   */
/* of any kind or otherwise maintain the information.                              */  
/*   SMIC disclaims any representation that the information does not infringe any  */
/* intellectual property rights or proprietary rights of any third parties. SMIC   */
/* makes no other warranty, whether express, implied or statutory as to any        */
/* matter whatsoever, including but not limited to the accuracy or sufficiency of  */
/* any information or the merchantability and fitness for a particular purpose.    */
/* Neither SMIC nor any of its representatives shall be liable for any cause of    */
/* action incurred to connect to this service.                                     */  
/*                                                                                 */
/* STATEMENT OF USE AND CONFIDENTIALITY                                            */  
/*                                                                                 */  
/*   The following/attached material contains confidential and proprietary         */  
/* information of SMIC. This material is based upon information which SMIC         */  
/* considers reliable, but SMIC neither represents nor warrants that such          */
/* information is accurate or complete, and it must not be relied upon as such.    */
/* This information was prepared for informational purposes and is for the use     */
/* by SMIC's customer only. SMIC reserves the right to make changes in the         */  
/* information at any time without notice.                                         */  
/*   No part of this information may be reproduced, transmitted, transcribed,      */  
/* stored in a retrieval system, or translated into any human or computer          */ 
/* language, in any form or by any means, electronic, mechanical, magnetic,        */  
/* optical, chemical, manual, or otherwise, without the prior written consent of   */
/* SMIC. Any unauthorized use or disclosure of this material is strictly           */  
/* prohibited and may be unlawful. By accepting this material, the receiving       */  
/* party shall be deemed to have acknowledged, accepted, and agreed to be bound    */
/* by the foregoing limitations and restrictions. Thank you.                       */  
/*                                                                                 */  

`timescale 1ns/1ps
`celldefine

module S018V3EBCDSP_X8Y4D32_PR(
                          Q,
			  CLK,
			  CEN,
			  WEN,
			  A,
			  D);

  parameter	Bits = 32;
  parameter	Word_Depth = 32;
  parameter	Add_Width = 5;

  output [Bits-1:0]      	Q;
  input		   		CLK;
  input		   		CEN;
  input		   		WEN;
  input	[Add_Width-1:0] 	A;
  input	[Bits-1:0] 		D;

  wire [Bits-1:0] 	Q_int;
  wire [Add_Width-1:0] 	A_int;
  wire                 	CLK_int;
  wire                 	CEN_int;
  wire                 	WEN_int;
  wire [Bits-1:0] 	D_int;

  reg  [Bits-1:0] 	Q_latched;
  reg  [Add_Width-1:0] 	A_latched;
  reg  [Bits-1:0] 	D_latched;
  reg                  	CEN_latched;
  reg                  	LAST_CLK;
  reg                  	WEN_latched;

  reg 			A0_flag;
  reg 			A1_flag;
  reg 			A2_flag;
  reg 			A3_flag;
  reg 			A4_flag;

  reg                	CEN_flag;
  reg                   CLK_CYC_flag;
  reg                   CLK_H_flag;
  reg                   CLK_L_flag;

  reg 			D0_flag;
  reg 			D1_flag;
  reg 			D2_flag;
  reg 			D3_flag;
  reg 			D4_flag;
  reg 			D5_flag;
  reg 			D6_flag;
  reg 			D7_flag;
  reg 			D8_flag;
  reg 			D9_flag;
  reg 			D10_flag;
  reg 			D11_flag;
  reg 			D12_flag;
  reg 			D13_flag;
  reg 			D14_flag;
  reg 			D15_flag;
  reg 			D16_flag;
  reg 			D17_flag;
  reg 			D18_flag;
  reg 			D19_flag;
  reg 			D20_flag;
  reg 			D21_flag;
  reg 			D22_flag;
  reg 			D23_flag;
  reg 			D24_flag;
  reg 			D25_flag;
  reg 			D26_flag;
  reg 			D27_flag;
  reg 			D28_flag;
  reg 			D29_flag;
  reg 			D30_flag;
  reg 			D31_flag;

  reg                   WEN_flag; 
  reg [Add_Width-1:0]   A_flag;
  reg [Bits-1:0]        D_flag;
  reg                   LAST_CEN_flag;
  reg                   LAST_WEN_flag;
  reg [Add_Width-1:0]   LAST_A_flag;
  reg [Bits-1:0]        LAST_D_flag;

  reg                   LAST_CLK_CYC_flag;
  reg                   LAST_CLK_H_flag;
  reg                   LAST_CLK_L_flag;

  wire                  CE_flag;
  wire                  WR_flag;
  reg    [Bits-1:0] 	mem_array[Word_Depth-1:0];

  integer      i;
  integer      n;

  buf dout_buf[Bits-1:0] (Q, Q_int);
  buf (CLK_int, CLK);
  buf (CEN_int, CEN);
  buf (WEN_int, WEN);
  buf a_buf[Add_Width-1:0] (A_int, A);
  buf din_buf[Bits-1:0] (D_int, D);   

  assign Q_int=Q_latched;
  assign CE_flag=!CEN_int;
  assign WR_flag=(!CEN_int && !WEN_int);

  always @(CLK_int)
    begin
      casez({LAST_CLK, CLK_int})
        2'b01: begin
          CEN_latched = CEN_int;
          WEN_latched = WEN_int;
          A_latched = A_int;
          D_latched = D_int;
          rw_mem;
        end
        2'b10,
        2'bx?,
        2'b00,
        2'b11: ;
        2'b?x: begin
	  for(i=0;i<Word_Depth;i=i+1)
    	    mem_array[i]={Bits{1'bx}};
    	  Q_latched={Bits{1'bx}};
          rw_mem;
          end
      endcase
    LAST_CLK=CLK_int;
   end

  always @(CEN_flag
           	or WEN_flag
		or A0_flag
		or A1_flag
		or A2_flag
		or A3_flag
		or A4_flag
		or D0_flag
		or D1_flag
		or D2_flag
		or D3_flag
		or D4_flag
		or D5_flag
		or D6_flag
		or D7_flag
		or D8_flag
		or D9_flag
		or D10_flag
		or D11_flag
		or D12_flag
		or D13_flag
		or D14_flag
		or D15_flag
		or D16_flag
		or D17_flag
		or D18_flag
		or D19_flag
		or D20_flag
		or D21_flag
		or D22_flag
		or D23_flag
		or D24_flag
		or D25_flag
		or D26_flag
		or D27_flag
		or D28_flag
		or D29_flag
		or D30_flag
		or D31_flag
           	or CLK_CYC_flag
           	or CLK_H_flag
           	or CLK_L_flag)
    begin
      update_flag_bus;
      CEN_latched = (CEN_flag!==LAST_CEN_flag) ? 1'bx : CEN_latched ;
      WEN_latched = (WEN_flag!==LAST_WEN_flag) ? 1'bx : WEN_latched ;
      for (n=0; n<Add_Width; n=n+1)
      A_latched[n] = (A_flag[n]!==LAST_A_flag[n]) ? 1'bx : A_latched[n] ;
      for (n=0; n<Bits; n=n+1)
      D_latched[n] = (D_flag[n]!==LAST_D_flag[n]) ? 1'bx : D_latched[n] ;
      LAST_CEN_flag = CEN_flag;
      LAST_WEN_flag = WEN_flag;
      LAST_A_flag = A_flag;
      LAST_D_flag = D_flag;
      LAST_CLK_CYC_flag = CLK_CYC_flag;
      LAST_CLK_H_flag = CLK_H_flag;
      LAST_CLK_L_flag = CLK_L_flag;
      rw_mem;
   end
      
  task rw_mem;
    begin
      if(CEN_latched==1'b0)
        begin
	  if(WEN_latched==1'b1) 	
   	    begin
   	      if(^(A_latched)==1'bx)
   	        Q_latched={Bits{1'bx}};
   	      else
		Q_latched=mem_array[A_latched];
       	    end
          else if(WEN_latched==1'b0)
   	    begin
   	      if(^(A_latched)==1'bx)
   	        begin
                  x_mem;
   	          Q_latched={Bits{1'bx}};
   	        end   	        
   	      else
		begin
   	          mem_array[A_latched]=D_latched;
   	          Q_latched=mem_array[A_latched];
   	        end
   	    end
	  else 
     	    begin
   	      Q_latched={Bits{1'bx}};
   	      if(^(A_latched)===1'bx)
                for(i=0;i<Word_Depth;i=i+1)
   		  mem_array[i]={Bits{1'bx}};   	        
              else
		mem_array[A_latched]={Bits{1'bx}};
   	    end
	end  	    	    
      else if(CEN_latched===1'bx)
        begin
	  if(WEN_latched===1'b1)
   	    Q_latched={Bits{1'bx}};
	  else 
	    begin
   	      Q_latched={Bits{1'bx}};
	      if(^(A_latched)===1'bx)
                x_mem;
              else
		mem_array[A_latched]={Bits{1'bx}};
   	    end	      	    	  
        end
    end
  endtask
      
   task x_mem;
   begin
     for(i=0;i<Word_Depth;i=i+1)
     mem_array[i]={Bits{1'bx}};
   end
   endtask

  task update_flag_bus;
  begin
    A_flag = {
		A4_flag,
		A3_flag,
		A2_flag,
		A1_flag,
            A0_flag};
    D_flag = {
		D31_flag,
		D30_flag,
		D29_flag,
		D28_flag,
		D27_flag,
		D26_flag,
		D25_flag,
		D24_flag,
		D23_flag,
		D22_flag,
		D21_flag,
		D20_flag,
		D19_flag,
		D18_flag,
		D17_flag,
		D16_flag,
		D15_flag,
		D14_flag,
		D13_flag,
		D12_flag,
		D11_flag,
		D10_flag,
		D9_flag,
		D8_flag,
		D7_flag,
		D6_flag,
		D5_flag,
		D4_flag,
		D3_flag,
		D2_flag,
		D1_flag,
            D0_flag};
   end
   endtask

  specify
    (posedge CLK => (Q[0] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[1] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[2] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[3] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[4] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[5] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[6] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[7] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[8] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[9] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[10] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[11] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[12] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[13] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[14] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[15] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[16] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[17] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[18] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[19] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[20] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[21] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[22] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[23] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[24] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[25] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[26] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[27] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[28] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[29] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[30] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[31] : 1'bx))=(1.000,1.000);
    $setuphold(posedge CLK &&& CE_flag,posedge A[0],0.500,0.250,A0_flag);
    $setuphold(posedge CLK &&& CE_flag,negedge A[0],0.500,0.250,A0_flag);
    $setuphold(posedge CLK &&& CE_flag,posedge A[1],0.500,0.250,A1_flag);
    $setuphold(posedge CLK &&& CE_flag,negedge A[1],0.500,0.250,A1_flag);
    $setuphold(posedge CLK &&& CE_flag,posedge A[2],0.500,0.250,A2_flag);
    $setuphold(posedge CLK &&& CE_flag,negedge A[2],0.500,0.250,A2_flag);
    $setuphold(posedge CLK &&& CE_flag,posedge A[3],0.500,0.250,A3_flag);
    $setuphold(posedge CLK &&& CE_flag,negedge A[3],0.500,0.250,A3_flag);
    $setuphold(posedge CLK &&& CE_flag,posedge A[4],0.500,0.250,A4_flag);
    $setuphold(posedge CLK &&& CE_flag,negedge A[4],0.500,0.250,A4_flag);
    $setuphold(posedge CLK,posedge CEN,0.500,0.250,CEN_flag);
    $setuphold(posedge CLK,negedge CEN,0.500,0.250,CEN_flag);
    $period(posedge CLK,3.284,CLK_CYC_flag);
    $width(posedge CLK,0.985,0,CLK_H_flag);
    $width(negedge CLK,0.985,0,CLK_L_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[0],0.500,0.250,D0_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[0],0.500,0.250,D0_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[1],0.500,0.250,D1_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[1],0.500,0.250,D1_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[2],0.500,0.250,D2_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[2],0.500,0.250,D2_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[3],0.500,0.250,D3_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[3],0.500,0.250,D3_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[4],0.500,0.250,D4_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[4],0.500,0.250,D4_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[5],0.500,0.250,D5_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[5],0.500,0.250,D5_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[6],0.500,0.250,D6_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[6],0.500,0.250,D6_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[7],0.500,0.250,D7_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[7],0.500,0.250,D7_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[8],0.500,0.250,D8_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[8],0.500,0.250,D8_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[9],0.500,0.250,D9_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[9],0.500,0.250,D9_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[10],0.500,0.250,D10_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[10],0.500,0.250,D10_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[11],0.500,0.250,D11_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[11],0.500,0.250,D11_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[12],0.500,0.250,D12_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[12],0.500,0.250,D12_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[13],0.500,0.250,D13_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[13],0.500,0.250,D13_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[14],0.500,0.250,D14_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[14],0.500,0.250,D14_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[15],0.500,0.250,D15_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[15],0.500,0.250,D15_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[16],0.500,0.250,D16_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[16],0.500,0.250,D16_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[17],0.500,0.250,D17_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[17],0.500,0.250,D17_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[18],0.500,0.250,D18_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[18],0.500,0.250,D18_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[19],0.500,0.250,D19_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[19],0.500,0.250,D19_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[20],0.500,0.250,D20_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[20],0.500,0.250,D20_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[21],0.500,0.250,D21_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[21],0.500,0.250,D21_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[22],0.500,0.250,D22_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[22],0.500,0.250,D22_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[23],0.500,0.250,D23_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[23],0.500,0.250,D23_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[24],0.500,0.250,D24_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[24],0.500,0.250,D24_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[25],0.500,0.250,D25_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[25],0.500,0.250,D25_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[26],0.500,0.250,D26_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[26],0.500,0.250,D26_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[27],0.500,0.250,D27_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[27],0.500,0.250,D27_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[28],0.500,0.250,D28_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[28],0.500,0.250,D28_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[29],0.500,0.250,D29_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[29],0.500,0.250,D29_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[30],0.500,0.250,D30_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[30],0.500,0.250,D30_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[31],0.500,0.250,D31_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[31],0.500,0.250,D31_flag);
    $setuphold(posedge CLK &&& CE_flag,posedge WEN,0.500,0.250,WEN_flag);
    $setuphold(posedge CLK &&& CE_flag,negedge WEN,0.500,0.250,WEN_flag);
  endspecify

endmodule

`endcelldefine
```

### `rtl/sram_32x32.v`

```verilog
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
```

