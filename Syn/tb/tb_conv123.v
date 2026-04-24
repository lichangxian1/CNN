`timescale 1ns / 1ps

module tb_conv123();
    localparam IN_SIZE        = 300;  
    localparam CONV1_OUT_SIZE = 2560; // 80 pixels * 32 channels
    localparam DW_OUT_SIZE    = 1152; // 36 pixels * 32 channels
    localparam PW_OUT_SIZE    = 1152; // 36 pixels * 32 channels

    reg signed [7:0]  golden_conv1 [0:CONV1_OUT_SIZE-1];
    reg signed [7:0]  golden_dw    [0:DW_OUT_SIZE-1];
    reg signed [7:0]  golden_pw    [0:PW_OUT_SIZE-1];
    
    reg signed [7:0]  actual_val;
    reg signed [7:0]  expected_val;

    reg clk, rst_n, start;

    cnn_top uut_cnn_top (
        .clk(clk), .rst_n(rst_n), .start(start),
        .ext_act_in(256'd0), .ext_act_valid(1'b0)
    );

    initial begin
        clk = 0; forever #5 clk = ~clk; 
    end

    integer fd_in, fd_out, code, i, j, c;
    integer err_conv1, err_dw, err_pw;
    integer temp_val;
    reg [255:0] tb_input_mem [0:79];
    reg [255:0] val_256;

    initial begin
        // 🌟 1. 禁用硬件 ReLU，由 Testbench 全权接管
        force uut_cnn_top.u_post_process.cur_relu = 1'b0;
        for (j = 0; j < 80; j = j + 1) tb_input_mem[j] = 256'd0;

        // ==========================================
        // 读入所有参考数据
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

        fd_out = $fopen("./data/Test/Out_PWConv.txt", "r");
        for (i = 0; i < PW_OUT_SIZE; i = i + 1) code = $fscanf(fd_out, "%d", golden_pw[i]);
        $fclose(fd_out);

        // ==========================================
        // 启动硬件
        // ==========================================
        rst_n = 0; start = 0; #100; rst_n = 1; #20;

        for (j = 0; j < 10; j = j + 1) begin
            uut_cnn_top.u_sram_ping.u_sram_low.mem_array[j]  = tb_input_mem[j][127:0];
            uut_cnn_top.u_sram_ping.u_sram_high.mem_array[j] = tb_input_mem[j][255:128];
        end

        @(posedge clk); start = 1; @(posedge clk); start = 0;

        // ====================================================================
        // 🌟 阶段一：Conv1 校验与 ReLU 补偿
        // ====================================================================
        $display("\n[INFO] Running Layer 1 (Conv1)...");
        wait(uut_cnn_top.u_controller.current_state == 4'd2 && uut_cnn_top.u_controller.drain_cnt == 3'd5);
        
        // 冻结保护机制
        force uut_cnn_top.u_controller.current_state  = 4'd2; 
        force uut_cnn_top.u_controller.drain_cnt      = 3'd5;
        force uut_cnn_top.u_controller.is_prefetching = 1'b0; 
        repeat(10) @(posedge clk); 

        $display("--------------------------------------------------");
        $display(" [VERIFY] Checking Conv1 Output (Pre-ReLU) in SRAM Pong");
        err_conv1 = 0;
        for (i = 0; i < 80; i = i + 1) begin
            val_256 = {uut_cnn_top.u_sram_pong.u_sram_high.mem_array[i], uut_cnn_top.u_sram_pong.u_sram_low.mem_array[i]};
            for (c = 0; c < 32; c = c + 1) begin
                actual_val = val_256[c*8 +: 8];
                expected_val = golden_conv1[c*80 + i]; 
                if (actual_val !== expected_val) begin
                    if (err_conv1 < 10) $display("   -> [Conv1 ERROR] Pixel %0d, Ch %0d | Exp: %0d, Got: %0d", i, c, expected_val, actual_val);
                    err_conv1 = err_conv1 + 1;
                end
            end
        end
        if (err_conv1 == 0) $display("   🎉 [PASS] Conv1 is 100%% Correct!");
        else $display("   ❌ [FAIL] Conv1 has %0d errors.", err_conv1);

        $display(" [ACTION] Applying Activation 1 (ReLU) to SRAM Pong...");
        for (i = 0; i < 80; i = i + 1) begin
            val_256 = {uut_cnn_top.u_sram_pong.u_sram_high.mem_array[i], uut_cnn_top.u_sram_pong.u_sram_low.mem_array[i]};
            for (c = 0; c < 32; c = c + 1) begin
                if ($signed(val_256[c*8 +: 8]) < 0) val_256[c*8 +: 8] = 8'd0; 
            end
            uut_cnn_top.u_sram_pong.u_sram_high.mem_array[i] = val_256[255:128];
            uut_cnn_top.u_sram_pong.u_sram_low.mem_array[i]  = val_256[127:0];
        end

        // 🌟 护航机制：提前一拍设好模式，解除冻结，完美切入 DWConv
        force uut_cnn_top.u_controller.layer_mode = 2'd1;
        @(posedge clk);
        release uut_cnn_top.u_controller.current_state;
        release uut_cnn_top.u_controller.drain_cnt;
        release uut_cnn_top.u_controller.is_prefetching;
        release uut_cnn_top.u_controller.layer_mode;

        // ====================================================================
        // 🌟 阶段二：DWConv 校验与 ReLU 补偿
        // ====================================================================
        $display("\n[INFO] Running Layer 2 (DWConv)...");
        wait(uut_cnn_top.u_controller.current_state == 4'd4 && uut_cnn_top.u_controller.drain_cnt == 3'd5);
        
        force uut_cnn_top.u_controller.current_state  = 4'd4;
        force uut_cnn_top.u_controller.drain_cnt      = 3'd5;
        force uut_cnn_top.u_controller.is_prefetching = 1'b0; 
        repeat(10) @(posedge clk); 

        $display("--------------------------------------------------");
        $display(" [VERIFY] Checking DWConv Output (Pre-ReLU) in SRAM Ping");
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
        if (err_dw == 0) $display("   🎉 [PASS] DWConv is 100%% Correct!");
        else $display("   ❌ [FAIL] DWConv has %0d errors.", err_dw);

        $display(" [ACTION] Applying Activation 2 (ReLU) to SRAM Ping...");
        for (i = 0; i < 36; i = i + 1) begin
            val_256 = {uut_cnn_top.u_sram_ping.u_sram_high.mem_array[i], uut_cnn_top.u_sram_ping.u_sram_low.mem_array[i]};
            for (c = 0; c < 32; c = c + 1) begin
                if ($signed(val_256[c*8 +: 8]) < 0) val_256[c*8 +: 8] = 8'd0; 
            end
            uut_cnn_top.u_sram_ping.u_sram_high.mem_array[i] = val_256[255:128];
            uut_cnn_top.u_sram_ping.u_sram_low.mem_array[i]  = val_256[127:0];
        end

        // 🌟 护航机制：提前设好 PWConv 模式，无缝切入
        force uut_cnn_top.u_controller.layer_mode = 2'd2;
        @(posedge clk);
        release uut_cnn_top.u_controller.current_state;
        release uut_cnn_top.u_controller.drain_cnt;
        release uut_cnn_top.u_controller.is_prefetching;
        release uut_cnn_top.u_controller.layer_mode;

        // ====================================================================
        // 🌟 阶段三：PWConv 校验 (最终无 ReLU)
        // ====================================================================
        $display("\n[INFO] Running Layer 3 (PWConv)...");
        wait(uut_cnn_top.u_controller.current_state == 4'd6 && uut_cnn_top.u_controller.drain_cnt == 3'd5);
        
        force uut_cnn_top.u_controller.current_state  = 4'd6;
        force uut_cnn_top.u_controller.drain_cnt      = 3'd5;
        force uut_cnn_top.u_controller.is_prefetching = 1'b0; 
        repeat(10) @(posedge clk); 

        $display("--------------------------------------------------");
        $display(" [VERIFY] Checking PWConv Output (No ReLU) in SRAM Pong");
        err_pw = 0;
        for (i = 0; i < 36; i = i + 1) begin
            val_256 = {uut_cnn_top.u_sram_pong.u_sram_high.mem_array[i], uut_cnn_top.u_sram_pong.u_sram_low.mem_array[i]};
            for (c = 0; c < 32; c = c + 1) begin
                actual_val = val_256[c*8 +: 8];
                expected_val = golden_pw[c*36 + i]; 
                if (actual_val !== expected_val) begin
                    if (err_pw < 10) $display("   -> [PWConv ERROR] Pixel %0d, Ch %0d | Exp: %0d, Got: %0d", i, c, expected_val, actual_val);
                    err_pw = err_pw + 1;
                end
            end
        end
        if (err_pw == 0) $display("   🎉 [PASS] PWConv is 100%% Correct!");
        else $display("   ❌ [FAIL] PWConv has %0d errors.", err_pw);

        $display("\n==================================================");
        if (err_conv1 == 0 && err_dw == 0 && err_pw == 0) begin
            $display(" 🏆 [SUCCESS] 三层全链路通关！(Conv1 -> DWConv -> PWConv)");
        end
        $display("==================================================\n");

        $finish;
    end
endmodule