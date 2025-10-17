#!/usr/bin/env pwsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2025 GaoZheng

param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$RepoUrl,

  [Parameter(Mandatory = $false)]
  [string]$Branch = "",

  [Parameter(Mandatory = $false)]
  [string]$Dest = "",

  [Parameter(Mandatory = $false)]
  [string]$ExcludeJson = "partial_clone_exclude_whitelist.json"
)

function Fail($msg) {
  Write-Error $msg
  exit 1
}

function Normalize-RepoPath([string]$p) {
  if ($null -eq $p) { return "" }
  $np = $p.Replace('\\','/').Trim()
  # 去除路径前导斜杠（保留以点开头的隐藏目录/文件名）
  $np = ($np -replace '^/+', '')
  # 去除末尾斜杠，统一用通用排除规则覆盖目录和文件
  $np = ($np -replace '/+$', '')
  return $np
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Fail "未检测到 git，请先安装 Git 再重试。"
}

$startDir = Get-Location
$repoRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($repoRoot)) { $repoRoot = $startDir }

if ([string]::IsNullOrWhiteSpace($Dest)) {
  $lastSegment = ($RepoUrl -replace '\\','/' -split '/')[ -1 ]
  $repoName = ($lastSegment -replace '^.+:', '') -replace '\.git$',''
  if ([string]::IsNullOrWhiteSpace($repoName)) { Fail "无法从地址解析仓库名，请指定 -Dest。" }
  $Dest = $repoName
}

if (Test-Path -LiteralPath $Dest -PathType Container) {
  if ((Get-ChildItem -LiteralPath $Dest -Force | Measure-Object).Count -gt 0) {
    Fail "目标目录已存在且非空：$Dest"
  }
}

Write-Host "[partial-clone] 开始：$RepoUrl -> $Dest"

# 组装 clone 参数（部分克隆 + 不检出）
$cloneArgs = @("clone", "--filter=blob:none", "--depth=1", "--no-checkout")
if ($Branch -and $Branch.Trim() -ne "") { $cloneArgs += @("--branch", $Branch) }
$cloneArgs += @($RepoUrl, $Dest)

& git @cloneArgs
if ($LASTEXITCODE -ne 0) { Fail "git clone 失败，请检查仓库地址/网络/权限。" }

Push-Location $Dest

# 读取排除白名单 JSON（默认在脚本所在目录，即项目根目录）
if ([System.IO.Path]::IsPathRooted($ExcludeJson)) {
  $excludeJsonPath = $ExcludeJson
} else {
  $excludeJsonPath = Join-Path -Path $repoRoot -ChildPath $ExcludeJson
}

$exclude = @()
if (Test-Path -LiteralPath $excludeJsonPath) {
  try {
    $jsonObj = Get-Content -LiteralPath $excludeJsonPath -Encoding utf8 -Raw | ConvertFrom-Json
    if ($null -ne $jsonObj.exclude) { $exclude += @($jsonObj.exclude) }
    # 兼容可选键：支持专门为“文件”列出的白名单数组（非必需）
    if ($null -ne $jsonObj.exclude_files) { $exclude += @($jsonObj.exclude_files) }
    if ($null -ne $jsonObj.excludeFiles) { $exclude += @($jsonObj.excludeFiles) }
  } catch {
    Fail "解析排除白名单失败：$excludeJsonPath"
  }
} else {
  Write-Host "[partial-clone] 未找到白名单文件：$excludeJsonPath，将仅默认排除 .git。"
}

$exclude = $exclude | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -ne "" } | Select-Object -Unique
if ($exclude -notcontains ".git") { $exclude += ".git" }

# 配置 sparse-checkout（先写规则，再检出分支，避免无谓拉取）
& git config core.sparseCheckout true
& git sparse-checkout init --no-cone | Out-Null

# 构建稀疏模式：包含全部（/*），再排除白名单中的路径（目录或文件）
$patterns = New-Object 'System.Collections.Generic.List[string]'
$patterns.Add("/*") | Out-Null
$(
  foreach ($item in $exclude) {
    if ($item -eq ".git") { continue }
    $safe = Normalize-RepoPath $item
    if ([string]::IsNullOrWhiteSpace($safe)) { continue }
    # 通用排除：既匹配同名文件，也匹配同名目录
    $patterns.Add("!/$safe")   | Out-Null
    $patterns.Add("!/$safe/*") | Out-Null
    $safe
  }
) | Out-Null

$scFile = Join-Path -Path ".git" -ChildPath "info/sparse-checkout"
$patterns | Set-Content -LiteralPath $scFile -Encoding utf8

# 解析默认分支（若未指定）
if (-not ($Branch -and $Branch.Trim() -ne "")) {
  $head = ""
  $sym = (& git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>$null)
  if ($LASTEXITCODE -eq 0 -and $sym) {
    $head = ($sym.Trim() -replace '^origin/','')
  }
  if (-not $head) {
    $info = (& git remote show origin)
    $m = ($info | Select-String -Pattern 'HEAD branch:\s+(.+)$' | Select-Object -First 1)
    if ($m) { $head = $m.Matches[0].Groups[1].Value.Trim() }
  }
  if (-not $head) { $head = "main" }
  $Branch = $head
}

# 检出目标分支（优先创建本地跟踪分支）
$checkoutOk = $false
& git checkout -q -b $Branch --track ("origin/" + $Branch)
if ($LASTEXITCODE -eq 0) { $checkoutOk = $true }
if (-not $checkoutOk) {
  & git checkout -q ("origin/" + $Branch)
  if ($LASTEXITCODE -eq 0) { $checkoutOk = $true }
}
if (-not $checkoutOk) { Fail "无法检出分支：$Branch" }

# 重新应用稀疏规则，确保工作区仅包含所需内容
& git sparse-checkout reapply | Out-Null

Write-Host "[partial-clone] 完成。已排除路径："
$excludedPrinted = $exclude | Where-Object { $_ -ne ".git" }
if ($excludedPrinted.Count -eq 0) {
  Write-Host "  (无额外排除项，默认仅排除 .git)"
} else {
  foreach ($i in $excludedPrinted) { Write-Host ("  - " + $i) }
}

Pop-Location
exit 0
