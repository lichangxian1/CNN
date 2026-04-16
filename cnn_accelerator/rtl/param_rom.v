`timescale 1ns / 1ps

// ==========================================================================
// 模块名称: param_rom (全能参数多路选择器 / 模拟 ROM)
// 功能描述: 
//   1. 内部保留所有层的 Weight 和 Bias 存储空间声明。
//   2. 数据将由外部 Testbench 在仿真 0 时刻通过层次化路径注入。
//   3. 纯组合逻辑 (MUX)，根据 layer_mode 和 ch_grp_cnt 拼装超宽向量。
// ==========================================================================

module param_rom (
    input  wire         clk,          
    input  wire [1:0]   layer_mode,   
    input  wire [3:0]   ch_grp_cnt,   
    
    output reg [2463:0] wgt_in_flat,  
    output reg [511:0]  bias_in_flat  
);

    // ======================================================================
    // 1. 定义物理存储容器 (纯净的 reg 数组，等待 TB 注入)
    // ======================================================================
    reg [7:0]  rom_conv1_w [0:2463];
    reg [15:0] rom_conv1_b [0:31];

    reg [7:0]  rom_dw_w [0:287];
    reg [15:0] rom_dw_b [0:31];

    reg [7:0]  rom_pw_w [0:1023];
    reg [15:0] rom_pw_b [0:31];

    // 🌟 原来的 initial $readmemh 块已被彻底删除，确保 100% 可综合 🌟

    // ======================================================================
    // 2. 动态张量重排 (纯组合逻辑连线，代码不变)
    // ======================================================================
    integer k, p, ch, in_ch;
    
    always @(*) begin
        wgt_in_flat  = 2464'd0;
        bias_in_flat = 512'd0;
        
        case (layer_mode)
            2'd0: begin // 【Conv1 模式】
                for (k = 0; k < 4; k = k + 1) begin
                    bias_in_flat[k*16 +: 16] = rom_conv1_b[ch_grp_cnt * 4 + k];
                    for (p = 0; p < 77; p = p + 1) begin
                        wgt_in_flat[(k*77 + p)*8 +: 8] = rom_conv1_w[(ch_grp_cnt * 4 + k)*77 + p];
                    end
                end
            end
            
            2'd1: begin // 【DWConv 模式】
                for (ch = 0; ch < 32; ch = ch + 1) begin
                    bias_in_flat[ch*16 +: 16] = rom_dw_b[ch];
                    for (p = 0; p < 9; p = p + 1) begin
                        wgt_in_flat[(ch*9 + p)*8 +: 8] = rom_dw_w[ch*9 + p];
                    end
                end
            end
            
            2'd2: begin // 【PWConv 模式】
                for (k = 0; k < 8; k = k + 1) begin
                    bias_in_flat[k*16 +: 16] = rom_pw_b[ch_grp_cnt * 8 + k];
                    for (in_ch = 0; in_ch < 32; in_ch = in_ch + 1) begin
                        wgt_in_flat[(k*32 + in_ch)*8 +: 8] = rom_pw_w[(ch_grp_cnt * 8 + k)*32 + in_ch];
                    end
                end
            end
            
            default: ;
        endcase
    end

endmodule