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
    Write-Err "未在 Git 仓库中，跳过钩子。"
    exit 0
}

$staged = (Invoke-Git diff --cached --name-only) -as [string]
if ([string]::IsNullOrWhiteSpace($staged)) {
    # 无暂存文件，直接通过
    exit 0
}

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

# 1) 统一按 .gitattributes 对齐（尊重 .gitignore）；若 .gitattributes 变更则全仓库重规范化
$stagedPaths = $staged -split "`n" | Where-Object { $_ -and $_.Trim() -ne '' }
$gitattributesChanged = $stagedPaths -contains '.gitattributes'

if ($gitattributesChanged) {
    Write-Info '检测到 .gitattributes 变更，执行全仓库 renormalize...'
    Invoke-Git add --renormalize . | Out-Null
} else {
    Write-Info '执行 renormalize（作用于工作区，遵循 .gitignore）...'
    Invoke-Git add --renormalize . | Out-Null
}

# 2) 基于 .gitattributes 检查：UTF-8（无 BOM）+ LF
$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$badBom = @(); $badCrlf = @(); $badUtf8 = @()

foreach ($rel in $stagedPaths) {
    $abs = Join-Path $top $rel
    if (-not (Test-Path -LiteralPath $abs -PathType Leaf)) { continue }
    $attr = Get-GitAttr $rel
    $isText = $false
    $expectLf = $false
    if ($attr.ContainsKey('text')) {
        $v = $attr['text']
        $isText = ($v -ne 'unset' -and $v -ne 'unspecified')
    }
    if ($attr.ContainsKey('eol')) {
        $expectLf = ($attr['eol'] -eq 'lf')
    }
    # 若未标记 text，但 eol=lf 已指定，也按文本检查
    if (-not $isText -and $expectLf) { $isText = $true }
    if (-not $isText) { continue }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($abs)
        if (Has-BOM $bytes) { $badBom += $rel }
        $text = $utf8Strict.GetString($bytes) # 严格 UTF-8 解码
        if ($expectLf -and ($text -match "\r\n")) { $badCrlf += $rel }
    } catch {
        $badUtf8 += $rel
    }
}

if ($badUtf8.Count -gt 0 -or $badBom.Count -gt 0 -or $badCrlf.Count -gt 0) {
    if ($badUtf8.Count -gt 0) {
        Write-Err '以下文件非严格 UTF-8 可解码（请转为 UTF-8）：'
        $badUtf8 | ForEach-Object { Write-Host " - $_" }
    }
    if ($badBom.Count -gt 0) {
        Write-Err '以下文件包含 UTF-8 BOM（请移除 BOM）：'
        $badBom | ForEach-Object { Write-Host " - $_" }
    }
    if ($badCrlf.Count -gt 0) {
        Write-Err '以下文件存在 CRLF 行尾，但 .gitattributes 要求 LF：'
        $badCrlf | ForEach-Object { Write-Host " - $_" }
    }
    Write-Warn '可尝试运行 `pwsh -NoLogo -File convert_to_utf8_lf.ps1` 进行批量修复，或手动规范后重试提交。'
    exit 1
}

if ($SelfTest) {
    Write-Info '自检完成：renormalize + UTF-8 无 BOM + LF 校验均通过。'
}

exit 0
