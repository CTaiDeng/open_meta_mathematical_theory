<#
SPDX-License-Identifier: GPL-3.0-only
Copyright (C) 2025 GaoZheng
#>

param(
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

function Write-Info($msg) { Write-Host "[gitattributes] $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host "[gitattributes] $msg" -ForegroundColor Yellow }
function Write-Err($msg) { Write-Host "[gitattributes] $msg" -ForegroundColor Red }

function Invoke-Git {
  param([Parameter(ValueFromRemainingArguments=$true)] [string[]]$Args)
  & git @Args
}

try {
  $top = (Invoke-Git rev-parse --show-toplevel).Trim()
} catch {
  Write-Err '未在 Git 仓库内，跳过钩子。'
  exit 0
}

# 获取暂存文件列表（逐行，禁用 quotepath；仅检查不阻拦）
$staged = @()
try {
  $staged = @(Invoke-Git -Args @('-c','core.quotepath=false','diff','--cached','--name-only'))
} catch { $staged = @() }

function Get-GitAttr([string]$path){
  $raw = Invoke-Git check-attr text eol -- $path 2>$null
  $attrs = @{}
  foreach($line in ($raw -split "`n")){
    if(-not $line){ continue }
    $parts = $line -split ':'
    if($parts.Count -ge 3){
      $name = $parts[1].Trim()
      $val  = ($parts[2..($parts.Count-1)] -join ':').Trim()
      $attrs[$name] = $val
    }
  }
  return $attrs
}

function Has-BOM([byte[]]$bytes){
  return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

# 先运行 Zenodo 统计脚本，确保提交前刷新并自动加入暂存
$fetchScript = Join-Path $top 'script/fetch_zenodo_stats.py'
if (Test-Path -LiteralPath $fetchScript) {
  $pythonCmd = $null
  foreach ($candidate in @('python','python3','py')) {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($cmd) { $pythonCmd = $cmd.Source; break }
  }
  if (-not $pythonCmd) {
    Write-Warn '未找到可用的 python 解释器，跳过 script/fetch_zenodo_stats.py。'
  } else {
    Write-Info "运行 $($fetchScript.Substring($top.Length + 1)) 刷新 Zenodo 统计..."
    try {
      & $pythonCmd $fetchScript | Out-Null
      $generated = @(
        'zenodo_stats.md',
        'README.md',
        'out/zenodo_17651584_stats.csv',
        'out/zenodo_17651584_stats.svg'
      )
      $toAdd = @()
      foreach ($rel in $generated) {
        $abs = Join-Path $top $rel
        if (Test-Path -LiteralPath $abs) { $toAdd += $rel }
      }
      if ($toAdd.Count -gt 0) {
        Write-Info "自动添加统计输出到暂存区：$($toAdd -join ', ')"
        Invoke-Git add -- @toAdd
      }
    } catch {
      Write-Warn "执行失败：$($_.Exception.Message)，跳过自动刷新（不阻塞提交）。"
    }
  }
}

# 再次获取暂存文件列表（包含自动添加的输出）
$staged = @()
try {
  $staged = @(Invoke-Git -Args @('-c','core.quotepath=false','diff','--cached','--name-only'))
} catch { $staged = @() }
$stagedPaths = @($staged | ForEach-Object { $_.Trim() }) | Where-Object { $_ -and $_ -ne '' }
if (-not $stagedPaths -or $stagedPaths.Count -eq 0) { exit 0 }

# 1) 统一做 renormalize（仅提示，不阻拦）
$gitattributesChanged = $stagedPaths -contains '.gitattributes'
if ($gitattributesChanged) {
  Write-Info '检测到 .gitattributes 变更，执行全仓库 renormalize...'
  Invoke-Git add --renormalize . | Out-Null
} else {
  Write-Info '执行 renormalize（遵循 .gitignore），仅提示不阻拦...'
  Invoke-Git add --renormalize . | Out-Null
}

# 2) 按 .gitattributes 校验：UTF-8（无BOM）+ LF（仅告警，不阻拦）
$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$badBom = @(); $badCrlf = @(); $badUtf8 = @()

foreach ($rel in $stagedPaths) {
  $abs = Join-Path $top $rel
  $exists = Test-Path -LiteralPath $abs -PathType Leaf -ErrorAction SilentlyContinue
  if (-not $exists) { continue }
  $attr = Get-GitAttr $rel
  $isText = $false
  $expectLf = $false
  if ($attr.ContainsKey('text')) {
    $v = $attr['text']
    $isText = ($v -ne 'unset' -and $v -ne 'unspecified')
  }
  if ($attr.ContainsKey('eol')) { $expectLf = ($attr['eol'] -eq 'lf') }
  if (-not $isText -and $expectLf) { $isText = $true }
  if (-not $isText) { continue }
  try {
    $bytes = [System.IO.File]::ReadAllBytes($abs)
    if (Has-BOM $bytes) { $badBom += $rel }
    $text = $utf8Strict.GetString($bytes)
    if ($expectLf -and ($text -match "\r\n")) { $badCrlf += $rel }
  } catch {
    $badUtf8 += $rel
  }
}

if ($badUtf8.Count -gt 0 -or $badBom.Count -gt 0 -or $badCrlf.Count -gt 0) {
  if ($badUtf8.Count -gt 0) {
    Write-Err '检测到无法严格按 UTF-8 解码的文件（请转为 UTF-8）。'
    $badUtf8 | ForEach-Object { Write-Host " - $_" }
  }
  if ($badBom.Count -gt 0) {
    Write-Err '检测到包含 UTF-8 BOM 的文件（请移除 BOM）。'
    $badBom | ForEach-Object { Write-Host " - $_" }
  }
  if ($badCrlf.Count -gt 0) {
    Write-Err '检测到 CRLF 行尾，.gitattributes 约定为 LF。'
    $badCrlf | ForEach-Object { Write-Host " - $_" }
  }
  Write-Warn '仅检查不阻拦：建议运行 `pwsh -NoLogo -File convert_to_utf8_lf.ps1` 修复后再提交。'
}

if ($SelfTest) {
  Write-Info '自检完成：renormalize + UTF-8 无BOM + LF 校验仅提示。'
}

exit 0
