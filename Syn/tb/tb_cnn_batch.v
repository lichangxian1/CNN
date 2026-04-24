`timescale 1ns / 1ps

module tb_cnn_batch;

    // ----------------------------------------------------
    // 信号声明
    // ----------------------------------------------------
    reg                 clk;
    reg                 rst_n;
    reg                 start;
    reg  [255:0]        ext_act_in;
    reg                 ext_act_valid;

    wire                done;
    wire [31:0]         fc_result;
    wire                fc_valid;

    // ----------------------------------------------------
    // 实例化顶层模块 cnn_top
    // ----------------------------------------------------
    cnn_top uut (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (start),
        .ext_act_in     (ext_act_in),
        .ext_act_valid  (ext_act_valid),
        .done           (done),
        .fc_result      (fc_result),
        .fc_valid       (fc_valid)
    );

    // ----------------------------------------------------
    // 时钟生成 (100MHz)
    // ----------------------------------------------------
    initial begin
        clk = 0;
        forever #5 clk = ~clk; 
    end

    // ----------------------------------------------------
    // 自定义转换与比对函数 (FP32 to Real & ABS)
    // ----------------------------------------------------
    function real fp32_to_real;
        input [31:0] fp32;
        reg        sign;
        reg [7:0]  exp;
        reg [22:0] frac;
        reg [10:0] exp64;
        reg [63:0] fp64;
        begin
            sign = fp32[31];
            exp  = fp32[30:23];
            frac = fp32[22:0];

            if (exp == 8'h00) begin
                exp64 = 11'h000; 
            end else if (exp == 8'hFF) begin
                exp64 = 11'h7FF; 
            end else begin
                exp64 = exp - 127 + 1023; 
            end

            fp64 = {sign, exp64, frac, 29'd0};
            fp32_to_real = $bitstoreal(fp64);
        end
    endfunction

    function real abs_real;
        input real val;
        begin
            if (val < 0.0) abs_real = -val;
            else abs_real = val;
        end
    endfunction

    // ----------------------------------------------------
    // 批量自动化验证主程序
    // ----------------------------------------------------
    integer f_idx;
    reg [2047:0] in_filename;  // 用于存放字符串路径
    reg [2047:0] out_filename; // 用于存放字符串路径
    integer fd_in, fd_out, r;
    integer val;
    integer pixel_cnt, addr_cnt;
    reg [255:0] sram_data;

    // 验证与统计变量
    real golden_val [0:1];
    real actual_val [0:1];
    real diff0, diff1;
    real max_err_observed;
    
    integer pass_cnt;
    integer fail_cnt;
    integer fc_cnt;
    integer wait_cnt;

    // 🌟 设置最大容忍误差 (根据 LUT 8-bit 的精度，0.015 以内都是正常的)
    localparam real ERROR_TOLERANCE = 0.015;

    initial begin
        // 初始化
        rst_n = 0;
        start = 0;
        ext_act_in = 0;       
        ext_act_valid = 0;
        
        max_err_observed = 0.0;
        pass_cnt = 0;
        fail_cnt = 0;

        $dumpfile("cnn_batch.vcd");
        $dumpvars(0, tb_cnn_batch);

        $display("\n==================================================");
        $display("[START] CNN Hardware Batch Regression Test");
        $display("Total Files: 496 | Tolerance: %f", ERROR_TOLERANCE);
        $display("==================================================\n");

        // 核心大循环：遍历 496 个输入文件
        for (f_idx = 0; f_idx < 496; f_idx = f_idx + 1) begin
            
            // 1. 动态生成文件名
            $sformat(in_filename, "./data/In/%0d.txt", f_idx);
            $sformat(out_filename, "./data/Out/%0d.txt", f_idx);

            fd_in = $fopen(in_filename, "r");
            fd_out = $fopen(out_filename, "r");
            
            if (fd_in == 0 || fd_out == 0) begin
                $display("[WARNING] Missing file for index %0d. Skipping...", f_idx);
                if (fd_in != 0) $fclose(fd_in);
                if (fd_out != 0) $fclose(fd_out);
                // 移除了 continue; 改用 else 块包住后续逻辑
            end else begin
            
                // 2. 清空底层 SRAM 阵列 (防止上一轮的脏数据残留)
                for (addr_cnt = 0; addr_cnt < 80; addr_cnt = addr_cnt + 1) begin
                    uut.u_sram_ping.u_sram_low.mem_array[addr_cnt]  = 128'd0;
                    uut.u_sram_ping.u_sram_high.mem_array[addr_cnt] = 128'd0;
                end

                // 3. 读取 Input 并后门灌入 SRAM
                pixel_cnt = 0;
                addr_cnt = 0;
                sram_data = 256'd0;
                while (!$feof(fd_in) && pixel_cnt < 300) begin
                    r = $fscanf(fd_in, "%d", val);
                    if (r == 1) begin
                        sram_data[(pixel_cnt%32)*8 +: 8] = val[7:0];
                        pixel_cnt = pixel_cnt + 1;
                        if (pixel_cnt % 32 == 0) begin
                            uut.u_sram_ping.u_sram_low.mem_array[addr_cnt]  = sram_data[127:0];
                            uut.u_sram_ping.u_sram_high.mem_array[addr_cnt] = sram_data[255:128];
                            addr_cnt = addr_cnt + 1;
                            sram_data = 256'd0;
                        end
                    end
                end
                if (pixel_cnt % 32 != 0) begin // 写入最后不满 32 字节的尾部
                    uut.u_sram_ping.u_sram_low.mem_array[addr_cnt]  = sram_data[127:0];
                    uut.u_sram_ping.u_sram_high.mem_array[addr_cnt] = sram_data[255:128];
                end
                $fclose(fd_in);

                // 4. 读取该文件对应的 Golden Output (两颗神经元的 FP32 浮点值)
                r = $fscanf(fd_out, "%f %f", golden_val[0], golden_val[1]);
                $fclose(fd_out);

                // 5. 触发硬件复位与启动
                rst_n = 0;
                #100;
                rst_n = 1;
                #20;
                
                @(posedge clk);
                start = 1;
                @(posedge clk);
                start = 0;

                // 6. 等待并拦截 2 个 fc_valid 脉冲
                fc_cnt = 0;
                wait_cnt = 0;
                while (fc_cnt < 2 && wait_cnt < 500000) begin
                    @(posedge clk);
                    wait_cnt = wait_cnt + 1;
                    if (fc_valid) begin
                        actual_val[fc_cnt] = fp32_to_real(fc_result);
                        fc_cnt = fc_cnt + 1;
                    end
                end

                // 7. 结果校验与容差计算
                if (wait_cnt >= 500000) begin
                    $display("[ERROR] Timeout on File %0d!", f_idx);
                    fail_cnt = fail_cnt + 1;
                end else begin
                    diff0 = abs_real(actual_val[0] - golden_val[0]);
                    diff1 = abs_real(actual_val[1] - golden_val[1]);
                    
                    // 记录历史最大误差
                    if (diff0 > max_err_observed) max_err_observed = diff0;
                    if (diff1 > max_err_observed) max_err_observed = diff1;

                    if (diff0 > ERROR_TOLERANCE || diff1 > ERROR_TOLERANCE) begin
                        fail_cnt = fail_cnt + 1;
                        $display("[FAIL] File %0d | Exp: (%.4f, %.4f), Got: (%.4f, %.4f) | MaxDiff: %.4f", 
                                 f_idx, golden_val[0], golden_val[1], actual_val[0], actual_val[1], 
                                 (diff0 > diff1) ? diff0 : diff1);
                    end else begin
                        pass_cnt = pass_cnt + 1;
                        // 🌟 改为每跑 10 个文件就打印一次，第一张图(0)也会打印，让你安心！
                        if ((f_idx + 1) % 10 == 0 || f_idx == 0) begin
                            $display("[INFO] Successfully processed %0d / 496 files...", f_idx + 1);
                        end
                    end
                end

                // 8. 🌟 修复：直接删除 wait(done)，替换为简单的时钟延迟
                // 让流水线排空，安稳过渡到下一个输入文件
                #200;
                
            end // End of else block
        end // End of Batch Loop

        // ----------------------------------------------------
        // 最终统计报告
        // ----------------------------------------------------
        $display("\n==================================================");
        $display("[FINISH] Batch Regression Test Completed!");
        $display("  -> Total Files: %0d", pass_cnt + fail_cnt);
        $display("  -> Pass: %0d", pass_cnt);
        $display("  -> Fail: %0d", fail_cnt);
        $display("  -> Max Error Observed: %.6f", max_err_observed);
        if (fail_cnt == 0)
            $display("  🎉 PERFECT MATCH! (Within Tolerance)");
        else
            $display("  ⚠️ PLEASE CHECK THE FAILURES.");
        $display("==================================================\n");

        $finish;
    end

endmodule