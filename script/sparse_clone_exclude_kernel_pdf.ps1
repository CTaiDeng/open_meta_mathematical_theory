# Copyright (C) 2025 GaoZheng
# SPDX-License-Identifier: GPL-3.0-only
# This file is part of this project.
# Licensed under the GNU General Public License version 3.
# See https://www.gnu.org/licenses/gpl-3.0.html for details.

<#
.SYNOPSIS
  稀疏只读克隆指定仓库到 `out`，排除 `src/kernel_reference_pdf` 目录。

.DESCRIPTION
  - 使用 `git clone --filter=blob:none --sparse --no-checkout` 进行部分克隆。
  - 以非 cone 模式初始化 sparse-checkout，并配置：
      包含全部（/* 与 /*/**），排除 `src/kernel_reference_pdf/**`。
  - 应用稀疏规则后，将工作区内（排除 .git）的所有文件标记为只读。

.PARAMETER RepoUrl
  远程仓库地址（默认：CTaiDeng/open_meta_mathematical_theory）。

.PARAMETER OutRoot
  输出根目录（默认：当前仓库根目录下的 `out`）。

.PARAMETER Force
  若目标目录已存在，先删除后再克隆。

.EXAMPLE
  pwsh -NoLogo -File script/sparse_clone_exclude_kernel_pdf.ps1

.EXAMPLE
  pwsh -NoLogo -File script/sparse_clone_exclude_kernel_pdf.ps1 -Force

.NOTES
  依赖 git (>= 2.25)。Windows 平台将通过 `IsReadOnly` 标记文件为只读。
#>

param(
  [string]$RepoUrl = 'https://github.com/CTaiDeng/open_meta_mathematical_theory.git',
  [string]$OutRoot,
  [switch]$Force
)

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$ErrorActionPreference = 'Stop'

# 解析路径：脚本位于仓库/script 下，输出默认到仓库/out
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Resolve-Path (Join-Path $ScriptDir '..')
if(-not $OutRoot -or [string]::IsNullOrWhiteSpace($OutRoot)){
  $OutRoot = Join-Path $RepoRoot 'out'
}

if(-not (Test-Path $OutRoot)){ New-Item -ItemType Directory -Path $OutRoot | Out-Null }

# 推导目标目录名（使用仓库名）
$repoName = [IO.Path]::GetFileNameWithoutExtension(($RepoUrl -replace '\.git$',''))
if([string]::IsNullOrWhiteSpace($repoName)){
  throw '无法从 RepoUrl 推导仓库名，请显式指定 OutRoot 或修正 RepoUrl。'
}
$TargetDir = Join-Path $OutRoot $repoName

if(Test-Path $TargetDir){
  if($Force){
    Write-Host "[info] 目标目录已存在，Force=true，正在清理：`$TargetDir=$TargetDir"
    Remove-Item -Recurse -Force -LiteralPath $TargetDir
  } else {
    throw "目标目录已存在：$TargetDir。使用 -Force 以覆盖，或修改 OutRoot/RepoUrl。"
  }
}

# 环境校验：git 版本
try {
  $gitVer = (& git --version) 2>$null
  Write-Host "[info] $gitVer"
} catch {
  throw '未检测到 git，请先安装 git (>= 2.25)。'
}

Write-Host "[step] 开始稀疏克隆：$RepoUrl -> $TargetDir"

# 1) 部分克隆 + 稀疏
& git clone --filter=blob:none --sparse --no-checkout -- "$RepoUrl" "$TargetDir"

Push-Location "$TargetDir"
try {
  # 2) 初始化非 cone 模式的 sparse-checkout
  & git sparse-checkout init --no-cone

  # 3) 配置 sparse 规则：包含所有、排除 src/kernel_reference_pdf/**
  $sparseFile = Join-Path (Join-Path $TargetDir '.git') 'info/sparse-checkout'
  @(
    '/*',
    '/*/**',
    '!/src/kernel_reference_pdf/**'
  ) | Set-Content -LiteralPath $sparseFile -Encoding UTF8

  # 4) 应用稀疏规则并检出
  & git sparse-checkout reapply
  & git checkout

  # 5) 将工作区文件设为只读（排除 .git）
  $gitMeta = Join-Path $TargetDir '.git'
  $prefix  = $gitMeta + [IO.Path]::DirectorySeparatorChar
  Get-ChildItem -LiteralPath $TargetDir -Recurse -File -Force |
    Where-Object { $_.FullName -notlike "$prefix*" } |
    ForEach-Object { $_.IsReadOnly = $true }

  Write-Host "[done] 稀疏克隆完成，并已将工作区文件设为只读。"
  Write-Host "        已排除：src/kernel_reference_pdf/"
  Write-Host "        位置：$TargetDir"
}
finally {
  Pop-Location
}

