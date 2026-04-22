# ==========================================================================
# 华大九天 ZenSyn 逻辑综合脚本 (基于 CNN 加速器项目)
# ==========================================================================

# 1. 设置搜索路径
set search_path "$search_path ../rtl ../scripts ../../../../SMIC18/lib ../../../../SMIC18/mem ../work"

# 2. 指定目标工艺库和链接优先级
set target_lib "slow.lib S018V3EBCDSP_X20Y4D128_PR_tt_1.8_25.lib SP018W_V1p8_max.lib"
set link_priority "* slow S018V3EBCDSP_X20Y4D128_PR_tt_1.8_25 SP018W_V1p8_max"
# 3. 读取设计文件
read_design -format verilog {
    ../rtl/sram_256x80.v
    ../rtl/SigLUT.v
    ../rtl/param_rom.v
    ../rtl/mac_array.v
    ../rtl/post_process.v
    ../rtl/output_staging_buffer.v
    ../rtl/maxpool_unit.v
    ../rtl/line_buffer.v
    ../rtl/cnn_controller.v
    ../rtl/cnn_top.v
    ../rtl/cnn_chip.v
}

# 4. 指定顶层模块并建立链接
set current_design cnn_chip
link_design
make_unique

# 5. 导入时序约束文件
source ../scripts/cnn.sdc

# 6. 执行综合优化
optimize

# 7. 生成分析报告 
analyze_constraint -all_violators > ../reports/violators_cnn.rpt
analyze_area > ../reports/area_cnn.rpt
analyze_timing > ../reports/timing_cnn.rpt

# 8. 导出结果文件 
write_design -format verilog -hierarchy -o ../outputs/cnn_chip_syn.v
write_sdc ../outputs/cnn_chip_syn.sdc

exit