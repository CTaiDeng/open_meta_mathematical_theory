#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# SPDX-License-Identifier: GPL-3.0-only
#
# Copyright (C) 2025 GaoZheng
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, version 3.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#
# ---
#
# This file is part of a modified version of the GROMACS molecular simulation package.
# For details on the original project, consult https://www.gromacs.org.
#
# To help fund GROMACS development, we humbly ask that you cite
# the research papers on the package. Check out https://www.gromacs.org.

from __future__ import annotations

import datetime as _datetime
import json
import re
from pathlib import Path
from typing import Any, Dict
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

ZENODO_RECORD_URL = "https://zenodo.org/api/records/17651584"
OUTPUT_FILENAME = "zenodo_17651584_stats.md"
REPO_ROOT = Path(__file__).resolve().parents[1]
OUTPUT_PATH = REPO_ROOT / OUTPUT_FILENAME
README_PATH = REPO_ROOT / "README.md"
START_MARKER = "<!-- ZENODO_STATS_START -->"
END_MARKER = "<!-- ZENODO_STATS_END -->"
REQUEST_TIMEOUT_SECONDS = 20


def _safe_ratio(numerator: int, denominator: int) -> float | None:
    if denominator == 0:
        return None
    return round(numerator / denominator, 2)


def _fmt_ratio(value: float | None) -> str:
    return "N/A" if value is None else f"{value:.2f}"


def fetch_record(url: str) -> Dict[str, Any]:
    request = Request(url, headers={"User-Agent": "zenodo-stats-fetcher/1.0"})
    with urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
        if response.status != 200:
            raise RuntimeError(f"请求失败，状态码 {response.status}")
        return json.load(response)


def build_markdown(stats: Dict[str, Any]) -> str:
    downloads = int(stats.get("downloads", 0))
    unique_downloads = int(stats.get("unique_downloads", 0))
    views = int(stats.get("views", 0))
    unique_views = int(stats.get("unique_views", 0))
    version_downloads = int(stats.get("version_downloads", 0))
    version_unique_downloads = int(stats.get("version_unique_downloads", 0))
    version_views = int(stats.get("version_views", 0))
    version_unique_views = int(stats.get("version_unique_views", 0))

    avg_downloads_per_user = _safe_ratio(downloads, unique_downloads)
    avg_views_per_user = _safe_ratio(views, unique_views)
    download_view_conversion = _safe_ratio(downloads, views)
    unique_download_view_conversion = _safe_ratio(unique_downloads, unique_views)

    version_in_sync = all(
        (
            downloads == version_downloads,
            unique_downloads == version_unique_downloads,
            views == version_views,
            unique_views == version_unique_views,
        )
    )

    tz_beijing = _datetime.timezone(_datetime.timedelta(hours=8))
    fetched_at = (
        _datetime.datetime.now(_datetime.timezone.utc)
        .astimezone(tz_beijing)
        .strftime("%Y-%m-%d %H:%M 北京时间")
    )

    lines = [
        "# Zenodo 记录 17651584 访问统计解读",
        "",
        "## 核心指标",
        f"- 数据源：{ZENODO_RECORD_URL}",
        f"- 拉取时间：{fetched_at}",
        f"- 下载量：{downloads} 次；独立下载 {unique_downloads} 次（人均 {_fmt_ratio(avg_downloads_per_user)} 次）",
        f"- 浏览量：{views} 次；独立访客 {unique_views} 次（人均 {_fmt_ratio(avg_views_per_user)} 次）",
        f"- 下载/浏览转化率：总体 {_fmt_ratio(download_view_conversion)}，独立 {_fmt_ratio(unique_download_view_conversion)}",
        "",
        "## 版本层级",
        "- 版本统计与总计一致，当前仅看到一个版本的数据。" if version_in_sync else "- 版本字段与总体不一致，需进一步核对。",
        "",
        "## 原始数值",
        f"- downloads：{downloads}",
        f"- unique_downloads：{unique_downloads}",
        f"- views：{views}",
        f"- unique_views：{unique_views}",
        f"- version_downloads：{version_downloads}",
        f"- version_unique_downloads：{version_unique_downloads}",
        f"- version_views：{version_views}",
        f"- version_unique_views：{version_unique_views}",
        "",
    ]

    return "\n".join(lines)


def write_markdown(content: str) -> None:
    with OUTPUT_PATH.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write(content)


def extract_core_metrics(md_path: Path) -> str:
    lines = md_path.read_text(encoding="utf-8").splitlines()
    captured: list[str] = []
    in_section = False
    for line in lines:
        if line.strip() == "## 核心指标":
            in_section = True
        if in_section:
            if line.startswith("## ") and line.strip() != "## 核心指标":
                break
            captured.append(line)
    result = "\n".join(captured).strip()
    if not result:
        raise SystemExit("未能在统计文件中提取“## 核心指标”段落。")
    return result


def inject_into_readme(core_md: str) -> None:
    readme_text = README_PATH.read_text(encoding="utf-8")
    block = f"{START_MARKER}\n{core_md}\n{END_MARKER}"

    if START_MARKER in readme_text and END_MARKER in readme_text:
        pattern = re.compile(
            re.escape(START_MARKER) + r".*?" + re.escape(END_MARKER), re.DOTALL
        )
        new_text = pattern.sub(block, readme_text)
    else:
        anchor = "Zenodo. https://doi.org/10.5281/zenodo.17651584"
        insert_pos = readme_text.find(anchor)
        if insert_pos == -1:
            raise SystemExit("未能在 README 中找到插入锚点。")
        insert_pos += len(anchor)
        new_text = (
            readme_text[:insert_pos] + "\n\n" + block + "\n" + readme_text[insert_pos:]
        )

    with README_PATH.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write(new_text)


def main() -> None:
    try:
        record = fetch_record(ZENODO_RECORD_URL)
    except (HTTPError, URLError, TimeoutError, RuntimeError) as exc:
        raise SystemExit(f"拉取数据失败：{exc}")

    stats = record.get("stats")
    if not isinstance(stats, dict):
        raise SystemExit("响应中缺少 stats 字段，无法解读。")

    write_markdown(build_markdown(stats))
    inject_into_readme(extract_core_metrics(OUTPUT_PATH))
    relative_output = OUTPUT_PATH.relative_to(REPO_ROOT)
    print(f"已生成 {relative_output} 并更新 README.md")


if __name__ == "__main__":
    main()
