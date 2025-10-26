# Copyright (C) 2025 GaoZheng
# SPDX-License-Identifier: GPL-3.0-only
# This file is part of this project.
# Licensed under the GNU General Public License version 3.
# See https://www.gnu.org/licenses/gpl-3.0.html for details.

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  # 根目录或文件路径。若是目录则递归扫描；若是文件则仅处理该文件。
  [string]$Root = 'src/kernel_reference',
  # 文件名匹配：10位秒级时间戳_标题.md
  [string]$IncludePattern = '^[0-9]{10}_.+\.md$',
  # 版本号默认值（缺失时插入）
  [string]$Version = 'v1.0.0'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

function Get-DateFromName([string]$name){
  if($name -notmatch '^(?<ts>\d{10})_'){ return $null }
  try {
    return [DateTimeOffset]::FromUnixTimeSeconds([int64]$Matches['ts']).ToLocalTime().ToString('yyyy-MM-dd')
  } catch { return $null }
}

function Get-Eol([string]$text){ return "`n" }

function Read-All([string]$path){ return Get-Content -LiteralPath $path -Raw -Encoding UTF8 }

function Write-All([string]$path, [string]$text){
  $enc = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($path, $text, $enc)
}

function Insert-DateVersion([string]$path){
  $name = [IO.Path]::GetFileName($path)
  $date = Get-DateFromName $name
  if(-not $date){ return @{ changed=$false; reason='no_date_from_name' } }

  $raw = Read-All $path
  $eol = Get-Eol $raw
  $lines = [regex]::Split($raw, '\r\n|\n', 0)

  # 定位作者行
  $authorIdx = -1
  for($i=0; $i -lt $lines.Length; $i++){
    if([regex]::IsMatch($lines[$i], '^(?m)-\s*作者：GaoZheng\s*$')){ $authorIdx = $i; break }
  }
  if($authorIdx -lt 0){ return @{ changed=$false; reason='no_author' } }

  # 获取现有版本号（若存在则保留），否则使用参数默认值
  $verMatch = [regex]::Match($raw, '(?m)^-\s*版本：\s*(.+?)\s*$')
  $verValue = if($verMatch.Success){ $verMatch.Groups[1].Value.Trim() } else { $Version }

  # 目标块样式（严格）：
  # - 作者：GaoZheng
  # - 日期：YYYY-MM-DD
  # - 版本：vX.Y.Z
  # [空行]

  # 计算替换范围：从作者行下一行开始，连续清理空行与已有的日期/版本行；
  # 停在遇到非空且非日期/版本的行或行尾。
  $start = $authorIdx + 1
  $end = $start
  # 吞掉紧随其后的空行
  while($end -lt $lines.Length -and [string]::IsNullOrWhiteSpace($lines[$end])){ $end++ }
  # 吞掉紧随其后的日期/版本行以及其间的空行
  $guard = 0
  while($end -lt $lines.Length -and $guard -lt 10){
    $t = $lines[$end].Trim()
    if($t -match '^-\s*日期：\d{4}-\d{2}-\d{2}\s*$' -or $t -match '^-\s*版本：'){ $end++ }
    elseif([string]::IsNullOrWhiteSpace($t)){ $end++ }
    else { break }
    $guard++
  }

  # 组装新内容：在作者行之后直接插入日期与版本，不留空行；版本行后补一个空行。
  $final = New-Object System.Collections.Generic.List[string]
  if($start -gt 0){ for($k=0; $k -lt $start; $k++){ $final.Add($lines[$k]) } }
  $final.Add("- 日期：$date")
  $final.Add("- 版本：$verValue")
  $final.Add("")
  for($k=$end; $k -lt $lines.Length; $k++){ $final.Add($lines[$k]) }

  $newText = [string]::Join($eol, $final)
  if(-not $newText.EndsWith($eol)){ $newText += $eol }
  $changed = ($newText -ne $raw)
  return @{ changed=$changed; content=$newText }
}

function Enumerate-Targets([string]$base){
  if(-not (Test-Path -LiteralPath $base)){ return @() }
  $it = Get-Item -LiteralPath $base
  if($it.PSIsContainer){
    return Get-ChildItem -LiteralPath $base -Recurse -File -Filter *.md |
      Where-Object { $_.Name -match $IncludePattern -and $_.Name -ne 'INDEX.md' }
  } else {
    if($it.Extension -ieq '.md' -and $it.Name -ne 'INDEX.md' -and ($it.Name -match $IncludePattern)){
      return ,$it
    }
    return @()
  }
}

$targets = @(Enumerate-Targets -base $Root)
if(-not $targets){ Write-Host "[info] 无匹配文件：$Root" -ForegroundColor Yellow; exit 0 }

$updated = 0
foreach($f in $targets){
  $res = Insert-DateVersion -path $f.FullName
  if($res.changed){
    if($PSCmdlet.ShouldProcess($f.FullName, 'Insert date/version under author')){
      Write-All $f.FullName $res.content
      Write-Host ("[update] {0}" -f $f.FullName)
      $updated++
    }
  }
}
Write-Host ("Summary => files={0} updated={1}" -f $targets.Count, $updated)

# 用法：
# 1) 默认扫描 src/kernel_reference：
#    pwsh -NoLogo -File script/insert_date_version_under_author.ps1
# 2) 指定目录：
#    pwsh -NoLogo -File script/insert_date_version_under_author.ps1 -Root 'src/full_reference'
# 3) 指定单个文件：
#    pwsh -NoLogo -File script/insert_date_version_under_author.ps1 -Root 'src/kernel_reference/1734546043_广义增强学习理论的公理系统.md'
# 说明：作者行下方不留空行，版本行之后补一个空行。
