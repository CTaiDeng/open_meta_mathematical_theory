<#

# Copyright (C) 2025 GaoZheng
# SPDX-License-Identifier: GPL-3.0-only
# This file is part of this project.
# Licensed under the GNU General Public License version 3.
# See https://www.gnu.org/licenses/gpl-3.0.html for details.
<#
说明: 检查 `src\kernel_reference` 中存在但 `src\full_reference` 中不存在的文件，逐行打印缺失文件的仓库相对路径。
规则: 递归扫描；排除 `AGENTS.md`、`INDEX.md`、`kernel_reference_说明.md`；统一忽略大小写差异。
用法: pwsh -NoLogo -File script/check_kernel_missing_in_full.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir  = Split-Path -Parent $PSCommandPath
$repoRoot   = Split-Path -Parent $scriptDir
$kernelRoot = Join-Path $repoRoot 'src\kernel_reference'
$fullRoot   = Join-Path $repoRoot 'src\full_reference'

if (-not (Test-Path -LiteralPath $kernelRoot)) { Write-Error "缺少目录: $kernelRoot"; exit 1 }

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

# 若 full_reference 不存在，则 kernel_reference 下的（非排除项）文件全部算缺失
if (-not (Test-Path -LiteralPath $fullRoot)) {
  $missing = 0
  Get-ChildItem -Path $kernelRoot -File -Recurse |
    ForEach-Object {
      $rel = Get-RelativePath -Base $kernelRoot -Path $_.FullName
      if ($KernelExcludedRel -contains $rel) { return }
      Write-Output ("src\kernel_reference\" + $rel)
      $missing++
    }
  if ($missing -eq 0) { Write-Output '未发现差异（kernel→full 无缺失项）' }
  exit 0
}

$missing = 0
Get-ChildItem -Path $kernelRoot -File -Recurse |
  ForEach-Object {
    $rel    = Get-RelativePath -Base $kernelRoot -Path $_.FullName
    if ($KernelExcludedRel -contains $rel) { return }
    $target = Join-Path $fullRoot $rel
    if (-not (Test-Path -LiteralPath $target)) {
      Write-Output ("src\kernel_reference\" + $rel)
      $missing++
    }
  }
if ($missing -eq 0) { Write-Output '未发现差异（kernel→full 无缺失项）' }


