# CNN工程代码全局快照

**Root Directory:** `/cluster/home/jiut107/cnn2/CNN`

### `Syn/rtl/cnn_top.v`

```verilog
`timescale 1ns / 1ps

module cnn_top (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 start,
    
    // --- 外部输入接口 ---
    input  wire [255:0]         ext_act_in,     
    input  wire                 ext_act_valid,  
    output wire                 done,           
    output wire [31:0]          fc_result,      // FP32 的 Sigmoid 最终结果
    output wire                 fc_valid        // 伴随 fc_result 的有效信号
);

    // FSM 控制信号 (原生态 0拍延迟)
    wire [1:0]  layer_mode;
    wire        line_buf_en;
    wire        mac_valid;
    wire [1:0]  sram_route_sel;
    wire [9:0]  act_raddr, act_waddr;
    wire [3:0]  ch_grp_cnt;
    
    // ==========================================
    // 🌟 Maxpool 独立加速单元连线
    // ==========================================
    // 注意：pool_start 和 pool_done 将在下一步更新 cnn_controller 时接入大脑
    wire         pool_start;  
    wire         pool_done;   
    wire [9:0]   pool_raddr;
    wire [9:0]   pool_waddr;
    wire [255:0] pool_wdata;
    wire         pool_wen;
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
    reg [1:0] route_sel_pipe [0:4];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mac_valid_pipe <= 2'd0;
            act_waddr_pipe[0] <= 10'd0; act_waddr_pipe[1] <= 10'd0; act_waddr_pipe[2] <= 10'd0; act_waddr_pipe[3] <= 10'd0;
            layer_mode_pipe[0] <= 2'd0; layer_mode_pipe[1] <= 2'd0; layer_mode_pipe[2] <= 2'd0; layer_mode_pipe[3] <= 2'd0;
            route_sel_pipe[0] <= 2'd0; route_sel_pipe[1] <= 2'd0; route_sel_pipe[2] <= 2'd0; route_sel_pipe[3] <= 2'd0; route_sel_pipe[4] <= 2'd0;
        end else begin
            mac_valid_pipe    <= {mac_valid_pipe[0], mac_valid};
            
            act_waddr_pipe[0] <= act_waddr;  
            act_waddr_pipe[1] <= act_waddr_pipe[0];  
            act_waddr_pipe[2] <= act_waddr_pipe[1];
            act_waddr_pipe[3] <= act_waddr_pipe[2]; // 🌟 补上漏掉的第 4 拍
            
            layer_mode_pipe[0]<= layer_mode; 
            layer_mode_pipe[1]<= layer_mode_pipe[0]; 
            layer_mode_pipe[2]<= layer_mode_pipe[1];
            layer_mode_pipe[3]<= layer_mode_pipe[2]; // 🌟 补上漏掉的第 4 拍
            
            route_sel_pipe[0] <= sram_route_sel; 
            route_sel_pipe[1] <= route_sel_pipe[0];  
            route_sel_pipe[2] <= route_sel_pipe[1];
            route_sel_pipe[3] <= route_sel_pipe[2];
            route_sel_pipe[4] <= route_sel_pipe[3];  // 🌟 路由选择撑到第 5 拍
        end
    end

