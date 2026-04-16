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