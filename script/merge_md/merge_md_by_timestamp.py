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
- Env override: if env var 'GEMINI_MODEL' is set, it overrides the model alias.
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
from typing import Iterable, List, Optional, Tuple, Dict, Any
import logging
import contextlib
import io


TIMESTAMP_BASENAME_RE = re.compile(r"^(?P<ts>\d{10})_.+\.md$")


def _supports_color() -> bool:
    try:
        return sys.stdout.isatty() and os.environ.get('TERM', '') != 'dumb'
    except Exception:
        return False


def _colorize(text: str, color: str = '36') -> str:  # 36=cyan, 32=green, 33=yellow, 31=red
    return f"\033[{color}m{text}\033[0m"


def _debug_print(msg: str, color: str = '36') -> None:
    # 简体中文 Debug：仅输出一行；若终端支持彩色，则只打印彩色行。
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


def write_json_summaries(
    out_path: Path,
    summaries: List[Dict[str, Any]],
    source_dirs: List[str],
    compression: Optional[dict] = None,
) -> None:
    payload = {
        'generated_at': datetime.now(timezone.utc).isoformat(),
        'source_dirs': source_dirs,
        'total_files': len(summaries),
        'files': summaries,
    }
    if compression is not None:
        payload['compression'] = compression
    with out_path.open('w', encoding='utf-8', newline='\n') as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
        f.write('\n')


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


def _quiet_gemini_logs() -> None:
    """尽量抑制 google-generativeai/grpc/absl 的噪声日志（跨平台最佳努力）。"""
    # 环境变量（仅在未设置时提供较严的默认）
    os.environ.setdefault('GLOG_minloglevel', '3')  # 仅 FATAL
    os.environ.setdefault('GRPC_VERBOSITY', 'ERROR')
    os.environ.setdefault('GRPC_TRACE', '')
    os.environ.setdefault('TF_CPP_MIN_LOG_LEVEL', '3')
    os.environ.setdefault('ABSL_LOGGING_MIN_LEVEL', '3')
    # Python 日志器等级
    logging.getLogger('google').setLevel(logging.ERROR)
    logging.getLogger('google.generativeai').setLevel(logging.ERROR)
    logging.getLogger('grpc').setLevel(logging.ERROR)


@contextlib.contextmanager
def _suppress_stderr_fd():
    """在 with 区块内暂时重定向底层 fd=2 到空设备，抑制 C/C++ 层日志。"""
    try:
        orig_fd = os.dup(2)
        devnull = os.open(os.devnull, os.O_WRONLY)
        os.dup2(devnull, 2)
        os.close(devnull)
        yield
    except Exception:
        # 若重定向失败，直接执行，不中断流程
        yield
    finally:
        try:
            if 'orig_fd' in locals():
                os.dup2(orig_fd, 2)
                os.close(orig_fd)
        except Exception:
            pass

