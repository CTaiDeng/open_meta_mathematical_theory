#!/usr/bin/env pwsh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2025 GaoZheng

[CmdletBinding()]
param(
  [string[]]$Repos,
  [switch]$StopOnError,
  [int]$DelaySecondsBetween = 0,
  [int]$SpinnerIntervalMs = 120,
  [int]$TailLines = 0
)

function Fail($msg) { Write-Error $msg; exit 1 }

$repoRoot = try { (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..' '..')).Path } catch { (Get-Location).Path }
$partialCloneCmd = Join-Path -Path $repoRoot -ChildPath 'partial_clone.cmd'
if (-not (Test-Path -LiteralPath $partialCloneCmd)) {
  Fail ("partial_clone.cmd not found at repo root: " + $partialCloneCmd)
}

if (-not $Repos -or $Repos.Count -eq 0) {
  $Repos = @(
    'https://github.com/CTaiDeng/open_meta_mathematical_theory.git',
    'https://github.com/CTaiDeng/gromacs-2024.1_developer.git',
    'https://github.com/CTaiDeng/character_rl_sac_pacer_haca_v1.git',
    'https://github.com/CTaiDeng/character_rl_sac_pacer_haca_v2.git',
    'https://github.com/CTaiDeng/financial_quant_lab_v1',
    'https://github.com/CTaiDeng/erp_base_on_blockchain_v1',
    'https://github.com/CTaiDeng/open_ra_rl_developer.git'
  )
}

Write-Host "[batch-partial-clone] will process " -NoNewline
Write-Host $Repos.Count -ForegroundColor Cyan -NoNewline
Write-Host " repos"

$logDir = Join-Path -Path $PSScriptRoot -ChildPath 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

function Invoke-PartialCloneSilently([string]$repoUrl, [string]$logPath) {
  if (Test-Path -LiteralPath $logPath) { Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue }
  $args = @('/c', '"' + $partialCloneCmd + '"', $repoUrl)
  $p = Start-Process -FilePath 'cmd.exe' -ArgumentList $args -NoNewWindow -RedirectStandardOutput $logPath -RedirectStandardError $logPath -PassThru
  return $p
}

$ok = 0; $fail = 0
$total = $Repos.Count
$startTime = Get-Date

for ($i = 0; $i -lt $total; $i++) {
  $repo = $Repos[$i]
  $pct = [int](($i) * 100 / [math]::Max(1,$total))

  # prepare log path
  $slug = ($repo -replace '\\.git$','').Split('/')[-1]
  $logPath = Join-Path -Path $logDir -ChildPath ("{0:00}_{1}.log" -f ($i+1), $slug)

  # start process (output redirected to log)
  $proc = Invoke-PartialCloneSilently -repoUrl $repo -logPath $logPath

  $spin = @('|','/','-','\\')
  $si = 0
  while (-not $proc.HasExited) {
    $ch = $spin[$si % $spin.Count]; $si++
    Write-Progress -Id 1 -Activity 'Batch partial clone' -Status ("{0}/{1} {2}  [{3}]" -f ($i+1), $total, $repo, $ch) -PercentComplete $pct
    Start-Sleep -Milliseconds $SpinnerIntervalMs
  }

  # finalize percent for this item
  $pct = [int](($i+1) * 100 / [math]::Max(1,$total))
  Write-Progress -Id 1 -Activity 'Batch partial clone' -Status ("{0}/{1} {2}  [done]" -f ($i+1), $total, $repo) -PercentComplete $pct

  $rc = $proc.ExitCode

  if ($rc -eq 0) {
    $ok++
    Write-Host "[OK] " -NoNewline -ForegroundColor Green; Write-Host $repo
  } else {
    $fail++
    Write-Host "[FAIL] " -NoNewline -ForegroundColor Red; Write-Host ("code=" + $rc + " repo=" + $repo)
    if ($StopOnError) { break }
  }

  Write-Host ("  log: " + $logPath) -ForegroundColor DarkGray
  if ($TailLines -gt 0 -and (Test-Path -LiteralPath $logPath)) {
    Write-Host ("  last " + $TailLines + " lines:") -ForegroundColor DarkGray
    Get-Content -LiteralPath $logPath -Tail $TailLines | ForEach-Object { Write-Host ('    ' + $_) }
  }

  if ($DelaySecondsBetween -gt 0 -and $i -lt ($total-1)) { Start-Sleep -Seconds $DelaySecondsBetween }
}

Write-Progress -Id 1 -Activity 'Batch partial clone' -Completed

$elapsed = (Get-Date) - $startTime
Write-Host "`n[SUMMARY] total=" -NoNewline; Write-Host $total -NoNewline -ForegroundColor Cyan
Write-Host ", ok=" -NoNewline; Write-Host $ok -NoNewline -ForegroundColor Green
Write-Host ", fail=" -NoNewline; Write-Host $fail -ForegroundColor Red
Write-Host ("elapsed: {0:g}" -f $elapsed)

exit ([int]($fail -gt 0))
