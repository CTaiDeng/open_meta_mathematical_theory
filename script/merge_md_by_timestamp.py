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
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, List, Optional


TIMESTAMP_BASENAME_RE = re.compile(r"^(?P<ts>\d{10})_.+\.md$")


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


def write_json(out_path: Path, entries: List[Entry], source_dirs: List[str]) -> None:
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
    # Ensure LF newlines when writing.
    with out_path.open('w', encoding='utf-8', newline='\n') as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
        f.write('\n')  # newline at EOF


def write_markdown(out_path: Path, entries: List[Entry], title: Optional[str] = None) -> None:
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
        # 原文内容直接拼接；保持原有段落。
        # 确保结尾有一个空行分隔。
        if e.content and not e.content.endswith('\n'):
            lines.append(e.content + '\n')
        else:
            lines.append(e.content)
    # Ensure LF newlines when writing.
    with out_path.open('w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(lines))


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

    files = list(iter_md_files(src_dirs))
    entries = parse_entries(repo_root, files)

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

    out_json = out_dir / f"{script_stem}.json"
    out_md = out_dir / f"{script_stem}.md"

    write_json(out_json, entries, source_dirs_raw)
    write_markdown(out_md, entries, title=f"{script_stem} 合并结果")

    print(f"Wrote JSON: {out_json}")
    print(f"Wrote Markdown: {out_md}")
    print(f"Total files merged: {len(entries)}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
