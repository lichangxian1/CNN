`timescale 1ns / 1ps

// ==========================================================================
// 模块名称: cnn_chip (带 IO Pad 封装的真实流片顶层)
// 结构说明: 
//   外围使用 PIW (输入Pad) 和 PO8W (输出Pad) 将内部核心逻辑的信号引出。
// ==========================================================================

module cnn_chip(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 start,
    input  wire [255:0]         ext_act_in,     // 256-bit 数据输入
    input  wire                 ext_act_valid,
    
    output wire                 done,
    output wire [31:0]          fc_result,      // 32-bit 计算结果输出
    output wire                 fc_valid
);

    // ==========================================
    // 内部连线 (Net) 声明
    // ==========================================
    wire                 net_clk;
    wire                 net_rst_n;
    wire                 net_start;
    wire [255:0]         net_ext_act_in;
    wire                 net_ext_act_valid;
    
    wire                 net_done;
    wire [31:0]          net_fc_result;
    wire                 net_fc_valid;

    // ==========================================
    // 输入管脚 (Input Pads - PIW) 例化
    // ==========================================
    // 单比特控制信号
    PIW PIW_clk           (.PAD(clk),           .C(net_clk));
    PIW PIW_rst_n         (.PAD(rst_n),         .C(net_rst_n));
    PIW PIW_start         (.PAD(start),         .C(net_start));
    PIW PIW_ext_act_valid (.PAD(ext_act_valid), .C(net_ext_act_valid));

    // 256位数据总线批量例化 (等效于助教手写 256 行 PIW_dinX)
    genvar i;
    generate
        for (i = 0; i < 256; i = i + 1) begin : gen_piw_ext_act_in
            PIW PIW_ext_act_in_inst (
                .PAD (ext_act_in[i]), 
                .C   (net_ext_act_in[i])
            );
        end
    endgenerate

    // ==========================================
    // 输出管脚 (Output Pads - PO8W) 例化
    // ==========================================
    // 单比特控制信号
    PO8W PO8W_done        (.I(net_done),        .PAD(done));
    PO8W PO8W_fc_valid    (.I(net_fc_valid),    .PAD(fc_valid));

    // 32位数据总线批量例化 (等效于助教手写 32 行 PO8W_doutX)
    genvar j;
    generate
        for (j = 0; j < 32; j = j + 1) begin : gen_po8w_fc_result
            PO8W PO8W_fc_result_inst (
                .I   (net_fc_result[j]), 
                .PAD (fc_result[j])
            );
        end
    endgenerate

    // ==========================================
    // 核心算法模块 (Core) 例化
    // ==========================================
    cnn_top inst_CNN_top (
        .clk            (net_clk),
        .rst_n          (net_rst_n),
        .start          (net_start),
        .ext_act_in     (net_ext_act_in),
        .ext_act_valid  (net_ext_act_valid),
        .done           (net_done),
        .fc_result      (net_fc_result),
        .fc_valid       (net_fc_valid)
    );

endmodule