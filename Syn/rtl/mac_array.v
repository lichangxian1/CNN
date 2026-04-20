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