def run_gemini_topic_check(
    text: str,
    model_alias: str,
    blocked_topics: List[str],
) -> Tuple[bool, Optional[Dict[str, Any]], Optional[str]]:
    """使用 Gemini 对文本进行主题检测：是否涉及任一 `blocked_topics`。

    返回：(ok, result, error)
    - ok=True 时，result 形如 {"hit": bool, "matched": [...], "reason": str}
    - 若无可用 API/依赖，返回 (False, None, 错误信息)
    """
    api_key = os.environ.get('GEMINI_API_KEY') or os.environ.get('GOOGLE_API_KEY')
    if not api_key:
        return False, None, '未检测到 GEMINI_API_KEY/GOOGLE_API_KEY 环境变量'
    try:
        _quiet_gemini_logs()
        import google.generativeai as genai  # type: ignore
    except Exception as e:
        return False, None, f'缺少 google-generativeai 依赖：{e!s}'

    try:
        genai.configure(api_key=api_key)
        model_name = _gemini_model_from_alias(model_alias)
        model = genai.GenerativeModel(model_name)

        topics_str = '、'.join(blocked_topics)
        sys_prompt = (
            '请判断以下中文文本是否涉及下列任一主题，并仅输出JSON：\n'
            f"- 目标主题：{topics_str}\n"
            "- 输出格式：{\"hit\": true|false, \"matched\": [字符串数组], \"reason\": \"<=60字\"}\n"
            "- 要求：\n"
            "  1) 若文本存在与上述主题相关的讨论/分析/观点/案例，则 hit=true；\n"
            "  2) matched 仅填入命中的主题原词；\n"
            "  3) 不要输出任何解释性文字或代码块围栏。\n\n"
            "【文本】\n"
        )

        with _suppress_stderr_fd():
            resp = model.generate_content(sys_prompt + text)
        out = getattr(resp, 'text', None)
        if not out and hasattr(resp, 'candidates') and resp.candidates:
            parts = []
            for c in resp.candidates:
                try:
                    parts.append(c.content.parts[0].text)
                except Exception:
                    continue
            out = '\n'.join([p for p in parts if p])
        if not out:
            return False, None, 'Gemini 无返回文本'
        s = out.strip()
        j = None
        try:
            j = json.loads(s)
        except Exception:
            try:
                start = s.find('{')
                end = s.rfind('}')
                if start != -1 and end != -1 and end > start:
                    j = json.loads(s[start:end+1])
            except Exception:
                j = None
        if not isinstance(j, dict):
            return False, None, 'Gemini 返回内容非JSON'
        hit = bool(j.get('hit'))
        matched = j.get('matched')
        if not isinstance(matched, list):
            matched = []
        matched = [str(x).strip() for x in matched if str(x).strip()]
        reason = str(j.get('reason') or '').strip()
        return True, { 'hit': hit, 'matched': matched, 'reason': reason }, None
    except Exception as e:
        return False, None, f'Gemini 异常：{e!s}'


