`timescale 1ns / 1ps

// ==========================================================================
// 模块名称: post_process (后处理：偏置加法 + 重量化 + ReLU)
// 功能描述: 
//   1. 接收 MAC 阵列输出的 32 个 INT32 累加和。
//   2. 加上对应通道的 INT16 偏置 (Bias)。
//   3. 进行重量化 Re-quantization: O = (I * M0) >> n
//   4. ReLU 激活: 负数截断为 0。
//   5. 饱和防溢出处理，最终输出 32 个 INT8 数据拼接而成的 256-bit 向量。
// ==========================================================================

module post_process (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 mac_valid,       // 标志当前输入的 INT32 数据有效
    
    // 输入接口 (来自 MAC 阵列与 SRAM)
    input  wire [1023:0]        psum_in_flat,    // 32 个 32-bit INT32 局部累加和
    input  wire [511:0]         bias_in_flat,    // 32 个 16-bit INT16 偏置
    
    // 量化参数 (假设由全局寄存器或统一配置给出，这里简化为统一输入)
    input  wire signed [15:0]   quant_M0,        // 量化乘数 M0
    input  wire [3:0]           quant_n,         // 量化右移位数 n (假设最大移位 15)
    
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
    // 1. 流水线计算：加偏置 -> 乘 M0 -> 移位截断 -> ReLU
    // ----------------------------------------------------------------------
    integer i;
    reg signed [32:0]  psum_with_bias;   // 扩展 1 位防溢出
    reg signed [47:0]  quant_mult;       // 32-bit * 16-bit = 48-bit 乘积
    reg signed [47:0]  quant_shifted;    // 移位后的结果
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            act_out_flat <= 256'd0;
        end else begin
            // 信号透传打拍
            out_valid <= mac_valid;
            
            if (mac_valid) begin
                for (i = 0; i < 32; i = i + 1) begin
                    // Step 1: 加偏置 (需将 INT16 的偏置符号扩展为 33 位相加)
                    psum_with_bias = $signed(psum_in[i]) + $signed({{16{bias_in[i][15]}}, bias_in[i]});
                    
                    // Step 2: 乘以 M0 (重量化公式 O = I * M0 * 2^-n 的前一半)
                    // 在硬件里我们先乘，以保留精度
                    quant_mult = psum_with_bias * $signed(quant_M0);
                    
                    // Step 3: 算术右移 n 位 (这里用 >>> 确保符号位正确填补)
                    quant_shifted = quant_mult >>> quant_n;
                    
                    // Step 4 & 5: ReLU 与 饱和截断 (Saturation) 变回 INT8
                    if (quant_shifted < 0) begin
                        // ReLU 激活：小于 0 的直接置 0
                        act_out_flat[i*8 +: 8] <= 8'd0;
                    end 
                    else if (quant_shifted > 127) begin
                        // 饱和处理：超过 INT8 正数最大值 127，强行卡在 127
                        act_out_flat[i*8 +: 8] <= 8'd127;
                    end 
                    else begin
                        // 正常截断取低 8 位
                        act_out_flat[i*8 +: 8] <= quant_shifted[7:0];
                    end
                end
            end
        end
    end

endmodule