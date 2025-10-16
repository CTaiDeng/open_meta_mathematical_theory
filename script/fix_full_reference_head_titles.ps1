# Copyright (C) 2025 GaoZheng
# SPDX-License-Identifier: GPL-3.0-only
# This file is part of this project.
# Licensed under the GNU General Public License version 3.
# See https://www.gnu.org/licenses/gpl-3.0.html for details.

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [string]$Root = 'src/full_reference',
  [string]$Pattern = '^[0-9]{10}_.+\.md$',
  [switch]$Recurse = $true,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

function Get-Eol([string]$text){ if($text -match "\r\n"){ return "`r`n" } else { return "`n" } }

function Fix-One([string]$path){
  $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
  $eol = Get-Eol $raw
  $lines = $raw -split "\r\n|\n", -1

  # 定位头部分隔线 '---'
  $sep = -1
  for($i=0; $i -lt [Math]::Min(60,$lines.Length); $i++){
    if($lines[$i].Trim() -eq '---'){ $sep = $i; break }
  }
  if($sep -lt 0){ return @{changed=$false; content=$raw} }

  # 规范头部分隔线上下各一空行
  # 上方：至少一空行，去多余
  $before = @()
  if($sep -gt 0){ $before = $lines[0..($sep-1)] }
  while($before.Count -gt 0 -and [string]::IsNullOrWhiteSpace($before[$before.Count-1])){
    if($before.Count -gt 1){ $before = $before[0..($before.Count-2)] } else { $before = @() }
  }
  $before += ''
  # 下方：至少一空行，去多余
  $after = @(); if($sep -lt $lines.Length-1){ $after = $lines[($sep+1)..($lines.Length-1)] }
  $k = 0
  while($k -lt $after.Count -and [string]::IsNullOrWhiteSpace($after[$k])){ $k++ }
  if($k -lt $after.Count){ $after = @('') + $after[$k..($after.Count-1)] } else { $after = @('') }

  $norm = @()
  $norm += $before
  $norm += '---'
  $norm += $after

  # 删除头部分隔线后紧跟的原标题/副标题块：连续的以 # 开头的行及其后紧邻的一个 '---' 和一个空行
  $pos = $before.Count + 1 # 指向分隔线后首行（空行），跳过空行
  while($pos -lt $norm.Count -and [string]::IsNullOrWhiteSpace($norm[$pos])){ $pos++ }
  $changedLocal = $false
  while($pos -lt $norm.Count -and ($norm[$pos].Trim() -match '^#{1,6}\s+.+$')){
    $start = $pos
    $end = $pos + 1
    while($end -lt $norm.Count -and [string]::IsNullOrWhiteSpace($norm[$end])){ $end++ }
    if($end -lt $norm.Count -and $norm[$end].Trim() -eq '---'){ $end++ }
    if($end -lt $norm.Count -and [string]::IsNullOrWhiteSpace($norm[$end])){ $end++ }
    # 删除区间 [start, end)
    $keep = @()
    if($start -gt 0){ $keep += $norm[0..($start-1)] }
    if($end -le $norm.Count-1){ $keep += $norm[$end..($norm.Count-1)] }
    $norm = $keep
    # 重新定位 pos（现在 pos 指向原 start 位置）
    while($pos -lt $norm.Count -and [string]::IsNullOrWhiteSpace($norm[$pos])){ $pos++ }
    $changedLocal = $true
  }

  $newText = [string]::Join($eol, $norm)
  if(-not $newText.EndsWith($eol)){ $newText += $eol }
  $changed = ($newText -ne $raw)
  return @{changed=$changed; content=$newText}
}

$files = if($Recurse){ Get-ChildItem -LiteralPath $Root -Recurse -File -Filter *.md } else { Get-ChildItem -LiteralPath $Root -File -Filter *.md }
$files = $files | Where-Object { $_.Name -match $Pattern }

$scanned=0; $updated=0
foreach($f in $files){
  $scanned++
  $res = Fix-One $f.FullName
  if($res.changed){
    if($PSCmdlet.ShouldProcess($f.FullName, 'Fix head duplicate titles')){
      if(-not $DryRun){ $enc = [System.Text.UTF8Encoding]::new($false); [System.IO.File]::WriteAllText($f.FullName, $res.content, $enc) }
      Write-Host ("Updated: {0}" -f $f.FullName)
      $updated++
    }
  }
}
Write-Host ("Summary => scanned={0} updated={1}" -f $scanned,$updated)
