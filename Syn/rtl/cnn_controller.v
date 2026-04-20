`timescale 1ns / 1ps

// ==========================================================================
// 模块名称: cnn_controller (全局大脑 / 调度中心)
// 功能描述: 
//   1. 控制芯片在 Conv1、Depthwise(DW)、Pointwise(PW)、Maxpool、FC 五种模式间平滑切换。
//   2. 踩准节拍：控制 Line Buffer (行缓存) 何时滑动、何时暂停。
//   3. 独立控制：为 Maxpool 单元让出控制权，并执行 FC 层所需的展平(Flatten)提取。
// ==========================================================================

module cnn_controller (
    input  wire         clk,             // 全局时钟 (100MHz)
    input  wire         rst_n,           // 全局复位信号 (低电平有效)
    input  wire         start,           // 外部触发信号：拉高一拍表示开始处理一帧图像
    input  wire         window_valid,    // 来自 Line Buffer: 为 1 表示 3x3 或 11x7 窗口内数据已填满且合法
    
    // --- 🌟 Maxpool 独立加速单元交互信号 ---
    output reg          pool_start,      // 告知 Maxpool 单元开始池化计算
    input  wire         pool_done,       // Maxpool 单元返回的计算完成信号
    
    // --- 给 MAC 阵列的控制信号 ---
    output reg  [1:0]   layer_mode,      // 模式: 00=Conv1, 01=DW, 10=PW, 11=FC
    
    // --- 给 Line Buffer 的控制信号 ---
    output reg          line_buf_en,     // 1: 允许窗口滑动进新数据; 0: 冻结窗口数据不动
    
    // --- 给后处理模块与外部的握手信号 ---
    output reg          mac_valid,       // 1: 告知后处理模块“当前周期的MAC输出有效，请进行 ReLU 并写回 SRAM”
    output reg          done,            // 1: 整帧网络前向推理彻底完成
    
    // --- SRAM 地址生成 (AGU) ---
    output reg  [1:0]   sram_route_sel,  // 0:输入->Pong, 1:Pong->Ping, 2:Ping->Pong, 3:Maxpool接管
    output reg  [9:0]   act_raddr,       // 特征图 SRAM 读取地址
    output reg  [9:0]   act_waddr,       // 特征图 SRAM 写入地址
    output reg  [3:0]   ch_grp_cnt       // 分组计数器 (用于通道折叠和 FC 神经元索引)
);

    // ==========================================================================
    // 第一部分：状态机定义 (FSM States)
    // ==========================================================================
    localparam ST_IDLE    = 3'd0; // 待机状态
    localparam ST_CONV1   = 3'd1; // 算第一层 (常规卷积)
    localparam ST_DW      = 3'd2; // 算第二层 (深度可分离卷积)
    localparam ST_PW      = 3'd3; // 算第三层 (逐点卷积)
    localparam ST_MAXPOOL = 3'd4; // 🌟 挂起等待池化层完成
    localparam ST_FC_LOAD = 3'd5; // 🌟 为全连接层预装载 9 个像素进 Line Buffer
    localparam ST_FC_CALC = 3'd6; // 🌟 全连接层矩阵向量乘法计算
    localparam ST_DONE    = 3'd7; // 完成状态
    
    reg [2:0] current_state, next_state;

    // ==========================================================================
    // 第二部分：核心嵌套计数器与状态标志
    // ==========================================================================
    reg [6:0] spatial_cnt;  
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
                // PW 结束后，进入 MAXPOOL 状态让出控制权
                if (spatial_cnt == 7'd35 && ch_grp_cnt == 4'd3 && window_valid) 
                    next_state = ST_MAXPOOL;
            end
            
            ST_MAXPOOL: begin
                // 等待独立池化单元拉高完成信号
                if (pool_done) next_state = ST_FC_LOAD;
            end
            
            ST_FC_LOAD: begin
                // 预装载 9 个像素 (地址 0~8)，装满后立刻进入计算状态
                if (spatial_cnt == 7'd8 && !is_prefetching) 
                    next_state = ST_FC_CALC;
            end
            
            ST_FC_CALC: begin
                // 计算完最后 2 个输出神经元后，全网推理结束！
                if (ch_grp_cnt == 4'd1) 
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
            is_prefetching <= 1'b0; 
            pool_start     <= 1'b0;
        end else begin
            case (current_state)
                
                // -------------------------------------------------------------
                // 【待机状态】
                // -------------------------------------------------------------
                ST_IDLE: begin
                    done       <= 1'b0;
                    pool_start <= 1'b0;
                    if (start) begin
                        spatial_cnt    <= 7'd0;
                        ch_grp_cnt     <= 4'd0;
                        act_raddr      <= 10'd0; 
                        act_waddr      <= 10'd0; 
                        sram_route_sel <= 2'd0; 
                        line_buf_en    <= 1'b0;  
                        is_prefetching <= 1'b1;  
                    end
                end
                
                // -------------------------------------------------------------
                // 【第一层：常规卷积】
                // -------------------------------------------------------------
                ST_CONV1: begin
                    layer_mode <= 2'b00; 
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
                            
                            // 🌟 核心分水岭：PW 结束，进入池化层
                            if (spatial_cnt == 7'd35) begin
                                mac_valid      <= 1'b0; 
                                line_buf_en    <= 1'b0;
                                sram_route_sel <= 2'd3; // 切换 MUX，由 Maxpool 接管 SRAM
                                pool_start     <= 1'b1; // 发送起跑脉冲
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
                // 【第四层：池化挂起等待】
                // -------------------------------------------------------------
                ST_MAXPOOL: begin
                    pool_start <= 1'b0; // 脉冲只需一拍
                    if (pool_done) begin
                        // 池化结束，池化结果被存在了 Ping 中。切回原有的控制通路准备读。
                        sram_route_sel <= 2'd2; // 路由：读取 Ping
                        act_raddr      <= 10'd0;
                        spatial_cnt    <= 7'd0;
                        is_prefetching <= 1'b1; // 为接下来的 FC 预读第一拍
                    end
                end
                
                // -------------------------------------------------------------
                // 【第五层装载：全连接层特征图展平装填】
                // -------------------------------------------------------------
                ST_FC_LOAD: begin
                    layer_mode <= 2'b11; // 11 即 2'd3 (FC模式)
                    
                    if (is_prefetching) begin
                        act_raddr      <= act_raddr + 1'b1;
                        line_buf_en    <= 1'b1;
                        is_prefetching <= 1'b0;
                    end else begin
                        line_buf_en <= 1'b1; // 强行拉高行缓存使能，把池化后的 9 个像素吸满
                        act_raddr   <= act_raddr + 1'b1;
                        
                        if (spatial_cnt == 7'd8) begin
                            spatial_cnt <= 7'd0;
                            ch_grp_cnt  <= 4'd0;
                            line_buf_en <= 1'b0; // 吸满 9 个，立刻冻结！
                        end else begin
                            spatial_cnt <= spatial_cnt + 1'b1;
                        end
                    end
                end

                // -------------------------------------------------------------
                // 【第五层计算：1个时钟周期摧毁 1 个全连接神经元】
                // -------------------------------------------------------------
                ST_FC_CALC: begin
                    layer_mode  <= 2'b11;
                    line_buf_en <= 1'b0;  // 持续冻结窗口
                    mac_valid   <= 1'b1;  // 连续 2 拍，MAC 输出均有效！
                    
                    if (ch_grp_cnt == 4'd1) begin
                        // 2 个神经元全算完了，准备功德圆满！
                        ch_grp_cnt <= 4'd0;
                        // ✅ 去掉了这里的 mac_valid <= 0，让它保持 1，完成第二发子弹的发射
                    end else begin
                        // 下一拍算下一个神经元
                        ch_grp_cnt <= ch_grp_cnt + 1'b1;
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