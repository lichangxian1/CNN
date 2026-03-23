`timescale 1ns / 1ps

module CNN_tb;

reg clk;
reg rst_n;
reg enable;
wire [63:0] data_out;
reg  [55:0] data_in;
wire        enable_out;
CNN_top uut(
    .clk(clk),
    .rst_n(rst_n),
    .enable(enable),
    .data_in(data_in),
    .data_out(data_out),
    .enable_out(enable_out)
);

initial begin
//初始化时钟信号
    clk = 0;
    forever #5 clk = ~clk;
end

integer i; //外层循环索引
integer fd;
integer fd_out;
integer j;
integer k;
integer data;
reg [55:0] data_in_reg;
reg [31:0] data1;
reg [31:0] data2;
reg [1023:0] input_path; //寄存器数组存储输入路径
reg [1023:0] output_path; //寄存器数组存储输出路径
initial begin
    //初始化复位和使能信号
    rst_n = 0;
    enable = 0;
    #10 rst_n = 1;
    
    //外层循环：496次迭代
    for (i = 0; i < 496; i = i + 1) begin
        //生成文件路径
        $sformat(input_path, "D:/work/Digtal_project/dataSet/In_processed/%0d_processed.txt", i);
        $sformat(output_path, "D:/work/Digtal_project/dataSet/tbOut/%0d.txt", i);
        //打开输入文件
        fd = $fopen(input_path, "r");
        if (fd == 0) begin
            $display("无法打开文件：%s", input_path);
            $stop;
        end
        //复位设计
        rst_n = 0;
        #10 rst_n = 1;
        enable = 0;
        //读取并驱动输入数据
        for (j = 0; j < 120; j = j + 1) begin
            for (k = 0; k < 7; k = k + 1) begin
                if ($fscanf(fd, "%d", data) != 1) begin
                    $display("无法读取数据，文件：%s，行：%0d", input_path, j+1);
                    $fclose(fd);
                    $stop;
                end
                data_in_reg[k*8 +: 8] = data;
            end
            @(posedge clk);
            enable <= 1;
            data_in <= data_in_reg;
        end
        
        $fclose(fd);

        //等待输出有效
        @(posedge enable_out);
        
        //打开输出文件并写入结果
        fd_out = $fopen(output_path, "w");
        if (fd_out == 0) begin
            $display("无法打开输出文件：%s", output_path);
            $stop;
        end
        
        @(posedge clk);
        data1 = data_out[31:0];
        @(posedge clk);
        data2 = data_out[63:32];
        $fwrite(fd_out, "%b %b\n", data1, data2);
        $fclose(fd_out);
        
        enable = 0;
        #100; //等待间隔
    end
    
    $display("所有456个文件处理完成！");
    $stop;
end

endmodule