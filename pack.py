import os

def pack_codebase_to_md(root_dir, output_file="CNN.md", extensions=('.py', '.v', '.sdc', '.tcl')):
    """
    [Dr. Gemini] 自动化工程快照封盒工具 (V2 纯净版)
    用于将多文件 EDA 架构坍缩为单一 Markdown 文件，严格保留路径拓扑上下文，并剔除污染源。
    """
    # 目录级物理隔离：防止扫描无用缓存和输出结果
    ignore_dirs = {'outputs','report' ,'scripts' ,'work','tb','data','助教示例代码'}
    
    # 文件级物理隔离：防止脚本自我吞噬或引入无关测试干扰 AI 推理
    ignore_files = {'pack.py','mac_array_self_check_tb.v' ,'tb_mac_array.v'}

    with open(output_file, 'w', encoding='utf-8') as md_file:
        md_file.write("# CNN工程代码全局快照\n\n")
        md_file.write(f"**Root Directory:** `{os.path.abspath(root_dir)}`\n\n")

        file_count = 0
        for dirpath, dirnames, filenames in os.walk(root_dir):
            # 原地修改 dirnames 以剪枝忽略的目录
            dirnames[:] = [d for d in dirnames if d not in ignore_dirs]

            for file in filenames:
                # 触发文件级隔离屏障
                if file in ignore_files:
                    continue

                if file.endswith(extensions):
                    filepath = os.path.join(dirpath, file)
                    rel_path = os.path.relpath(filepath, root_dir)

                    md_file.write(f"### `{rel_path}`\n\n")

                    if file.endswith('.py'):
                        lang = "python"
                    elif file.endswith('.v') or file.endswith('.sv'):
                        lang = "verilog"
                    elif file.endswith('.sdc') or file.endswith('.tcl'):
                        lang = "tcl"
                    else:
                        lang = "text"

                    md_file.write(f"```{lang}\n")
                    try:
                        with open(filepath, 'r', encoding='utf-8') as f:
                            md_file.write(f.read())
                        file_count += 1
                        print(f" -> 已封印模块: {rel_path}")
                    except Exception as e:
                        md_file.write(f"// [Error] 解析失败: {str(e)}\n")
                        print(f" [!] 警告: 模块 {rel_path} 封印失败 ({str(e)})")
                    md_file.write("\n```\n\n")

    print("="*60)
    print(f" [打包完成] 共捕获 {file_count} 个核心源码文件。")
    print(f" 污染源 {ignore_files} 已被成功拦截。")
    print(f" 全局快照已安全坍缩至: {os.path.abspath(output_file)}")
    print("="*60)

if __name__ == "__main__":
    target_directory = "." 
    output_filename = "CNN.md"
    pack_codebase_to_md(target_directory, output_filename)