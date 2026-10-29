<#
.SYNOPSIS
  通用 ERP 取数：任意表结构一次取全并缓存、看样例数据、任意只读 SQL 一次建连跑完。

.DESCRIPTION
  把「一次建连 + 表结构缓存 + 列名预检」做成通用工具，不绑定任何业务口径：

    env     列出配置里的环境与企业（纯本地，不联网）
    schema  任意表：一次取全字段/主键，落 .cache/<环境>.tables.json；之后 0 次调用
    peek    任意表：按需选列看几行真实数据（认业务含义比读字典快）
    sql     任意一条或多条只读 SQL：写进一个 batch 文件，一次建连跑完

  为什么值得：tt 每次调用要付 进程启动(~60ms) + Oracle 登录(~55ms) 的固定成本；
  逐条问会把这笔钱付很多遍，且列名猜错还要多一轮。这里一律只付一次。

.PARAMETER Command
  env | schema | peek | sql

.PARAMETER Target
  schema: 表名，逗号分隔，如 "pmdl_t,pmdn_t"
  peek  : 单个表名

.PARAMETER Env
  环境名（config.json 的 hosts.sshs[].name），默认 正式。

.PARAMETER Ent
  企业编号。peek/sql 省略时取该环境配置里的第一个 ENT；schema 不需要。

.PARAMETER At
  也可写成 <环境>@<企业>，如 "正式@1000"；给了它就覆盖 Env/Ent。

.PARAMETER Where
  peek 用的过滤条件（SQL 片段，不含 where 关键字），如 "pmdnent=1000"。

.PARAMETER Columns
  peek 要显示的列，逗号分隔；省略则取表结构前 12 列。

.PARAMETER Sql
  sql 命令的语句（单条）。

.PARAMETER File
  sql 命令的 JSON 文件：[{"id":"a","sql":"select ..."}]；也可用 -Sql 传一条。
  文件带 BOM 也能吃（会清洗后重写）。

.PARAMETER Top
  peek 显示行数，默认 5。

.PARAMETER MaxFields
  schema 显示字段上限，默认 60；0 = 全列。

.PARAMETER Match
  schema 只显示字段名/说明匹配该正则的字段。

.PARAMETER Refresh
  schema 强制重取（忽略缓存）。

.PARAMETER Json
  打印原始 JSON 信封。

.EXAMPLE
  ttq.ps1 env

.EXAMPLE
  ttq.ps1 schema "pmdl_t,pmdn_t"

.EXAMPLE
  ttq.ps1 peek pmdn_t -Where "pmdnent=1000" -Top 3

.EXAMPLE
  ttq.ps1 sql "正式@1000" -Sql "select count(*) c from pmdl_t"
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateSet('env', 'schema', 'peek', 'sql')]
  [string]$Command,
  [Parameter(Position = 1)][string]$Target,
  [string]$Env,
  [string]$Ent,
  [string]$At,
  [string]$Where,
  [string]$Columns,
  [string]$Sql,
  [string]$File,
  [int]$Top = 5,
  [int]$MaxFields = 60,
  [string]$Match,
  [switch]$Refresh,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ScriptDir = $PSScriptRoot
$SkillDir = Split-Path -Parent $ScriptDir
$CacheDir = Join-Path $SkillDir '.cache'
$OutDir = Join-Path $SkillDir 'out'
$swTotal = [System.Diagnostics.Stopwatch]::StartNew()

# -At <环境>@<企业> 覆盖 Env/Ent：必须在读 config 之前解析，否则会拿旧环境解析企业。
if ($At) {
  if ($At -match '^(.+?)@(\d+)$') { $Env = $Matches[1]; $Ent = $Matches[2] }
  else { Write-Host "[错误] -At 要写成 <环境>@<企业>，如 正式@1000（收到 '$At'）" -ForegroundColor Red; exit 2 }
}

