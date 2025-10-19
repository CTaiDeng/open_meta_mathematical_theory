<#
SPDX-License-Identifier: GPL-3.0-only
Copyright (C) 2025 GaoZheng

用途：
- 基于 `src/full_reference/common_name_hash_diff.csv` 的文件名列表，将
  `src/kernel_reference/<name>` 的文件复制到 `src/full_reference/<name>` 的“源文件绝对路径”。
- 若 `src/full_reference/<name>` 为符号链接，则解析其 `Target` 并复制到该绝对路径；
  若不是符号链接但存在，则直接覆盖该文件；若不存在则跳过并告警。

使用：
- 干跑预览：
  pwsh -NoLogo -File script/copy_kernel_to_full_from_diff.ps1 -WhatIf
- 实际执行：
  pwsh -NoLogo -File script/copy_kernel_to_full_from_diff.ps1
- 指定 CSV 路径：
  pwsh -NoLogo -File script/copy_kernel_to_full_from_diff.ps1 -CsvPath 'src/full_reference/common_name_hash_diff.csv'

CSV 格式（由 `sync_common_name_hash.ps1 -Mode diff` 生成）：
  name,kernel_reference,full_reference
  仅 `name` 字段参与复制匹配，哈希字段仅用于人类审阅。
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$CsvPath = 'src/full_reference/common_name_hash_diff.csv'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

function Repo-Root {
  return (Resolve-Path '.').Path
}

function Resolve-Abs([string]$p){
  try{ return (Resolve-Path -LiteralPath $p -ErrorAction Stop).Path } catch { return $p }
}

function Get-FullTarget([string]$fullLinkPath){
  if(-not (Test-Path -LiteralPath $fullLinkPath)){
    return $null
  }
  $item = Get-Item -LiteralPath $fullLinkPath -Force -ErrorAction SilentlyContinue
  if(-not $item){ return $null }
  if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){
    try{
      $t = (Get-Item -LiteralPath $fullLinkPath -Force).Target
      if([string]::IsNullOrWhiteSpace($t)){ return $null }
      # 若为相对路径，则基于链接所在目录求绝对路径
      if([IO.Path]::IsPathRooted($t)){ return (Resolve-Abs $t) }
      $base = Split-Path -Parent $fullLinkPath
      return (Resolve-Abs (Join-Path $base $t))
    } catch { return $null }
  } else {
    return (Resolve-Abs $fullLinkPath)
  }
}

function Ensure-ParentDir([string]$path){
  $dir = Split-Path -Parent $path
  if(-not (Test-Path -LiteralPath $dir -PathType Container)){
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
}

function Copy-One([string]$name,[string]$krDir,[string]$frDir){
  $src = Join-Path $krDir $name
  $frLink = Join-Path $frDir $name
  if(-not (Test-Path -LiteralPath $src -PathType Leaf)){
    Write-Warning ("kernel_reference 源文件不存在：{0}" -f $src)
    return $false
  }
  $target = Get-FullTarget -fullLinkPath $frLink
  if([string]::IsNullOrWhiteSpace($target)){
    Write-Warning ("full_reference 目标缺失或不可解析：{0}" -f $frLink)
    return $false
  }
  if($PSCmdlet.ShouldProcess($target, "Copy from kernel -> full source")){
    Ensure-ParentDir $target
    Copy-Item -LiteralPath $src -Destination $target -Force
    Write-Host ("已复制：{0} -> {1}" -f $src,$target) -ForegroundColor Green
  }
  return $true
}

$root = Repo-Root
$krDir = Join-Path $root 'src\kernel_reference'
$frDir = Join-Path $root 'src\full_reference'
$csvAbs = Resolve-Abs $CsvPath

if(-not (Test-Path -LiteralPath $csvAbs -PathType Leaf)){
  throw "CSV 不存在：$csvAbs"
}

$rows = Import-Csv -LiteralPath $csvAbs -Encoding UTF8
if($null -eq $rows){ $rows = @() }

$total=0; $ok=0; $skip=0
foreach($row in $rows){
  $name = [string]$row.name
  if([string]::IsNullOrWhiteSpace($name)){ continue }
  $total++
  $res = Copy-One -name $name -krDir $krDir -frDir $frDir
  if($res){ $ok++ } else { $skip++ }
}

Write-Host ("完成：共 {0} 条，复制 {1} 条，跳过 {2} 条。" -f $total,$ok,$skip) -ForegroundColor Cyan
