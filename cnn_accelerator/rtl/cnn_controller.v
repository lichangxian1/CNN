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