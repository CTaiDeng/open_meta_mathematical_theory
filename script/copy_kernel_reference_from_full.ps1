# 直接执行（便于复制粘贴）
# pwsh -NoLogo -File script/copy_kernel_reference_from_full.ps1

param(
  [string]$FullDir = "src\full_reference",
  [string]$MarkerDir = "res\kernel",
  [string]$DestDir = "src\kernel_reference",
  [switch]$Exact,       # 启用后按完整文件名（含扩展名）匹配
  [switch]$Overwrite    # 已存在时允许覆盖
)

$ErrorActionPreference = "Stop"

if (!(Test-Path -LiteralPath $FullDir -PathType Container)) {
  throw "目录不存在：$FullDir"
}
if (!(Test-Path -LiteralPath $MarkerDir -PathType Container)) {
  throw "目录不存在：$MarkerDir"
}

$fullFull = (Resolve-Path -LiteralPath $FullDir).Path
$markerFull = (Resolve-Path -LiteralPath $MarkerDir).Path
$destFull = (Resolve-Path -LiteralPath $DestDir -ErrorAction SilentlyContinue)?.Path
if (-not $destFull) { $destFull = (Resolve-Path -LiteralPath (Split-Path -Parent $DestDir) -ErrorAction SilentlyContinue)?.Path; $destFull = Join-Path ($destFull ? $destFull : (Get-Location).Path) (Split-Path -Leaf $DestDir) }

# 受保护与默认排除（避免自动化改动授权/索引文件）
$protected = @("INDEX.md", "LICENSE.md")

# 根据匹配策略生成“键”
$GetKey = if ($Exact) {
  { param($f) $f.Name }
} else {
  { param($f) [System.IO.Path]::GetFileNameWithoutExtension($f.Name) }
}

# 生成 Marker（res\kernel）中的文件名集合（忽略大小写）
$markerFiles = Get-ChildItem -Path $markerFull -File -Recurse
$markerKeySet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($f in $markerFiles) {
  $key = & $GetKey $f
  if ($null -ne $key -and $key -ne "") { [void]$markerKeySet.Add($key) }
}

# 收集 src\full_reference 中的候选 .md 文件
$srcFiles = Get-ChildItem -Path $fullFull -File -Recurse -Filter *.md

$tasks = @()
$skippedExisting = @()
foreach ($sf in $srcFiles) {
  if ($protected -contains $sf.Name) { continue }
  $key = & $GetKey $sf
  if (-not $markerKeySet.Contains($key)) { continue }
  $destPath = Join-Path $DestDir $sf.Name
  $exists = Test-Path -LiteralPath $destPath -PathType Leaf
  if ($exists -and -not $Overwrite) {
    $skippedExisting += $destPath
    continue
  }
  $tasks += [pscustomobject]@{
    Source      = $sf.FullName
    Destination = (Resolve-Path -LiteralPath (Split-Path -Parent $destPath) -ErrorAction SilentlyContinue)?.Path ? (Join-Path ((Resolve-Path -LiteralPath (Split-Path -Parent $destPath) -ErrorAction SilentlyContinue).Path) (Split-Path -Leaf $destPath)) : $destPath
    Overwrite   = $exists
  }
}

if ($tasks.Count -eq 0) {
  if ($skippedExisting.Count -gt 0) {
    Write-Host "没有需要复制的文件（存在同名且未指定 -Overwrite，跳过 $($skippedExisting.Count) 个）。" -ForegroundColor Yellow
  } else {
    Write-Host "没有需要复制的文件。" -ForegroundColor Yellow
  }
  if ($skippedExisting.Count -gt 0) {
    Write-Host "已存在且被跳过："
    $skippedExisting | ForEach-Object { Write-Host $_ }
  }
  exit 0
}

Write-Host "将复制以下文件（共 $($tasks.Count) 个）：" -ForegroundColor Yellow
foreach ($t in $tasks) {
  $tag = if ($t.Overwrite) { "[覆盖]" } else { "[新建]" }
  Write-Host "$tag $($t.Source) -> $($t.Destination)"
}

if (!(Test-Path -LiteralPath $DestDir -PathType Container)) {
  [void](New-Item -ItemType Directory -Path $DestDir)
}
$copied = 0
$overwritten = 0
foreach ($t in $tasks) {
  if ($t.Overwrite) { $overwritten++ }
  Copy-Item -LiteralPath $t.Source -Destination $t.Destination -Force
  $copied++
}
Write-Host "已复制 $copied 个文件（覆盖 $overwritten 个）。" -ForegroundColor Green
if ($skippedExisting.Count -gt 0 -and -not $Overwrite) {
  Write-Host "另有 $($skippedExisting.Count) 个因已存在而被跳过（使用 -Overwrite 可覆盖）。"
}
