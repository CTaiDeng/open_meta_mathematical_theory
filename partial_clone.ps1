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

if (Test-Path -LiteralPath $Dest -PathType Container) {
  if ((Get-ChildItem -LiteralPath $Dest -Force | Measure-Object).Count -gt 0) {
    Fail ("target directory exists and not empty: " + $Dest)
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

# clone (partial, no-checkout)
$cloneArgs = @("clone", "--filter=blob:none", "--depth=1", "--no-checkout")
if ($targetBranch -and $targetBranch.Trim() -ne "") { $cloneArgs += @("--branch", $targetBranch) }
$cloneArgs += @($RepoUrl, $Dest)

& git @cloneArgs
if ($LASTEXITCODE -ne 0) { Fail "git clone failed. check repo/network/permissions." }

Push-Location $Dest

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
  Write-Host "[partial-clone] no whitelist found. default exclude .git only."
}

$exclude = $exclude | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -ne "" } | Select-Object -Unique
if ($exclude -notcontains ".git") { $exclude += ".git" }

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

# remove .git to leave a clean tree
try {
  $gitDir = Join-Path -Path (Get-Location) -ChildPath ".git"
  if (Test-Path -LiteralPath $gitDir -PathType Container) {
    Remove-Item -LiteralPath $gitDir -Recurse -Force -ErrorAction Stop
    Write-Host "[partial-clone] removed .git directory"
  }
} catch {
  Write-Warning ("[partial-clone] failed to remove .git directory: " + $_.Exception.Message)
}

Pop-Location
exit 0

