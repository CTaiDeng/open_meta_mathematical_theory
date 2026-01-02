# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2025 GaoZheng
# 用法：.\git_update.ps1 [-Message update] [-TrackedOnly] [-NoPush] [-Remote origin] [-Branch master]
param(
    [string]$Message = "update",
    [string]$Remote = "",
    [string]$Branch = "",
    [switch]$TrackedOnly,
    [switch]$NoPush
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Redact-UrlCredentials {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }

    # Redact credentials embedded in URLs (e.g. https://token@github.com/...).
    return ([regex]::Replace($Text, "(?i)(https?://)([^/\\s@]+)@", '${1}***@'))
}

function Write-Step {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    Write-Host ("[{0}] {1}" -f $ts, $Message)
}

function Quote-Win32Arg {
    param([string]$Arg)
    if ($null -eq $Arg) { return '""' }

    $a = [string]$Arg
    if ($a.Length -eq 0) { return '""' }
    if ($a -notmatch '[\s"]') { return $a }

    $result = '"'
    $backslashes = 0

    foreach ($ch in $a.ToCharArray()) {
        if ($ch -eq '\') {
            $backslashes++
            continue
        }

        if ($ch -eq '"') {
            $result += ('\' * ($backslashes * 2 + 1)) + '"'
            $backslashes = 0
            continue
        }

        if ($backslashes -gt 0) {
            $result += ('\' * $backslashes)
            $backslashes = 0
        }

        $result += $ch
    }

    if ($backslashes -gt 0) {
        $result += ('\' * ($backslashes * 2))
    }

    $result += '"'
    return $result
}

function Join-Win32Args {
    param([string[]]$ArgList)
    $parts = @()
    foreach ($a in @($ArgList)) {
        $parts += (Quote-Win32Arg -Arg $a)
    }
    return ($parts -join " ")
}

function Read-TextLinesAuto {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return @() }
    if (-not (Test-Path -LiteralPath $Path)) { return @() }

    $bytes = $null
    try { $bytes = [System.IO.File]::ReadAllBytes($Path) } catch { return @() }
    if ($null -eq $bytes -or $bytes.Length -eq 0) { return @() }

    $encoding = $null
    $offset = 0

    # BOM detection
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = [System.Text.Encoding]::UTF8
        $offset = 3
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = [System.Text.Encoding]::Unicode
        $offset = 2
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = [System.Text.Encoding]::BigEndianUnicode
        $offset = 2
    } else {
        # Prefer strict UTF-8; fallback to system ANSI codepage if bytes are not valid UTF-8.
        try {
            $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
            [void]$utf8Strict.GetString($bytes)
            $encoding = [System.Text.Encoding]::UTF8
            $offset = 0
        } catch {
            $encoding = [System.Text.Encoding]::Default
            $offset = 0
        }
    }

    $text = ""
    try { $text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset) } catch { return @() }
    if ([string]::IsNullOrEmpty($text)) { return @() }

    $text = $text -replace "`r`n", "`n"
    $text = $text -replace "`r", "`n"
    return ($text -split "`n", 0, "SimpleMatch")
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [Alias("Args")]
        [string[]]$GitArgs,
        [switch]$AllowFailure
    )

    $code = $null
    $out = @()

    # git writes progress output (e.g. "To https://...") to stderr even on success.
    # With $ErrorActionPreference="Stop", PowerShell treats native stderr as errors and will terminate.
    # Temporarily relax it and rely on exit codes instead.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        Write-Step ("git " + ($GitArgs -join " "))
        $gitExe = $null
        try { $gitExe = (Get-Command git -ErrorAction SilentlyContinue).Source } catch { $gitExe = $null }
        if ([string]::IsNullOrWhiteSpace($gitExe)) { $gitExe = "git" }

        $stdoutPath = $null
        $stderrPath = $null
        try {
            $stdoutPath = [System.IO.Path]::GetTempFileName()
            $stderrPath = [System.IO.Path]::GetTempFileName()
            $argLine = Join-Win32Args -ArgList $GitArgs
            $proc = Start-Process -FilePath $gitExe -ArgumentList $argLine -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
            $code = $proc.ExitCode

            if (Test-Path -LiteralPath $stdoutPath) {
                $out += Read-TextLinesAuto -Path $stdoutPath
            }
            if (Test-Path -LiteralPath $stderrPath) {
                $out += Read-TextLinesAuto -Path $stderrPath
            }
        }
        finally {
            if (-not [string]::IsNullOrWhiteSpace($stdoutPath)) {
                Remove-Item -LiteralPath $stdoutPath -ErrorAction SilentlyContinue
            }
            if (-not [string]::IsNullOrWhiteSpace($stderrPath)) {
                Remove-Item -LiteralPath $stderrPath -ErrorAction SilentlyContinue
            }
        }
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
    if ($null -eq $code) { $code = $LASTEXITCODE }

    $lines = @()
    foreach ($o in @($out)) {
        if ($null -eq $o) { continue }

        # Avoid PowerShell's ErrorRecord formatting (which prints "At ...", CategoryInfo, etc).
        $line = ""
        if ($o -is [System.Management.Automation.ErrorRecord]) {
            try { $line = $o.ToString() } catch { $line = "" }
        } else {
            try { $line = [string]$o } catch { $line = "" }
        }

        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $line = Redact-UrlCredentials -Text $line.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $lines += $line
    }

    foreach ($line in $lines) {
        Write-Host $line
    }

    if (-not $AllowFailure -and $code -ne 0) {
        if ($lines.Count -gt 0) {
            throw ("git {0} failed with exit code {1}`n{2}" -f ($GitArgs -join " "), $code, ($lines -join "`n"))
        }

        throw ("git {0} failed with exit code {1}" -f ($GitArgs -join " "), $code)
    }

    return $code
}

