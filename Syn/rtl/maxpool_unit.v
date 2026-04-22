`timescale 1ns / 1ps

module maxpool_unit (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 pool_start,  
    input  wire [255:0]         sram_rdata,  
    
    output reg  [6:0]           sram_raddr,
    output reg  [6:0]           sram_waddr,
    output wire [255:0]         sram_wdata,
    output reg                  sram_wen,    
    output reg                  pool_done
);

    reg [5:0] addr_cnt;     // 发送地址计数器
    reg [5:0] process_cnt;  // 接收数据计数器
    reg [3:0] out_cnt;      // 写回 SRAM 计数器
    reg       req_valid;
    reg       req_valid_d1;
    reg       req_valid_d2; // 延迟 2 拍，正好对齐 SRAM 的读出延迟
    reg       is_working;

    // 所有控制信号整合在唯一的 always 块中，彻底消灭多驱动！
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            addr_cnt     <= 0;
            process_cnt  <= 0;
            out_cnt      <= 0;
            is_working   <= 0;
            pool_done    <= 0;
            req_valid    <= 0;
            req_valid_d1 <= 0;
            req_valid_d2 <= 0;
            sram_wen     <= 1;
            sram_raddr   <= 0;
            sram_waddr   <= 0;
        end else begin
            pool_done    <= 0;
            sram_wen     <= 1;
            req_valid_d1 <= req_valid;
            req_valid_d2 <= req_valid_d1; // 打 2 拍，等待数据到达

            if (pool_start) begin
                is_working   <= 1;
                addr_cnt     <= 0;
                process_cnt  <= 0;
                out_cnt      <= 0;
                req_valid    <= 1;
            end else if (is_working) begin
                
                // 1. 发送读地址 (T+0)
                if (req_valid) begin
                    sram_raddr <= addr_cnt;
                    if (addr_cnt == 35) begin
                        req_valid <= 0; // 36个点发完，停止请求
                    end
                    addr_cnt <= addr_cnt + 1'b1;
                end
                
                // 2. 接收数据并处理写回 (T+2)
                if (req_valid_d2) begin
                    if (process_cnt % 4 == 3) begin
                        sram_wen   <= 0;
                        sram_waddr <= out_cnt;
                        if (out_cnt == 8) begin
                            pool_done  <= 1;  // 发送完成脉冲
                            is_working <= 0;  // 功德圆满，下班
                        end
                        out_cnt <= out_cnt + 1'b1;
                    end
                    process_cnt <= process_cnt + 1'b1;
                end
            end
        end
    end

    // 32通道并行比较器 (纯正流水线，不污染状态机)
    reg signed [7:0] max_reg [0:31];
    genvar g;
    generate
        for (g = 0; g < 32; g = g + 1) begin : gen_max
            wire signed [7:0] cur_data = sram_rdata[g*8 +: 8];
            assign sram_wdata[g*8 +: 8] = max_reg[g];
            
            always @(posedge clk) begin
                if (is_working && req_valid_d2) begin
                    if (process_cnt % 4 == 0) begin
                        max_reg[g] <= cur_data; // 第 1 个点直接覆盖
                    end else begin
                        if (cur_data > max_reg[g]) max_reg[g] <= cur_data; // 后面 3 个点取 Max
                    end
                end
            end
        end
    endgenerate

endmodule