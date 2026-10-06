# 开发所需技能与实现方式（含 GitHub 开源借鉴）

> 这一章回答两个问题：**CineFlow 要做的事分别需要什么技能**，**每一块去哪借鉴现成实现**。
> 原则：**先查开源再动手**——能抄的契约/脚手架不重复造；抄之前先读它的坑（README、issues、AGENTS.md）。
> 每条都标注「借鉴什么」与「我们不能照抄什么」。版本会过期，以链接指向的仓库当前状态为准。
>
> **引用纪律（2026-10-04 起）：**
> 1. 写任何仓库名之前先 `python scripts/discover_oss.py --verify <owner/repo>`——凭记忆写是违规
>    （首次核实即抓到 2 个 404、1 个 0 star、1 个 1 star）
> 2. 每个引用都要带 **stars / 最近提交 / 许可**；许可边界见 [`docs/OSS-SOURCES.md`](OSS-SOURCES.md)
> 3. **GPL / AGPL 项目：只借鉴架构与流程，禁止合并源码**（本项目许可尚未定，这是不可逆决定）

## 0. 技能全景

| # | 技能 | 干什么 | 实现方式 | 主要开源借鉴 |
|---|---|---|---|---|
| S1 | Emby 客户端协议 | 认证/媒体库/详情/进度/图片 | Dart + dio，`EmbyProvider` 实现 `MediaProvider`；防御式解析 | LinPlayer（踩坑语料）、plezy（排序参数）、jellyfin-web（参数语义） |
| S2 | 播放内核 | 播放、字幕、音轨、手势 | media_kit（libmpv）封装在 `lib/player/`；参数走 mpv option | media-kit/media-kit、mpv-player/mpv、Themby |
| S3 | 数据与安全 | 凭据、偏好、历史 | `flutter_secure_storage`（Android Keystore）；键值对，不引 ORM | 见 §S3 |
| S4 | 状态与导航 | 会话、派生数据、路由 | riverpod 3.x（AsyncNotifier + Provider）；Navigator（不引 go_router） | 见 §S4 |
| S5 | 豆瓣数据源 | 榜单、热门、详情、图床 | rexxar 公开接口 + dio 双头；`DoubanImage` 破防盗链 | 见 §S5 |
| S6 | 降级与错误呈现 | 失败不伪装成空 | 单区块降级 + 全失败报错 + 重试 | 本仓库缺陷 7.8/7.9 的回归线 |
| S7 | 弹幕（未启动） | 匹配 + 渲染 | 弹弹play v2（或自建）+ 生成 ASS/libass | Tony15246/uosc_danmaku、huangxd-/danmu_api |
| S8 | 测试与门禁 | 假绿防护 | 反向注入 + PowerShell 门禁脚本 | 见 `cineflow-workflow/references/gates.md` |
| S9 | 构建与发版 | 打包、版本号、变更日志 | `tool/build_apk.sh`（`--split-per-abi` + `--obfuscate`）；`VERSION` 唯一权威 | 见 `docs/CHANGELOG-GUIDE.md` |
| S10 | 开源发现与核实 | 不会就查谁做过 | `scripts/discover_oss.py` 搜索 + `--verify` 核实 + 入表 | 技能 `cineflow-oss-search`；注册表 `docs/OSS-SOURCES.md` |

> 本仓库**没有** Flutter↔Go 桥接、没有 Protobuf over FFI、没有 115 网盘实现。
> 那些是计划书的原始设想，已由 [ADR 0002](decisions/0002-pure-dart-mvp.md) 否决——
> **除非用户明确要求，不要引入**。

---

## S1 · Emby 客户端协议（最关键的一块）

### 实现方式

