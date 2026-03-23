注意事项：
1.代码包含详细中文注释，修改时建议在支持中文的编辑器中修改，直接导入仿真软件可能无法查看中文注释；
2.代码不包含testbench文件，需自行编写及验证。

代码包结构如下：
顶层
- `CNN_top.v`：系统顶层模块
卷积计算单元
- `SA1.v` / `SA1_channel.v`：第一层常规卷积
- `SA_2.v` / `SA_channel_2.v`：第二层深度可分离卷积
- `SA_3.v` / `SA_channel_3.v`：第三层逐点卷积
- `PE.v`：脉动阵列基本处理单元
数据缓存与存储
- `sramBuffer1.v`：第一缓存层，由多个SRAM和移位寄存器构成
- `BUFFER_2.v`：第二缓存层，简单的256位寄存器
- `SRAM_32_256.v`：256位宽32深度单口SRAM封装
- `S018V3EBCDSP_X8Y4D128_PR.v`：工艺库提供的128位SRAM宏单元模型
池化与全连接
- `maxpool_v2.v`：最大池化层，两周期输出一个池化结果
- `FC.v`：全连接层顶层，包含32个`FC_PE`
- `FC_PE.v`：全连接层处理单元
激活与重量化
- `relu.v`：ReLU激活层
- `rescale_conv.v` / `rescale_dwconv.v` / `rescale_pwconv.v` / `rescale_linear.v`：分别为各层专用的重量化模块
- `SigLUT.v`：Sigmoid查找表
基本时序单元
- `FF_8.v` / `FF_32.v`：8位/32位D触发器，用于流水线寄存器