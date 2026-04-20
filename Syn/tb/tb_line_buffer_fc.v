`timescale 1ns / 1ps

module tb_line_buffer_fc;
    reg clk = 0;
    reg rst_n = 1;
    always #5 clk = ~clk;

    reg  [1:0]   layer_mode;
    reg          shift_en;
    reg  [255:0] sram_data_in;
    wire         window_valid;
    wire [2463:0] act_in_flat;

    line_buffer uut (
        .clk(clk), .rst_n(rst_n),
        .layer_mode(layer_mode), .shift_en(shift_en),
        .sram_data_in(sram_data_in),
        .window_valid(window_valid), .act_in_flat(act_in_flat)
    );

    integer i, ch;
    initial begin
        rst_n = 0; layer_mode = 2'd3; shift_en = 0; sram_data_in = 0;
        #15 rst_n = 1;
        
        // 模拟 cnn_controller 的 ST_FC_LOAD 状态：连续压入 9 拍数据
        // 为方便观察，每拍的数据为其“行号”。例如第0行全是 8'h00，第1行全是 8'h11...第8行全是 8'h88
        for (i = 0; i < 9; i = i + 1) begin
            shift_en = 1;
            for (ch = 0; ch < 32; ch = ch + 1) begin
                sram_data_in[ch*8 +: 8] = i * 8'h11; // 写入 0x00, 0x11, 0x22...
            end
            #10;
        end
        shift_en = 0;
        
        #10;
        $display("=================================================");
        $display("[line_buffer 全连接层 Flatten 测试]");
        // 在 PyTorch 中，NCHW 展平后，第一个元素应该是 Channel 0 的 Row 0 (也就是最老的那一拍数据，值为 0x00)
        // 最后一个元素应该是 Channel 31 的 Row 8 (最新的一拍数据，值为 0x88)
        
        $display("提取的最老像素 (预期 0)   : %h", act_in_flat[7:0]);
        $display("提取的第二老像素 (预期 11): %h", act_in_flat[15:8]);
        $display("提取的最新像素 (预期 88)  : %h", act_in_flat[2463:2456]);
        
        if (act_in_flat[7:0] !== 8'h00)
            $display(">>> 结论：逆序提取【存在越界或脏数据】！公式写错了！");
        else
            $display(">>> 结论：Flatten 张量映射【正确】！");
        $display("=================================================");
        $finish;
    end
endmodule