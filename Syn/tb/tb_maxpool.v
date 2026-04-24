`timescale 1ns / 1ps

module tb_maxpool();

    // ==========================================
    // 1. 信号与接口定义
    // ==========================================
    reg          clk;
    reg          rst_n;
    reg          pool_start;
    
    wire [9:0]   sram_raddr;
    reg  [255:0] sram_rdata;
    
    wire [9:0]   sram_waddr;
    wire [255:0] sram_wdata;
    wire         sram_wen;
    wire         pool_done;

    // 例化待测模块 (DUT)
    maxpool_unit u_maxpool (
        .clk        (clk),
        .rst_n      (rst_n),
        .pool_start (pool_start),
        .sram_rdata (sram_rdata),
        .sram_raddr (sram_raddr),
        .sram_waddr (sram_waddr),
        .sram_wdata (sram_wdata),
        .sram_wen   (sram_wen),
        .pool_done  (pool_done)
    );

    // ==========================================
    // 2. 模拟 SRAM 与数据装载
    // ==========================================
    reg [255:0] fake_sram      [0:35]; // 充当 PWConv 输出的数据源 (36个地址)
    reg [255:0] golden_maxpool [0:8];  // Python 生成的正确答案 (9个地址)
    
    integer fd, code;
    integer i, c;
    integer err_cnt, write_cnt;

    initial begin
        // A. 预加载 PWConv 数据到 fake_sram
        // 注意：PWConv_Out 是按照通道外循环、像素内循环排列的 (c*36 + i)
        // 但 SRAM 的物理排布是按像素排列的 (每个地址存 32 个通道)
        fd = $fopen("./data/Test/Out_PWConv.txt", "r");
        if (fd == 0) begin
            $display("❌ [ERROR] 找不到 Out_PWConv.txt 文件！");
            $finish;
        end
        for (c = 0; c < 32; c = c + 1) begin
            for (i = 0; i < 36; i = i + 1) begin
                integer tmp; code = $fscanf(fd, "%d", tmp);
                fake_sram[i][c*8 +: 8] = tmp[7:0];
            end
        end
        $fclose(fd);

        // B. 预加载 Python 算出的黄金池化答案
        fd = $fopen("./data/Test/Out_Maxpool_py.txt", "r");
        if (fd == 0) begin
            $display("❌ [ERROR] 找不到 Out_Maxpool_py.txt 文件！");
            $finish;
        end
        // Python 输出的是 9 行，每行 32 个用空格隔开的数字
        for (i = 0; i < 9; i = i + 1) begin
            for (c = 0; c < 32; c = c + 1) begin
                integer tmp; code = $fscanf(fd, "%d", tmp);
                golden_maxpool[i][c*8 +: 8] = tmp[7:0];
            end
        end
        $fclose(fd);
    end

    // 模拟 SRAM 的 1 拍读延迟 (地址在 posedge T0 给出，数据在 T1 更新，供模块在 T2 使用)
    always @(posedge clk) begin
        if (sram_raddr < 36) begin
            sram_rdata <= fake_sram[sram_raddr];
        end
    end

    // ==========================================
    // 3. 时钟生成与主测试流程
    // ==========================================
    initial begin
        clk = 0; forever #5 clk = ~clk; 
    end

    initial begin
        err_cnt = 0;
        write_cnt = 0;
        rst_n = 0;
        pool_start = 0;
        
        #100;
        rst_n = 1;
        #20;
        
        $display("\n🚀 [Maxpool Unit Test] 独立验证启动...");
        
        // 给出单拍的启动脉冲
        @(posedge clk);
        pool_start = 1;
        @(posedge clk);
        pool_start = 0;

        // 死等 pool_done 信号
        wait(pool_done == 1'b1);
        @(posedge clk);

        $display("--------------------------------------------------");
        if (err_cnt == 0 && write_cnt == 9) begin
            $display(" 🎉 [PASS] Maxpool (含 ReLU) 逻辑 100%% 正确！");
            $display("    共捕获 %0d 次 SRAM 写入，零错误。", write_cnt);
        end else begin
            $display(" ❌ [FAIL] Maxpool 模块有 %0d 个通道错误，发生写入 %0d 次 (预期9次)。", err_cnt, write_cnt);
        end
        $display("==================================================\n");
        $finish;
    end

    // ==========================================
    // 4. 实时拦截核对：当 sram_wen 被拉低时验证数据
    // ==========================================
    reg signed [7:0] actual_val, expected_val;
    
    // 使用 negedge 避免与 posedge 时产生的信号发生竞争(Race Condition)
    always @(negedge clk) begin
        if (!sram_wen && rst_n) begin
            for (c = 0; c < 32; c = c + 1) begin
                actual_val   = sram_wdata[c*8 +: 8];
                expected_val = golden_maxpool[sram_waddr][c*8 +: 8];
                
                if (actual_val !== expected_val) begin
                    if (err_cnt < 20) begin
                        $display("   -> [Maxpool ERROR] Addr %0d, Ch %0d | Exp: %0d, Got: %0d", 
                                 sram_waddr, c, expected_val, actual_val);
                    end
                    err_cnt = err_cnt + 1;
                end
            end
            write_cnt = write_cnt + 1;
        end
    end

endmodule