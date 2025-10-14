<#

# Copyright (C) 2025 GaoZheng
# SPDX-License-Identifier: GPL-3.0-only
# This file is part of this project.
# Licensed under the GNU General Public License version 3.
# See https://www.gnu.org/licenses/gpl-3.0.html for details.
<#
将工作区指定目录恢复到最近提交（HEAD），本质执行：git checkout -- src

用法：
  还原 src： pwsh -NoLogo -File script/batch_title_author_dryrun.ps1 [-Root src] [-CleanUntracked]
#>
[CmdletBinding()]
param(
  [string]$Root = 'src',
  [switch]$CleanUntracked
)

try {
  $isRepo = git rev-parse --is-inside-work-tree 2>$null
  if ($LASTEXITCODE -ne 0) { throw '当前目录不是 Git 仓库，无法恢复改动。' }

  Write-Host "[revert] git checkout -- $Root" -ForegroundColor Yellow
  git checkout -- $Root

  if ($CleanUntracked) {
    Write-Host "[clean] git clean -fd -- $Root" -ForegroundColor DarkYellow
    git clean -fd -- $Root
  }

  Write-Host "[status]" -ForegroundColor Cyan
  git status -s -- $Root | Out-Host
  exit 0
}
catch {
  Write-Error $_
  exit 1
}