# sql 的位置参数也可写成 <环境>@<企业> 或 <企业>：同样要在读 config 之前定下环境
if (-not $At -and $Command -eq 'sql' -and $Target) {
  if ($Target -match '^(.+?)@(\d+)$') { $Env = $Matches[1]; $Ent = $Matches[2] }
  elseif ($Target -match '^\d+$') { $Ent = $Target }
}

function Die {
  param([string]$Msg, [int]$Code = 2)
  Write-Host "[错误] $Msg" -ForegroundColor Red
  exit $Code
}

function Convert-JsonEnvelope {
  param([string]$Text)
  $i = $Text.IndexOf('{')
  if ($i -lt 0) { Die "没有拿到 JSON 输出：`n$Text" 4 }
  try { return ($Text.Substring($i) | ConvertFrom-Json) }
  catch { Die "JSON 解析失败：`n$Text" 4 }
}

function Format-Cell {
  param($Value, [int]$Max = 40)
  if ($null -eq $Value) { return '-' }
  $s = [string]$Value
  if ($s.Trim() -eq '') { return '-' }
  if ($s.Length -gt $Max) { return $s.Substring(0, $Max - 1) + '…' }
  return $s
}

function Show-Rows {
  param($Columns, $Rows, [int]$MaxCell = 40)
  $cols = @($Columns)
  if (-not $Rows) { Write-Host '  （0 行）' -ForegroundColor DarkGray; return }
  $widths = @{}
  foreach ($c in $cols) { $widths[$c] = $c.Length }
  foreach ($r in $Rows) {
    for ($i = 0; $i -lt $cols.Count; $i++) {
      $v = Format-Cell $r[$i] $MaxCell
      if ($v.Length -gt $widths[$cols[$i]]) { $widths[$cols[$i]] = $v.Length }
    }
  }
  $hdr = '  '
  foreach ($c in $cols) { $hdr += $c.PadRight([Math]::Min($widths[$c], $MaxCell)) + '  ' }
  Write-Host $hdr.TrimEnd() -ForegroundColor DarkGray
  foreach ($r in $Rows) {
    $line = '  '
    for ($i = 0; $i -lt $cols.Count; $i++) {
      $line += (Format-Cell $r[$i] $MaxCell).PadRight([Math]::Min($widths[$cols[$i]], $MaxCell)) + '  '
    }
    Write-Host $line.TrimEnd()
  }
}

# ---- tt / config ------------------------------------------------------------
# 位置不写死：从脚本目录逐级往上找 tt.exe / config.json，克隆到任意位置都能定位；
# 找不到再退回 TT_EXE / TT_CONFIG 环境变量与 PATH。PowerShell 5.1 与 7 行为一致。
function Find-Upward {
  param([string]$Start, [string]$Name, [int]$MaxDepth = 8)
  $d = $Start
  for ($i = 0; $i -lt $MaxDepth -and $d; $i++) {
    $cand = Join-Path $d $Name
    if (Test-Path $cand) { return $cand }
    $parent = Split-Path -Parent $d
    if (-not $parent -or $parent -eq $d) { break }
    $d = $parent
  }
  return $null
}

$TtExe = $null
if ($env:TT_EXE -and (Test-Path $env:TT_EXE)) { $TtExe = $env:TT_EXE }
if (-not $TtExe) { $TtExe = Find-Upward -Start $ScriptDir -Name 'tt.exe' }
if (-not $TtExe) {
  $cmd = Get-Command tt -ErrorAction SilentlyContinue
  if ($cmd) { $TtExe = $cmd.Source }
}
if (-not $TtExe) { Die '找不到 tt：设置 TT_EXE、把 tt.exe 放到上层目录，或装进 PATH' }

