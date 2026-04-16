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
```

### `rtl/cnn_top.v`

```verilog
`timescale 1ns / 1ps

module cnn_top (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 start,
    
    // --- 外部输入接口 ---
    input  wire [255:0]         ext_act_in,     
    input  wire                 ext_act_valid,  
    output wire                 done            
);

    // FSM 控制信号 (原生态 0拍延迟)
    wire [1:0]  layer_mode;
    wire        line_buf_en;
    wire        mac_valid;
    wire [1:0]  sram_route_sel;
    wire [9:0]  act_raddr, act_waddr;
    wire [3:0]  ch_grp_cnt;
    
    // ==========================================
    // 🌟 流水线时序对齐 (Pipeline Synchronization)
    // 解决数据流延迟与控制信号不匹配的核心！
    // ==========================================
    // 1. MAC 阵列自带 2 拍延迟，mac_valid 必须打 2 拍再给后处理
    reg [1:0] mac_valid_pipe;
    
    // 2. 算上后处理的 1 拍，总延迟 3 拍。写地址和模式必须打 3 拍！
    reg [9:0] act_waddr_pipe [0:3];
    reg [1:0] layer_mode_pipe [0:3];
    
    // 3. SRAM 路由信号需要管到最后一次写，所以打 3 拍给写 MUX 用
    reg [1:0] route_sel_pipe [0:2];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mac_valid_pipe <= 2'd0;
            act_waddr_pipe[0] <= 10'd0;  act_waddr_pipe[1] <= 10'd0;  act_waddr_pipe[2] <= 10'd0;
            layer_mode_pipe[0] <= 2'd0;  layer_mode_pipe[1] <= 2'd0;  layer_mode_pipe[2] <= 2'd0;
            route_sel_pipe[0] <= 2'd0;   route_sel_pipe[1] <= 2'd0;   route_sel_pipe[2] <= 2'd0;
        end else begin
            mac_valid_pipe    <= {mac_valid_pipe[0], mac_valid};
            
            act_waddr_pipe[0] <= act_waddr;             act_waddr_pipe[1] <= act_waddr_pipe[0];             act_waddr_pipe[2] <= act_waddr_pipe[1];
            layer_mode_pipe[0]<= layer_mode;            layer_mode_pipe[1]<= layer_mode_pipe[0];            layer_mode_pipe[2]<= layer_mode_pipe[1];
            route_sel_pipe[0] <= sram_route_sel;        route_sel_pipe[1] <= route_sel_pipe[0];             route_sel_pipe[2] <= route_sel_pipe[1];
        end
    end

    // 提取同步后的安全信号
    wire       mac_valid_sync   = mac_valid_pipe[1];
    wire [9:0] act_waddr_sync   = act_waddr_pipe[2];
    wire [1:0] layer_mode_sync  = layer_mode_pipe[2];
    wire [1:0] route_sel_write  = route_sel_pipe[2]; 

    // ==========================================
    // 数据通路与模块连线
    // ==========================================
    wire [255:0] ping_dout, pong_dout;
    reg  [255:0] ping_din, pong_din;
    reg  [9:0]   ping_addr, pong_addr;
    reg          ping_wen, pong_wen;
    
    wire [2463:0] act_in_flat, wgt_in_flat;
    wire [1023:0] psum_out_flat;         
    wire [511:0]  bias_in_flat;          
    wire [255:0]  act_out_flat;          
    wire          out_valid;             
    wire          window_valid;
    
    wire          staging_wen;
    wire [9:0]    staging_waddr;
    wire [255:0]  staging_wdata;

    // 🌟 SRAM 物理地址紧凑转换 (读专用)
    wire [9:0] ping_raddr = (sram_route_sel == 2'd0) ? act_raddr[9:5] : act_raddr;
    
    // 🌟 第一层读出数据的字节切片MUX (从 256bit 抠出 8bit)
    reg [9:0] act_raddr_delay;
    always @(posedge clk) act_raddr_delay <= act_raddr;
    wire [255:0] conv1_act_in = { 248'd0, ping_dout[ act_raddr_delay[4:0] * 8 +: 8 ] };

    wire [255:0] current_layer_act_in = (layer_mode == 2'd0) ? conv1_act_in : 
                                        (sram_route_sel == 2'd1) ? pong_dout : ping_dout;

    // ==========================================
    // 🌟 读写分离的终极 Ping-Pong 路由
    // ==========================================
    always @(*) begin
        ping_wen = 1'b1; ping_addr = 10'd0; ping_din = 256'd0;
        // Ping 写判定 (使用延迟后的 route_sel_write)
        if (route_sel_write == 2'd1) begin
            ping_wen = staging_wen; ping_addr = staging_waddr; ping_din = staging_wdata;
        end 
        // Ping 读判定 (使用实时的 sram_route_sel)
        else if (sram_route_sel == 2'd2 || sram_route_sel == 2'd0) begin
            ping_wen = 1'b1; ping_addr = ping_raddr;
        end
    end

    always @(*) begin
        pong_wen = 1'b1; pong_addr = 10'd0; pong_din = 256'd0;
        // Pong 写判定
        if (route_sel_write == 2'd0 || route_sel_write == 2'd2) begin
            pong_wen = staging_wen; pong_addr = staging_waddr; pong_din = staging_wdata;
        end 
        // Pong 读判定
        else if (sram_route_sel == 2'd1) begin
            pong_wen = 1'b1; pong_addr = act_raddr;
        end
    end

    // ==========================================
    // 模块例化区 (全拼图组装)
    // ==========================================
    cnn_controller u_controller (.clk(clk), .rst_n(rst_n), .start(start), .window_valid(window_valid),
        .layer_mode(layer_mode), .line_buf_en(line_buf_en), .mac_valid(mac_valid), .done(done),
        .sram_route_sel(sram_route_sel), .act_raddr(act_raddr), .act_waddr(act_waddr), .ch_grp_cnt(ch_grp_cnt));

    sram_256x80 u_sram_ping (.CLK(clk), .CEN(1'b0), .WEN(ping_wen), .A(ping_addr), .D(ping_din), .Q(ping_dout));
    sram_256x80 u_sram_pong (.CLK(clk), .CEN(1'b0), .WEN(pong_wen), .A(pong_addr), .D(pong_din), .Q(pong_dout));

    line_buffer u_line_buffer (.clk(clk), .rst_n(rst_n), .layer_mode(layer_mode), .shift_en(line_buf_en),
        .sram_data_in(current_layer_act_in), .window_valid(window_valid), .act_in_flat(act_in_flat));

    param_rom u_param_rom (.clk(clk), .layer_mode(layer_mode), .ch_grp_cnt(ch_grp_cnt),
        .wgt_in_flat(wgt_in_flat), .bias_in_flat(bias_in_flat));

    mac_array u_mac_array (.clk(clk), .rst_n(rst_n), .layer_mode(layer_mode),
        .act_in_flat(act_in_flat), .wgt_in_flat(wgt_in_flat), .psum_out_flat(psum_out_flat));

    post_process u_post_process (.clk(clk), .rst_n(rst_n), .mac_valid(mac_valid_sync), // 🌟 传入延迟对齐的 valid
        .psum_in_flat(psum_out_flat), .bias_in_flat(bias_in_flat), .quant_M0(16'sd128), .quant_n(4'd8),
        .out_valid(out_valid), .act_out_flat(act_out_flat));

    output_staging_buffer u_staging_buffer (.clk(clk), .rst_n(rst_n), 
        .layer_mode_sync(layer_mode_sync), .act_waddr_sync(act_waddr_sync), // 🌟 传入延迟对齐的控制信号
        .out_valid(out_valid), .act_out_flat(act_out_flat),
        .staging_wen(staging_wen), .staging_waddr(staging_waddr), .staging_wdata(staging_wdata));

endmodule
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

### `rtl/post_process.v`

```verilog
`timescale 1ns / 1ps

// ==========================================================================
// 模块名称: post_process (后处理：偏置加法 + 重量化 + ReLU)
// 功能描述: 
//   1. 接收 MAC 阵列输出的 32 个 INT32 累加和。
//   2. 【Stage 1】加上对应通道的 INT16 偏置 (Bias)，并乘以量化乘数 M0。
//   3. 【Stage 2】进行算术右移 n 位 (重量化)。
//   4. 【Stage 2】ReLU 激活: 负数截断为 0。
//   5. 【Stage 2】饱和防溢出处理，最终输出 32 个 INT8 数据拼接而成的 256-bit 向量。
// ==========================================================================

module post_process (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 mac_valid,       // 标志当前输入的 INT32 数据有效
    
    // 输入接口 (来自 MAC 阵列与 SRAM)
    input  wire [1023:0]        psum_in_flat,    // 32 个 32-bit INT32 局部累加和
    input  wire [511:0]         bias_in_flat,    // 32 个 16-bit INT16 偏置
    
    // 量化参数
    input  wire signed [15:0]   quant_M0,        // 量化乘数 M0
    input  wire [3:0]           quant_n,         // 量化右移位数 n
    
    // 输出接口 (写回特征图 SRAM)
    output reg                  out_valid,       // 标志输出的 INT8 数据有效，通知 SRAM 写入
    output reg  [255:0]         act_out_flat     // 32 个 8-bit INT8 最终激活输出
);

    // ----------------------------------------------------------------------
    // 0. 扁平数据解包 (Unpacking)
    // ----------------------------------------------------------------------
    wire signed [31:0] psum_in [0:31];
    wire signed [15:0] bias_in [0:31];
    
    genvar g;
    generate
        for (g = 0; g < 32; g = g + 1) begin : unpack_loop
            assign psum_in[g] = psum_in_flat[g*32 +: 32];
            assign bias_in[g] = bias_in_flat[g*16 +: 16];
        end
    endgenerate

    // ----------------------------------------------------------------------
    // 🌟 流水线寄存器声明
    // ----------------------------------------------------------------------
    reg                 stage1_valid;
    reg signed [47:0]   stage1_mult [0:31]; // 暂存第一级 32 个 48-bit 乘法结果

    // 用于组合逻辑计算的内部临时变量
    integer i;
    reg signed [32:0]   psum_with_bias;     
    reg signed [47:0]   temp_shifted;       

    // ----------------------------------------------------------------------
    // 1. 二级流水线核心逻辑
    // ----------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stage1_valid <= 1'b0;
            out_valid    <= 1'b0;
            act_out_flat <= 256'd0;
            for (i = 0; i < 32; i = i + 1) begin
                stage1_mult[i] <= 48'sd0;
            end
        end else begin
            
            // =========================================================
            // 【Stage 1】: 加偏置 (Add) + 乘 M0 (Mult)
            // =========================================================
            stage1_valid <= mac_valid;
            
            if (mac_valid) begin
                for (i = 0; i < 32; i = i + 1) begin
                    // 符号扩展并相加
                    psum_with_bias = $signed(psum_in[i]) + $signed({{16{bias_in[i][15]}}, bias_in[i]});
                    // 乘法运算，将结果推入流水线寄存器
                    stage1_mult[i] <= psum_with_bias * $signed(quant_M0);
                end
            end

            // =========================================================
            // 【Stage 2】: 算术右移 (Shift) + ReLU + 饱和截断 (Sat)
            // =========================================================
            out_valid <= stage1_valid;
            
            if (stage1_valid) begin
                for (i = 0; i < 32; i = i + 1) begin
                    // 从 Stage 1 寄存器读取数据并右移
                    temp_shifted = stage1_mult[i] >>> quant_n;
                    
                    if (temp_shifted < 0) begin
                        // ReLU: 负数变 0
                        act_out_flat[i*8 +: 8] <= 8'd0;
                    end 
                    else if (temp_shifted > 127) begin
                        // Saturation: 超过 127 强行截断为 127
                        act_out_flat[i*8 +: 8] <= 8'd127;
                    end 
                    else begin
                        // 正常取低 8 位
                        act_out_flat[i*8 +: 8] <= temp_shifted[7:0];
                    end
                end
            end
            
        end
    end

endmodule
```

