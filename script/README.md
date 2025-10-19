# 脚本总览与开发协议

本目录收录仓库内的自动化脚本与脚本包，统一采用 UTF-8 编码，PowerShell 脚本默认为 `pwsh` 执行。以下为主要脚本用途与入口命令。

## 子项目文档

- `script/clone_docs_from_sub_projects.ps1`
  - 按 `src/sub_projects_docs/sub_projects_clone_map.json` 进行“部分稀疏克隆”，将外部仓库指定子目录的顶层 `*.md` 文件复制至 `src/sub_projects_docs/<name>`；并生成/更新 `src/sub_projects_docs/README.md` 索引。
  - 关键参数：`-SkipClone`、`-SkipCopy`、`-SkipIndex`、`-KeepOut`、`-MaxChars`、`-Step`。
  - 稀疏克隆优化：优先使用 `--no-cone` + `/<subdir>/*.md` 精确匹配，失败则回退 `--cone`。

## kernel_reference 相关

- `script/kernel_reference_build_index.ps1`
  - 重建 `src/kernel_reference/INDEX.md`，遵守固定头样式与“声明区”保持不动的规则。

## full_reference 相关

- `script/sync_full_reference_symlinks.ps1`
  - 按 `src/full_reference/Link.json` 建立 `src/full_reference` 下的符号链接，指向各外部源文件绝对路径；完成后导出 `src/full_reference/symlink_target_map.json`（链接名 -> 目标绝对路径）。
- `script/copy_kernel_to_full_from_diff.ps1`
  - 读取 `src/full_reference/common_name_hash_diff.csv` 的 `name` 列，将 `src/kernel_reference/<name>` 拷贝到 full 端“源文件绝对路径”。优先使用 `symlink_target_map.json` 定位，缺失时回退解析 `src/full_reference/<name>`。

## 差异/一致性检查

- `script/check_kernel_missing_in_full.ps1`、`script/check_full_missing_in_kernel.ps1`
  - 双向检查缺失的 Markdown 文件（按名称），输出仓库相对路径列表。

## 其他工具

- `script/add_gpl3_headers.ps1`、`script/add_gpl3_headers.py`
  - 为脚本/源码文件补齐或规范化 GPL-3 许可头，遵循“单年版权头”规范。

---

## 开发协议（摘要）

- 受保护的授权文件（仅人工维护，脚本不得改写）：
  - `src/docs/LICENSE.md`、`src/kernel_reference/LICENSE.md`、`src/full_reference/LICENSE.md`、`LICENSE`
- 新建脚本（`.ps1`/`.py`/`.sh`/`.cmd`/`.bat`）：
  - 头部必须包含：`SPDX-License-Identifier: GPL-3.0-only` 与 `Copyright (C) 2025 GaoZheng`
  - 若存在 shebang 或编码声明，许可证头置于其后。
- 版权头规范：统一为 `Copyright (C) 2025 GaoZheng`
- Markdown 操作：批量处理时跳过名为 `INDEX.md` 的文件；`src/kernel_reference/INDEX.md` 条目结构与声明区不得脚本化更改。

---

## 维护约定

- 当更新与子项目文档聚合相关的脚本（如 `clone_docs_from_sub_projects.ps1`）时，请同步校对并更新 `src/sub_projects_docs/README.md` 中的使用说明与示例命令，确保路径与参数描述一致。

