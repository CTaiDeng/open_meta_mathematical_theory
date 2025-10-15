# Copyright (C) 2025 GaoZheng
# SPDX-License-Identifier: GPL-3.0-only
# This file is part of this project.
# Licensed under the GNU General Public License version 3.
# See https://www.gnu.org/licenses/gpl-3.0.html for details.
param(
  [int]$MaxChars = 300
)

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path '.').Path
$dir  = Join-Path $root 'src\kernel_reference'

# 分类规则（按优先级匹配一个主类）
$categories = [ordered]@{
  '传统/O3/PFB-GNLA论证' = @('严谨论证','近似实现','PFB-GNLA','O3理论','解析解AI','O3元数学','传统数学');
  '算法/路径积分/逆参'   = @('DERI','GCPOLAA','路径积分','逆参','状态路径','w\(t\)');
  '量子/观察者/卡丘/宇宙' = @('量子','观察者','卡丘','宇宙','流形');
  '元数学理论'           = @('元数学','泛逻辑','泛迭代','公理化','C泛范畴','泛拓扑','泛抽象代数');
  'GRL/广义增强学习'     = @('广义增强学习','\bGRL\b','解析解');
  '广义集合/分形/康托'   = @('集合论','康托','分形','集合');
  '金融/量化交易/价→账→参' = @('量化交易','价→账','价—账','相对价');
  '生命科学/PGOM/LBOPB/HIV' = @('PGOM','LBOPB','生命','HIV');
  'AI对齐/原则/博弈/统计解' = @('对齐','原则','博弈','统计解','随机生成');
  '连续统假设'           = @('连续统假设');
  '长时序/认知模型'       = @('长时序','认知模型');
  'D结构'                = @('D结构');
  '其他综述/评价'         = @('发展','评价','交汇','综述');
  '未分类'               = @();
}

function Get-PrimaryCategory([string]$name){
  foreach($kv in $categories.GetEnumerator()){
    $cat=$kv.Key; $pats=$kv.Value
    if($cat -eq '未分类'){ continue }
    foreach($p in $pats){ if($name -match $p){ return $cat } }
  }
  return '未分类'
}

function Clean-Text([string]$text){
  if([string]::IsNullOrWhiteSpace($text)){ return '' }
  $t = $text
  # 删除“目录”分节（从目录标题到下一个标题/文末）
  $t = [Regex]::Replace($t,'(?ms)^\s*#{1,6}\s*目\s*录\s*$.*?(?=^\s*#{1,6}\s*\S|\z)','')
  # 删除center块、水平线
  $t = $t -replace '(?is)<center>.*?</center>','' -replace '(?m)^\s*[-*_]{3,}\s*$',''
  # 删除块引用中的“说明：”以及独立“说明：”行
  $t = $t -replace '(?m)^\s*>?\s*说明[:：].*$',''
  # 删除Markdown标题前缀 #### 等，但保留标题文字
  $t = $t -replace '(?m)^\s{0,3}#{1,6}\s*',''
  # 删除粗体/斜体/行内代码/数学
  $t = $t -replace '(\*\*|__|\*)','' -replace '`','' -replace '\$[^$]*\$',''
  # 删除多余空行与空白
  $lines = $t -split "\r?\n" | Where-Object { $_ -ne '' -and $_.Trim().Length -gt 0 -and $_.Trim() -ne '目录' }
  $t = ($lines -join ' ')
  $t = ($t -replace '\s+',' ').Trim()
  return $t
}

function Get-Abstract([string]$path, [int]$max=500){
  try{ $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 } catch { return '' }
  # 优先取“摘要”段落
  $m = [Regex]::Match($raw, '(?ms)^\s*#{1,6}\s*摘要[:：]?\s*$([^#]+)')
  if($m.Success){ $text = $m.Groups[1].Value } else { $text = $raw }
  $text = Clean-Text $text
  if([string]::IsNullOrWhiteSpace($text)){ return '' }
  if($text.Length -gt $max){ $text = $text.Substring(0,[Math]::Min($text.Length,$max)).Trim() + '…' }
  return $text
}

$files = Get-ChildItem -LiteralPath $dir -Recurse -File -Filter '*.md' |
         Where-Object { $_.Name -ne 'INDEX.md' -and $_.Name -ne 'LICENSE.md' -and $_.Name -ne 'KERNEL_REFERENCE_README.md' -and -not $_.Name.EndsWith('说明.md') } |
         Sort-Object FullName

# 构建分组
$groups = @{}
foreach($f in $files){
  $name = $f.Name
  $cat  = Get-PrimaryCategory $name
  if(-not $groups.ContainsKey($cat)){ $groups[$cat] = New-Object System.Collections.Generic.List[object] }
  $groups[$cat].Add($f)
}

# 生成内容
$out = New-Object System.Collections.Generic.List[string]
$out.Add('**基于分类的索引（含摘要）**')
$out.Add('')
$total = $files.Count
$out.Add("- 总计：$total 篇；第一行仅显示文件名（代码样式，无链接/无项目符），下一行输出清洗后的摘要。")
$out.Add('')

# 使用手动定义的头样式替换自动生成的简化头部
$out = New-Object System.Collections.Generic.List[string]
$out.Add('# **基于分类的索引（含摘要）**')
$out.Add('')
$out.Add('### [若为非Github的镜像点击这里为项目官方在Github的完整原版](https://github.com/CTaiDeng/open_meta_mathematical_theory)')
$out.Add('### [作者：GaoZheng](https://mymetamathematics.blogspot.com)')
$out.Add('')
$out.Add('---')
$out.Add('')
$out.Add("### 总计：$total 篇；第一行仅显示文件名（代码样式，无链接/无项目符），下一行输出清洗后的摘要。")
$out.Add('')
$out.Add('---')
$out.Add('')

foreach($cat in $categories.Keys){
  if(-not $groups.ContainsKey($cat)){ continue }
  $out.Add("## $cat")
  $out.Add('')
  foreach($f in ($groups[$cat] | Sort-Object FullName)){
    $abstract   = Get-Abstract $f.FullName $MaxChars
    # 文件形如：`文件名.md`（不加-，不加链接）
    $out.Add('`' + $f.Name + '`')
    if($abstract -ne ''){ $out.Add('摘要：' + $abstract) } else { $out.Add('摘要：无（建议在文首添加“摘要”段落）') }
  }
  $out.Add('')
}

$target = Join-Path $dir 'INDEX.md'
$out | Set-Content -LiteralPath $target -Encoding UTF8
Write-Host "Generated: $target with $total entries."


