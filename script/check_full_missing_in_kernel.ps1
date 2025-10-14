<#

# Copyright (C) 2025 GaoZheng
# SPDX-License-Identifier: GPL-3.0-only
# This file is part of this project.
# Licensed under the GNU General Public License version 3.
# See https://www.gnu.org/licenses/gpl-3.0.html for details.
<#
说明: 检查 `src\full_reference` 中存在但 `src\kernel_reference` 中不存在的文件，逐行打印缺失文件的仓库相对路径。
规则: 递归扫描；排除 kernel 侧特殊文件 `AGENTS.md`、`INDEX.md`、`kernel_reference_说明.md`；统一忽略大小写差异。
用法: pwsh -NoLogo -File script/check_full_missing_in_kernel.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir  = Split-Path -Parent $PSCommandPath
$repoRoot   = Split-Path -Parent $scriptDir
$fullRoot   = Join-Path $repoRoot 'src\full_reference'
$kernelRoot = Join-Path $repoRoot 'src\kernel_reference'

if (-not (Test-Path -LiteralPath $fullRoot))   { Write-Error "缺少目录: $fullRoot"; exit 1 }

# 需要在 kernel_reference 侧排除的特定文件（相对 kernel_reference 根）
$KernelExcludedRel = @('AGENTS.md','INDEX.md','kernel_reference_说明.md')

function Get-RelativePath {
  param(
    [Parameter(Mandatory = $true)][string]$Base,
    [Parameter(Mandatory = $true)][string]$Path
  )
  $basePath = (Resolve-Path -LiteralPath $Base).ProviderPath.TrimEnd('\\')
  $fullPath = (Resolve-Path -LiteralPath $Path).ProviderPath
  try {
    return [System.IO.Path]::GetRelativePath($basePath, $fullPath)
  }
  catch {
    if ($fullPath.StartsWith($basePath + '\\', [System.StringComparison]::OrdinalIgnoreCase)) {
      return $fullPath.Substring($basePath.Length + 1)
    }
    return $fullPath
  }
}

# 若 kernel_reference 不存在，则 full_reference 下的（非排除项）文件全部算缺失
if (-not (Test-Path -LiteralPath $kernelRoot)) {
  $missing = 0
  Get-ChildItem -Path $fullRoot -File -Recurse |
    ForEach-Object {
      $rel = Get-RelativePath -Base $fullRoot -Path $_.FullName
      if ($KernelExcludedRel -contains $rel) { return }
      Write-Output ("src\full_reference\" + $rel)
      $missing++
    }
  if ($missing -eq 0) { Write-Output '未发现差异（full→kernel 无缺失项）' }
  exit 0
}

$missing = 0
Get-ChildItem -Path $fullRoot -File -Recurse |
  ForEach-Object {
    $rel    = Get-RelativePath -Base $fullRoot -Path $_.FullName
    if ($KernelExcludedRel -contains $rel) { return }
    $target = Join-Path $kernelRoot $rel
    if (-not (Test-Path -LiteralPath $target)) {
      Write-Output ("src\full_reference\" + $rel)
      $missing++
    }
  }
if ($missing -eq 0) { Write-Output '未发现差异（full→kernel 无缺失项）' }


