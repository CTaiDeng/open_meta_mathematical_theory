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
  [string]$ExcludeJson = "clone_exclude_whitelist.json"
)

function Fail($msg) {
  Write-Error $msg
  exit 1
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Fail "未检测到 git，请先安装 Git 再重试。"
}

$startDir = Get-Location

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

# 读取排除白名单 JSON（默认在运行脚本时所在仓库根目录）
if ([System.IO.Path]::IsPathRooted($ExcludeJson)) {
  $excludeJsonPath = $ExcludeJson
} else {
  $excludeJsonPath = Join-Path -Path $startDir -ChildPath $ExcludeJson
}

$exclude = @()
if (Test-Path -LiteralPath $excludeJsonPath) {
  try {
    $jsonObj = Get-Content -LiteralPath $excludeJsonPath -Encoding utf8 -Raw | ConvertFrom-Json
    if ($null -ne $jsonObj.exclude) { $exclude = @($jsonObj.exclude) }
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

# 构建稀疏模式：包含全部（/*），再排除列出的顶层目录
$patterns = New-Object 'System.Collections.Generic.List[string]'
$patterns.Add("/*") | Out-Null
foreach ($item in $exclude) {
  if ($item -eq ".git") { continue }
  $safe = $item.TrimStart('.', '/', '\\').TrimEnd('/', '\\')
  if ([string]::IsNullOrWhiteSpace($safe)) { continue }
  $patterns.Add("!/$safe")   | Out-Null
  $patterns.Add("!/$safe/*") | Out-Null
}

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

Write-Host "[partial-clone] 完成。已排除目录："
$excludedPrinted = $exclude | Where-Object { $_ -ne ".git" }
if ($excludedPrinted.Count -eq 0) {
  Write-Host "  (无额外排除项，默认仅排除 .git)"
} else {
  foreach ($i in $excludedPrinted) { Write-Host ("  - " + $i) }
}

Pop-Location
exit 0

