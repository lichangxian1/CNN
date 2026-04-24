`timescale 1ns / 1ps

module tb_conv123_fc();
    localparam PW_OUT_SIZE = 1152; 
    localparam FL_OUT_SIZE = 288;  // Flatten 向量长度

    reg signed [7:0]  golden_pw [0:PW_OUT_SIZE-1];
    reg signed [7:0]  golden_fl [0:FL_OUT_SIZE-1];
    reg signed [7:0]  actual_val, expected_val;

    reg clk, rst_n, start;

    cnn_top uut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .ext_act_in(256'd0), .ext_act_valid(1'b0)
    );

    initial begin
        clk = 0; forever #5 clk = ~clk; 
    end

    integer i, j, c, fd, code, err_pw, err_fl;
    reg [255:0] tb_input_mem [0:9];
    reg [255:0] val_256;
    
    // FC 结果寄存器
    reg [31:0] fc_out [0:1];

    initial begin
        // 1. 数据装载 (输入、PWConv、Flatten)
        fd = $fopen("./data/Test/Input.txt", "r");
        for (j = 0; j < 300; j = j + 1) begin
            integer tmp; code = $fscanf(fd, "%d", tmp);
            tb_input_mem[j / 32][(j % 32) * 8 +: 8] = tmp[7:0];
        end
        $fclose(fd);

        fd = $fopen("./data/Test/Out_PWConv.txt", "r");
        for (i = 0; i < PW_OUT_SIZE; i = i + 1) code = $fscanf(fd, "%d", golden_pw[i]);
        $fclose(fd);
        
        fd = $fopen("./data/Test/Out_Flatten.txt", "r");
        for (i = 0; i < FL_OUT_SIZE; i = i + 1) code = $fscanf(fd, "%d", golden_fl[i]);
        $fclose(fd);

        // 2. 硬件复位与启动
        rst_n = 0; start = 0; #100; rst_n = 1;
        #20;

        for (j = 0; j < 10; j = j + 1) begin
            uut.u_sram_ping.u_sram_low.mem_array[j]  = tb_input_mem[j][127:0];
            uut.u_sram_ping.u_sram_high.mem_array[j] = tb_input_mem[j][255:128];
        end

        @(posedge clk); start = 1; @(posedge clk);
        start = 0;

        $display("\n🚀 [Chip Start] System Running...");

        // =======================================================
        // 3. 校验 PWConv (作为中间锚点)
        // =======================================================
        wait(uut.u_controller.current_state == 4'd6 && uut.u_controller.drain_cnt == 3'd5);
        repeat(20) @(posedge clk); 

        $display("--------------------------------------------------");
        $display(" [VERIFY] Checking PWConv Output");
        err_pw = 0;
        for (i = 0; i < 36; i = i + 1) begin
            val_256 = {uut.u_sram_pong.u_sram_high.mem_array[i], uut.u_sram_pong.u_sram_low.mem_array[i]};
            for (c = 0; c < 32; c = c + 1) begin
                if (val_256[c*8 +: 8] !== golden_pw[c*36 + i]) err_pw = err_pw + 1;
            end
        end
        if (err_pw == 0) $display("   🎉 [PASS] PWConv is 100%% Correct!");
        else $display("   ❌ [FAIL] PWConv has %0d errors.", err_pw);

        // =======================================================
        // 4. 校验 Flatten 展平组装层
        // =======================================================
        // 等待 FSM 进入 ST_FC_CALC (状态 9)，此时行缓存正好组装完毕
        wait(uut.u_controller.current_state == 4'd9);
        @(posedge clk); // 延时一拍，确保组合逻辑已彻底稳定映射

        $display("--------------------------------------------------");
        $display(" [VERIFY] Checking Flatten Output in Line Buffer");
        err_fl = 0;
        for (i = 0; i < FL_OUT_SIZE; i = i + 1) begin
            actual_val = uut.u_line_buffer.act_in_flat[i*8 +: 8];
            expected_val = golden_fl[i];
            
            if (actual_val !== expected_val) begin
                if (err_fl < 20) $display("   -> [Flatten ERROR] Index %0d | Exp: %0d, Got: %0d", i, expected_val, actual_val);
                err_fl = err_fl + 1;
            end
        end
        if (err_fl == 0) $display("   🎉 [PASS] Flatten is 100%% Correct!");
        else $display("   ❌ [FAIL] Flatten has %0d errors.", err_fl);

        // =======================================================
        // 5. 捕获最终全连接和 Sigmoid 输出
        // =======================================================
        wait(uut.fc_valid); // FC 第一拍 valid
        fc_out[0] = uut.fc_result;
        
        @(posedge clk);     // FC 第二拍 valid
        fc_out[1] = uut.fc_result;

        $display("--------------------------------------------------");
        $display(" 🏆 [SUCCESS] Network Full Forward Pass Completed!");
        $display(" 🎯 [Neuron 0] Output (FP32 Hex): %h", fc_out[0]);
        $display(" 🎯 [Neuron 1] Output (FP32 Hex): %h", fc_out[1]);
        $display("==================================================\n");

        $finish;
    end
endmodule