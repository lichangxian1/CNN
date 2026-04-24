`timescale 1ns / 1ps

module cnn_controller (
    input  wire         clk,             
    input  wire         rst_n,           
    input  wire         start,           
    input  wire         window_valid,    
    
    output reg          pool_start,      
    input  wire         pool_done,       
    
    output reg  [1:0]   layer_mode,      
    output reg          line_buf_en,     
    output reg          mac_valid,       
    output reg          done,            
    
    output reg  [1:0]   sram_route_sel,  
    output reg  [9:0]   act_raddr,       
    output reg  [9:0]   act_waddr,       
    output reg  [3:0]   ch_grp_cnt       
);

    // ==========================================
    // 1. 状态定义 (扩展为 4-bit, 加入 3 个独立排空态)
    // ==========================================
    localparam ST_IDLE    = 4'd0;
    localparam ST_CONV1   = 4'd1;
    localparam ST_DRAIN1  = 4'd2; // Conv1 -> DW 排空
    localparam ST_DW      = 4'd3;
    localparam ST_DRAIN2  = 4'd4; // DW -> PW 排空
    localparam ST_PW      = 4'd5;
    localparam ST_DRAIN3  = 4'd6; // PW -> Maxpool 排空
    localparam ST_MAXPOOL = 4'd7;
    localparam ST_FC_LOAD = 4'd8;
    localparam ST_FC_CALC = 4'd9;
    localparam ST_DONE    = 4'd10;
    
    reg [3:0] current_state, next_state;

    // ==========================================
    // 2. 核心计数器与标志位
    // ==========================================
    reg [6:0] spatial_cnt;
    reg       is_prefetching; 
    reg [2:0] drain_cnt;
    reg       shift_wait;     // 🌟 核心悬停寄存器

    // ==========================================
    // 3. 状态机跳转逻辑 (组合逻辑)
    // ==========================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) current_state <= ST_IDLE;
        else        current_state <= next_state;
    end

    always @(*) begin
        next_state = current_state;
        case (current_state)
            ST_IDLE:    if (start) next_state = ST_CONV1;
            ST_CONV1:   if (spatial_cnt == 7'd79 && ch_grp_cnt == 4'd7 && mac_valid) next_state = ST_DRAIN1;
            ST_DRAIN1:  if (drain_cnt == 3'd5) next_state = ST_DW;
            ST_DW:      if (spatial_cnt == 7'd35 && mac_valid) next_state = ST_DRAIN2;
            ST_DRAIN2:  if (drain_cnt == 3'd5) next_state = ST_PW;
            ST_PW:      if (spatial_cnt == 7'd35 && ch_grp_cnt == 4'd3 && mac_valid) next_state = ST_DRAIN3;
            ST_DRAIN3:  if (drain_cnt == 3'd5) next_state = ST_MAXPOOL;
            ST_MAXPOOL: if (pool_done) next_state = ST_FC_LOAD;
            ST_FC_LOAD: if (spatial_cnt == 7'd10) next_state = ST_FC_CALC;
            ST_FC_CALC: if (ch_grp_cnt == 4'd1 && mac_valid) next_state = ST_DONE;
            ST_DONE:    next_state = ST_IDLE;
            default:    next_state = ST_IDLE;
        endcase
    end

    // ==========================================
    // 4. 数据通路控制逻辑 (时序逻辑)
    // ==========================================
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
            drain_cnt      <= 3'd0;
            shift_wait     <= 1'b0;
        end else begin
            case (current_state)
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
                        shift_wait     <= 1'b0;
                    end
                end
                
                // -------------------------------------------------------------
                // 【第一层：常规卷积】
                // -------------------------------------------------------------
                ST_CONV1: begin
                    layer_mode <= 2'b00;
                    if (is_prefetching) begin
                        is_prefetching <= 1'b0;
                        line_buf_en    <= 1'b1;             
                        act_raddr      <= act_raddr + 1'b1;
                        shift_wait     <= 1'b1;  
                    end 
                    else if (shift_wait) begin
                        shift_wait  <= 1'b0;
                        line_buf_en <= 1'b0;
                        mac_valid   <= 1'b0;
                    end
                    else if (!window_valid) begin
                        line_buf_en <= 1'b1;
                        mac_valid   <= 1'b0; 
                        act_raddr   <= act_raddr + 1'b1;
                        // 如果马上要填满 window (此拍将要置 1)，就不进 shift_wait，直接转而停歇
                        shift_wait  <= 1'b1;     
                    end 
                    else begin
                        mac_valid <= 1'b1;
                        if (!mac_valid) begin
                            ch_grp_cnt  <= 4'd0;
                            line_buf_en <= 1'b0;
                        end else begin
                            act_waddr <= act_waddr + 1'b1;
                            if (ch_grp_cnt == 4'd7) begin
                                ch_grp_cnt  <= 4'd0;
                                spatial_cnt <= spatial_cnt + 1'b1;
                                
                                if (spatial_cnt == 7'd79) begin
                                    spatial_cnt    <= 7'd0;
                                    act_raddr      <= 10'd0;
                                    act_waddr      <= 10'd0; 
                                    mac_valid      <= 1'b0;  
                                    line_buf_en    <= 1'b0;  
                                    drain_cnt      <= 3'd0;
                                end else begin
                                    line_buf_en <= 1'b1; 
                                    act_raddr   <= act_raddr + 1'b1;
                                    // 给下一像素预读取一位
                                    shift_wait  <= 1'b1; 
                                    mac_valid   <= 1'b0; 
                                end
                            end else begin
                                line_buf_en <= 1'b0;
                                ch_grp_cnt  <= ch_grp_cnt + 1'b1;
                            end
                        end
                    end
                end

                // --- 排空 1 ---
                ST_DRAIN1: begin
                    mac_valid <= 1'b0;
                    
                    // 🌟 终极修复：在排空态的第 0 拍就切换路由和模式！
                    // 这给 5 级写流水线留足了时间，确保下一层开始时 SRAM 读端口已完全释放
                    sram_route_sel <= 2'd1;
                    layer_mode     <= 2'd1;
                    
                    if (drain_cnt == 3'd5) begin
                        is_prefetching <= 1'b1;
                    end else begin
                        drain_cnt <= drain_cnt + 1'b1;
                    end
                end
                
                // -------------------------------------------------------------
                // 【第二层：深度可分离卷积】
                // -------------------------------------------------------------
                ST_DW: begin
                    layer_mode <= 2'b01;
                    if (is_prefetching) begin
                        is_prefetching <= 1'b0;
                        line_buf_en    <= 1'b1;
                        act_raddr      <= act_raddr + 1'b1;
                        shift_wait     <= 1'b1;
                    end 
                    else if (shift_wait) begin
                        shift_wait  <= 1'b0;
                        line_buf_en <= 1'b0;
                        mac_valid   <= 1'b0;
                    end
                    else if (!window_valid) begin
                        line_buf_en <= 1'b1;
                        mac_valid   <= 1'b0;
                        act_raddr   <= act_raddr + 1'b1;
                        shift_wait  <= 1'b1;
                    end 
                    else begin
                        mac_valid <= 1'b1;
                        if (!mac_valid) begin
                            line_buf_en <= 1'b0;
                        end else begin
                            act_waddr    <= act_waddr + 1'b1;
                            spatial_cnt  <= spatial_cnt + 1'b1;
                            
                            if (spatial_cnt == 7'd35) begin
                                spatial_cnt    <= 7'd0;
                                act_raddr      <= 10'd0; 
                                act_waddr      <= 10'd0; 
                                mac_valid      <= 1'b0;
                                line_buf_en    <= 1'b0;  
                                drain_cnt      <= 3'd0;
                                shift_wait     <= 1'b0;
                            end else begin
                                line_buf_en  <= 1'b1;
                                act_raddr    <= act_raddr + 1'b1;
                                shift_wait   <= 1'b1; 
                                mac_valid    <= 1'b0; 
                            end
                        end
                    end
                end

                // --- 排空 2 ---
                ST_DRAIN2: begin
                    mac_valid <= 1'b0;
                    
                    // 🌟 同理，提前 5 拍切换
                    sram_route_sel <= 2'd2;
                    layer_mode     <= 2'd2;
                    
                    if (drain_cnt == 3'd5) begin
                        is_prefetching <= 1'b1;
                    end else begin
                        drain_cnt <= drain_cnt + 1'b1;
                    end
                end

                // -------------------------------------------------------------
                // 【第三层：逐点卷积】
                // -------------------------------------------------------------
                ST_PW: begin
                    layer_mode <= 2'b10;
                    if (is_prefetching) begin
                        is_prefetching <= 1'b0;
                        line_buf_en    <= 1'b1;
                        act_raddr      <= act_raddr + 1'b1;
                        shift_wait     <= 1'b1;
                    end 
                    else if (shift_wait) begin
                        shift_wait  <= 1'b0;
                        line_buf_en <= 1'b0; 
                        mac_valid   <= 1'b0;
                    end
                    else if (!window_valid) begin
                        line_buf_en <= 1'b1;
                        mac_valid   <= 1'b0;
                        act_raddr   <= act_raddr + 1'b1;
                        shift_wait  <= 1'b1;
                    end 
                    else begin
                        mac_valid <= 1'b1;
                        if (!mac_valid) begin
                            ch_grp_cnt  <= 4'd0;
                            line_buf_en <= 1'b0;
                        end else begin
                            act_waddr <= act_waddr + 1'b1;
                            if (ch_grp_cnt == 4'd3) begin
                                ch_grp_cnt  <= 4'd0;
                                spatial_cnt <= spatial_cnt + 1'b1;
                                
                                if (spatial_cnt == 7'd35) begin
                                    spatial_cnt    <= 7'd0;
                                    act_raddr      <= 10'd0; 
                                    act_waddr      <= 10'd0; 
                                    mac_valid      <= 1'b0;
                                    line_buf_en    <= 1'b0;
                                    drain_cnt      <= 3'd0;
                                    shift_wait     <= 1'b0;
                                end else begin
                                    line_buf_en <= 1'b1;
                                    act_raddr   <= act_raddr + 1'b1;
                                    shift_wait  <= 1'b1;
                                    mac_valid   <= 1'b0;
                                end
                            end else begin
                                line_buf_en <= 1'b0;
                                ch_grp_cnt  <= ch_grp_cnt + 1'b1;
                            end
                        end
                    end
                end

                // --- 排空 3 (并触发池化) ---
                ST_DRAIN3: begin
                    mac_valid <= 1'b0;
                    if (drain_cnt == 3'd5) begin
                        pool_start     <= 1'b1;
                        // 🌟 修复 3：移交 SRAM 读写权，否则池化全在做无用功！
                        sram_route_sel <= 2'd3; 
                    end else begin
                        drain_cnt <= drain_cnt + 1'b1;
                    end
                end

                // -------------------------------------------------------------
                // 【第四层：池化挂起等待】
                // -------------------------------------------------------------
                ST_MAXPOOL: begin
                    pool_start <= 1'b0; // 脉冲只需一拍
                    if (pool_done) begin
                        sram_route_sel <= 2'd2; // 切回 Ping，供下面的 FC 展平读取
                        spatial_cnt    <= 7'd0;
                        // 注意：这里不需要 is_prefetching 了，因为新版 LOAD 逻辑自己处理
                    end
                end
                
                // -------------------------------------------------------------
                // 【第五层装载：全连接层特征图展平装填】
                // -------------------------------------------------------------
                ST_FC_LOAD: begin
                    layer_mode <= 2'b11;
                    
                    // 🌟 修复 4：连续 10 拍无缝读取 (Burst Read)
                    if (spatial_cnt == 7'd0) begin
                        act_raddr   <= 10'd0;
                        line_buf_en <= 1'b0;
                        spatial_cnt <= 7'd1;
                    end 
                    else if (spatial_cnt <= 7'd9) begin
                        act_raddr   <= spatial_cnt; // 发送读地址 1~9
                        line_buf_en <= 1'b1;        // 打开移位缓存吸入数据
                        spatial_cnt <= spatial_cnt + 1'b1;
                    end
                    else if (spatial_cnt == 7'd10) begin
                        line_buf_en <= 1'b0;        // 最后一拍闭合缓存
                        spatial_cnt <= 7'd11; 
                    end
                end

                // -------------------------------------------------------------
                // 【第五层计算：1个时钟周期摧毁 1 个全连接神经元】
                // -------------------------------------------------------------
                ST_FC_CALC: begin
                    layer_mode  <= 2'b11;
                    line_buf_en <= 1'b0;  
                    mac_valid   <= 1'b1;
                    
                    if (!mac_valid) begin
                        ch_grp_cnt <= 4'd0;
                    end else begin
                        if (ch_grp_cnt == 4'd1) begin
                            // comb 组合逻辑会在此处抓取并跳转 ST_DONE
                        end else begin
                            ch_grp_cnt <= ch_grp_cnt + 1'b1;
                        end
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