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
  $np = ($np -replace '^/+', '')
  $np = ($np -replace '/+$', '')
  return $np
}

function Get-DefaultBranch([string]$remoteUrl) {
  try {
    $out = git ls-remote --symref $remoteUrl HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $out) {
      foreach ($line in $out) {
        if ($line -match '^ref:\s+refs/heads/([^\s]+)\s+HEAD$') { return $Matches[1] }
      }
    }
  } catch { }
  return 'main'
}

function Parse-GitHubRepo([string]$remoteUrl) {
  $u = $remoteUrl.Trim().TrimEnd('/')
  if ($u -match '^[^@]+@([^:]+):([^/]+)/([^/]+?)(?:\.git)?$') {
    return [ordered]@{ host=$Matches[1]; owner=$Matches[2]; repo=$Matches[3] }
  }
  if ($u -match '^https?://([^/]+)/([^/]+)/([^/]+?)(?:\.git)?$') {
    return [ordered]@{ host=$Matches[1]; owner=$Matches[2]; repo=$Matches[3] }
  }
  return $null
}

function Try-Download-Remote-Whitelist([string]$remoteUrl, [string]$defaultBranch) {
  $parsed = Parse-GitHubRepo $remoteUrl
  if ($null -eq $parsed) { return $null }
  $ghHost = $parsed.host.ToLower()
  if ($ghHost -ne 'github.com' -and $ghHost -ne 'www.github.com') { return $null }
  $owner = $parsed.owner
  $repo  = $parsed.repo
  $branch = if ([string]::IsNullOrWhiteSpace($defaultBranch)) { 'main' } else { $defaultBranch }
  $raw = "https://raw.githubusercontent.com/$owner/$repo/$branch/partial_clone_exclude_whitelist.json"
  try {
    $tmp = New-TemporaryFile
    $resp = Invoke-WebRequest -Uri $raw -UseBasicParsing -Headers @{ 'User-Agent'='partial_clone.ps1' } -TimeoutSec 20 -ErrorAction Stop
    if ($resp -and $resp.Content) {
      [System.IO.File]::WriteAllText($tmp.FullName, $resp.Content, [System.Text.Encoding]::UTF8)
      return $tmp.FullName
    }
  } catch { }
  return $null
}

function New-TempDirectory {
  $base = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "partial_clone_" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $base -Force | Out-Null
  return $base
}

function Get-RelNormalized([string]$root, [string]$fullPath) {
  try {
    $rel = [System.IO.Path]::GetRelativePath($root, $fullPath)
  } catch {
    $rootFull = [System.IO.Path]::GetFullPath($root)
    $fileFull = [System.IO.Path]::GetFullPath($fullPath)
    if ($fileFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
      $rel = $fileFull.Substring($rootFull.Length).TrimStart([char[]]"/\\")
    } else {
      $rel = $fileFull
    }
  }
  $rel = $rel.Replace('\\','/')
  $rel = ($rel -replace '^/+', '')
  return $rel
}

function New-ExcludeChecker([string[]]$excludeList) {
  $normalized = @()
  foreach ($e in $excludeList) {
    $n = Normalize-RepoPath $e
    if (-not [string]::IsNullOrWhiteSpace($n)) { $normalized += $n.ToLowerInvariant() }
  }
  return {
    param([string]$relPath)
    $r = (Normalize-RepoPath $relPath).ToLowerInvariant()
    foreach ($ex in $normalized) {
      if ($r -eq $ex) { return $true }
      if ($r.StartsWith($ex + '/')) { return $true }
    }
    return $false
  }.GetNewClosure()
}

