`timescale 1ns / 1ps

module mac_array_self_check_tb();

    // ---------------------------------------------------------
    // 信号定义
    // ---------------------------------------------------------
    reg                 clk;
    reg                 rst_n;
    reg  [1:0]          layer_mode;
    reg  [2463:0]       act_in_flat;
    reg  [2463:0]       wgt_in_flat;
    wire [1023:0]       psum_out_flat;

    // 统计变量
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // ---------------------------------------------------------
    // 模块例化
    // ---------------------------------------------------------
    mac_array uut (
        .clk(clk), .rst_n(rst_n), .layer_mode(layer_mode),
        .act_in_flat(act_in_flat), .wgt_in_flat(wgt_in_flat),
        .psum_out_flat(psum_out_flat)
    );

    // 时钟生成
    initial clk = 0;
    always #5 clk = ~clk;

    // ---------------------------------------------------------
    // 自动化验证任务 (Tasks)
    // ---------------------------------------------------------
    
    // 核心比对任务：自动等待 2 拍流水线后检查结果
    task verify_result(input [127:0] test_name, input integer num_outputs);
        integer i;
        reg signed [31:0] expected_psum [0:31];
        reg signed [31:0] actual_psum;
        begin
            // 1. 自动计算 Golden Reference (由于是 TB，这里用循环计算模拟硬件逻辑)
            for(i=0; i<32; i=i+1) expected_psum[i] = 32'sd0;
            
            case(layer_mode)
                2'd0: begin // Conv1: 4组，每组77 
                    for(i=0; i<4; i=i+1) begin
                        for(integer j=0; j<77; j=j+1)
                            expected_psum[i] = expected_psum[i] + $signed(act_in_flat[(i*77+j)*8 +: 8]) * $signed(wgt_in_flat[(i*77+j)*8 +: 8]);
                    end
                end
                2'd1: begin // DW: 32组，每组9 
                    for(i=0; i<32; i=i+1) begin
                        for(integer j=0; j<9; j=j+1)
                            expected_psum[i] = expected_psum[i] + $signed(act_in_flat[(i*9+j)*8 +: 8]) * $signed(wgt_in_flat[(i*9+j)*8 +: 8]);
                    end
                end
                2'd2: begin // PW: 8组，每组32 
                    for(i=0; i<8; i=i+1) begin
                        for(integer j=0; j<32; j=j+1)
                            expected_psum[i] = expected_psum[i] + $signed(act_in_flat[(i*32+j)*8 +: 8]) * $signed(wgt_in_flat[(i*32+j)*8 +: 8]);
                    end
                end
            endcase

            // 2. 等待硬件流水线完成 (2拍延迟)
            repeat(2) @(posedge clk);
            #1; // 避开采样边沿

            // 3. 逐一比对
            for(i=0; i<num_outputs; i=i+1) begin
                actual_psum = $signed(psum_out_flat[i*32 +: 32]);
                if (actual_psum !== expected_psum[i]) begin
                    $display("[FAILED] %s | Ch:%0d | Exp:%d | Got:%d", test_name, i, expected_psum[i], actual_psum);
                    fail_cnt = fail_cnt + 1;
                end else begin
                    pass_cnt = pass_cnt + 1;
                end
            end
        end
    endtask

    // ---------------------------------------------------------
    // 测试流程
    // ---------------------------------------------------------
    initial begin
        // 初始化
        rst_n = 0; layer_mode = 0; act_in_flat = 0; wgt_in_flat = 0;
        #20 rst_n = 1;

        $display("======= Starting Automated MAC Array Verification =======");

        // --- TEST 1: Conv1 模式下的全 1 测试 ---
        layer_mode = 2'b00;
        act_in_flat = {308{8'sd1}};  // 输入全为 1
        wgt_in_flat = {308{8'sd1}};  // 权重全为 1
        verify_result("Conv1_All_Ones", 4);

        // --- TEST 2: DW 模式下的随机负数测试 ---
        layer_mode = 2'b01;
        for(integer k=0; k<308; k=k+1) begin
            act_in_flat[k*8 +: 8] = $random % 128;
            wgt_in_flat[k*8 +: 8] = -8'sd1; // 权重固定为 -1，测试负数累加
        end
        verify_result("DW_Negative_Wgt", 32);

        // --- TEST 3: PW 模式下的极端边界测试 ---
        layer_mode = 2'b10;
        for(integer k=0; k<308; k=k+1) begin
            act_in_flat[k*8 +: 8] = 8'sd127; // 最大正数
            wgt_in_flat[k*8 +: 8] = 8'sd127; // 最大正数
        end
        verify_result("PW_Max_Boundary", 8);

        // --- 最终总结 ---
        $display("---------------------------------------------------------");
        $display("Verification Report:");
        $display("Total Sub-checks Passed: %0d", pass_cnt);
        $display("Total Sub-checks Failed: %0d", fail_cnt);
        
        if (fail_cnt == 0) 
            $display("[SUCCESS] All tests passed! You are ready for the next layer.");
        else 
            $display("[CRITICAL] Found %0d errors. Please check your adder tree logic.", fail_cnt);
        $display("---------------------------------------------------------");
        
        $finish;
    end

endmodule