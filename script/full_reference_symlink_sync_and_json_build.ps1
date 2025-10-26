# Copyright (C) 2025 GaoZheng
# SPDX-License-Identifier: GPL-3.0-only
# This file is part of this project.
# Licensed under the GNU General Public License version 3.
# See https://www.gnu.org/licenses/gpl-3.0.html for details.

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  # 源目录配置文件（JSON）。默认读取 src/full_reference/Link.json。
  [string]$Config = 'src/full_reference/Link.json',
  # 符号链接的目标根目录（仓库内）。
  [string]$DestRoot = 'src/full_reference',
  # 生成链接名 -> 源文件绝对路径的映射 JSON（写入到仓库内）。
  [string]$ExportMapPath = 'src/full_reference/symlink_target_map.json',
  # 是否递归扫描源目录。
  [switch]$Recurse = $true,
  # 重复文件（同名）选择策略：first（按源目录顺序优先）、latest（按源文件修改时间最新）。
  [ValidateSet('first','latest')]
  [string]$DuplicatePolicy = 'first'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

# 防御性初始化（处理某些环境下参数未绑定导致的 StrictMode 报错）
if (-not $PSBoundParameters.ContainsKey('Config') -or [string]::IsNullOrWhiteSpace($Config)) {
  $script:Config = 'src/full_reference/Link.json'
}
if (-not $PSBoundParameters.ContainsKey('DestRoot') -or [string]::IsNullOrWhiteSpace($DestRoot)) {
  $script:DestRoot = 'src/full_reference'
}

function Resolve-RepoPath([string]$p){
  if ([string]::IsNullOrWhiteSpace($p)) { return $null }
  try { return (Resolve-Path -LiteralPath $p -ErrorAction Stop).Path } catch { return $p }
}

