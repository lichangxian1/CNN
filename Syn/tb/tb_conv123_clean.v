`timescale 1ns / 1ps

module tb_conv123_clean();
    localparam IN_SIZE     = 300;  
    localparam PW_OUT_SIZE = 1152; // 36 pixels * 32 channels

    reg signed [7:0]  golden_pw [0:PW_OUT_SIZE-1];
    reg signed [7:0]  actual_val, expected_val;

    reg clk, rst_n, start;

    cnn_top uut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .ext_act_in(256'd0), .ext_act_valid(1'b0)
    );

    initial begin
        clk = 0; forever #5 clk = ~clk; 
    end

    integer i, j, c, fd, code, err_pw;
    reg [255:0] tb_input_mem [0:9];
    reg [255:0] val_256;

    initial begin
        // 1. 数据与参考答案装载
        fd = $fopen("./data/Test/Input.txt", "r");
        for (j = 0; j < 300; j = j + 1) begin
            integer tmp; code = $fscanf(fd, "%d", tmp);
            tb_input_mem[j / 32][(j % 32) * 8 +: 8] = tmp[7:0];
        end
        $fclose(fd);

        fd = $fopen("./data/Test/Out_PWConv.txt", "r");
        for (i = 0; i < PW_OUT_SIZE; i = i + 1) code = $fscanf(fd, "%d", golden_pw[i]);
        $fclose(fd);

        // 2. 硬件复位与系统启动
        rst_n = 0; start = 0; #100; rst_n = 1; #20;

        for (j = 0; j < 10; j = j + 1) begin
            uut.u_sram_ping.u_sram_low.mem_array[j]  = tb_input_mem[j][127:0];
            uut.u_sram_ping.u_sram_high.mem_array[j] = tb_input_mem[j][255:128];
        end

        @(posedge clk); start = 1; @(posedge clk); start = 0;

        $display("\n🚀 [Chip Start] ...");

        // 3. 彻底放手，挂机等待硬件原生跑完三层
        // 静静等待 FSM 进入池化层的排空状态
        wait(uut.u_controller.current_state == 4'd6 && uut.u_controller.drain_cnt == 3'd5);
        repeat(20) @(posedge clk); 

        // 4. 终极检阅：全量校验 PWConv 输出
        $display("--------------------------------------------------");
        $display(" [VERIFY] Checking PWConv Output (No ReLU) in SRAM Pong");
        err_pw = 0;
        
        for (i = 0; i < 36; i = i + 1) begin
            val_256 = {uut.u_sram_pong.u_sram_high.mem_array[i], uut.u_sram_pong.u_sram_low.mem_array[i]};
            for (c = 0; c < 32; c = c + 1) begin
                actual_val = val_256[c*8 +: 8];
                expected_val = golden_pw[c*36 + i]; 
                
                if (actual_val !== expected_val) begin
                    if (err_pw < 20) $display("   -> [PWConv ERROR] Pixel %0d, Ch %0d | Exp: %0d, Got: %0d", i, c, expected_val, actual_val);
                    err_pw = err_pw + 1;
                end
            end
        end
        
        if (err_pw == 0) $display("   🎉 [PASS] PWConv is 100%% Correct!");
        else $display("   ❌ [FAIL] PWConv has %0d errors.", err_pw);

        $display("\n==================================================");
        if (err_pw == 0) $display(" 🏆 [SUCCESS] 前三层卷积全链路完美贯通！");
        $display("==================================================\n");

        $finish;
    end
endmodule