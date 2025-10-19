# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2025 GaoZheng

import glob
import os
import re
import subprocess
import json
import hashlib
import uuid
from pathlib import Path


# 仓库根目录
ROOT_DIRECTORY = str(Path(__file__).resolve().parents[2])

# 源与目标映射（子项目 -> 输出子目录）
SUBPROJECTS = {
    'haca': 'haca_pdf',
    'lbopb': 'lbopb_pdf',
}

# 路径常量
SUB_DOCS_ROOT = os.path.join(ROOT_DIRECTORY, 'src', 'sub_projects_docs')
SUB_DOCS_PDF_ROOT = os.path.join(ROOT_DIRECTORY, 'src', 'sub_projects_docs_pdf')
HASH_MAP_PATH = os.path.join(SUB_DOCS_PDF_ROOT, '_hash_map.json')


def _sha256_of_file(path: str):
    if not os.path.exists(path) or not os.path.isfile(path):
        return None
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def _load_hash_map(json_path: str):
    if not os.path.exists(json_path):
        return {}
    try:
        with open(json_path, 'r', encoding='utf-8') as f:
            data = json.load(f)
            return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _save_hash_map(json_path: str, data: dict):
    os.makedirs(os.path.dirname(json_path), exist_ok=True)
    with open(json_path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def _to_rel_under_root(path: str):
    try:
        return os.path.relpath(path, ROOT_DIRECTORY)
    except Exception:
        return path


def _sanitize_paths_in_hash_map(data: dict, root_dir: str):
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


def _process_one_subproject(sub_dir_name: str, output_sub_dir_name: str, hash_map: dict):
    input_dir = os.path.join(SUB_DOCS_ROOT, sub_dir_name)
    output_dir = os.path.join(SUB_DOCS_PDF_ROOT, output_sub_dir_name)

    if not os.path.isdir(input_dir):
        print(f"[WARN] 输入目录不存在或无效: {input_dir}")
        return

    os.makedirs(output_dir, exist_ok=True)

    # 递归查找 .md 文件
    search_pattern = os.path.join(input_dir, '**', '*.md')
    markdown_files = glob.glob(search_pattern, recursive=True)
    if not markdown_files:
        print(f"[INFO] 未找到 Markdown 文件: {input_dir}")
        return

    # Node.js 转换脚本路径
    script_dir = os.path.dirname(os.path.abspath(__file__))
    node_script_path = os.path.join(script_dir, 'convert.js')
    if not os.path.exists(node_script_path):
        print("[ERROR] convert.js 未找到，请确认脚本位置。")
        return

    # 跳过模式（保持与 kernel 脚本一致）
    skip_pattern = re.compile(r'^\d+_\.md$')

    # 额外排除列表（按需扩展）
    excluded_basenames = {
        'README.md',
        'INDEX.md',
    }

    for md_file in markdown_files:
        filename = os.path.basename(md_file)

        # 排除 README 与特定模式
        if filename in excluded_basenames or skip_pattern.match(filename):
            print(f"\n--- SKIPPING: {filename} ---")
            continue

        # 目标 PDF 路径（放置在子项目专属输出目录）
        pdf_filename = os.path.splitext(filename)[0] + '.pdf'
        expected_pdf_path = os.path.join(output_dir, pdf_filename)

        # 计算当前哈希
        pdf_exists = os.path.exists(expected_pdf_path)
        current_pdf_hash = _sha256_of_file(expected_pdf_path) if pdf_exists else None
        current_md_hash = _sha256_of_file(md_file)

        # 读取历史记录
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
            # 立即持久化（补全/修复变更）
            _save_hash_map(HASH_MAP_PATH, _sanitize_paths_in_hash_map(hash_map, ROOT_DIRECTORY))
            print(f"\n--- SKIPPING (无变化): {pdf_filename} ---")
            continue

        print(f"\n--- 开始转换: {filename} ---")
        temp_md_path = None
        try:
            # 在同目录创建带一个头部换行的临时 md 文件，仅供本次转换使用
            dir_name = os.path.dirname(md_file)
            base_token = uuid.uuid4().hex[:8]
            temp_md_path = os.path.join(dir_name, f"._tmp_convert_{base_token}_{os.path.basename(md_file)}")

            # 以二进制读写，保留原编码/BOM，并尽量匹配原换行风格
            with open(md_file, 'rb') as rf:
                content = rf.read()
            bom = b''
            rest = content
            if content.startswith(b"\xef\xbb\xbf"):
                bom = content[:3]
                rest = content[3:]
            newline = b"\r\n" if b"\r\n" in rest else b"\n"
            with open(temp_md_path, 'wb') as wf:
                header = "License：CC BY-NC-ND 4.0".encode('utf-8')
                wf.write(bom + header + newline + rest)

            # 使用临时 md 进行转换
            result = subprocess.run(
                ['node', node_script_path, temp_md_path, output_dir],
                check=True,
                capture_output=True,
                encoding='utf-8'
            )
            print(result.stdout.strip())
            if result.stderr:
                print("错误信息:", result.stderr.strip())

            # 若 convert.js 以临时名输出，则重命名为期望文件名
            generated_pdf_from_temp = os.path.join(
                output_dir,
                os.path.splitext(os.path.basename(temp_md_path))[0] + '.pdf'
            )
            if os.path.exists(generated_pdf_from_temp) and generated_pdf_from_temp != expected_pdf_path:
                try:
                    if os.path.exists(expected_pdf_path):
                        os.remove(expected_pdf_path)
                    os.replace(generated_pdf_from_temp, expected_pdf_path)
                except Exception as _:
                    pass

            new_pdf_hash = _sha256_of_file(expected_pdf_path)
            print(f"  -> 新 pdf_hash: {new_pdf_hash if new_pdf_hash else 'None'}")
            hash_map[pdf_filename] = {
                "md_path": _to_rel_under_root(md_file),
                "pdf_path": _to_rel_under_root(expected_pdf_path),
                "md_hash": current_md_hash,
                "pdf_hash": new_pdf_hash,
            }
            # 立即持久化（补全/修复变更）
            _save_hash_map(HASH_MAP_PATH, _sanitize_paths_in_hash_map(hash_map, ROOT_DIRECTORY))

        except subprocess.CalledProcessError as e:
            print(f"转换失败: {filename}")
            print("--- Node.js 输出 ---")
            print(e.stdout.strip())
            print(e.stderr.strip())
            print("-------------------")
            # 即便失败，也补全当前 MD 条目（PDF 仍以现状记录）
            hash_map[pdf_filename] = {
                "md_path": _to_rel_under_root(md_file),
                "pdf_path": _to_rel_under_root(expected_pdf_path),
                "md_hash": current_md_hash,
                "pdf_hash": _sha256_of_file(expected_pdf_path) if os.path.exists(expected_pdf_path) else None,
            }
            _save_hash_map(HASH_MAP_PATH, _sanitize_paths_in_hash_map(hash_map, ROOT_DIRECTORY))
        except FileNotFoundError:
            print("错误: 未找到 'node' 命令，请安装 Node.js 并加入 PATH。")
            break
        except Exception as e:
            # 兜底异常处理，同样补全映射
            print(f"转换异常({filename}): {e}")
            hash_map[pdf_filename] = {
                "md_path": _to_rel_under_root(md_file),
                "pdf_path": _to_rel_under_root(expected_pdf_path),
                "md_hash": current_md_hash,
                "pdf_hash": _sha256_of_file(expected_pdf_path) if os.path.exists(expected_pdf_path) else None,
            }
            _save_hash_map(HASH_MAP_PATH, _sanitize_paths_in_hash_map(hash_map, ROOT_DIRECTORY))
        finally:
            if temp_md_path and os.path.exists(temp_md_path):
                try:
                    os.remove(temp_md_path)
                except Exception:
                    pass


def main():
    # 确保输出根目录存在
    os.makedirs(SUB_DOCS_PDF_ROOT, exist_ok=True)

    # 读取/初始化哈希映射
    hash_map = _load_hash_map(HASH_MAP_PATH)

    # 依次处理各子项目
    for sub, out_sub in SUBPROJECTS.items():
        _process_one_subproject(sub, out_sub, hash_map)

    # 统一保存映射，路径归一为相对仓库根
    sanitized_map = _sanitize_paths_in_hash_map(hash_map, ROOT_DIRECTORY)
    _save_hash_map(HASH_MAP_PATH, sanitized_map)
    print("\n所有子项目处理完成，映射已更新：", _to_rel_under_root(HASH_MAP_PATH))


if __name__ == '__main__':
    main()
