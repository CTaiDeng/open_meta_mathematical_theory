# Copyright (C) 2025 GaoZheng
# SPDX-License-Identifier: GPL-3.0-only
# This file is part of this project.
# Licensed under the GNU General Public License version 3.
# See https://www.gnu.org/licenses/gpl-3.0.html for details.

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  # 根目录（默认：src/full_reference）
  [string]$Root = 'src/full_reference',
  # 仅处理符合“时间戳_标题.md”的文件（10位秒级时间戳 + '_' + 至少1字符标题）。
  [string]$NamePattern = '^[0-9]{10}_.+\.md$',
  # 只处理前 N 个文件（调试用）。
  [int]$Limit = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

function Get-Eol([string]$text){ if($text -match "\r\n"){ return "`r`n" } else { return "`n" } }
function Read-Text([string]$path){ return Get-Content -LiteralPath $path -Raw -Encoding UTF8 }
function Write-Text([string]$path, [string]$text){ $enc = [System.Text.UTF8Encoding]::new($false); [System.IO.File]::WriteAllText($path, $text, $enc) }

function Get-DateFromName([string]$name){
  if($name -notmatch '^(?<ts>\d{10})_'){ return $null }
  try { return [DateTimeOffset]::FromUnixTimeSeconds([int64]$Matches['ts']).ToLocalTime().ToString('yyyy-MM-dd') } catch { return $null }
}

function Get-TitleFromName([string]$name){
  $base = [IO.Path]::GetFileNameWithoutExtension($name)
  if($base -match '^[0-9]{10}_(?<t>.+)$'){ return $Matches['t'] } else { return $base }
}

function Find-ExistingVersion([string]$text){
  $m = [regex]::Match($text, '(?m)^-\s*版本：\s*(.+?)\s*$')
  if($m.Success){ return $m.Groups[1].Value.Trim() }
  return $null
}

function Build-Header([string]$title,[string]$date,[string]$version,[string]$eol){
  $lines = @(
    "# **$title**",
    "",
    "- 作者：GaoZheng",
    "- 日期：$date",
    "- 版本：$version",
    "",
    "---",
    ""
  )
  return [string]::Join($eol, $lines)
}

function Build-Footer([string]$date,[string]$eol){
  $year = 2025
  try { if($date -match '^(\d{4})-'){ $year = [int]$Matches[1] } } catch {}
  $copy = if($year -lt 2025){ ("{0}-2025" -f $year) } else { '2025' }
  $lines = @(
    "",
    "---",
    "",
    "**许可声明 (License)**",
    "",
    "Copyright (C) $copy GaoZheng ",
    "",
    "本文档采用[知识共享-署名-非商业性使用-禁止演绎 4.0 国际许可协议 (CC BY-NC-ND 4.0)](https://creativecommons.org/licenses/by-nc-nd/4.0/deed.zh-Hans)进行许可。"
  )
  return [string]::Join($eol, $lines)
}

function Strip-ExistingHeader([string]$text){
  # 行级解析，限制在文件前 200 行内查找头部，避免大正则回溯超时
  $lines = $text -split "\r\n|\n", -1
  $maxScan = [Math]::Min(200, $lines.Length)
  $i = 0
  $sawTitle = $false
  $sawMeta  = $false
  $removed  = $false

  function IsTitleLine([string]$s){
    $t = $s.Trim()
    if([string]::IsNullOrWhiteSpace($t)){ return $false }
    # 匹配：带/不带加粗的居中标题 或 任何 Markdown 级别标题（# 开头）
    if($t -match '^#{1,6}\s*(?:<center>\s*)?.+?(?:\s*</center>)?$'){ return $true }
    if($t -match '^(?:<center>\s*)?\*\*.*\*\*(?:\s*</center>)?$'){ return $true }
    if($t -match '^(?:<center>\s*).+?(?:\s*</center>)$'){ return $true }
    return $false
  }

  function IsSubTitle([string]$s){
    $t = $s.Trim(); return ($t -match '^[—–-]{2,}.*$')
  }

  # 跳过文件开头的空行
  while($i -lt $maxScan -and [string]::IsNullOrWhiteSpace($lines[$i])){ $i++ }

  # 标题行（含 <center>）
  if($i -lt $maxScan -and (IsTitleLine $lines[$i])){ $sawTitle = $true; $removed = $true; $i++ }

  # 跳过标题后的空行
  while($i -lt $maxScan -and [string]::IsNullOrWhiteSpace($lines[$i])){ $i++ }

  # 副标题行（破折号/短横线开始）
  if($i -lt $maxScan -and (IsSubTitle $lines[$i])){ $removed = $true; $i++ }

  # 跳过副标题后的空行
  while($i -lt $maxScan -and [string]::IsNullOrWhiteSpace($lines[$i])){ $i++ }

  # 作者/日期/版本元信息（若存在于顶部则剔除）
  $metaRemoved = $false
  $loopGuard = 0
  while($i -lt $maxScan -and $loopGuard -lt 20){
    $trim = $lines[$i].Trim()
    if($trim -match '^-\s*作者：'){ $removed=$true; $metaRemoved=$true; $i++ }
    elseif($trim -match '^-\s*日期：'){ $removed=$true; $metaRemoved=$true; $i++ }
    elseif($trim -match '^-\s*版本：'){ $removed=$true; $metaRemoved=$true; $i++ }
    elseif([string]::IsNullOrWhiteSpace($trim)){ $i++ }
    else { break }
    $loopGuard++
  }

  # 可选的分隔线
  if($i -lt $maxScan -and $lines[$i].Trim() -eq '---'){ $removed = $true; $i++ }
  # 分隔线之后的单个空行
  if($removed -and $i -lt $lines.Length -and [string]::IsNullOrWhiteSpace($lines[$i])){ $i++ }

  if($removed -or $metaRemoved){
    $remain = @()
    if($i -lt $lines.Length){ $remain = $lines[$i..($lines.Length-1)] }
    $eol = Get-Eol $text
    return [string]::Join($eol, $remain)
  }

  return $text
}

