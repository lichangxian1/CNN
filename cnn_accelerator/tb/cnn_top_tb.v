`timescale 1ns / 1ps

// ==========================================================================
// 模块名称: cnn_top_tb (全链路系统级验证平台)
// ==========================================================================

module cnn_top_tb();

    // ---------------------------------------------------------
    // 1. 全局信号定义
    // ---------------------------------------------------------
    reg          clk;
    reg          rst_n;
    reg          start;
    
    // 假设外部通过这些引脚给芯片喂初始图像数据 (目前可以先置 0)
    reg  [255:0] ext_act_in;
    reg          ext_act_valid;
    wire         done;

    // ---------------------------------------------------------
    // 2. 顶层芯片例化 (Device Under Test)
    // ---------------------------------------------------------
    cnn_top uut_cnn_top (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (start),
        .ext_act_in     (ext_act_in),
        .ext_act_valid  (ext_act_valid),
        .done           (done)
    );

    // ---------------------------------------------------------
    // 3. 时钟生成
    // ---------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk; // 100MHz

    // ---------------------------------------------------------
    // 🌟 4. 核心后门加载：将文件数据强行注入芯片内部 🌟
    // ---------------------------------------------------------
    initial begin
        $display("==================================================");
        $display(" [Backdoor Loading] Loading CNN Parameters...");
        $display("==================================================");
        
        // 注意路径：基于你运行仿真 (iverilog/vcs) 时的相对目录
        // 语法: $readmemh("文件路径", 顶层例化名.子模块例化名.内部变量名);
        
        $readmemh("../data/CNN测试数据/Param/Param_Conv_Weight.txt",   uut_cnn_top.u_param_rom.rom_conv1_w);
        $readmemh("../data/CNN测试数据/Param/Param_Conv_Bias.txt",     uut_cnn_top.u_param_rom.rom_conv1_b);
        
        $readmemh("../data/CNN测试数据/Param/Param_DWConv_Weight.txt", uut_cnn_top.u_param_rom.rom_dw_w);
        $readmemh("../data/CNN测试数据/Param/Param_DWConv_Bias.txt",   uut_cnn_top.u_param_rom.rom_dw_b);
        
        $readmemh("../data/CNN测试数据/Param/Param_PWConv_Weight.txt", uut_cnn_top.u_param_rom.rom_pw_w);
        $readmemh("../data/CNN测试数据/Param/Param_PWConv_Bias.txt",   uut_cnn_top.u_param_rom.rom_pw_b);
        
        // 如果你后续还有 Input 图像特征图，也可以直接注入到 Ping SRAM 中
        // $readmemh("../data/CNN测试数据/Input_MFCC.txt", uut_cnn_top.u_sram_ping.u_sram_low.mem_array);
        // $readmemh("../data/CNN测试数据/Input_MFCC.txt", uut_cnn_top.u_sram_ping.u_sram_high.mem_array);
        
        $display(" [Backdoor Loading] Parameters Loaded Successfully!");
    end

    // ---------------------------------------------------------
    // 5. 仿真流程控制
    // ---------------------------------------------------------
    initial begin
        // 波形抓取 (可选)
        $dumpfile("cnn_system.vcd");
        $dumpvars(0, cnn_top_tb);
        
        // 系统初始化
        rst_n         = 0;
        start         = 0;
        ext_act_in    = 0;
        ext_act_valid = 0;
        
        #100;
        rst_n = 1; // 释放复位
        #20;
        
        // 发送启动脉冲，全链路开跑！
        $display(" [System] Asserting START signal...");
        start = 1;
        #10;
        start = 0;
        
        // 等待芯片运算完成
        wait(done == 1'b1);
        $display(" [System] DONE signal received. Inference Complete!");
        
        #100;
        $finish;
    end

endmodule