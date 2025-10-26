# Copyright (C) 2025 GaoZheng
# SPDX-License-Identifier: GPL-3.0-only
# This file is part of this project.
# Licensed under the GNU General Public License version 3.
# See https://www.gnu.org/licenses/gpl-3.0.html for details.
Param(
    [string]$Root = 'res/kernel',
    [string]$Version = 'v1.0.0',
    [string]$IncludePattern = '^[0-9]{10}_.+\.md$',
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

function Get-EolStyle([string]$text){
    return "`n"
}

function Insert-VersionLine([string]$text, [string]$version){
    $eol = Get-EolStyle $text
    $lines = [regex]::Split($text, '\r\n|\n')

    $dateIdx = -1
    for($i=0; $i -lt $lines.Length; $i++){
        if($lines[$i] -match '^\-\s*日期：\d{4}-\d{2}-\d{2}\s*$'){
            $dateIdx = $i
            break
        }
    }
    if($dateIdx -lt 0){ return $null }

    $insertLine = "- 版本：$version"

    if($lines.Length -eq 0){ return $text }

    $newLines = @()
    if($dateIdx -ge 0){ $newLines += $lines[0..$dateIdx] }
    $newLines += $insertLine
    if(($dateIdx + 1) -lt $lines.Length){
        $newLines += $lines[($dateIdx+1)..($lines.Length-1)]
    }

    return [string]::Join($eol, $newLines)
}

function Should-ProcessFile([string]$text){
    if(-not ($text -match '(?m)^\-\s*作者：GaoZheng\s*$')){ return $false }
    if($text -match '(?m)^\-\s*版本：'){ return $false }
    if(-not ($text -match '(?m)^\-\s*日期：\d{4}-\d{2}-\d{2}\s*$')){ return $false }
    return $true
}

$files = Get-ChildItem -Path $Root -Recurse -File -Include *.md |
    Where-Object { $_.Name -match $IncludePattern }

$updated = 0
$skipped = 0
$total   = $files.Count

foreach($f in $files){
    $text = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8

    if(-not (Should-ProcessFile $text)){
        $skipped++
        continue
    }

    $newText = Insert-VersionLine -text $text -version $Version
    if($null -eq $newText){
        $skipped++
        continue
    }

    if(-not $WhatIf){
        # UTF-8 (no BOM) write, preserve original EOLs by writing $newText verbatim
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($f.FullName, $newText, $utf8NoBom)
    }
    Write-Output ("Updated: {0}" -f $f.FullName)
    $updated++
}

Write-Output ("Summary => Updated: {0}; Skipped: {1}; Total: {2}" -f $updated, $skipped, $total)

# Usage examples:
# pwsh -NoLogo -File script/add_version_to_kernel_md.ps1 -Root 'res/kernel' -Version 'v1.0.0' -WhatIf
# pwsh -NoLogo -File script/add_version_to_kernel_md.ps1 -Root 'res/kernel' -Version 'v1.0.0'
