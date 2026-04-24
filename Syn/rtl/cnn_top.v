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
    // 🌟 新增：为 bias 添加两级流水线延迟，对齐 MAC 阵列
    reg  [511:0]  bias_pipe_0;
    reg  [511:0]  bias_pipe_1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bias_pipe_0 <= 512'd0;
            bias_pipe_1 <= 512'd0;
        end else begin
            bias_pipe_0 <= bias_in_flat;
            bias_pipe_1 <= bias_pipe_0;
        end
    end
    
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

// 🚨 删去写死的 quant_M0 和 quant_n，传入动态对齐的 layer_mode_pipe[1]
// 🚨 删去写死的 quant_M0 和 quant_n，传入动态对齐的 layer_mode_pipe[1]
    post_process u_post_process (
        .clk(clk), 
        .rst_n(rst_n), 
        .mac_valid(mac_valid_sync), 
        .layer_mode(layer_mode_pipe[1]), 
        .psum_in_flat(psum_out_flat), 
        // 🌟 核心修复：这里改为传入延迟 2 拍的 bias，实现时空绝对对齐！
        .bias_in_flat(bias_pipe_1), 
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

endmodule