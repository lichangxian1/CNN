`timescale 1ns / 1ps

// ==========================================================================
// 模块名称: cnn_top (CNN 加速器顶层模块)
// 功能描述: 
//   1. 例化并连接所有子模块：大脑、运算阵列、行缓存、后处理、SRAM。
//   2. 实现 Ping-Pong SRAM 的数据流向动态路由。
// ==========================================================================

module cnn_top (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 start,
    
    // --- 外部输入接口 (例如接收 MFCC 特征图数据) ---
    input  wire [255:0]         ext_act_in,     // 外部输入数据
    input  wire                 ext_act_valid,  // 外部输入有效信号
    
    // --- 外部输出接口 ---
    output wire                 done            // 推理完成信号
);

    // ==========================================
    // 1. 内部互连线网声明 (Interconnect Nets)
    // ==========================================
    // FSM 控制信号
    wire [1:0]  layer_mode;
    wire        line_buf_en;
    wire        mac_valid;
    wire [1:0]  sram_route_sel;
    wire [9:0]  act_raddr, act_waddr;
    wire [11:0] weight_raddr;
    
    // SRAM 接口信号
    wire [255:0] ping_dout, pong_dout;
    reg  [255:0] ping_din, pong_din;
    reg  [9:0]   ping_addr, pong_addr;
    reg          ping_wen, pong_wen;
    wire         ping_cen = 1'b0; // 芯片使能常开
    wire         pong_cen = 1'b0;
    
    // 数据通路信号
    wire [255:0] current_layer_act_in;   // 当前层送到行缓存的输入数据
    wire [2463:0] act_in_flat;           // 行缓存展平后给 MAC 的输入 (2560 bits 省略到 2464)
    wire [2463:0] wgt_in_flat;           // 权重 SRAM 给 MAC 的输入
    wire [1023:0] psum_out_flat;         // MAC 给后处理的 INT32 数据
    wire [511:0]  bias_in_flat;          // 偏置 SRAM 给后处理的 INT16 数据
    
    wire [255:0]  act_out_flat;          // 后处理算完的 INT8 数据 (准备写回 SRAM)
    wire          out_valid;             // 后处理算完的有效信号

    // 行缓存状态
    wire window_valid = 1'b1; // 仿真中需连接行缓存的真实状态，此处为逻辑占位

    // ==========================================
    // 2. Ping-Pong SRAM 动态路由逻辑 (核心灵魂)
    // ==========================================
    // 这里的组合逻辑像“铁路道岔”一样，根据当前计算哪一层，引导数据流向
    
    always @(*) begin
        // 默认状态：防止锁存器
        ping_wen  = 1'b1; // 1为读
        pong_wen  = 1'b1;
        ping_addr = 10'd0;
        pong_addr = 10'd0;
        ping_din  = 256'd0;
        pong_din  = 256'd0;
        
        case (sram_route_sel)
            2'd0: begin
                // 第一层 (Conv1)：从外部读入特征图，结果写到 Pong
                // 此时 Ping SRAM 空闲或用于其他
                pong_wen  = ~out_valid;      // 当输出有效时拉低，写入 Pong
                pong_addr = act_waddr;
                pong_din  = act_out_flat;
            end
            
            2'd1: begin
                // 第二层 (Depthwise)：从 Pong 读入上一层结果，算出结果写到 Ping
                pong_wen  = 1'b1;            // Pong 只读不写
                pong_addr = act_raddr;       // 给 Pong 读地址
                
                ping_wen  = ~out_valid;      // 写入 Ping
                ping_addr = act_waddr;
                ping_din  = act_out_flat;
            end
            
            2'd2: begin
                // 第三层 (Pointwise)：从 Ping 读入结果，算出结果写到 Pong
                ping_wen  = 1'b1;            // Ping 只读不写
                ping_addr = act_raddr;
                
                pong_wen  = ~out_valid;      // 写入 Pong
                pong_addr = act_waddr;
                pong_din  = act_out_flat;
            end
            
            default: ;
        endcase
    end

    // 当前层送往计算阵列的输入数据选择器 (MUX)
    assign current_layer_act_in = (sram_route_sel == 2'd0) ? ext_act_in : 
                                  (sram_route_sel == 2'd1) ? pong_dout : ping_dout;


    // ==========================================
    // 3. 子模块例化 (Sub-module Instantiations)
    // ==========================================

    // 3.1 全局控制器 (大脑)
    cnn_controller u_controller (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (start),
        .window_valid   (window_valid),
        .layer_mode     (layer_mode),
        .line_buf_en    (line_buf_en),
        .mac_valid      (mac_valid),
        .done           (done),
        .sram_route_sel (sram_route_sel),
        .act_raddr      (act_raddr),
        .act_waddr      (act_waddr),
        .weight_raddr   (weight_raddr)
    );

    // 3.2 特征图 SRAM (由于你提供了 sram_32x32，我们用宏参数覆写位宽为 256)
    // Ping 缓存
    sram_32x32 #(
        .Bits(256), .Word_Depth(80), .Add_Width(10)
    ) u_sram_ping (
        .CLK(clk), .CEN(ping_cen), .WEN(ping_wen), .A(ping_addr), .D(ping_din), .Q(ping_dout)
    );

    // Pong 缓存
    sram_32x32 #(
        .Bits(256), .Word_Depth(80), .Add_Width(10)
    ) u_sram_pong (
        .CLK(clk), .CEN(pong_cen), .WEN(pong_wen), .A(pong_addr), .D(pong_din), .Q(pong_dout)
    );

    // 3.3 行缓存 Line Buffer (伪代码连线：接收SRAM数据，吐出展平窗口)
    // (此处应例化我们之前写的 line_buffer.v，为了代码简洁，省去中间展平连线)
    assign act_in_flat = {10{current_layer_act_in}}[2463:0]; // 这是一个占位符，实际需连接 Line Buffer 的输出 p00~p22
    
    // 权重与偏置模块 (此处简化为直接获取，实际工程可能连接外部 ROM 或另设 SRAM)
    assign wgt_in_flat  = 2464'd0; // 假定连到 Weight SRAM_Q
    assign bias_in_flat = 512'd0;  // 假定连到 Bias SRAM_Q

    // 3.4 统一计算阵列 MAC Array
    mac_array u_mac_array (
        .clk            (clk),
        .rst_n          (rst_n),
        .layer_mode     (layer_mode),
        .act_in_flat    (act_in_flat),
        .wgt_in_flat    (wgt_in_flat),
        .psum_out_flat  (psum_out_flat)
    );

    // 3.5 后处理模块 Post Process
    post_process u_post_process (
        .clk            (clk),
        .rst_n          (rst_n),
        .mac_valid      (mac_valid),
        .psum_in_flat   (psum_out_flat),
        .bias_in_flat   (bias_in_flat),
        .quant_M0       (16'sd128),  // 假设量化参数 M0
        .quant_n        (4'd8),      // 假设量化参数 n
        .out_valid      (out_valid),
        .act_out_flat   (act_out_flat)
    );

endmodule