function Load-SourcesFromConfig([string]$configPath){
  if (-not (Test-Path -LiteralPath $configPath)) { return $null }
  $raw = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
  $json = $raw | ConvertFrom-Json -ErrorAction Stop
  $paths = New-Object System.Collections.Generic.List[string]
  if ($json -is [System.Collections.IEnumerable]) {
    foreach($x in $json){ if ($x -is [string]) { $paths.Add($x) } elseif ($x.PSObject.Properties['path']) { $paths.Add([string]$x.path) } }
  } elseif ($json.PSObject.Properties['sources']) {
    foreach($x in $json.sources){ if ($x -is [string]) { $paths.Add($x) } elseif ($x.PSObject.Properties['path']) { $paths.Add([string]$x.path) } }
  } elseif ($json.PSObject.Properties['Paths']) {
    foreach($x in $json.Paths){ if ($x) { $paths.Add([string]$x) } }
  }
  return ($paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

# 为避免脚本编码/解析问题，这里不再内置含中文字符的默认目录。
$DefaultSources = @()

function Is-ValidKernelName([string]$name){
  if (-not ($name -match '^[0-9]{10}_.+\.md$')) { return $false }
  $title = ([IO.Path]::GetFileNameWithoutExtension($name) -replace '^[0-9]{10}_','').Trim()
  if ([string]::IsNullOrWhiteSpace($title)) { return $false }
  if ($title -match '^[._-]+$') { return $false }
  return $true
}

function Ensure-DestRoot([string]$path){ if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path | Out-Null } }

function Norm([string]$p){ try { return [IO.Path]::GetFullPath($p) } catch { return $p } }

function Build-LinkTargetMap([string]$destAbs){
  $map = [ordered]@{}
  $items = Get-ChildItem -LiteralPath $destAbs -File -ErrorAction SilentlyContinue
  foreach($e in $items){
    try {
      $itm = Get-Item -LiteralPath $e.FullName -Force -ErrorAction Stop
      if (-not ($itm.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
      $t = $itm.Target
      if ([string]::IsNullOrWhiteSpace($t)) { continue }
      if (-not [IO.Path]::IsPathRooted($t)){
        $base = Split-Path -Parent $e.FullName
        $t = Join-Path $base $t
      }
      $map[$e.Name] = Norm $t
    } catch { }
  }
  return $map
}

function Save-LinkTargetMap($map,[string]$path){
  $json = ($map | ConvertTo-Json -Depth 5)
  $parent = Split-Path -Path $path -Parent
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent | Out-Null }
  $enc = [System.Text.UTF8Encoding]::new($false)
  $text = $json -replace "`r`n","`n"
  [System.IO.File]::WriteAllText($path, $text, $enc)
}

$sources = Load-SourcesFromConfig (Resolve-RepoPath $Config)
if (-not $sources -or $sources.Count -eq 0) {
  throw "No sources found in '$Config'. Please edit src/full_reference/Link.json to provide source directories."
}
$destAbs = Resolve-RepoPath $DestRoot
Ensure-DestRoot $destAbs

# 收集期望的链接映射：Name -> TargetAbs（按策略去重）
$desired = @{}
$dups = 0
for ($ri=0; $ri -lt $sources.Count; $ri++){
  $rp = Resolve-RepoPath $sources[$ri]
  if (-not (Test-Path -LiteralPath $rp)) { Write-Warning "源目录不存在：$rp"; continue }
  $files = if ($Recurse) { Get-ChildItem -LiteralPath $rp -Recurse -File -Filter *.md } else { Get-ChildItem -LiteralPath $rp -File -Filter *.md }
  foreach($f in $files){
    if (-not (Is-ValidKernelName $f.Name)) { continue }
    $key = $f.Name
    if (-not $desired.ContainsKey($key)) {
      $desired[$key] = Norm $f.FullName
    } else {
      $dups++
      if ($DuplicatePolicy -eq 'latest') {
        $curr = Get-Item -LiteralPath $desired[$key] -ErrorAction SilentlyContinue
        if ($curr -and $f.LastWriteTime -gt $curr.LastWriteTime) { $desired[$key] = Norm $f.FullName }
      }
    }
  }
}

$created=0; $updated=0; $removed=0; $skipped=0

# 先清理目标目录中无效/孤儿链接（仅处理符号链接且命名符合规则）
$existing = Get-ChildItem -LiteralPath $destAbs -File -ErrorAction SilentlyContinue
foreach($e in $existing){
  if (-not ($e.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
  if (-not (Is-ValidKernelName $e.Name)) { continue }
  $needRemove = $false
  try {
    $target = (Get-Item -LiteralPath $e.FullName -Force).Target
    if (-not $target) { $needRemove = $true }
    else {
      $tAbs = Norm $target
      if (-not (Test-Path -LiteralPath $tAbs)) { $needRemove = $true }
      elseif (-not $desired.ContainsKey($e.Name)) { $needRemove = $true }
    }
  } catch { $needRemove = $true }

  if ($needRemove) {
    if ($PSCmdlet.ShouldProcess($e.FullName, 'Remove orphan/broken symlink')){
      Remove-Item -LiteralPath $e.FullName -Force -ErrorAction SilentlyContinue
      $removed++
    }
  }
}

# 创建/更新所需符号链接
foreach($name in $desired.Keys){
  $targetAbs = $desired[$name]
  $linkPath = Join-Path $destAbs $name
  if (Test-Path -LiteralPath $linkPath){
    $item = Get-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue
    if (-not $item) { continue }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint){
      # 已存在的符号链接，若目标不同则更新
      $currTarget = $null
      try { $currTarget = (Get-Item -LiteralPath $linkPath -Force).Target } catch {}
      if (-not $currTarget -or (Norm $currTarget) -ne (Norm $targetAbs)){
        if ($PSCmdlet.ShouldProcess($linkPath, 'Update symlink target')){
          Remove-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue
          New-Item -ItemType SymbolicLink -Path $linkPath -Target $targetAbs | Out-Null
          $updated++
        }
      } else {
        # 目标一致，无需动作
      }
    } else {
      # 不是符号链接，跳过避免覆盖真实文件
      $skipped++
    }
  } else {
    if ($PSCmdlet.ShouldProcess($linkPath, "Create symlink -> $targetAbs")){
      New-Item -ItemType SymbolicLink -Path $linkPath -Target $targetAbs | Out-Null
      $created++
    }
  }
}

Write-Host ("Summary => created={0} updated={1} removed={2} skipped={3} duplicates_seen={4} out_dir={5}" -f $created,$updated,$removed,$skipped,$dups,$destAbs)

# 生成链接名 -> 源文件绝对路径的映射 JSON
try {
  $exportAbs = Resolve-RepoPath $ExportMapPath
  $linkMap = Build-LinkTargetMap -destAbs $destAbs
  Save-LinkTargetMap -map $linkMap -path $exportAbs
  Write-Host ("Wrote link target map: {0} (count={1})" -f $exportAbs, ($linkMap.Keys.Count)) -ForegroundColor Green
} catch {
  Write-Warning ("导出链接映射失败：{0}" -f $_.Exception.Message)
}

# 用法：
# 干跑预览（不写入）：
#   pwsh -NoLogo -File script/full_reference_symlink_sync_and_json_build.ps1 -WhatIf
# 实际执行（需要 Windows 开发者模式或管理员权限以允许创建符号链接）：
#   pwsh -NoLogo -File script/full_reference_symlink_sync_and_json_build.ps1
# 指定配置/输出目录：
#   pwsh -NoLogo -File script/full_reference_symlink_sync_and_json_build.ps1 -Config 'src/full_reference/Link.json' -DestRoot 'src/full_reference'
# 导出链接映射（JSON 路径可改）：
#   pwsh -NoLogo -File script/full_reference_symlink_sync_and_json_build.ps1 -ExportMapPath 'src/full_reference/symlink_target_map.json'
# 重复文件策略（选最新修改时间）：
#   pwsh -NoLogo -File script/full_reference_symlink_sync_and_json_build.ps1 -DuplicatePolicy latest
