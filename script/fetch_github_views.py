#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2025 GaoZheng
"""
通过 GitHub REST API 获取仓库最近 14 天（可选日/周粒度）的访问量视图数据。

使用前请设置环境变量 `GITHUB_TOKEN`（具备 `repo` 或最少 `public_repo` 权限）。
示例：
    python3 script/fetch_github_views.py --owner CTaiDeng --repo open_meta_mathematical_theory --per day
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime
from typing import Any, Dict
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

API_VERSION = "2022-11-28"
DEFAULT_OWNER = "CTaiDeng"
DEFAULT_REPO = "open_meta_mathematical_theory"
DEFAULT_PER = "day"
TIMEOUT = 20


def _get_token() -> str:
    token = os.getenv("GITHUB_TOKEN")
    if not token:
        raise SystemExit("缺少环境变量 GITHUB_TOKEN，无法请求 GitHub API。")
    return token


def _fetch_views(owner: str, repo: str, per: str) -> Dict[str, Any]:
    url = f"https://api.github.com/repos/{owner}/{repo}/traffic/views?per={per}"
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {_get_token()}",
        "X-GitHub-Api-Version": API_VERSION,
        "User-Agent": "github-traffic-fetcher/1.0",
    }
    req = Request(url, headers=headers)
    try:
        with urlopen(req, timeout=TIMEOUT) as resp:
            if resp.status != 200:
                raise SystemExit(f"请求失败，状态码 {resp.status}")
            return json.load(resp)
    except HTTPError as exc:
        raise SystemExit(f"HTTPError: {exc.code} {exc.reason}") from exc
    except URLError as exc:
        raise SystemExit(f"URLError: {exc.reason}") from exc


def _fetch_clones(owner: str, repo: str, per: str) -> Dict[str, Any]:
    url = f"https://api.github.com/repos/{owner}/{repo}/traffic/clones?per={per}"
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {_get_token()}",
        "X-GitHub-Api-Version": API_VERSION,
        "User-Agent": "github-traffic-fetcher/1.0",
    }
    req = Request(url, headers=headers)
    try:
        with urlopen(req, timeout=TIMEOUT) as resp:
            if resp.status != 200:
                raise SystemExit(f"请求失败，状态码 {resp.status}")
            return json.load(resp)
    except HTTPError as exc:
        raise SystemExit(f"HTTPError: {exc.code} {exc.reason}") from exc
    except URLError as exc:
        raise SystemExit(f"URLError: {exc.reason}") from exc


def _parse_timestamp(ts: str) -> str:
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        return dt.date().isoformat()
    except ValueError:
        return ts


def _print_views(data: Dict[str, Any], per: str) -> None:
    views = data.get("views", [])
    total = data.get("count", "N/A")
    uniques = data.get("uniques", "N/A")

    print(f"[Views] 粒度：{per}；总访问量：{total}；独立访客：{uniques}")
    print("日期\t\tcount\tuniques")
    for item in views:
        date = _parse_timestamp(str(item.get("timestamp", "")))
        count = item.get("count", "N/A")
        unique = item.get("uniques", "N/A")
        print(f"{date}\t{count}\t{unique}")


def _print_clones(data: Dict[str, Any], per: str) -> None:
    clones = data.get("clones", [])
    total = data.get("count", "N/A")
    uniques = data.get("uniques", "N/A")

    print(f"[Clones] 粒度：{per}；总克隆数：{total}；独立克隆者：{uniques}")
    print("日期\t\tcount\tuniques")
    for item in clones:
        date = _parse_timestamp(str(item.get("timestamp", "")))
        count = item.get("count", "N/A")
        unique = item.get("uniques", "N/A")
        print(f"{date}\t{count}\t{unique}")


def _print_summary(views_data: Dict[str, Any], clones_data: Dict[str, Any]) -> None:
    clones_total = clones_data.get("count", "N/A")
    clones_uniques = clones_data.get("uniques", "N/A")
    views_total = views_data.get("count", "N/A")
    views_uniques = views_data.get("uniques", "N/A")

    print("Clones in last 14 days:", clones_total)
    print("Unique cloners in last 14 days:", clones_uniques)
    print("Total views in last 14 days:", views_total)
    print("Unique visitors in last 14 days:", views_uniques)


def get_traffic(
    owner: str = DEFAULT_OWNER,
    repo: str = DEFAULT_REPO,
    per: str = DEFAULT_PER,
) -> Dict[str, Any]:
    """
    供其他脚本调用的 API：返回 GitHub traffic 的原始 JSON 与简要汇总。

    返回结构示例：
    {
        "owner": "...",
        "repo": "...",
        "per": "day",
        "views": {...},   # /traffic/views 原始响应
        "clones": {...},  # /traffic/clones 原始响应
        "summary": {
            "clones_total": int,
            "clones_uniques": int,
            "views_total": int,
            "views_uniques": int,
            "per": "day"
        }
    }
    """
    views_data = _fetch_views(owner, repo, per)
    clones_data = _fetch_clones(owner, repo, per)

    def _to_int(value: Any) -> int:
        try:
            return int(value)
        except (TypeError, ValueError):
            return 0

    summary = {
        "clones_total": _to_int(clones_data.get("count")),
        "clones_uniques": _to_int(clones_data.get("uniques")),
        "views_total": _to_int(views_data.get("count")),
        "views_uniques": _to_int(views_data.get("uniques")),
        "per": per,
    }

    return {
        "owner": owner,
        "repo": repo,
        "per": per,
        "views": views_data,
        "clones": clones_data,
        "summary": summary,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="获取 GitHub 仓库最近 14 天访问量（views）与克隆量（clones）数据。"
    )
    parser.add_argument("--owner", default=DEFAULT_OWNER, help="仓库拥有者，默认 CTaiDeng")
    parser.add_argument("--repo", default=DEFAULT_REPO, help="仓库名，默认 open_meta_mathematical_theory")
    parser.add_argument("--per", choices=["day", "week"], default=DEFAULT_PER, help="视图粒度，day 或 week")
    args = parser.parse_args()

    traffic = get_traffic(args.owner, args.repo, args.per)
    views_data = traffic["views"]
    clones_data = traffic["clones"]

    _print_summary(views_data, clones_data)
    print()
    _print_views(views_data, args.per)
    print()
    _print_clones(clones_data, args.per)


if __name__ == "__main__":
    main()
