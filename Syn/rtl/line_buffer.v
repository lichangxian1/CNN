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