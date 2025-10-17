import glob
import os
import re
import subprocess
import json
import hashlib

# --- 请在这里修改您的文件夹路径 ---
# 使用 r"..." 格式可以防止路径中的反斜杠被错误地转义，特别是在 Windows 上。
# 示例 (Windows):
ROOT_DIRECTORY = r"D:\WorkSpace\31-FlowerPig\open_meta_mathematical_theory"
INPUT_DIRECTORY = f"{ROOT_DIRECTORY}\src\kernel_reference"
OUTPUT_DIRECTORY = f"{ROOT_DIRECTORY}\src\kernel_reference_pdf"


# 示例 (macOS / Linux):
# INPUT_DIRECTORY = r"/Users/your_username/documents/notes"
# OUTPUT_DIRECTORY = r"/Users/your_username/documents/pdf_exports"
# ------------------------------------

def _sha256_of_file(path):
    """
    计算文件的 SHA256 哈希值（十六进制字符串）。
    如果文件不存在，返回 None。
    """
    if not os.path.exists(path) or not os.path.isfile(path):
        return None
    h = hashlib.sha256()
    # 以较小块读取避免占用过多内存
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def _load_hash_map(json_path):
    """从给定路径加载哈希映射 JSON，文件不存在则返回空字典。"""
    if not os.path.exists(json_path):
        return {}
    try:
        with open(json_path, 'r', encoding='utf-8') as f:
            data = json.load(f)
            # 必须是 dict
            return data if isinstance(data, dict) else {}
    except Exception:
        # JSON 损坏等情况，返回空，避免崩溃
        return {}


