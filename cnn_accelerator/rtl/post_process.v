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
    input  wire        AV         mac_valid,       // 标志当前输入的 INT32 数据有效
    
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