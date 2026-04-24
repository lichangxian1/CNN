`timescale 1ns / 1ps

module tb_fc_linear();
    localparam FC_OUT_SIZE = 2; // Fully Connected layer: 2 neurons

    reg signed [7:0] golden_linear [0:FC_OUT_SIZE-1];
    reg signed [7:0] actual_linear [0:FC_OUT_SIZE-1];

    reg clk, rst_n, start;
    wire done;

    // Instantiate top module
    cnn_top uut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .ext_act_in(256'd0), .ext_act_valid(1'b0),
        .done(done)
    );

    initial begin
        clk = 0; forever #5 clk = ~clk; 
    end

    integer i, j, fd, code, err_fc, fc_cnt, wait_cnt;
    reg [255:0] tb_input_mem [0:9];

    initial begin
        // 1. Load Data (Input map and FC golden answers)
        fd = $fopen("./data/Test/Input.txt", "r");
        for (j = 0; j < 300; j = j + 1) begin
            integer tmp; code = $fscanf(fd, "%d", tmp);
            tb_input_mem[j / 32][(j % 32) * 8 +: 8] = tmp[7:0];
        end
        $fclose(fd);

        fd = $fopen("./data/Test/Out_Linear.txt", "r");
        if (fd == 0) $display("❌ [ERROR] Cannot find Out_Linear.txt!");
        for (i = 0; i < FC_OUT_SIZE; i = i + 1) code = $fscanf(fd, "%d", golden_linear[i]);
        $fclose(fd);

        // 2. Hardware Reset and System Start
        rst_n = 0; start = 0; #100; rst_n = 1; #20;

        // Move data to the initial SRAM (Ping)
        for (j = 0; j < 10; j = j + 1) begin
            uut.u_sram_ping.u_sram_low.mem_array[j]  = tb_input_mem[j][127:0];
            uut.u_sram_ping.u_sram_high.mem_array[j] = tb_input_mem[j][255:128];
        end

        @(posedge clk); start = 1; @(posedge clk); start = 0;

        $display("\n🚀 [FC Verify] Starting full pipeline computation...");

        // 3. Real-time Comparison: Intercept FC layer linear output (Quantized INT8)
        fc_cnt   = 0;
        err_fc   = 0;
        wait_cnt = 0;
        
        // Continue monitoring until both FC results are received
        while (fc_cnt < 2) begin
            @(posedge clk);
            
            // 🌟 核心修改：使用 uut.layer_mode_sync (T+4)，它与 out_valid 的时序完美对齐！
            if (uut.u_post_process.out_valid && uut.layer_mode_sync == 2'd3) begin
                actual_linear[fc_cnt] = uut.u_post_process.act_out_flat[7:0]; 
                $display("   -> [FC INFO] Neuron %0d | Exp: %0d, Got: %0d", 
                         fc_cnt, golden_linear[fc_cnt], actual_linear[fc_cnt]);
                
                if (actual_linear[fc_cnt] !== golden_linear[fc_cnt]) begin
                    err_fc = err_fc + 1;
                end
                fc_cnt = fc_cnt + 1;
            end
            
            // 🌟 核心修改：移除 done 判断，改为 500 拍的弹性等待周期
            wait_cnt = wait_cnt + 1;
            if (wait_cnt > 100000) begin 
                $display("❌ [ERROR] Timeout! Pipeline did not output FC results.");
                $finish;
            end
        end

        // 4. Final Verification
        $display("--------------------------------------------------");
        if (err_fc == 0) $display("   🎉 [PASS] FC layer linear output is 100%% Correct!");
        else $display("   ❌ [FAIL] FC layer has %0d value errors.", err_fc);
        $display("==================================================\n");

        $finish;
    end
endmodule