def _save_hash_map(json_path, data):
    """将哈希映射保存为 JSON（UTF-8，带缩进）。"""
    # 确保输出目录存在
    os.makedirs(os.path.dirname(json_path), exist_ok=True)
    with open(json_path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def _to_rel_under_root(path):
    """将给定路径转换为相对于 ROOT_DIRECTORY 的相对路径。"""
    try:
        return os.path.relpath(path, ROOT_DIRECTORY)
    except Exception:
        # 理论上不会发生（INPUT/OUTPUT 都在 ROOT 下），保底返回原值
        return path


def _sanitize_paths_in_hash_map(data, root_dir):
    """将映射中的 md_path/pdf_path 统一转换为相对于 root_dir 的相对路径。"""
    if not isinstance(data, dict):
        return data
    sanitized = {}
    for k, v in data.items():
        if isinstance(v, dict):
            entry = dict(v)
            for key in ("md_path", "pdf_path"):
                p = entry.get(key)
                if isinstance(p, str):
                    try:
                        if os.path.isabs(p):
                            entry[key] = os.path.relpath(p, root_dir)
                        else:
                            # 已经是相对路径则保持
                            entry[key] = p
                    except Exception:
                        # 出现异常则保持原值
                        entry[key] = p
            sanitized[k] = entry
        else:
            sanitized[k] = v
    return sanitized

def batch_convert_md_to_pdf(input_dir, output_dir):
    """
    查找指定输入目录下的所有 Markdown 文件，并将它们转换为 PDF 存放到指定的输出目录。
    会跳过以 "数字_.md" 格式命名的文件，以及在输出目录中已存在的同名 PDF 文件。
    """
    # 检查输入目录是否存在
    if not os.path.isdir(input_dir):
        print(f"错误: 输入目录 '{input_dir}' 不存在或不是一个有效的目录。")
        return

    # 如果输出目录不存在，则创建它
    if not os.path.exists(output_dir):
        os.makedirs(output_dir)
        print(f"已创建输出目录: '{output_dir}'")

    # 使用 glob 查找输入目录下的所有 .md 文件 (包括子目录)
    search_pattern = os.path.join(input_dir, '**', '*.md')
    markdown_files = glob.glob(search_pattern, recursive=True)

    if not markdown_files:
        print(f"在目录 '{input_dir}' 中未找到任何 Markdown 文件。")
        return

    print(f"找到了 {len(markdown_files)} 个 Markdown 文件，开始处理...")

    # 获取 Node.js 脚本的路径 (假设它和 python 脚本在同一目录)
    script_dir = os.path.dirname(os.path.abspath(__file__))
    node_script_path = os.path.join(script_dir, 'convert.js')

    if not os.path.exists(node_script_path):
        print(f"错误: 未找到转换脚本 'convert.js'。请确保它和 Python 脚本在同一目录下。")
        return

    # 定义要跳过的文件名的正则表达式模式
    skip_pattern = re.compile(r'^\d+_\.md$')

    # 哈希映射 JSON 文件路径（保存在输出目录）
    hash_map_path = os.path.join(output_dir, '_hash_map.json')
    hash_map = _load_hash_map(hash_map_path)

    for md_file in markdown_files:
        # 获取纯文件名，用于规则判断
        filename = os.path.basename(md_file)

        # 规则1: 如果文件名匹配我们定义的跳过规则
        if skip_pattern.match(filename):
            print(f"\n--- SKIPPING (规则匹配): {filename} ---")
            continue  # 跳过当前文件，继续下一个

        # <--- 哈希映射与变更检测开始 --->
        # 1. 获取文件名（不含扩展名），并构建出目标 PDF 文件名
        pdf_filename = os.path.splitext(filename)[0] + '.pdf'
        # 2. 构建出目标 PDF 文件在输出目录中的完整路径
        expected_pdf_path = os.path.join(output_dir, pdf_filename)

        # 计算当前哈希并打印校对信息
        pdf_exists = os.path.exists(expected_pdf_path)
        current_pdf_hash = _sha256_of_file(expected_pdf_path) if pdf_exists else None
        current_md_hash = _sha256_of_file(md_file)

        # 从映射中取出历史记录
        entry = hash_map.get(pdf_filename) if isinstance(hash_map, dict) else None
        stored_pdf_hash = entry.get('pdf_hash') if isinstance(entry, dict) else None
        stored_md_hash = entry.get('md_hash') if isinstance(entry, dict) else None

        # 打印哈希校对
        print(f"\n[HASH CHECK] {pdf_filename}")
        print(f"  stored_pdf_hash: {stored_pdf_hash if stored_pdf_hash else 'None'}")
        print(f"  stored_md_hash: {stored_md_hash if stored_md_hash else 'None'}")
        print(f"  current_pdf_hash: {current_pdf_hash if current_pdf_hash else 'None'}")
        print(f"  current_md_hash: {current_md_hash if current_md_hash else 'None'}")

        # 判定是否需要重新生成
        need_convert = False

        if not pdf_exists:
            need_convert = True
            print("  -> PDF 不存在，将生成。")
        elif stored_pdf_hash is None:
            # 没有历史记录，视为需要重建，强制转换
            need_convert = True
            print("  -> 无历史记录，强制转换以重建目标 PDF。")
        elif stored_md_hash is not None and stored_md_hash != current_md_hash:
            need_convert = True
            print("  -> 源 Markdown 哈希变化，将重新生成并覆盖。")
        elif stored_pdf_hash != current_pdf_hash:
            need_convert = True
            print("  -> 输出 PDF 哈希不一致，将重新生成并覆盖。")
        else:
            print("  -> 哈希一致，无需重新生成。")

        if not need_convert:
            # 更新/写入映射条目
            hash_map[pdf_filename] = {
                "md_path": _to_rel_under_root(md_file),
                "pdf_path": _to_rel_under_root(expected_pdf_path),
                "md_hash": current_md_hash,
                "pdf_hash": current_pdf_hash,
            }
            print(f"\n--- SKIPPING (无变化): {pdf_filename} ---")
            continue
        # <--- 哈希映射与变更检测结束 --->

        print(f"\n--- 正在转换: {filename} ---")
        try:
            # 调用 Node.js 脚本，并传递文件路径和输出目录
            result = subprocess.run(
                ['node', node_script_path, md_file, output_dir],
                check=True,
                capture_output=True,
                encoding='utf-8'
            )
            # 打印 Node.js 脚本的输出
            print(result.stdout.strip())
            if result.stderr:
                print("错误信息:", result.stderr.strip())

            # 生成成功后，更新哈希映射并打印新的哈希
            new_pdf_hash = _sha256_of_file(expected_pdf_path)
            print(f"  新 pdf_hash: {new_pdf_hash if new_pdf_hash else 'None'}")
            hash_map[pdf_filename] = {
                "md_path": _to_rel_under_root(md_file),
                "pdf_path": _to_rel_under_root(expected_pdf_path),
                "md_hash": current_md_hash,
                "pdf_hash": new_pdf_hash,
            }

        except subprocess.CalledProcessError as e:
            print(f"转换文件 {filename} 时发生错误:")
            print(f"--- Node.js 输出 ---")
            print(e.stdout.strip())
            print(e.stderr.strip())
            print(f"----------------------")
        except FileNotFoundError:
            print("错误: 'node' 命令未找到。请确保您已安装 Node.js 并且已将其添加到系统路径中。")
            break

    # 将最新的哈希映射保存到输出目录（统一路径为相对 ROOT_DIRECTORY）
    sanitized_map = _sanitize_paths_in_hash_map(hash_map, ROOT_DIRECTORY)
    _save_hash_map(hash_map_path, sanitized_map)

    print("\n所有文件处理完毕！")


if __name__ == '__main__':
    batch_convert_md_to_pdf(INPUT_DIRECTORY, OUTPUT_DIRECTORY)