### `rtl/line_buffer.v`

```verilog
`timescale 1ns / 1ps

// ==========================================================================
// 模块名称: line_buffer (多模式二维窗口发生器)
// 功能描述: 
//   1. 接收 SRAM 的 1 维数据流，通过移位寄存器链折叠成 2 维图像。
//   2. 模式 0 (Conv1): 构建 11x7 窗口 (图像宽 W=10)，复用广播给 4 个 MAC 组。
//   3. 模式 1 (DW): 构建 3x3 窗口 (图像宽 W=4)，分配给 32 个通道的 MAC 组。
//   4. 模式 2 (PW): 1x1 窗口，直接将当前像素广播给 8 个 MAC 组。
//   5. 展平 (Flatten) 输出 2464-bit 总线，完美对齐 mac_array.v 的输入引脚。
// ==========================================================================

module line_buffer (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire [1:0]           layer_mode,   // 00: Conv1, 01: DW, 10: PW
    input  wire                 shift_en,     // 窗口滑动使能 (来自 Controller)
    input  wire [255:0]         sram_data_in, // SRAM 读出的当前最新数据
    
    output reg                  window_valid, // 标志当前拼出的 2D 窗口完全合法
    output reg  [2463:0]        act_in_flat   // 展平后的数据，直接连给 MAC 阵列
);

    // ======================================================================
    // 1. 移位寄存器链 (Shift Register Chains)
    // ======================================================================
    // Conv1 需要 11x7 窗口，图像宽 W=10。最老的像素距离现在 10行*10宽 + 6列 = 106 拍。
    // 因为 Conv1 是单通道，我们只需要存低 8 位 (假设测试数据放在 SRAM word 的低 8 位)
    reg [7:0]   cb [1:106]; 
    
    // DW 需要 3x3 窗口，图像宽 W=4。最老的像素距离现在 2行*4宽 + 2列 = 10 拍。
    // DW 是 32 通道，所以必须存完整的 256 bits。
    reg [255:0] db [1:10];  
    
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 1; i <= 106; i = i + 1) cb[i] <= 8'd0;
            for (i = 1; i <= 10;  i = i + 1) db[i] <= 256'd0;
        end else if (shift_en) begin
            // 移位逻辑：新数据推入 [1]，老数据向后挤
            cb[1] <= sram_data_in[7:0];
            for (i = 2; i <= 106; i = i + 1) cb[i] <= cb[i-1];
            
            db[1] <= sram_data_in;
            for (i = 2; i <= 10;  i = i + 1) db[i] <= db[i-1];
        end
    end

    // 将当前输入 sram_data_in 视作坐标 [0]，方便后续统一数学索引
    wire [7:0]   cb_wire [0:106];
    wire [255:0] db_wire [0:10];
    
    assign cb_wire[0] = sram_data_in[7:0];
    assign db_wire[0] = sram_data_in;
    
    genvar g;
    generate
        for (g = 1; g <= 106; g = g + 1) begin : gen_cb_wire
            assign cb_wire[g] = cb[g];
        end
        for (g = 1; g <= 10; g = g + 1) begin : gen_db_wire
            assign db_wire[g] = db[g];
        end
    endgenerate

    // ======================================================================
    // 2. 窗口有效性控制逻辑 (Window Valid)
    // ======================================================================
    reg [1:0] prev_mode;
    reg [4:0] col_cnt; // 图像列坐标
    reg [4:0] row_cnt; // 图像行坐标
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_mode    <= 2'b00;
            col_cnt      <= 5'd0;
            row_cnt      <= 5'd0;
            window_valid <= 1'b0;
        end else begin
            prev_mode <= layer_mode;
            
            // 核心技巧：当 Controller 切换层时，利用模式跳变沿清零计数器
            if (layer_mode != prev_mode) begin
                col_cnt      <= 5'd0;
                row_cnt      <= 5'd0;
                window_valid <= 1'b0;
            end 
            else if (shift_en) begin
                if (layer_mode == 2'd0) begin
                    // --- Conv1 模式 (W = 10) ---
                    if (col_cnt == 5'd9) begin
                        col_cnt <= 5'd0;
                        row_cnt <= row_cnt + 1'b1;
                    end else begin
                        col_cnt <= col_cnt + 1'b1;
                    end
                    // 11x7 窗口填满条件：扫过第 10 行，且列数达到第 6 列
                    if (row_cnt >= 10 && col_cnt >= 6) window_valid <= 1'b1;
                    else window_valid <= 1'b0;
                    
                end else if (layer_mode == 2'd1) begin
                    // --- DW 模式 (W = 4) ---
                    if (col_cnt == 5'd3) begin
                        col_cnt <= 5'd0;
                        row_cnt <= row_cnt + 1'b1;
                    end else begin
                        col_cnt <= col_cnt + 1'b1;
                    end
                    // 3x3 窗口填满条件：扫过第 2 行，且列数达到第 2 列
                    if (row_cnt >= 2 && col_cnt >= 2) window_valid <= 1'b1;
                    else window_valid <= 1'b0;
                    
                end else if (layer_mode == 2'd2) begin
                    // --- PW 模式 (1x1 窗口) ---
                    // 1x1 卷积无需等待周围像素，当前像素随时合法
                    window_valid <= 1'b1;
                end
            end
        end
    end

    // ======================================================================
    // 3. 2D 窗口提取与展平布线 (Flatten Routing) -> 纯组合逻辑连线
    // ======================================================================
    reg [7:0] conv_window [0:76];     // 存放 Conv1 提取出的 77 个点
    reg [7:0] dw_window   [0:31][0:8]; // 存放 DW 提取出的 [32通道][9个点]
    
    integer r, c, p, ch, grp;
    
    always @(*) begin
        act_in_flat = 2464'd0; // 默认置零防锁存
        
        // -------------------------------------------------------------
        // Step 3A: 从 1 维长条形寄存器链中抠出 2D 矩形窗口
        // -------------------------------------------------------------
        // [Conv1 提取]
        p = 0;
        for (r = 0; r < 11; r = r + 1) begin
            for (c = 0; c < 7; c = c + 1) begin
                // 行距偏移为 10
                conv_window[p] = cb_wire[r*10 + c];
                p = p + 1;
            end
        end
        
        // [DW 提取]
        for (ch = 0; ch < 32; ch = ch + 1) begin
            p = 0;
            for (r = 0; r < 3; r = r + 1) begin
                for (c = 0; c < 3; c = c + 1) begin
                    // 行距偏移为 4，并切片取出属于该通道的 8 bits
                    dw_window[ch][p] = db_wire[r*4 + c][ch*8 +: 8];
                    p = p + 1;
                end
            end
        end

        // -------------------------------------------------------------
        // Step 3B: 将提取出的窗口塞入 MAC 阵列对应的坑位中 (Flatten)
        // -------------------------------------------------------------
        if (layer_mode == 2'd0) begin
            // Conv1: 77 个点被原封不动地复制 4 份，发给 4 组 MAC (计算 4 个卷积核)
            for (grp = 0; grp < 4; grp = grp + 1) begin
                for (p = 0; p < 77; p = p + 1) begin
                    act_in_flat[(grp*77 + p)*8 +: 8] = conv_window[p];
                end
            end
        end 
        else if (layer_mode == 2'd1) begin
            // DW: 32 个通道，每个通道 9 个点，发给 32 组独立 MAC
            for (ch = 0; ch < 32; ch = ch + 1) begin
                for (p = 0; p < 9; p = p + 1) begin
                    act_in_flat[(ch*9 + p)*8 +: 8] = dw_window[ch][p];
                end
            end
        end 
        else if (layer_mode == 2'd2) begin
            // PW: 只有 1 个点 (包含 32 个通道)。将其复制 8 份，发给 8 组跨通道 MAC
            for (grp = 0; grp < 8; grp = grp + 1) begin
                for (ch = 0; ch < 32; ch = ch + 1) begin
                    act_in_flat[(grp*32 + ch)*8 +: 8] = sram_data_in[ch*8 +: 8];
                end
            end
        end
    end

endmodule
```

### `rtl/weight_rom.v`

```verilog
`timescale 1ns / 1ps

module weight_rom (
    input  wire         clk,
    input  wire [11:0]  addr,    // 控制器发来的权重读取地址
    output reg  [2463:0] dout    // 吐给 MAC 阵列的超宽权重数据
);

    // 声明一个内存数组作为容器，深度比如为 1024，位宽 2464
    // (这就是所谓的 "ROM" 本体)
    reg [2463:0] rom_memory [0:1023];

    // 使用你说的从文件夹直接读的方法加载数据！
    initial begin
        // 这里就是利用电脑直接读 txt 文件，填入容器
        $readmemh("../data/CNN测试数据/Param/Param_Conv_Weight.txt", rom_memory);
    end

    // 时序逻辑：根据地址给出数据
    always @(posedge clk) begin
        dout <= rom_memory[addr];
    end

endmodule
```

### `rtl/param_rom.v`

```verilog
`timescale 1ns / 1ps

// ==========================================================================
// 模块名称: param_rom (全能参数只读存储器)
// 功能描述: 
//   1. 内部集成所有层的 Weight 和 Bias 存储空间。
//   2. 在 initial 块中直接读取助教的 txt 文件填入存储器。
//   3. 使用纯组合逻辑 (MUX)，根据当前的 layer_mode 和 ch_grp_cnt，
//      将 1-byte 的数据拼装成 2464-bit 的超宽向量，精准喂给 MAC 阵列。
// ==========================================================================

module param_rom (
    input  wire         clk,          // 在纯组合逻辑 ROM 中，clk 仅做备用
    input  wire [1:0]   layer_mode,   // 00: Conv1, 01: DW, 10: PW
    input  wire [3:0]   ch_grp_cnt,   // 当前正在计算通道的第几组
    
    output reg [2463:0] wgt_in_flat,  // 拼装好的 2464-bit 权重，发给 MAC
    output reg [511:0]  bias_in_flat  // 拼装好的 512-bit 偏置，发给 Post Process
);

    // ======================================================================
    // 1. 定义物理存储容器 (对应 txt 文件的行数)
    // ======================================================================
    // Conv1: 32 输出通道 * 1 输入通道 * 11x7 核 = 2464 字节
    reg [7:0]  rom_conv1_w [0:2463];
    reg [15:0] rom_conv1_b [0:31];

    // DWConv: 32 输出通道 * 1 深度 * 3x3 核 = 288 字节
    reg [7:0]  rom_dw_w [0:287];
    reg [15:0] rom_dw_b [0:31];

    // PWConv: 32 输出通道 * 32 输入通道 * 1x1 核 = 1024 字节
    reg [7:0]  rom_pw_w [0:1023];
    reg [15:0] rom_pw_b [0:31];

    // ======================================================================
    // 2. 仿真初始化：从硬盘直接吸入数据
    // 注意：这里的路径是相对路径，请确保仿真软件运行目录能找到这些文件！
    // ======================================================================
    initial begin
        // 使用相对路径读取你工程 data 目录下的文件
        $readmemh("../data/CNN测试数据/Param/Param_Conv_Weight.txt",   rom_conv1_w);
        $readmemh("../data/CNN测试数据/Param/Param_Conv_Bias.txt",     rom_conv1_b);
        
        $readmemh("../data/CNN测试数据/Param/Param_DWConv_Weight.txt", rom_dw_w);
        $readmemh("../data/CNN测试数据/Param/Param_DWConv_Bias.txt",   rom_dw_b);
        
        $readmemh("../data/CNN测试数据/Param/Param_PWConv_Weight.txt", rom_pw_w);
        $readmemh("../data/CNN测试数据/Param/Param_PWConv_Bias.txt",   rom_pw_b);
    end

    // ======================================================================
    // 3. 动态张量重排 (Dynamic Tensor Reshaping) -> 纯组合逻辑连线
    // ======================================================================
    integer k, p, ch, in_ch;
    
    always @(*) begin
        // 默认清零，防止产生锁存器 (Latch)
        wgt_in_flat  = 2464'd0;
        bias_in_flat = 512'd0;
        
        case (layer_mode)
            2'd0: begin
                // 【Conv1 模式】
                // FSM 分 8 组算 (0~7)。每组算 4 个输出通道。
                // 当前计算的 4 个输出通道的绝对索引是：ch = ch_grp_cnt * 4 + k (k=0,1,2,3)
                for (k = 0; k < 4; k = k + 1) begin
                    // 1. 抓取这 4 个通道的 Bias，对齐到 MAC 阵列的前 4 个坑位
                    bias_in_flat[k*16 +: 16] = rom_conv1_b[ch_grp_cnt * 4 + k];
                    
                    // 2. 抓取这 4 个通道对应的 77 个权重
                    for (p = 0; p < 77; p = p + 1) begin
                        wgt_in_flat[(k*77 + p)*8 +: 8] = rom_conv1_w[(ch_grp_cnt * 4 + k)*77 + p];
                    end
                end
            end
            
            2'd1: begin
                // 【DWConv 模式】
                // 32 个通道在一个周期内全开，不需要分批。
                for (ch = 0; ch < 32; ch = ch + 1) begin
                    // 1. 抓取全部 32 个 Bias
                    bias_in_flat[ch*16 +: 16] = rom_dw_b[ch];
                    
                    // 2. 抓取 32个通道*9个点 的权重
                    for (p = 0; p < 9; p = p + 1) begin
                        wgt_in_flat[(ch*9 + p)*8 +: 8] = rom_dw_w[ch*9 + p];
                    end
                end
            end
            
            2'd2: begin
                // 【PWConv 模式】
                // FSM 分 4 组算 (0~3)。每组算 8 个输出通道。
                // 当前计算的 8 个输出通道的绝对索引是：ch = ch_grp_cnt * 8 + k (k=0~7)
                for (k = 0; k < 8; k = k + 1) begin
                    // 1. 抓取这 8 个通道的 Bias，对齐到 MAC 阵列的前 8 个坑位
                    bias_in_flat[k*16 +: 16] = rom_pw_b[ch_grp_cnt * 8 + k];
                    
                    // 2. 抓取这 8 个输出通道，每个需要 32 个输入通道的权重
                    for (in_ch = 0; in_ch < 32; in_ch = in_ch + 1) begin
                        wgt_in_flat[(k*32 + in_ch)*8 +: 8] = rom_pw_w[(ch_grp_cnt * 8 + k)*32 + in_ch];
                    end
                end
            end
            
            default: ;
        endcase
    end

endmodule
```

### `rtl/sram_256x80.v`

```verilog
module sram_256x80 (
    input  wire         CLK,
    input  wire         CEN,
    input  wire         WEN,
    input  wire [9:0]   A,  // 外部传入，高位补0即可
    input  wire [255:0] D,
    output wire [255:0] Q
);

    // 官方 128位宽 x 80深度 SRAM (处理低 128 位)
    S018V3EBCDSP_X20Y4D128_PR u_sram_low (
        .CLK(CLK), .CEN(CEN), .WEN(WEN), .A(A[6:0]), .D(D[127:0]), .Q(Q[127:0])
    );

    // 官方 128位宽 x 80深度 SRAM (处理高 128 位)
    S018V3EBCDSP_X20Y4D128_PR u_sram_high (
        .CLK(CLK), .CEN(CEN), .WEN(WEN), .A(A[6:0]), .D(D[255:128]), .Q(Q[255:128])
    );

endmodule

```

### `rtl/output_staging_buffer.v`

```verilog
`timescale 1ns / 1ps

// ==========================================================================
// 模块名称: output_staging_buffer (输出组装缓存)
// 功能描述: 
//   解决 32-bit 计算输出与 256-bit SRAM 位宽的存储墙矛盾。
//   1. Conv1 模式：攒齐 8 批 32-bit，拼成 256-bit 发起一次写入，物理地址 /8。
//   2. DW 模式：直接将 256-bit 发起写入，物理地址不变。
//   3. PW 模式：攒齐 4 批 64-bit，拼成 256-bit 发起一次写入，物理地址 /4。
// ==========================================================================

module output_staging_buffer (
    input  wire             clk,
    input  wire             rst_n,
    
    // 延迟对齐后的控制信号 (来自顶层打拍后)
    input  wire [1:0]       layer_mode_sync, 
    input  wire [9:0]       act_waddr_sync,  
    
    // 来自后处理模块的数据
    input  wire             out_valid,       
    input  wire [255:0]     act_out_flat,    
    
    // 发送给 SRAM MUX 的终极写操作信号
    output reg              staging_wen,     // 低电平有效
    output reg  [9:0]       staging_waddr,
    output reg  [255:0]     staging_wdata
);

    reg [255:0] buffer;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buffer        <= 256'd0;
            staging_wen   <= 1'b1; // 默认不写
            staging_waddr <= 10'd0;
            staging_wdata <= 256'd0;
        end else begin
            // 默认每拍都拉高 wen (停止写入)
            staging_wen <= 1'b1; 
            
            if (out_valid) begin
                if (layer_mode_sync == 2'd0) begin
                    // 【Conv1】: 8 批 32-bit 拼装 (低3位恰好是 0~7)
                    buffer[act_waddr_sync[2:0] * 32 +: 32] <= act_out_flat[31:0];
                    if (act_waddr_sync[2:0] == 3'd7) begin
                        staging_wen   <= 1'b0; // 满仓！发车！
                        // 巧妙拼接：把刚刚算出的第8批和寄存器里存的前7批瞬间拼合
                        staging_wdata <= {act_out_flat[31:0], buffer[223:0]};
                        staging_waddr <= act_waddr_sync[9:3]; // 逻辑地址 / 8 = 真实物理地址
                    end
                end 
                else if (layer_mode_sync == 2'd1) begin
                    // 【DWConv】: 1 批 256-bit 直接写
                    staging_wen   <= 1'b0;
                    staging_wdata <= act_out_flat;
                    staging_waddr <= act_waddr_sync;
                end 
                else if (layer_mode_sync == 2'd2) begin
                    // 【PWConv】: 4 批 64-bit 拼装 (低2位恰好是 0~3)
                    buffer[act_waddr_sync[1:0] * 64 +: 64] <= act_out_flat[63:0];
                    if (act_waddr_sync[1:0] == 2'd3) begin
                        staging_wen   <= 1'b0;
                        staging_wdata <= {act_out_flat[63:0], buffer[191:0]};
                        staging_waddr <= act_waddr_sync[9:2]; // 逻辑地址 / 4 = 真实物理地址
                    end
                end
            end
        end
    end

endmodule
```

### `rtl/S018V3EBCDSP_X20Y4D128_PR.v`

```verilog
/*
    Copyright (c) 2026 SMIC
    Filename:      S018V3EBCDSP_X20Y4D128_PR.v
    IP code :      S018V3EBCDSP
    Version:       0.1.a
    CreateDate:    Apr 12, 2026

    Verilog Model for Single-PORT SRAM
    SMIC 0.18um V3EBCD

    Configuration: -instname S018V3EBCDSP_X20Y4D128_PR -rows 20 -bits 128 -mux 4 
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

module S018V3EBCDSP_X20Y4D128_PR(
                          Q,
			  CLK,
			  CEN,
			  WEN,
			  A,
			  D);

  parameter	Bits = 128;
  parameter	Word_Depth = 80;
  parameter	Add_Width = 7;

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
  reg 			A5_flag;
  reg 			A6_flag;

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
  reg 			D32_flag;
  reg 			D33_flag;
  reg 			D34_flag;
  reg 			D35_flag;
  reg 			D36_flag;
  reg 			D37_flag;
  reg 			D38_flag;
  reg 			D39_flag;
  reg 			D40_flag;
  reg 			D41_flag;
  reg 			D42_flag;
  reg 			D43_flag;
  reg 			D44_flag;
  reg 			D45_flag;
  reg 			D46_flag;
  reg 			D47_flag;
  reg 			D48_flag;
  reg 			D49_flag;
  reg 			D50_flag;
  reg 			D51_flag;
  reg 			D52_flag;
  reg 			D53_flag;
  reg 			D54_flag;
  reg 			D55_flag;
  reg 			D56_flag;
  reg 			D57_flag;
  reg 			D58_flag;
  reg 			D59_flag;
  reg 			D60_flag;
  reg 			D61_flag;
  reg 			D62_flag;
  reg 			D63_flag;
  reg 			D64_flag;
  reg 			D65_flag;
  reg 			D66_flag;
  reg 			D67_flag;
  reg 			D68_flag;
  reg 			D69_flag;
  reg 			D70_flag;
  reg 			D71_flag;
  reg 			D72_flag;
  reg 			D73_flag;
  reg 			D74_flag;
  reg 			D75_flag;
  reg 			D76_flag;
  reg 			D77_flag;
  reg 			D78_flag;
  reg 			D79_flag;
  reg 			D80_flag;
  reg 			D81_flag;
  reg 			D82_flag;
  reg 			D83_flag;
  reg 			D84_flag;
  reg 			D85_flag;
  reg 			D86_flag;
  reg 			D87_flag;
  reg 			D88_flag;
  reg 			D89_flag;
  reg 			D90_flag;
  reg 			D91_flag;
  reg 			D92_flag;
  reg 			D93_flag;
  reg 			D94_flag;
  reg 			D95_flag;
  reg 			D96_flag;
  reg 			D97_flag;
  reg 			D98_flag;
  reg 			D99_flag;
  reg 			D100_flag;
  reg 			D101_flag;
  reg 			D102_flag;
  reg 			D103_flag;
  reg 			D104_flag;
  reg 			D105_flag;
  reg 			D106_flag;
  reg 			D107_flag;
  reg 			D108_flag;
  reg 			D109_flag;
  reg 			D110_flag;
  reg 			D111_flag;
  reg 			D112_flag;
  reg 			D113_flag;
  reg 			D114_flag;
  reg 			D115_flag;
  reg 			D116_flag;
  reg 			D117_flag;
  reg 			D118_flag;
  reg 			D119_flag;
  reg 			D120_flag;
  reg 			D121_flag;
  reg 			D122_flag;
  reg 			D123_flag;
  reg 			D124_flag;
  reg 			D125_flag;
  reg 			D126_flag;
  reg 			D127_flag;

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
		or A5_flag
		or A6_flag
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
		or D32_flag
		or D33_flag
		or D34_flag
		or D35_flag
		or D36_flag
		or D37_flag
		or D38_flag
		or D39_flag
		or D40_flag
		or D41_flag
		or D42_flag
		or D43_flag
		or D44_flag
		or D45_flag
		or D46_flag
		or D47_flag
		or D48_flag
		or D49_flag
		or D50_flag
		or D51_flag
		or D52_flag
		or D53_flag
		or D54_flag
		or D55_flag
		or D56_flag
		or D57_flag
		or D58_flag
		or D59_flag
		or D60_flag
		or D61_flag
		or D62_flag
		or D63_flag
		or D64_flag
		or D65_flag
		or D66_flag
		or D67_flag
		or D68_flag
		or D69_flag
		or D70_flag
		or D71_flag
		or D72_flag
		or D73_flag
		or D74_flag
		or D75_flag
		or D76_flag
		or D77_flag
		or D78_flag
		or D79_flag
		or D80_flag
		or D81_flag
		or D82_flag
		or D83_flag
		or D84_flag
		or D85_flag
		or D86_flag
		or D87_flag
		or D88_flag
		or D89_flag
		or D90_flag
		or D91_flag
		or D92_flag
		or D93_flag
		or D94_flag
		or D95_flag
		or D96_flag
		or D97_flag
		or D98_flag
		or D99_flag
		or D100_flag
		or D101_flag
		or D102_flag
		or D103_flag
		or D104_flag
		or D105_flag
		or D106_flag
		or D107_flag
		or D108_flag
		or D109_flag
		or D110_flag
		or D111_flag
		or D112_flag
		or D113_flag
		or D114_flag
		or D115_flag
		or D116_flag
		or D117_flag
		or D118_flag
		or D119_flag
		or D120_flag
		or D121_flag
		or D122_flag
		or D123_flag
		or D124_flag
		or D125_flag
		or D126_flag
		or D127_flag
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
		A6_flag,
		A5_flag,
		A4_flag,
		A3_flag,
		A2_flag,
		A1_flag,
            A0_flag};
    D_flag = {
		D127_flag,
		D126_flag,
		D125_flag,
		D124_flag,
		D123_flag,
		D122_flag,
		D121_flag,
		D120_flag,
		D119_flag,
		D118_flag,
		D117_flag,
		D116_flag,
		D115_flag,
		D114_flag,
		D113_flag,
		D112_flag,
		D111_flag,
		D110_flag,
		D109_flag,
		D108_flag,
		D107_flag,
		D106_flag,
		D105_flag,
		D104_flag,
		D103_flag,
		D102_flag,
		D101_flag,
		D100_flag,
		D99_flag,
		D98_flag,
		D97_flag,
		D96_flag,
		D95_flag,
		D94_flag,
		D93_flag,
		D92_flag,
		D91_flag,
		D90_flag,
		D89_flag,
		D88_flag,
		D87_flag,
		D86_flag,
		D85_flag,
		D84_flag,
		D83_flag,
		D82_flag,
		D81_flag,
		D80_flag,
		D79_flag,
		D78_flag,
		D77_flag,
		D76_flag,
		D75_flag,
		D74_flag,
		D73_flag,
		D72_flag,
		D71_flag,
		D70_flag,
		D69_flag,
		D68_flag,
		D67_flag,
		D66_flag,
		D65_flag,
		D64_flag,
		D63_flag,
		D62_flag,
		D61_flag,
		D60_flag,
		D59_flag,
		D58_flag,
		D57_flag,
		D56_flag,
		D55_flag,
		D54_flag,
		D53_flag,
		D52_flag,
		D51_flag,
		D50_flag,
		D49_flag,
		D48_flag,
		D47_flag,
		D46_flag,
		D45_flag,
		D44_flag,
		D43_flag,
		D42_flag,
		D41_flag,
		D40_flag,
		D39_flag,
		D38_flag,
		D37_flag,
		D36_flag,
		D35_flag,
		D34_flag,
		D33_flag,
		D32_flag,
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
    (posedge CLK => (Q[32] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[33] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[34] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[35] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[36] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[37] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[38] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[39] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[40] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[41] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[42] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[43] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[44] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[45] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[46] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[47] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[48] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[49] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[50] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[51] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[52] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[53] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[54] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[55] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[56] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[57] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[58] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[59] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[60] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[61] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[62] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[63] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[64] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[65] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[66] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[67] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[68] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[69] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[70] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[71] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[72] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[73] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[74] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[75] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[76] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[77] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[78] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[79] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[80] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[81] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[82] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[83] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[84] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[85] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[86] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[87] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[88] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[89] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[90] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[91] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[92] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[93] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[94] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[95] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[96] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[97] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[98] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[99] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[100] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[101] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[102] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[103] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[104] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[105] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[106] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[107] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[108] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[109] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[110] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[111] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[112] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[113] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[114] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[115] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[116] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[117] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[118] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[119] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[120] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[121] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[122] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[123] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[124] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[125] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[126] : 1'bx))=(1.000,1.000);
    (posedge CLK => (Q[127] : 1'bx))=(1.000,1.000);
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
    $setuphold(posedge CLK &&& CE_flag,posedge A[5],0.500,0.250,A5_flag);
    $setuphold(posedge CLK &&& CE_flag,negedge A[5],0.500,0.250,A5_flag);
    $setuphold(posedge CLK &&& CE_flag,posedge A[6],0.500,0.250,A6_flag);
    $setuphold(posedge CLK &&& CE_flag,negedge A[6],0.500,0.250,A6_flag);
    $setuphold(posedge CLK,posedge CEN,0.500,0.250,CEN_flag);
    $setuphold(posedge CLK,negedge CEN,0.500,0.250,CEN_flag);
    $period(posedge CLK,3.623,CLK_CYC_flag);
    $width(posedge CLK,1.087,0,CLK_H_flag);
    $width(negedge CLK,1.087,0,CLK_L_flag);
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
    $setuphold(posedge CLK &&& WR_flag,posedge D[32],0.500,0.250,D32_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[32],0.500,0.250,D32_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[33],0.500,0.250,D33_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[33],0.500,0.250,D33_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[34],0.500,0.250,D34_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[34],0.500,0.250,D34_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[35],0.500,0.250,D35_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[35],0.500,0.250,D35_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[36],0.500,0.250,D36_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[36],0.500,0.250,D36_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[37],0.500,0.250,D37_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[37],0.500,0.250,D37_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[38],0.500,0.250,D38_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[38],0.500,0.250,D38_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[39],0.500,0.250,D39_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[39],0.500,0.250,D39_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[40],0.500,0.250,D40_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[40],0.500,0.250,D40_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[41],0.500,0.250,D41_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[41],0.500,0.250,D41_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[42],0.500,0.250,D42_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[42],0.500,0.250,D42_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[43],0.500,0.250,D43_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[43],0.500,0.250,D43_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[44],0.500,0.250,D44_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[44],0.500,0.250,D44_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[45],0.500,0.250,D45_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[45],0.500,0.250,D45_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[46],0.500,0.250,D46_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[46],0.500,0.250,D46_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[47],0.500,0.250,D47_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[47],0.500,0.250,D47_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[48],0.500,0.250,D48_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[48],0.500,0.250,D48_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[49],0.500,0.250,D49_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[49],0.500,0.250,D49_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[50],0.500,0.250,D50_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[50],0.500,0.250,D50_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[51],0.500,0.250,D51_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[51],0.500,0.250,D51_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[52],0.500,0.250,D52_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[52],0.500,0.250,D52_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[53],0.500,0.250,D53_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[53],0.500,0.250,D53_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[54],0.500,0.250,D54_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[54],0.500,0.250,D54_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[55],0.500,0.250,D55_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[55],0.500,0.250,D55_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[56],0.500,0.250,D56_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[56],0.500,0.250,D56_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[57],0.500,0.250,D57_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[57],0.500,0.250,D57_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[58],0.500,0.250,D58_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[58],0.500,0.250,D58_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[59],0.500,0.250,D59_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[59],0.500,0.250,D59_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[60],0.500,0.250,D60_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[60],0.500,0.250,D60_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[61],0.500,0.250,D61_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[61],0.500,0.250,D61_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[62],0.500,0.250,D62_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[62],0.500,0.250,D62_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[63],0.500,0.250,D63_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[63],0.500,0.250,D63_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[64],0.500,0.250,D64_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[64],0.500,0.250,D64_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[65],0.500,0.250,D65_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[65],0.500,0.250,D65_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[66],0.500,0.250,D66_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[66],0.500,0.250,D66_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[67],0.500,0.250,D67_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[67],0.500,0.250,D67_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[68],0.500,0.250,D68_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[68],0.500,0.250,D68_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[69],0.500,0.250,D69_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[69],0.500,0.250,D69_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[70],0.500,0.250,D70_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[70],0.500,0.250,D70_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[71],0.500,0.250,D71_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[71],0.500,0.250,D71_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[72],0.500,0.250,D72_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[72],0.500,0.250,D72_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[73],0.500,0.250,D73_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[73],0.500,0.250,D73_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[74],0.500,0.250,D74_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[74],0.500,0.250,D74_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[75],0.500,0.250,D75_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[75],0.500,0.250,D75_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[76],0.500,0.250,D76_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[76],0.500,0.250,D76_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[77],0.500,0.250,D77_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[77],0.500,0.250,D77_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[78],0.500,0.250,D78_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[78],0.500,0.250,D78_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[79],0.500,0.250,D79_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[79],0.500,0.250,D79_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[80],0.500,0.250,D80_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[80],0.500,0.250,D80_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[81],0.500,0.250,D81_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[81],0.500,0.250,D81_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[82],0.500,0.250,D82_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[82],0.500,0.250,D82_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[83],0.500,0.250,D83_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[83],0.500,0.250,D83_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[84],0.500,0.250,D84_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[84],0.500,0.250,D84_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[85],0.500,0.250,D85_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[85],0.500,0.250,D85_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[86],0.500,0.250,D86_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[86],0.500,0.250,D86_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[87],0.500,0.250,D87_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[87],0.500,0.250,D87_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[88],0.500,0.250,D88_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[88],0.500,0.250,D88_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[89],0.500,0.250,D89_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[89],0.500,0.250,D89_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[90],0.500,0.250,D90_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[90],0.500,0.250,D90_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[91],0.500,0.250,D91_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[91],0.500,0.250,D91_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[92],0.500,0.250,D92_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[92],0.500,0.250,D92_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[93],0.500,0.250,D93_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[93],0.500,0.250,D93_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[94],0.500,0.250,D94_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[94],0.500,0.250,D94_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[95],0.500,0.250,D95_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[95],0.500,0.250,D95_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[96],0.500,0.250,D96_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[96],0.500,0.250,D96_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[97],0.500,0.250,D97_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[97],0.500,0.250,D97_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[98],0.500,0.250,D98_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[98],0.500,0.250,D98_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[99],0.500,0.250,D99_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[99],0.500,0.250,D99_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[100],0.500,0.250,D100_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[100],0.500,0.250,D100_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[101],0.500,0.250,D101_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[101],0.500,0.250,D101_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[102],0.500,0.250,D102_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[102],0.500,0.250,D102_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[103],0.500,0.250,D103_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[103],0.500,0.250,D103_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[104],0.500,0.250,D104_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[104],0.500,0.250,D104_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[105],0.500,0.250,D105_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[105],0.500,0.250,D105_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[106],0.500,0.250,D106_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[106],0.500,0.250,D106_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[107],0.500,0.250,D107_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[107],0.500,0.250,D107_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[108],0.500,0.250,D108_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[108],0.500,0.250,D108_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[109],0.500,0.250,D109_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[109],0.500,0.250,D109_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[110],0.500,0.250,D110_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[110],0.500,0.250,D110_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[111],0.500,0.250,D111_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[111],0.500,0.250,D111_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[112],0.500,0.250,D112_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[112],0.500,0.250,D112_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[113],0.500,0.250,D113_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[113],0.500,0.250,D113_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[114],0.500,0.250,D114_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[114],0.500,0.250,D114_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[115],0.500,0.250,D115_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[115],0.500,0.250,D115_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[116],0.500,0.250,D116_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[116],0.500,0.250,D116_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[117],0.500,0.250,D117_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[117],0.500,0.250,D117_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[118],0.500,0.250,D118_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[118],0.500,0.250,D118_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[119],0.500,0.250,D119_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[119],0.500,0.250,D119_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[120],0.500,0.250,D120_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[120],0.500,0.250,D120_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[121],0.500,0.250,D121_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[121],0.500,0.250,D121_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[122],0.500,0.250,D122_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[122],0.500,0.250,D122_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[123],0.500,0.250,D123_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[123],0.500,0.250,D123_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[124],0.500,0.250,D124_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[124],0.500,0.250,D124_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[125],0.500,0.250,D125_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[125],0.500,0.250,D125_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[126],0.500,0.250,D126_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[126],0.500,0.250,D126_flag);
    $setuphold(posedge CLK &&& WR_flag,posedge D[127],0.500,0.250,D127_flag);
    $setuphold(posedge CLK &&& WR_flag,negedge D[127],0.500,0.250,D127_flag);
    $setuphold(posedge CLK &&& CE_flag,posedge WEN,0.500,0.250,WEN_flag);
    $setuphold(posedge CLK &&& CE_flag,negedge WEN,0.500,0.250,WEN_flag);
  endspecify

endmodule

`endcelldefine
```

### `tb/mac_array_self_check_tb.v`

```verilog
`timescale 1ns / 1ps

module mac_array_self_check_tb();

    // ---------------------------------------------------------
    // 信号定义
    // ---------------------------------------------------------
    reg                 clk;
    reg                 rst_n;
    reg  [1:0]          layer_mode;
    reg  [2463:0]       act_in_flat;
    reg  [2463:0]       wgt_in_flat;
    wire [1023:0]       psum_out_flat;

    // 统计变量
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // ---------------------------------------------------------
    // 模块例化
    // ---------------------------------------------------------
    mac_array uut (
        .clk(clk), .rst_n(rst_n), .layer_mode(layer_mode),
        .act_in_flat(act_in_flat), .wgt_in_flat(wgt_in_flat),
        .psum_out_flat(psum_out_flat)
    );

    // 时钟生成
    initial clk = 0;
    always #5 clk = ~clk;

    // ---------------------------------------------------------
    // 自动化验证任务 (Tasks)
    // ---------------------------------------------------------
    
    // 核心比对任务：自动等待 2 拍流水线后检查结果
    task verify_result(input [127:0] test_name, input integer num_outputs);
        integer i;
        reg signed [31:0] expected_psum [0:31];
        reg signed [31:0] actual_psum;
        begin
            // 1. 自动计算 Golden Reference (由于是 TB，这里用循环计算模拟硬件逻辑)
            for(i=0; i<32; i=i+1) expected_psum[i] = 32'sd0;
            
            case(layer_mode)
                2'd0: begin // Conv1: 4组，每组77 
                    for(i=0; i<4; i=i+1) begin
                        for(integer j=0; j<77; j=j+1)
                            expected_psum[i] = expected_psum[i] + $signed(act_in_flat[(i*77+j)*8 +: 8]) * $signed(wgt_in_flat[(i*77+j)*8 +: 8]);
                    end
                end
                2'd1: begin // DW: 32组，每组9 
                    for(i=0; i<32; i=i+1) begin
                        for(integer j=0; j<9; j=j+1)
                            expected_psum[i] = expected_psum[i] + $signed(act_in_flat[(i*9+j)*8 +: 8]) * $signed(wgt_in_flat[(i*9+j)*8 +: 8]);
                    end
                end
                2'd2: begin // PW: 8组，每组32 
                    for(i=0; i<8; i=i+1) begin
                        for(integer j=0; j<32; j=j+1)
                            expected_psum[i] = expected_psum[i] + $signed(act_in_flat[(i*32+j)*8 +: 8]) * $signed(wgt_in_flat[(i*32+j)*8 +: 8]);
                    end
                end
            endcase

            // 2. 等待硬件流水线完成 (2拍延迟)
            repeat(2) @(posedge clk);
            #1; // 避开采样边沿

            // 3. 逐一比对
            for(i=0; i<num_outputs; i=i+1) begin
                actual_psum = $signed(psum_out_flat[i*32 +: 32]);
                if (actual_psum !== expected_psum[i]) begin
                    $display("[FAILED] %s | Ch:%0d | Exp:%d | Got:%d", test_name, i, expected_psum[i], actual_psum);
                    fail_cnt = fail_cnt + 1;
                end else begin
                    pass_cnt = pass_cnt + 1;
                end
            end
        end
    endtask

    // ---------------------------------------------------------
    // 测试流程
    // ---------------------------------------------------------
    initial begin
        // 初始化
        rst_n = 0; layer_mode = 0; act_in_flat = 0; wgt_in_flat = 0;
        #20 rst_n = 1;

        $display("======= Starting Automated MAC Array Verification =======");

        // --- TEST 1: Conv1 模式下的全 1 测试 ---
        layer_mode = 2'b00;
        act_in_flat = {308{8'sd1}};  // 输入全为 1
        wgt_in_flat = {308{8'sd1}};  // 权重全为 1
        verify_result("Conv1_All_Ones", 4);

        // --- TEST 2: DW 模式下的随机负数测试 ---
        layer_mode = 2'b01;
        for(integer k=0; k<308; k=k+1) begin
            act_in_flat[k*8 +: 8] = $random % 128;
            wgt_in_flat[k*8 +: 8] = -8'sd1; // 权重固定为 -1，测试负数累加
        end
        verify_result("DW_Negative_Wgt", 32);

        // --- TEST 3: PW 模式下的极端边界测试 ---
        layer_mode = 2'b10;
        for(integer k=0; k<308; k=k+1) begin
            act_in_flat[k*8 +: 8] = 8'sd127; // 最大正数
            wgt_in_flat[k*8 +: 8] = 8'sd127; // 最大正数
        end
        verify_result("PW_Max_Boundary", 8);

        // --- 最终总结 ---
        $display("---------------------------------------------------------");
        $display("Verification Report:");
        $display("Total Sub-checks Passed: %0d", pass_cnt);
        $display("Total Sub-checks Failed: %0d", fail_cnt);
        
        if (fail_cnt == 0) 
            $display("[SUCCESS] All tests passed! You are ready for the next layer.");
        else 
            $display("[CRITICAL] Found %0d errors. Please check your adder tree logic.", fail_cnt);
        $display("---------------------------------------------------------");
        
        $finish;
    end

endmodule
```

