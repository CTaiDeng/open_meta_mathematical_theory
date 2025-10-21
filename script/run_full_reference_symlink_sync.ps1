# Copyright (C) 2025 GaoZheng
# SPDX-License-Identifier: GPL-3.0-only
# This file is part of this project.
# Licensed under the GNU General Public License version 3.
# See https://www.gnu.org/licenses/gpl-3.0.html for details.

[CmdletBinding()]
param(
  # 允许透传额外参数到目标脚本
  [string[]]$PassThru
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$here = $PSScriptRoot
$repoRoot = Resolve-Path (Join-Path $here '..')
$tool = Join-Path $here 'full_reference_symlink_sync_and_json_build.ps1'
$cfg  = Join-Path $repoRoot 'src/full_reference/Link.json'

if (-not (Test-Path -LiteralPath $tool)) { throw "Missing tool: $tool" }
if (-not (Test-Path -LiteralPath $cfg))  { throw "Missing config: $cfg" }

function Get-PwshPath {
  $candidates = @('pwsh','pwsh.exe')
  foreach($c in $candidates){ try { $p = (Get-Command $c -ErrorAction Stop).Source; if($p){ return $p } } catch {} }
  return $null
}

$pwsh = Get-PwshPath
if ($pwsh) {
  & $pwsh -NoLogo -File $tool -Config $cfg @PassThru
} else {
  # 回退到 Windows PowerShell（可能在旧环境显示为 1.0），尽量兼容参数
  & powershell -NoLogo -ExecutionPolicy Bypass -File $tool -Config $cfg @PassThru
}