// ==========================================
    // 提取同步后的安全信号 (严格对齐 4拍/5拍 流水线)
    // ==========================================
    wire       mac_valid_sync   = mac_valid_pipe[1];   // T+2 送给 PostProcess Stage 1
    
    // 以下信号必须等到 T+4 (数据到达 staging_buffer 时) 才生效
    wire [9:0] act_waddr_sync   = act_waddr_pipe[3];   
    wire [1:0] layer_mode_sync  = layer_mode_pipe[3];  
    
    // 路由选择信号必须撑到 T+5 (staging_buffer 真正发起写 SRAM 的那一拍)
    wire [1:0] route_sel_write  = route_sel_pipe[4];

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
// ==========================================
    // 🌟 读写分离的终极 Ping-Pong 路由 (含 Maxpool 独立控制通道)
    // ==========================================
    wire is_maxpool = (sram_route_sel == 2'd3);

    // ------------------------------------------
    // Ping SRAM 端口复用 (Maxpool 目标写入点)
    // ------------------------------------------
    always @(*) begin
        ping_wen  = 1'b1; 
        ping_addr = 10'd0; 
        ping_din  = 256'd0;
        
        if (is_maxpool) begin
            // 🚀 Maxpool 模式：绕过长流水线，直接接管 Ping 写端口
            ping_wen  = pool_wen; 
            ping_addr = pool_waddr; 
            ping_din  = pool_wdata;
        end 
        else if (route_sel_write == 2'd1) begin
            // 正常流水线 (DW 层)：写入 Ping (使用打 4 拍后的延迟信号)
            ping_wen  = staging_wen; 
            ping_addr = staging_waddr; 
            ping_din  = staging_wdata;
        end 
        else if (sram_route_sel == 2'd2 || sram_route_sel == 2'd0) begin
            // 正常流水线 (Conv1/PW 层)：读取 Ping (使用实时的读取信号)
            ping_wen  = 1'b1; 
            ping_addr = ping_raddr;
        end
    end

    // ------------------------------------------
    // Pong SRAM 端口复用 (Maxpool 数据源)
    // ------------------------------------------
    always @(*) begin
        pong_wen  = 1'b1; 
        pong_addr = 10'd0; 
        pong_din  = 256'd0;
        
        if (is_maxpool) begin
            // 🚀 Maxpool 模式：绕过长流水线，直接接管 Pong 读端口
            pong_wen  = 1'b1; 
            pong_addr = pool_raddr;
        end
        else if (route_sel_write == 2'd0 || route_sel_write == 2'd2) begin
            // 正常流水线 (Conv1/PW 层)：写入 Pong
            pong_wen  = staging_wen; 
            pong_addr = staging_waddr; 
            pong_din  = staging_wdata;
        end 
        else if (sram_route_sel == 2'd1) begin
            // 正常流水线 (DW 层)：读取 Pong
            pong_wen  = 1'b1; 
            pong_addr = act_raddr;
        end
    end

    // ==========================================
    // 模块例化区 (全拼图组装)
    // ==========================================
    cnn_controller u_controller (
        .clk(clk), .rst_n(rst_n), .start(start), .window_valid(window_valid),
        .layer_mode(layer_mode), .line_buf_en(line_buf_en), .mac_valid(mac_valid), .done(done),
        .sram_route_sel(sram_route_sel), .act_raddr(act_raddr), .act_waddr(act_waddr), .ch_grp_cnt(ch_grp_cnt),
        // 👇 预留给下一阶段状态机更新的引脚
        .pool_start(pool_start), .pool_done(pool_done)
    );
    sram_256x80 u_sram_ping (.CLK(clk), .CEN(1'b0), .WEN(ping_wen), .A(ping_addr), .D(ping_din), .Q(ping_dout));
    sram_256x80 u_sram_pong (.CLK(clk), .CEN(1'b0), .WEN(pong_wen), .A(pong_addr), .D(pong_din), .Q(pong_dout));

    line_buffer u_line_buffer (.clk(clk), .rst_n(rst_n), .layer_mode(layer_mode), .shift_en(line_buf_en),
        .sram_data_in(current_layer_act_in), .window_valid(window_valid), .act_in_flat(act_in_flat));

    param_rom u_param_rom (.clk(clk), .layer_mode(layer_mode), .ch_grp_cnt(ch_grp_cnt),
        .wgt_in_flat(wgt_in_flat), .bias_in_flat(bias_in_flat));

    mac_array u_mac_array (.clk(clk), .rst_n(rst_n), .layer_mode(layer_mode),
        .act_in_flat(act_in_flat), .wgt_in_flat(wgt_in_flat), .psum_out_flat(psum_out_flat));


    // 增加一根 wire 提取数组元素
    wire [1:0] cur_layer_mode = layer_mode_pipe[1];

    post_process u_post_process (
        .clk(clk), 
        .rst_n(rst_n), 
        .mac_valid(mac_valid_sync), 
        .layer_mode(cur_layer_mode), // 🌟 传入一维的 wire
        .psum_in_flat(psum_out_flat), 
        .bias_in_flat(bias_in_flat), 
        .out_valid(out_valid), 
        .act_out_flat(act_out_flat)
    );
    
    output_staging_buffer u_staging_buffer (.clk(clk), .rst_n(rst_n), 
        .layer_mode_sync(layer_mode_sync), .act_waddr_sync(act_waddr_sync), // 🌟 传入延迟对齐的控制信号
        .out_valid(out_valid), .act_out_flat(act_out_flat),
        .staging_wen(staging_wen), .staging_waddr(staging_waddr), .staging_wdata(staging_wdata));

    maxpool_unit u_maxpool (
        .clk        (clk),
        .rst_n      (rst_n),
        .pool_start (pool_start),
        .sram_rdata (pong_dout),    // PW 层的输出存在 Pong 中，此处读取 Pong
        .sram_raddr (pool_raddr),
        .sram_waddr (pool_waddr),
        .sram_wdata (pool_wdata),
        .sram_wen   (pool_wen),
        .pool_done  (pool_done)
    );

    // ==========================================
    // 🌟 最终输出：Sigmoid 激活与顶层管脚映射
    // ==========================================
    // 拦截条件：当模式为 FC (2'd3) 且后处理宣告输出有效时
    wire is_fc_output = (layer_mode_sync == 2'd3) && out_valid;

    sigmoid_lut u_sig_lut (
        .clk         (clk),
        .en          (is_fc_output),
        // FC 层的单点计算结果默认被存放在第 0 号通道中
        .fc_int8_in  (act_out_flat[7:0]), 
        .sigmoid_out (fc_result)
    );

    // FC 输出的 valid 信号需要打一拍，因为 sigmoid_lut 内部读 ROM 消耗了一拍
    reg fc_valid_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) fc_valid_reg <= 1'b0;
        else        fc_valid_reg <= is_fc_output;
    end
    assign fc_valid = fc_valid_reg;

    // 防止激进综合器剔除未使用的端口
    wire dummy_prevent_opt = ^ext_act_in | ext_act_valid;
endmodule
```

### `Syn/rtl/line_buffer.v`

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
        // -------------------------------------------------------------
        // Step 3B: (在结尾加入 FC 模式提取)
        // -------------------------------------------------------------
        else if (layer_mode == 2'd3) begin
            // FC: 严格对齐 PyTorch (NCHW) 的 Flatten 逻辑！
            // 确保最高位 p=287 接收的是 C0_H0，最低位 p=0 接收的是 C31_H8
            for (r = 0; r < 9; r = r + 1) begin
                for (c = 0; c < 32; c = c + 1) begin
                    // ✅ 终极修正：p = 287 - (c * 9 + r)
                    act_in_flat[ (287 - (c * 9 + r)) * 8 +: 8 ] = db_wire[9-r][c*8 +: 8];
                end
            end
        end
    end

    

endmodule
```

### `Syn/rtl/mac_array.v`

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
    reg signed [31:0] sum_fc; // 新增 FC 累加器

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
        // --- D. FC 加法树 (1 组，累加 288 个点) ---
        sum_fc = 32'sd0;
        for (n = 0; n < 288; n = n + 1) begin
            sum_fc = sum_fc + mult_out[n];
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
                
                2'd3: begin // === FC 模式 ===
                    psum_out_flat[31:0] <= sum_fc; // 只有节点 0 有效
                    for (k = 1; k < 32; k = k + 1) begin
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

### `Syn/rtl/maxpool_unit.v`

```verilog
`timescale 1ns / 1ps

module maxpool_unit (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 pool_start,  
    input  wire [255:0]         sram_rdata,  
    
    output reg  [9:0]           sram_raddr,
    output reg  [9:0]           sram_waddr,
    output wire [255:0]         sram_wdata,
    output reg                  sram_wen,    
    output reg                  pool_done
);

    reg [5:0] addr_cnt;     // 发送地址计数器
    reg [5:0] process_cnt;  // 接收数据计数器
    reg [3:0] out_cnt;      // 写回 SRAM 计数器
    reg       req_valid;
    reg       req_valid_d1;
    reg       req_valid_d2; // 延迟 2 拍，正好对齐 SRAM 的读出延迟
    reg       is_working;

    // 所有控制信号整合在唯一的 always 块中，彻底消灭多驱动！
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            addr_cnt     <= 0;
            process_cnt  <= 0;
            out_cnt      <= 0;
            is_working   <= 0;
            pool_done    <= 0;
            req_valid    <= 0;
            req_valid_d1 <= 0;
            req_valid_d2 <= 0;
            sram_wen     <= 1;
            sram_raddr   <= 0;
            sram_waddr   <= 0;
        end else begin
            pool_done    <= 0;
            sram_wen     <= 1;
            req_valid_d1 <= req_valid;
            req_valid_d2 <= req_valid_d1; // 打 2 拍，等待数据到达

            if (pool_start) begin
                is_working   <= 1;
                addr_cnt     <= 0;
                process_cnt  <= 0;
                out_cnt      <= 0;
                req_valid    <= 1;
            end else if (is_working) begin
                
                // 1. 发送读地址 (T+0)
                if (req_valid) begin
                    sram_raddr <= addr_cnt;
                    if (addr_cnt == 35) begin
                        req_valid <= 0; // 36个点发完，停止请求
                    end
                    addr_cnt <= addr_cnt + 1'b1;
                end
                
                // 2. 接收数据并处理写回 (T+2)
                if (req_valid_d2) begin
                    if (process_cnt % 4 == 3) begin
                        sram_wen   <= 0;
                        sram_waddr <= out_cnt;
                        if (out_cnt == 8) begin
                            pool_done  <= 1;  // 发送完成脉冲
                            is_working <= 0;  // 功德圆满，下班
                        end
                        out_cnt <= out_cnt + 1'b1;
                    end
                    process_cnt <= process_cnt + 1'b1;
                end
            end
        end
    end

    // 32通道并行比较器 (纯正流水线，不污染状态机)
    reg signed [7:0] max_reg [0:31];
    genvar g;
    generate
        for (g = 0; g < 32; g = g + 1) begin : gen_max
            wire signed [7:0] cur_data = sram_rdata[g*8 +: 8];
            assign sram_wdata[g*8 +: 8] = max_reg[g];
            
            always @(posedge clk) begin
                if (is_working && req_valid_d2) begin
                    if (process_cnt % 4 == 0) begin
                        max_reg[g] <= cur_data; // 第 1 个点直接覆盖
                    end else begin
                        if (cur_data > max_reg[g]) max_reg[g] <= cur_data; // 后面 3 个点取 Max
                    end
                end
            end
        end
    endgenerate

endmodule
```

### `Syn/rtl/output_staging_buffer.v`

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
    output reg  [7:0]       staging_waddr,
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
                    // 【Conv1】: 8 批 32-bit 拼装，使用标准 case 替代动态切片
                    case (act_waddr_sync[2:0])
                        3'd0: buffer[31:0]    <= act_out_flat[31:0];
                        3'd1: buffer[63:32]   <= act_out_flat[31:0];
                        3'd2: buffer[95:64]   <= act_out_flat[31:0];
                        3'd3: buffer[127:96]  <= act_out_flat[31:0];
                        3'd4: buffer[159:128] <= act_out_flat[31:0];
                        3'd5: buffer[191:160] <= act_out_flat[31:0];
                        3'd6: buffer[223:192] <= act_out_flat[31:0];
                        3'd7: buffer[255:224] <= act_out_flat[31:0];
                    endcase
                    
                    if (act_waddr_sync[2:0] == 3'd7) begin
                        staging_wen   <= 1'b0; // 满仓！发车！
                        staging_wdata <= {act_out_flat[31:0], buffer[223:0]};
                        staging_waddr <= act_waddr_sync[9:3]; 
                    end
                end 
                else if (layer_mode_sync == 2'd1) begin
                    // 【DWConv】: 1 批 256-bit 直接写
                    staging_wen   <= 1'b0;
                    staging_wdata <= act_out_flat;
                    staging_waddr <= act_waddr_sync;
                end 
                else if (layer_mode_sync == 2'd2) begin
                    // 【PWConv】: 4 批 64-bit 拼装，使用标准 case 替代动态切片
                    case (act_waddr_sync[1:0])
                        2'd0: buffer[63:0]    <= act_out_flat[63:0];
                        2'd1: buffer[127:64]  <= act_out_flat[63:0];
                        2'd2: buffer[191:128] <= act_out_flat[63:0];
                        2'd3: buffer[255:192] <= act_out_flat[63:0];
                    endcase
                    
                    if (act_waddr_sync[1:0] == 2'd3) begin
                        staging_wen   <= 1'b0;
                        staging_wdata <= {act_out_flat[63:0], buffer[191:0]};
                        staging_waddr <= act_waddr_sync[9:2]; 
                    end
                end
            end
        end
    end

endmodule
```

### `Syn/rtl/param_rom.v`

```verilog
`timescale 1ns / 1ps

// ==========================================================================
// 模块名称: param_rom (硬编码参数路由中心)
// 功能描述: 
//   1. 抛弃不可综合的 reg 数组和 $readmemh。
//   2. 直接使用助教提供的 assign 拼接语法，将参数固化为物理连线。
//   3. 零面积开销：综合工具会将其映射为 Tie-High / Tie-Low 单元。
// ==========================================================================

module param_rom (
    input  wire         clk,          
    input  wire [1:0]   layer_mode,   
    input  wire [3:0]   ch_grp_cnt,   
    
    output reg [2463:0] wgt_in_flat,  
    output reg [511:0]  bias_in_flat  
);

    // ======================================================================
    // 1. 将助教的硬编码参数直接粘贴为模块内部的 wire
    // ⚠️ 注意：下面的 {} 中我只保留了开头几个数据示意，请务必将助教
    // CNN_top.v 里的完整数据串复制替换到对应的 {} 内部！
    // ======================================================================
    
    // 【第一层】32通道 * 16bit = 512bit, 32*11*7 * 8bit = 19712bit
    wire [511:0] bias_1={
    16'd5904,16'd4582,-16'd893,16'd807,16'd2672,-16'd6028,-16'd3779,16'd4636,16'd3566,16'd365,-16'd6147,16'd1226,16'd2838,16'd3038,16'd3922,-16'd5385,16'd1529,16'd876,-16'd3797,-16'd97,16'd3457,-16'd726,-16'd5669,16'd3191,-16'd2720,-16'd3804,-16'd2984,16'd891,-16'd5433,-16'd4078,-16'd4930,16'd5426
    };
    wire [19711:0] weight_1={
    -8'd58, -8'd4, -8'd29, -8'd4, -8'd5, -8'd51, -8'd8, -8'd5, 8'd32, -8'd39, -8'd29, -8'd52, -8'd57, 8'd11, -8'd50, 8'd48, 8'd48, -8'd36, -8'd28, -8'd23, -8'd13, -8'd30, -8'd43, 8'd18, -8'd4, 8'd2, -8'd20, 8'd32, -8'd15, -8'd7, -8'd64, -8'd25, -8'd42, 8'd3, -8'd60, 8'd6, 8'd30, -8'd58, -8'd28, -8'd57, 8'd14, -8'd27, -8'd0, -8'd52, 8'd3, -8'd5, -8'd14, 8'd6, -8'd45, -8'd39, -8'd47, 8'd42, -8'd8, -8'd37, -8'd17, 8'd20, -8'd23, 8'd57, -8'd7, 8'd14, -8'd7, -8'd42, 8'd14, -8'd56, -8'd5, 8'd6, -8'd21, 8'd46, -8'd0, 8'd37, 8'd47, 8'd19, 8'd24, 8'd16, -8'd16, 8'd5, -8'd43, 8'd3, -8'd16, -8'd39, -8'd53, -8'd28, -8'd78, -8'd36, 8'd66, -8'd5, 8'd5, -8'd26, -8'd24, 8'd36, 8'd43, -8'd64, -8'd15, -8'd6, 8'd42, 8'd1, -8'd18, -8'd63, -8'd48, -8'd51, -8'd52, 8'd16, 8'd31, -8'd44, 8'd18, -8'd60, 8'd22, -8'd0, -8'd77, -8'd8, 8'd7, 8'd61, -8'd2, 8'd80, 8'd30, -8'd22, -8'd3, 8'd30, -8'd60, 8'd50, 8'd30, -8'd23, 8'd50, 8'd64, -8'd73, -8'd26, -8'd13, -8'd11, 8'd42, -8'd76, 8'd18, -8'd57, -8'd53, 8'd76, -8'd37, 8'd52, 8'd25, 8'd52, -8'd43, 8'd51, -8'd45, -8'd37, 8'd24, -8'd31, -8'd49, 8'd1, 8'd20, -8'd68, -8'd31, 8'd6, -8'd62, -8'd37, -8'd57, 8'd9, 8'd79, 8'd34, 8'd22, -8'd76, -8'd51, 8'd80, 8'd73, -8'd85, 8'd17, 8'd71, -8'd70, 8'd88, 8'd82, -8'd92, 8'd52, 8'd14, -8'd22, 8'd20, -8'd15, 8'd5, -8'd14, 8'd39, 8'd62, -8'd101, -8'd54, -8'd57, -8'd19, 8'd10, 8'd63, 8'd18, 8'd66, 8'd19, 8'd105, -8'd70, 8'd83, -8'd44, 8'd58, -8'd47, 8'd68, 8'd66, -8'd10, -8'd55, 8'd41, -8'd73, -8'd84, 8'd57, -8'd0, 8'd70, -8'd70, 8'd73, 8'd12, 8'd44, -8'd27, -8'd28, 8'd98, -8'd53, -8'd82, 8'd75, 8'd8, -8'd7, 8'd8, 8'd42, 8'd15, 8'd2, 8'd83, 8'd14, -8'd43, -8'd64, 8'd37, 8'd1, -8'd10, 8'd82, -8'd29, 8'd30, -8'd14, -8'd36, 8'd19, 8'd14, -8'd27, 8'd44, 8'd52, 8'd73, 8'd104, -8'd60, -8'd8, 8'd20, -8'd1, -8'd20, -8'd31, 8'd49, -8'd50, 8'd71, 8'd13, -8'd17, -8'd11, 8'd91, 8'd41, -8'd58, -8'd73, -8'd58, 8'd31, -8'd61, -8'd20, -8'd32, 8'd49, -8'd2, 8'd7, 8'd62, -8'd12, 8'd81, 8'd6, -8'd40, -8'd29, -8'd9, 8'd37, 8'd59, 8'd44, 8'd64, -8'd55, 8'd79, -8'd54, -8'd0, 8'd17, 8'd20, -8'd43, 8'd53, 8'd75, -8'd76, 8'd42, 8'd37, 8'd29, 8'd23, -8'd32, 8'd1, 8'd42, -8'd18, -8'd3, -8'd21, 8'd20, -8'd57, -8'd89, -8'd56, 8'd20, 8'd57, 8'd19, -8'd23, 8'd89, 8'd69, -8'd20, -8'd28, 8'd10, -8'd50, -8'd4, -8'd34, -8'd20, 8'd53, -8'd44, -8'd31, -8'd79, 8'd49, 8'd42, -8'd55, 8'd35, 8'd14, 8'd75, -8'd59, -8'd66, -8'd38, 8'd62, -8'd12, -8'd17, 8'd25, 8'd55, -8'd46, -8'd41, -8'd58, 8'd86, -8'd6, 8'd42, -8'd80, -8'd1, 8'd34, 8'd47, 8'd45, 8'd33, 8'd11, -8'd25, -8'd5, -8'd49, 8'd16, 8'd65, -8'd0, 8'd5, -8'd21, 8'd24, -8'd28, 8'd15, 8'd10, -8'd41, 8'd12, 8'd33, 8'd77, -8'd34, 8'd23, -8'd38, 8'd49, -8'd60, -8'd52, 8'd6, 8'd10, -8'd49, 8'd63, -8'd8, -8'd43, -8'd24, -8'd57, 8'd3, 8'd38, 8'd67, 8'd56, -8'd18, -8'd40, 8'd68, -8'd23, -8'd23, -8'd18, 8'd6, -8'd28, 8'd8, 8'd31, 8'd61, 8'd28, 8'd30, -8'd1, -8'd51, 8'd43, 8'd32, 8'd29, 8'd16, 8'd52, -8'd77, 8'd49, 8'd66, -8'd55, 8'd1, -8'd53, -8'd73, 8'd62, -8'd10, -8'd15, 8'd58, 8'd77, -8'd45, 8'd3, 8'd3, -8'd7, 8'd44, -8'd41, 8'd56, 8'd42, 8'd40, -8'd43, 8'd36, 8'd66, 8'd73, 8'd71, 8'd66, 8'd8, 8'd20, -8'd9, 8'd62, 8'd48, 8'd40, -8'd43, 8'd4, -8'd66, -8'd55, -8'd56, 8'd45, -8'd16, -8'd27, 8'd3, 8'd38, 8'd15, 8'd51, 8'd27, -8'd12, -8'd75, -8'd68, 8'd26, 8'd7, -8'd33, 8'd18, -8'd37, 8'd64, -8'd31, 8'd30, -8'd33, -8'd73, -8'd9, -8'd111, -8'd1, 8'd30, 8'd19, 8'd78, -8'd54, 8'd39, 8'd3, 8'd24, -8'd56, -8'd32, -8'd27, -8'd45, -8'd7, -8'd48, 8'd40, -8'd8, 8'd25, 8'd34, 8'd46, -8'd55, 8'd22, 8'd40, -8'd46, 8'd43, -8'd19, 8'd19, 8'd23, -8'd45, -8'd14, 8'd40, 8'd19, 8'd12, -8'd29, -8'd9, 8'd21, 8'd37, 8'd29, -8'd55, -8'd22, 8'd32, -8'd7, 8'd28, 8'd11, 8'd11, 8'd32, 8'd42, 8'd41, -8'd21, 8'd2, 8'd17, -8'd41, 8'd53, 8'd39, -8'd25, 8'd42, 8'd53, 8'd14, -8'd38, -8'd33, -8'd31, -8'd16, -8'd57, -8'd27, 8'd17, -8'd32, 8'd24, 8'd41, 8'd39, -8'd26, 8'd71, -8'd62, 8'd49, -8'd20, 8'd4, -8'd20, 8'd54, 8'd64, 8'd14, 8'd3, 8'd38, 8'd12, 8'd8, -8'd45, 8'd31, -8'd32, 8'd18, 8'd33, 8'd11, -8'd15, 8'd14, -8'd39, -8'd22, -8'd3, -8'd22, 8'd38, 8'd8, 8'd9, -8'd31, 8'd32, 8'd15, -8'd16, -8'd0, 8'd4, -8'd29, -8'd18, 8'd14, -8'd24, -8'd5, 8'd7, 8'd12, 8'd18, 8'd10, 8'd11, -8'd1, -8'd22, -8'd9, 8'd33, 8'd5, -8'd19, 8'd31, 8'd23, 8'd27, -8'd23, 8'd30, 8'd1, -8'd32, 8'd26, -8'd4, -8'd15, 8'd25, -8'd34, 8'd25, -8'd28, -8'd26, 8'd3, 8'd19, -8'd16, -8'd32, 8'd17, 8'd4, 8'd31, -8'd5, -8'd38, 8'd6, -8'd27, -8'd34, -8'd22, 8'd19, 8'd28, -8'd16, 8'd7, 8'd15, -8'd32, 8'd4, 8'd26, 8'd15, 8'd5, -8'd10, -8'd14, 8'd29, -8'd18, 8'd48, 8'd15, 8'd13, 8'd52, -8'd55, -8'd40, -8'd27, -8'd71, -8'd1, 8'd62, -8'd8, -8'd9, 8'd22, 8'd51, 8'd9, -8'd36, 8'd12, -8'd23, 8'd23, 8'd49, -8'd12, 8'd56, 8'd15, 8'd64, -8'd57, -8'd61, -8'd14, 8'd55, -8'd56, -8'd52, -8'd44, -8'd17, -8'd62, 8'd22, -8'd28, 8'd32, -8'd5, 8'd15, -8'd12, -8'd39, -8'd52, -8'd54, 8'd55, -8'd72, -8'd14, 8'd37, -8'd2, 8'd62, -8'd26, 8'd13, 8'd9, 8'd7, -8'd13, -8'd68, -8'd4, -8'd65, -8'd65, -8'd38, 8'd43, -8'd44, -8'd66, 8'd57, -8'd71, -8'd9, -8'd0, -8'd66, -8'd4, 8'd26, 8'd40, 8'd13, -8'd76, -8'd12, -8'd64, 8'd28, 8'd46, -8'd39, 8'd44, 8'd42, 8'd37, -8'd50, 8'd38, -8'd97, 8'd11, 8'd65, -8'd30, -8'd86, -8'd73, 8'd57, 8'd54, 8'd88, -8'd99, -8'd44, -8'd77, 8'd42, 8'd29, -8'd32, 8'd37, -8'd74, 8'd55, -8'd11, -8'd73, -8'd27, -8'd57, -8'd75, 8'd22, -8'd117, -8'd116, -8'd0, 8'd72, 8'd40, 8'd18, 8'd27, 8'd59, 8'd11, -8'd118, -8'd65, -8'd26, 8'd12, 8'd64, -8'd41, 8'd56, -8'd113, 8'd3, 8'd45, 8'd68, 8'd16, -8'd19, -8'd62, 8'd2, -8'd73, -8'd29, -8'd49, 8'd7, 8'd62, -8'd71, -8'd18, -8'd49, 8'd86, -8'd28, 8'd19, -8'd34, -8'd37, -8'd85, -8'd41, -8'd14, -8'd85, -8'd57, 8'd16, -8'd60, -8'd59, 8'd46, 8'd47, -8'd56, 8'd34, -8'd1, -8'd8, 8'd11, -8'd8, -8'd27, -8'd10, 8'd33, -8'd2, -8'd2, -8'd4, -8'd13, 8'd46, -8'd26, 8'd33, -8'd36, 8'd20, -8'd20, 8'd39, 8'd32, 8'd6, 8'd49, -8'd15, -8'd5, 8'd29, -8'd1, -8'd40, 8'd32, 8'd3, -8'd11, -8'd37, 8'd45, 8'd1, -8'd5, 8'd35, 8'd10, -8'd19, -8'd7, 8'd2, 8'd42, -8'd13, -8'd1, -8'd32, 8'd30, 8'd2, 8'd32, -8'd32, -8'd2, 8'd8, 8'd47, 8'd19, -8'd33, 8'd24, 8'd38, 8'd46, 8'd32, -8'd16, -8'd31, -8'd19, 8'd32, -8'd33, 8'd35, 8'd35, 8'd17, -8'd31, -8'd3, -8'd8, 8'd7, -8'd5, 8'd11, -8'd20, -8'd4, 8'd47, 8'd14, -8'd36, -8'd37, 8'd39, 8'd33, -8'd35, -8'd63, 8'd58, -8'd41, -8'd33, 8'd24, 8'd24, 8'd30, 8'd51, 8'd17, -8'd58, 8'd55, -8'd103, -8'd37, 8'd65, -8'd58, 8'd35, -8'd6, -8'd71, -8'd43, -8'd25, 8'd33, 8'd1, -8'd78, -8'd37, 8'd75, 8'd3, 8'd36, 8'd74, -8'd28, -8'd20, 8'd45, -8'd38, 8'd49, 8'd11, -8'd56, -8'd43, 8'd63, -8'd5, -8'd15, -8'd59, 8'd47, -8'd30, 8'd41, 8'd84, 8'd26, -8'd58, -8'd4, -8'd26, 8'd28, -8'd13, 8'd31, -8'd36, 8'd18, -8'd64, -8'd15, 8'd45, -8'd47, -8'd11, -8'd28, 8'd36, -8'd65, 8'd55, 8'd72, 8'd61, -8'd55, 8'd37, -8'd84, -8'd40, 8'd47, 8'd53, -8'd8, 8'd69, -8'd26, 8'd8, 8'd51, -8'd25, 8'd17, -8'd34, 8'd93, 8'd76, 8'd69, -8'd25, -8'd0, 8'd20, -8'd21, -8'd59, 8'd16, 8'd67, 8'd34, -8'd24, 8'd11, -8'd37, -8'd65, -8'd17, 8'd67, 8'd47, -8'd36, -8'd2, -8'd60, 8'd40, -8'd17, -8'd77, -8'd18, -8'd32, 8'd12, 8'd31, 8'd13, 8'd45, -8'd42, 8'd48, -8'd61, -8'd34, 8'd72, -8'd36, -8'd78, 8'd50, 8'd72, -8'd62, 8'd57, 8'd58, 8'd13, -8'd47, -8'd55, 8'd22, 8'd36, 8'd12, 8'd64, -8'd27, 8'd9, 8'd28, -8'd14, -8'd14, -8'd61, -8'd70, 8'd63, -8'd70, -8'd0, 8'd44, -8'd34, -8'd77, -8'd48, 8'd71, -8'd12, -8'd18, -8'd32, 8'd69, 8'd68, 8'd66, -8'd25, 8'd37, -8'd59, -8'd0, -8'd36, 8'd71, -8'd82, 8'd37, -8'd13, 8'd36, -8'd55, 8'd53, 8'd64, -8'd2, -8'd32, -8'd29, 8'd39, -8'd5, 8'd4, 8'd26, 8'd47, 8'd32, 8'd60, 8'd96, 8'd52, -8'd48, 8'd89, -8'd47, -8'd75, -8'd80, 8'd91, 8'd63, 8'd9, 8'd86, 8'd59, -8'd59, -8'd51, -8'd1, -8'd49, 8'd2, -8'd17, 8'd30, -8'd66, -8'd35, 8'd83, -8'd70, -8'd71, 8'd21, 8'd35, -8'd91, 8'd34, 8'd15, 8'd32, -8'd80, 8'd76, -8'd62, -8'd40, 8'd9, 8'd21, -8'd48, 8'd4, -8'd72, 8'd4, 8'd40, -8'd76, -8'd45, 8'd59, 8'd35, 8'd38, -8'd79, 8'd56, -8'd28, 8'd5, -8'd12, -8'd69, 8'd69, -8'd37, -8'd20, 8'd31, -8'd37, -8'd36, 8'd18, 8'd30, 8'd48, -8'd36, 8'd32, 8'd27, 8'd12, -8'd39, 8'd38, -8'd31, -8'd40, -8'd34, 8'd14, -8'd6, -8'd42, 8'd2, 8'd21, 8'd26, -8'd34, 8'd44, -8'd40, -8'd37, -8'd32, -8'd25, 8'd40, 8'd20, 8'd33, -8'd41, -8'd17, -8'd50, 8'd6, -8'd31, 8'd45, -8'd11, -8'd2, -8'd9, -8'd32, -8'd6, 8'd21, 8'd40, -8'd17, 8'd50, -8'd26, -8'd26, -8'd29, 8'd46, -8'd37, 8'd48, 8'd32, -8'd5, 8'd4, 8'd47, 8'd39, 8'd45, 8'd50, -8'd1, -8'd17, -8'd20, 8'd9, 8'd42, 8'd41, 8'd1, 8'd43, -8'd40, -8'd17, 8'd22, 8'd12, 8'd17, 8'd28, -8'd33, 8'd27, 8'd17, -8'd11, -8'd37, 8'd50, -8'd27, -8'd22, -8'd15, -8'd23, -8'd11, 8'd17, 8'd12, -8'd27, 8'd19, 8'd26, 8'd30, 8'd18, -8'd6, -8'd19, 8'd34, 8'd15, -8'd0, -8'd9, 8'd27, -8'd4, 8'd7, 8'd17, 8'd39, 8'd15, 8'd19, 8'd35, -8'd37, -8'd35, 8'd12, -8'd27, 8'd29, -8'd32, -8'd46, 8'd2, -8'd3, -8'd16, 8'd2, 8'd30, -8'd9, 8'd2, -8'd11, -8'd10, -8'd14, 8'd19, 8'd47, -8'd0, -8'd40, 8'd26, -8'd28, 8'd29, -8'd9, -8'd8, 8'd8, 8'd2, -8'd34, -8'd24, 8'd27, 8'd16, 8'd25, 8'd1, -8'd2, 8'd21, -8'd0, -8'd6, 8'd28, -8'd25, -8'd16, 8'd18, 8'd15, -8'd28, -8'd8, -8'd19, 8'd43, 8'd23, 8'd1, -8'd19, -8'd5, -8'd4, -8'd19, 8'd8, -8'd6, 8'd66, 8'd37, 8'd64, -8'd78, 8'd36, -8'd58, -8'd71, 8'd26, 8'd32, -8'd29, 8'd67, 8'd20, 8'd51, 8'd2, 8'd59, 8'd14, -8'd45, 8'd22, 8'd34, 8'd19, -8'd31, -8'd64, 8'd25, -8'd29, -8'd0, 8'd88, -8'd34, -8'd99, -8'd66, 8'd18, -8'd58, 8'd67, 8'd76, -8'd40, -8'd17, -8'd73, 8'd60, 8'd49, -8'd13, -8'd0, -8'd45, -8'd65, -8'd42, -8'd52, -8'd36, 8'd21, 8'd13, 8'd20, -8'd79, -8'd52, 8'd4, 8'd12, 8'd66, 8'd56, 8'd59, 8'd35, -8'd7, 8'd17, -8'd59, 8'd20, 8'd32, -8'd57, -8'd3, 8'd73, 8'd60, -8'd23, -8'd29, -8'd55, -8'd40, -8'd65, 8'd90, 8'd53, 8'd40, 8'd39, -8'd71, -8'd93, -8'd49, -8'd50, 8'd11, 8'd12, -8'd16, -8'd27, -8'd91, 8'd25, -8'd92, 8'd69, 8'd50, -8'd7, 8'd56, 8'd7, -8'd62, 8'd13, 8'd9, 8'd12, -8'd31, 8'd64, -8'd89, -8'd3, -8'd47, 8'd7, 8'd90, -8'd111, 8'd42, -8'd75, 8'd94, 8'd3, -8'd2, -8'd10, 8'd31, -8'd0, -8'd52, -8'd100, 8'd93, 8'd107, -8'd86, 8'd25, 8'd65, 8'd89, -8'd36, -8'd58, 8'd86, 8'd64, -8'd39, -8'd52, -8'd15, 8'd53, -8'd34, 8'd112, -8'd84, -8'd58, -8'd67, -8'd83, -8'd128, 8'd64, -8'd34, 8'd44, 8'd99, 8'd51, -8'd6, -8'd51, -8'd52, 8'd104, 8'd88, 8'd77, 8'd59, 8'd79, 8'd38, -8'd75, -8'd80, -8'd10, 8'd97, -8'd12, 8'd77, 8'd67, 8'd44, -8'd63, -8'd30, -8'd87, -8'd4, 8'd43, 8'd58, 8'd57, 8'd38, -8'd8, -8'd81, 8'd18, -8'd38, -8'd23, -8'd34, -8'd95, -8'd23, 8'd45, 8'd77, 8'd60, 8'd47, -8'd9, 8'd53, -8'd0, -8'd34, -8'd82, -8'd44, 8'd66, -8'd48, -8'd110, 8'd55, 8'd29, 8'd5, 8'd40, -8'd8, -8'd8, 8'd63, 8'd44, -8'd1, -8'd85, 8'd8, -8'd69, -8'd30, -8'd73, -8'd62, 8'd1, -8'd68, 8'd4, -8'd19, 8'd58, 8'd40, 8'd97, -8'd68, 8'd86, 8'd98, -8'd43, -8'd20, -8'd14, 8'd47, -8'd57, 8'd3, 8'd18, -8'd83, -8'd32, -8'd38, 8'd99, 8'd26, 8'd27, 8'd52, -8'd45, -8'd50, -8'd20, -8'd18, -8'd43, -8'd34, -8'd3, -8'd43, 8'd14, -8'd29, 8'd1, -8'd41, -8'd13, -8'd47, -8'd41, 8'd8, 8'd68, -8'd24, 8'd9, 8'd44, -8'd50, -8'd10, 8'd10, -8'd9, -8'd22, -8'd75, 8'd59, -8'd15, -8'd54, 8'd24, 8'd25, 8'd1, -8'd6, 8'd53, 8'd25, -8'd42, 8'd15, -8'd54, 8'd17, 8'd16, -8'd24, 8'd18, -8'd43, 8'd51, 8'd2, 8'd16, 8'd31, 8'd74, -8'd56, 8'd35, 8'd42, 8'd26, -8'd12, 8'd39, 8'd27, 8'd43, -8'd40, -8'd32, -8'd5, -8'd40, -8'd30, 8'd30, -8'd2, -8'd4, 8'd59, -8'd15, -8'd30, -8'd0, -8'd14, -8'd59, 8'd64, 8'd60, -8'd26, 8'd32, 8'd23, 8'd50, 8'd45, 8'd32, -8'd34, 8'd68, -8'd15, -8'd8, 8'd13, -8'd10, 8'd54, -8'd24, 8'd56, 8'd48, 8'd41, -8'd34, -8'd14, -8'd23, -8'd10, -8'd0, 8'd23, -8'd22, 8'd54, -8'd23, 8'd55, -8'd44, 8'd24, 8'd5, 8'd5, -8'd55, 8'd25, 8'd14, 8'd22, -8'd7, 8'd50, 8'd29, -8'd24, 8'd30, -8'd44, -8'd15, 8'd68, 8'd26, 8'd16, 8'd27, -8'd40, -8'd59, 8'd23, -8'd6, 8'd13, 8'd31, 8'd29, -8'd29, 8'd13, 8'd23, -8'd11, 8'd30, -8'd32, 8'd22, -8'd73, -8'd55, -8'd31, 8'd9, -8'd55, -8'd24, 8'd33, -8'd39, -8'd59, -8'd42, 8'd61, 8'd26, 8'd1, 8'd10, -8'd60, 8'd40, -8'd2, 8'd64, 8'd25, -8'd47, 8'd19, 8'd30, 8'd51, 8'd27, 8'd65, 8'd1, 8'd43, -8'd23, -8'd9, 8'd38, 8'd45, 8'd14, -8'd6, -8'd2, 8'd10, 8'd24, 8'd10, 8'd21, -8'd14, -8'd63, 8'd31, -8'd53, -8'd4, -8'd33, -8'd23, 8'd48, -8'd23, 8'd6, -8'd44, 8'd18, 8'd6, -8'd20, 8'd38, -8'd25, -8'd39, -8'd28, -8'd0, 8'd23, -8'd45, -8'd42, 8'd43, 8'd51, 8'd27, 8'd12, 8'd48, 8'd39, 8'd16, 8'd1, -8'd50, -8'd44, 8'd45, -8'd39, 8'd33, 8'd25, -8'd32, 8'd41, -8'd54, 8'd27, -8'd43, 8'd27, 8'd28, -8'd22, -8'd52, -8'd55, 8'd43, -8'd7, 8'd48, 8'd47, 8'd42, -8'd14, -8'd19, 8'd14, 8'd40, -8'd31, 8'd39, -8'd10, -8'd22, 8'd8, 8'd2, -8'd17, 8'd43, -8'd30, -8'd22, -8'd59, 8'd31, -8'd17, -8'd21, 8'd24, 8'd40, -8'd14, 8'd44, 8'd27, -8'd4, 8'd27, 8'd17, 8'd2, -8'd43, -8'd2, 8'd38, 8'd43, 8'd13, 8'd39, 8'd31, 8'd8, 8'd40, -8'd35, 8'd11, -8'd2, 8'd39, -8'd29, 8'd17, -8'd20, -8'd5, -8'd17, -8'd6, 8'd38, 8'd37, 8'd35, 8'd7, 8'd10, -8'd7, 8'd37, -8'd7, -8'd6, 8'd39, 8'd11, -8'd45, -8'd24, -8'd2, -8'd31, 8'd37, 8'd40, 8'd44, 8'd31, 8'd23, -8'd2, -8'd14, 8'd24, 8'd9, 8'd35, -8'd6, -8'd10, 8'd1, 8'd44, 8'd27, -8'd27, 8'd13, 8'd45, 8'd43, 8'd9, 8'd41, 8'd21, -8'd15, -8'd45, 8'd17, 8'd49, -8'd9, 8'd42, -8'd28, 8'd3, -8'd17, 8'd5, 8'd44, 8'd88, -8'd122, -8'd26, 8'd106, 8'd12, -8'd100, 8'd106, 8'd65, -8'd74, -8'd61, 8'd103, -8'd35, -8'd47, 8'd97, -8'd48, 8'd4, -8'd61, 8'd60, -8'd42, 8'd43, -8'd84, -8'd49, -8'd115, -8'd103, -8'd55, -8'd15, -8'd35, -8'd50, 8'd81, -8'd7, 8'd71, 8'd2, -8'd63, -8'd34, -8'd80, 8'd85, 8'd62, 8'd53, 8'd64, -8'd25, 8'd22, -8'd29, 8'd74, -8'd51, 8'd2, 8'd16, 8'd32, -8'd118, -8'd23, 8'd47, -8'd5, -8'd3, 8'd95, -8'd76, 8'd49, 8'd24, -8'd58, 8'd1, -8'd70, 8'd93, -8'd38, -8'd50, 8'd39, -8'd26, -8'd39, 8'd26, 8'd55, -8'd28, -8'd24, -8'd56, 8'd47, -8'd106, 8'd44, -8'd2, 8'd66, -8'd4, 8'd75, 8'd21, 8'd11, -8'd45, -8'd3, 8'd22, 8'd5, -8'd12, 8'd1, 8'd3, 8'd10, -8'd2, -8'd13, -8'd46, 8'd8, -8'd37, 8'd43, 8'd14, 8'd37, 8'd4, 8'd46, 8'd33, 8'd3, -8'd30, -8'd39, -8'd29, 8'd38, -8'd34, -8'd10, -8'd30, -8'd39, -8'd17, -8'd2, 8'd11, -8'd24, 8'd80, 8'd32, -8'd15, -8'd31, 8'd3, 8'd4, 8'd15, 8'd30, -8'd33, 8'd13, -8'd8, -8'd38, -8'd30, -8'd20, 8'd60, 8'd15, -8'd4, 8'd37, -8'd19, 8'd62, -8'd21, 8'd55, 8'd37, -8'd5, -8'd35, 8'd38, 8'd47, -8'd45, -8'd23, 8'd28, 8'd8, 8'd49, -8'd19, 8'd15, -8'd41, -8'd41, 8'd13, 8'd56, 8'd7, 8'd53, -8'd26, 8'd22, -8'd18, -8'd40, -8'd34, 8'd75, -8'd10, 8'd38, -8'd40, -8'd11, -8'd32, -8'd32, -8'd11, 8'd14, -8'd2, 8'd44, 8'd33, 8'd47, -8'd60, 8'd71, 8'd24, 8'd45, -8'd1, 8'd3, -8'd24, -8'd26, 8'd18, -8'd29, 8'd38, 8'd21, 8'd60, 8'd5, -8'd20, 8'd17, -8'd8, -8'd49, -8'd44, 8'd32, -8'd15, -8'd53, 8'd7, -8'd25, 8'd8, 8'd29, 8'd54, 8'd23, 8'd40, 8'd46, 8'd11, -8'd54, -8'd0, -8'd27, 8'd39, -8'd46, -8'd28, -8'd31, 8'd3, -8'd35, -8'd30, 8'd28, -8'd61, -8'd25, -8'd27, -8'd54, 8'd9, 8'd51, -8'd47, 8'd41, 8'd3, 8'd25, 8'd21, -8'd17, 8'd37, 8'd18, -8'd3, -8'd18, -8'd26, -8'd28, 8'd21, -8'd36, 8'd33, 8'd22, -8'd51, 8'd31, -8'd67, -8'd33, -8'd46, -8'd58, 8'd75, -8'd3, -8'd66, 8'd25, 8'd30, 8'd13, -8'd85, 8'd59, 8'd19, -8'd61, -8'd0, -8'd59, -8'd41, 8'd11, -8'd53, -8'd48, 8'd52, -8'd45, 8'd66, 8'd88, 8'd74, -8'd64, -8'd68, 8'd52, 8'd57, 8'd61, 8'd53, 8'd42, -8'd25, -8'd45, -8'd21, -8'd61, 8'd38, 8'd96, 8'd18, -8'd62, 8'd60, -8'd9, -8'd44, -8'd16, 8'd59, 8'd40, -8'd47, -8'd13, -8'd64, -8'd62, 8'd57, 8'd58, 8'd7, -8'd67, 8'd21, -8'd40, 8'd11, -8'd54, 8'd63, -8'd22, 8'd52, 8'd46, -8'd52, 8'd62, -8'd62, -8'd75, -8'd57, 8'd23, 8'd65, 8'd65, -8'd45, -8'd84, -8'd77, -8'd18, -8'd28, -8'd20, -8'd29, -8'd64, -8'd3, -8'd5, 8'd43, -8'd25, 8'd25, 8'd11, -8'd56, -8'd9, 8'd63, 8'd38, 8'd57, -8'd53, -8'd9, -8'd67, -8'd34, 8'd3, -8'd63, -8'd10, -8'd5, -8'd30, -8'd54, -8'd73, 8'd5, -8'd0, 8'd6, -8'd41, -8'd2, 8'd38, 8'd56, 8'd22, 8'd42, 8'd69, -8'd28, 8'd34, 8'd3, -8'd46, 8'd34, 8'd37, -8'd31, 8'd1, -8'd66, 8'd64, -8'd72, 8'd27, -8'd49, 8'd73, -8'd57, -8'd48, -8'd13, 8'd12, -8'd7, -8'd9, -8'd9, -8'd62, 8'd57, 8'd9, -8'd35, 8'd27, 8'd6, -8'd56, -8'd64, -8'd27, -8'd10, 8'd1, -8'd8, 8'd17, -8'd67, -8'd38, 8'd27, -8'd39, -8'd52, -8'd15, 8'd63, -8'd41, 8'd57, 8'd46, -8'd1, 8'd35, 8'd78, 8'd3, -8'd49, 8'd15, 8'd37, -8'd61, -8'd54, 8'd51, -8'd41, 8'd20, 8'd15, -8'd37, -8'd35, 8'd29, 8'd26, 8'd22, -8'd13, -8'd15, 8'd35, -8'd46, 8'd10, -8'd12, -8'd0, 8'd53, -8'd37, -8'd17, -8'd15, -8'd19, 8'd62, 8'd70, -8'd36, 8'd9, -8'd20, 8'd42, -8'd59, 8'd32, -8'd9, -8'd30, -8'd27, -8'd37, -8'd45, 8'd34, 8'd5, 8'd45, 8'd22, 8'd46, 8'd66, -8'd2, -8'd21, 8'd27, 8'd53, -8'd15, -8'd38, 8'd5, 8'd51, 8'd44, -8'd26, 8'd63, -8'd59, -8'd35, 8'd28, 8'd25, -8'd20, -8'd29, 8'd69, 8'd50, 8'd36, 8'd13, -8'd40, 8'd49, 8'd10, 8'd4, -8'd32, -8'd12, -8'd3, -8'd73, -8'd63, 8'd52, 8'd34, -8'd22, -8'd20, 8'd45, -8'd47, 8'd50, 8'd83, -8'd14, 8'd54, -8'd68, 8'd72, -8'd68, 8'd39, -8'd40, -8'd22, -8'd39, 8'd25, 8'd49, -8'd35, -8'd50, 8'd89, 8'd27, 8'd57, -8'd50, -8'd62, 8'd51, 8'd7, 8'd13, 8'd59, -8'd0, 8'd30, -8'd58, 8'd33, 8'd41, 8'd39, -8'd50, 8'd34, 8'd22, -8'd58, -8'd60, -8'd51, 8'd20, 8'd54, 8'd52, -8'd47, 8'd71, -8'd9, 8'd5, 8'd41, 8'd20, -8'd68, -8'd8, -8'd45, -8'd12, -8'd43, -8'd47, -8'd32, 8'd11, 8'd59, -8'd18, 8'd9, -8'd49, 8'd3, -8'd60, 8'd57, -8'd17, 8'd8, -8'd4, 8'd50, -8'd3, -8'd7, 8'd23, -8'd4, 8'd21, 8'd27, -8'd13, -8'd15, 8'd51, 8'd25, 8'd16, -8'd19, -8'd16, -8'd18, 8'd14, 8'd40, -8'd2, 8'd7, 8'd23, 8'd28, 8'd4, 8'd40, 8'd44, -8'd20, -8'd40, 8'd30, 8'd20, 8'd19, 8'd52, 8'd36, 8'd18, -8'd11, 8'd14, -8'd30, 8'd23, 8'd42, -8'd38, 8'd29, 8'd34, 8'd32, -8'd35, -8'd13, 8'd32, -8'd40, 8'd30, 8'd41, -8'd1, -8'd35, 8'd5, 8'd46, -8'd13, -8'd10, -8'd7, 8'd41, 8'd11, -8'd35, 8'd6, 8'd12, -8'd45, 8'd27, -8'd36, 8'd14, 8'd1, -8'd23, -8'd31, -8'd17, 8'd34, -8'd21, -8'd33, -8'd22, -8'd29, -8'd17, -8'd19, 8'd43, 8'd36, 8'd15, 8'd23, 8'd35, -8'd56, 8'd29, -8'd72, -8'd19, -8'd84, 8'd79, -8'd34, -8'd33, -8'd62, 8'd72, -8'd76, -8'd73, -8'd7, 8'd63, 8'd75, 8'd66, -8'd30, 8'd23, -8'd54, -8'd61, 8'd80, -8'd23, -8'd27, 8'd81, 8'd16, 8'd10, -8'd12, -8'd15, 8'd18, -8'd39, -8'd23, -8'd61, 8'd62, 8'd30, 8'd8, 8'd28, -8'd43, -8'd67, -8'd101, 8'd20, 8'd71, -8'd38, -8'd1, 8'd24, 8'd22, 8'd37, 8'd3, -8'd99, -8'd53, -8'd95, -8'd44, 8'd21, -8'd17, 8'd5, 8'd46, -8'd46, -8'd26, 8'd55, 8'd12, -8'd42, 8'd64, -8'd0, -8'd30, 8'd44, -8'd62, 8'd7, -8'd36, -8'd51, -8'd58, 8'd3, -8'd37, 8'd67, 8'd1, -8'd1, -8'd73, -8'd46, -8'd63 };
    // 【第二层】32通道 * 16bit = 512bit, 32*9 * 8bit = 2304bit
    wire [511:0] bias_2={
    16'd592, 16'd1155, -16'd1094, -16'd514, 16'd348, -16'd1118, 16'd957, -16'd987, -16'd842, -16'd933, -16'd1119, -16'd751, -16'd190, -16'd461, -16'd1239, -16'd118, -16'd1440, -16'd426, -16'd889, 16'd19, 16'd614, 16'd645, 16'd1128, -16'd748, -16'd274, 16'd1102, -16'd920, -16'd1014, 16'd1016, -16'd788, -16'd1164, 16'd1009
    };
    wire [2303:0] weight_2={
    -8'd77, 8'd18, -8'd43, 8'd44, 8'd25, 8'd14, 8'd33, -8'd56, -8'd21, -8'd43, 8'd25, -8'd13, -8'd16, 8'd4, 8'd2, 8'd18, -8'd32, 8'd2, 8'd48, 8'd41, -8'd2, 8'd26, 8'd3, 8'd37, -8'd38, -8'd18, -8'd23, -8'd49, 8'd17, -8'd29, 8'd41, -8'd12, 8'd1, 8'd51, 8'd28, 8'd2, 8'd3, -8'd14, 8'd47, -8'd45, 8'd9, 8'd12, 8'd17, -8'd18, -8'd17, 8'd14, 8'd7, 8'd16, 8'd4, 8'd9, 8'd10, 8'd5, 8'd2, 8'd3, -8'd28, -8'd30, -8'd11, 8'd6, 8'd31, -8'd16, 8'd15, -8'd2, -8'd4, 8'd24, -8'd2, -8'd9, 8'd25, 8'd28, -8'd30, 8'd26, -8'd21, -8'd25, 8'd4, -8'd2, 8'd17, -8'd7, 8'd11, 8'd12, 8'd3, 8'd8, 8'd19, -8'd16, 8'd19, 8'd10, 8'd6, -8'd6, 8'd1, 8'd12, 8'd4, 8'd17, -8'd11, 8'd31, 8'd17, -8'd6, -8'd15, 8'd5, 8'd29, -8'd6, 8'd9, 8'd13, 8'd6, -8'd2, -8'd0, -8'd2, 8'd15, 8'd16, -8'd6, 8'd8, 8'd27, -8'd15, -8'd8, -8'd13, -8'd20, 8'd27, -8'd14, 8'd13, 8'd20, 8'd12, 8'd10, -8'd5, -8'd5, 8'd19, -8'd21, -8'd3, 8'd16, -8'd2, 8'd23, -8'd10, 8'd28, 8'd17, 8'd22, 8'd2, 8'd1, -8'd19, 8'd11, 8'd10, 8'd106, -8'd37, -8'd128, 8'd22, 8'd55, 8'd3, -8'd72, -8'd16, 8'd45, 8'd34, 8'd19, 8'd3, -8'd11, -8'd4, -8'd13, -8'd2, 8'd18, -8'd1, -8'd13, 8'd12, -8'd4, 8'd5, 8'd18, -8'd5, -8'd15, 8'd16, 8'd21, -8'd6, 8'd15, -8'd26, 8'd26, 8'd16, 8'd2, -8'd11, -8'd3, 8'd4, 8'd17, -8'd27, -8'd21, -8'd25, 8'd25, 8'd12, -8'd21, 8'd27, -8'd9, 8'd23, -8'd21, -8'd16, 8'd10, 8'd9, -8'd10, -8'd3, -8'd19, -8'd28, -8'd3, -8'd7, -8'd31, 8'd30, -8'd5, 8'd15, -8'd19, -8'd0, -8'd46, -8'd52, -8'd3, 8'd50, 8'd16, 8'd16, -8'd47, 8'd27, -8'd42, 8'd41, -8'd35, -8'd3, -8'd11, -8'd8, 8'd14, 8'd22, 8'd24, 8'd3, -8'd33, -8'd13, -8'd12, -8'd23, 8'd34, -8'd15, -8'd22, 8'd30, 8'd37, -8'd15, -8'd20, -8'd2, 8'd4, 8'd12, -8'd17, 8'd18, -8'd18, -8'd11, -8'd7, -8'd3, 8'd15, 8'd14, 8'd12, -8'd2, -8'd9, 8'd15, 8'd14, 8'd11, 8'd1, -8'd1, 8'd6, 8'd10, 8'd5, 8'd13, -8'd1, 8'd14, -8'd2, 8'd14, -8'd4, -8'd10, -8'd20, -8'd22, 8'd51, -8'd5, -8'd6, -8'd3, 8'd6, 8'd12, 8'd5, 8'd8, 8'd12, -8'd12, -8'd7, 8'd5, -8'd13, 8'd13, 8'd18, 8'd6, 8'd12, -8'd0, 8'd25, 8'd24, 8'd7, -8'd12, -8'd5, 8'd37, -8'd36, 8'd10, 8'd22, -8'd7, 8'd5, -8'd8
    };
    // 【第三层】32通道 * 16bit = 512bit, 32*32 * 8bit = 8192bit
    wire [511:0] bias_3={
    -16'd1634, -16'd544, -16'd2415, -16'd2652, 16'd67, -16'd686, -16'd1977, -16'd807, -16'd1063, -16'd1156, -16'd4649, 16'd2250, -16'd4055, -16'd2044, 16'd1951, 16'd793, -16'd2116, -16'd401, -16'd1031, -16'd1377, -16'd2509, 16'd929, -16'd609, -16'd1843, -16'd613, 16'd3701, -16'd1499, 16'd2279, -16'd3217, -16'd791, 16'd1487, -16'd4003};
    wire [8191:0] weight_3={
    8'd5, 8'd3, -8'd50, 8'd9, 8'd15, 8'd33, -8'd2, -8'd47, 8'd55, 8'd42, 8'd18, 8'd56, -8'd19, -8'd58, -8'd23, -8'd20, 8'd11, -8'd50, -8'd39, -8'd18, 8'd42, 8'd22, 8'd29, 8'd45, 8'd12, 8'd19, 8'd54, 8'd13, -8'd9, 8'd3, -8'd39, 8'd4, -8'd4, 8'd69, -8'd45, -8'd25, 8'd3, 8'd42, -8'd82, 8'd32, 8'd25, -8'd63, -8'd3, -8'd26, -8'd32, 8'd35, 8'd13, 8'd52, 8'd27, -8'd56, 8'd21, 8'd23, 8'd45, 8'd23, 8'd41, 8'd32, 8'd51, -8'd80, -8'd24, -8'd36, 8'd38, 8'd57, -8'd39, -8'd39, 8'd49, 8'd2, -8'd62, -8'd34, 8'd45, 8'd9, 8'd65, -8'd10, 8'd10, 8'd42, 8'd45, 8'd12, -8'd33, -8'd24, 8'd15, 8'd57, 8'd55, -8'd12, -8'd16, -8'd23, 8'd39, 8'd17, -8'd55, 8'd86, -8'd46, -8'd13, -8'd52, 8'd40, 8'd1, 8'd38, 8'd21, -8'd66, 8'd37, 8'd90, -8'd77, 8'd60, 8'd92, -8'd12, -8'd40, -8'd28, 8'd29, -8'd3, 8'd53, -8'd10, -8'd17, 8'd16, -8'd99, 8'd16, 8'd14, 8'd96, -8'd1, -8'd78, 8'd39, -8'd15, -8'd25, -8'd44, -8'd56, 8'd81, 8'd85, 8'd8, 8'd73, -8'd82, -8'd35, 8'd27, -8'd5, 8'd24, -8'd15, -8'd33, -8'd42, 8'd63, -8'd20, -8'd31, -8'd4, 8'd47, -8'd53, -8'd52, 8'd11, 8'd60, 8'd58, 8'd20, 8'd15, -8'd20, 8'd12, 8'd18, -8'd3, 8'd51, -8'd19, -8'd69, 8'd69, -8'd87, 8'd38, 8'd24, 8'd26, -8'd12, -8'd31, -8'd7, 8'd5, -8'd74, 8'd59, -8'd6, -8'd10, 8'd18, -8'd50, 8'd38, -8'd42, -8'd71, 8'd32, 8'd42, 8'd58, 8'd29, -8'd12, 8'd55, -8'd74, -8'd23, 8'd76, 8'd34, -8'd15, 8'd41, 8'd69, -8'd20, -8'd53, -8'd57, 8'd3, 8'd43, 8'd53, -8'd32, -8'd24, -8'd14, -8'd4, 8'd40, 8'd86, -8'd15, 8'd78, 8'd84, 8'd56, 8'd39, 8'd11, 8'd65, 8'd76, -8'd42, 8'd62, -8'd23, -8'd55, -8'd94, -8'd104, -8'd51, 8'd19, 8'd55, -8'd11, -8'd95, -8'd31, -8'd15, 8'd37, 8'd74, -8'd40, 8'd9, 8'd37, -8'd29, -8'd55, -8'd49, 8'd62, 8'd11, -8'd22, -8'd19, 8'd1, -8'd0, 8'd9, 8'd26, 8'd24, -8'd17, -8'd14, -8'd69, 8'd17, 8'd50, 8'd11, 8'd20, 8'd60, 8'd32, 8'd53, 8'd19, -8'd16, 8'd59, -8'd20, -8'd38, -8'd19, -8'd35, -8'd66, 8'd36, -8'd83, 8'd12, 8'd41, -8'd30, 8'd35, -8'd46, -8'd47, 8'd14, -8'd6, 8'd53, 8'd37, -8'd46, 8'd19, -8'd41, 8'd53, -8'd24, -8'd42, 8'd16, -8'd46, -8'd13, -8'd20, -8'd4, 8'd38, 8'd30, 8'd1, 8'd18, 8'd40, -8'd35, 8'd47, -8'd15, 8'd27, 8'd52, -8'd26, 8'd14, -8'd45, 8'd38, 8'd7, -8'd19, 8'd10, 8'd17, -8'd10, 8'd30, 8'd15, 8'd4, -8'd19, -8'd2, -8'd29, 8'd27, 8'd23, -8'd26, -8'd43, -8'd29, -8'd32, 8'd24, 8'd28, -8'd24, 8'd9, 8'd11, -8'd25, 8'd35, 8'd36, -8'd19, 8'd38, 8'd18, 8'd9, 8'd27, 8'd36, -8'd31, 8'd52, 8'd55, 8'd21, 8'd42, -8'd8, -8'd31, 8'd34, -8'd47, -8'd26, 8'd52, 8'd17, -8'd43, -8'd27, 8'd53, 8'd35, 8'd17, 8'd6, 8'd31, -8'd32, 8'd57, 8'd7, -8'd28, 8'd30, 8'd58, -8'd15, 8'd14, -8'd28, 8'd45, 8'd21, 8'd15, -8'd48, 8'd15, -8'd54, 8'd62, 8'd32, -8'd23, -8'd50, 8'd34, 8'd7, -8'd43, 8'd56, -8'd21, 8'd7, 8'd41, 8'd20, -8'd16, -8'd56, 8'd44, 8'd49, -8'd33, -8'd54, -8'd29, -8'd32, -8'd36, -8'd7, 8'd8, 8'd31, -8'd53, 8'd41, -8'd21, -8'd48, 8'd17, 8'd26, -8'd40, 8'd38, 8'd43, 8'd35, 8'd53, -8'd16, 8'd44, 8'd57, 8'd31, 8'd25, 8'd8, 8'd15, -8'd33, 8'd15, -8'd22, -8'd35, 8'd61, -8'd72, -8'd58, 8'd14, 8'd21, 8'd7, 8'd66, -8'd33, -8'd13, -8'd74, 8'd1, -8'd66, 8'd54, 8'd43, -8'd20, 8'd49, 8'd67, -8'd40, 8'd1, 8'd34, 8'd40, -8'd20, 8'd1, -8'd25, 8'd47, 8'd7, 8'd7, 8'd45, -8'd8, -8'd12, -8'd6, 8'd5, -8'd13, -8'd10, -8'd5, 8'd46, -8'd35, 8'd48, -8'd38, -8'd44, -8'd33, 8'd36, 8'd20, 8'd44, 8'd2, 8'd27, -8'd19, -8'd1, 8'd31, 8'd53, -8'd44, -8'd10, 8'd21, -8'd67, -8'd64, -8'd66, 8'd58, -8'd0, 8'd72, 8'd29, -8'd67, 8'd5, 8'd66, 8'd29, -8'd60, 8'd27, 8'd54, -8'd80, 8'd20, 8'd9, 8'd35, -8'd69, 8'd21, -8'd49, -8'd73, -8'd30, -8'd5, 8'd67, 8'd16, 8'd34, -8'd53, -8'd42, 8'd9, 8'd43, 8'd32, 8'd22, 8'd27, -8'd32, -8'd6, -8'd30, 8'd38, -8'd38, 8'd35, 8'd25, 8'd46, 8'd18, -8'd35, -8'd52, -8'd29, 8'd4, -8'd17, 8'd24, -8'd5, -8'd8, -8'd15, -8'd26, -8'd42, 8'd38, 8'd42, 8'd11, -8'd43, 8'd5, -8'd52, 8'd68, -8'd45, -8'd30, 8'd69, -8'd64, 8'd25, -8'd18, 8'd25, 8'd65, -8'd72, 8'd15, -8'd76, 8'd35, -8'd8, -8'd37, -8'd40, 8'd35, 8'd31, -8'd15, 8'd34, -8'd16, 8'd77, 8'd38, -8'd74, -8'd55, 8'd47, 8'd71, 8'd45, 8'd64, 8'd19, 8'd6, -8'd71, 8'd32, -8'd1, 8'd5, 8'd13, 8'd19, 8'd41, 8'd31, -8'd10, 8'd28, -8'd49, -8'd16, -8'd56, 8'd8, 8'd24, 8'd34, 8'd15, -8'd8, -8'd11, 8'd4, 8'd24, 8'd2, 8'd2, -8'd14, -8'd35, 8'd39, -8'd44, 8'd50, -8'd35, -8'd7, -8'd48, 8'd18, -8'd5, -8'd16, 8'd48, 8'd12, -8'd54, 8'd20, -8'd29, -8'd40, -8'd23, 8'd55, 8'd8, 8'd53, 8'd20, 8'd5, 8'd51, 8'd42, 8'd56, 8'd27, 8'd49, -8'd19, -8'd15, -8'd50, -8'd46, 8'd6, 8'd7, -8'd34, 8'd9, -8'd35, 8'd25, 8'd29, 8'd6, -8'd44, -8'd33, -8'd41, -8'd48, 8'd15, -8'd31, -8'd45, 8'd30, 8'd29, -8'd21, -8'd30, 8'd5, -8'd24, -8'd66, -8'd66, 8'd9, 8'd39, 8'd109, 8'd26, -8'd69, -8'd27, 8'd1, -8'd35, 8'd1, 8'd47, -8'd25, 8'd19, 8'd87, -8'd23, 8'd20, 8'd83, 8'd87, -8'd14, 8'd38, 8'd56, 8'd23, -8'd20, -8'd7, 8'd51, 8'd47, -8'd29, 8'd33, -8'd10, -8'd7, -8'd29, -8'd18, -8'd53, 8'd31, 8'd37, -8'd60, 8'd22, -8'd12, 8'd52, -8'd16, 8'd19, 8'd70, -8'd46, -8'd17, 8'd12, -8'd64, 8'd55, -8'd18, 8'd36, 8'd72, -8'd50, 8'd30, 8'd59, -8'd28, 8'd30, -8'd51, -8'd44, 8'd52, 8'd38, 8'd41, -8'd34, -8'd9, 8'd31, -8'd63, 8'd47, -8'd44, -8'd1, -8'd34, 8'd54, -8'd1, -8'd56, 8'd42, -8'd14, -8'd37, 8'd50, 8'd7, -8'd46, 8'd10, 8'd63, -8'd52, -8'd54, 8'd59, -8'd54, -8'd43, -8'd44, 8'd30, -8'd21, -8'd4, -8'd22, 8'd49, -8'd44, 8'd45, -8'd3, -8'd55, -8'd21, -8'd50, -8'd8, 8'd39, 8'd34, 8'd23, 8'd40, 8'd21, -8'd28, 8'd54, -8'd13, 8'd48, -8'd60, -8'd32, 8'd34, -8'd3, 8'd7, 8'd8, -8'd11, 8'd26, -8'd4, 8'd24, 8'd68, -8'd15, -8'd13, 8'd33, -8'd85, 8'd41, 8'd51, 8'd52, -8'd38, 8'd17, -8'd14, -8'd80, 8'd93, -8'd41, -8'd31, -8'd30, -8'd29, 8'd59, -8'd6, 8'd78, -8'd5, 8'd25, -8'd40, -8'd43, -8'd85, 8'd57, 8'd56, 8'd37, 8'd34, -8'd57, 8'd60, -8'd23, -8'd15, -8'd40, 8'd16, 8'd31, -8'd79, 8'd92, 8'd69, 8'd21, -8'd32, 8'd43, 8'd60, 8'd2, 8'd56, -8'd22, -8'd29, -8'd80, 8'd79, 8'd34, -8'd6, 8'd54, -8'd94, 8'd16, 8'd27, -8'd19, -8'd59, -8'd16, 8'd27, -8'd31, -8'd70, 8'd55, -8'd59, -8'd10, -8'd57, -8'd17, 8'd1, -8'd40, 8'd53, 8'd35, -8'd59, 8'd50, -8'd70, 8'd67, -8'd4, -8'd8, 8'd22, -8'd14, -8'd49, -8'd8, 8'd24, -8'd53, 8'd18, 8'd49, 8'd43, 8'd44, 8'd36, -8'd9, 8'd23, -8'd58, -8'd57, -8'd34, -8'd41, -8'd70, -8'd9, -8'd58, -8'd61, 8'd87, 8'd43, -8'd41, 8'd46, -8'd9, 8'd35, 8'd41, -8'd55, 8'd33, 8'd9, 8'd72, 8'd91, -8'd27, -8'd89, 8'd34, -8'd51, -8'd35, -8'd58, 8'd54, -8'd62, 8'd22, 8'd71, -8'd60, -8'd40, -8'd21, 8'd65, -8'd3, 8'd94, -8'd66, 8'd77, -8'd68, -8'd10, 8'd54, -8'd59, 8'd30, -8'd44, -8'd29, -8'd44, 8'd19, -8'd37, -8'd49, 8'd49, -8'd43, -8'd19, 8'd29, 8'd23, -8'd52, 8'd19, -8'd28, -8'd27, -8'd23, -8'd36, -8'd37, 8'd42, -8'd24, -8'd20, 8'd44, -8'd22, 8'd14, 8'd1, 8'd15, 8'd17, 8'd40, 8'd88, 8'd46, -8'd51, 8'd41, -8'd63, -8'd46, -8'd32, 8'd1, 8'd64, -8'd59, 8'd74, 8'd12, -8'd84, 8'd42, 8'd18, 8'd32, -8'd5, 8'd66, -8'd61, -8'd38, -8'd85, 8'd61, -8'd41, 8'd31, -8'd28, 8'd3, 8'd83, -8'd8, 8'd108, 8'd48, -8'd101, 8'd127, -8'd23, -8'd76, 8'd34, 8'd26, -8'd118, -8'd39, -8'd77, 8'd19, -8'd18, -8'd33, 8'd1, -8'd19, 8'd91, -8'd44, -8'd28, 8'd95, -8'd56, -8'd28, 8'd55, 8'd46, -8'd74, 8'd54, 8'd9, -8'd37, 8'd3, 8'd84, -8'd5, -8'd20, 8'd120, 8'd80, -8'd63, 8'd99, 8'd4, 8'd14, -8'd14, 8'd8, 8'd24, -8'd45, -8'd53, 8'd28, -8'd64, -8'd31, 8'd51, -8'd51, -8'd46, 8'd23, 8'd31, -8'd52, 8'd45, -8'd16, -8'd35, 8'd22, 8'd14, -8'd29, 8'd18, 8'd53, 8'd39, -8'd48, -8'd54, -8'd54, -8'd46, 8'd71, 8'd57, 8'd18, -8'd40, -8'd39, -8'd27, 8'd51, 8'd47, -8'd10, 8'd23, -8'd40, 8'd13, 8'd30, 8'd47, 8'd18, -8'd20, -8'd39, 8'd48, 8'd40, -8'd29, -8'd16, 8'd30, 8'd32, 8'd6, -8'd18, 8'd40, 8'd17, -8'd10, 8'd45, 8'd19, -8'd32, 8'd45, 8'd44, 8'd36, -8'd28
    };
    // 【全连接层】2个神经元 * 16bit = 32bit, 2*288 * 8bit = 4608bit
    // FC 层较短，这里直接给你贴全了
    wire [31:0] bias_fc={
    -16'd2337, 16'd1339
    };
    wire [4607:0] weight_fc={
    8'd20 ,-8'd23 ,8'd74 ,-8'd58 ,8'd17 ,-8'd17 ,8'd22 ,-8'd96 ,8'd73 ,-8'd35 ,8'd6 ,-8'd40 ,8'd61 ,-8'd13 ,8'd58 ,-8'd1 ,8'd12 ,-8'd29 ,8'd63 ,-8'd64 ,8'd68 ,-8'd30 ,8'd22 ,-8'd78 ,8'd107 ,-8'd94 ,8'd59 ,-8'd122 ,8'd68 ,-8'd64 ,8'd89 ,-8'd26 ,-8'd9 ,-8'd5 ,8'd28 ,-8'd55 ,8'd12 ,-8'd33 ,8'd72 ,-8'd43 ,8'd42 ,-8'd17 ,8'd76 ,-8'd79 ,8'd38 ,-8'd12 ,8'd119 ,-8'd102 ,8'd4 ,-8'd44 ,-8'd9 ,8'd8 ,8'd27 ,-8'd52 ,-8'd1 ,8'd46 ,-8'd23 ,8'd17 ,-8'd60 ,8'd14 ,-8'd31 ,8'd97 ,-8'd113 ,8'd54 ,-8'd60 ,8'd114 ,-8'd101 ,8'd100 ,-8'd102 ,8'd52 ,-8'd56 ,8'd31 ,8'd53 ,-8'd73 ,8'd62 ,-8'd80 ,8'd74 ,-8'd40 ,8'd40 ,-8'd96 ,8'd97 ,-8'd94 ,8'd56 ,-8'd38 ,8'd56 ,-8'd22 ,8'd60 ,-8'd72 ,8'd72 ,-8'd29 ,-8'd15 ,8'd21 ,-8'd8 ,-8'd22 ,-8'd25 ,8'd16 ,8'd29 ,-8'd15 ,8'd5 ,-8'd18 ,8'd29 ,8'd8 ,-8'd5 ,8'd22 ,-8'd4 ,8'd10 ,8'd26 ,8'd6 ,-8'd53 ,8'd84 ,-8'd85 ,8'd61 ,-8'd43 ,8'd94 ,-8'd62 ,8'd41 ,-8'd83 ,8'd66 ,-8'd59 ,8'd27 ,-8'd39 ,8'd60 ,-8'd37 ,8'd16 ,-8'd61 ,8'd44 ,8'd55 ,-8'd21 ,8'd47 ,-8'd27 ,8'd49 ,-8'd51 ,8'd32 ,-8'd28 ,8'd69 ,-8'd8 ,8'd58 ,-8'd59 ,8'd16 ,-8'd75 ,8'd87 ,-8'd64 ,-8'd16 ,-8'd27 ,-8'd43 ,8'd4 ,-8'd9 ,-8'd2 ,8'd44 ,-8'd71 ,8'd55 ,-8'd4 ,8'd52 ,-8'd77 ,8'd10 ,-8'd64 ,8'd33 ,-8'd28 ,8'd41 ,-8'd54 ,8'd40 ,-8'd79 ,8'd51 ,-8'd3 ,8'd64 ,-8'd27 ,-8'd6 ,-8'd3 ,8'd63 ,-8'd49 ,8'd80 ,-8'd80 ,8'd38 ,-8'd9 ,-8'd21 ,-8'd47 ,8'd30 ,-8'd53 ,8'd42 ,-8'd3 ,8'd107 ,-8'd71 ,8'd80 ,-8'd91 ,-8'd5 ,-8'd1 ,-8'd2 ,-8'd24 ,-8'd16 ,-8'd25 ,-8'd4 ,8'd6 ,-8'd29 ,8'd60 ,-8'd20 ,8'd8 ,-8'd32 ,8'd50 ,8'd47 ,-8'd19 ,8'd8 ,-8'd15 ,8'd41 ,-8'd3 ,8'd83 ,-8'd48 ,8'd99 ,-8'd65 ,8'd81 ,-8'd81 ,8'd75 ,-8'd52 ,8'd74 ,-8'd11 ,8'd90 ,-8'd106 ,-8'd39 ,-8'd27 ,-8'd1 ,8'd43 ,-8'd66 ,8'd44 ,-8'd6 ,8'd22 ,-8'd37 ,8'd12 ,8'd31 ,8'd3 ,-8'd19 ,8'd41 ,-8'd52 ,8'd19 ,-8'd14 ,8'd34 ,-8'd35 ,-8'd38 ,8'd55 ,8'd2 ,-8'd4 ,-8'd48 ,8'd10 ,-8'd60 ,8'd30 ,-8'd2 ,8'd37 ,8'd24 ,8'd59 ,8'd2 ,8'd5 ,-8'd15 ,8'd7 ,-8'd41 ,8'd103 ,-8'd56 ,8'd48 ,-8'd78 ,8'd11 ,-8'd34 ,8'd11 ,-8'd27 ,8'd0 ,8'd14 ,-8'd41 ,8'd16 ,8'd2 ,8'd18 ,8'd9 ,8'd35 ,-8'd38 ,-8'd1 ,-8'd22 ,8'd34 ,8'd25 ,8'd16 ,-8'd27 ,8'd11 ,8'd47 ,-8'd28 ,8'd10 ,-8'd45 ,8'd8 ,8'd34 ,-8'd40 ,-8'd30 ,-8'd2 ,-8'd12 ,-8'd16 ,8'd15 ,-8'd72 ,8'd68 ,-8'd6 ,8'd44 ,-8'd26 ,8'd76 ,-8'd56 ,8'd81 ,-8'd67 ,8'd37 ,8'd14 ,8'd54 ,-8'd5 ,-8'd5 ,-8'd61 ,8'd56 ,-8'd13 ,-8'd12 ,-8'd11 ,8'd6 ,8'd46 ,-8'd38 ,8'd57 ,-8'd35 ,8'd11 ,-8'd72 ,8'd78 ,-8'd67 ,8'd35 ,-8'd70 ,8'd67 ,-8'd38 ,8'd45 ,-8'd35 ,8'd27 ,-8'd62 ,8'd64 ,-8'd50 ,-8'd13 ,-8'd8 ,8'd6 ,-8'd21 ,-8'd66 ,8'd56 ,8'd17 ,-8'd22 ,8'd15 ,8'd29 ,-8'd50 ,8'd48 ,8'd35 ,-8'd33 ,8'd36 ,-8'd27 ,-8'd46 ,8'd50 ,-8'd66 ,8'd38 ,-8'd38 ,8'd74 ,-8'd31 ,8'd59 ,-8'd5 ,8'd1 ,-8'd65 ,8'd52 ,-8'd33 ,8'd49 ,-8'd17 ,8'd8 ,8'd18 ,8'd35 ,8'd67 ,-8'd38 ,8'd28 ,-8'd15 ,8'd9 ,-8'd81 ,8'd48 ,-8'd44 ,8'd44 ,-8'd21 ,8'd54 ,-8'd31 ,8'd47 ,-8'd49 ,8'd22 ,-8'd58 ,8'd70 ,-8'd31 ,-8'd27 ,8'd50 ,-8'd41 ,8'd27 ,-8'd39 ,8'd18 ,-8'd49 ,-8'd9 ,8'd26 ,8'd3 ,-8'd9 ,8'd7 ,8'd33 ,8'd4 ,-8'd48 ,-8'd28 ,-8'd1 ,8'd31 ,8'd54 ,-8'd77 ,8'd45 ,-8'd57 ,8'd50 ,-8'd22 ,8'd61 ,-8'd72 ,8'd71 ,-8'd87 ,8'd20 ,-8'd30 ,8'd15 ,-8'd72 ,8'd26 ,-8'd51 ,8'd45 ,-8'd28 ,-8'd41 ,8'd12 ,-8'd75 ,8'd61 ,-8'd36 ,8'd76 ,-8'd108 ,8'd83 ,-8'd48 ,8'd53 ,-8'd73 ,8'd104 ,-8'd72 ,8'd67 ,-8'd35 ,8'd45 ,-8'd11 ,8'd93 ,-8'd76 ,8'd69 ,-8'd92 ,8'd77 ,-8'd71 ,8'd36 ,-8'd61 ,8'd71 ,-8'd1 ,8'd9 ,8'd35 ,-8'd10 ,-8'd26 ,8'd9 ,-8'd44 ,8'd13 ,8'd13 ,-8'd36 ,8'd15 ,-8'd11 ,8'd43 ,8'd3 ,8'd4 ,-8'd42 ,8'd8 ,-8'd54 ,8'd75 ,8'd1 ,-8'd14 ,8'd17 ,8'd1 ,-8'd29 ,-8'd47 ,-8'd17 ,-8'd34 ,8'd68 ,-8'd36 ,8'd29 ,-8'd85 ,8'd52 ,-8'd100 ,8'd89 ,-8'd86 ,8'd75 ,8'd10 ,-8'd1 ,-8'd70 ,8'd64 ,-8'd55 ,8'd35 ,-8'd73 ,8'd41 ,-8'd18 ,8'd61 ,-8'd55 ,8'd69 ,-8'd45 ,8'd37 ,8'd7 ,8'd69 ,-8'd56 ,8'd48 ,-8'd83 ,8'd40 ,-8'd72 ,8'd47 ,8'd1 ,-8'd4 ,8'd21 ,-8'd11 ,-8'd8 ,8'd61 ,8'd20 ,-8'd10 ,-8'd18 ,8'd19 ,-8'd33 ,-8'd24 ,-8'd37 ,8'd74 ,-8'd125 ,8'd76 ,-8'd99 ,8'd66 ,-8'd72 ,8'd87 ,-8'd84 ,8'd81 ,-8'd40 ,8'd34 ,-8'd40 ,8'd86 ,-8'd91 ,8'd46 ,-8'd99 ,8'd100 ,-8'd86 ,8'd84 ,-8'd56 ,8'd111 ,-8'd46 ,8'd88 ,-8'd115 ,8'd59 ,-8'd87 ,8'd64 ,-8'd52 ,8'd24 ,8'd45 ,-8'd43 ,8'd35 ,-8'd71 ,8'd75 ,-8'd31 ,8'd76 ,-8'd20 ,8'd39 ,-8'd56 ,8'd17 ,-8'd36 ,8'd28 ,-8'd30 ,8'd28 ,-8'd1 ,8'd4 ,8'd13 ,-8'd43 ,8'd14 ,8'd0 ,-8'd19 ,-8'd2 ,8'd38 ,8'd0 ,-8'd37 ,8'd4 ,-8'd4 ,-8'd23 ,8'd15 ,-8'd50 ,8'd47 ,-8'd7 ,-8'd27 ,8'd19 ,8'd10
    };


    // ======================================================================
    // 2. 动态张量重排 (数学降维打击版：整块切片，拯救综合器)
    // ======================================================================
    always @(*) begin
        // 默认全赋零，防止产生锁存器 (Latch)
        wgt_in_flat  = 2464'd0;
        bias_in_flat = 512'd0;
        
        case (layer_mode)
            2'd0: begin // 【Conv1 模式】
                // 4组 * 16bit = 64bit
                bias_in_flat[63:0]   = bias_1[ch_grp_cnt * 64 +: 64];
                // 4组 * 77点 * 8bit = 2464bit，整块直接截取！
                wgt_in_flat[2463:0]  = weight_1[ch_grp_cnt * 2464 +: 2464];
            end
            
            2'd1: begin // 【DWConv 模式】
                // 32通道全上，直接整体赋值
                bias_in_flat[511:0]  = bias_2;
                wgt_in_flat[2303:0]  = weight_2;
            end
            
            2'd2: begin // 【PWConv 模式】
                // 8组 * 16bit = 128bit
                bias_in_flat[127:0]  = bias_3[ch_grp_cnt * 128 +: 128];
                // 8组 * 32通道 * 8bit = 2048bit
                wgt_in_flat[2047:0]  = weight_3[ch_grp_cnt * 2048 +: 2048];
            end

            2'd3: begin // 【FC 模式】
                // 1个神经元 * 16bit
                bias_in_flat[15:0]   = bias_fc[ch_grp_cnt * 16 +: 16];
                // 1个神经元 * 288点 * 8bit = 2304bit
                wgt_in_flat[2303:0]  = weight_fc[ch_grp_cnt * 2304 +: 2304];
            end
            
            default: ;
        endcase
    end

endmodule
```

### `Syn/rtl/post_process.v`

```verilog
`timescale 1ns / 1ps

module post_process (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 mac_valid,
    input  wire [1:0]           layer_mode,      // 🌟 新增：接收当前在算哪一层
    input  wire [1023:0]        psum_in_flat,
    input  wire [511:0]         bias_in_flat,
    
    output reg                  out_valid,
    output reg  [255:0]         act_out_flat
);

    wire signed [31:0] psum_in [0:31];
    wire signed [15:0] bias_in [0:31];
    
    genvar g;
    generate
        for (g = 0; g < 32; g = g + 1) begin : unpack_loop
            assign psum_in[g] = psum_in_flat[g*32 +: 32];
            assign bias_in[g] = bias_in_flat[g*16 +: 16];
        end
    endgenerate

    reg                 stage1_valid;
    reg signed [47:0]   stage1_mult [0:31];
    reg [3:0]           stage1_quant_n;
    reg                 stage1_relu;

    // =========================================================
    // 🌟 核心：根据助教的 rescale 文件，修正漏算的 scaled2 倍数
    // =========================================================
    reg signed [15:0] cur_M0;
    reg [3:0]         cur_n;
    reg               cur_relu;
    always @(*) begin
        case (layer_mode)
            2'd0: begin cur_M0 = 16'd111; cur_n = 4'd14; cur_relu = 1'b1; end // Conv1 (104+7=111)
            2'd1: begin cur_M0 = 16'd59;  cur_n = 4'd11; cur_relu = 1'b1; end // DW    (56+3=59)
            2'd2: begin cur_M0 = 16'd69;  cur_n = 4'd13; cur_relu = 1'b1; end // PW    (69, 不变)
            2'd3: begin cur_M0 = 16'd11;  cur_n = 4'd15; cur_relu = 1'b0; end // FC    (11, 不变, 关ReLU)
            default: begin cur_M0 = 16'd0; cur_n = 4'd0; cur_relu = 1'b0; end
        endcase
    end

    integer i;
    reg signed [32:0] psum_with_bias;
    reg signed [47:0] temp_shifted;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stage1_valid <= 1'b0;
            out_valid    <= 1'b0;
            act_out_flat <= 256'd0;
            stage1_quant_n <= 4'd0;
            stage1_relu  <= 1'b0;
            for (i = 0; i < 32; i = i + 1) begin
                stage1_mult[i] <= 48'sd0;
            end
        end else begin
            
            // 【Stage 1】: 加偏置并乘动态倍数
            stage1_valid <= mac_valid;
            if (mac_valid) begin
                stage1_quant_n <= cur_n;
                stage1_relu    <= cur_relu; // 将开关传递到下一拍
                for (i = 0; i < 32; i = i + 1) begin
                    psum_with_bias = $signed(psum_in[i]) + $signed({{16{bias_in[i][15]}}, bias_in[i]});
                    stage1_mult[i] <= psum_with_bias * cur_M0;
                end
            end

            // 【Stage 2】: 算术右移，截断，条件 ReLU
            out_valid <= stage1_valid;
            if (stage1_valid) begin
                for (i = 0; i < 32; i = i + 1) begin
                    temp_shifted = stage1_mult[i] >>> stage1_quant_n;
                    
                    if (stage1_relu && temp_shifted < 0) begin
                        // 开启 ReLU 且为负数 -> 截断为 0
                        act_out_flat[i*8 +: 8] <= 8'd0;
                    end else if (temp_shifted > 127) begin
                        // 正向饱和
                        act_out_flat[i*8 +: 8] <= 8'd127;
                    end else if (temp_shifted < -128) begin
                        // 🌟 负向饱和 (全连接层负数专用保护)
                        act_out_flat[i*8 +: 8] <= -8'sd128; 
                    end else begin
                        // 正常返回真实值
                        act_out_flat[i*8 +: 8] <= temp_shifted[7:0];
                    end
                end
            end
        end
    end
endmodule
```

### `Syn/rtl/S018V3EBCDSP_X20Y4D128_PR.v`

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

### `Syn/rtl/SigLUT.v`

```verilog
`timescale 1ns / 1ps

module sigmoid_lut (
    input  wire                 clk,
    input  wire                 en,
    input  wire signed [7:0]    fc_int8_in,  // 输入定点值 (-128 ~ 127)
    output reg  [31:0]          sigmoid_out  // FP32 标准浮点
);

    // 将有符号的 INT8 转为 0~255 的无符号索引
    wire [7:0] index = fc_int8_in;
    
    // 纯组合逻辑查找表
    reg [31:0] lut_val;

    always @(*) begin
        case (index)
            8'd128: lut_val = 32'h364e5111; // x = -128, f(x) = 0.000003
            8'd129: lut_val = 32'h3663d2d3; // x = -127, f(x) = 0.000003
            8'd130: lut_val = 32'h367b9283; // x = -126, f(x) = 0.000004
            8'd131: lut_val = 32'h368ae5fa; // x = -125, f(x) = 0.000004
            8'd132: lut_val = 32'h3699609c; // x = -124, f(x) = 0.000005
            8'd133: lut_val = 32'h36a95d9f; // x = -123, f(x) = 0.000005
            8'd134: lut_val = 32'h36bb054d; // x = -122, f(x) = 0.000006
            8'd135: lut_val = 32'h36ce841d; // x = -121, f(x) = 0.000006
            8'd136: lut_val = 32'h36e40b2c; // x = -120, f(x) = 0.000007
            8'd137: lut_val = 32'h36fbd0b6; // x = -119, f(x) = 0.000008
            8'd138: lut_val = 32'h370b084e; // x = -118, f(x) = 0.000008
            8'd139: lut_val = 32'h3719867f; // x = -117, f(x) = 0.000009
            8'd140: lut_val = 32'h37298771; // x = -116, f(x) = 0.000010
            8'd141: lut_val = 32'h373b3373; // x = -115, f(x) = 0.000011
            8'd142: lut_val = 32'h374eb70b; // x = -114, f(x) = 0.000012
            8'd143: lut_val = 32'h37644360; // x = -113, f(x) = 0.000014
            8'd144: lut_val = 32'h377c0eba; // x = -112, f(x) = 0.000015
            8'd145: lut_val = 32'h378b2a84; // x = -111, f(x) = 0.000017
            8'd146: lut_val = 32'h3799ac3e; // x = -110, f(x) = 0.000018
            8'd147: lut_val = 32'h37a9b114; // x = -109, f(x) = 0.000020
            8'd148: lut_val = 32'h37bb6161; // x = -108, f(x) = 0.000022
            8'd149: lut_val = 32'h37cee9b2; // x = -107, f(x) = 0.000025
            8'd150: lut_val = 32'h37e47b3c; // x = -106, f(x) = 0.000027
            8'd151: lut_val = 32'h37fc4c50; // x = -105, f(x) = 0.000030
            8'd152: lut_val = 32'h380b4c77; // x = -104, f(x) = 0.000033
            8'd153: lut_val = 32'h3819d1a9; // x = -103, f(x) = 0.000037
            8'd154: lut_val = 32'h3829da50; // x = -102, f(x) = 0.000040
            8'd155: lut_val = 32'h383b8ed0; // x = -101, f(x) = 0.000045
            8'd156: lut_val = 32'h384f1bbe; // x = -100, f(x) = 0.000049
            8'd157: lut_val = 32'h3864b258; // x = -99, f(x) = 0.000055
            8'd158: lut_val = 32'h387c88fd; // x = -98, f(x) = 0.000060
            8'd159: lut_val = 32'h388b6dda; // x = -97, f(x) = 0.000066
            8'd160: lut_val = 32'h3899f664; // x = -96, f(x) = 0.000073
            8'd161: lut_val = 32'h38aa02b5; // x = -95, f(x) = 0.000081
            8'd162: lut_val = 32'h38bbbb36; // x = -94, f(x) = 0.000090
            8'd163: lut_val = 32'h38cf4c85; // x = -93, f(x) = 0.000099
            8'd164: lut_val = 32'h38e4e7e8; // x = -92, f(x) = 0.000109
            8'd165: lut_val = 32'h38fcc3c3; // x = -91, f(x) = 0.000121
            8'd166: lut_val = 32'h390b8e14; // x = -90, f(x) = 0.000133
            8'd167: lut_val = 32'h391a19b4; // x = -89, f(x) = 0.000147
            8'd168: lut_val = 32'h392a295d; // x = -88, f(x) = 0.000162
            8'd169: lut_val = 32'h393be57e; // x = -87, f(x) = 0.000179
            8'd170: lut_val = 32'h394f7ab6; // x = -86, f(x) = 0.000198
            8'd171: lut_val = 32'h39651a4e; // x = -85, f(x) = 0.000218
            8'd172: lut_val = 32'h397cfaae; // x = -84, f(x) = 0.000241
            8'd173: lut_val = 32'h398babf3; // x = -83, f(x) = 0.000266
            8'd174: lut_val = 32'h399a3a23; // x = -82, f(x) = 0.000294
            8'd175: lut_val = 32'h39aa4c83; // x = -81, f(x) = 0.000325
            8'd176: lut_val = 32'h39bc0b7c; // x = -80, f(x) = 0.000359
            8'd177: lut_val = 32'h39cfa3ac; // x = -79, f(x) = 0.000396
            8'd178: lut_val = 32'h39e54652; // x = -78, f(x) = 0.000437
            8'd179: lut_val = 32'h39fd29cd; // x = -77, f(x) = 0.000483
            8'd180: lut_val = 32'h3a0bc510; // x = -76, f(x) = 0.000533
            8'd181: lut_val = 32'h3a1a54c5; // x = -75, f(x) = 0.000589
            8'd182: lut_val = 32'h3a2a6895; // x = -74, f(x) = 0.000650
            8'd183: lut_val = 32'h3a3c28d9; // x = -73, f(x) = 0.000718
            8'd184: lut_val = 32'h3a4fc21a; // x = -72, f(x) = 0.000793
            8'd185: lut_val = 32'h3a65657f; // x = -71, f(x) = 0.000875
            8'd186: lut_val = 32'h3a7d4944; // x = -70, f(x) = 0.000966
            8'd187: lut_val = 32'h3a8bd4a2; // x = -69, f(x) = 0.001067
            8'd188: lut_val = 32'h3a9a63c3; // x = -68, f(x) = 0.001178
            8'd189: lut_val = 32'h3aaa7674; // x = -67, f(x) = 0.001301
            8'd190: lut_val = 32'h3abc34e6; // x = -66, f(x) = 0.001436
            8'd191: lut_val = 32'h3acfcb6e; // x = -65, f(x) = 0.001585
            8'd192: lut_val = 32'h3ae56af1; // x = -64, f(x) = 0.001750
            8'd193: lut_val = 32'h3afd495d; // x = -63, f(x) = 0.001932
            8'd194: lut_val = 32'h3b0bd114; // x = -62, f(x) = 0.002133
            8'd195: lut_val = 32'h3b1a5b72; // x = -61, f(x) = 0.002355
            8'd196: lut_val = 32'h3b2a67ec; // x = -60, f(x) = 0.002600
            8'd197: lut_val = 32'h3b3c1e54; // x = -59, f(x) = 0.002870
            8'd198: lut_val = 32'h3b4faa8f; // x = -58, f(x) = 0.003169
            8'd199: lut_val = 32'h3b653cf7; // x = -57, f(x) = 0.003498
            8'd200: lut_val = 32'h3b7d0ace; // x = -56, f(x) = 0.003861
            8'd201: lut_val = 32'h3b8ba75c; // x = -55, f(x) = 0.004262
            8'd202: lut_val = 32'h3b9a24a3; // x = -54, f(x) = 0.004704
            8'd203: lut_val = 32'h3baa20c0; // x = -53, f(x) = 0.005192
            8'd204: lut_val = 32'h3bbbc2c7; // x = -52, f(x) = 0.005730
            8'd205: lut_val = 32'h3bcf35b0; // x = -51, f(x) = 0.006324
            8'd206: lut_val = 32'h3be4a8b6; // x = -50, f(x) = 0.006978
            8'd207: lut_val = 32'h3bfc4fbb; // x = -49, f(x) = 0.007700
            8'd208: lut_val = 32'h3c0b31dc; // x = -48, f(x) = 0.008496
            8'd209: lut_val = 32'h3c19919a; // x = -47, f(x) = 0.009373
            8'd210: lut_val = 32'h3c29695f; // x = -46, f(x) = 0.010340
            8'd211: lut_val = 32'h3c3adebc; // x = -45, f(x) = 0.011406
            8'd212: lut_val = 32'h3c4e1ad3; // x = -44, f(x) = 0.012580
            8'd213: lut_val = 32'h3c634aa5; // x = -43, f(x) = 0.013873
            8'd214: lut_val = 32'h3c7a9f60; // x = -42, f(x) = 0.015297
            8'd215: lut_val = 32'h3c8a275b; // x = -41, f(x) = 0.016864
            8'd216: lut_val = 32'h3c984998; // x = -40, f(x) = 0.018590
            8'd217: lut_val = 32'h3ca7d649; // x = -39, f(x) = 0.020488
            8'd218: lut_val = 32'h3cb8f014; // x = -38, f(x) = 0.022575
            8'd219: lut_val = 32'h3ccbbc98; // x = -37, f(x) = 0.024870
            8'd220: lut_val = 32'h3ce06499; // x = -36, f(x) = 0.027392
            8'd221: lut_val = 32'h3cf71426; // x = -35, f(x) = 0.030161
            8'd222: lut_val = 32'h3d07fd65; // x = -34, f(x) = 0.033201
            8'd223: lut_val = 32'h3d15a5d7; // x = -33, f(x) = 0.036535
            8'd224: lut_val = 32'h3d249ed9; // x = -32, f(x) = 0.040191
            8'd225: lut_val = 32'h3d3505c4; // x = -31, f(x) = 0.044195
            8'd226: lut_val = 32'h3d46f9df; // x = -30, f(x) = 0.048578
            8'd227: lut_val = 32'h3d5a9c5c; // x = -29, f(x) = 0.053372
            8'd228: lut_val = 32'h3d70104c; // x = -28, f(x) = 0.058609
            8'd229: lut_val = 32'h3d83bd47; // x = -27, f(x) = 0.064326
            8'd230: lut_val = 32'h3d9080d3; // x = -26, f(x) = 0.070558
            8'd231: lut_val = 32'h3d9e66ca; // x = -25, f(x) = 0.077344
            8'd232: lut_val = 32'h3dad83c3; // x = -24, f(x) = 0.084724
            8'd233: lut_val = 32'h3dbdecc5; // x = -23, f(x) = 0.092737
            8'd234: lut_val = 32'h3dcfb711; // x = -22, f(x) = 0.101423
            8'd235: lut_val = 32'h3de2f7da; // x = -21, f(x) = 0.110824
            8'd236: lut_val = 32'h3df7c3fb; // x = -20, f(x) = 0.120979
            8'd237: lut_val = 32'h3e0717ca; // x = -19, f(x) = 0.131927
            8'd238: lut_val = 32'h3e1326d3; // x = -18, f(x) = 0.143703
            8'd239: lut_val = 32'h3e2017c9; // x = -17, f(x) = 0.156341
            8'd240: lut_val = 32'h3e2df24f; // x = -16, f(x) = 0.169870
            8'd241: lut_val = 32'h3e3cbcae; // x = -15, f(x) = 0.184314
            8'd242: lut_val = 32'h3e4c7b8e; // x = -14, f(x) = 0.199690
            8'd243: lut_val = 32'h3e5d31a9; // x = -13, f(x) = 0.216010
            8'd244: lut_val = 32'h3e6edf7c; // x = -12, f(x) = 0.233274
            8'd245: lut_val = 32'h3e80c180; // x = -11, f(x) = 0.251476
            8'd246: lut_val = 32'h3e8a8bb8; // x = -10, f(x) = 0.270597
            8'd247: lut_val = 32'h3e94ca83; // x = -9, f(x) = 0.290608
            8'd248: lut_val = 32'h3e9f7870; // x = -8, f(x) = 0.311466
            8'd249: lut_val = 32'h3eaa8e72; // x = -7, f(x) = 0.333118
            8'd250: lut_val = 32'h3eb603e1; // x = -6, f(x) = 0.355498
            8'd251: lut_val = 32'h3ec1ce88; // x = -5, f(x) = 0.378529
            8'd252: lut_val = 32'h3ecde2ba; // x = -4, f(x) = 0.402120
            8'd253: lut_val = 32'h3eda337b; // x = -3, f(x) = 0.426174
            8'd254: lut_val = 32'h3ee6b2b3; // x = -2, f(x) = 0.450582
            8'd255: lut_val = 32'h3ef35167; // x = -1, f(x) = 0.475230
            8'd0: lut_val = 32'h3f000000; // x = 0, f(x) = 0.500000
            8'd1: lut_val = 32'h3f06574c; // x = 1, f(x) = 0.524770
            8'd2: lut_val = 32'h3f0ca6a6; // x = 2, f(x) = 0.549418
            8'd3: lut_val = 32'h3f12e642; // x = 3, f(x) = 0.573826
            8'd4: lut_val = 32'h3f190ea3; // x = 4, f(x) = 0.597880
            8'd5: lut_val = 32'h3f1f18bc; // x = 5, f(x) = 0.621471
            8'd6: lut_val = 32'h3f24fe0f; // x = 6, f(x) = 0.644502
            8'd7: lut_val = 32'h3f2ab8c7; // x = 7, f(x) = 0.666882
            8'd8: lut_val = 32'h3f3043c8; // x = 8, f(x) = 0.688534
            8'd9: lut_val = 32'h3f359abe; // x = 9, f(x) = 0.709392
            8'd10: lut_val = 32'h3f3aba24; // x = 10, f(x) = 0.729403
            8'd11: lut_val = 32'h3f3f9f40; // x = 11, f(x) = 0.748524
            8'd12: lut_val = 32'h3f444821; // x = 12, f(x) = 0.766726
            8'd13: lut_val = 32'h3f48b396; // x = 13, f(x) = 0.783990
            8'd14: lut_val = 32'h3f4ce11c; // x = 14, f(x) = 0.800310
            8'd15: lut_val = 32'h3f50d0d5; // x = 15, f(x) = 0.815686
            8'd16: lut_val = 32'h3f54836c; // x = 16, f(x) = 0.830130
            8'd17: lut_val = 32'h3f57fa0e; // x = 17, f(x) = 0.843659
            8'd18: lut_val = 32'h3f5b364b; // x = 18, f(x) = 0.856297
            8'd19: lut_val = 32'h3f5e3a0e; // x = 19, f(x) = 0.868073
            8'd20: lut_val = 32'h3f610781; // x = 20, f(x) = 0.879021
            8'd21: lut_val = 32'h3f63a105; // x = 21, f(x) = 0.889176
            8'd22: lut_val = 32'h3f66091e; // x = 22, f(x) = 0.898577
            8'd23: lut_val = 32'h3f684267; // x = 23, f(x) = 0.907263
            8'd24: lut_val = 32'h3f6a4f88; // x = 24, f(x) = 0.915276
            8'd25: lut_val = 32'h3f6c3327; // x = 25, f(x) = 0.922656
            8'd26: lut_val = 32'h3f6defe6; // x = 26, f(x) = 0.929442
            8'd27: lut_val = 32'h3f6f8857; // x = 27, f(x) = 0.935674
            8'd28: lut_val = 32'h3f70fefb; // x = 28, f(x) = 0.941391
            8'd29: lut_val = 32'h3f72563a; // x = 29, f(x) = 0.946628
            8'd30: lut_val = 32'h3f739062; // x = 30, f(x) = 0.951422
            8'd31: lut_val = 32'h3f74afa4; // x = 31, f(x) = 0.955805
            8'd32: lut_val = 32'h3f75b612; // x = 32, f(x) = 0.959809
            8'd33: lut_val = 32'h3f76a5a3; // x = 33, f(x) = 0.963465
            8'd34: lut_val = 32'h3f77802a; // x = 34, f(x) = 0.966799
            8'd35: lut_val = 32'h3f78475f; // x = 35, f(x) = 0.969839
            8'd36: lut_val = 32'h3f78fcdb; // x = 36, f(x) = 0.972608
            8'd37: lut_val = 32'h3f79a21b; // x = 37, f(x) = 0.975130
            8'd38: lut_val = 32'h3f7a387f; // x = 38, f(x) = 0.977425
            8'd39: lut_val = 32'h3f7ac14e; // x = 39, f(x) = 0.979512
            8'd40: lut_val = 32'h3f7b3db3; // x = 40, f(x) = 0.981410
            8'd41: lut_val = 32'h3f7baec5; // x = 41, f(x) = 0.983136
            8'd42: lut_val = 32'h3f7c1583; // x = 42, f(x) = 0.984703
            8'd43: lut_val = 32'h3f7c72d5; // x = 43, f(x) = 0.986127
            8'd44: lut_val = 32'h3f7cc795; // x = 44, f(x) = 0.987420
            8'd45: lut_val = 32'h3f7d1485; // x = 45, f(x) = 0.988594
            8'd46: lut_val = 32'h3f7d5a5b; // x = 46, f(x) = 0.989660
            8'd47: lut_val = 32'h3f7d99ba; // x = 47, f(x) = 0.990627
            8'd48: lut_val = 32'h3f7dd339; // x = 48, f(x) = 0.991504
            8'd49: lut_val = 32'h3f7e0761; // x = 49, f(x) = 0.992300
            8'd50: lut_val = 32'h3f7e36af; // x = 50, f(x) = 0.993022
            8'd51: lut_val = 32'h3f7e6195; // x = 51, f(x) = 0.993676
            8'd52: lut_val = 32'h3f7e887a; // x = 52, f(x) = 0.994270
            8'd53: lut_val = 32'h3f7eabbe; // x = 53, f(x) = 0.994808
            8'd54: lut_val = 32'h3f7ecbb7; // x = 54, f(x) = 0.995296
            8'd55: lut_val = 32'h3f7ee8b1; // x = 55, f(x) = 0.995738
            8'd56: lut_val = 32'h3f7f02f5; // x = 56, f(x) = 0.996139
            8'd57: lut_val = 32'h3f7f1ac3; // x = 57, f(x) = 0.996502
            8'd58: lut_val = 32'h3f7f3055; // x = 58, f(x) = 0.996831
            8'd59: lut_val = 32'h3f7f43e2; // x = 59, f(x) = 0.997130
            8'd60: lut_val = 32'h3f7f5598; // x = 60, f(x) = 0.997400
            8'd61: lut_val = 32'h3f7f65a5; // x = 61, f(x) = 0.997645
            8'd62: lut_val = 32'h3f7f742f; // x = 62, f(x) = 0.997867
            8'd63: lut_val = 32'h3f7f815b; // x = 63, f(x) = 0.998068
            8'd64: lut_val = 32'h3f7f8d4b; // x = 64, f(x) = 0.998250
            8'd65: lut_val = 32'h3f7f981a; // x = 65, f(x) = 0.998415
            8'd66: lut_val = 32'h3f7fa1e6; // x = 66, f(x) = 0.998564
            8'd67: lut_val = 32'h3f7faac5; // x = 67, f(x) = 0.998699
            8'd68: lut_val = 32'h3f7fb2ce; // x = 68, f(x) = 0.998822
            8'd69: lut_val = 32'h3f7fba16; // x = 69, f(x) = 0.998933
            8'd70: lut_val = 32'h3f7fc0ae; // x = 70, f(x) = 0.999034
            8'd71: lut_val = 32'h3f7fc6a7; // x = 71, f(x) = 0.999125
            8'd72: lut_val = 32'h3f7fcc0f; // x = 72, f(x) = 0.999207
            8'd73: lut_val = 32'h3f7fd0f6; // x = 73, f(x) = 0.999282
            8'd74: lut_val = 32'h3f7fd566; // x = 74, f(x) = 0.999350
            8'd75: lut_val = 32'h3f7fd96b; // x = 75, f(x) = 0.999411
            8'd76: lut_val = 32'h3f7fdd0f; // x = 76, f(x) = 0.999467
            8'd77: lut_val = 32'h3f7fe05b; // x = 77, f(x) = 0.999517
            8'd78: lut_val = 32'h3f7fe357; // x = 78, f(x) = 0.999563
            8'd79: lut_val = 32'h3f7fe60c; // x = 79, f(x) = 0.999604
            8'd80: lut_val = 32'h3f7fe87f; // x = 80, f(x) = 0.999641
            8'd81: lut_val = 32'h3f7feab6; // x = 81, f(x) = 0.999675
            8'd82: lut_val = 32'h3f7fecb9; // x = 82, f(x) = 0.999706
            8'd83: lut_val = 32'h3f7fee8b; // x = 83, f(x) = 0.999734
            8'd84: lut_val = 32'h3f7ff030; // x = 84, f(x) = 0.999759
            8'd85: lut_val = 32'h3f7ff1ae; // x = 85, f(x) = 0.999782
            8'd86: lut_val = 32'h3f7ff308; // x = 86, f(x) = 0.999802
            8'd87: lut_val = 32'h3f7ff442; // x = 87, f(x) = 0.999821
            8'd88: lut_val = 32'h3f7ff55d; // x = 88, f(x) = 0.999838
            8'd89: lut_val = 32'h3f7ff65e; // x = 89, f(x) = 0.999853
            8'd90: lut_val = 32'h3f7ff747; // x = 90, f(x) = 0.999867
            8'd91: lut_val = 32'h3f7ff81a; // x = 91, f(x) = 0.999879
            8'd92: lut_val = 32'h3f7ff8d9; // x = 92, f(x) = 0.999891
            8'd93: lut_val = 32'h3f7ff986; // x = 93, f(x) = 0.999901
            8'd94: lut_val = 32'h3f7ffa22; // x = 94, f(x) = 0.999910
            8'd95: lut_val = 32'h3f7ffab0; // x = 95, f(x) = 0.999919
            8'd96: lut_val = 32'h3f7ffb30; // x = 96, f(x) = 0.999927
            8'd97: lut_val = 32'h3f7ffba5; // x = 97, f(x) = 0.999934
            8'd98: lut_val = 32'h3f7ffc0e; // x = 98, f(x) = 0.999940
            8'd99: lut_val = 32'h3f7ffc6d; // x = 99, f(x) = 0.999945
            8'd100: lut_val = 32'h3f7ffcc4; // x = 100, f(x) = 0.999951
            8'd101: lut_val = 32'h3f7ffd12; // x = 101, f(x) = 0.999955
            8'd102: lut_val = 32'h3f7ffd59; // x = 102, f(x) = 0.999960
            8'd103: lut_val = 32'h3f7ffd99; // x = 103, f(x) = 0.999963
            8'd104: lut_val = 32'h3f7ffdd3; // x = 104, f(x) = 0.999967
            8'd105: lut_val = 32'h3f7ffe07; // x = 105, f(x) = 0.999970
            8'd106: lut_val = 32'h3f7ffe37; // x = 106, f(x) = 0.999973
            8'd107: lut_val = 32'h3f7ffe62; // x = 107, f(x) = 0.999975
            8'd108: lut_val = 32'h3f7ffe89; // x = 108, f(x) = 0.999978
            8'd109: lut_val = 32'h3f7ffead; // x = 109, f(x) = 0.999980
            8'd110: lut_val = 32'h3f7ffecd; // x = 110, f(x) = 0.999982
            8'd111: lut_val = 32'h3f7ffeea; // x = 111, f(x) = 0.999983
            8'd112: lut_val = 32'h3f7fff04; // x = 112, f(x) = 0.999985
            8'd113: lut_val = 32'h3f7fff1c; // x = 113, f(x) = 0.999986
            8'd114: lut_val = 32'h3f7fff31; // x = 114, f(x) = 0.999988
            8'd115: lut_val = 32'h3f7fff45; // x = 115, f(x) = 0.999989
            8'd116: lut_val = 32'h3f7fff56; // x = 116, f(x) = 0.999990
            8'd117: lut_val = 32'h3f7fff66; // x = 117, f(x) = 0.999991
            8'd118: lut_val = 32'h3f7fff75; // x = 118, f(x) = 0.999992
            8'd119: lut_val = 32'h3f7fff82; // x = 119, f(x) = 0.999992
            8'd120: lut_val = 32'h3f7fff8e; // x = 120, f(x) = 0.999993
            8'd121: lut_val = 32'h3f7fff99; // x = 121, f(x) = 0.999994
            8'd122: lut_val = 32'h3f7fffa2; // x = 122, f(x) = 0.999994
            8'd123: lut_val = 32'h3f7fffab; // x = 123, f(x) = 0.999995
            8'd124: lut_val = 32'h3f7fffb3; // x = 124, f(x) = 0.999995
            8'd125: lut_val = 32'h3f7fffbb; // x = 125, f(x) = 0.999996
            8'd126: lut_val = 32'h3f7fffc1; // x = 126, f(x) = 0.999996
            8'd127: lut_val = 32'h3f7fffc7; // x = 127, f(x) = 0.999997
            default: lut_val = 32'h00000000;
        endcase
    end

    // 打一拍输出 (与之前顶层 cnn_top 里的时序完美匹配)
    always @(posedge clk) begin
        if (en) begin
            sigmoid_out <= lut_val;
        end
    end

endmodule
```

### `Syn/rtl/sram_256x80.v`

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

### `Syn/rtl/weight_rom.v`

```verilog
`timescale 1ns / 1ps

module weight_rom (
    input  wire         clk,
    input  wire [11:0]  addr,    
    output reg  [2463:0] dout    
);

    // ROM 本体阵列
    reg [2463:0] rom_memory [0:1023];

    always @(posedge clk) begin
        dout <= rom_memory[addr];
    end

endmodule
```

### `Syn/rtl/cnn_controller.v`

```verilog
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
```

### `Syn/rtl/cnn_chip.v`

```verilog
`timescale 1ns / 1ps

// ==========================================================================
// 模块名称: cnn_chip (带 IO Pad 封装的真实流片顶层)
// 结构说明: 
//   外围使用 PIW (输入Pad) 和 PO8W (输出Pad) 将内部核心逻辑的信号引出。
// ==========================================================================

module cnn_chip(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 start,
    input  wire [255:0]         ext_act_in,     // 256-bit 数据输入
    input  wire                 ext_act_valid,
    
    output wire                 done,
    output wire [31:0]          fc_result,      // 32-bit 计算结果输出
    output wire                 fc_valid
);

    // ==========================================
    // 内部连线 (Net) 声明
    // ==========================================
    wire                 net_clk;
    wire                 net_rst_n;
    wire                 net_start;
    wire [255:0]         net_ext_act_in;
    wire                 net_ext_act_valid;
    
    wire                 net_done;
    wire [31:0]          net_fc_result;
    wire                 net_fc_valid;

    // ==========================================
    // 输入管脚 (Input Pads - PIW) 例化
    // ==========================================
    // 单比特控制信号
    PIW PIW_clk           (.PAD(clk),           .C(net_clk));
    PIW PIW_rst_n         (.PAD(rst_n),         .C(net_rst_n));
    PIW PIW_start         (.PAD(start),         .C(net_start));
    PIW PIW_ext_act_valid (.PAD(ext_act_valid), .C(net_ext_act_valid));

    // 256位数据总线批量例化 (等效于助教手写 256 行 PIW_dinX)
    genvar i;
    generate
        for (i = 0; i < 256; i = i + 1) begin : gen_piw_ext_act_in
            PIW PIW_ext_act_in_inst (
                .PAD (ext_act_in[i]), 
                .C   (net_ext_act_in[i])
            );
        end
    endgenerate

    // ==========================================
    // 输出管脚 (Output Pads - PO8W) 例化
    // ==========================================
    // 单比特控制信号
    PO8W PO8W_done        (.I(net_done),        .PAD(done));
    PO8W PO8W_fc_valid    (.I(net_fc_valid),    .PAD(fc_valid));

    // 32位数据总线批量例化 (等效于助教手写 32 行 PO8W_doutX)
    genvar j;
    generate
        for (j = 0; j < 32; j = j + 1) begin : gen_po8w_fc_result
            PO8W PO8W_fc_result_inst (
                .I   (net_fc_result[j]), 
                .PAD (fc_result[j])
            );
        end
    endgenerate

    // ==========================================
    // 核心算法模块 (Core) 例化
    // ==========================================
    cnn_top inst_CNN_top (
        .clk            (net_clk),
        .rst_n          (net_rst_n),
        .start          (net_start),
        .ext_act_in     (net_ext_act_in),
        .ext_act_valid  (net_ext_act_valid),
        .done           (net_done),
        .fc_result      (net_fc_result),
        .fc_valid       (net_fc_valid)
    );

endmodule
```

