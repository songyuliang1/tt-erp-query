# tt-erp-query

T100 通用取数技能：查任意表的结构与真实样例、跑任意只读 SQL（多条一次建连）。
表结构取一次就缓存、字段先看后写，不用猜列名、不靠报错试探。

**用法、参数、限制一律看 [SKILL.md](SKILL.md)** —— 技能本体只有那一份，避免两处维护走样。

## 安装

目录名必须等于 `SKILL.md` 里的 `name`（`tt-erp-query`），否则技能不会被加载。

**方式一：clone（推荐，目录天然同名）**

```powershell
git clone https://github.com/songyuliang1/tt-erp-query.git D:\技能库\tt-erp-query
```

**方式二：下 Releases 里的 `tt-erp-query.zip`**，解压即得 `tt-erp-query/` 目录。

> ⚠️ 不要用 GitHub 的 **Code → Download ZIP**：那个包解压出来是 `tt-erp-query-main/`，
> 名字和 `name` 对不上，装了也不会生效。已经下了的话，把目录改名成 `tt-erp-query` 即可：
>
> ```powershell
> Rename-Item .\tt-erp-query-main tt-erp-query
> ```

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

登记后重启 agent 会话即可命中；也可以用 `tt install skills` 把它装到目标目录的 `.agents/` 下。

## 依赖

- `tt` 命令（需要 `tt dict r.t --full` 与 `tt db sql`）。`db sql --batch` 是 0.5.3 之后才加的，
  旧版 tt 会自动退回逐条执行，结果一致、只是慢。
- Windows + PowerShell 5.1 或 7（`pwsh`）；脚本保留 UTF-8 BOM 以兼容 5.1。
- 你自己的 `config.json`（脚本按「从脚本目录逐级向上找 → `TT_CONFIG` → `%APPDATA%\tt\config.json`」定位）。

## 结构

```
tt-erp-query/
├── SKILL.md          # 技能本体：YAML 元数据 + 使用说明
├── scripts/          # ttq.ps1（四个命令）、selfcheck.ps1（BOM/语法/frontmatter 自检）
├── LICENSE           # MIT
└── .gitignore        # 忽略 .cache/ 与 out/
```

## 许可

[MIT](LICENSE)
