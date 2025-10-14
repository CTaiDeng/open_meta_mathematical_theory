#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2025 GaoZheng

"""
Minimal filters for commit message generation.

Exports:
- collect_diff_filtered(max_patch_chars=8000) -> tuple[str, str]
  Returns (name-status, unified=0 patch) for staged changes, with size limit.

Notes:
- Keep simple: do not introduce repo-specific rules unless requested.
"""

from __future__ import annotations

import subprocess
from typing import Tuple


def _run(cmd: list[str]) -> str:
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.STDOUT)
        return out.decode("utf-8", errors="replace")
    except subprocess.CalledProcessError as e:
        return e.output.decode("utf-8", errors="replace")


def collect_diff_filtered(max_patch_chars: int = 8000) -> Tuple[str, str]:
    """Collect staged diff with a conservative size cap.

    - Returns a name-status list and a unified=0 patch of staged changes.
    - The patch string is truncated to `max_patch_chars` to avoid overlong prompts.
    """
    stat = _run(["git", "diff", "--staged", "--name-status"]).strip()
    patch = _run(["git", "diff", "--staged", "--unified=0"]).strip()
    if len(patch) > max_patch_chars:
        patch = patch[: max_patch_chars - 1] + "\n...(truncated)"
    return stat, patch

