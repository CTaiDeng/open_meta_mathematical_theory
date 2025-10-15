**Agent 协议（仓库级）**

**作用范围**
- 本文件对整个仓库生效；若子目录存在更具体的 `AGENTS.md`，则子目录内文件以就近文件为准（就近优先）。
- 特别说明：`src/kernel_reference` 子树内禁止添加 `AGENTS.md`；该子树一律以仓库根目录 `AGENTS.md` 为准。

**第一前提：中文沟通**
- 与用户的自然语言沟通一律使用“简体中文”。
- 命令、代码、路径、标识符使用英文原文并用反引号包裹（如 `apply_patch`、`src/path/file`）。
- 回答以“简洁、直接、友好”为默认风格，优先给出可执行的下一步。

**系统提示词（可直接作为 System Prompt 使用）**
```text
你是在 Codex CLI 中运行的编码助手。必须遵守以下要求：
- 所有与用户的自然语言交流统一使用简体中文。
- 语气简洁、直接、友好；优先输出可执行结论与下一步。
- 工具调用前给出一句话“将要做什么”的简短前置说明；逻辑相近的操作合并描述。
- 非必要不使用重格式化；命令、路径、代码标识使用反引号。
- 若需要对多个步骤开展工作，使用计划（plan）工具同步进度；保持一步在进行中。
- 修改文件统一通过 `apply_patch`；遵循最小变更原则；避免无关重构。
- 若目录存在 `AGENTS.md`，严格遵守就近优先原则；`src/kernel_reference` 子树需额外遵循其索引构建脚本规范，但不允许自行放置 `AGENTS.md`。
- 验证时优先运行与改动最相关的最小集测试/构建；如无测试，不盲目新增与本次任务无关的内容。
- 若遇到权限/沙箱/网络限制，显式说明并给出可替代路径。
```

**文档与编码**
- 文档默认使用 UTF-8 编码。尽量保留原有换行风格（CRLF/LF）。
- 不擅自改动与任务无关的内容；避免格式“抖动”。

**Markdown 操作约定（全局）**
- 批量处理时跳过任何名为 `INDEX.md` 的文件（通常为脚本生成）。
- 仅在用户明确提出时才整体重写标题级别；否则保持正文子标题不变。
- 如需插入作者信息，推荐格式：
  - 首行为文档主标题（H1，`# 标题`）
  - 接一空行
  - `- 作者：GaoZheng`
  - 再接一空行后进入正文

**kernel_reference 子树特别约定（合并版）**
- 快速着陆：先阅读 `src/kernel_reference/KERNEL_REFERENCE_README.md` 与 `src/kernel_reference/INDEX.md`。
- 重建索引命令：
  - `pwsh -NoLogo -File script/kernel_reference_build_index.ps1 -MaxChars 500`
- 索引范围与排除：`KERNEL_REFERENCE_README.md` 为前言/说明文档，不纳入 `src/kernel_reference/INDEX.md`。
- 索引生成与统计：脚本重建 `INDEX.md` 时必须保留手动定义的头样式，仅更新“总计：{N} 篇”中的数字，不得更改其他字符与行序。
- 固定头样式（INDEX 头，必须精确一致）：
```
# **基于分类的索引（含摘要）**

### [若为非Github的镜像点击这里为项目官方在Github的完整原版](https://github.com/CTaiDeng/open_meta_mathematical_theory)
### [作者：GaoZheng](https://mymetamathematics.blogspot.com)

---

### 总计：{N} 篇；第一行仅显示文件名（代码样式，无链接/无项目符），下一行输出清洗后的摘要。

---
```
- 固定头样式（KERNEL_REFERENCE_README 头，必须精确一致）：
```
# kernel_reference 前言与分类总览（含使用说明）

### [若为非Github的镜像点击这里为项目官方在Github的完整原版](https://github.com/CTaiDeng/open_meta_mathematical_theory)
### [作者：GaoZheng](https://mymetamathematics.blogspot.com)

---
```
- 请勿手动编辑 `src/kernel_reference/INDEX.md` 的条目结构与格式。
- 禁止在 `src/kernel_reference` 子树内新增 `AGENTS.md`；该子树全部以仓库根目录 `AGENTS.md` 为准。
- 自动化脚本输出需避免不必要的格式“抖动”，统一使用 UTF-8 编码并尽量保持原有换行风格。

**变更边界**
- 仅完成用户明确提出的任务；发现旁支问题可在结果中简述但不主动修改。
- 需大规模/破坏性变更时，先与用户确认方案与范围。

**开发协议（总纲）**
- 以下授权文件为人工维护文件，严禁通过代理、自动化脚本或批处理工具进行任何自动写入或修改：
  - `src/docs/LICENSE.md`
  - `src/kernel_reference/LICENSE.md`
  - `src/full_reference/LICENSE.md`
  - `LICENSE`
- 如需变更，上述文件仅可手工编辑；提交时须在提交信息中说明变更缘由、范围与影响，并由维护者审核。
- 批处理或自动化任务涉及“许可声明”等内容时，不得修改上述授权文件本身；如需对外提示，请在具体文档正文中追加声明。
- 本开发协议为流程与协作约束，不改变各自授权文件的法律条款。
 - 版权头统一规范：统一使用 `Copyright (C) 2025 GaoZheng`（单年，不带连字符）。
   - 所有自动化脚本（如 `script/add_gpl3_headers.*`）需遵循该格式；如检测到旧格式（如 `2025- GaoZheng`），应在不改变其余内容的前提下就地规范化。

