#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2025 GaoZheng

"""
Merge Markdown files whose basenames match '<UNIX_EPOCH_SECONDS>_*.md' from
configured directories, sorted by timestamp ascending, and emit combined
Markdown and JSON into the 'out' directory.

Defaults:
- Config path: same directory, same basename with '.json'
- Output files: in 'out' as '<script_basename>.md' and '<script_basename>.json'

Notes:
- Encoding is UTF-8 (no BOM). Newlines are LF ('\n').
- Does not modify any source files. Only reads and writes under 'out/'.

Optional Gemini compression summary:
- Controlled by config JSON key 'compression'. If enabled and API key is set
  in env var 'GEMINI_API_KEY' or 'GOOGLE_API_KEY', the script asks Gemini to
  compress the merged content into a concise Chinese summary (<= max_chars,
  default 500). Model alias 'flash2.5' maps to 'gemini-2.5-flash'.
- Principles (configurable via 'compression.principles'):
  - 信息无损（不遗漏关键事实与结论，不引入新信息）
  - 不重复（合并同类项，去除赘述）
  - 符号化（能用数学/逻辑符号表达则优先使用）
  - 尽可能的简洁（短句；必要时使用分号/列表）
  - 定义一致（术语/符号/概念前后一致、一一对应）
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, List, Optional, Tuple


TIMESTAMP_BASENAME_RE = re.compile(r"^(?P<ts>\d{10})_.+\.md$")


def _supports_color() -> bool:
    try:
        return sys.stdout.isatty() and os.environ.get('TERM', '') != 'dumb'
    except Exception:
        return False


def _colorize(text: str, color: str = '36') -> str:  # 36=cyan, 32=green, 33=yellow, 31=red
    return f"\033[{color}m{text}\033[0m"


def _debug_print(msg: str, color: str = '36') -> None:
    # 简体中文 Debug：普通行 + 彩色行；若不支持彩色，则重复普通行。
    print(msg)
    if _supports_color():
        print(_colorize(msg, color))
    else:
        print(msg)


@dataclass
class Entry:
    ts: int
    path: Path  # absolute path
    rel: Path   # relative to repo root
    name: str   # basename
    content: str


def load_config(config_path: Path) -> dict:
    with config_path.open('r', encoding='utf-8') as f:
        cfg = json.load(f)
    return cfg


def iter_md_files(dirs: Iterable[Path]) -> Iterable[Path]:
    for d in dirs:
        if not d.exists():
            continue
        # 递归枚举 Markdown 文件，再由正则过滤文件名
        yield from d.rglob('*.md')


def parse_entries(repo_root: Path, files: Iterable[Path]) -> List[Entry]:
    entries: List[Entry] = []
    for p in files:
        name = p.name
        m = TIMESTAMP_BASENAME_RE.match(name)
        if not m:
            continue
        try:
            ts = int(m.group('ts'))
        except Exception:
            continue
        try:
            content = p.read_text(encoding='utf-8')
        except UnicodeDecodeError:
            # Fallback: try utf-8 with errors replaced to avoid aborting.
            content = p.read_text(encoding='utf-8', errors='replace')
        entries.append(Entry(
            ts=ts,
            path=p.resolve(),
            rel=p.resolve().relative_to(repo_root.resolve()),
            name=name,
            content=content,
        ))
    entries.sort(key=lambda e: (e.ts, str(e.rel)))
    return entries


def ensure_out_dir(out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)


def write_json(out_path: Path, entries: List[Entry], source_dirs: List[str], compression: Optional[dict] = None) -> None:
    payload = {
        'generated_at': datetime.now(timezone.utc).isoformat(),
        'source_dirs': source_dirs,
        'total_files': len(entries),
        'files': [
            {
                'path': str(e.rel).replace('\\', '/'),
                'filename': e.name,
                'timestamp': e.ts,
                'datetime_utc': datetime.fromtimestamp(e.ts, tz=timezone.utc).isoformat(),
                'content': e.content,
            }
            for e in entries
        ],
    }
    if compression is not None:
        payload['compression'] = compression
    # 保证 LF 换行
    with out_path.open('w', encoding='utf-8', newline='\n') as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
        f.write('\n')  # newline at EOF


def build_markdown_text(entries: List[Entry], title: Optional[str] = None) -> str:
    if title is None:
        title = '按时间戳合并的 Markdown 文档'
    lines: List[str] = []
    total = len(entries)
    lines.append(f"# {title}")
    lines.append("")
    lines.append(f"生成时间（UTC）：{datetime.now(timezone.utc).isoformat()}")
    lines.append(f"合计文件：{total}")
    lines.append("")
    for idx, e in enumerate(entries, start=1):
        dt_utc = datetime.fromtimestamp(e.ts, tz=timezone.utc).isoformat()
        lines.append('---')
        lines.append("")
        lines.append(f"## [{idx}/{total}] {e.name}")
        lines.append("")
        rel_posix = e.rel.as_posix()
        lines.append(f"- 源路径：`{rel_posix}`")
        lines.append(f"- 时间戳：`{e.ts}`；UTC：`{dt_utc}`")
        lines.append("")
        if e.content and not e.content.endswith('\n'):
            lines.append(e.content + '\n')
        else:
            lines.append(e.content)
        # 控制台同步输出进度：x/总数 + 文件名
        _debug_print(f"[进度] {idx}/{total}：{e.name}", '36')
    return '\n'.join(lines)


def write_markdown(out_path: Path, entries: List[Entry], title: Optional[str] = None) -> None:
    text = build_markdown_text(entries, title)
    with out_path.open('w', encoding='utf-8', newline='\n') as f:
        f.write(text)


def _gemini_model_from_alias(alias: str) -> str:
    alias = (alias or '').strip().lower()
    mapping = {
        'flash2.5': 'gemini-2.5-flash',
        'pro2.5': 'gemini-2.5-pro',
        'flash1.5': 'gemini-1.5-flash',
        'pro1.5': 'gemini-1.5-pro',
    }
    return mapping.get(alias, alias or 'gemini-2.5-flash')


def run_gemini_summary(
    text: str,
    model_alias: str,
    max_chars: int,
    interval_sec: float = 0.0,
    on_progress: Optional[callable] = None,
    principles: Optional[List[str]] = None,
) -> Tuple[bool, Optional[str], Optional[str]]:
    """调用 Gemini 压缩文本；当文本过长时分块请求后再二次汇总，尽量信息无损。

    on_progress(i, n, chunk_summary) 若提供，则在每个分块摘要完成后被调用（i 从 1 开始）。
    """
    api_key = os.environ.get('GEMINI_API_KEY') or os.environ.get('GOOGLE_API_KEY')
    if not api_key:
        return False, None, '未检测到 GEMINI_API_KEY/GOOGLE_API_KEY 环境变量'
    try:
        import google.generativeai as genai  # type: ignore
    except Exception as e:
        return False, None, f'缺少 google-generativeai 依赖：{e!s}'

    try:
        genai.configure(api_key=api_key)
        model_name = _gemini_model_from_alias(model_alias)
        model = genai.GenerativeModel(model_name)

        def _call(prompt: str) -> Tuple[bool, Optional[str]]:
            if interval_sec and interval_sec > 0:
                _debug_print(f"[Gemini] 等待 {interval_sec}s 后发起请求…", '33')
                time.sleep(interval_sec)
            _debug_print("[Gemini] 正在请求…", '33')
            try:
                resp = model.generate_content(prompt)
                out = getattr(resp, 'text', None)
                if not out and hasattr(resp, 'candidates') and resp.candidates:
                    parts = []
                    for c in resp.candidates:
                        try:
                            parts.append(c.content.parts[0].text)
                        except Exception:
                            continue
                    out = '\n'.join([p for p in parts if p])
                if out:
                    return True, out.strip()
                return False, None
            except Exception:
                return False, None

        chunk_size = 60000  # 粗略按字符长度限制输入规模
        if len(text) <= chunk_size:
            principles_lines = []
            if principles:
                for p in principles:
                    p = str(p).strip()
                    if p:
                        principles_lines.append(f"- {p}")
            fixed_lines = [
                f"- 仅用简体中文输出，总字数不超过 {max_chars} 字；",
                "- 只保留关键信息与结论，去除冗余与复述；",
                "- 不逐篇复述，不重复相同主题的内容；",
                "- 尽可能采用符号化表达（例如 →, ⇒, ∵, ∴, ⟺, ∈, ⊆, ∀, ∃, ≈, ≡ 等）；",
                "- 保持术语/定义/符号前后一致，必要时用紧凑短句或分号分隔。",
            ]
            all_rules = "\n".join(principles_lines + fixed_lines)
            prompt = (
                '你将收到一份按时间排列的多篇中文文档合并文本。请进行“信息无损”的高度凝练压缩：\n'
                f"{all_rules}\n\n"
                '【合并文本】\n'
            )
            ok, out = _call(prompt + text)
            if ok and out:
                s = out.strip()
                if len(s) > max_chars:
                    s = s[:max_chars]
                return True, s, None
            return False, None, 'Gemini 无返回文本'

        # 分块摘要阶段
        chunks = [text[i:i+chunk_size] for i in range(0, len(text), chunk_size)]
        digests: List[str] = []
        for i, ch in enumerate(chunks, 1):
            _debug_print(f"[Gemini] 分块 {i}/{len(chunks)} 摘要…", '33')
            prompt_part_lines = []
            if principles:
                for p in principles:
                    p = str(p).strip()
                    if p:
                        prompt_part_lines.append(f"- {p}")
            prompt_part_fixed = [
                "- 去重、不赘述、合并同类项；",
                "- 仅用简体中文输出，限 400 字以内；",
                "- 术语/定义/符号前后一致，尽量符号化表达；",
            ]
            prompt_part = (
                '以下是合并文档的一部分。请提炼“信息无损”的关键要点：\n\n' +
                "\n".join(prompt_part_lines + prompt_part_fixed) +
                "\n\n"
            )
            ok, out = _call(prompt_part + ch)
            digests.append((out or '').strip())
            if on_progress:
                try:
                    on_progress(i, len(chunks), (out or '').strip())
                except Exception:
                    pass

        # 二次汇总到最终 <= max_chars
        joined = '\n'.join(digests)
        final_rules_lines = []
        if principles:
            for p in principles:
                p = str(p).strip()
                if p:
                    final_rules_lines.append(f"- {p}")
        final_rules_fixed = [
            f"- 仅用简体中文输出，总字数不超过 {max_chars} 字；",
            "- 不逐条复述，合并同类项，去重；",
            "- 聚焦结论与独特信息；术语/定义/符号保持一致，尽量符号化表达。",
        ]
        final_prompt = (
            '你将收到若干分块摘要，请在“尽量信息无损”的前提下进行最终高度凝练：\n' +
            "\n".join(final_rules_lines + final_rules_fixed) +
            '\n\n【分块摘要】\n'
        )
        ok, out = _call(final_prompt + joined)
        if ok and out:
            s = out.strip()
            if len(s) > max_chars:
                s = s[:max_chars]
            return True, s, None
        return False, None, 'Gemini 汇总失败'
    except Exception as e:
        return False, None, f'Gemini 异常：{e!s}'


def guess_repo_root(start: Path) -> Path:
    """Ascend from start to find top-level git repo root.
    Preference order:
      1) Directory containing '.git'
      2) Highest directory (closest to root) containing 'README.md'
      3) start's parent if it contains 'src'
      4) start
    """
    cur = start.resolve()
    best_readme: Optional[Path] = None
    while True:
        if (cur / '.git').exists():
            return cur
        if (cur / 'README.md').exists():
            best_readme = cur
        if cur.parent == cur:
            break
        cur = cur.parent
    if best_readme is not None:
        return best_readme
    if (start.parent / 'src').exists():
        return start.parent
    return start.resolve()


def main(argv: Optional[List[str]] = None) -> int:
    script_path = Path(__file__).resolve()
    script_stem = script_path.stem
    default_config = script_path.with_suffix('.json')

    parser = argparse.ArgumentParser(description='合并文件名为 <UNIX秒>_*.md 的 Markdown（按时间戳升序），输出 JSON 与 Markdown。')
    parser.add_argument('--config', type=Path, default=default_config, help='配置文件路径（默认：与脚本同名同目录的 .json）')
    parser.add_argument('--out-dir', type=Path, default=None, help='覆盖输出目录（默认：配置中的 output_dir 或仓库 ./out）')
    parser.add_argument('--dry-run', action='store_true', help='仅扫描与计数，不写入输出文件')
    args = parser.parse_args(argv)

    cfg = load_config(args.config)
    _debug_print(f"[合并] 使用配置：{args.config}", '36')

    source_dirs_raw: List[str] = cfg.get('source_dirs', [])
    output_dir_cfg: Optional[str] = cfg.get('output_dir')

    # 目录归一化（兼容 '/' 与 '\\'）
    script_dir = script_path.parent
    repo_root = guess_repo_root(script_dir)

    src_dirs: List[Path] = []
    for d in source_dirs_raw:
        # 优先按仓库根相对路径解析
        p = (repo_root / d).resolve()
        if not p.exists():
            # 回退绝对路径
            p = Path(d).expanduser().resolve()
        src_dirs.append(p)
    _debug_print(f"[合并] 仓库根：{repo_root}", '36')
    _debug_print(f"[合并] 源目录：{[str(p) for p in src_dirs]}", '36')

    files = list(iter_md_files(src_dirs))
    entries = parse_entries(repo_root, files)
    _debug_print(f"[合并] 匹配文件数：{len(entries)}", '36')

    if args.dry_run:
        total = len(entries)
        print(f"找到 {total} 个匹配文件（展示前 10 个）：")
        for i, e in enumerate(entries[:10], 1):
            print(f"- {i}/{total} {e.ts} {e.rel}")
        return 0

    out_dir = args.out_dir if args.out_dir else (
        Path(output_dir_cfg) if output_dir_cfg else (repo_root / 'out')
    )
    if not out_dir.is_absolute():
        out_dir = (repo_root / out_dir).resolve()
    ensure_out_dir(out_dir)
    _debug_print(f"[合并] 输出目录：{out_dir}", '36')

    out_json = out_dir / f"{script_stem}.json"
    out_md = out_dir / f"{script_stem}.md"

    # 读取压缩设置
    compression_cfg = cfg.get('compression', {}) if isinstance(cfg.get('compression', {}), dict) else {}
    comp_enabled = bool(compression_cfg.get('enabled', False))
    comp_model_alias = str(compression_cfg.get('model', 'flash2.5'))
    comp_max_chars = int(compression_cfg.get('max_chars', 500))
    comp_interval = float(compression_cfg.get('request_interval_seconds', 0) or 0)
    comp_principles = compression_cfg.get('principles')
    if isinstance(comp_principles, list):
        comp_principles = [str(x) for x in comp_principles]
    else:
        comp_principles = [
            '信息无损（不遗漏关键事实与结论，不引入新信息）',
            '不重复（合并同类项，去除赘述）',
            '符号化（能用数学/逻辑符号表达则优先使用）',
            '尽可能的简洁（短句；必要时使用分号/列表）',
            '定义一致（术语/符号/概念前后一致、一一对应）',
        ]

    comp_ok: bool = False
    comp_summary: Optional[str] = None
    comp_error: Optional[str] = None

    md_title = f"{script_stem} 合并结果"
    md_text = build_markdown_text(entries, title=md_title)

    # 若启用压缩：先不写入最终 JSON/Markdown；逐请求落盘进度
    progress_path = None
    if comp_enabled:
        progress_path = (out_dir / f"{script_stem}.progress.md").resolve()
        _debug_print(f"[Gemini] 压缩启用；模型={comp_model_alias}，最大字数={comp_max_chars}，请求间隔={comp_interval}s", '33')

        def _progress_writer(i: int, n: int, txt: str) -> None:
            header = f"### 分块 {i}/{n} 摘要\n\n"
            mode = 'a' if progress_path and progress_path.exists() else 'w'
            with open(progress_path, mode, encoding='utf-8', newline='\n') as pf:
                if mode == 'w':
                    pf.write('# Gemini 分块摘要进度\n\n')
                    pf.write(f'生成时间（UTC）：{datetime.now(timezone.utc).isoformat()}\n\n')
                pf.write(header)
                pf.write((txt or '').strip() + "\n\n")
            _debug_print(f"[进度] 已保存分块摘要 {i}/{n} 至 {progress_path}", '33')

        ok, summ, err = run_gemini_summary(
            md_text, comp_model_alias, comp_max_chars, comp_interval, on_progress=_progress_writer, principles=comp_principles
        )
        comp_ok, comp_summary, comp_error = ok, summ, err
        _debug_print(f"[Gemini] 完成：ok={comp_ok} error={comp_error}", '33')

    comp_info = None
    if comp_enabled:
        comp_info = {
            'enabled': comp_enabled,
            'provider': 'gemini',
            'model_alias': comp_model_alias,
            'model_resolved': _gemini_model_from_alias(comp_model_alias),
            'max_chars': comp_max_chars,
            'ok': comp_ok,
            'error': comp_error,
            'summary': comp_summary,
            'principles': comp_principles,
        }

    # 写入最终 JSON/Markdown（仅在压缩结束后执行，避免“预先写入”）
    write_json(out_json, entries, source_dirs_raw, compression=comp_info)
    _debug_print(f"[合并] 已写入 JSON：{out_json}", '32')

    # 若启用压缩：在 Markdown 顶部加入“压缩摘要（Gemini）”段
    if comp_enabled:
        lines: List[str] = []
        lines.append(f"# {md_title}")
        lines.append("")
        lines.append(f"生成时间（UTC）：{datetime.now(timezone.utc).isoformat()}")
        lines.append(f"合计文件：{len(entries)}")
        lines.append("")
        lines.append('---')
        lines.append("")
        lines.append('## 压缩摘要（Gemini）')
        lines.append("")
        lines.append((comp_summary or f"（未生成）{comp_error or '未启用或发生错误'}"))
        lines.append("")
        # 追加详细合并内容（剔除重复头部）
        marker = '\n---\n'
        idx = md_text.find(marker)
        if idx != -1:
            lines.append(md_text[idx + 1:])
        else:
            lines.append(md_text)
        with out_md.open('w', encoding='utf-8', newline='\n') as f:
            f.write('\n'.join(lines))
        _debug_print(f"[合并] 已写入 Markdown：{out_md}", '32')
    else:
        write_markdown(out_md, entries, title=md_title)
        _debug_print(f"[合并] 已写入 Markdown：{out_md}", '32')

    print(f"完成：JSON -> {out_json}")
    print(f"完成：Markdown -> {out_md}")
    print(f"总计合并文件数：{len(entries)}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