def run_gemini_summary(
    text: str,
    model_alias: str,
    max_chars: int,
    interval_sec: float = 0.0,
    on_progress: Optional[callable] = None,
    principles: Optional[List[str]] = None,
    blocked_topics: Optional[List[str]] = None,
) -> Tuple[bool, Optional[Any], Optional[str]]:
    """调用 Gemini 压缩文本；当文本过长时分块请求后再二次汇总，尽量信息无损。

    on_progress(i, n, chunk_summary) 若提供，则在每个分块摘要完成后被调用（i 从 1 开始）。
    """
    api_key = os.environ.get('GEMINI_API_KEY') or os.environ.get('GOOGLE_API_KEY')
    if not api_key:
        return False, None, '未检测到 GEMINI_API_KEY/GOOGLE_API_KEY 环境变量'
    try:
        _quiet_gemini_logs()
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
                with _suppress_stderr_fd():
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
        topics_str = '、'.join(blocked_topics) if blocked_topics else ''

        def _try_parse_exclusion(s: str) -> Optional[Dict[str, Any]]:
            try:
                j = json.loads(s)
            except Exception:
                try:
                    start = s.find('{')
                    end = s.rfind('}')
                    if start != -1 and end != -1 and end > start:
                        j = json.loads(s[start:end+1])
                    else:
                        return None
                except Exception:
                    return None
            if isinstance(j, dict) and bool(j.get('excluded')):
                matched = j.get('matched')
                if not isinstance(matched, list):
                    matched = []
                matched = [str(x).strip() for x in matched if str(x).strip()]
                reason = str(j.get('reason') or '').strip()
                return {'excluded': True, 'matched': matched, 'reason': reason}
            return None
        if len(text) <= chunk_size:
            principles_lines = []
            if principles:
                for p in principles:
                    p = str(p).strip()
                    if p:
                        principles_lines.append(f"- {p}")
            fixed_lines = [
                f"- 仅用简体中文输出，严格限制在 {max_chars} 字以内；",
                "- 只保留关键信息与结论，去除冗余与复述；",
                "- 不逐篇复述，不重复相同主题的内容；",
                "- 尽可能采用符号化表达（例如 →, ⇒, ∵, ∴, ⟺, ∈, ⊆, ∀, ∃, ≈, ≡ 等）；",
                "- 保持术语/定义/符号前后一致，必要时用紧凑短句或分号分隔。",
            ]
            all_rules = "\n".join(principles_lines + fixed_lines)
            exclude_block = ''
            if blocked_topics:
                exclude_block = (
                    '【排除规则】\n'
                    f"- 若文本涉及下列任一主题（命中即可）：{topics_str}；\n"
                    '- 则不要进行摘要；只输出严格JSON：{"excluded": true, "matched": ["<命中主题原词>"], "reason": "<=60字"}；\n'
                    '- 仅输出上述JSON，不要包含其他文字或代码块围栏。\n\n'
                )
            prompt = (
                '你将收到一份按时间排列的多篇中文文档合并文本。若未命中排除主题，请进行“信息无损”的高度凝练压缩：\n'
                f"{all_rules}\n\n"
                f"{exclude_block}"
                '【合并文本】\n'
            )
            ok, out = _call(prompt + text)
            if ok and out:
                s = out.strip()
                if blocked_topics:
                    ex = _try_parse_exclusion(s)
                    if ex is not None:
                        return True, ex, None
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
                "- 仅用简体中文输出，严格限制在 400 字以内；",
                "- 术语/定义/符号前后一致，尽量符号化表达；",
            ]
            exclude_block2 = ''
            if blocked_topics:
                exclude_block2 = (
                    '【排除规则】\n'
                    f"- 若该部分文本涉及任一主题：{topics_str}；\n"
                    '- 则不要摘要；仅输出严格JSON：{"excluded": true, "matched": ["<命中主题原词>"], "reason": "<=60字"}；\n'
                    '- 仅输出上述JSON，不要包含其他文字或代码块围栏。\n\n'
                )
            prompt_part = (
                '以下是合并文档的一部分。若未命中排除主题，请提炼“信息无损”的关键要点：\n\n' +
                "\n".join(prompt_part_lines + prompt_part_fixed) +
                "\n\n" + exclude_block2
            )
            ok, out = _call(prompt_part + ch)
            s = (out or '').strip()
            if blocked_topics:
                ex = _try_parse_exclusion(s)
                if ex is not None:
                    return True, ex, None
            digests.append(s)
            if on_progress:
                try:
                    on_progress(i, len(chunks), s)
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
            f"- 仅用简体中文输出，严格限制在 {max_chars} 字以内；",
            "- 不逐条复述，合并同类项，去重；",
            "- 聚焦结论与独特信息；术语/定义/符号保持一致，尽量符号化表达。",
        ]
        exclude_block3 = ''
        if blocked_topics:
            exclude_block3 = (
                '【排除规则】\n'
                f"- 若整体涉及任一主题：{topics_str}；\n"
                '- 则不要摘要；仅输出严格JSON：{"excluded": true, "matched": ["<命中主题原词>"], "reason": "<=60字"}；\n'
                '- 仅输出上述JSON，不要包含其他文字或代码块围栏。\n\n'
            )
        final_prompt = (
            '你将收到若干分块摘要，请在“尽量信息无损”的前提下进行最终高度凝练：\n' +
            "\n".join(final_rules_lines + final_rules_fixed) +
            '\n\n' + exclude_block3 + '【分块摘要】\n'
        )
        ok, out = _call(final_prompt + joined)
        if ok and out:
            s = out.strip()
            if blocked_topics:
                ex = _try_parse_exclusion(s)
                if ex is not None:
                    return True, ex, None
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


