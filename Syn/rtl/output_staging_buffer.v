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
    output reg  [6:0]       staging_waddr,
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