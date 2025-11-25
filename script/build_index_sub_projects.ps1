# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2025 GaoZheng
param(
  [string]$ConfigPath = 'src/sub_projects_docs/sub_projects_clone_map.json',
  [int]$MaxChars = 500
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

function Normalize-Rel([string]$p){
  if([string]::IsNullOrWhiteSpace($p)){ return $p }
  return ($p -replace '/', '\').Trim()
}

function Read-CloneMap([string]$path){
  if(-not (Test-Path -LiteralPath $path -PathType Leaf)){
    throw "配置不存在：$path"
  }
  $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
  try{
    $cfg = $raw | ConvertFrom-Json -ErrorAction Stop
  }catch{
    throw "配置解析失败：$path -> $($_.Exception.Message)"
  }
  if(-not $cfg.repos){
    throw "配置格式错误：缺少 repos"
  }
  return $cfg.repos
}

function Get-AbstractFromSection([string]$path, [int]$maxChars){
  try { $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 } catch { return '' }
  $m = [Regex]::Match($raw, '(?ms)^\s*##\s*摘要\s*$\s*([\s\S]*?)(?=^\s*#{1,6}\s|\z)')
  if(-not $m.Success){ return '' }
  $text = $m.Groups[1].Value
  $text = $text -replace '(?ms)```.*?```',''
  $text = $text -replace '(?m)^\s*`{3,}.*$',''
  $text = $text -replace '!\[[^\]]*\]\([^)]*\)',''
  $text = [Regex]::Replace($text, '\[([^\]]+)\]\([^)]*\)', '$1')
  $text = $text -replace '`',''
  $text = $text -replace '(?m)^\s*#{1,6}\s*',''
  $text = $text -replace '(?m)^\s*>\s*',''
  $text = $text -replace '(?m)^\s*[-*_]{3,}\s*$',''
  $text = ($text -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) -join ' '
  $text = ($text -replace '\s+',' ').Trim()
  if([string]::IsNullOrWhiteSpace($text)){ return '' }
  if($text.Length -gt $maxChars){ $text = $text.Substring(0, $maxChars).Trim() }
  return $text
}

function BuildIndexFor([string]$dir, [int]$maxChars){
  if(-not (Test-Path -LiteralPath $dir -PathType Container)){ return @() }
  $files = Get-ChildItem -LiteralPath $dir -File -Filter '*.md' |
    Where-Object { $_.Name -ne 'LICENSE.md' -and $_.Name -ne 'INDEX.md' -and $_.FullName -notmatch '\\kernel_reference\\' } |
    Sort-Object Name
  $lines = New-Object System.Collections.Generic.List[string]
  foreach($f in $files){
    $rel = ($f.FullName | Resolve-Path -Relative)
    $rel = $rel -replace '^\.+\\',''
    $rel = $rel -replace '/', '\\'
    $lines.Add('- `' + $rel + '`：')
    $abs = Get-AbstractFromSection -path $f.FullName -maxChars $maxChars
    if(-not [string]::IsNullOrWhiteSpace($abs)){
      $lines.Add('  ' + $abs)
    }
  }
  return $lines
}

function UpdateReadmeSections([string]$readmePath, [hashtable]$sections){
  $exists = Test-Path -LiteralPath $readmePath -PathType Leaf
  if(-not $exists){
    Write-Verbose "创建 README：$readmePath"
    $header = @(
      '# 子项目文档汇总（部分稀疏克隆）',
      '',
      '- 本目录用于汇聚部分外部子仓库中的文档子目录（通过稀疏克隆复制到本仓库）。',
      '- 克隆映射配置见：`src/sub_projects_docs/sub_projects_clone_map.json`。',
      '- 更新步骤：运行 `pwsh -NoLogo -File script/clone_docs_from_sub_projects.ps1 -Verbose` 或 `pwsh -NoLogo -File script/build_index_sub_projects.ps1 -Verbose`。',
      '- 临时克隆目录：`out`（如无特殊需要，可保留以便增量更新）。',
      '-',
      '- 索引规则：非递归扫描各子目录下的 `*.md` 文件；为每个文件尝试抽取其“`## 摘要`”段落的前 `N` 个字符（默认 `500`）。',
      '-',
      '- 注意：本目录为集中展示，版权与许可遵循各子项目原始仓库；本仓库不修改其授权条款。',
      ''
    )
    $out = New-Object System.Collections.Generic.List[string]
    foreach($ln in $header){ $out.Add($ln) }
    foreach($k in $sections.Keys){
      $out.Add('## ' + $k)
      $out.Add('')
      foreach($ln in $sections[$k]){ $out.Add($ln) }
      if((@($sections[$k])).Count -eq 0){ $out.Add('（暂无条目）') }
      $out.Add('')
    }
    $enc = [System.Text.UTF8Encoding]::new($false)
    $text = ($out -join "`n")
    if(-not $text.EndsWith("`n")){ $text += "`n" }
    [System.IO.File]::WriteAllText($readmePath, $text, $enc)
    return
  }

  $all = Get-Content -LiteralPath $readmePath -Encoding UTF8

  foreach($name in $sections.Keys){
    $start = -1; $end = $all.Length
    for($i=0; $i -lt $all.Length; $i++){
      if($all[$i] -match ('^\s*##\s*' + [Regex]::Escape($name) + '\s*$')){ $start = $i; break }
    }
    if($start -lt 0){
      # 追加该节
      $append = New-Object System.Collections.Generic.List[string]
      if($all.Count -gt 0 -and $all[$all.Count-1] -ne ''){ $append.Add('') }
      $append.Add('## ' + $name)
      $append.Add('')
      foreach($ln in $sections[$name]){ $append.Add($ln) }
      if((@($sections[$name])).Count -eq 0){ $append.Add('（暂无条目）') }
      $all = @($all + $append.ToArray())
      continue
    }
    for($j=$start+1; $j -lt $all.Length; $j++){
      if($all[$j] -match '^\s*##\s+') { $end = $j; break }
    }
    $pre  = if($start -gt 0) { $all[0..$start] } else { @($all[$start]) }
    $post = if($end -lt $all.Length) { $all[$end..($all.Length-1)] } else { @() }
    $mid  = New-Object System.Collections.Generic.List[string]
    $mid.Add('')
    foreach($ln in $sections[$name]){ $mid.Add($ln) }
    if((@($sections[$name])).Count -eq 0){ $mid.Add('（暂无条目）') }
    $outLines = @($pre + $mid.ToArray() + $post)
    $all = $outLines
  }
  $enc = [System.Text.UTF8Encoding]::new($false)
  $text = ($all -join "`n")
  if(-not $text.EndsWith("`n")){ $text += "`n" }
  [System.IO.File]::WriteAllText($readmePath, $text, $enc)
}

# 主流程：不执行克隆，仅根据现有目录重建索引
Write-Host "[STEP] 读取配置（仅用于确定目标目录，不执行克隆）：$ConfigPath" -ForegroundColor Cyan
$repos = Read-CloneMap -path $ConfigPath

$sections = @{}
foreach($repo in $repos){
  $destDirRaw = [string](Normalize-Rel $repo.dest_dir)
  if([string]::IsNullOrWhiteSpace($destDirRaw)){
    throw "配置项缺少 dest_dir：$($repo | ConvertTo-Json -Compress)"
  }
  $destDir = $destDirRaw
  if(-not (Test-Path -LiteralPath $destDir -PathType Container)){
    Write-Verbose "目标目录不存在（跳过但保留空节）：$destDir"
    $sections[[IO.Path]::GetFileName($destDir)] = @()
    continue
  }
  $absDest = (Resolve-Path -LiteralPath $destDir).Path
  $name = [IO.Path]::GetFileName($absDest)
  $sections[$name] = BuildIndexFor -dir $absDest -maxChars $MaxChars
}

$docsRoot = 'src/sub_projects_docs'
$readme = Join-Path $docsRoot 'README.md'
UpdateReadmeSections -readmePath $readme -sections $sections
Write-Host "已重建索引（仅基于本地文件，不执行克隆）：$readme" -ForegroundColor Green

