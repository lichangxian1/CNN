# 定义时钟：100MHz (周期 10ns)
create_clock -name clk -period 10.0 [get_ports clk]

# 设置输入/输出延迟 (示例)
set_input_delay -max 2.0 -clock clk [all_inputs]
set_output_delay -max 2.0 -clock clk [all_outputs]

# 设置时钟不确定性 (Clock Uncertainty)
set_clock_uncertainty 0.5 [get_clocks clk]