function Strip-ExistingFooter([string]$text){
  # 行级解析：在文件尾 200 行范围内查找 '---' 与 '**许可声明 (License)**' 块并去除
  $lines = $text -split "\r\n|\n", -1
  $from = [Math]::Max(0, $lines.Length - 200)
  $sep = -1; $lic = -1
  for($i=$lines.Length-1; $i -ge $from; $i--){
    $t = $lines[$i].Trim()
    if($lic -lt 0 -and $t -eq '**许可声明 (License)**'){ $lic = $i; continue }
    if($lic -ge 0 -and $t -eq '---'){ $sep = $i; break }
  }
  if($sep -ge 0 -and $lic -ge 0 -and $sep -lt $lic){
    $keep = @()
    if($sep -gt 0){ $keep = $lines[0..($sep-1)] }
    $eol = Get-Eol $text
    return [string]::Join($eol, $keep)
  }
  return $text
}

function Normalize-One([IO.FileInfo]$file){
  $orig = Read-Text $file.FullName
  $eol = Get-Eol $orig

  $name = $file.Name
  $title = Get-TitleFromName $name
  $date  = Get-DateFromName $name
  if(-not $date){ return @{ changed=$false; reason='no_date_from_name' } }

  $version = Find-ExistingVersion $orig
  if(-not $version){ $version = 'v1.0.0' }

  $header = Build-Header -title $title -date $date -version $version -eol $eol

  # 先移除脚本规范化生成过的标准头（锚定文件起始，避免重复插入）
  $ourHeaderPattern = '^(?ms)^#\s+\*\*.+?\*\*\s*\r?\n\s*\r?\n-\s*作者：.*?\r?\n-\s*日期：.*?\r?\n-\s*版本：.*?\r?\n\s*\r?\n---\s*\r?\n\s*\r?\n'
  $clean = [regex]::Replace($orig, $ourHeaderPattern, '')

  # 去除旧头与旧尾
  $body = Strip-ExistingHeader $clean
  $body = Strip-ExistingFooter $body

  # 二次清理：若正文起始仍残留旧式标题/分隔线，行级删除
  $arr = $body -split "\r\n|\n", -1
  $j = 0
  while($j -lt $arr.Length -and [string]::IsNullOrWhiteSpace($arr[$j])){ $j++ }
  function _IsTitle2([string]$s){ $t=$s.Trim(); return ($t -match '^#{1,6}\s*(?:<center>\s*)?.+?(?:\s*</center>)?$' -or $t -match '^(?:<center>\s*).+?(?:\s*</center>)$' -or $t -match '^(?:<center>\s*)?\*\*.*\*\*(?:\s*</center>)?$') }
  if($j -lt $arr.Length -and (_IsTitle2 $arr[$j])){ $j++ }
  while($j -lt $arr.Length -and [string]::IsNullOrWhiteSpace($arr[$j])){ $j++ }
  if($j -lt $arr.Length -and $arr[$j].Trim() -eq '---'){ $j++ }
  if($j -lt $arr.Length -and [string]::IsNullOrWhiteSpace($arr[$j])){ $j++ }
  if($j -gt 0){
    if($j -lt $arr.Length){ $body = [string]::Join($eol, $arr[$j..($arr.Length-1)]) } else { $body = '' }
  }

  # 去除开头多余空行
  $body = [regex]::Replace($body, '^(?:\s*\r?\n)+', '')

  $footer = Build-Footer -date $date -eol $eol
  # 去除正文尾部多余空行，保证尾部分隔线上方至少一行空行
  $body = [regex]::Replace($body, '(\r?\n\s*)+$', '')
  $final = $header + $body + $footer
  if(-not $final.EndsWith($eol)){ $final += $eol }

  $changed = ($final -ne $orig)
  return @{ changed=$changed; content=$final; version=$version }
}

function Is-ValidName([string]$name,[string]$pat){ return [regex]::IsMatch($name, $pat) }

if(-not (Test-Path -LiteralPath $Root)){ throw "目录不存在：$Root" }

$files = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter *.md |
  Where-Object { Is-ValidName $_.Name $NamePattern } |
  Where-Object { $_.Name -notin 'INDEX.md','LICENSE.md','KERNEL_REFERENCE_README.md' }

if($Limit -gt 0){ $files = $files | Select-Object -First $Limit }

$scanned=0; $updated=0; $skipped=0
foreach($f in $files){
  $scanned++
  $res = Normalize-One $f
  if(-not $res.changed){ $skipped++; continue }
  if($PSCmdlet.ShouldProcess($f.FullName, 'Normalize header/footer style')){
    Write-Text $f.FullName $res.content
    Write-Host ("Updated: {0}" -f $f.FullName)
    $updated++
  }
}

Write-Host ("Summary => scanned={0} updated={1} skipped={2}" -f $scanned,$updated,$skipped)

# 用法示例：
# 1) 干跑预览：
#    pwsh -NoLogo -File script/normalize_full_reference_style.ps1 -Root 'src/full_reference' -WhatIf
# 2) 实际执行：
#    pwsh -NoLogo -File script/normalize_full_reference_style.ps1 -Root 'src/full_reference'
# 3) 仅处理前 10 个：
#    pwsh -NoLogo -File script/normalize_full_reference_style.ps1 -Limit 10 -WhatIf
