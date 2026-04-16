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
    output reg  [3:0]   ch_grp_cnt       // 【新增输出】将内部的分组计数器引出给 ROM
);

    // ==========================================================================
    // 第一部分：状态机定义 (FSM States)
    // ==========================================================================
    localparam ST_IDLE  = 3'd0; // 待机状态：等待 start 信号
    localparam ST_CONV1 = 3'd1; // 算第一层 (常规卷积)
    localparam ST_DW    = 3'd2; // 算第二层 (深度可分离卷积)
    localparam ST_PW    = 3'd3; // 算第三层 (逐点卷积)
    localparam ST_DONE  = 3'd4; // 完成状态
    
    reg [2:0] current_state, next_state;

    // ==========================================================================
    // 第二部分：核心嵌套计数器与状态标志
    // ==========================================================================
    reg [6:0] spatial_cnt;  
    
    // 🌟 新增：预读标志位。1: 正在等待 SRAM 首地址数据的 1 拍延迟
    reg       is_prefetching; 

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
        next_state = current_state; 
        
        case (current_state)
            ST_IDLE: begin
                if (start) next_state = ST_CONV1; 
            end
            
            ST_CONV1: begin
                if (spatial_cnt == 7'd79 && ch_grp_cnt == 4'd7 && window_valid)
                    next_state = ST_DW;
            end
            
            ST_DW: begin
                if (spatial_cnt == 7'd35 && window_valid)
                    next_state = ST_PW;
            end
            
            ST_PW: begin
                if (spatial_cnt == 7'd35 && ch_grp_cnt == 4'd3 && window_valid) 
                    next_state = ST_DONE;
            end
            
            ST_DONE: begin
                next_state = ST_IDLE; 
            end
            
            default: next_state = ST_IDLE;
        endcase
    end

    // ==========================================================================
    // 三段式状态机 段3：数据通路控制与地址生成 (最核心的时序逻辑)
    // ==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spatial_cnt    <= 7'd0;
            ch_grp_cnt     <= 4'd0;
            layer_mode     <= 2'b00;
            line_buf_en    <= 1'b0;
            mac_valid      <= 1'b0;
            done           <= 1'b0;
            sram_route_sel <= 2'd0;
            act_raddr      <= 10'd0;
            act_waddr      <= 10'd0;
            is_prefetching <= 1'b0; // 🌟 新增：复位预读标志
        end else begin
            case (current_state)
                
                // -------------------------------------------------------------
                // 【待机状态】
                // -------------------------------------------------------------
                ST_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        spatial_cnt    <= 7'd0;
                        ch_grp_cnt     <= 4'd0;
                        act_raddr      <= 10'd0; 
                        act_waddr      <= 10'd0; 
                        sram_route_sel <= 2'd0; 
                        
                        // 🌟 修改：第一拍坚决不打开行缓存，而是立起预读 Flag
                        line_buf_en    <= 1'b0;  
                        is_prefetching <= 1'b1;  
                    end
                end
                
                // -------------------------------------------------------------
                // 【第一层：常规卷积】
                // -------------------------------------------------------------
                ST_CONV1: begin
                    layer_mode <= 2'b00; 
                    
                    // 🌟 新增：拦截预读拍
                    if (is_prefetching) begin
                        act_raddr      <= act_raddr + 1'b1; // 发出下一个地址
                        line_buf_en    <= 1'b1;             // 打开门，准备接收首地址数据
                        is_prefetching <= 1'b0;             // 预读完成
                    end 
                    else if (!window_valid) begin
                        line_buf_en <= 1'b1; 
                        mac_valid   <= 1'b0; 
                        act_raddr   <= act_raddr + 1'b1; 
                    end 
                    else begin
                        line_buf_en <= 1'b0; 
                        mac_valid   <= 1'b1; 
                        act_waddr   <= act_waddr + 1'b1;    
                        
                        if (ch_grp_cnt == 4'd7) begin
                            ch_grp_cnt  <= 4'd0;
                            spatial_cnt <= spatial_cnt + 1'b1;
                            
                            line_buf_en <= 1'b1; 
                            act_raddr   <= act_raddr + 1'b1; 
                            
                            if (spatial_cnt == 7'd79) begin
                                spatial_cnt    <= 7'd0;
                                ch_grp_cnt     <= 4'd0;
                                act_raddr      <= 10'd0; 
                                act_waddr      <= 10'd0; 
                                sram_route_sel <= 2'd1;  
                                mac_valid      <= 1'b0;  
                                
                                // 🌟 新增：层切换瞬间强行关门，为下一层做预读准备
                                line_buf_en    <= 1'b0;  
                                is_prefetching <= 1'b1;  
                            end
                        end else begin
                            ch_grp_cnt <= ch_grp_cnt + 1'b1;
                        end
                    end
                end
                
                // -------------------------------------------------------------
                // 【第二层：深度可分离卷积】
                // -------------------------------------------------------------
                ST_DW: begin
                    layer_mode <= 2'b01; 
                    
                    // 🌟 新增：拦截预读拍
                    if (is_prefetching) begin
                        act_raddr      <= act_raddr + 1'b1;
                        line_buf_en    <= 1'b1;
                        is_prefetching <= 1'b0;
                    end 
                    else if (!window_valid) begin
                        line_buf_en <= 1'b1;
                        mac_valid   <= 1'b0;
                        act_raddr   <= act_raddr + 1'b1;
                    end 
                    else begin
                        line_buf_en  <= 1'b1;  
                        mac_valid    <= 1'b1;
                        
                        act_waddr    <= act_waddr + 1'b1;
                        act_raddr    <= act_raddr + 1'b1;
                        spatial_cnt  <= spatial_cnt + 1'b1;
                        
                        if (spatial_cnt == 7'd35) begin
                            spatial_cnt    <= 7'd0;
                            act_raddr      <= 10'd0; 
                            act_waddr      <= 10'd0; 
                            sram_route_sel <= 2'd2;  
                            mac_valid      <= 1'b0;
                            
                            // 🌟 新增：为下一层做预读准备
                            line_buf_en    <= 1'b0;  
                            is_prefetching <= 1'b1;  
                        end
                    end
                end
                
                // -------------------------------------------------------------
                // 【第三层：逐点卷积】
                // -------------------------------------------------------------
                ST_PW: begin
                    layer_mode <= 2'b10; 
                    
                    // 🌟 新增：拦截预读拍
                    if (is_prefetching) begin
                        act_raddr      <= act_raddr + 1'b1;
                        line_buf_en    <= 1'b1;
                        is_prefetching <= 1'b0;
                    end 
                    else if (window_valid) begin
                        line_buf_en <= 1'b0; 
                        mac_valid   <= 1'b1;
                        act_waddr   <= act_waddr + 1'b1;
                        
                        if (ch_grp_cnt == 4'd3) begin
                            ch_grp_cnt  <= 4'd0;
                            spatial_cnt <= spatial_cnt + 1'b1;
                            line_buf_en <= 1'b1;
                            act_raddr   <= act_raddr + 1'b1;
                            
                            if (spatial_cnt == 7'd35) begin
                                mac_valid <= 1'b0; 
                                // (由于直接进入 DONE 状态，这里不需要置位 is_prefetching)
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
                    done        <= 1'b1; 
                    line_buf_en <= 1'b0;
                    mac_valid   <= 1'b0;
                end
                
            endcase
        end
    end

endmodule