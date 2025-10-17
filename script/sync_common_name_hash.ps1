<#
SPDX-License-Identifier: GPL-3.0-only
Copyright (C) 2025 GaoZheng

用途：
- 在 `src/kernel_reference` 与 `src/full_reference` 之间，基于“共同文件名（交集）”建立/校验/重建哈希映射（JSON 存储于 `src/full_reference/common_name_hash_map.json`）。
- 菜单模式：
  1) 初始化映射（若存在则覆盖）
  2) 打印变更（缺失/变更/新增交集/失去交集）
  3) 打印不一致（打印存在但不一致的）
  4) 生成不一致 CSV（生成存在但不一致的导入 CSV）
  5) 重建映射（覆盖为当前交集状态）
  6) 退出
- 也支持非交互：`-Mode init|check|diff|rebuild|menu`
- 额外开关：`-DiffCsvPath <path>` 将“不一致列表”导出为 CSV（与 `diff` 联动）。

说明：
- 仅统计两侧都存在、且“文件名完全一致”的 `.md` 文件（可按需调整 `Get-CommonMdNames`）。
- JSON 结构示例：
  {
    "example.md": { "kernel_reference": "<sha256>", "full_reference": "<sha256>" },
    ...
  }
#>

param(
  [ValidateSet('menu','init','check','diff','rebuild')]
  [string]$Mode = 'menu',
  [string]$DiffCsvPath
)

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$ErrorActionPreference = 'Stop'

function Get-RepoPaths {
  $root = (Resolve-Path '.').Path
  $kr   = Join-Path $root 'src' | Join-Path -ChildPath 'kernel_reference'
  $fr   = Join-Path $root 'src' | Join-Path -ChildPath 'full_reference'
  $map  = Join-Path $fr 'common_name_hash_map.json'
  return [ordered]@{ Root=$root; KernelDir=$kr; FullDir=$fr; MapPath=$map }
}

function Get-CommonMdNames([string]$krDir, [string]$frDir){
  $krFiles = Get-ChildItem -LiteralPath $krDir -File -Filter '*.md' -ErrorAction SilentlyContinue
  $frFiles = Get-ChildItem -LiteralPath $frDir -File -Filter '*.md' -ErrorAction SilentlyContinue
  $krSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach($f in $krFiles){ [void]$krSet.Add($f.Name) }
  $common = New-Object System.Collections.Generic.List[string]
  foreach($f in $frFiles){ if($krSet.Contains($f.Name)){ $common.Add($f.Name) } }
  return ($common | Sort-Object)
}

