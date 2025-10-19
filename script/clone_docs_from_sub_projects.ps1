<#
SPDX-License-Identifier: GPL-3.0-only
Copyright (C) 2025 GaoZheng

本脚本用于：按 JSON 配置对外部子仓库执行“部分（稀疏）克隆”，
将指定子目录内容复制到本仓库 `src/sub_projects_docs/<name>` 下，并在该目录生成索引型 README。

使用示例：
  pwsh -NoLogo -File script/clone_docs_from_sub_projects/clone_docs_from_sub_projects.ps1 -Verbose

参数说明：
  -ConfigPath  配置 JSON 路径（默认：src/sub_projects_docs/sub_projects_clone_map.json）
  -OutDir      临时克隆目录（默认：out）
  -DocsRoot    目标文档根（默认：src/sub_projects_docs）
  -MaxChars    摘要截断字符数（默认：500）
  -Step        逐步调试；在关键步骤暂停等待回车
  -SkipClone   跳过克隆阶段
  -SkipCopy    跳过复制阶段
  -SkipIndex   跳过 README 索引更新

注意：遵循仓库 AGENTS.md 协议；不修改任何授权文件。
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$ConfigPath = 'src/sub_projects_docs/sub_projects_clone_map.json',
  [string]$OutDir = 'out',
  [string]$DocsRoot = 'src/sub_projects_docs',
  [int]$MaxChars = 500,
  [switch]$Step,
  [switch]$SkipClone,
  [switch]$SkipCopy,
  [switch]$SkipIndex,
  [switch]$KeepOut
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

function Write-Step([string]$msg){ Write-Host "[STEP] $msg" -ForegroundColor Cyan }
function Pause-IfStep([string]$msg){ if($Step){ Write-Host $msg -ForegroundColor Yellow; Read-Host '按回车继续' | Out-Null } }

