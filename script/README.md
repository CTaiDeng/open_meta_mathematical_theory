# 脚本清单与开发协议

本目录收录仓库内的自动化脚本。脚本输出统一为 UTF-8 编码，PowerShell 脚本默认由 `pwsh` 执行。以下为主要脚本与用途、示例命令。

## 子项目文档

- `script/clone_docs_from_sub_projects.ps1`
  - 按 `src/sub_projects_docs/sub_projects_clone_map.json` 配置，稀疏克隆并复制外部仓库指定目录的顶层 `*.md` 文件到 `src/sub_projects_docs/<name>`；生成/更新 `src/sub_projects_docs/README.md` 索引。
  - 关键参数：`-SkipClone`、`-SkipCopy`、`-SkipIndex`、`-KeepOut`、`-MaxChars`、`-Step`。
  - 稀疏克隆优化：优先使用 `--no-cone` + `/<subdir>/*.md` 精确匹配，失败时回退 `--cone`。

## kernel_reference 目录

- `script/build_index_kernel_reference.ps1`
  - 重建 `src/kernel_reference/INDEX.md`；保留固定头样式与声明区，仅更新“总计：{N} 篇”与条目列表。

## kernel_plus 目录

- `script/build_index_kernel_plus.ps1`
  - 生成/更新 `src/kernel_plus/README.md`；仅收录形如 `<unittime秒>_*.md` 的文件，排除 `LICENSE.md`。

## app_docs 目录

- `script/build_index_app_docs.ps1`
  - 生成/更新 `src/app_docs/README.md`；仅收录形如 `<unittime秒>_*.md` 的文件，排除 `LICENSE.md`。如需兼容 `src/app_doc`，可传参 `-TargetDir src/app_doc`。

## full_reference 目录

- `script/full_reference_symlink_sync_and_json_build.ps1`
  - 读取 `src/full_reference/Link.json` 与 `src/full_reference` 下的符号链接，指向外部源文件的路径；生成后导出 `src/full_reference/symlink_target_map.json`（源 -> 目标 的路径映射）。
- `script/copy_kernel_reference_to_full_reference_by_diff_use_csv_map.ps1`
  - 读取 `src/full_reference/common_name_hash_diff.csv` 中 `name` 列，将 `src/kernel_reference/<name>` 同步到 full 侧。源文件采用路径映射；无法定位时回落复制到 `src/full_reference/<name>`。

## 批处理/一键脚本



## 统一处理

- `script/add_gpl3_headers.ps1`、`script/add_gpl3_headers.py`
  - 为脚本/源码文件补齐规范化 GPL-3 许可证头；遵循项目版权头规范。
 
- `script/print_env_ai.ps1`
  - 打印与 AI 相关的环境变量状态，支持掩码显示或原文显示；可输出 JSON。
  - 检查项：`AZURE_SPEECH_KEY`、`AZURE_SPEECH_REGION`、`GEMINI_API_KEY`、`GEMINI_MODEL`。
  - 示例：
    - `pwsh -NoLogo -File script/print_env_ai.ps1`
    - 明文显示：`pwsh -NoLogo -File script/print_env_ai.ps1 -Reveal`
    - JSON：`pwsh -NoLogo -File script/print_env_ai.ps1 -AsJson`

---

## 文档合并导出

- `script/merge_md/merge_md_by_timestamp.py`
  - 按 `script/merge_md/merge_md_by_timestamp.json` 配置，收集 `source_dirs` 下基名匹配 `<UNIX时间戳秒>_*.md` 的文件，按时间戳升序合并为 JSON 与 Markdown 两份结果，输出到 `out`（或配置项 `output_dir`）。
  - 主要参数：`--config`（配置文件路径）、`--out-dir`（覆盖输出目录）、`--dry-run`（仅预览不写入）。
  - 示例：`python3 script/merge_md/merge_md_by_timestamp.py`；预览：`python3 script/merge_md/merge_md_by_timestamp.py --dry-run`。
  - 输出流程（逐项摘要）：
    - 先生成完整合并文件 `out/merge_md_by_timestamp_all.json`（含全文内容）。
    - 然后对 `files` 中的每一项逐一进行摘要：
      - 当 `compression.enabled=true` 时，调用 Gemini 进行信息无损压缩（约束见配置 `principles`，`max_chars=500`）。
      - 当 `compression.enabled=false` 时，直接截断前 500 字并在末尾追加 `……`。
    - 跳过项（排除主题）：当 `compression.content_guard.enabled=true` 且命中 `blocked_topics` 时，本次请求仅返回排除告知，脚本只在 `out/merge_md_by_timestamp.json` 记录该条目（含 `content_guard` 与 `skipped: true`），不写入 `out/merge_md_by_timestamp.md`。断点续跑时亦会跳过这些条目的 Markdown 输出，不回写占位提示。
    - 最终输出逐项摘要的 `out/merge_md_by_timestamp.json` 与 `out/merge_md_by_timestamp.md`。
    - 逐项 JSON 中的 `compression` 字段包含：`enabled`、`requested`（是否发起请求）、`ok`（请求是否成功）、`error`（错误信息，若有）。成功则不再做 500 字截断；失败或未请求才做 500 字截断。

- `script/merge_md/merge_md_by_timestamp.json`
  - 配置项：`source_dirs`（目录列表）、`output_dir`（默认 `out`）；`compression`（`enabled`/`model`/`max_chars`/`request_interval_seconds`）。
  - 默认目录包含：`src/kernel_plus`、`src/app_docs`、`src/kernel_reference`、`src/sub_projects_docs/haca`、`src/sub_projects_docs/lbopb`。
  - `compression.principles`：压缩遵循的约束列表（信息无损、不重复、符号化、尽量简洁、定义一致）。

---

## 开发协议（摘要）

- 以下授权文件为人工维护文件，脚本不得自动修改：
  - `src/docs/LICENSE.md`、`src/kernel_reference/LICENSE.md`、`src/full_reference/LICENSE.md`、`LICENSE`
- 新增脚本（`.ps1`/`.py`/`.sh`/`.cmd`/`.bat`）需：
  - 头部包含：`SPDX-License-Identifier: GPL-3.0-only` 与 `Copyright (C) 2025 GaoZheng`
  - 若存在 shebang，则许可证头置于 shebang 下一行
- 版权头规范统一为 `Copyright (C) 2025 GaoZheng`
- Markdown 批量处理时跳过 `INDEX.md`；`src/kernel_reference/INDEX.md` 的结构受 AGENTS.md 限制，相关脚本需遵循。

---

## 维护约定

- 涉及子项目文档聚合的脚本（如 `clone_docs_from_sub_projects.ps1`）更新时，应同步校对 `src/sub_projects_docs/README.md` 的使用说明与示例命令，确保路径与参数一致。
- 索引构建脚本更名或新增时，需同步维护本文件中的脚本清单与示例命令，并与 AGENTS.md 约束一致；脚本输出统一为 UTF-8（无BOM）+ LF。
