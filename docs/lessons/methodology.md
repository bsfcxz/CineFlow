# 工作方法与工具链陷阱

> 写法：一行现象 → 一行根因 → 一行对策。全部来自本仓库的实际执行记录。

## 1. 工具链陷阱（Windows / PowerShell / 沙箱）

| 现象 | 根因 | 对策 |
|---|---|---|
| `bash` 报 `fatal error - NtCreateDirectoryObject(\BaseNamedObjects\msys-2.0S5-...): 0xC0000022` | msys 运行时被沙箱拒绝创建命名对象；**所有 `.sh` 脚本都跑不了** | 门禁改用 PowerShell（`scripts/*.ps1`）。不要反复重试 bash，也不要以为"脚本写错了" |
| `.ps1` 含中文时报一堆语法错误，且报错行号指向中文行的**下一行** | 文件被按 GBK 解码，中文字节把换行吃掉了 | 脚本必须存成 **UTF-8 with BOM**。用编辑工具改完 `.ps1` 后**确认 BOM 还在**（`[IO.File]::ReadAllBytes($p)` 前三字节是 `EF BB BF`） |
| `[System.IO.File]::ReadAllText('lib/x.dart')` 报 `DirectoryNotFoundException` | .NET 静态方法按**进程工作目录**解析相对路径，不跟随 PowerShell 的 `cd` | 一律用绝对路径，或直接用文件读写工具 |
| `Get-Content` 数出的行数比实际少 | 源码是 **LF** 行尾，PowerShell 少算（实测 README 报 79 实际 117） | 用 `[System.IO.File]::ReadAllLines($p).Count` 或 `grep` 的行号 |
| PowerShell 里 `curl`/`Invoke-WebRequest` 全部失败（连 baidu 都连不上），报 `schannel: AcquireCredentialsHandle failed` | 沙箱对子进程 TLS 的限制 | 不要据此判定"没网"。用 `python`（本机 python 有网）或 `web_fetch` 类工具验证；`git` 走本地代理 `http://127.0.0.1:7897` 可通 |
| `git ls-remote` 报 `could not read Username for 'https://github.com'` | 没配代理时连不上；配上代理后凭据由 GCM 提供 | `git config http.proxy http://127.0.0.1:7897`；凭据在 Git Credential Manager 里（`git-credential-manager get` 可取） |

## 2. 假绿与假解释

- **恒绿的门禁等于没有门禁**：`check-secrets.ps1` 写完必须**反向注入**——塞一个假凭据文件进暂存区，
  确认它变红并报出行号，删掉后转绿。实测时还发现原正则**不允许值被引号包裹**，
  `api_key = "AKIA..."` 这种最常见写法扫不出来 → 已修。
- **"应该是环境问题"是甩锅**：本仓库的真实教训是 `flutter analyze` 退出码 1 被误判为"构建失败"，
  实际只是 3 条 info。**判定标准看输出文本，不看退出码**。
- **测试数量不要手抄**：文档里写"26 例"而实际是 25 例（`sort_and_prefs_test.dart` 是 8 例不是 9 例）。
  写数量前先跑一次 `flutter test`，或干脆不写具体数字。

## 3. 上下文与文档纪律

- **缺陷台账的删除线是语义**：`~~7.8~~` 表示**已修复**，没划掉的才是待办。
  只看编号不看删除线，会把已修好的当待办，或把缺口当已完成。
- **不要整仓读**：`lib/player/player_page.dart`（~1500 行）与 `lib/pages/detail_page.dart`（~34KB）
  先定位方法名再读区间；`build/` 与 `tool/icon/_gen/` 永远不要当上下文（后者是 256 个 Edge 缓存文件）。
- **文档不得比代码乐观**：README 曾宣称"自动重连""6h/24h 缓存"，代码里都没有（缺陷 7.10）。
  写"已实现"之前先 grep 代码确认。

## 4. 引用开源前必核（且要连许可一起看）

- 凭记忆写仓库名 = 违规：实测抓到 `go-flutter/go-flutter`(404)、`moonfin/moonfin`(404) 等。
- **星高 ≠ 能抄**：核查过的多款高星同类播放器实为 **GPL-3.0** 或
  **NOASSERTION**（无明确许可）——都只能借鉴思路，**不能合并源码**。
- 核实用 `python scripts/discover_oss.py --verify owner/repo`（未设 token 会撞限速，设 `GITHUB_TOKEN` 更稳）。

## 5. 变更日志

| 版本 | 日期 | 变更 |
|---|---|---|
| v1.0 | 2026-10-04 | 初始版本：工具链陷阱（bash 沙箱 / ps1 BOM / .NET 路径 / 行尾 / 网络）、假绿与假解释、上下文纪律、开源引用许可 |