function Normalize-Rel([string]$p){ if([string]::IsNullOrWhiteSpace($p)){ return $p } return ($p -replace '/', '\').Trim() }

function Ensure-Dir([string]$path){ if(-not (Test-Path -LiteralPath $path -PathType Container)){ New-Item -ItemType Directory -Force -Path $path | Out-Null } }

function Read-CloneMap([string]$path){
  if(-not (Test-Path -LiteralPath $path -PathType Leaf)){ throw "配置不存在：$path" }
  $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
  try{ $cfg = $raw | ConvertFrom-Json -ErrorAction Stop }catch{ throw "配置解析失败：$path -> $($_.Exception.Message)" }
  if(-not $cfg.repos){ throw "配置格式错误：缺少 repos" }
  return $cfg.repos
}

function Get-RepoNameFromUrl([string]$url){
  $u = $url.TrimEnd('/')
  $name = [IO.Path]::GetFileName($u)
  if($name -like '*.git'){ $name = $name.Substring(0, $name.Length-4) }
  return $name
}

function Invoke-SparseClone([string]$url, [string]$sourceSubdir, [string]$outDir, [switch]$TopFilesOnly, [string]$FileGlob='*.md'){
  $repoName = Get-RepoNameFromUrl $url
  $cloneDir = Join-Path -Path $outDir -ChildPath $repoName
  Ensure-Dir $outDir

  if(Test-Path -LiteralPath $cloneDir -PathType Container){
    Write-Verbose "临时克隆目录已存在：$cloneDir（将复用）"
  } else {
    Write-Step "克隆（no-checkout + blob:none）：$url -> $cloneDir"
    if($PSCmdlet.ShouldProcess($cloneDir, "git clone --no-checkout --depth=1 --filter=blob:none")){
      git clone --depth=1 --filter=blob:none --no-checkout -- "$url" "$cloneDir" | Write-Verbose
    }
  }
  Pause-IfStep "已准备克隆目录：$cloneDir"

  $src = Normalize-Rel $sourceSubdir
  $srcSlash = ($src -replace '\\','/')

  if($TopFilesOnly){
    Write-Verbose "初始化 sparse-checkout（no-cone，顶层文件模式）"
    if($PSCmdlet.ShouldProcess($cloneDir, "git sparse-checkout init --no-cone")){
      git -C "$cloneDir" sparse-checkout init --no-cone | Write-Verbose
    }
    $pattern = "/$srcSlash/$FileGlob"
    Write-Verbose "设置稀疏模式（no-cone set）：$pattern"
    if($PSCmdlet.ShouldProcess($cloneDir, "git sparse-checkout set --no-cone $pattern")){
      git -C "$cloneDir" sparse-checkout set --no-cone -- "$pattern" | Write-Verbose
    }
    if($LASTEXITCODE -ne 0){
      Write-Verbose "no-cone 模式失败（exit $LASTEXITCODE），回退至 cone 模式目录级稀疏。"
      if($PSCmdlet.ShouldProcess($cloneDir, "git sparse-checkout init --cone [fallback]")){
        git -C "$cloneDir" sparse-checkout init --cone | Write-Verbose
      }
      if($PSCmdlet.ShouldProcess($cloneDir, "git sparse-checkout set $src [fallback]")){
        git -C "$cloneDir" sparse-checkout set -- "$src" | Write-Verbose
      }
    }
  } else {
    Write-Verbose "初始化 sparse-checkout（cone 模式）"
    if($PSCmdlet.ShouldProcess($cloneDir, "git sparse-checkout init --cone")){
      git -C "$cloneDir" sparse-checkout init --cone | Write-Verbose
    }
    Write-Verbose "设置稀疏路径：$src"
    if($PSCmdlet.ShouldProcess($cloneDir, "git sparse-checkout set $src")){
      git -C "$cloneDir" sparse-checkout set -- "$src" | Write-Verbose
    }
  }
  if($PSCmdlet.ShouldProcess($cloneDir, "git checkout")){
    git -C "$cloneDir" checkout | Write-Verbose
  }
  Pause-IfStep "已完成稀疏检出：$src"
  return @{ CloneDir = $cloneDir; SourcePath = (Join-Path $cloneDir $src) }
}

function Copy-FromSource([string]$srcPath, [string]$destDir){
  if(-not (Test-Path -LiteralPath $srcPath -PathType Container)){
    throw "源目录不存在：$srcPath"
  }
  Ensure-Dir $destDir
  Write-Step "复制内容：$srcPath -> $destDir"
  $items = Get-ChildItem -LiteralPath $srcPath -Recurse -Force |
    Where-Object { $_.PSIsContainer -eq $false -and $_.FullName -notmatch '\\.git(\\|$)' }
  foreach($it in $items){
    $rel = [System.IO.Path]::GetRelativePath($srcPath, $it.FullName)
    # 去除前导分隔符（兼容 / 和 \）
    while($rel.StartsWith('\') -or $rel.StartsWith('/')){ $rel = $rel.Substring(1) }
    $to  = Join-Path $destDir $rel
    $toDir = Split-Path -Parent $to
    if(-not (Test-Path -LiteralPath $toDir -PathType Container)){
      if($PSCmdlet.ShouldProcess($toDir, '创建目录')){ New-Item -ItemType Directory -Force -Path $toDir | Out-Null }
    }
    if($PSCmdlet.ShouldProcess($to, '复制文件')){ Copy-Item -LiteralPath $it.FullName -Destination $to -Force }
  }
}

function Copy-TopLevelFiles([string]$srcPath, [string]$destDir){
  if(-not (Test-Path -LiteralPath $srcPath -PathType Container)){
    throw "源目录不存在：$srcPath"
  }
  Ensure-Dir $destDir
  Write-Step "复制内容（不递归）：$srcPath -> $destDir"
  $items = Get-ChildItem -LiteralPath $srcPath -Force -File |
    Where-Object { $_.Name -notin @('LICENSE.md','INDEX.md') }
  foreach($it in $items){
    $to  = Join-Path $destDir $it.Name
    if($PSCmdlet.ShouldProcess($to, '复制文件')){ Copy-Item -LiteralPath $it.FullName -Destination $to -Force }
  }
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

function Clean-ForbiddenDirs([string]$destDir){
  if(-not (Test-Path -LiteralPath $destDir -PathType Container)){ return }
  $forbidden = @('kernel_reference','theory','hematical_theory')
  $subs = Get-ChildItem -LiteralPath $destDir -Directory -Force
  foreach($d in $subs){
    if($forbidden -contains $d.Name){
      Write-Verbose "移除禁止目录：$($d.FullName)"
      if($PSCmdlet.ShouldProcess($d.FullName, '删除禁止目录')){ Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }
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
      '- 更新步骤：运行 `pwsh -NoLogo -File script/clone_docs_from_sub_projects.ps1 -Verbose`。',
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
    $out | Set-Content -LiteralPath $readmePath -Encoding UTF8
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
    $out = @($pre + $mid.ToArray() + $post)
    $all = $out
  }
  $all | Set-Content -LiteralPath $readmePath -Encoding UTF8
}

# 主流程
Write-Step "读取配置：$ConfigPath"
$repos = Read-CloneMap -path $ConfigPath
Pause-IfStep "已读取配置，共 $($repos.Count) 个条目"

$sections = @{}

foreach($repo in $repos){
  $url = [string]$repo.url
  $srcSub = [string](Normalize-Rel $repo.source_subdir)
  $destDir = [string](Normalize-Rel $repo.dest_dir)
  if([string]::IsNullOrWhiteSpace($url) -or [string]::IsNullOrWhiteSpace($srcSub) -or [string]::IsNullOrWhiteSpace($destDir)){
    throw "配置项不完整：$($repo | ConvertTo-Json -Compress)"
  }
  if(-not $SkipClone){
    # 仅需顶层 Markdown 文件，启用 TopFilesOnly 以减少检出规模、提升速度
    $res = Invoke-SparseClone -url $url -sourceSubdir $srcSub -outDir $OutDir -TopFilesOnly
    $sourcePath = [string]$res.SourcePath
  } else {
    $repoName = Get-RepoNameFromUrl $url
    $sourcePath = Join-Path (Join-Path $OutDir $repoName) $srcSub
    Write-Verbose "跳过克隆，使用现有路径：$sourcePath"
  }

  # 无论是否复制，都先清理一次禁止目录，满足“删除并避免创建”的要求
  Clean-ForbiddenDirs -destDir $destDir

  # 当 SkipClone 打开且源目录不存在时，自动跳过复制，仅重建索引
  $skipCopyThisRepo = $false
  if($SkipClone -and -not (Test-Path -LiteralPath $sourcePath -PathType Container)){
    $skipCopyThisRepo = $true
    Write-Verbose "跳过复制：源目录缺失 -> $sourcePath"
  }

  if(-not $SkipCopy -and -not $skipCopyThisRepo){
    # 仅复制顶层文件（不递归，不进入子目录）
    Copy-TopLevelFiles -srcPath $sourcePath -destDir $destDir
    # 再次清理禁止目录，避免误创建
    Clean-ForbiddenDirs -destDir $destDir
  } else {
    Write-Verbose "已跳过复制：SkipCopy=$SkipCopy, skipCopyThisRepo=$skipCopyThisRepo"
  }

  Pause-IfStep "准备为 $destDir 构建索引"
  $absDest = (Resolve-Path -LiteralPath $destDir).Path
  $sections[[IO.Path]::GetFileName($absDest)] = BuildIndexFor -dir $absDest -maxChars $MaxChars
}

if(-not $SkipIndex){
  $readme = Join-Path $DocsRoot 'README.md'
  UpdateReadmeSections -readmePath $readme -sections $sections
  Write-Host "已更新索引：$readme" -ForegroundColor Green
}

# 按需清理临时克隆目录（用完即删）
if(-not $KeepOut){
  foreach($r in $repos){
    $rName = Get-RepoNameFromUrl([string]$r.url)
    $rDir = Join-Path $OutDir $rName
    if(Test-Path -LiteralPath $rDir -PathType Container){
      Write-Verbose "清理临时克隆：$rDir"
      Remove-Item -LiteralPath $rDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Write-Host "完成。" -ForegroundColor Green
