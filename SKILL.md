---
name: tt-erp-query
description: T100 通用取数技能：查任意表的结构与真实样例、跑任意只读 SQL（多条一次建连）。表结构取一次就缓存、字段先看后写，不用猜列名、不靠报错试探。触发词：取数、查表、表结构、字段是什么意思、这个单号在哪张表、跑条 SQL、批量查数。
---

# ERP 通用取数（任意表 / 任意只读 SQL）

面向「要查的数据在哪张表、这张表字段是什么、这条 SQL 跑出来对不对」这类问题。
不绑定任何业务口径 —— 库存、采购、应收、BOM 都一样处理。

核心只有两句：

- **表结构只取一次**（进 `.cache/`，之后零调用），并用它做列名预检
- **SQL 合进一个 batch 文件**，`tt db sql --batch` **只建一次连**

这把每次取数的固定开销（进程启动 ~60 ms + Oracle 登录 ~55 ms）从「每条付一次」
变成「每轮付一次」。

> 路径约定：仓库里脚本在 `skills/tt-erp-query/scripts/`；装到 agent 目录后是
> `<技能目录>/scripts/`。下文一律写 `<技能目录>`。

下文示例用 Windows PowerShell 5.1 的 `powershell`；PowerShell 7 用户把命令里的 `powershell` 换成 `pwsh` 即可（参数一致）。

## 四个命令

```powershell
# 0) 环境与企业（纯本地，不联网）
powershell -NoProfile -File <技能目录>/scripts/ttq.ps1 env

# 1) 找表：按业务词搜本地字典（47 ms 级）
tt dict r.t --kw 采购单 --env local:正式 --format table

# 2) 看结构：任意表一次取全字段 + 主键，进缓存
powershell -NoProfile -File <技能目录>/scripts/ttq.ps1 schema "pmdl_t,pmdn_t"
powershell -NoProfile -File <技能目录>/scripts/ttq.ps1 schema pmdn_t -Match "数量|单价"   # 零网络
powershell -NoProfile -File <技能目录>/scripts/ttq.ps1 schema pmdn_t -MaxFields 0          # 全列

# 3) 看样例：从真实数据认字段含义（比读字典快）
powershell -NoProfile -File <技能目录>/scripts/ttq.ps1 peek pmdn_t -Ent <企业> -Top 3 `
  -Columns "pmdndocno,pmdn001,pmdn007"

# 4) 一次建连跑完（单条 / 多条）
powershell -NoProfile -File <技能目录>/scripts/ttq.ps1 sql "正式@<企业>" -Sql "select count(*) c from pmdl_t"
powershell -NoProfile -File <技能目录>/scripts/ttq.ps1 sql "正式@<企业>" -File q.json
```

## 顺序比技巧重要

新口径先问「有没有」再问「长什么样」。一个 batch 同时回答「表里有没有数据、
有没有我要的那条、在哪个企业」，比逐条试少两轮：

```json
[{"id":"total","sql":"select count(*) c from pmdl_t"},
 {"id":"target","sql":"select count(*) c from pmdn_t where pmdn001='ABC12345'"},
 {"id":"ents","sql":"select pmdnent,count(*) c from pmdn_t where pmdn001='ABC12345' group by pmdnent"}]
```

三条一起跑 ≈ 0.36 s；逐条问要付三次登录，还要多两轮对话。

## 实测（正式环境，单表约 28 万行）

| 动作 | 内部 | 墙钟 |
|---|---:|---:|
| `ttq env`（纯本地） | ~30 ms | ~300 ms |
| `ttq schema` 2 张表（首次取结构） | 249 ms | 539 ms |
| `ttq schema` 命中缓存 + `-Match` | 175 ms | 493 ms |
| `ttq sql` 1 条 | 304 ms | 588 ms |
| `ttq sql` 4 条一次建连 | 362 ms | 625 ms |
| `ttq peek` 2 行 | 568 ms | — |

墙钟多出的 ~300 ms 是 `powershell.exe` 进程启动，不是查询。

## 自检（改完脚本必跑）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <技能目录>/scripts/selfcheck.ps1
```

- `*.ps1` 缺 UTF-8 BOM 就补上（PowerShell 5.1 没有 BOM 会按 ANSI 解码，中文变乱码、直接语法错；7 两种都行，保留 BOM 是为了 5.1 也能跑）
- 用 `[Parser]::ParseFile` 解析每个脚本，报行号列号
- 校验同级技能目录的 `SKILL.md`：`name` 等于目录名、字符集合规、`description` 非空且 ≤1024 字

`-CheckOnly` 只报不补（`make skill-check` 就是它）。退出码：`0` 干净 / `1` 有问题 / `2` 根目录不存在。

## 参数

| 参数 | 说明 |
|---|---|
| `Command` | `env` / `schema` / `peek` / `sql` |
| `Target` | schema 用表名（逗号分隔）；peek 用表名；sql 可用 `<环境>@<企业>` 或 `<企业>` |
| `-Env` | 环境名；省略时用 config 里第一个环境并回显 |
| `-Ent` / `-At` | 企业编号 / `<环境>@<企业>` |
| `-Where` | peek 的过滤条件（不含 where 关键字） |
| `-Columns` | peek 显示的列，默认表结构前 12 列 + 主键 |
| `-Top` | peek 行数，默认 5 |
| `-MaxFields` | schema 显示字段上限，默认 60；0 = 全列 |
| `-Match` | schema 只显示字段名/说明匹配该正则的字段 |
| `-Refresh` | 强制重取表结构 |
| `-Json` | 打印原始 JSON 信封 |

## 限制（别拿它当万能的）

- **一个连接只看得到一个 schema**：多公司按账号分成多个 schema，`where ent in (...)` 跨不过去，
  而且**不报错、静默少行**。跨账号要多次建连，也不能跨 schema join。
- **报表口径不等于表口径**：成本、期间结算在程序里，直查表未必与界面数字一致；
  要对数就先找到那个作业的 SQL。
- **业务过滤在代码里**：状态、有效日期、据点/资料权限等条件程序里才加，直查会多算。
- **大表聚合照样慢**：本技能只省往返，不省扫描；先用索引列（ent/单号/料号/日期）落范围。
- **只读**：写语句会被 `tt db sql` 的只读闸门拒绝。
- **旧版 tt**：没有 `db sql --batch` 时自动退回逐条执行，结果相同、速度慢（约 1.4 s/条）。
- **Windows + PowerShell**：PowerShell 5.1 与 7（`pwsh`）都能跑；脚本保留 UTF-8 BOM —— 5.1 必需，7 兼容。Linux/macOS 不支持。

## 缓存与产物

- 表结构：`.cache/<环境>.tables.json`（按表名累积，取过一次就不再取）
- batch 文件与结果：`out/`

两者都在 `.gitignore` 内。表结构变动（打 patch、加字段）后加 `-Refresh` 重取。
