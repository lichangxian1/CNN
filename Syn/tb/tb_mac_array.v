`timescale 1ns / 1ps

module tb_mac_array();

    // ==========================================
    // 1. 时钟与复位信号
    // ==========================================
    reg clk;
    reg rst_n;

    // ==========================================
    // 2. 模块接口信号
    // ==========================================
    reg  [1:0]      layer_mode;
    wire [2463:0]   act_in_flat;
    wire [2463:0]   wgt_in_flat;
    wire [1023:0]   psum_out_flat;

    // ==========================================
    // 3. 为了方便赋值，定义易读的一维数组 (308个点)
    // ==========================================
    reg signed [7:0] tb_act_in [0:307];
    reg signed [7:0] tb_wgt_in [0:307];

    // 自动打包逻辑：将易读的数组拼装成 2464-bit 给模块输入
    genvar g;
    generate
        for (g = 0; g < 308; g = g + 1) begin : pack_loop
            assign act_in_flat[g*8 +: 8] = tb_act_in[g];
            assign wgt_in_flat[g*8 +: 8] = tb_wgt_in[g];
        end
    endgenerate

    // 自动解包逻辑：将输出的 1024-bit 拆解为 32 个 32-bit 方便我们用 $display 查看
    wire signed [31:0] psum_out [0:31];
    generate
        for (g = 0; g < 32; g = g + 1) begin : unpack_loop
            assign psum_out[g] = psum_out_flat[g*32 +: 32];
        end
    endgenerate

    // ==========================================
    // 4. 被测模块 (DUT) 实例化
    // ==========================================
    mac_array dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .layer_mode     (layer_mode),
        .act_in_flat    (act_in_flat),
        .wgt_in_flat    (wgt_in_flat),
        .psum_out_flat  (psum_out_flat)
    );

    // ==========================================
    // 5. 时钟生成 (100MHz)
    // ==========================================
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 周期 10ns
    end

    // ==========================================
    // 6. 主测试流程
    // ==========================================
    integer i, grp, p;
    initial begin
        // --- 初始化 ---
        rst_n = 0;
        layer_mode = 2'b00; // 设置为 Conv1 模式
        for (i = 0; i < 308; i = i + 1) begin
            tb_act_in[i] = 8'd0;
            tb_wgt_in[i] = 8'd0;
        end

        // --- 复位释放 ---
        #20;
        rst_n = 1;
        #10; // 等待一个周期

        $display("========== 测试开始: Conv1 模式 ==========");

        // -------------------------------------------------------------
        // 【修改这里 1】：填入你的特征图 (Feature Map) 数据
        // 说明: Conv1 模式下，MAC 阵列有 4 组，每组 77 个乘法器。
        // 根据你在 line_buffer.v 的设计，这 4 组输入的是**完全相同的特征图窗口**。
        // -------------------------------------------------------------
        // 假设你要输入的 77 个点的数据放在以下循环中：
        for (grp = 0; grp < 4; grp = grp + 1) begin
            for (p = 0; p < 77; p = p + 1) begin
                // 这里我用简单的递增数列 1, 2, 3... 模拟你提取的 77 个特征点
                // 真实验证时，请替换为你手头的真实数据，例如： tb_act_in[grp*77 + p] = real_act_data[p];
                tb_act_in[grp*77 + p] = p + 1; 
            end
        end

        // -------------------------------------------------------------
        // 【修改这里 2】：填入你的权重 (Weight) 数据
        // 说明: 4 组对应 4 个不同的输出通道卷积核，每个核 77 个权重。
        // -------------------------------------------------------------
        for (grp = 0; grp < 4; grp = grp + 1) begin
            for (p = 0; p < 77; p = p + 1) begin
                // 这里我给 4 个卷积核赋不同的固定值作为示例：
                // Kernel 0 全为 1, Kernel 1 全为 2, Kernel 2 全为 -1, Kernel 3 全为 0
                // 真实验证时，请替换为真实权重，例如：tb_wgt_in[grp*77 + p] = real_wgt_data[grp][p];
                if (grp == 0) tb_wgt_in[grp*77 + p] = 8'sd1;
                if (grp == 1) tb_wgt_in[grp*77 + p] = 8'sd2;
                if (grp == 2) tb_wgt_in[grp*77 + p] = -8'sd1;
                if (grp == 3) tb_wgt_in[grp*77 + p] = 8'sd0;
            end
        end

        // -------------------------------------------------------------
        // 🌟 关键点：等待流水线延迟 (2 拍)
        // -------------------------------------------------------------
        // MAC 阵列内部有两级寄存器：
        // 第 1 拍：乘法器输出 (mult_out)
        // 第 2 拍：加法树汇总并输出 (psum_out_flat)
        @(posedge clk); // 数据打入
        @(posedge clk); // 流水线 Stage 1 (乘法完成)
        @(posedge clk); // 流水线 Stage 2 (加法完成并输出)
        #1; // 稍微延后一点查看波形稳定值

        // -------------------------------------------------------------
        // 【修改这里 3】：验证输出结果
        // 说明: Conv1 模式下，只有前 4 个通道的数据 (psum_out[0] 到 [3]) 是有效的。
        // -------------------------------------------------------------
        $display("Time: %0t ns", $time);
        $display("--- 实际计算输出 ---");
        $display("Channel 0 Psum: %d", psum_out[0]);
        $display("Channel 1 Psum: %d", psum_out[1]);
        $display("Channel 2 Psum: %d", psum_out[2]);
        $display("Channel 3 Psum: %d", psum_out[3]);
        
        // （你可以利用 if 语句将其与你给的预期结果对比）
        // 比如上面例子中，Ch0 = 1*1 + 2*1 + ... + 77*1 = 3003
        // Ch1 = 1*2 + 2*2 + ... + 77*2 = 6006
        if (psum_out[0] == 32'd3003) 
            $display(">> Channel 0 测试通过 (Pass)!");
        else 
            $display(">> Channel 0 测试失败 (Fail)!");

        #50;
        $display("========== 测试结束 ==========");
        $finish;
    end

    // 可选：产生 VCD 波形文件用于 gtkwave 或 modelsim 查看
    initial begin
        $dumpfile("tb_mac_array.vcd");
        $dumpvars(0, tb_mac_array);
    end

endmodule