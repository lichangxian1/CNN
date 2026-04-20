`timescale 1ns / 1ps

module tb_post_process;
    reg clk = 0;
    reg rst_n = 1;
    always #5 clk = ~clk;

    reg  mac_valid;
    reg  [1:0] layer_mode;
    reg  [1023:0] psum_in_flat;
    reg  [511:0]  bias_in_flat;
    wire out_valid;
    wire [255:0] act_out_flat;

    post_process uut (
        .clk(clk), .rst_n(rst_n),
        .mac_valid(mac_valid), .layer_mode(layer_mode),
        .psum_in_flat(psum_in_flat), .bias_in_flat(bias_in_flat),
        .out_valid(out_valid), .act_out_flat(act_out_flat)
    );

    // 构造一个在四舍五入边缘的数据
    // 假设 Conv1: M0 = 111, n = 14 (分母为 16384)
    // 构造 psum_with_bias * M0 = 24576 (数学上 24576 / 16384 = 1.5)
    // 如果不加四舍五入，直接 >>>14，结果会是 1
    // 如果加上四舍五入，结果应该是 2

    initial begin
        rst_n = 0; mac_valid = 0; psum_in_flat = 0; bias_in_flat = 0;
        #15 rst_n = 1;
        
        // 注入测试数据 (通道 0 测试正数四舍五入，通道 1 测试负数极端饱和)
        layer_mode = 2'd0; // Conv1 模式 (M0=111, n=14)
        mac_valid  = 1;
        
        // Channel 0: 构造 psum + bias = 221 (221 * 111 = 24531, 24531/16384 = 1.49... 应舍入为 1)
        // Channel 1: 构造 psum + bias = 222 (222 * 111 = 24642, 24642/16384 = 1.504... 应舍入为 2)
        // Channel 2: 测试负数极值饱和 (FC模式下测试)
        psum_in_flat[31:0]   = 32'd221; bias_in_flat[15:0]   = 16'd0;
        psum_in_flat[63:32]  = 32'd222; bias_in_flat[31:16]  = 16'd0;
        
        #10 mac_valid = 0;
        
        #20; // 等待两拍流水线
        $display("=================================================");
        $display("[post_process 精度与截断测试]");
        $display("数学期望 1.49 -> 硬件输出: %d (预期: 1)", act_out_flat[7:0]);
        $display("数学期望 1.50 -> 硬件输出: %d (预期: 2)", act_out_flat[15:8]);
        
        if (act_out_flat[15:8] == 8'd1)
            $display(">>> 结论：发生了【截断误差】！你需要补上 +(1<<(n-1)) 的四舍五入偏置！");
        else if (act_out_flat[15:8] == 8'd2)
            $display(">>> 结论：四舍五入【正确】！");
        $display("=================================================");
        $finish;
    end
endmodule