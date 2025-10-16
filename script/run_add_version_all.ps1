# Copyright (C) 2025 GaoZheng
# SPDX-License-Identifier: GPL-3.0-only
# This file is part of this project.
# Licensed under the GNU General Public License version 3.
# See https://www.gnu.org/licenses/gpl-3.0.html for details.

[CmdletBinding()]
param(
  [string]$Version = 'v1.0.0',
  [string[]]$Roots = @('src/docs','src/full_reference','src/kernel_reference'),
  [string]$IncludePattern = '^(?!(INDEX|LICENSE|KERNEL_REFERENCE_README)\.md$).*\.md$',
  [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$tool = Join-Path $here 'add_version_to_kernel_md.ps1'
if (-not (Test-Path -LiteralPath $tool)) {
  throw "依赖脚本未找到：$tool"
}

foreach($root in $Roots){
  if(-not (Test-Path -LiteralPath $root)){
    Write-Host "[skip] $root (not found)"
    continue
  }
  Write-Host "[run] $root"
  pwsh -NoLogo -File $tool -Root $root -Version $Version -IncludePattern $IncludePattern -WhatIf:$WhatIf |
    Select-String 'Summary =>' | ForEach-Object { $_.ToString() }
}