def _load_existing_summaries(out_json: Path) -> Optional[List[Dict[str, Any]]]:
    """读取先前生成的精简 JSON 的 `files` 列表，用于断点续跑。

    若文件不存在或解析失败则返回 None。
    """
    try:
        if not out_json.exists():
            return None
        with out_json.open('r', encoding='utf-8') as f:
            data = json.load(f)
        files = data.get('files')
        if isinstance(files, list):
            return files
    except Exception:
        return None
    return None


def _rewrite_md_upto(out_md: Path, entries: List[Entry], upto: int, total: int, existing_summaries: List[Dict[str, Any]], title: str) -> None:
    """用已存在的摘要（索引区间 [0, upto)）重写 Markdown 头与对应片段。

    - 始终重写（覆盖） `out_md`，确保格式一致；
    - 文本内容使用 `existing_summaries[i]['summary']`；
    - 路径与时间信息取当前扫描的 `entries[i]`。
    """
    with out_md.open('w', encoding='utf-8', newline='\n') as fmd:
        fmd.write(f"# {title}\n\n")
        fmd.write(f"生成时间（UTC）：{datetime.now(timezone.utc).isoformat()}\n")
        fmd.write(f"合计文件：{total}\n\n")
        for i in range(max(0, upto)):
            if i >= len(entries):
                break
            e = entries[i]
            dt_utc = datetime.fromtimestamp(e.ts, tz=timezone.utc).isoformat()
            rel_posix = e.rel.as_posix()
            summary_text = ''
            try:
                summary_text = (existing_summaries[i].get('summary') or '').strip()
            except Exception:
                summary_text = ''
            fmd.write('---\n\n')
            fmd.write(f"## [{i+1}/{total}] {e.name}\n\n")
            fmd.write(f"- 源路径：`{rel_posix}`\n")
            fmd.write(f"- 时间戳：`{e.ts}`；UTC：`{dt_utc}`\n\n")
            fmd.write(summary_text + "\n\n")


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

    out_json = out_dir / f"{script_stem}.json"  # 精简版（逐项摘要）
    out_md = out_dir / f"{script_stem}.md"      # 逐项摘要 Markdown
    out_json_all = out_dir / f"{script_stem}_all.json"  # 完整合并（含全文）

    # 读取压缩设置
    compression_cfg = cfg.get('compression', {}) if isinstance(cfg.get('compression', {}), dict) else {}
    comp_enabled = bool(compression_cfg.get('enabled', False))
    comp_model_alias = str(compression_cfg.get('model', 'flash2.5'))
    # 环境变量优先覆盖模型（参考 script/print_env_ai.ps1）
    env_model = os.environ.get('GEMINI_MODEL')
    if env_model:
        comp_model_alias = env_model.strip()
    comp_max_chars = int(compression_cfg.get('max_chars', 500))
    comp_interval = float(compression_cfg.get('request_interval_seconds', 0) or 0)
    # 新增：每次运行的请求上限（>0 时，本次运行处理到达到上限即正常退出，便于分批执行）
    comp_max_requests_per_run = int(compression_cfg.get('max_requests_per_run', 0) or 0)
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

    # 内容检测配置（现推荐配置在 compression.content_guard；仍兼容顶层 content_guard）
    if isinstance(compression_cfg.get('content_guard', {}), dict):
        guard_cfg = compression_cfg.get('content_guard', {})
    else:
        guard_cfg = cfg.get('content_guard', {}) if isinstance(cfg.get('content_guard', {}), dict) else {}
    guard_enabled = bool(guard_cfg.get('enabled', False))
    guard_blocked_topics = guard_cfg.get('blocked_topics')
    if not isinstance(guard_blocked_topics, list):
        guard_blocked_topics = ['地缘政治', '金融市场', '量化交易', '法律工程']
    else:
        guard_blocked_topics = [str(x).strip() for x in guard_blocked_topics if str(x).strip()]

    # 1) 先输出完整合并 JSON（含全文）
    write_json(out_json_all, entries, source_dirs_raw, compression={
        'enabled': comp_enabled,
        'provider': 'gemini',
        'model_alias': comp_model_alias,
        'model_resolved': _gemini_model_from_alias(comp_model_alias),
        'max_chars': comp_max_chars,
        'principles': comp_principles,
    })
    _debug_print(f"[合并] 已写入完整 JSON（含全文）：{out_json_all}", '32')

    # 2) 逐项压缩并写入 Markdown（摘要）+ 失败重试 + 断点续跑
    md_title = f"{script_stem} 逐项摘要合并"

    # 如存在先前输出，尝试断点续跑（覆盖失败项）
    existing_files: Optional[List[Dict[str, Any]]] = None
    if out_md.exists() and out_json.exists():
        existing_files = _load_existing_summaries(out_json)
        if existing_files:
            _debug_print("[恢复] 检测到先前摘要输出，尝试从上次失败处续跑…", '33')

    # 计算恢复起点：按顺序比对 `path`/`filename` 与当前 entries 对齐段
    start_idx = 0
    if existing_files:
        n_align = min(len(existing_files), len(entries))
        for i in range(n_align):
            try:
                e = entries[i]
                rel_posix = e.rel.as_posix()
                ef = existing_files[i]
                if ef.get('path') != rel_posix or ef.get('filename') != e.name:
                    break
                comp_meta = ef.get('compression') or {}
                # 若该项为上次失败（特定错误），从该项开始覆盖
                if comp_meta.get('requested') and (comp_meta.get('ok') is False) and (comp_meta.get('error') == 'Gemini 无返回文本'):
                    break
                start_idx = i + 1
            except Exception:
                break

    # 重写 Markdown 到 start_idx（覆盖失败项；start_idx=0 时仅写头）
    _rewrite_md_upto(out_md, entries, start_idx, len(entries), existing_files or [], md_title)

    # 初始化 summaries 为已完成部分（用于继续写 JSON）
    summaries: List[Dict[str, Any]] = []
    if existing_files and start_idx > 0:
        for i in range(start_idx):
            e = entries[i]
            ef = existing_files[i]
            summaries.append({
                'path': e.rel.as_posix(),
                'filename': e.name,
                'timestamp': e.ts,
                'datetime_utc': datetime.fromtimestamp(e.ts, tz=timezone.utc).isoformat(),
                'summary': (ef.get('summary') or ''),
                'compression': ef.get('compression') or None,
            })
        comp_info_step = {
            'enabled': comp_enabled,
            'provider': 'gemini',
            'model_alias': comp_model_alias,
            'model_resolved': _gemini_model_from_alias(comp_model_alias),
            'max_chars': comp_max_chars,
            'principles': comp_principles,
        }
        write_json_summaries(out_json, summaries, source_dirs_raw, compression=comp_info_step)

    MAX_RETRY = 5
    RETRY_SLEEP = 3.0

    # 从 start_idx 开始继续处理
    requests_made_this_run = 0
    for idx in range(start_idx, len(entries)):
        e = entries[idx]
        _debug_print(f"[进度] {idx+1}/{len(entries)}：{e.name}", '36')
        dt_utc = datetime.fromtimestamp(e.ts, tz=timezone.utc).isoformat()
        rel_posix = e.rel.as_posix()

        # 内容检测状态（用于记录到 JSON）
        guard_requested: bool = False
        guard_hit: Optional[bool] = None
        guard_err: Optional[str] = None
        guard_matched: List[str] = []

        summary_requested: bool = False
        summary_ok: Optional[bool] = None
        summary_err: Optional[str] = None
        summary_text: Optional[str] = None

        pure = (e.content or '').strip()
        # 排除逻辑在提交 LLM 压缩请求时顺便判断
        if comp_enabled and pure:
            summary_requested = True
            if guard_enabled and guard_blocked_topics:
                guard_requested = True
            attempt = 0
            while True:
                # 首次尝试前按配置等待；后续重试不再二次等待，避免与重试睡眠叠加
                if attempt == 0 and comp_interval and comp_interval > 0:
                    _debug_print(f"[Gemini] 等待 {comp_interval}s 后发起请求…", '33')
                    time.sleep(comp_interval)
                ok, res, err = run_gemini_summary(
                    pure, comp_model_alias, comp_max_chars, 0.0, on_progress=None,
                    principles=comp_principles,
                    blocked_topics=(guard_blocked_topics if guard_enabled and guard_blocked_topics else None)
                )
                # 统计本次运行已发起的请求次数（包含排除/失败/成功）
                requests_made_this_run += 1
                if ok and res is not None:
                    # 若返回为排除 JSON，则直接写入占位并进入下一项
                    if isinstance(res, dict) and res.get('excluded'):
                        guard_hit = True
                        guard_matched = list(res.get('matched') or [])
                        # 写入 Markdown 占位提示
                        with out_md.open('a', encoding='utf-8', newline='\n') as fmd:
                            fmd.write('---\n\n')
                            fmd.write(f"## [{idx+1}/{len(entries)}] {e.name}\n\n")
                            fmd.write(f"- 源路径：`{rel_posix}`\n")
                            fmd.write(f"- 时间戳：`{e.ts}`；UTC：`{dt_utc}`\n\n")
                            mt = '、'.join(sorted(set(guard_matched))) if guard_matched else '命中受限主题'
                            fmd.write(f"提示：该条目涉及受限主题（{mt}），已按配置跳过摘要处理。\n\n")

                        summaries.append({
                            'path': rel_posix,
                            'filename': e.name,
                            'timestamp': e.ts,
                            'datetime_utc': dt_utc,
                            'summary': '',
                            'compression': {
                                'enabled': comp_enabled,
                                'requested': True,
                                'ok': True,
                                'error': None,
                            },
                            'content_guard': {
                                'enabled': guard_enabled,
                                'provider': 'gemini',
                                'requested': guard_requested,
                                'hit': True,
                                'matched_topics': sorted(set(guard_matched)),
                                'error': None,
                            },
                            'skipped': True,
                        })

                        comp_info_step_guard2 = {
                            'enabled': comp_enabled,
                            'provider': 'gemini',
                            'model_alias': comp_model_alias,
                            'model_resolved': _gemini_model_from_alias(comp_model_alias),
                            'max_chars': comp_max_chars,
                            'principles': comp_principles,
                        }
                        write_json_summaries(out_json, summaries, source_dirs_raw, compression=comp_info_step_guard2)

                        # 达到请求上限则正常结束
                        if comp_enabled and comp_max_requests_per_run > 0 and requests_made_this_run >= comp_max_requests_per_run:
                            remaining = len(entries) - (idx + 1)
                            print(
                                f"已按配置处理 {requests_made_this_run} 篇（达到每次运行请求上限：{comp_max_requests_per_run}）。"
                            )
                            print(f"已输出中间结果：{out_md} 与 {out_json}。剩余待处理：{remaining} 篇；下次运行将从断点继续。")
                            return 0
                        # 跳过当前条目
                        break
                    # 正常摘要文本
                    if isinstance(res, str):
                        summary_ok, summary_text, summary_err = True, res, None
                        break
                if (not ok) and (err == 'Gemini 无返回文本') and (attempt < MAX_RETRY):
                    attempt += 1
                    _debug_print(f"[Gemini] 无返回文本，{RETRY_SLEEP}s 后重试（{attempt}/{MAX_RETRY}）…", '33')
                    time.sleep(RETRY_SLEEP)
                    continue
                summary_ok, summary_text, summary_err = False, None, err
                if err == 'Gemini 无返回文本' and attempt >= MAX_RETRY:
                    print(f"达到最大重试次数（{MAX_RETRY}），在第 {idx+1} 项失败：{e.name}。中断退出以便稍后重试。")
                    comp_info_step2 = {
                        'enabled': comp_enabled,
                        'provider': 'gemini',
                        'model_alias': comp_model_alias,
                        'model_resolved': _gemini_model_from_alias(comp_model_alias),
                        'max_chars': comp_max_chars,
                        'principles': comp_principles,
                    }
                    write_json_summaries(out_json, summaries, source_dirs_raw, compression=comp_info_step2)
                    return 2
                break

            # 如被判定排除，则跳过摘要写入逻辑
            if guard_hit is True:
                continue

            if not summary_text:
                summary_text = (pure[:comp_max_chars] + ('……' if len(pure) > comp_max_chars else ''))
        else:
            summary_text = (pure[:comp_max_chars] + ('……' if len(pure) > comp_max_chars else '')) if pure else ''

        with out_md.open('a', encoding='utf-8', newline='\n') as fmd:
            fmd.write('---\n\n')
            fmd.write(f"## [{idx+1}/{len(entries)}] {e.name}\n\n")
            fmd.write(f"- 源路径：`{rel_posix}`\n")
            fmd.write(f"- 时间戳：`{e.ts}`；UTC：`{dt_utc}`\n\n")
            fmd.write((summary_text or '').strip() + "\n\n")

        summaries.append({
            'path': rel_posix,
            'filename': e.name,
            'timestamp': e.ts,
            'datetime_utc': dt_utc,
            'summary': summary_text,
            'compression': {
                'enabled': comp_enabled,
                'requested': summary_requested,
                'ok': summary_ok if summary_requested else None,
                'error': summary_err if summary_requested else None,
            },
            'content_guard': {
                'enabled': guard_enabled,
                'provider': 'gemini',
                'requested': guard_requested,
                'hit': guard_hit if guard_hit is not None else False,
                'matched_topics': sorted(set(guard_matched)) if guard_matched else [],
                'error': guard_err,
            },
            'skipped': False,
        })

        comp_info_step = {
            'enabled': comp_enabled,
            'provider': 'gemini',
            'model_alias': comp_model_alias,
            'model_resolved': _gemini_model_from_alias(comp_model_alias),
            'max_chars': comp_max_chars,
            'principles': comp_principles,
        }
        write_json_summaries(out_json, summaries, source_dirs_raw, compression=comp_info_step)

        # 若配置了“每次运行请求上限”，达到后立即正常结束（便于分批执行与限速）
        if comp_enabled and comp_max_requests_per_run > 0 and requests_made_this_run >= comp_max_requests_per_run:
            remaining = len(entries) - (idx + 1)
            print(
                f"已按配置处理 {requests_made_this_run} 篇（达到每次运行请求上限：{comp_max_requests_per_run}）。"
            )
            print(f"已输出中间结果：{out_md} 与 {out_json}。剩余待处理：{remaining} 篇；下次运行将从断点继续。")
            return 0

    _debug_print(f"[合并] 已写入 Markdown：{out_md}", '32')

    # 3) 写入精简 JSON（仅包含逐项摘要）
    comp_info = {
        'enabled': comp_enabled,
        'provider': 'gemini',
        'model_alias': comp_model_alias,
        'model_resolved': _gemini_model_from_alias(comp_model_alias),
        'max_chars': comp_max_chars,
        'principles': comp_principles,
    }
    write_json_summaries(out_json, summaries, source_dirs_raw, compression=comp_info)
    _debug_print(f"[合并] 已写入 JSON（摘要）：{out_json}", '32')

    print(f"完成：JSON（全文） -> {out_json_all}")
    print(f"完成：JSON（摘要） -> {out_json}")
    print(f"完成：Markdown（摘要） -> {out_md}")
    print(f"总计合并文件数：{len(entries)}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
