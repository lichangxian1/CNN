`timescale 1ns / 1ps

module tb_param_rom;
    reg clk;
    reg [1:0] layer_mode;
    reg [3:0] ch_grp_cnt;
    wire [2463:0] wgt_in_flat;
    wire [511:0]  bias_in_flat;

    // 例化待测模块
    param_rom uut (
        .clk(clk),
        .layer_mode(layer_mode),
        .ch_grp_cnt(ch_grp_cnt),
        .wgt_in_flat(wgt_in_flat),
        .bias_in_flat(bias_in_flat)
    );

    initial begin
        clk = 0;
        // 设定为全连接层 (FC)，计算第 0 个神经元
        layer_mode = 2'd3; 
        ch_grp_cnt = 4'd0; 
        
        #10;
        $display("=================================================");
        $display("[param_rom 提取端序测试]");
        $display("预期 FC 层第 1 个权重: 20");
        $display("预期 FC 层第 2 个权重: -23");
        $display("-------------------------------------------------");
        // 检查送入 MAC 阵列最右侧（最低8位）的第一个数据
        $display("实际 wgt_in_flat[7:0]   读取到的值: %d", $signed(wgt_in_flat[7:0]));
        $display("实际 wgt_in_flat[15:8]  读取到的值: %d", $signed(wgt_in_flat[15:8]));
        
        if ($signed(wgt_in_flat[7:0]) == 20)
            $display(">>> 结论：端序【正确】！张量拼接无误。");
        else
            $display(">>> 结论：端序【反了】！你读到的是巨型字符串最末尾的垃圾数据！");
        $display("=================================================");
        $finish;
    end
endmodule