$CfgPath = $null
if ($env:TT_CONFIG -and (Test-Path $env:TT_CONFIG)) { $CfgPath = $env:TT_CONFIG }
if (-not $CfgPath) { $CfgPath = Find-Upward -Start $ScriptDir -Name 'config.json' }
if (-not $CfgPath -and (Test-Path (Join-Path $env:APPDATA 'tt\config.json'))) { $CfgPath = Join-Path $env:APPDATA 'tt\config.json' }
if (-not $CfgPath) { Die '找不到 config.json：设置 TT_CONFIG，或放到上层目录 / %APPDATA%\tt\' }

$cfg = Get-Content -Path $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $Env) { $Env = ($cfg.hosts.sshs | Select-Object -First 1).name; if ($Command -ne 'env') { Write-Host ("（未指定 -Env，用配置里第一个环境：{0}）" -f $Env) -ForegroundColor DarkGray } }
$hostCfg = $cfg.hosts.sshs | Where-Object { $_.name -eq $Env }
if (-not $hostCfg) {
  $names = (($cfg.hosts.sshs | ForEach-Object { $_.name }) -join ', ')
  Die "环境 '$Env' 不在配置里（可用：$names）"
}

# ---- env --------------------------------------------------------------------
if ($Command -eq 'env') {
  foreach ($h in $cfg.hosts.sshs) {
    $ents = (($h.ents | ForEach-Object { "{0}/{1}" -f $_.ent, $_.account }) -join ' ')
    Write-Host ("{0}  ssh={1}  db={2}:{3}/{4}" -f $h.name, $h.host, $h.db.host, $h.db.port, $h.db.service) -ForegroundColor Cyan
    Write-Host ("   ENT: {0}" -f $ents) -ForegroundColor DarkGray
  }
  exit 0
}

# ---- 表结构缓存 -------------------------------------------------------------
function Get-CachePath { return (Join-Path $CacheDir ("{0}.tables.json" -f $Env)) }

function Load-Cache {
  $p = Get-CachePath
  $cache = @{}
  if (Test-Path $p) {
    $obj = Get-Content -Path $p -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($prop in $obj.PSObject.Properties) { $cache[$prop.Name] = $prop.Value }
  }
  return $cache
}