function Resolve-RepoRoot {
    $root = $null
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $root = $PSScriptRoot
    } else {
        $root = (Get-Location).Path
    }

    # Best-effort: prefer git's view of the repository root.
    try {
        $gitRoot = (& git -C $root rev-parse --show-toplevel 2>&1)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($gitRoot)) {
            $root = ([string]$gitRoot).Trim()
        }
    } catch {
    }

    try { $root = (Resolve-Path -LiteralPath $root).Path } catch { }
    return ([string]$root).Trim()
}

function To-GitPath {
    param([string]$Path)
    $p = $Path
    try { $p = (Resolve-Path -LiteralPath $p).Path } catch { }
    return ([string]$p).Replace("\\", "/")
}

$repoRoot = Resolve-RepoRoot
Push-Location $repoRoot
try {
    Write-Step ("repoRoot={0}" -f $repoRoot)
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "git not found in PATH."
    }

    $dotGit = Join-Path $repoRoot ".git"
    if (-not (Test-Path -LiteralPath $dotGit)) {
        throw ("Not inside a git repository: '{0}' has no .git metadata." -f $repoRoot)
    }

    Write-Step "checking git repository..."
    $insideOut = & git -C $repoRoot rev-parse --is-inside-work-tree 2>&1
    $insideCode = $LASTEXITCODE
    $insideText = ""
    try { $insideText = ($insideOut | Out-String).Trim() } catch { $insideText = "" }
    $insideText = Redact-UrlCredentials -Text $insideText

    if ($insideCode -ne 0) {
        # Auto-fix Git's "dubious ownership" safe.directory guard when applicable.
        if ($insideText -match "(?i)dubious ownership|safe\\.directory") {
            $safePath = To-GitPath -Path $repoRoot
            Write-Step ("applying git safe.directory: {0}" -f $safePath)
            Invoke-Git -Args @("config", "--global", "--add", "safe.directory", $safePath) | Out-Null

            $insideOut = & git -C $repoRoot rev-parse --is-inside-work-tree 2>&1
            $insideCode = $LASTEXITCODE
            try { $insideText = ($insideOut | Out-String).Trim() } catch { $insideText = "" }
            $insideText = Redact-UrlCredentials -Text $insideText
        }
    }

    if ($insideCode -ne 0) {
        if ([string]::IsNullOrWhiteSpace($insideText)) {
            throw "Not inside a git repository."
        }

        throw ("Not inside a git repository.`n{0}" -f $insideText)
    }

    $branchNow = ""
    try { $branchNow = (& git -C $repoRoot rev-parse --abbrev-ref HEAD).Trim() } catch { $branchNow = "" }
    if (-not [string]::IsNullOrWhiteSpace($branchNow)) {
        Write-Step ("current branch: {0}" -f $branchNow)
    }

    if ($TrackedOnly) {
        Write-Step "staging: tracked-only (git add -u)"
        Invoke-Git -Args @("-C", $repoRoot, "add", "-u") | Out-Null
    } else {
        Write-Step "staging: all (git add -A)"
        Invoke-Git -Args @("-C", $repoRoot, "add", "-A") | Out-Null
    }

    $hasStaged = $false
    Write-Step "checking staged changes..."
    $diffCode = Invoke-Git -Args @("-C", $repoRoot, "diff", "--cached", "--quiet") -AllowFailure
    if ($diffCode -eq 1) {
        $hasStaged = $true
    } elseif ($diffCode -eq 0) {
        $hasStaged = $false
    } else {
        throw ("git diff --cached --quiet failed with exit code {0}" -f $diffCode)
    }

    if ($hasStaged) {
        Write-Step ("committing: message='{0}'" -f $Message)
        Invoke-Git -Args @("-C", $repoRoot, "commit", "-m", $Message) | Out-Null
    } else {
        Write-Step "no staged changes; skip commit"
    }

    if ($NoPush) {
        Write-Step "NoPush set; done"
        return
    }

    Write-Step "detecting upstream..."
    $upstream = $null
    try {
        $upstream = (& git -C $repoRoot rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>$null)
        if ($LASTEXITCODE -ne 0) { $upstream = $null }
    } catch {
        $upstream = $null
    }

    $remoteToUse = $Remote
    if ([string]::IsNullOrWhiteSpace($remoteToUse)) { $remoteToUse = "origin" }

    $branchToUse = $Branch
    if ([string]::IsNullOrWhiteSpace($branchToUse)) {
        $branchToUse = (& git -C $repoRoot rev-parse --abbrev-ref HEAD).Trim()
    }

    if ([string]::IsNullOrWhiteSpace($branchToUse) -or $branchToUse -eq "HEAD") {
        throw "Detached HEAD; cannot auto-push."
    }

    if ([string]::IsNullOrWhiteSpace($upstream)) {
        Write-Step ("pushing: set upstream {0} {1}" -f $remoteToUse, $branchToUse)
        Invoke-Git -Args @("-C", $repoRoot, "push", "--set-upstream", $remoteToUse, $branchToUse) | Out-Null
    } else {
        Write-Step ("pushing: upstream={0}" -f $upstream.Trim())
        Invoke-Git -Args @("-C", $repoRoot, "push") | Out-Null
    }

    Write-Step "done"
}
finally {
    Pop-Location
}
