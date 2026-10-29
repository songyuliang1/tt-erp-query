<#
.SYNOPSIS
  技能自检：UTF-8 BOM、PowerShell 语法解析、SKILL.md frontmatter 合规。

.DESCRIPTION
  Windows PowerShell 5.1 读 .ps1 时，没有 UTF-8 BOM 就按 ANSI（简中机器是 GBK）解码，
  中文全变乱码、引号与括号被吞，脚本直接语法错。任何编辑器或工具重写文件都可能把 BOM
  丢掉，所以把它做成可重复执行的自检，而不是靠人记。

  默认行为：
    1) 扫描 <Root> 下每个技能目录；
    2) *.ps1 缺 BOM 就补上（-CheckOnly 时只报不补）；
    3) 用 PowerShell 解析器解析每个 *.ps1，报出语法错误 —— BOM 丢没丢，这一步会兜住；
    4) 校验 SKILL.md frontmatter：name 必须等于目录名、字符集合规、description 非空且 <= 1024 字。

.PARAMETER Root
  技能根目录，默认本脚本所在技能目录的上一级（仓库里是 skills/）。

.PARAMETER CheckOnly
  只检查不改：不补 BOM。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .agents/skills/tt-erp-inv-query/scripts/selfcheck.ps1

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File selfcheck.ps1 -CheckOnly
#>
[CmdletBinding()]
param(
  [string]$Root,
  [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'

if (-not $Root) {
  $Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
if (-not (Test-Path $Root)) {
  Write-Host "[错误] 技能根目录不存在：$Root" -ForegroundColor Red
  exit 2
}

$bomBytes = [byte[]](0xEF, 0xBB, 0xBF)
$problems = 0
$fixed = 0
$skillCount = 0
$scriptCount = 0

function Test-Bom {
  param([string]$Path)
  $b = [System.IO.File]::ReadAllBytes($Path)
  if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { return $true }
  return $false
}

function Add-Bom {
  param([string]$Path)
  $b = [System.IO.File]::ReadAllBytes($Path)
  [System.IO.File]::WriteAllBytes($Path, [byte[]]($bomBytes + $b))
}

# 与 internal/skill 的 ParseFrontmatter 对齐：只认顶层 `键: 值`，支持 | / > 块标量。
function Get-Frontmatter {
  param([string]$Path)
  $text = Get-Content -Path $Path -Raw -Encoding UTF8
  if ($null -eq $text) { return $null }
  $text = $text -replace "^\uFEFF", ''
  $lines = ($text -replace "`r`n", "`n") -split "`n"
  if ($lines.Count -eq 0 -or $lines[0].Trim() -ne '---') { return $null }
  $end = -1
  for ($i = 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i].Trim() -eq '---') { $end = $i; break }
  }
  if ($end -lt 0) { return $null }

  $meta = @{ name = ''; description = '' }
  for ($i = 1; $i -lt $end; $i++) {
    $line = $lines[$i]
    if ($line -eq '' -or $line[0] -eq ' ' -or $line[0] -eq "`t") { continue }
    if ($line.TrimStart().StartsWith('#')) { continue }
    $idx = $line.IndexOf(':')
    if ($idx -lt 0) { continue }
    $key = $line.Substring(0, $idx).Trim()
    $val = $line.Substring($idx + 1).Trim()
    if ($key -eq 'name') {
      $meta.name = $val.Trim('"').Trim("'")
    }
    elseif ($key -eq 'description') {
      if ($val -in @('|', '>', '|-', '>-')) {
        $parts = @()
        for ($j = $i + 1; $j -lt $end; $j++) {
          $l = $lines[$j]
          if ($l.Trim() -eq '') { continue }
          if ($l[0] -ne ' ' -and $l[0] -ne "`t") { break }
          $parts += $l.Trim()
          $i = $j
        }
        $meta.description = ($parts -join ' ')
      }
      else {
        $meta.description = $val.Trim('"').Trim("'")
      }
    }
  }
  return $meta
}

function Test-SkillName {
  param([string]$Name)
  if ($Name.Length -eq 0 -or $Name.Length -gt 64) { return $false }
  if ($Name -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$') { return $false }
  return $true
}

Write-Host ''
Write-Host "技能根目录：$Root" -ForegroundColor DarkGray
Write-Host ''

foreach ($dir in (Get-ChildItem -Path $Root -Directory | Sort-Object Name)) {
  $skillMd = Join-Path $dir.FullName 'SKILL.md'
  if (-not (Test-Path $skillMd)) { continue }
  $skillCount++

  Write-Host ("[{0}]" -f $dir.Name) -ForegroundColor Cyan

  # --- SKILL.md frontmatter ---
  $meta = Get-Frontmatter -Path $skillMd
  if ($null -eq $meta) {
    Write-Host '  SKILL.md   frontmatter 缺失或未闭合（第一行必须是 ---）' -ForegroundColor Red
    $problems++
  }
  else {
    $errs = @()
    if (-not $meta.name) { $errs += 'name 为空' }
    elseif ($meta.name -ne $dir.Name) { $errs += ("name={0} 必须等于目录名 {1}" -f $meta.name, $dir.Name) }
    elseif (-not (Test-SkillName $meta.name)) { $errs += ("name {0} 字符集不合规（只允许小写字母/数字/连字符）" -f $meta.name) }
    if (-not $meta.description) { $errs += 'description 为空（别的 agent 靠它决定何时加载）' }
    elseif ($meta.description.Length -gt 1024) { $errs += ("description {0} 字，超过上限 1024" -f $meta.description.Length) }

    if ($errs.Count -gt 0) {
      Write-Host ("  SKILL.md   {0}" -f ($errs -join '；')) -ForegroundColor Red
      $problems++
    }
    else {
      Write-Host ("  SKILL.md   ok        name={0}  description={1} 字" -f $meta.name, $meta.description.Length) -ForegroundColor Green
    }
  }

  # --- *.ps1：BOM + 语法 ---
  $scripts = Get-ChildItem -Path $dir.FullName -Recurse -Filter *.ps1 -File
  foreach ($f in $scripts) {
    $scriptCount++
    $rel = $f.FullName.Substring($dir.FullName.Length).TrimStart('\')
    $notes = @()
    $bad = $false

    if (Test-Bom -Path $f.FullName) {
      $notes += 'BOM 在'
    }
    elseif ($CheckOnly) {
      $notes += 'BOM 缺失'
      $bad = $true
    }
    else {
      Add-Bom -Path $f.FullName
      $notes += 'BOM 缺失 → 已补写'
      $fixed++
    }

    $tokens = $null
    $errsParse = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errsParse)
    if ($errsParse -and $errsParse.Count -gt 0) {
      $bad = $true
      $first = $errsParse[0]
      $notes += ("语法错误 {0} 处，首处 行{1}: {2}" -f $errsParse.Count, $first.Extent.StartLineNumber, $first.Message)
    }
    else {
      $notes += '解析 0 错误'
    }

    if ($bad) {
      Write-Host ("  {0,-12} {1}" -f $rel, ($notes -join ' ｜ ')) -ForegroundColor Red
      $problems++
    }
    else {
      $color = if ($notes -match '已补写') { 'Yellow' } else { 'Green' }
      Write-Host ("  {0,-12} {1}" -f $rel, ($notes -join ' ｜ ')) -ForegroundColor $color
    }
  }
  Write-Host ''
}

Write-Host ("汇总：{0} 个技能，{1} 个脚本；BOM 补写 {2}，其余问题 {3}" -f $skillCount, $scriptCount, $fixed, $problems) -ForegroundColor $(if ($problems -gt 0) { 'Red' } else { 'Green' })
if ($problems -gt 0) {
  Write-Host "（-CheckOnly 时不会补 BOM；去掉该开关重跑即可修好 BOM 那一类）" -ForegroundColor DarkGray
  exit 1
}
exit 0
