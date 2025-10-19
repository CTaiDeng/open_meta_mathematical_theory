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

# 2) 校验文档编码为 UTF-8（严格），文件列表只检查本次暂存的文档类
$docExts = @('.md', '.mdx', '.txt', '.csv')
$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$badEncoding = @()

foreach ($rel in $stagedPaths) {
    $ext = [System.IO.Path]::GetExtension($rel).ToLowerInvariant()
    if ($docExts -notcontains $ext) { continue }
    $abs = Join-Path $top $rel
    if (-not (Test-Path -LiteralPath $abs)) { continue }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($abs)
        # 若非 UTF-8（严格，无替换解码）则会抛异常
        $null = $utf8Strict.GetString($bytes)
    } catch {
        $badEncoding += $rel
    }
}

if ($badEncoding.Count -gt 0) {
    Write-Err '以下文档未满足 UTF-8 编码要求（请转换为 UTF-8 后重试）：'
    $badEncoding | ForEach-Object { Write-Host " - $_" }
    exit 1
}

if ($SelfTest) {
    Write-Info '自检完成：renormalize + UTF-8 校验工作正常。'
}

exit 0

