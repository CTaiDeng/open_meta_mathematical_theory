<#
SPDX-License-Identifier: GPL-3.0-only
Copyright (C) 2025 GaoZheng

功能：为 src/app_docs 目录生成或更新 README.md 索引，仅包含形如
      "<unittime秒>_*.md" 的顶层 Markdown 文件（排除 LICENSE.md）。

说明：实现思路参考 script/clone_docs_from_sub_projects.ps1 中索引相关代码，
      包括摘要抽取（优先读取 "## 摘要" 段落）与 UTF-8（无BOM）+ LF 输出。
#>
[CmdletBinding()] param(
  [string]$TargetDir = 'src/app_docs',
  [int]$MaxChars = 500
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

function Get-AbstractFromSection([string]$path, [int]$maxChars){
  try { $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 } catch { return '' }
  $m = [Regex]::Match($raw, '(?ms)^\s*##\s*摘要\s*$\s*([\s\S]*?)(?=^\s*#{1,6}\s|\z)')
  if(-not $m.Success){ return '' }
  $text = $m.Groups[1].Value
  $text = $text -replace '(?ms)```.*?```',''
  $text = $text -replace '(?m)^\s*`{3,}.*$',''
  $text = $text -replace '!\[[^\]]*\]\([^)]*\)',''
  $text = $text -replace '\[([^\]]+)\]\([^)]*\)', '$1'
  $text = $text -replace '`',''
  $text = $text -replace '(?m)^\s*#{1,6}\s*',''
  $text = $text -replace '(?m)^\s*>\s*',''
  $text = $text -replace '(?m)^\s*[-*_]{3,}\s*$',''
  $text = ($text -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) -join ' '
  $text = ($text -replace '\s+',' ').Trim()
  if([string]::IsNullOrWhiteSpace($text)){ return '' }
  if($text.Length -gt $maxChars){
    $text = $text.Substring(0, $maxChars).Trim()
    $text += '…'
  }
  return $text
}

function BuildIndexLines([string]$dir, [int]$maxChars){
  if(-not (Test-Path -LiteralPath $dir -PathType Container)){ return @() }
  $files = Get-ChildItem -LiteralPath $dir -File -Filter '*.md' |
    Where-Object { $_.Name -ne 'LICENSE.md' -and ($_.Name -match '^[0-9]+_.*\.md$') } |
    Sort-Object Name
  $lines = New-Object System.Collections.Generic.List[string]
  foreach($f in $files){
    $lines.Add('- `' + $f.Name + '`')
    $abs = Get-AbstractFromSection -path $f.FullName -maxChars $maxChars
    if(-not [string]::IsNullOrWhiteSpace($abs)){
      $lines.Add('  ' + $abs)
    }
  }
  return $lines
}

function Write-Readme([string]$dir, [System.Collections.Generic.List[string]]$lines){
  $readmePath = Join-Path $dir 'README.md'
  $title = '# app_docs 索引（自动生成）'
  $count = $lines | Where-Object { $_ -like '- *' } | Measure-Object | Select-Object -ExpandProperty Count
  $header = @(
    $title,
    '',
    "- 总计：$count 篇；仅收录形如 '<unittime秒>_*.md' 的文件",
    ''
  )
  $out = New-Object System.Collections.Generic.List[string]
  foreach($ln in $header){ $out.Add($ln) }
  foreach($ln in $lines){ $out.Add($ln) }

  $enc = [System.Text.UTF8Encoding]::new($false)
  $text = ($out -join "`n")
  if(-not $text.EndsWith("`n")){ $text += "`n" }
  [System.IO.File]::WriteAllText($readmePath, $text, $enc)
}

# 兼容可能的目录名误差（可传入 -TargetDir 覆盖）
if(-not (Test-Path -LiteralPath $TargetDir -PathType Container)){
  $alt = 'src/app_doc'
  if(Test-Path -LiteralPath $alt -PathType Container){ $TargetDir = $alt }
}

if(-not (Test-Path -LiteralPath $TargetDir -PathType Container)){
  Write-Error "目录不存在：$TargetDir"
  exit 1
}

$lines = BuildIndexLines -dir $TargetDir -maxChars $MaxChars
Write-Readme -dir $TargetDir -lines $lines
Write-Host "已更新索引：$(Join-Path $TargetDir 'README.md')" -ForegroundColor Green
