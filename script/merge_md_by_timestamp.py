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


def _colorize(text: str, color: str = '36') -> str:  # 36=cyan
    return f"\033[{color}m{text}\033[0m"


def debug_print(msg: str) -> None:
    # 默认 Debug：先打印普通行，再打印彩色重复行（若终端支持）；否则重复普通行。
    print(msg)
    if _supports_color():
        print(_colorize(msg, '36'))
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
        # Recursive glob for all markdown files; we'll filter by basename regex.
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
    # Ensure LF newlines when writing.
    with out_path.open('w', encoding='utf-8', newline='\n') as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
        f.write('\n')  # newline at EOF


def write_markdown(out_path: Path, entries: List[Entry], title: Optional[str] = None) -> None:
    text = build_markdown_text(entries, title)
    # Ensure LF newlines when writing.
    with out_path.open('w', encoding='utf-8', newline='\n') as f:
        f.write(text)


def build_markdown_text(entries: List[Entry], title: Optional[str] = None) -> str:
    if title is None:
        title = 'Merged Markdown (sorted by UNIX timestamp)'
    lines: List[str] = []
    lines.append(f"# {title}")
    lines.append("")
    lines.append(f"生成时间（UTC）：{datetime.now(timezone.utc).isoformat()}")
    lines.append(f"合计文件：{len(entries)}")
    lines.append("")
    for i, e in enumerate(entries, start=1):
        dt_utc = datetime.fromtimestamp(e.ts, tz=timezone.utc).isoformat()
        lines.append('---')
        lines.append("")
        lines.append(f"## [{i}] {e.name}")
        lines.append("")
        rel_posix = e.rel.as_posix()
        lines.append(f"- 源路径：`{rel_posix}`")
        lines.append(f"- 时间戳：`{e.ts}`；UTC：`{dt_utc}`")
        lines.append("")
        if e.content and not e.content.endswith('\n'):
            lines.append(e.content + '\n')
        else:
            lines.append(e.content)
    return '\n'.join(lines)


def _gemini_model_from_alias(alias: str) -> str:
    alias = (alias or '').strip().lower()
    mapping = {
        'flash2.5': 'gemini-2.5-flash',
        'pro2.5': 'gemini-2.5-pro',
        'flash1.5': 'gemini-1.5-flash',
        'pro1.5': 'gemini-1.5-pro',
    }
    return mapping.get(alias, alias or 'gemini-2.5-flash')


