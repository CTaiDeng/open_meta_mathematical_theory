# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2025 GaoZheng

import glob
import os
import re
import subprocess
import json
import hashlib
from pathlib import Path

# 根路径与默认输入/输出（kernel_reference 专用）
ROOT_DIRECTORY = str(Path(__file__).resolve().parents[2])
INPUT_DIRECTORY = os.path.join(ROOT_DIRECTORY, 'src', 'kernel_reference')
OUTPUT_DIRECTORY = os.path.join(ROOT_DIRECTORY, 'src', 'kernel_reference_pdf')


def _sha256_of_file(path):
    if not os.path.exists(path) or not os.path.isfile(path):
        return None
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def _load_hash_map(json_path):
    if not os.path.exists(json_path):
        return {}
    try:
        with open(json_path, 'r', encoding='utf-8') as f:
            data = json.load(f)
            return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _save_hash_map(json_path, data):
    os.makedirs(os.path.dirname(json_path), exist_ok=True)
    with open(json_path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def _to_rel_under_root(path):
    try:
        return os.path.relpath(path, ROOT_DIRECTORY)
    except Exception:
        return path


def _sanitize_paths_in_hash_map(data, root_dir):
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
                            entry[key] = p
                    except Exception:
                        entry[key] = p
            sanitized[k] = entry
        else:
            sanitized[k] = v
    return sanitized


def batch_convert_md_to_pdf(input_dir, output_dir):
    # 校验与准备目录
    if not os.path.isdir(input_dir):
        print(f"警告: 输入目录 '{input_dir}' 不存在或无效。")
        return

    os.makedirs(output_dir, exist_ok=True)

    # 递归收集 .md 文件
    markdown_files = glob.glob(os.path.join(input_dir, '**', '*.md'), recursive=True)
    if not markdown_files:
        print(f"目录 '{input_dir}' 下未找到任何 Markdown 文件。")
        return

    print(f"找到 {len(markdown_files)} 个 Markdown 文件，开始处理...")

    # Node 脚本路径
    script_dir = os.path.dirname(os.path.abspath(__file__))
    node_script_path = os.path.join(script_dir, 'convert.js')
    if not os.path.exists(node_script_path):
        print("错误: 未找到 'convert.js'，请确认脚本在同一目录。")
        return

    # 跳过模式（与原脚本一致）
    skip_pattern = re.compile(r'^\d+_\.md$')

    # 哈希映射
    hash_map_path = os.path.join(output_dir, '_hash_map.json')
    hash_map = _load_hash_map(hash_map_path)

    for md_file in markdown_files:
        filename = os.path.basename(md_file)
        if skip_pattern.match(filename):
            print(f"\n--- SKIPPING (模式匹配): {filename} ---")
            continue

        pdf_filename = os.path.splitext(filename)[0] + '.pdf'
        expected_pdf_path = os.path.join(output_dir, pdf_filename)

        pdf_exists = os.path.exists(expected_pdf_path)
        current_pdf_hash = _sha256_of_file(expected_pdf_path) if pdf_exists else None
        current_md_hash = _sha256_of_file(md_file)

        entry = hash_map.get(pdf_filename) if isinstance(hash_map, dict) else None
        stored_pdf_hash = entry.get('pdf_hash') if isinstance(entry, dict) else None
        stored_md_hash = entry.get('md_hash') if isinstance(entry, dict) else None

        print(f"\n[HASH CHECK] {pdf_filename}")
        print(f"  stored_pdf_hash: {stored_pdf_hash if stored_pdf_hash else 'None'}")
        print(f"  stored_md_hash: {stored_md_hash if stored_md_hash else 'None'}")
        print(f"  current_pdf_hash: {current_pdf_hash if current_pdf_hash else 'None'}")
        print(f"  current_md_hash: {current_md_hash if current_md_hash else 'None'}")

        need_convert = False
        if not pdf_exists:
            need_convert = True
            print("  -> PDF 不存在，准备生成。")
        elif stored_pdf_hash is None:
            need_convert = True
            print("  -> 无历史记录，强制转换并重建 PDF。")
        elif stored_md_hash is not None and stored_md_hash != current_md_hash:
            need_convert = True
            print("  -> 源 Markdown 变更，准备增量生成。")
        elif stored_pdf_hash != current_pdf_hash:
            need_convert = True
            print("  -> 现有 PDF 哈希不一致，准备重建。")
        else:
            print("  -> 哈希一致，跳过生成。")

        if not need_convert:
            hash_map[pdf_filename] = {
                "md_path": _to_rel_under_root(md_file),
                "pdf_path": _to_rel_under_root(expected_pdf_path),
                "md_hash": current_md_hash,
                "pdf_hash": current_pdf_hash,
            }
            print(f"\n--- SKIPPING (无变化): {pdf_filename} ---")
            continue

        print(f"\n--- 开始转换: {filename} ---")
        try:
            before_pdfs = {f for f in os.listdir(output_dir) if f.lower().endswith('.pdf')}

            # 直接使用原始 MD（不插入任何额外首行）
            result = subprocess.run(
                ['node', node_script_path, md_file, output_dir],
                check=True,
                capture_output=True,
                encoding='utf-8'
            )
            print(result.stdout.strip())
            if result.stderr:
                print("错误信息:", result.stderr.strip())

            # 若输出名与预期不一致，尝试根据新增文件重命名到预期名
            if not os.path.exists(expected_pdf_path):
                after_pdfs = {f for f in os.listdir(output_dir) if f.lower().endswith('.pdf')}
                new_candidates = list(after_pdfs - before_pdfs)
                if len(new_candidates) == 1:
                    src = os.path.join(output_dir, new_candidates[0])
                    try:
                        if os.path.exists(expected_pdf_path):
                            os.remove(expected_pdf_path)
                        os.replace(src, expected_pdf_path)
                    except Exception:
                        pass
                elif len(new_candidates) > 1:
                    try:
                        src = max((os.path.join(output_dir, n) for n in new_candidates), key=lambda p: os.path.getmtime(p))
                        if os.path.exists(expected_pdf_path):
                            os.remove(expected_pdf_path)
                        os.replace(src, expected_pdf_path)
                    except Exception:
                        pass

            new_pdf_hash = _sha256_of_file(expected_pdf_path)
            print(f"  -> 新 pdf_hash: {new_pdf_hash if new_pdf_hash else 'None'}")
            hash_map[pdf_filename] = {
                "md_path": _to_rel_under_root(md_file),
                "pdf_path": _to_rel_under_root(expected_pdf_path),
                "md_hash": current_md_hash,
                "pdf_hash": new_pdf_hash,
            }
            # 转换完成立即落盘，补全/修复变更
            _save_hash_map(hash_map_path, _sanitize_paths_in_hash_map(hash_map, ROOT_DIRECTORY))

        except subprocess.CalledProcessError as e:
            print(f"转换失败: {filename}")
            print("--- Node.js 输出 ---")
            print(e.stdout.strip())
            print(e.stderr.strip())
            print("-------------------")
            hash_map[pdf_filename] = {
                "md_path": _to_rel_under_root(md_file),
                "pdf_path": _to_rel_under_root(expected_pdf_path),
                "md_hash": current_md_hash,
                "pdf_hash": _sha256_of_file(expected_pdf_path) if os.path.exists(expected_pdf_path) else None,
            }
            _save_hash_map(hash_map_path, _sanitize_paths_in_hash_map(hash_map, ROOT_DIRECTORY))
        except FileNotFoundError:
            print("错误: 未找到 'node' 命令，请安装 Node.js 并加入 PATH。")
            hash_map[pdf_filename] = {
                "md_path": _to_rel_under_root(md_file),
                "pdf_path": _to_rel_under_root(expected_pdf_path),
                "md_hash": current_md_hash,
                "pdf_hash": _sha256_of_file(expected_pdf_path) if os.path.exists(expected_pdf_path) else None,
            }
            _save_hash_map(hash_map_path, _sanitize_paths_in_hash_map(hash_map, ROOT_DIRECTORY))
            return
        except Exception as e:
            print(f"转换异常({filename}): {e}")
            hash_map[pdf_filename] = {
                "md_path": _to_rel_under_root(md_file),
                "pdf_path": _to_rel_under_root(expected_pdf_path),
                "md_hash": current_md_hash,
                "pdf_hash": _sha256_of_file(expected_pdf_path) if os.path.exists(expected_pdf_path) else None,
            }
            _save_hash_map(hash_map_path, _sanitize_paths_in_hash_map(hash_map, ROOT_DIRECTORY))

    # 统一保存（兜底）
    sanitized_map = _sanitize_paths_in_hash_map(hash_map, ROOT_DIRECTORY)
    _save_hash_map(hash_map_path, sanitized_map)
    print("\n所有文件处理完成。")


if __name__ == '__main__':
    batch_convert_md_to_pdf(INPUT_DIRECTORY, OUTPUT_DIRECTORY)

