module line_buffer_1ch #(
    parameter WORD_WIDTH = 32 // 每个SRAM word为32-bit (4个INT8)
)(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  shift_en,  // 移位使能：当SRAM读出有效新行时拉高
    input  wire [WORD_WIDTH-1:0] din,       // 来自SRAM的数据
    
    // 输出缓存的3行数据
    output reg  [WORD_WIDTH-1:0] line_row0, 
    output reg  [WORD_WIDTH-1:0] line_row1,
    output reg  [WORD_WIDTH-1:0] line_row2
);

    // 同步时序逻辑：实现向下移位
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            line_row0 <= {WORD_WIDTH{1'b0}};
            line_row1 <= {WORD_WIDTH{1'b0}};
            line_row2 <= {WORD_WIDTH{1'b0}};
        end else if (shift_en) begin
            // 新数据进入最底层，旧数据依次向上冒泡
            line_row2 <= din;
            line_row1 <= line_row2;
            line_row0 <= line_row1;
        end
    end

endmodule