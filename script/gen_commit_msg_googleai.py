#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2025 GaoZheng

"""
使用 Google Generative AI（Gemini）或本地回退逻辑生成简体中文提交信息。

环境变量
- GEMINI_API_KEY 或 GOOGLE_API_KEY：Google AI Studio API Key
- GEMINI_MODEL：可覆盖默认模型（默认 gemini-2.5-flash）
- COMMIT_MSG_LANG：语言（zh/en，默认 zh）

依赖
- python -m pip install google-generativeai  （可选，若不安装将自动回退）

用法
- 由 Git 钩子调用：生成提交信息到标准输出
"""

from __future__ import annotations

import os
import subprocess
import sys
from typing import Optional, Tuple

from commit_filters import collect_diff_filtered


def _run(cmd: list[str]) -> str:
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.STDOUT)
        return out.decode("utf-8", errors="replace")
    except subprocess.CalledProcessError as e:
        return e.output.decode("utf-8", errors="replace")


def collect_diff(max_patch_chars: int = 8000) -> Tuple[str, str]:
    stat = _run(["git", "diff", "--staged", "--name-status"]).strip()
    patch = _run(["git", "diff", "--staged", "--unified=0"]).strip()
    if len(patch) > max_patch_chars:
        patch = patch[: max_patch_chars - 1] + "\n...(truncated)"
    return stat, patch


def build_prompt(stat: str, patch: str, lang: str) -> str:
    lang = (lang or "zh").lower()
    if lang == "en":
        return (
            "Please read the staged Git changes and produce a concise commit message.\n"
            "- First line <= 60 chars in `type: subject`, type in {feat, fix, docs, chore, refactor, test, perf, build, ci}.\n"
            "- Then list 1-3 bullet points, each one line starting with `- `.\n"
            "- Output in English only.\n\n"
            "Name-status list:\n{stat}\n\n"
            "Diff patch (may be truncated):\n{patch}\n"
        ).format(stat=stat, patch=patch)
    # default zh
    return (
        "请阅读已暂存的 Git 变更并生成精炼的提交信息。\n"
        "- 第一行不超过 60 字，格式为 `type: subject`，type ∈ {feat, fix, docs, chore, refactor, test, perf, build, ci}。\n"
        "- 其后列出 1-3 个要点，每行以 `- ` 开头。\n"
        "- 仅输出简体中文内容。\n\n"
        "变更清单（name-status）：\n{stat}\n\n"
        "差异补丁（可能已截断）：\n{patch}\n"
    ).format(stat=stat, patch=patch)


def generate_with_gemini(prompt: str) -> Optional[str]:
    api_key = os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY")
    if not api_key:
        return None
    try:
        import google.generativeai as genai  # type: ignore
    except Exception:
        return None
    try:
        genai.configure(api_key=api_key)
        model_name = os.environ.get("GEMINI_MODEL", "gemini-2.5-flash")
        model = genai.GenerativeModel(model_name)
        resp = model.generate_content(prompt)
        text = getattr(resp, "text", None)
        if not text and hasattr(resp, "candidates") and resp.candidates:
            parts = []
            for c in resp.candidates:
                try:
                    parts.append(c.content.parts[0].text)
                except Exception:
                    continue
            text = "\n".join([p for p in parts if p])
        if text:
            return text.strip()
        return None
    except Exception:
        return None


def fallback_summary(stat: str) -> str:
    lines = [ln for ln in stat.splitlines() if ln.strip()]
    added = sum(1 for ln in lines if ln.startswith("A\t"))
    modified = sum(1 for ln in lines if ln.startswith("M\t"))
    deleted = sum(1 for ln in lines if ln.startswith("D\t"))
    renamed = sum(1 for ln in lines if ln.startswith("R"))
    total = len(lines)
    top_files = ", ".join([ln.split("\t")[-1] for ln in lines[:3]])
    lang = os.environ.get("COMMIT_MSG_LANG", "zh").lower()
    if lang == "en":
        head = "chore: update"
        detail = []
        if total:
            detail.append(f"- files: {total} (A{added}/M{modified}/D{deleted}/R{renamed})")
        if top_files:
            detail.append(f"- sample: {top_files}")
        return "\n".join([head] + detail)
    head = "chore: 更新"
    detail = []
    if total:
        detail.append(f"- 文件: {total} (A{added}/M{modified}/D{deleted}/R{renamed})")
    if top_files:
        detail.append(f"- 示例: {top_files}")
    return "\n".join([head] + detail)


def main() -> int:
    stat, patch = collect_diff_filtered()
    lang = os.environ.get("COMMIT_MSG_LANG", "zh").lower()
    if not stat and not patch:
        print("chore: 更新（无暂存更改）" if lang != "en" else "chore: update (no staged changes)")
        return 0
    prompt = build_prompt(stat, patch, lang)
    text = generate_with_gemini(prompt)
    if not text:
        text = fallback_summary(stat)
    print(text.strip())
    return 0


if __name__ == "__main__":
    sys.exit(main())

