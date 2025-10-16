# Copyright (C) 2025 GaoZheng
# SPDX-License-Identifier: GPL-3.0-only
# This file is part of this project.
# Licensed under the GNU General Public License version 3.
# See https://www.gnu.org/licenses/gpl-3.0.html for details.

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  # 根目录或文件路径。目录则递归匹配 Markdown；文件则仅处理该文件。
  [string]$Root = 'src/full_reference',
  # 文件名匹配：10位秒级时间戳_标题.md
  [string]$IncludePattern = '^[0-9]{10}_.+\.md$',
  # 递归扫描（当 Root 为目录时）
  [switch]$Recurse = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

function Get-Eol([string]$text){ if($text -match "\r\n"){ return "`r`n" } else { return "`n" } }
function Read-All([string]$path){ return Get-Content -LiteralPath $path -Raw -Encoding UTF8 }
function Write-All([string]$path, [string]$text){ $enc=[System.Text.UTF8Encoding]::new($false); [System.IO.File]::WriteAllText($path,$text,$enc) }

function Get-DateFromName([string]$name){
  if($name -notmatch '^(?<ts>\d{10})_'){ return $null }
  try { return [DateTimeOffset]::FromUnixTimeSeconds([int64]$Matches['ts']).ToLocalTime().ToString('yyyy-MM-dd') } catch { return $null }
}

function Determine-CopyrightYear([string]$text,[string]$path){
  $m = [regex]::Match($text, '(?m)^-\s*日期：(?<y>\d{4})-\d{2}-\d{2}\s*$')
  if($m.Success){ return [int]$m.Groups['y'].Value }
  $date = Get-DateFromName ([IO.Path]::GetFileName($path))
  if($date -and $date -match '^(?<y>\d{4})-'){ return [int]$Matches['y'].Value }
  return 2025
}

function Build-Footer([int]$year,[string]$eol){
  $copy = if($year -lt 2025){ ("{0}-2025" -f $year) } else { '2025' }
  $lines = @(
    '',
    '',
    '---',
    '',
    '**许可声明 (License)**',
    '',
    "Copyright (C) $copy GaoZheng ",
    '',
    '本文档采用[知识共享-署名-非商业性使用-禁止演绎 4.0 国际许可协议 (CC BY-NC-ND 4.0)](https://creativecommons.org/licenses/by-nc-nd/4.0/deed.zh-Hans)进行许可。'
  )
  return [string]::Join($eol,$lines)
}

function Strip-ExistingFooter([string]$text){
  $lines = $text -split "\r\n|\n", -1
  $from = [Math]::Max(0, $lines.Length - 300)
  $lic = -1; $sep = -1
  for($i=$lines.Length-1; $i -ge $from; $i--){
    if($lic -lt 0 -and $lines[$i].Trim() -eq '**许可声明 (License)**'){ $lic=$i; continue }
    if($lic -ge 0 -and $lines[$i].Trim() -eq '---'){ $sep=$i; break }
  }
  if($lic -ge 0 -and $sep -ge 0 -and $sep -lt $lic){
    $keep = @()
    if($sep -gt 0){ $keep += $lines[0..($sep-1)] }
    $eol = Get-Eol $text
    return [string]::Join($eol,$keep)
  }
  return $text
}

function Ensure-OneBlankLineBefore([string]$text,[string]$eol){
  # 去除文末多余空行，保留 0 行；由 Build-Footer 的开头空行负责提供“[内容]与---之间的空行”。
  return [regex]::Replace($text,'(\r?\n\s*)+$','')
}

function Process-One([string]$path){
  $raw = Read-All $path
  $eol = Get-Eol $raw
  $year = Determine-CopyrightYear $raw $path
  $body = Strip-ExistingFooter $raw
  $body = Ensure-OneBlankLineBefore $body $eol
  $footer = Build-Footer -year $year -eol $eol
  $final = $body + $footer
  if(-not $final.EndsWith($eol)){ $final += $eol }
  $changed = ($final -ne $raw)
  return @{ changed=$changed; content=$final }
}

function Enumerate-Targets([string]$base){
  if(-not (Test-Path -LiteralPath $base)){ return @() }
  $it = Get-Item -LiteralPath $base
  if($it.PSIsContainer){
    $seq = if($Recurse){ Get-ChildItem -LiteralPath $base -Recurse -File -Filter *.md } else { Get-ChildItem -LiteralPath $base -File -Filter *.md }
    return $seq | Where-Object { $_.Name -match $IncludePattern -and $_.Name -ne 'INDEX.md' }
  } else {
    if($it.Extension -ieq '.md' -and $it.Name -match $IncludePattern -and $it.Name -ne 'INDEX.md'){ return ,$it }
    return @()
  }
}

$targets = @(Enumerate-Targets -base $Root)
if(-not $targets){ Write-Host "[info] 无匹配文件：$Root" -ForegroundColor Yellow; exit 0 }

$updated=0
foreach($f in $targets){
  $res = Process-One $f.FullName
  if($res.changed){
    if($PSCmdlet.ShouldProcess($f.FullName,'Insert/Normalize license footer')){
      Write-All $f.FullName $res.content
      Write-Host ("[update] {0}" -f $f.FullName)
      $updated++
    }
  }
}
Write-Host ("Summary => files={0} updated={1}" -f $targets.Count,$updated)

# 用法：
# 1) 默认处理 src/full_reference：
#    pwsh -NoLogo -File script/insert_license_footer.ps1
# 2) 指定目录或文件：
#    pwsh -NoLogo -File script/insert_license_footer.ps1 -Root 'src/kernel_reference'
#    pwsh -NoLogo -File script/insert_license_footer.ps1 -Root 'src/full_reference/1734546039_广义集合论的公理体系.md'
