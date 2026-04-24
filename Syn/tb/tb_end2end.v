`timescale 1ns / 1ps

module tb_end2end();
    localparam IN_SIZE  = 300;  
    localparam CONV1_OUT_SIZE = 2560; // 80 pixels * 32 channels
    localparam DW_OUT_SIZE    = 1152; // 36 pixels * 32 channels

    reg signed [7:0]  golden_conv1 [0:CONV1_OUT_SIZE-1];
    reg signed [7:0]  golden_dw    [0:DW_OUT_SIZE-1];
    
    reg signed [7:0]  actual_val;
    reg signed [7:0]  expected_val;

    reg clk;
    reg rst_n;
    reg start;

    cnn_top uut_cnn_top (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .ext_act_in(256'd0),
        .ext_act_valid(1'b0)
    );

    initial begin
        clk = 0;
        forever #5 clk = ~clk; 
    end

    integer fd_in, fd_out, code, i, j, c;
    integer err_conv1, err_dw;
    integer temp_val;
    
    reg [255:0] tb_input_mem [0:79];
    reg [255:0] val_256;

    initial begin
        // 🌟 1. 全局强制关闭硬件的 ReLU，我们要在 TB 里手动控制
        force uut_cnn_top.u_post_process.cur_relu = 1'b0;
        
        for (j = 0; j < 80; j = j + 1) tb_input_mem[j] = 256'd0;

        // ==========================================
        // 数据装载
        // ==========================================
        fd_in = $fopen("./data/Test/Input.txt", "r");
        for (j = 0; j < IN_SIZE; j = j + 1) begin
            code = $fscanf(fd_in, "%d", temp_val);
            tb_input_mem[j / 32][(j % 32) * 8 +: 8] = temp_val[7:0];
        end
        $fclose(fd_in);

        fd_out = $fopen("./data/Test/Out_Conv.txt", "r");
        for (i = 0; i < CONV1_OUT_SIZE; i = i + 1) code = $fscanf(fd_out, "%d", golden_conv1[i]);
        $fclose(fd_out);

        fd_out = $fopen("./data/Test/Out_DWConv.txt", "r");
        for (i = 0; i < DW_OUT_SIZE; i = i + 1) code = $fscanf(fd_out, "%d", golden_dw[i]);
        $fclose(fd_out);

        // ==========================================
        // 硬件复位与启动
        // ==========================================
        rst_n = 0;
        start = 0;
        #100;
        rst_n = 1;
        #20;

        // 写入原始图像
        for (j = 0; j < 10; j = j + 1) begin
            uut_cnn_top.u_sram_ping.u_sram_low.mem_array[j]  = tb_input_mem[j][127:0];
            uut_cnn_top.u_sram_ping.u_sram_high.mem_array[j] = tb_input_mem[j][255:128];
        end

        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        // ====================================================================
        // 🌟 阶段一：等待 Conv1 结束，时停冻结，全量比对
        // ====================================================================
        $display("\n[INFO] Running Conv1...");
        wait(uut_cnn_top.u_controller.current_state == 4'd2 && uut_cnn_top.u_controller.drain_cnt == 3'd5);
        
        // 【时停魔法】冻结状态机，但不冻结时钟，让最后几个数据的 SRAM 写操作安全落盘
        force uut_cnn_top.u_controller.current_state  = 4'd2; 
        force uut_cnn_top.u_controller.drain_cnt      = 3'd5;
        force uut_cnn_top.u_controller.is_prefetching = 1'b0; 
        repeat(10) @(posedge clk); 

        $display("\n==================================================");
        $display(" [VERIFY] Checking Conv1 Output (Pre-ReLU)");
        err_conv1 = 0;
        
        for (i = 0; i < 80; i = i + 1) begin
            val_256 = {uut_cnn_top.u_sram_pong.u_sram_high.mem_array[i], uut_cnn_top.u_sram_pong.u_sram_low.mem_array[i]};
            for (c = 0; c < 32; c = c + 1) begin
                actual_val = val_256[c*8 +: 8];
                expected_val = golden_conv1[c*80 + i]; // Channel-First 映射
                
                if (actual_val !== expected_val) begin
                    if (err_conv1 < 10) $display("   -> [Conv1 ERROR] Pixel %0d, Ch %0d | Exp: %0d, Got: %0d", i, c, expected_val, actual_val);
                    err_conv1 = err_conv1 + 1;
                end
            end
        end
        if (err_conv1 == 0) $display("   🎉 [PASS] Conv1 Layer is 100%% Correct!");
        else $display("   ❌ [FAIL] Conv1 Layer has %0d errors.", err_conv1);
        $display("==================================================\n");

        // ====================================================================
        // 🌟 阶段二：在 TB 中充当 Activation 1，对 SRAM Pong 执行就地 ReLU
        // ====================================================================
        $display("[INFO] Applying ReLU to SRAM Pong via Testbench...");
        for (i = 0; i < 80; i = i + 1) begin
            val_256 = {uut_cnn_top.u_sram_pong.u_sram_high.mem_array[i], uut_cnn_top.u_sram_pong.u_sram_low.mem_array[i]};
            for (c = 0; c < 32; c = c + 1) begin
                actual_val = val_256[c*8 +: 8];
                if (actual_val < 0) begin
                    val_256[c*8 +: 8] = 8'd0; // 负数截断为 0
                end
            end
            uut_cnn_top.u_sram_pong.u_sram_high.mem_array[i] = val_256[255:128];
            uut_cnn_top.u_sram_pong.u_sram_low.mem_array[i]  = val_256[127:0];
        end
        $display("[INFO] ReLU Applied. Ready for DWConv.\n");

        // ====================================================================
        // 🌟 阶段三：解除时停，让 DWConv 开始运行
        // ====================================================================
        // 提前设好 layer_mode 避免毛刺，然后解除劫持
        force uut_cnn_top.u_controller.layer_mode = 2'd1;
        @(posedge clk);
        release uut_cnn_top.u_controller.current_state;
        release uut_cnn_top.u_controller.drain_cnt;
        release uut_cnn_top.u_controller.is_prefetching;
        release uut_cnn_top.u_controller.layer_mode;

        $display("[INFO] Running DWConv...");
        wait(uut_cnn_top.u_controller.current_state == 4'd4 && uut_cnn_top.u_controller.drain_cnt == 3'd5);
        
        // 再次时停冻结，准备校验 DWConv
        force uut_cnn_top.u_controller.current_state = 4'd4;
        force uut_cnn_top.u_controller.drain_cnt     = 3'd5;
        repeat(10) @(posedge clk); 

        // ====================================================================
        // 🌟 阶段四：全量校验 DWConv
        // ====================================================================
        $display("\n==================================================");
        $display(" [VERIFY] Checking DWConv Output (Pre-ReLU)");
        err_dw = 0;
        
        for (i = 0; i < 36; i = i + 1) begin
            val_256 = {uut_cnn_top.u_sram_ping.u_sram_high.mem_array[i], uut_cnn_top.u_sram_ping.u_sram_low.mem_array[i]};
            for (c = 0; c < 32; c = c + 1) begin
                actual_val = val_256[c*8 +: 8];
                expected_val = golden_dw[c*36 + i]; 
                
                if (actual_val !== expected_val) begin
                    if (err_dw < 10) $display("   -> [DWConv ERROR] Pixel %0d, Ch %0d | Exp: %0d, Got: %0d", i, c, expected_val, actual_val);
                    err_dw = err_dw + 1;
                end
            end
        end
        
        if (err_dw == 0) $display("   🎉 [PASS] DWConv Layer is 100%% Correct!");
        else $display("   ❌ [FAIL] DWConv Layer has %0d errors.", err_dw);
        $display("==================================================\n");

        $finish;
    end
endmodule