function Sync-Directories([string]$src, [string]$dst, [ScriptBlock]$isExcluded) {
  $added = 0; $updated = 0; $removed = 0
  # index source files with hashes
  $srcIndex = @{}
  Get-ChildItem -LiteralPath $src -Recurse -File -Force | ForEach-Object {
    $rel = Get-RelNormalized -root $src -fullPath $_.FullName
    if (-not (& $isExcluded $rel)) {
      $h = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
      $srcIndex[$rel] = @{ Full = $_.FullName; Hash = $h }
    }
  }

  # build dest file set
  $dstIndex = @{}
  if (Test-Path -LiteralPath $dst) {
    Get-ChildItem -LiteralPath $dst -Recurse -File -Force | ForEach-Object {
      $rel = Get-RelNormalized -root $dst -fullPath $_.FullName
      if (-not (& $isExcluded $rel)) { $dstIndex[$rel] = $_.FullName }
    }
  } else {
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
  }

  # add or update
  foreach ($k in $srcIndex.Keys) {
    $srcMeta = $srcIndex[$k]
    $dstPath = Join-Path -Path $dst -ChildPath $k
    $dstDir  = Split-Path -Path $dstPath -Parent
    if (-not (Test-Path -LiteralPath $dstPath)) {
      if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
      Copy-Item -LiteralPath $srcMeta.Full -Destination $dstPath -Force
      $added++
    } else {
      $dstHash = (Get-FileHash -LiteralPath $dstPath -Algorithm SHA256).Hash
      if ($dstHash -ne $srcMeta.Hash) {
        Copy-Item -LiteralPath $srcMeta.Full -Destination $dstPath -Force
        $updated++
      }
    }
  }

  # remove extras
  foreach ($k in $dstIndex.Keys) {
    if (-not $srcIndex.ContainsKey($k)) {
      $p = Join-Path -Path $dst -ChildPath $k
      Remove-Item -LiteralPath $p -Force
      $removed++
    }
  }

  # try remove empty directories
  Get-ChildItem -LiteralPath $dst -Recurse -Directory -Force | Sort-Object FullName -Descending | ForEach-Object {
    try {
      $items = Get-ChildItem -LiteralPath $_.FullName -Force
      if ($items.Count -eq 0) { Remove-Item -LiteralPath $_.FullName -Force }
    } catch {}
  }

  return [PSCustomObject]@{ Added=$added; Updated=$updated; Removed=$removed }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Fail "git not found. Please install Git."
}

$startDir = Get-Location
$repoRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($repoRoot)) { $repoRoot = $startDir }

if ([string]::IsNullOrWhiteSpace($Dest)) {
  $lastSegment = ($RepoUrl -replace '\\','/' -split '/')[ -1 ]
  $repoName = ($lastSegment -replace '^.+:', '') -replace '\.git$',''
  if ([string]::IsNullOrWhiteSpace($repoName)) { Fail "cannot derive repo name from url; please specify -Dest" }
  $Dest = $repoName
}

# snapshot destination existence and key subdir state
$destExistsStart = Test-Path -LiteralPath $Dest -PathType Container
$hadGiteeStart = $false
if ($destExistsStart) {
  $giteePathStart = Join-Path -Path $Dest -ChildPath 'gitee'
  if (Test-Path -LiteralPath $giteePathStart -PathType Container) { $hadGiteeStart = $true }
}

${needSync} = $false
if (Test-Path -LiteralPath $Dest -PathType Container) {
  if ((Get-ChildItem -LiteralPath $Dest -Force | Measure-Object).Count -gt 0) {
    $needSync = $true
  }
}

Write-Host "[partial-clone] start: $RepoUrl -> $Dest"

# decide branch early for remote whitelist
$targetBranch = if ($Branch -and $Branch.Trim() -ne "") { $Branch } else { Get-DefaultBranch $RepoUrl }

# choose whitelist json: prefer remote; then user-specified; then script dir default
$excludeJsonPath = $null
$remoteJson = Try-Download-Remote-Whitelist -remoteUrl $RepoUrl -defaultBranch $targetBranch
if ($remoteJson) {
  Write-Host "[partial-clone] remote whitelist detected: $remoteJson"
  $excludeJsonPath = $remoteJson
} else {
  if ($PSBoundParameters.ContainsKey('ExcludeJson') -and -not [string]::IsNullOrWhiteSpace($ExcludeJson)) {
    if ([System.IO.Path]::IsPathRooted($ExcludeJson)) {
      $excludeJsonPath = $ExcludeJson
    } else {
      $excludeJsonPath = Join-Path -Path $repoRoot -ChildPath $ExcludeJson
    }
  } else {
    $candidate = Join-Path -Path $repoRoot -ChildPath 'partial_clone_exclude_whitelist.json'
    if (Test-Path -LiteralPath $candidate) { $excludeJsonPath = $candidate }
  }
}

# select working path (dest or temp)
$workPath = $Dest
$clonedIntoDest = $true
if ($needSync) {
  $workPath = New-TempDirectory
  $clonedIntoDest = $false
}

# clone (partial, no-checkout) into working path
$cloneArgs = @("clone", "--filter=blob:none", "--depth=1", "--no-checkout")
if ($targetBranch -and $targetBranch.Trim() -ne "") { $cloneArgs += @("--branch", $targetBranch) }
$cloneArgs += @($RepoUrl, $workPath)

& git @cloneArgs
if ($LASTEXITCODE -ne 0) { Fail "git clone failed. check repo/network/permissions." }

Push-Location $workPath

