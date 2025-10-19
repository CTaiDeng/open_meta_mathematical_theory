# SPDX-License-Identifier: GPL-3.0-only
# Copyright ( C ) 2025 GaoZheng

import glob
import os
import re
import subprocess
import json
import hashlib
from pathlib import Path


# 仓库根目录
ROOT_DIRECTORY = str(Path(__file__).resolve().parents[2])

# 子项目映射（源 → 输出子目录）
SUBPROJECTS = {
    'haca': 'haca_pdf',
    'lbopb': 'lbopb_pdf',
}

# 路径
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

    # 收集 .md 文件
    markdown_files = glob.glob(os.path.join(input_dir, '**', '*.md'), recursive=True)
    if not markdown_files:
        print(f"[INFO] 未找到 Markdown 文件: {input_dir}")
        return

    # Node.js 转换脚本
    script_dir = os.path.dirname(os.path.abspath(__file__))
    node_script_path = os.path.join(script_dir, 'convert.js')
    if not os.path.exists(node_script_path):
        print("[ERROR] convert.js 未找到，请确认脚本位置。")
        return

    # 跳过模式
    skip_pattern = re.compile(r'^\d+_\.md$')
    excluded_basenames = {'README.md', 'INDEX.md'}

    for md_file in markdown_files:
        filename = os.path.basename(md_file)

        if filename in excluded_basenames or skip_pattern.match(filename):
            print(f"\n--- SKIPPING: {filename} ---")
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
            # 立即持久化，确保补全/修复
            _save_hash_map(HASH_MAP_PATH, _sanitize_paths_in_hash_map(hash_map, ROOT_DIRECTORY))
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

            # 若生成文件名与预期不一致，使用差集策略重命名
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
            _save_hash_map(HASH_MAP_PATH, _sanitize_paths_in_hash_map(hash_map, ROOT_DIRECTORY))

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
            _save_hash_map(HASH_MAP_PATH, _sanitize_paths_in_hash_map(hash_map, ROOT_DIRECTORY))
        except FileNotFoundError:
            print("错误: 未找到 'node' 命令，请安装 Node.js 并加入 PATH。")
            break
        except Exception as e:
            print(f"转换异常({filename}): {e}")
            hash_map[pdf_filename] = {
                "md_path": _to_rel_under_root(md_file),
                "pdf_path": _to_rel_under_root(expected_pdf_path),
                "md_hash": current_md_hash,
                "pdf_hash": _sha256_of_file(expected_pdf_path) if os.path.exists(expected_pdf_path) else None,
            }
            _save_hash_map(HASH_MAP_PATH, _sanitize_paths_in_hash_map(hash_map, ROOT_DIRECTORY))


def main():
    os.makedirs(SUB_DOCS_PDF_ROOT, exist_ok=True)
    hash_map = _load_hash_map(HASH_MAP_PATH)

    for sub, out_sub in SUBPROJECTS.items():
        _process_one_subproject(sub, out_sub, hash_map)

    sanitized_map = _sanitize_paths_in_hash_map(hash_map, ROOT_DIRECTORY)
    _save_hash_map(HASH_MAP_PATH, sanitized_map)
    print("\n所有子项目处理完成，映射已更新：", _to_rel_under_root(HASH_MAP_PATH))


if __name__ == '__main__':
    main()