function Get-FileSha256([string]$path){
  if(-not (Test-Path -LiteralPath $path -PathType Leaf)){ return $null }
  try{ return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
  catch { return $null }
}

function Build-Mapping([string]$krDir,[string]$frDir){
  $names = Get-CommonMdNames -krDir $krDir -frDir $frDir
  $map = [ordered]@{}
  foreach($n in $names){
    $krPath = Join-Path $krDir $n
    $frPath = Join-Path $frDir $n
    $map[$n] = [ordered]@{
      kernel_reference = Get-FileSha256 $krPath
      full_reference   = Get-FileSha256 $frPath
    }
  }
  return $map
}

function Load-Mapping([string]$mapPath){
  if(-not (Test-Path -LiteralPath $mapPath -PathType Leaf)){ return $null }
  $raw = Get-Content -LiteralPath $mapPath -Raw -Encoding UTF8
  if([string]::IsNullOrWhiteSpace($raw)){ return $null }
  $obj = $raw | ConvertFrom-Json -ErrorAction Stop
  # 转字典（保持 name->hashtable，有序性非关键）
  $dict = @{}
  foreach($p in $obj.PSObject.Properties){ $dict[$p.Name] = $p.Value }
  return $dict
}

function Save-Mapping([hashtable]$map,[string]$mapPath){
  $json = ($map | ConvertTo-Json -Depth 5)
  $parent = Split-Path -Path $mapPath -Parent
  if(-not (Test-Path -LiteralPath $parent -PathType Container)){ New-Item -ItemType Directory -Path $parent | Out-Null }
  $json | Set-Content -LiteralPath $mapPath -Encoding UTF8
}

function Export-InconsistenciesCsv($items,[string]$path){
  $parent = Split-Path -Path $path -Parent
  if(-not (Test-Path -LiteralPath $parent -PathType Container)){
    New-Item -ItemType Directory -Path $parent | Out-Null
  }
  if($null -eq $items -or $items.Count -eq 0){
    # 输出仅表头，便于后续流水线使用
    "name,kernel_reference,full_reference" | Set-Content -LiteralPath $path -Encoding UTF8
    Write-Host ("已导出 CSV（空结果，仅表头）：{0}" -f $path) -ForegroundColor Yellow
    return
  }
  # 规范为 PSCustomObject，确保列顺序
  $objs = foreach($i in $items){
    [pscustomobject]@{
      name              = $i.name
      kernel_reference  = $i.kernel_reference
      full_reference    = $i.full_reference
    }
  }
  $objs | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8
  Write-Host ("已导出 CSV：{0}" -f $path) -ForegroundColor Green
}

function Print-Inconsistencies([hashtable]$current, [string]$CsvPath){
  if($null -eq $current -or $current.Keys.Count -eq 0){
    Write-Host '无共同文件名可检查。' -ForegroundColor Yellow
    return @()
  }
  $list = New-Object System.Collections.Generic.List[object]
  foreach($name in $current.Keys | Sort-Object){
    $v = $current[$name]
    $kr = $v.kernel_reference
    $fr = $v.full_reference
    if([string]::IsNullOrEmpty($kr) -or [string]::IsNullOrEmpty($fr)){ continue }
    if($kr -ne $fr){
      $list.Add([ordered]@{ name=$name; kernel_reference=$kr; full_reference=$fr })
    }
  }
  if($list.Count -eq 0){
    Write-Host '无不一致项。' -ForegroundColor Green
  } else {
    Write-Host '[不一致] 以下文件两侧均存在，但内容哈希不同：' -ForegroundColor Cyan
    foreach($i in $list){
      Write-Host (" - {0}" -f $i.name)
      Write-Host ("   kernel_reference: {0}" -f $i.kernel_reference)
      Write-Host ("   full_reference  : {0}" -f $i.full_reference)
    }
  }
  # 兼容：优先使用显式 CsvPath；否则回退到脚本参数 -DiffCsvPath
  $targetCsv = $CsvPath
  if([string]::IsNullOrWhiteSpace($targetCsv) -and -not [string]::IsNullOrWhiteSpace($DiffCsvPath)){
    $targetCsv = $DiffCsvPath
  }
  if(-not [string]::IsNullOrWhiteSpace($targetCsv)){
    Export-InconsistenciesCsv -items $list -path $targetCsv
  }
  return $list
}

function Print-Changes([hashtable]$saved,[hashtable]$current,[string]$krDir,[string]$frDir){
  if($null -eq $saved){
    Write-Host '映射不存在，请先选择“初始化映射”。' -ForegroundColor Yellow
    return
  }
  $savedNames   = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach($k in $saved.Keys){ [void]$savedNames.Add($k) }
  $currentNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach($k in $current.Keys){ [void]$currentNames.Add($k) }

  $changed = New-Object System.Collections.Generic.List[object]
  $missing = New-Object System.Collections.Generic.List[object]
  $newint  = New-Object System.Collections.Generic.List[object]
  $lostint = New-Object System.Collections.Generic.List[object]

  # 变更与缺失
  foreach($name in $saved.Keys | Sort-Object){
    $sv = $saved[$name]
    $cur = $current.ContainsKey($name) ? $current[$name] : $null
    if($null -eq $cur){ $lostint.Add($name); continue }

    $krPath = Join-Path $krDir $name
    $frPath = Join-Path $frDir $name

    $krExists = Test-Path -LiteralPath $krPath -PathType Leaf
    $frExists = Test-Path -LiteralPath $frPath -PathType Leaf
    if(-not $krExists){ $missing.Add([ordered]@{ name=$name; side='kernel_reference'; reason='缺失文件' }); }
    if(-not $frExists){ $missing.Add([ordered]@{ name=$name; side='full_reference'; reason='缺失文件' }); }

    if($krExists -and $sv.kernel_reference -ne $cur.kernel_reference){
      $changed.Add([ordered]@{
        name=$name; side='kernel_reference'; old=$sv.kernel_reference; new=$cur.kernel_reference
      })
    }
    if($frExists -and $sv.full_reference -ne $cur.full_reference){
      $changed.Add([ordered]@{
        name=$name; side='full_reference'; old=$sv.full_reference; new=$cur.full_reference
      })
    }
  }

  # 新增交集（当前有，历史没有）
  foreach($name in $current.Keys){ if(-not $savedNames.Contains($name)){ $newint.Add($name) } }

  # 输出
  if($changed.Count -eq 0 -and $missing.Count -eq 0 -and $newint.Count -eq 0 -and $lostint.Count -eq 0){
    Write-Host '无变更。' -ForegroundColor Green
    return
  }

  if($changed.Count -gt 0){
    Write-Host "[变更] 以下条目哈希已改变：" -ForegroundColor Cyan
    foreach($c in $changed){ Write-Host (" - {0} [{1}] {2} -> {3}" -f $c.name,$c.side,$c.old,$c.new) }
  }
  if($missing.Count -gt 0){
    Write-Host "[缺失] 以下条目在对应侧不存在：" -ForegroundColor Magenta
    foreach($m in $missing){ Write-Host (" - {0} [{1}] {2}" -f $m.name,$m.side,$m.reason) }
  }
  if($newint.Count -gt 0){
    Write-Host "[新增交集] 当前新增的共同文件名（未记录于映射）：" -ForegroundColor Yellow
    foreach($n in $newint){ Write-Host (" - {0}" -f $n) }
  }
  if($lostint.Count -gt 0){
    Write-Host "[失去交集] 这些文件名不再两侧同时存在：" -ForegroundColor DarkYellow
    foreach($n in $lostint){ Write-Host (" - {0}" -f $n) }
  }
}

function Do-Init(){
  $p = Get-RepoPaths
  $existed = Test-Path -LiteralPath $p.MapPath -PathType Leaf
  $map = Build-Mapping -krDir $p.KernelDir -frDir $p.FullDir
  Save-Mapping -map $map -mapPath $p.MapPath
  $action = if($existed){ '覆盖' } else { '创建' }
  Write-Host ("已{0}映射：{1}，条目数：{2}" -f $action, $p.MapPath, $map.Keys.Count) -ForegroundColor Green
}

function Do-Check(){
  $p = Get-RepoPaths
  $saved = Load-Mapping -mapPath $p.MapPath
  $current = Build-Mapping -krDir $p.KernelDir -frDir $p.FullDir
  Print-Changes -saved $saved -current $current -krDir $p.KernelDir -frDir $p.FullDir
}

function Do-Diff(){
  $p = Get-RepoPaths
  $current = Build-Mapping -krDir $p.KernelDir -frDir $p.FullDir
  Print-Inconsistencies -current $current -CsvPath $DiffCsvPath | Out-Null
}

function Do-DiffCsv(){
  $p = Get-RepoPaths
  $current = Build-Mapping -krDir $p.KernelDir -frDir $p.FullDir
  $defaultPath = Join-Path $p.FullDir 'common_name_hash_diff.csv'
  $hint = Read-Host ("请输入导出 CSV 路径（默认：$defaultPath）")
  $outPath = if([string]::IsNullOrWhiteSpace($hint)) { $defaultPath } else { $hint }
  Print-Inconsistencies -current $current -CsvPath $outPath | Out-Null
}

function Do-Rebuild(){
  $p = Get-RepoPaths
  $map = Build-Mapping -krDir $p.KernelDir -frDir $p.FullDir
  Save-Mapping -map $map -mapPath $p.MapPath
  Write-Host ("已重建映射：{0}，条目数：{1}" -f $p.MapPath, $map.Keys.Count) -ForegroundColor Green
}

function Show-Menu(){
  while($true){
    Write-Host ''
    Write-Host '==== 共同文件名哈希映射 ====' -ForegroundColor White
    Write-Host '1) 初始化映射（若存在则覆盖）'
    Write-Host '2) 打印变更（缺失/变更/新增交集/失去交集）'
    Write-Host '3) 打印不一致（打印存在但不一致的）'
    Write-Host '4) 生成不一致 CSV（生成存在但不一致的导入 CSV）'
    Write-Host '5) 重建映射（覆盖为当前交集状态）'
    Write-Host '6) 退出'
    $sel = Read-Host '请选择操作 [1-6]'
    switch($sel){
      '1' { Do-Init }
      '2' { Do-Check }
      '3' { Do-Diff }
      '4' { Do-DiffCsv }
      '5' { Do-Rebuild }
      '6' { return }
      default { Write-Host '无效选项，请输入 1-6。' -ForegroundColor Red }
    }
  }
}

switch($Mode){
  'init'    { Do-Init }
  'check'   { Do-Check }
  'diff'    { Do-Diff }
  'rebuild' { Do-Rebuild }
  default   { Show-Menu }
}
