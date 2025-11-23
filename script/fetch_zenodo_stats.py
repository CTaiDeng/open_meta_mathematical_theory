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
import csv
import json
import re
from pathlib import Path
from dataclasses import dataclass
from typing import Any, Dict
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

REPO_ROOT = Path(__file__).resolve().parents[1]
OUTPUT_PATH = REPO_ROOT / "zenodo_stats.md"
README_PATH = REPO_ROOT / "README.md"
START_MARKER = "<!-- ZENODO_STATS_START -->"
END_MARKER = "<!-- ZENODO_STATS_END -->"
OUT_DIR = REPO_ROOT / "out"
REQUEST_TIMEOUT_SECONDS = 20
SVG_WIDTH = 900
SVG_HEIGHT = 700
TZ_BEIJING = _datetime.timezone(_datetime.timedelta(hours=8))


@dataclass(frozen=True)
class RecordSpec:
    name: str
    record_id: str
    doi: str

    @property
    def api_url(self) -> str:
        return f"https://zenodo.org/api/records/{self.record_id}"

    @property
    def csv_path(self) -> Path:
        return OUT_DIR / f"zenodo_{self.record_id}_stats.csv"

    @property
    def svg_path(self) -> Path:
        return OUT_DIR / f"zenodo_{self.record_id}_stats.svg"


RECORDS = [
    RecordSpec(
        name="纯粹数学",
        record_id="17651584",
        doi="10.5281/zenodo.17651584",
    ),
    RecordSpec(
        name="应用数学·第1卷",
        record_id="17685524",
        doi="10.5281/zenodo.17685524",
    ),
]


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


def build_markdown(record: RecordSpec, stats: Dict[str, Any], fetched_at_text: str) -> str:
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

    lines = [
        f"# {record.name}（Zenodo 记录 {record.record_id}）访问统计解读",
        "",
        "## 核心指标",
        f"- 数据源：{record.api_url}",
        f"- 拉取时间：{fetched_at_text}",
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


def build_core_metrics(record: RecordSpec, stats: Dict[str, Any], fetched_at_text: str) -> str:
    downloads = int(stats.get("downloads", 0))
    unique_downloads = int(stats.get("unique_downloads", 0))
    views = int(stats.get("views", 0))
    unique_views = int(stats.get("unique_views", 0))

    avg_downloads_per_user = _safe_ratio(downloads, unique_downloads)
    avg_views_per_user = _safe_ratio(views, unique_views)
    download_view_conversion = _safe_ratio(downloads, views)
    unique_download_view_conversion = _safe_ratio(unique_downloads, unique_views)

    return "\n".join(
        [
            f"## {record.name}（Zenodo 记录 {record.record_id}）",
            f"- 数据源：{record.api_url}",
            f"- 拉取时间：{fetched_at_text}",
            f"- 下载量：{downloads} 次；独立下载 {unique_downloads} 次（人均 {_fmt_ratio(avg_downloads_per_user)} 次）",
            f"- 浏览量：{views} 次；独立访客 {unique_views} 次（人均 {_fmt_ratio(avg_views_per_user)} 次）",
            f"- 下载/浏览转化率：总体 {_fmt_ratio(download_view_conversion)}，独立 {_fmt_ratio(unique_download_view_conversion)}",
        ]
    )


def inject_into_readme(core_sections: list[str]) -> None:
    readme_text = README_PATH.read_text(encoding="utf-8")
    core_md = "\n\n".join(core_sections)
    block = f"{START_MARKER}\n{core_md}\n{END_MARKER}"

    if START_MARKER in readme_text and END_MARKER in readme_text:
        pattern = re.compile(
            re.escape(START_MARKER) + r".*?" + re.escape(END_MARKER), re.DOTALL
        )
        new_text = pattern.sub(block, readme_text)
    else:
        anchors = [
            "Zenodo. https://doi.org/10.5281/zenodo.17685524",
            "Zenodo. https://doi.org/10.5281/zenodo.17651584",
        ]
        insert_pos = -1
        for anchor in anchors:
            insert_pos = readme_text.find(anchor)
            if insert_pos != -1:
                insert_pos += len(anchor)
                break
        if insert_pos == -1:
            raise SystemExit("未能在 README 中找到插入锚点。")
        new_text = (
            readme_text[:insert_pos] + "\n\n" + block + "\n" + readme_text[insert_pos:]
        )

    with README_PATH.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write(new_text)


def append_timeseries(
    record: RecordSpec, stats: Dict[str, Any], fetched_at_dt: _datetime.datetime
) -> list[dict[str, str]]:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "timestamp",
        "downloads",
        "unique_downloads",
        "views",
        "unique_views",
        "version_downloads",
        "version_unique_downloads",
        "version_views",
        "version_unique_views",
    ]
    rows: list[dict[str, str]] = []
    if record.csv_path.exists():
        with record.csv_path.open("r", encoding="utf-8") as fh:
            reader = csv.DictReader(fh)
            for row in reader:
                if row:
                    rows.append(row)

    new_row = {
        "timestamp": fetched_at_dt.isoformat(timespec="seconds"),
        "downloads": str(int(stats.get("downloads", 0))),
        "unique_downloads": str(int(stats.get("unique_downloads", 0))),
        "views": str(int(stats.get("views", 0))),
        "unique_views": str(int(stats.get("unique_views", 0))),
        "version_downloads": str(int(stats.get("version_downloads", 0))),
        "version_unique_downloads": str(int(stats.get("version_unique_downloads", 0))),
        "version_views": str(int(stats.get("version_views", 0))),
        "version_unique_views": str(int(stats.get("version_unique_views", 0))),
    }
    rows.append(new_row)

    with record.csv_path.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)

    return rows


