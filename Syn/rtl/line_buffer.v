`timescale 1ns / 1ps

module line_buffer (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire [1:0]           layer_mode,   
    input  wire                 shift_en,     
    input  wire [255:0]         sram_data_in, 
    
    output reg                  window_valid, 
    output reg  [2463:0]        act_in_flat   
);

    reg [7:0]   cb [1:106];
    reg [255:0] db [1:10];
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 1; i <= 106; i = i + 1) cb[i] <= 8'd0;
            for (i = 1; i <= 10;  i = i + 1) db[i] <= 256'd0;
        end else if (shift_en) begin
            cb[1] <= sram_data_in[7:0];
            for (i = 2; i <= 106; i = i + 1) cb[i] <= cb[i-1];
            
            db[1] <= sram_data_in;
            for (i = 2; i <= 10;  i = i + 1) db[i] <= db[i-1];
        end
    end

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

    reg [1:0] prev_mode;
    reg [4:0] col_cnt; 
    reg [4:0] row_cnt; 
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_mode    <= 2'b00;
            col_cnt      <= 5'd0;
            row_cnt      <= 5'd0;
            window_valid <= 1'b0;
        end else begin
            prev_mode <= layer_mode;
            if (layer_mode != prev_mode) begin
                col_cnt      <= 5'd0;
                row_cnt      <= 5'd0;
                window_valid <= 1'b0;
            end 
            else if (shift_en) begin
                if (layer_mode == 2'd0) begin
                    if (col_cnt == 5'd9) begin
                        col_cnt <= 5'd0;
                        row_cnt <= row_cnt + 1'b1;
                    end else begin
                        col_cnt <= col_cnt + 1'b1;
                    end
                    // 🌟 修复 Conv1：宽度 10，核宽 7，每行有效输出 4 个。控制 col_cnt 只能是 5, 6, 7, 8
                    if (row_cnt >= 10 && col_cnt >= 5 && col_cnt <= 8) window_valid <= 1'b1;
                    else window_valid <= 1'b0;
                    
                end else if (layer_mode == 2'd1) begin
                    if (col_cnt == 5'd3) begin
                        col_cnt <= 5'd0;
                        row_cnt <= row_cnt + 1'b1;
                    end else begin
                        col_cnt <= col_cnt + 1'b1;
                    end
                    // 🌟 修复 DWConv：宽度 4，核宽 3，每行有效输出 2 个。控制 col_cnt 只能是 1, 2
                    if (row_cnt >= 2 && col_cnt >= 1 && col_cnt <= 2) window_valid <= 1'b1;
                    else window_valid <= 1'b0;
                    
                end else if (layer_mode == 2'd2) begin
                    window_valid <= 1'b1;
                end
            end
        end
    end

    reg [7:0] conv_window [0:76];
    reg [7:0] dw_window   [0:31][0:8];
    integer r, c, p, ch, grp;

    always @(*) begin
        act_in_flat = 2464'd0;
        p = 0;
        
        // -------------------------------------------------------------
        // 🌟 核心修改 4：空间翻转 (Spatial Flip Mapping)
        // -------------------------------------------------------------
        for (r = 0; r < 11; r = r + 1) begin
            for (c = 0; c < 7; c = c + 1) begin
                // MAC 期望 p=0 是最老的像素（左上角），对应 cb_wire 最大的索引
                conv_window[p] = cb_wire[(10 - r) * 10 + (6 - c)];
                p = p + 1;
            end
        end
        
        for (ch = 0; ch < 32; ch = ch + 1) begin
            p = 0;
            for (r = 0; r < 3; r = r + 1) begin
                for (c = 0; c < 3; c = c + 1) begin
                    // DW 同样翻转映射
                    dw_window[ch][p] = db_wire[(2 - r) * 4 + (2 - c)][ch*8 +: 8];
                    p = p + 1;
                end
            end
        end

        if (layer_mode == 2'd0) begin
            for (grp = 0; grp < 4; grp = grp + 1) begin
                for (p = 0; p < 77; p = p + 1) begin
                    act_in_flat[(grp*77 + p)*8 +: 8] = conv_window[p];
                end
            end
        end 
        else if (layer_mode == 2'd1) begin
            for (ch = 0; ch < 32; ch = ch + 1) begin
                for (p = 0; p < 9; p = p + 1) begin
                    act_in_flat[(ch*9 + p)*8 +: 8] = dw_window[ch][p];
                end
            end
        end 
        else if (layer_mode == 2'd2) begin
            for (grp = 0; grp < 8; grp = grp + 1) begin
                for (ch = 0; ch < 32; ch = ch + 1) begin
                    // 修复：改用经过移位锁存的 db_wire[1]，隔绝预取地址提前变化的影响
                    act_in_flat[(grp*32 + ch)*8 +: 8] = db_wire[1][ch*8 +: 8]; 
                end
            end
        end
        else if (layer_mode == 2'd3) begin
            for (r = 0; r < 9; r = r + 1) begin
                for (c = 0; c < 32; c = c + 1) begin
                    // 🌟 拨乱反正：恢复最原汁原味的 c * 9 + r，这才是 PyTorch 真实的展平顺序！
                    act_in_flat[ (c * 9 + r) * 8 +: 8 ] = db_wire[9 - r][c*8 +: 8];
                end
            end
        end
    end
endmodule