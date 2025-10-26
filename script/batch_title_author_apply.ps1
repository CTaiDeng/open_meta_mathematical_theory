<#

# Copyright (C) 2025 GaoZheng
# SPDX-License-Identifier: GPL-3.0-only
# This file is part of this project.
# Licensed under the GNU General Public License version 3.
# See https://www.gnu.org/licenses/gpl-3.0.html for details.
<#
批量规范 Markdown（仅首标题与作者行），纯 PowerShell 实现。

规则：
- 仅处理文件名匹配 ^\d{10,}_.*\.md 的 Markdown（例如：1734546039_标题.md）。
- 只规范“首个标题”为 H1："# <标题文本>"；正文子标题不改。
- 在首标题下方插入：空行、"- 作者：GaoZheng"、空行（幂等，不会重复）。
- 保留 YAML front matter 与原始换行风格（CRLF/LF）；仅内容变更时写回。

用法：
  pwsh -NoLogo -File script/batch_title_author_apply.ps1 [-Root src] [-SkipCheck]
#>
[CmdletBinding()]
param(
  [string]$Root = 'src',
  [switch]$SkipCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-MdTargets {
  param([string]$Base)
  if (-not (Test-Path -LiteralPath $Base)) { return @() }
  $item = Get-Item -LiteralPath $Base -ErrorAction SilentlyContinue
  if (-not $item) { return @() }
  if ($item.PSIsContainer) {
    return Get-ChildItem -LiteralPath $Base -Recurse -File -Filter *.md |
      Where-Object { $_.Name -ne 'INDEX.md' -and ($_.Name -match '^(\d{10,}_.*)\.md$') }
  }
  else {
    if ($item.Extension -ieq '.md' -and $item.Name -ne 'INDEX.md' -and ($item.Name -match '^(\d{10,}_.*)\.md$')) {
      return ,$item
    }
    return @()
  }
}

function Read-Utf8Preserve {
  param([string]$Path)
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  $withBOM = $false
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    $withBOM = $true
    $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
  } else {
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
  }
  return [pscustomobject]@{ Text = $text; WithBOM = $withBOM }
}