def run_gemini_summary(text: str, model_alias: str, max_chars: int) -> Tuple[bool, Optional[str], Optional[str]]:
    api_key = os.environ.get('GEMINI_API_KEY') or os.environ.get('GOOGLE_API_KEY')
    if not api_key:
        return False, None, 'missing API key in GEMINI_API_KEY/GOOGLE_API_KEY'
    try:
        import google.generativeai as genai  # type: ignore
    except Exception as e:
        return False, None, f'missing google-generativeai: {e!s}'

    try:
        genai.configure(api_key=api_key)
        model_name = _gemini_model_from_alias(model_alias)
        model = genai.GenerativeModel(model_name)
        prompt = (
            '你将收到一份按时间排列的多篇中文文档合并文本。请进行“信息无损”的高度凝练压缩：\n'
            f'- 仅用简体中文输出，总字数不超过 {max_chars} 字；\n'
            '- 只保留关键信息与结论，去除冗余与复述；\n'
            '- 不逐篇复述，不重复相同主题的内容；\n'
            '- 保持术语与符号精确，必要时用紧凑短句或分号分隔。\n\n'
            '【合并文本】\n'
        )
        resp = model.generate_content(prompt + text)
        summary = getattr(resp, 'text', None)
        if not summary and hasattr(resp, 'candidates') and resp.candidates:
            parts = []
            for c in resp.candidates:
                try:
                    parts.append(c.content.parts[0].text)
                except Exception:
                    continue
            summary = '\n'.join([p for p in parts if p])
        if summary:
            s = summary.strip()
            if len(s) > max_chars:
                s = s[:max_chars]
            return True, s, None
        return False, None, 'no text in response'
    except Exception as e:
        return False, None, f'gemini error: {e!s}'


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

    parser = argparse.ArgumentParser(description='Merge timestamp-named Markdown files to JSON and Markdown outputs.')
    parser.add_argument('--config', type=Path, default=default_config, help='Path to config JSON (default: same dir/name as script).')
    parser.add_argument('--out-dir', type=Path, default=None, help='Override output directory (default from config or repo ./out).')
    parser.add_argument('--dry-run', action='store_true', help='Scan and report counts without writing outputs.')
    args = parser.parse_args(argv)

    cfg = load_config(args.config)
    debug_print(f"[merge] config path: {args.config}")

    source_dirs_raw: List[str] = cfg.get('source_dirs', [])
    output_dir_cfg: Optional[str] = cfg.get('output_dir')

    # Normalize directories (support both '/' and '\\' in paths)
    script_dir = script_path.parent
    repo_root = guess_repo_root(script_dir)

    src_dirs: List[Path] = []
    for d in source_dirs_raw:
        # Try repo-root relative first
        p = (repo_root / d).resolve()
        if not p.exists():
            # Try as-is absolute
            p = Path(d).expanduser().resolve()
        src_dirs.append(p)
    debug_print(f"[merge] repo root: {repo_root}")
    debug_print(f"[merge] source dirs: {[str(p) for p in src_dirs]}")

    files = list(iter_md_files(src_dirs))
    entries = parse_entries(repo_root, files)
    debug_print(f"[merge] matched files: {len(entries)}")

    if args.dry_run:
        print(f"Found {len(entries)} matching files.")
        for e in entries[:10]:
            print(f"- {e.ts} {e.rel}")
        return 0

    out_dir = args.out_dir if args.out_dir else (
        Path(output_dir_cfg) if output_dir_cfg else (repo_root / 'out')
    )
    if not out_dir.is_absolute():
        out_dir = (repo_root / out_dir).resolve()
    ensure_out_dir(out_dir)
    debug_print(f"[merge] output dir: {out_dir}")

    out_json = out_dir / f"{script_stem}.json"
    out_md = out_dir / f"{script_stem}.md"

    # Prepare compression settings from config
    compression_cfg = cfg.get('compression', {}) if isinstance(cfg.get('compression', {}), dict) else {}
    comp_enabled = bool(compression_cfg.get('enabled', False))
    comp_model_alias = str(compression_cfg.get('model', 'flash2.5'))
    comp_max_chars = int(compression_cfg.get('max_chars', 500))
    comp_interval = float(compression_cfg.get('request_interval_seconds', 0) or 0)
    debug_print(f"[merge] compression enabled={comp_enabled}, model={comp_model_alias}, max_chars={comp_max_chars}, interval={comp_interval}s")

    comp_ok: bool = False
    comp_summary: Optional[str] = None
    comp_error: Optional[str] = None

    md_title = f"{script_stem} 合并结果"
    md_text = build_markdown_text(entries, title=md_title)
    if comp_enabled:
        if comp_interval > 0:
            debug_print(f"[merge] sleeping {comp_interval}s before Gemini request…")
            time.sleep(comp_interval)
        debug_print("[merge] Gemini request starting…")
        comp_ok, comp_summary, comp_error = run_gemini_summary(md_text, comp_model_alias, comp_max_chars)
        debug_print(f"[merge] Gemini done ok={comp_ok} error={comp_error}")

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
        }

    write_json(out_json, entries, source_dirs_raw, compression=comp_info)
    debug_print(f"[merge] wrote JSON: {out_json}")

    # Write Markdown; if compression enabled, prepend a summary section
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
        # Append the detailed merged content (excluding duplicated header)
        marker = '\n---\n'
        idx = md_text.find(marker)
        if idx != -1:
            lines.append(md_text[idx + 1:])
        else:
            lines.append(md_text)
        with out_md.open('w', encoding='utf-8', newline='\n') as f:
            f.write('\n'.join(lines))
        debug_print(f"[merge] wrote Markdown: {out_md}")
    else:
        write_markdown(out_md, entries, title=md_title)
        debug_print(f"[merge] wrote Markdown: {out_md}")

    print(f"Wrote JSON: {out_json}")
    print(f"Wrote Markdown: {out_md}")
    print(f"Total files merged: {len(entries)}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