$exclude = @()
if ($excludeJsonPath -and (Test-Path -LiteralPath $excludeJsonPath)) {
  try {
    $jsonObj = Get-Content -LiteralPath $excludeJsonPath -Encoding utf8 -Raw | ConvertFrom-Json
    if ($null -ne $jsonObj.exclude) { $exclude += @($jsonObj.exclude) }
    if ($null -ne $jsonObj.exclude_files) { $exclude += @($jsonObj.exclude_files) }
    if ($null -ne $jsonObj.excludeFiles) { $exclude += @($jsonObj.excludeFiles) }
  } catch {
    Fail ("failed to parse whitelist: " + $excludeJsonPath)
  }
} else {
  Write-Host "[partial-clone] no whitelist found. enforcing required defaults."
}

# enforce required entries in whitelist
$required = @(
  ".git",
  "partial_clone.cmd",
  "partial_clone.ps1",
  "partial_clone_exclude_whitelist.json",
  "gitee"
)

# normalize and merge
$exclude = $exclude | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -ne "" }
$exclude = @($exclude + $required) | Select-Object -Unique

# enable sparse-checkout, write rules before checkout
& git config core.sparseCheckout true
& git sparse-checkout init --no-cone | Out-Null

$patterns = New-Object 'System.Collections.Generic.List[string]'
$patterns.Add("/*") | Out-Null
foreach ($item in $exclude) {
  if ($item -eq ".git") { continue }
  $safe = Normalize-RepoPath $item
  if ([string]::IsNullOrWhiteSpace($safe)) { continue }
  $patterns.Add("!/$safe")   | Out-Null
  $patterns.Add("!/$safe/*") | Out-Null
}

$scFile = Join-Path -Path ".git" -ChildPath "info/sparse-checkout"
$patterns | Set-Content -LiteralPath $scFile -Encoding utf8

# checkout target branch
$checkoutOk = $false
& git checkout -q -b $targetBranch --track ("origin/" + $targetBranch)
if ($LASTEXITCODE -eq 0) { $checkoutOk = $true }
if (-not $checkoutOk) {
  & git checkout -q ("origin/" + $targetBranch)
  if ($LASTEXITCODE -eq 0) { $checkoutOk = $true }
}
if (-not $checkoutOk) { Fail ("failed to checkout branch: " + $targetBranch) }

& git sparse-checkout reapply | Out-Null

Write-Host "[partial-clone] done. excluded paths:"
$excludedPrinted = $exclude | Where-Object { $_ -ne ".git" }
if ($excludedPrinted.Count -eq 0) {
  Write-Host "  (none, default exclude .git)"
} else {
  foreach ($i in $excludedPrinted) { Write-Host ("  - " + $i) }
}

# if working in temp, sync to dest
if (-not $clonedIntoDest) {
  Pop-Location
  $checker = New-ExcludeChecker -excludeList $exclude
  $result = Sync-Directories -src $workPath -dst $Dest -isExcluded $checker
  Write-Host ("[partial-clone] synced. added=" + $result.Added + ", updated=" + $result.Updated + ", removed=" + $result.Removed)
  # cleanup temp clone
  try { Remove-Item -LiteralPath $workPath -Recurse -Force } catch {}
} else {
  # remove .git to leave a clean tree
  try {
    $gitDir = Join-Path -Path (Join-Path $workPath ".git") -ChildPath ""
    if (Test-Path -LiteralPath $gitDir -PathType Container) {
      Remove-Item -LiteralPath $gitDir -Recurse -Force -ErrorAction Stop
      Write-Host "[partial-clone] removed .git directory"
    }
  } catch {
    Write-Warning ("[partial-clone] failed to remove .git directory: " + $_.Exception.Message)
  }
  Pop-Location
}

# ensure gitee directory policy
try {
  $giteeDirFinal = Join-Path -Path $Dest -ChildPath 'gitee'
  if (-not $destExistsStart) {
    if (-not (Test-Path -LiteralPath $giteeDirFinal -PathType Container)) {
      New-Item -ItemType Directory -Path $giteeDirFinal -Force | Out-Null
      Write-Host "[partial-clone] created gitee directory (new destination)"
    }
  } elseif ($hadGiteeStart) {
    if (-not (Test-Path -LiteralPath $giteeDirFinal -PathType Container)) {
      New-Item -ItemType Directory -Path $giteeDirFinal -Force | Out-Null
      Write-Host "[partial-clone] restored gitee directory"
    }
  }
} catch {
  Write-Warning ("[partial-clone] failed to ensure gitee directory: " + $_.Exception.Message)
}

exit 0
