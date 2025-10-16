#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Copyright (C) 2025 GaoZheng
# SPDX-License-Identifier: GPL-3.0-only
# This file is part of this project.
# Licensed under the GNU General Public License version 3.
# See https://www.gnu.org/licenses/gpl-3.0.html for details.
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2025 GaoZheng

"""
Gemini 长文本通信探针（简体中文）。

作用
- 直连 Gemini 生成约 800~1200 字中文段落，便于验证网络与鉴权是否正常。

依赖
- google-generativeai（未安装将直接返回错误码）
  Windows: .venv\Scripts\python.exe -m pip install --no-cache-dir google-generativeai
  POSIX:   .venv/bin/python3 -m pip install --no-cache-dir google-generativeai

API Key 解析顺序（任一来源即可）
1) 环境变量：GEMINI_API_KEY 或 GOOGLE_API_KEY
2) 文件：.githooks/.gemini_api_key（第一行）
3) Git 配置：gemini.apiKey（本地配置优先）

模型解析顺序
1) 环境变量：GEMINI_MODEL
2) 文件：.githooks/.gemini_model（第一行）
3) Git 配置：gemini.model
4) 默认：gemini-2.5-pro

退出码
 0 正常（输出长度 >= 200）
 2 无 API Key
 3 未安装 google-generativeai
 5 其它错误
"""

from __future__ import annotations

import os
import sys
import subprocess
from typing import Optional


def _run(cmd: list[str]) -> str:
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL)
        return out.decode("utf-8", errors="replace").strip()
    except Exception:
        return ""


def _root() -> str:
    return _run(["git", "rev-parse", "--show-toplevel"]) or os.getcwd()


def _load_key() -> Optional[str]:
    key = os.getenv("GEMINI_API_KEY") or os.getenv("GOOGLE_API_KEY")
    if key:
        return key.strip()
    p = os.path.join(_root(), ".githooks", ".gemini_api_key")
    try:
        if os.path.isfile(p):
            with open(p, "r", encoding="utf-8") as f:
                line = f.readline().strip()
                if line:
                    return line
    except Exception:
        pass
    cfg = _run(["git", "config", "--get", "gemini.apiKey"]).strip()
    return cfg or None


def _load_model() -> str:
    m = os.getenv("GEMINI_MODEL")
    if m:
        return m
    p = os.path.join(_root(), ".githooks", ".gemini_model")
    try:
        if os.path.isfile(p):
            with open(p, "r", encoding="utf-8") as f:
                line = f.readline().strip()
                if line:
                    return line
    except Exception:
        pass
    cfg = _run(["git", "config", "--get", "gemini.model"]).strip()
    return cfg or "gemini-2.5-pro"


def main() -> int:
    # 尽量让输出为 UTF-8，避免终端乱码（不要求一定成功）
    try:
        if hasattr(sys.stdout, "reconfigure"):
            sys.stdout.reconfigure(encoding="utf-8")
        if hasattr(sys.stderr, "reconfigure"):
            sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

    key = _load_key()
    if not key:
        print("[probe] no api key", file=sys.stderr)
        return 2
    model = _load_model()

    try:
        import google.generativeai as genai  # type: ignore
    except Exception as e:
        print(f"[probe] missing google-generativeai: {e}", file=sys.stderr)
        return 3

    genai.configure(api_key=key)
    prompt = (
        "请用简体中文输出约800~1200字的连续段落，"
        "主题为“系统设计中的一致性与可用性权衡（CAP）”，"
        "不使用项目符号或小标题，不插入代码块，保持行文自然连贯。"
    )

    try:
        generation_config = {"max_output_tokens": 2048, "temperature": 0.7}
        model_obj = genai.GenerativeModel(model)
        resp = model_obj.generate_content(prompt, generation_config=generation_config)
        text = getattr(resp, "text", None)
        if not text and getattr(resp, "candidates", None):
            parts = []
            for c in resp.candidates:
                try:
                    parts.append(c.content.parts[0].text)
                except Exception:
                    pass
            text = "\n".join([p for p in parts if p])
        text = (text or "").strip()
        print(f"[probe] model={model}", file=sys.stderr)
        print(f"[probe] chars={len(text)}", file=sys.stderr)
        print(text)
        return 0 if len(text) >= 200 else 5
    except Exception as e:
        print(f"[probe] error={e.__class__.__name__}: {e}", file=sys.stderr)
        return 5


if __name__ == "__main__":
    raise SystemExit(main())


