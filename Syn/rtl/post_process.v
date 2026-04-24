`timescale 1ns / 1ps

module post_process (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 mac_valid,
    input  wire [1:0]           layer_mode,      
    input  wire [1023:0]        psum_in_flat,
    input  wire [511:0]         bias_in_flat,
    
    output reg                  out_valid,
    output reg  [255:0]         act_out_flat
);
    wire signed [31:0] psum_in [0:31];
    wire signed [15:0] bias_in [0:31];
    
    genvar g;
    generate
        for (g = 0; g < 32; g = g + 1) begin : unpack_loop
            assign psum_in[g] = psum_in_flat[g*32 +: 32];
            assign bias_in[g] = bias_in_flat[g*16 +: 16];
        end
    endgenerate

    reg                 stage1_valid;
    reg signed [47:0]   stage1_mult [0:31];
    reg [3:0]           stage1_quant_n;
    reg                 stage1_relu;

    reg signed [15:0] cur_M0;
    reg [3:0]         cur_n;
    reg               cur_relu;

    always @(*) begin
        case (layer_mode)
            // 🌟 核心修改 1：关闭 Conv1 的 ReLU (设为 1'b0)
            2'd0: begin cur_M0 = 16'd111; cur_n = 4'd14; cur_relu = 1'b1; end // Conv1
            2'd1: begin cur_M0 = 16'd59;  cur_n = 4'd11; cur_relu = 1'b1; end // DW
            2'd2: begin cur_M0 = 16'd69;  cur_n = 4'd13; cur_relu = 1'b1; end // PW
            2'd3: begin cur_M0 = 16'd11;  cur_n = 4'd15; cur_relu = 1'b0; end // FC
            default: begin cur_M0 = 16'd0; cur_n = 4'd0; cur_relu = 1'b0; end
        endcase
    end

    integer i;
    reg signed [32:0] psum_with_bias;
    reg signed [47:0] temp_shifted;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stage1_valid   <= 1'b0;
            out_valid      <= 1'b0;
            act_out_flat   <= 256'd0;
            stage1_quant_n <= 4'd0;
            stage1_relu    <= 1'b0;
            for (i = 0; i < 32; i = i + 1) begin
                stage1_mult[i] <= 48'sd0;
            end
        end else begin
            
            // 【Stage 1】: 加偏置并乘动态倍数
            stage1_valid <= mac_valid;
            if (mac_valid) begin
                stage1_quant_n <= cur_n;
                stage1_relu    <= cur_relu; 
                for (i = 0; i < 32; i = i + 1) begin
                    psum_with_bias = $signed(psum_in[i]) + $signed({{16{bias_in[i][15]}}, bias_in[i]});
                    stage1_mult[i] <= psum_with_bias * cur_M0;
                end
            end

            // 【Stage 2】: 算术右移，截断，条件 ReLU
            out_valid <= stage1_valid;
            if (stage1_valid) begin
                for (i = 0; i < 32; i = i + 1) begin
                    // 🌟 核心修改 2：去除所有四舍五入补偿，使用最纯粹的算术右移 (Floor)
                    temp_shifted = stage1_mult[i] >>> stage1_quant_n;

                    if (stage1_relu && temp_shifted < 0) begin
                        act_out_flat[i*8 +: 8] <= 8'd0;
                    end else if (temp_shifted > 127) begin
                        act_out_flat[i*8 +: 8] <= 8'd127;
                    end else if (temp_shifted < -128) begin
                        act_out_flat[i*8 +: 8] <= -8'sd128;
                    end else begin
                        act_out_flat[i*8 +: 8] <= temp_shifted[7:0];
                    end
                end
            end
        end
    end
endmodule