- 认证：`POST /Users/AuthenticateByName` → `AccessToken` + `User.Id`；认证头四段（Client/Device/DeviceId/**Version**）缺一不可
- 媒体库：`/Users/{uid}/Items` 带 `StartIndex`/`Limit`/`Recursive`；**`SortBy`/`SortOrder` 必须显式给方向**
- 图片：`imageUrl()` 由 `item.ImageTags.Primary` 拼 `maxWidth`/`maxHeight`
- 播放：`PlaybackInfo` → `MediaSources[]`（**始终返回全部**，客户端按 id 复选）→ `?static=true&mediaSourceId=`
- 进度：`Sessions/Playing` → `Progress`（10s）→ `Stopped`，fire-and-forget
- 全链路带超时；失败分类（鉴权/网络/超时）

**详细坑表见技能 `cineflow-tech-skills` 的 `references/emby-api.md`。**

### 开源借鉴

| 项目 | 借鉴什么 |
|---|---|
| [zzzwannasleep/LinPlayer](https://github.com/zzzwannasleep/LinPlayer)（325★ AGPL-3.0） | **最贴身的参考**：`core/cmd/diffcheck/corpus/*.json` 是按"现象"命名的 Emby 踩坑语料（服务端过滤是假的、`/Latest` 裸数组、认证头必须带 Version）。**AGPL：只读现象结论，不许合并源码** |
| [edde746/plezy](https://github.com/edde746/plezy)（3595★ **GPL-3.0**） | 排序方向的工程决策基准：`lib/services/jellyfin_client/parts/browse.dart` 的 `fetchSortOptions`（`title→asc`、`rating→desc`、`addedAt→desc`）、`library_query_translator.dart` 的参数拼装。**GPL：只借鉴决策，禁止合并源码** |
| [jellyfin/jellyfin-web](https://github.com/jellyfin/jellyfin-web) | 查询参数语义的权威参考（Jellyfin 与 Emby 同源） |
| MediaBrowser/Emby 官方 API 文档 | 字段与端点权威；**但不要猜字段名**，以真机响应为准 |

---

## S2 · 播放内核（media_kit / libmpv）

### 实现方式

- `media_kit` 统一封装在 `lib/player/player_page.dart`，页面不直接 new Player
- 控制层用 `NoVideoControls` 关掉默认 UI，全部自绘
- mpv 参数与手势分区见技能 `references/player-media.md`
- **`dispose()` 里绝不同步 `_player.dispose()`**（原生崩溃）——延迟 ≥300ms 异步销毁

### 开源借鉴

| 项目 | 借鉴什么 |
|---|---|
| [media-kit/media-kit](https://github.com/media-kit/media-kit)（1830★ MIT） | 官方封装与平台库组合，先看它的平台支持矩阵 |
| [mpv-player/mpv](https://github.com/mpv-player/mpv)（37221★） | option 与 `mpv.conf` 语义全集；硬解、色调映射、ASS 渲染的权威说明 |
| [chicring/Themby-Release](https://github.com/chicring/Themby-Release)（61★ **NOASSERTION**，2024-08 停更） | 播放器控制层布局与手势体系、`Sessions/Playing` 进度上报载荷结构。**无明确许可 → 只借鉴思路与协议理解，禁止复制代码**；且已停更超 2 年，引用前重新核实 |
| [okami-horo/DDPlayTV](https://github.com/okami-horo/DDPlayTV)（3★ Apache-2.0） | 多内核切换 + libass 渲染 + 对远端源做本地 HTTP 代理改善 seek。许可最友好，但体量小，只取思路 |

---

## S3 · 数据与安全

- 凭据只进 `flutter_secure_storage`（Android Keystore），**不入库、不落项目目录、不打日志**
- 播放偏好与搜索历史用 `cf_pref_*` 键；`SessionStore` 是唯一出口
- 设备 ID 首启生成 UUID v4 持久化
- **不引 drift/SQLite**：当前持久化需求是键值对（ADR 0002）

## S4 · 状态与导航

- `SessionNotifier`（`AsyncNotifier`）管理会话；`embyApiProvider` 由会话派生 API 实例
- 数据流用 `FutureProvider`；未引入代码生成
- 路由用 Navigator；**深度链接需求出现时再评估 go_router**（ADR 0002）

## S5 · 豆瓣数据源

- `m.douban.com/rexxar/api/v2` 公开接口，**必须带移动端 UA + Referer**（否则 418）
- 图床必须走 `DoubanImage`（`Image.network` 即使带 headers 也 418）
- 缓存走 SQLite（drift），TTL 在**写入时**固化（`expires_at` 列），由 SQL 判过期。
  旧实现 `MemoryDoubanCache` 忽略 ttl 且不落盘（缺陷 7.4），**已修复**

**详细见技能 `references/douban.md`。**

## S6 / S7 / S8 / S9 要点

| 技能 | 实现方式 | 借鉴 |
|---|---|---|
| S6 降级 | 单区块失败只降级该区块；全失败经 `fatalError` 报错；「重试」必须真能恢复 | 缺陷 7.8/7.9 的回归线；`test/home_repository_test.dart` |
| S7 弹幕 | 弹弹play v2（或自建 `danmu_api`）；Title+Episode+指纹匹配；屏蔽在生成 ASS 前做 | `Tony15246/uosc_danmaku`、`huangxd-/danmu_api`、`DDPlayTV` |
| S8 门禁 | 反向注入防假绿 + `check-secrets.ps1` / `check-docs.ps1` | `cineflow-workflow/references/gates.md` |
| S9 发版 | `VERSION` 唯一权威；changelog 写作法；隐私政策 + 不宣称与 Emby 官方关联 | `docs/CHANGELOG-GUIDE.md` |

---

## 变更日志

| 版本 | 日期 | 变更 |
|---|---|---|
| v1.0 | 2026-10-04 | 初始版本：S1–S9 技能全景（桥接/Emby/播放/弹幕/115/存储/构建/门禁/发版） |
| v1.1 | 2026-10-04 | 新增引用纪律与 S10「开源发现与核实」；订正失效引用（`go-flutter/go-flutter` 404 等） |
| v1.2 | 2026-10-04 | **按本仓库实际技术栈重建**：删除 S1 桥接、S5 115 预留、S7 三端构建三节（无 Go 层，见 ADR 0002）；S1 改为 Emby 协议、新增 S4 状态与导航 / S6 降级与错误呈现；补充 `plezy`、`Themby`、`jellyfin-web` 三个已核实参考 |