def _scale_points(
    values: list[int],
    width: float,
    height: float,
    margin_left: float,
    margin_right: float,
    margin_top: float,
    margin_bottom: float,
    min_val: float,
    max_val: float,
) -> list[tuple[float, float]]:
    usable_w = width - margin_left - margin_right
    usable_h = height - margin_top - margin_bottom
    count = len(values)
    if count == 1:
        xs = [margin_left + usable_w / 2]
    else:
        xs = [
            margin_left + (usable_w * idx) / (count - 1)
            for idx in range(count)
        ]
    if max_val == min_val:
        max_val += 1
        min_val -= 1

    def to_y(val: float) -> float:
        ratio = (max_val - val) / (max_val - min_val)
        return margin_top + ratio * usable_h

    ys = [to_y(v) for v in values]
    return list(zip(xs, ys))


def write_svg_chart(record: RecordSpec, rows: list[dict[str, str]]) -> None:
    if not rows:
        return

    series = [
        ("downloads", "下载量"),
        ("unique_downloads", "独立下载"),
        ("views", "浏览量"),
        ("unique_views", "独立访客"),
    ]
    timestamps = [r.get("timestamp", "") for r in rows]
    values: dict[str, list[int]] = {k: [] for k, _ in series}
    for row in rows:
        for key, _ in series:
            try:
                values[key].append(int(row.get(key, "0")))
            except ValueError:
                values[key].append(0)

    svg_lines = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{SVG_WIDTH}" height="{SVG_HEIGHT}" viewBox="0 0 {SVG_WIDTH} {SVG_HEIGHT}">',
        f'<rect x="0" y="0" width="{SVG_WIDTH}" height="{SVG_HEIGHT}" fill="#ffffff" />',
        f'<text x="{SVG_WIDTH/2:.1f}" y="24" text-anchor="middle" font-size="16" fill="#333">Zenodo {record.record_id} 访问统计（时序，分图）</text>',
    ]

    outer_margin_x = 30
    outer_margin_y = 40
    gap_x = 40
    gap_y = 60
    panel_width = (SVG_WIDTH - outer_margin_x * 2 - gap_x) / 2
    panel_height = (SVG_HEIGHT - outer_margin_y * 2 - gap_y) / 2
    margin_left = 70
    margin_right = 30
    margin_top = 30
    margin_bottom = 50

    colors = ["#d62728", "#1f77b4", "#2ca02c", "#ff7f0e"]

    for idx, (key, label) in enumerate(series):
        row_idx = idx // 2
        col_idx = idx % 2
        origin_x = outer_margin_x + col_idx * (panel_width + gap_x)
        origin_y = outer_margin_y + row_idx * (panel_height + gap_y)

        vals = values[key]
        min_val = min(vals)
        max_val = max(vals)
        pad = max(1, int((max_val - min_val) * 0.05))
        min_val -= pad
        max_val += pad

        pts = _scale_points(
            vals,
            panel_width,
            panel_height,
            margin_left,
            margin_right,
            margin_top,
            margin_bottom,
            float(min_val),
            float(max_val),
        )
        # shift to panel origin
        pts = [(origin_x + x, origin_y + y) for x, y in pts]

        # axes
        x0 = origin_x + margin_left
        y0 = origin_y + panel_height - margin_bottom
        x1 = origin_x + panel_width - margin_right
        y1 = origin_y + margin_top
        svg_lines.append(
            f'<line x1="{x0}" y1="{y0}" x2="{x1}" y2="{y0}" stroke="#444" stroke-width="1.2" />'
        )
        svg_lines.append(
            f'<line x1="{x0}" y1="{y0}" x2="{x0}" y2="{y1}" stroke="#444" stroke-width="1.2" />'
        )

        color = colors[idx % len(colors)]
        coord_str = " ".join(f"{x:.1f},{y:.1f}" for x, y in pts)
        svg_lines.append(
            f'<polyline fill="none" stroke="{color}" stroke-width="2" points="{coord_str}" />'
        )
        for x, y in pts:
            svg_lines.append(
                f'<circle cx="{x:.1f}" cy="{y:.1f}" r="3" fill="{color}" stroke="#fff" stroke-width="1" />'
            )

        # y ticks
        for frac in [0, 0.5, 1]:
            val = min_val + (max_val - min_val) * frac
            y_tick = origin_y + margin_top + (1 - frac) * (
                panel_height - margin_top - margin_bottom
            )
            svg_lines.append(
                f'<line x1="{x0-5}" y1="{y_tick:.1f}" x2="{x0}" y2="{y_tick:.1f}" stroke="#666" />'
            )
            svg_lines.append(
                f'<text x="{x0-8}" y="{y_tick+4:.1f}" font-size="10" text-anchor="end" fill="#555">{int(val)}</text>'
            )

        # x labels (first/last)
        if timestamps:
            first_label = timestamps[0].replace("T", " ")
            last_label = timestamps[-1].replace("T", " ")
            svg_lines.append(
                f'<text x="{x0}" y="{origin_y + panel_height - margin_bottom + 18}" font-size="10" text-anchor="start" fill="#555">{first_label}</text>'
            )
            svg_lines.append(
                f'<text x="{x1}" y="{origin_y + panel_height - margin_bottom + 18}" font-size="10" text-anchor="end" fill="#555">{last_label}</text>'
            )

        # title
        svg_lines.append(
            f'<text x="{origin_x + panel_width/2:.1f}" y="{origin_y + 18:.1f}" text-anchor="middle" font-size="13" fill="#222">{label}</text>'
        )

    svg_lines.append("</svg>")

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    with record.svg_path.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(svg_lines))


