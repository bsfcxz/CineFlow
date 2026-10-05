# 变更日志

> 写法见 [docs/CHANGELOG-GUIDE.md](docs/CHANGELOG-GUIDE.md)。
> 版本号唯一权威是仓库根 [VERSION](VERSION)；本文件最新条目必须与它一致。
> 历史行只增不改。
>
> **用户向的发布说明在 [docs/changelog/](docs/changelog/README.md)（每版一份），
> 那里的内容会被自动同步为 GitHub Release 正文**——本文件是开发视角的累计历史。

## v0.2.0：断网时不再骗你「片库是空的」

发布说明见 [docs/changelog/v0.2.0.md](docs/changelog/v0.2.0.md)（也是 Release 正文）。要点：

- 首次公开开源发布，采用 **Apache-2.0** 许可
- 修掉「加载失败被伪装成空库/空首页」（§7.8 / §7.9）与「导演被全部丢弃」（§7.14）
- 起播即上报进度（§7.1）、排序方向（§7.2）与默认倍速写入（§7.5）
- **版本号收敛为单一来源**（§7.17）：`lib/core/version.dart` + `tool/bump_version.ps1` 强制校验
- 建立发布体系：`docs/changelog/`、CI、Release 工作流、Issue/PR 模板
- 顺带并入桌面 `CineFlow/` 规划仓库里仍成立的工程资产，并把文档改回与代码一致

## v0.2.0（开发视角细则）

以下为上一节的开发视角补充，保留原「规划仓库并入」条目内容。

## v0.2.0：规划仓库并入 + 文档与代码对齐

本版把桌面 `CineFlow/` 规划仓库里**仍然成立**的工程资产并入本仓库（门禁脚本、
ADR、文档工作流、开源核实清单），并顺手把文档里比代码乐观的说法改回事实。
功能代码无行为变化——这一版是"让规范能落地、让文档说实话"。

> ⚠️ **需要你动手**：门禁脚本从 `.sh` 换成 `.ps1`（本机 bash 在沙箱下不可执行）。
> 如果你之前记的是 `bash scripts/check-docs.sh`，改用
> `powershell -File scripts/check-docs.ps1`。日常开发不受影响。

### 本版亮点

#### 规划仓库并入，但只并入"还成立"的部分

桌面 `CineFlow/` 是一套按「Flutter + Go 内嵌服务 + libmpv」写的规范，而本仓库实际走的是
**纯 Dart MVP**（无任何 Go 代码）。所以并入时做了取舍：

- **并入**：门禁脚本、工程文档与模板、
  ADR 体系、文档更新流程、踩坑索引、变更日志写法、提示词模板
- **不并入**：桥接/FFI 相关的一切、115 网盘预留层、Go 工具链门禁
- **改写**：凡是假设"有 Go 层"的条文（门禁命令、角色表、目录地图）都按本仓库实情重写

新增 [ADR 0002](docs/decisions/0002-pure-dart-mvp.md) 把"为什么放弃 Go 桥接"记成正式决策，
原 [ADR 0001](docs/decisions/0001-flutter-go-libmpv-stack.md) 保留并标注"已废弃"——
以后不用再重新吵一遍。

#### 门禁脚本现在真的能跑

原来的门禁是 `.sh`，本机 bash 被沙箱拒绝（`msys NtCreateDirectoryObject 0xC0000022`），
等于**门禁从未真正执行过**。现改为 PowerShell 版并实测：

- `scripts/check-secrets.ps1`——敏感信息扫描（**反向注入验证过：塞入假凭据会红并报行号，删除后转绿**）
- `scripts/check-docs.ps1`——必需文档齐全 + Markdown 断链检查
- `scripts/secrets-allow.txt`——**逐行**白名单（`路径 :: 片段` + 理由）。用行级而非文件级，
  是为了让被放行的文件其余行仍受扫描；当前仅放行 `docs/lessons/methodology.md` 里的
  本机回环地址 `127.0.0.1:7897`（记录工具链踩坑时必然出现，不指向任何用户服务器）

顺带修掉两个真实漏检/误报：

- 原正则不允许值被引号包裹，`api_key = "AKIA..."` 这种最常见写法**扫不出来**（已修，并实测确认）
- 白名单文件自身会自命中 → 作为控制文件排除，并在输出里明示"另有 N 处被白名单放行"（不静默）

#### 文档不再比代码乐观

- 新增 `docs/architecture.md`，按**实际代码**描述分层与 `MediaProvider` 契约
  （旧的写的是 Go 服务层 + 桥接 proto + 115 预留，与代码完全不符）
- 新增 `docs/task-board.md`，按真实进度重建；已作废的卡片（Go module、桥接 Hello World、
  `Pan115Provider`）移入"取消"区并写明原因
- 完成第三方依赖许可核查：GPL / 无明确许可的第三方项目一律只借鉴思路，
  不合并源码

### 其他改进

- `docs/` 新增：`UPDATE-WORKFLOW.md`、`review-checklist.md`、`TECH-SKILLS.md`、
  `decisions/`（ADR 索引 + 0001 + 0002）、`lessons/`（踩坑索引）
  共 8 篇 reference，全部按本仓库实测结论撰写
- `.gitignore` 补 `.env` / `*.local` / `*.key` 等凭据文件忽略规则（原来没有）
- `scripts/discover_oss.py`：GitHub 开源发现与核实工具（仅标准库）

### 修好了

- 恢复误删的 `ACKNOWLEDGEMENTS.md`（README 一直在引用它，链接是断的）

### 升级须知

- **版本号**：`VERSION` 从 `0.1.0` 升到 `0.2.0`（文档与规范体系成型）。
  注意 `pubspec.yaml` 仍是 `1.0.0+1`，`EmbyProvider.clientVersion` 仍是 `0.1.0`——
  **这三处不一致是已知缺陷（AGENTS.md §7.17）**，本版未修，需要单独一张卡。
- **已知限制**（未变）：release 用 debug 签名（§7.16）、无 WakeLock（§7.11）、
  无 401 自愈（§7.7）、类型/年份筛选仅客户端（§7.15）、豆瓣缓存 TTL 未生效（§7.4）。
- 无数据库迁移，无破坏性变更。

## v0.1.1：媒体库与首页的失败不再伪装成空

修复三个"点了没反应 / 看不到错"型缺陷，并补齐单测。

- **媒体库**：加载失败不再显示「该库暂无内容」，改为错误页 + 重试（缺陷 7.8）
- **首页**：四个区块各自降级；全失败时报错而不是渲染空首页（缺陷 7.9）
- **详情页**：新增导演摘要行——旧实现把 14 条导演数据全部静默丢弃（缺陷 7.14）
- 测试从 10 例增加到 25 例；恢复误删的 `ACKNOWLEDGEMENTS.md`

## v0.1.0：首个可用版本

- Emby 第三方客户端：多服务器登录、媒体库、详情、播放器（media_kit/libmpv）、
  排行榜与搜索（豆瓣公开接口）、我的页面
- 阶段三：`Sessions/Playing` 起始上报、多版本媒体源选择
- 阶段四：媒体库排序修复（含 `SortOrder` 硬编码）、默认倍速读写闭环
