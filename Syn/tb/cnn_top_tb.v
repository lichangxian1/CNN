`timescale 1ns / 1ps

// ==========================================================================
// 模块名称: cnn_top_tb (全链路批量验证平台 - Icarus 完美兼容十进制版)
// ==========================================================================

module cnn_top_tb();

    reg          clk;
    reg          rst_n;
    reg          start;
    
    reg  [255:0] ext_act_in;
    reg          ext_act_valid;
    wire         done;
    wire [31:0]  fc_result;
    wire         fc_valid;

    cnn_top uut_cnn_top (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (start),
        .ext_act_in     (ext_act_in),
        .ext_act_valid  (ext_act_valid),
        .done           (done),
        .fc_result      (fc_result),
        .fc_valid       (fc_valid)
    );

    initial clk = 0;
    always #5 clk = ~clk; 

    // =========================================================
    // IEEE 754 转换为 real 的函数 (绕开 Icarus 限制)
    // =========================================================
    function real bits2real;
        input [31:0] bits;
        reg sign;
        reg [7:0] exp;
        reg [22:0] frac;
        real fraction_real;
        real result;
        begin
            sign = bits[31];
            exp  = bits[30:23];
            frac = bits[22:0];

            if (exp == 0 && frac == 0) begin
                result = 0.0;
            end else begin
                fraction_real = 1.0 + (frac / 8388608.0);
                result = fraction_real * (2.0 ** (exp - 127.0));
                if (sign) result = -result;
            end
            bits2real = result;
        end
    endfunction

    // 文件操作变量
    string file_in_name;
    string file_out_name;
    integer fd_in, fd_out, code;
    
    // 暂存数据的内存
    reg [255:0] tb_input_mem [0:79];  
    integer temp_val;
    
    // 比较用的浮点变量
    reg [31:0]  actual_fc_out [0:1];
    real golden_val_0, golden_val_1;
    real actual_val_0, actual_val_1;
    real abs_error_0, abs_error_1;
    real ERROR_THRESHOLD = 0.05; 
    
    integer test_idx, j, fc_cnt, timeout_cnt;
    integer pass_count = 0;
    integer fail_count = 0;

    initial begin
        rst_n         = 0;
        start         = 0;
        ext_act_in    = 0;
        ext_act_valid = 0;
        
        #100;
        rst_n = 1; 
        #20;
        
        $display("==================================================");
        $display(" [Auto-Test] Starting Batch Verification for 496 Cases...");
        $display("==================================================");

        for (test_idx = 0; test_idx < 496; test_idx = test_idx + 1) begin
            
            // 生成相对路径
            $sformat(file_in_name, "./data/In/%0d.txt", test_idx);
            $sformat(file_out_name, "./data/Out/%0d.txt", test_idx);
            
            // ---------------------------------------------------------
            // 1. 读取带有负号的十进制文本输入 (30x10 = 300个像素)
            // ---------------------------------------------------------
            fd_in = $fopen(file_in_name, "r");
            if (fd_in == 0) begin
                $display("ERROR: Cannot open %s", file_in_name);
                $finish;
            end
            
            for (j = 0; j < 80; j = j + 1) tb_input_mem[j] = 256'd0; // 清空数组
            
            for (j = 0; j < 300; j = j + 1) begin
                code = $fscanf(fd_in, "%d", temp_val);
                // 巧妙地将读出的 8-bit 有符号数拼接拼入 256-bit SRAM 对应的字节位置
                tb_input_mem[j/32] = tb_input_mem[j/32] | ({248'd0, temp_val[7:0]} << ((j%32)*8));
            end
            $fclose(fd_in);
            
            // 将拼装好的数据灌入底层物理 SRAM
            for (j = 0; j < 80; j = j + 1) begin
                uut_cnn_top.u_sram_ping.u_sram_low.mem_array[j]  = tb_input_mem[j][127:0];
                uut_cnn_top.u_sram_ping.u_sram_high.mem_array[j] = tb_input_mem[j][255:128];
            end
            
            // ---------------------------------------------------------
            // 2. 读取明文的小数标准答案
            // ---------------------------------------------------------
            fd_out = $fopen(file_out_name, "r");
            if (fd_out == 0) begin
                $display("ERROR: Cannot open %s", file_out_name);
                $finish;
            end
            code = $fscanf(fd_out, "%f", golden_val_0);
            code = $fscanf(fd_out, "%f", golden_val_1);
            $fclose(fd_out);
            
            // ---------------------------------------------------------
            // 3. 触发芯片运算
            // ---------------------------------------------------------
            @(posedge clk);
            start = 1;
            @(posedge clk);
            start = 0;
            
            fc_cnt = 0;
            timeout_cnt = 0;
            actual_fc_out[0] = 32'd0;
            actual_fc_out[1] = 32'd0;
            
            // 抓取 2 个输出 (加入超时防抱死机制)
            while ((fc_cnt < 2) && (timeout_cnt < 10000)) begin
                @(posedge clk);
                if (fc_valid) begin
                    actual_fc_out[fc_cnt] = fc_result;
                    fc_cnt = fc_cnt + 1;
                end
                timeout_cnt = timeout_cnt + 1;
            end
            
            // 等待状态机复位
            // wait(done == 1'b1);
            repeat(20) @(posedge clk);
            // ---------------------------------------------------------
            // 4. 浮点误差计算与判定
            // ---------------------------------------------------------
            if (fc_cnt == 2) begin
                actual_val_0 = bits2real(actual_fc_out[0]);
                abs_error_0  = actual_val_0 - golden_val_0;
                if (abs_error_0 < 0) abs_error_0 = -abs_error_0; 
                
                actual_val_1 = bits2real(actual_fc_out[1]);
                abs_error_1  = actual_val_1 - golden_val_1;
                if (abs_error_1 < 0) abs_error_1 = -abs_error_1; 
                
                if ((abs_error_0 > ERROR_THRESHOLD) || (abs_error_1 > ERROR_THRESHOLD)) begin
                    $display("[FAIL] Case %0d | Exp: (%.4f, %.4f) | Got: (%.4f, %.4f)", 
                              test_idx, golden_val_0, golden_val_1, actual_val_0, actual_val_1);
                    fail_count = fail_count + 1;
                end else begin
                    pass_count = pass_count + 1;
                end
            end else begin
                $display("[TIMEOUT] Case %0d | Did not get 2 valid outputs in 10000 cycles!", test_idx);
                fail_count = fail_count + 1;
            end
        end
        
        // ---------------------------------------------------------
        // 5. 打印报表
        // ---------------------------------------------------------
        $display("==================================================");
        $display(" [Auto-Test] Verification Completed!");
        $display("   Total Cases : %0d", 496);
        $display("   Passed      : %0d", pass_count);
        $display("   Failed      : %0d", fail_count);
        $display("   Accuracy    : %0.2f %%", (pass_count * 100.0) / 496);
        $display("==================================================");
        
        #100;
        $finish;
    end

endmodule