function Write-Utf8Preserve {
  param([string]$Path, [string]$Text, [bool]$WithBOM)
  $enc = New-Object System.Text.UTF8Encoding($false)
  $bytes = $enc.GetBytes($Text)
  [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function Get-EOL {
  param([string]$Text)
  return "`n"
}

function Is-MeaningfulHeadingText {
  param([string]$Text)
  # 至少包含一个“字母或数字”或下划线（Unicode 友好）
  return [bool]([System.Text.RegularExpressions.Regex]::IsMatch($Text, "[\p{L}\p{N}_]"))
}

function Find-YamlFrontEnd {
  param([string[]]$Lines)
  $i = 0
  while ($i -lt $Lines.Count -and $Lines[$i].Trim() -eq '') { $i++ }
  if ($i -lt $Lines.Count -and $Lines[$i].Trim() -eq '---') {
    $i++
    while ($i -lt $Lines.Count -and $Lines[$i].Trim() -ne '---') { $i++ }
    if ($i -lt $Lines.Count -and $Lines[$i].Trim() -eq '---') { return ($i + 1) }
  }
  return 0
}

function Match-AtxHeading {
  param([string]$Line)
  $m = [System.Text.RegularExpressions.Regex]::Match($Line, '^(\s{0,3})(#{1,6})\s+(.*?)\s*(#+\s*)?$')
  if ($m.Success) { return ,@($true, $m.Groups[3].Value) } else { return ,@($false, '') }
}

function Is-SetextUnderline {
  param([string]$Line)
  return [bool]([System.Text.RegularExpressions.Regex]::IsMatch($Line, '^\s*(=+|-+)\s*$'))
}

function Normalize-FirstHeadingAndAuthor {
  param([string]$Content)

  $eol = Get-EOL -Text $Content
  $endsWith = $Content.EndsWith($eol)
  $lines = [System.Text.RegularExpressions.Regex]::Split($Content, "\r?\n")

  $fmEnd = Find-YamlFrontEnd -Lines $lines
  $n = $lines.Count

  # 查找首个标题（ATX 优先，其次 Setext），跳过空标题
  $hStart = -1; $hEnd = -1; $hText = ''
  $i = $fmEnd
  while ($i -lt $n -and $lines[$i].Trim() -eq '') { $i++ }
  if ($i -lt $n) {
    $atx = Match-AtxHeading -Line $lines[$i]
    if ($atx[0] -and (Is-MeaningfulHeadingText $atx[1])) { $hStart = $i; $hEnd = $i; $hText = $atx[1] }
    elseif (($i + 1) -lt $n -and $lines[$i].Trim() -ne '' -and (Is-SetextUnderline $lines[$i+1])) {
      if (Is-MeaningfulHeadingText $lines[$i].Trim()) { $hStart = $i; $hEnd = $i + 1; $hText = $lines[$i].Trim() }
    }
    if ($hStart -lt 0) {
      for ($j = $i + 1; $j -lt $n; $j++) {
        $atx2 = Match-AtxHeading -Line $lines[$j]
        if ($atx2[0] -and (Is-MeaningfulHeadingText $atx2[1])) { $hStart = $j; $hEnd = $j; $hText = $atx2[1]; break }
        if (($j + 1) -lt $n -and $lines[$j].Trim() -ne '' -and (Is-SetextUnderline $lines[$j+1])) {
          if (Is-MeaningfulHeadingText $lines[$j].Trim()) { $hStart = $j; $hEnd = $j + 1; $hText = $lines[$j].Trim(); break }
        }
      }
    }
  }
  if ($hStart -lt 0) { return $Content } # 无标题，不改

  # 1) 规范首标题为 H1
  $newHead = ('# ' + $hText).TrimEnd()
  $newLines = New-Object System.Collections.Generic.List[string]
  if ($hStart -gt 0) { $seg = @($lines[0..($hStart-1)]); $newLines.AddRange([string[]]$seg) }
  $newLines.Add($newHead)
  if ($hEnd + 1 -le $n - 1) { $seg2 = @($lines[($hEnd+1)..($n-1)]); $newLines.AddRange([string[]]$seg2) }

  # 1.1) 清理文首可能存在的“空标题”（仅有 #/## 且无文字）
  while ($newLines.Count -gt 0) {
    $atx0 = Match-AtxHeading -Line $newLines[0]
    if ($atx0[0] -and -not (Is-MeaningfulHeadingText $atx0[1])) { $null = $newLines.RemoveAt(0); continue }
    break
  }

  # 2) 确保标题下方为：空行、作者行、空行（幂等）
  $insertAt = $hStart + 1
  if ($insertAt -gt $newLines.Count) { $insertAt = $newLines.Count }
  $j = $insertAt
  while ($j -lt $newLines.Count) {
    $s = $newLines[$j].Trim()
    if ($s -eq '' -or [System.Text.RegularExpressions.Regex]::IsMatch($newLines[$j], '^\s*[-*]\s*作者\s*[:：]\s*GaoZheng\s*$')) {
      $null = $newLines.RemoveAt($j)
      continue
    }
    break
  }
  $finalLines = New-Object System.Collections.Generic.List[string]
  if ($insertAt -gt 0) { $seg3 = @($newLines[0..($insertAt-1)]); $finalLines.AddRange([string[]]$seg3) }
  $finalLines.Add('')
  $finalLines.Add('- 作者：GaoZheng')
  $finalLines.Add('')
  if ($insertAt -le $newLines.Count - 1) { $seg4 = @($newLines[$insertAt..($newLines.Count-1)]); $finalLines.AddRange([string[]]$seg4) }

  $result = [string]::Join($eol, $finalLines.ToArray())
  if ($endsWith -and -not $result.EndsWith($eol)) { $result += $eol }
  return $result
}

try {
  $targets = @(Get-MdTargets -Base $Root)
  if (-not $targets) {
    Write-Host "[info] 无匹配文件：$Root" -ForegroundColor Yellow
    exit 0
  }

  $changed = 0
  if (-not $SkipCheck) {
    foreach ($f in $targets) {
      $read = Read-Utf8Preserve -Path $f.FullName
      $updated = Normalize-FirstHeadingAndAuthor -Content $read.Text
      if ($updated -ne $read.Text) { $changed++ }
    }
    if ($changed -eq 0) {
      Write-Host '所有目标文件均已符合规范；不进行写回。' -ForegroundColor Yellow
      exit 0
    }
    Write-Host ("[apply] 即将更新 {0} 个文件" -f $changed) -ForegroundColor Green
  }

  $changed = 0
  foreach ($f in $targets) {
    $read = Read-Utf8Preserve -Path $f.FullName
    $updated = Normalize-FirstHeadingAndAuthor -Content $read.Text
    if ($updated -ne $read.Text) {
      Write-Host "[update] $($f.FullName)"
      Write-Utf8Preserve -Path $f.FullName -Text $updated -WithBOM $read.WithBOM
      $changed++
    }
  }
  Write-Host ("Done. Changed {0} of {1} files." -f $changed, $targets.Count)
  exit 0
}
catch {
  Write-Error $_
  exit 1
}