def main() -> None:
    fetched_at_dt = _datetime.datetime.now(_datetime.timezone.utc).astimezone(
        TZ_BEIJING
    )
    fetched_at_text = fetched_at_dt.strftime("%Y-%m-%d %H:%M 北京时间")

    OUT_DIR.mkdir(parents=True, exist_ok=True)

    full_sections: list[str] = []
    core_sections: list[str] = []
    for record in RECORDS:
        try:
            response = fetch_record(record.api_url)
        except (HTTPError, URLError, TimeoutError, RuntimeError) as exc:
            raise SystemExit(f"拉取 {record.record_id} 数据失败：{exc}")

        stats = response.get("stats")
        if not isinstance(stats, dict):
            raise SystemExit(f"响应中缺少 stats 字段，无法解读（记录 {record.record_id}）。")

        full_sections.append(build_markdown(record, stats, fetched_at_text))
        rows = append_timeseries(record, stats, fetched_at_dt)
        write_svg_chart(record, rows)
        core_sections.append(build_core_metrics(record, stats, fetched_at_text))

    write_markdown("\n---\n\n".join(full_sections))
    inject_into_readme(core_sections)
    relative_output = OUTPUT_PATH.relative_to(REPO_ROOT)
    print(
        f"已生成 {relative_output} 并更新 README.md；CSV/SVG 输出位于 {OUT_DIR.relative_to(REPO_ROOT)}"
    )


if __name__ == "__main__":
    main()
