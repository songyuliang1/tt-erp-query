# tt-erp-query

T100 通用取数技能：查任意表的结构与真实样例、跑任意只读 SQL（多条一次建连）。
表结构取一次就缓存、字段先看后写，不用猜列名、不靠报错试探。

## 安装

```powershell
git clone https://github.com/songyuliang1/tt-erp-query.git D:\技能库\tt-erp-query
```

在 `tt` 的 `config.json` 里登记本地路径：

```json
{
  "skills": {
    "externals": [
      { "path": "D:\\技能库\\tt-erp-query", "label": "tt-erp-query" }
    ]
  }
}
```

登记后重启 agent 会话即可命中；也可用 `tt install skills` 把它装到目标目录的 `.agents/` 下。

## 依赖

- `tt` 命令（需要 `tt dict r.t --full` 与 `tt db sql`）。
  `db sql --batch`（一次建连跑多条）是 0.5.3 之后才加的；旧版 tt 会自动退回逐条执行，
  结果相同，只是每条多付一次登录（约 1.4 s/条，而不是 0.3 s/条）。
- Windows PowerShell 5.1
- 用户自己的 `tt` 配置：`config.json`（脚本按「仓库根 → `TT_CONFIG` → `%APPDATA%\tt\config.json`」找）

## 四个命令

```powershell
powershell -NoProfile -File .\scripts\ttq.ps1 env                                  # 环境与企业（纯本地）
powershell -NoProfile -File .\scripts\ttq.ps1 schema "pmdl_t,pmdn_t"                # 表结构一次取全并缓存
powershell -NoProfile -File .\scripts\ttq.ps1 schema pmdn_t -Match "数量|单价"       # 只筛相关字段（零网络）
powershell -NoProfile -File .\scripts\ttq.ps1 peek pmdn_t -Ent <企业> -Top 3        # 看几行真实数据
powershell -NoProfile -File .\scripts\ttq.ps1 sql "正式@<企业>" -Sql "select ..."   # 单条
powershell -NoProfile -File .\scripts\ttq.ps1 sql "正式@<企业>" -File q.json        # 多条，一次建连
```

`-Env` 省略时用 config 里第一个环境，并在输出里回显。

## 自检

脚本是 PowerShell 5.1 + UTF-8 BOM：没有 BOM 会被按 ANSI 解码，中文变乱码、直接语法错。
改完脚本跑一次：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\selfcheck.ps1
```

它会补 BOM、用解析器检查语法、并校验 `SKILL.md` 的 frontmatter。`-CheckOnly` 只报不补。

## 限制

- **一个连接只看得到一个 schema**：多公司按账号分 schema，`where ent in (...)` 跨不过去且**静默少行**。
- **报表口径不等于表口径**：成本、期间结算在程序里，直链表未必与界面一致。
- **大表聚合照样慢**：本技能只省往返，不省扫描。
- **只读**：写语句会被 `tt db sql` 的只读闸门拒绝。