function Save-Cache {
  param($Cache)
  New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
  $json = $Cache | ConvertTo-Json -Depth 8
  [System.IO.File]::WriteAllText((Get-CachePath), $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Convert-TableNode {
  param($Node)
  $fields = @()
  foreach ($f in $Node.'字段') {
    $fields += [pscustomobject]@{
      n   = [string]$f.'字段名'
      d   = [string]$f.'字段说明'
      t   = [string]$f.'数据类型'
      len = [string]$f.'长度'
      req = [string]$f.'必填'
      pk  = [string]$f.'主键'
    }
  }
  $pkeys = @()
  foreach ($k in $Node.'键值') {
    if ([string]$k.'类型' -eq 'P') { $pkeys += [string]$k.'键值字段' }
  }
  return [pscustomobject]@{
    table  = [string]$Node.'表名'
    desc   = [string]$Node.'表说明'
    module = [string]$Node.'模块'
    type   = [string]$Node.'类型'
    fields = $fields
    pkeys  = ($pkeys -join ',')
  }
}

function Ensure-Tables {
  param([string[]]$Tables, [switch]$Force)
  $cache = Load-Cache
  $missing = @()
  foreach ($t in $Tables) {
    $key = $t.ToLower()
    if ($Force -or -not $cache.ContainsKey($key)) { $missing += $key }
  }
  if ($missing.Count -eq 0) { return $cache }

  $list = ($missing -join ',')
  $raw = & $TtExe dict r.t $list --full --env ("local:{0}" -f $Env) --config $CfgPath --format json 2>&1
  $code = $LASTEXITCODE
  if ($code -ne 0) {
    $raw = & $TtExe dict r.t $list --full --env $Env --config $CfgPath --format json 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) { Die "取表结构失败（local 与在线都试过）：`n$($raw -join "`n")" 4 }
  }
  $env2 = Convert-JsonEnvelope (($raw -join "`n"))
  foreach ($node in $env2.data) {
    $node2 = Convert-TableNode $node
    $cache[$node2.table.ToLower()] = $node2
  }
  Save-Cache $cache
  return $cache
}

function Resolve-EntCode {
  param([string]$Explicit)
  if ($Explicit) { return $Explicit }
  $first = $hostCfg.ents | Select-Object -First 1
  if (-not $first) { Die "环境 $Env 没有配置任何 ENT" 2 }
  return [string]$first.ent
}

# ---- At / Ent ---------------------------------------------------------------
# （-At 已在脚本开头解析，这里只做兜底说明）

function New-BatchFile {
  param([object[]]$Statements, [string]$Name)
  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
  $path = Join-Path $OutDir $Name
  $parts = @()
  foreach ($s in $Statements) { $parts += ($s | ConvertTo-Json -Compress) }
  [System.IO.File]::WriteAllText($path, ('[' + ($parts -join ',') + ']'), (New-Object System.Text.UTF8Encoding($false)))
  return $path
}

# tt 0.5.3 及更早没有 db sql --batch（该参数在 0.5.3 之后才加）。
# 为了在旧版 tt 上也能用，这里探测一次：不支持就退回逐条执行 —— 结果一样，
# 只是每条多付一次进程启动与登录，所以只在必要时走这条路。
$script:BatchUnsupported = $false

function Invoke-TtSingle {
  param([string]$EntCode, [string]$Statement, [string]$Id)
  $raw = & $TtExe db sql --at ("{0}@{1}" -f $Env, $EntCode) --config $CfgPath $Statement 2>&1
  $text = ($raw -join "`n")
  $env2 = $null
  try { $env2 = Convert-JsonEnvelope $text } catch { $env2 = $null }
  if ($null -eq $env2) {
    return [pscustomobject]@{ id = $Id; ok = $false; code = 'NO_JSON'; error = $text; columns = @(); rows = @(); totalRows = 0 }
  }
  $cols = @(); if ($env2.data -and $env2.data.columns) { $cols = @($env2.data.columns) }
  $rows = @(); if ($env2.data -and $env2.data.rows) { $rows = @($env2.data.rows) }
  return [pscustomobject]@{
    id = $Id; ok = [bool]$env2.ok; code = $env2.code; error = $env2.error
    columns = $cols; rows = $rows; totalRows = $(if ($null -ne $env2.totalRows) { $env2.totalRows } else { $rows.Count })
  }
}

function Invoke-TtFallback {
  param([string]$EntCode, [object[]]$Statements)
  $items = @()
  foreach ($s in $Statements) { $items += (Invoke-TtSingle -EntCode $EntCode -Statement $s.sql -Id $s.id) }
  return [pscustomobject]@{ data = [pscustomobject]@{ items = $items; failed = @($items | Where-Object { -not $_.ok }).Count } }
}

function Invoke-TtBatch {
  param([string]$EntCode, [object[]]$Statements, [string]$Name)
  if ($script:BatchUnsupported) { return (Invoke-TtFallback -EntCode $EntCode -Statements $Statements) }

  $file = New-BatchFile -Statements $Statements -Name $Name
  $raw = & $TtExe db sql --at ("{0}@{1}" -f $Env, $EntCode) --batch $file --config $CfgPath 2>&1
  $code = $LASTEXITCODE
  $text = ($raw -join "`n")
  if ($code -ne 0) {
    if ($text -match 'unknown flag:\s*--batch') {
      $script:BatchUnsupported = $true
      Write-Host '（当前 tt 不支持 db sql --batch，退回逐条执行：结果相同，但每条多付一次登录）' -ForegroundColor DarkGray
      return (Invoke-TtFallback -EntCode $EntCode -Statements $Statements)
    }
    Die "查询失败（exit $code）：`n$text" 4
  }
  return (Convert-JsonEnvelope $text)
}

# ---- schema -----------------------------------------------------------------
if ($Command -eq 'schema') {
  if (-not $Target) { Die 'schema 需要表名，如 ttq.ps1 schema "pmdl_t,pmdn_t"' 2 }
  $tables = @($Target -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $swFetch = [System.Diagnostics.Stopwatch]::StartNew()
  $had = @{}
  foreach ($t in $tables) { $had[$t.ToLower()] = (Test-Path (Get-CachePath)) -and (Load-Cache).ContainsKey($t.ToLower()) }
  $cache = Ensure-Tables -Tables $tables -Force:$Refresh
  $swFetch.Stop()

  if ($Json) {
    $out = @{}
    foreach ($t in $tables) { $out[$t.ToLower()] = $cache[$t.ToLower()] }
    $out | ConvertTo-Json -Depth 8
    exit 0
  }

  foreach ($t in $tables) {
    $key = $t.ToLower()
    if (-not $cache.ContainsKey($key)) { Write-Host ("[{0}] 缓存里没有这张表（表名可能拼错，用 tt dict r.t --kw <业务词> 找）" -f $t) -ForegroundColor Red; continue }
    $info = $cache[$key]
    Write-Host ''
    Write-Host ("{0}  {1}  [{2} / {3}]  {4} 字段  主键 {5}" -f $info.table, $info.desc, $info.module, $info.type, $info.fields.Count, $(if ($info.pkeys) { $info.pkeys } else { '-' })) -ForegroundColor Cyan
    $fields = @($info.fields)
    if ($Match) { $fields = @($fields | Where-Object { $_.n -match $Match -or $_.d -match $Match }) }
    if ($MaxFields -gt 0 -and $fields.Count -gt $MaxFields) {
      $fields = @($fields | Select-Object -First $MaxFields)
      $more = '（已截断，-MaxFields 0 看全列）'
    }
    else { $more = '' }
    $w = 26
    foreach ($f in $fields) { if ($f.n.Length -gt $w) { $w = $f.n.Length } }
    foreach ($f in $fields) {
      $flag = if ($f.pk -eq 'Y') { 'PK' } elseif ($f.req -eq 'Y') { '必填' } else { '' }
      Write-Host ('  {0}  {1,-10} {2,-7} {3,-4} {4}' -f $f.n.PadRight($w), $f.t, $f.len, $flag, $f.d)
    }
    if ($more) { Write-Host ("  {0}" -f $more) -ForegroundColor DarkGray }
    $hit = $had[$key]
    Write-Host ("  来源：{0}" -f $(if ($hit -and -not $Refresh) { '缓存' } else { '本次新取' })) -ForegroundColor DarkGray
  }
  $swTotal.Stop()
  Write-Host ''
  Write-Host ("用时 {0:N0} ms（取结构 {1:N0} ms，{2} 张表）" -f $swTotal.ElapsedMilliseconds, $swFetch.ElapsedMilliseconds, $tables.Count) -ForegroundColor DarkGray
  exit 0
}

# ---- peek -------------------------------------------------------------------
if ($Command -eq 'peek') {
  if (-not $Target) { Die 'peek 需要表名，如 ttq.ps1 peek pmdn_t -Top 3' 2 }
  $table = $Target.Trim()
  $cache = Ensure-Tables -Tables @($table)
  $key = $table.ToLower()
  if (-not $cache.ContainsKey($key)) { Die "表 $table 不在字典里（表名拼错？用 tt dict r.t --kw <业务词> 找）" 4 }
  $info = $cache[$key]

  if ($Columns) { $cols = @($Columns -split ',' | ForEach-Object { $_.Trim() }) }
  else {
    $cols = @($info.fields | Select-Object -First 12 | ForEach-Object { $_.n })
    if ($info.pkeys) {
      foreach ($pk in ($info.pkeys -split ',')) {
        $pk = $pk.Trim()
        if ($pk -and ($cols -notcontains $pk)) { $cols = @($pk) + $cols }
      }
    }
  }

  $entCode = Resolve-EntCode $Ent
  $sql = "select $($cols -join ',') from $table"
  if ($Where) { $sql = "select * from ($sql where $Where) where rownum <= $Top" }
  else { $sql = "select * from ($sql) where rownum <= $Top" }

  $res = Invoke-TtBatch -EntCode $entCode -Statements @(@{ id = 'peek'; sql = $sql }) -Name ('peek-{0}-{1}.json' -f $table, (Get-Date -Format 'HHmmss'))
  if ($Json) { $res | ConvertTo-Json -Depth 8; exit 0 }

  $it = $res.data.items[0]
  Write-Host ''
  Write-Host ("{0}  {1}   [ENT {2}]" -f $table, $info.desc, $entCode) -ForegroundColor Cyan
  if (-not $it.ok) { Die ("SQL 被拒：{0}" -f $it.error) 4 }
  Show-Rows -Columns $it.columns -Rows $it.rows
  $swTotal.Stop()
  Write-Host ("用时 {0:N0} ms ｜ 列：{1}" -f $swTotal.ElapsedMilliseconds, ($cols -join ',')) -ForegroundColor DarkGray
  exit 0
}

# ---- sql --------------------------------------------------------------------
if ($Command -eq 'sql') {
  if (-not $Sql -and -not $File) { Die 'sql 需要 -Sql "select ..." 或 -File q.json' 2 }
  # 目标也可写在第二个位置参数上：ttq sql "正式@1000" / ttq sql 1000
  if (-not $At -and $Target) {
    if ($Target -match '^(.+?)@(\d+)$') { $Env = $Matches[1]; $Ent = $Matches[2] }
    elseif ($Target -match '^\d+$') { $Ent = $Target }
    else { Die "sql 的第二个位置参数要写成 <环境>@<企业> 或 <企业>（收到 '$Target'）" 2 }
  }
  $stmts = @()
  if ($File) {
    if (-not (Test-Path $File)) { Die "文件不存在：$File" 2 }
    $text = ([System.IO.File]::ReadAllText((Resolve-Path $File).Path)) -replace "^\uFEFF", ''
    $i = $text.IndexOf('[')
    if ($i -lt 0) { Die '-File 要是 JSON 数组：[{"sql":"select ..."}, ...]' 2 }
    try { $arr = $text.Substring($i) | ConvertFrom-Json }
    catch { Die "批量文件 JSON 解析失败：$File" 2 }
    $n = 0
    foreach ($s in @($arr)) {
      $n++
      $stmts += @{ id = $(if ($s.id) { [string]$s.id } else { [string]$n }); sql = [string]$s.sql }
    }
  }
  else {
    $stmts += @{ id = 'q1'; sql = $Sql }
  }

  $entCode = Resolve-EntCode $Ent
  $swQ = [System.Diagnostics.Stopwatch]::StartNew()
  $res = Invoke-TtBatch -EntCode $entCode -Statements $stmts -Name ('sql-{0}.json' -f (Get-Date -Format 'HHmmss'))
  $swQ.Stop()

  if ($Json) { $res | ConvertTo-Json -Depth 8; exit 0 }

  $modeLabel = if ($script:BatchUnsupported) { '逐条执行（tt 不支持 --batch）' } else { '1 次建连' }
  Write-Host ("{0}@{1} ｜ {2} 条语句 / {3}" -f $Env, $entCode, $stmts.Count, $modeLabel) -ForegroundColor Cyan
  foreach ($it in $res.data.items) {
    Write-Host ''
    if (-not $it.ok) {
      Write-Host ("[{0}] 失败：{1} {2}" -f $it.id, $it.code, $it.error) -ForegroundColor Red
      continue
    }
    Write-Host ("[{0}] {1} 行" -f $it.id, $it.totalRows) -ForegroundColor Yellow
    Show-Rows -Columns $it.columns -Rows $it.rows
  }
  $swTotal.Stop()
  Write-Host ''
  Write-Host ("用时 {0:N0} ms（SQL {1:N0} ms）" -f $swTotal.ElapsedMilliseconds, $swQ.ElapsedMilliseconds) -ForegroundColor DarkGray
  exit 0
}
