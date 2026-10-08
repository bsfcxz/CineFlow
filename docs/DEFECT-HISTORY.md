# 已修复缺陷历史（DEFECT HISTORY）

> **本文档从 [`AGENTS.md`](../AGENTS.md) §7 外移而来**（2026-10-09）。
>
> **为什么外移**：`AGENTS.md` 有 **65536 字节**的工作区指令预算，超出会被截断、
> 后面的章节代理读不到（实测 §12「领域知识在哪」整节丢失）。
> §7 的标题本就是「**未修复**，勿当成已完成功能」，把已修项的详细记录留在里面
> 既超预算、又与标题不符 —— 故归档到这里；**未修项仍在 AGENTS §7**。
>
> **给后续代理**：这些不是"待办"，是**已经修好的**。
> 但里面的**实测依据与验证方法**有长期价值 ——
> 修同类问题时先看这里有没有现成的手法（反向注入怎么做的、用什么物证确认的）。

| # | 缺陷 | 修复依据与验证方式 |
|---|---|---|
| ~~7.1~~ | `reportPlaybackStart` 零调用点 | **已修复**：`_reportStart(PlaybackLaunch)` 起播即发 `Sessions/Playing`（`player_page.dart`）。真机实测：起播 8s 时服务器会话已带 `PositionTicks=8.2s`（Progress 周期 10s，故只能来自 Start） | — |
| ~~7.2~~ | 媒体库排序完全失效 | **已修复**：新增 `LibraryPage.sortOptions`（SortBy → 标签, 方向）与 `_cycleSort()` 循环切换。**同时修掉一个更深的问题**：`getItems` 的 `SortOrder` 原被硬编码为 `Ascending`，导致"最近添加"实际返回**最旧**的条目。真机验证：点击 chip 依次得到 名称/评分/最近添加 三种结果，评分序为 10.0→9.2→9.0 严格降序 | — |
| ~~7.4~~ | 豆瓣缓存 TTL 形同虚设 | **已修复**（ADR 0005）：契约改为 **TTL 在写入时固化**——`put(key,value,{required ttl})` 必填、`get(key)` 无可忽略参数（旧契约 `get(key,ttl:)` 允许实现方收下参数却不用，这正是缺陷根源）。缓存改走 drift/SQLite：`expires_at` 列 + `idx_douban_expires` 索引，过期判断在 SQL 里；旧 `FileDoubanCache`（写好却零引用）已删除。**反向注入验证**：把 `get` 改回忽略 ttl → 测试变红 `Expected: null, Actual: 'v'`。**真机物证**：设备导出 SQLite 中 `rank:movie_showing:0:25` 一行，`expires_at - saved_at = 21600` 秒（正是榜单 6h），且跨进程重启后日志仍显示 `现有 1 条 / 30125 字符` | — |
| ~~7.5~~ | `default_rate` 有读无写 | **已修复**：播放设置抽屉新增「默认倍速（下次起播）」组（1x/1.25x/1.5x/2x），经 `PlayerPage.parseDefaultRate/encodeDefaultRate` 读写 `cf_pref_default_rate`；1x 存空串以清除偏好。真机确认 4 个选项渲染正常 | — |
| ~~7.6~~ | `getItems` 中 `'Filters'` 键写了两次 | **已修复**：改为 `if (unplayedOnly) ... else if (filters ...)` 互斥分支，不再静默覆盖 | — |
| ~~7.8~~ | 媒体库加载失败被吞成"暂无内容" | **已修复**：`_reload` 捕获错误存入 `_error`，`_results` 在空列表时优先渲染 `CfErrorView` + 重试。真机验证：关 WiFi → 强制 reload → 显示「加载失败，请检查网络后重试」+「重试」，**不再出现"该库暂无内容"** | — |
| ~~7.9~~ | 首页 `/Latest` 无 try | **已修复**：四个区块各自独立降级；但**全失败时**把首个错误放进 `HomeData.fatalError`，UI 据此显示错误页。真机验证：关 WiFi → 下拉刷新 → 显示错误页 + 重试；点重试恢复 | — |
| ~~7.12~~ | 转码仅有 UI 文案 | **经实测判定为"服务器不具备转码能力，暂不实现"**：Emby 4.10.0.40 免费版 `HardwareAccelerationRequiresPremiere=True`；带 DeviceProfile 强制转码的 POST 返回 `SupportsTranscoding=false` 且无 `TranscodingUrl`；直连 `master.m3u8` 虽 200 但 `CODECS` 仍是源编码（hvc1），即未真正转码。结论已写入 `emby_provider.resolvePlayback` 注释。**待服务器具备转码能力后再接入** | — |
| ~~7.14~~ | 演职员只渲染 `Actor` | **已修复**：`models.dart` 新增 `EmbyPeople` 扩展（`actors/directors/writers/crewLine`），详情页在演员横滑上方显示「导演 A / B」摘要行。**实测依据**：本服务器 `People[].Type` 只有 `Actor`(107) 与 `Director`(14) 两种，旧实现把 **14 条导演数据全部静默丢弃**。真机验证：详情页显示「导演 石头熊 / Ma Hua / 王子悦」 | — |
| ~~7.15~~ | 类型/年份筛选仅客户端 | **数据层已修复**：`getItems` 新增 `genres`/`years` 参数；`getGenres`（`/Genres?ParentId=` → 200 + `{Items:[{Name}]}`，空名需滤）与 `getYearRange`（`ProductionYear` 升/降序 + `Limit=1` 双探针，本服务器实测 **1931–2026**）落地。实测 `Genres=动作` 使总数 2035→**823**、`Years=2024`→**67**、组合→**19**（交集语义），且返回条目确实都含该类型。**页面部分随 ADR 0003 作废**（媒体库页已删除）；参数拼装由 `test/server_filter_test.dart` 6 例守住，重构时直接复用 | — |
| ~~7.16~~ | release 用 debug 签名 | **已修复**：RSA-4096 / PKCS12 / 30 年有效期，keystore 存**仓库外**（`%USERPROFILE%\cineflow-keystore\`），CI 从 5 个 Secrets 还原（`KEYSTORE_BASE64` 等）并写 `android/key.properties`，发布前有**签名守卫**（grep `Android Debug` + `keytool -printcert` 指纹比对）。**已产出并发布 v0.3.1 三个 ABI 的正式签名包**；工具 `tool/verify_signing.ps1`。⚠️ 注意 `apksigner verify` **必须带 `--verbose`** 才会打印 v2/v3 签名方案行 | — |
| ~~7.17~~ | `clientVersion = '0.1.0'` 与 pubspec `1.0.0+1` 不一致 | **已修复**：新增 `lib/core/version.dart` 作为 Dart 侧唯一来源（`kAppVersion` / `kClientVersion` / `kAppVersionLabel`），`VERSION` 为全仓唯一权威，`pubspec.yaml` 对齐为 `0.2.0+1`，「我的」页不再硬编码。一致性由 `tool/bump_version.ps1 -Check` 强制校验（收工前与 CI 必跑）；改版本用 `tool/bump_version.ps1 -Version X.Y.Z` 一次改齐三处 | — |
| ~~7.19~~ | `MediaProvider` 抽象实际未解耦（ADR 0002 的"UI 零改动"承诺不成立） | **已修复**：抽象层 12 个签名原本直接返回 `Emby*` 类型，全仓 **21 文件 / 243 处**引用。已把**跨越抽象边界的类型**中立化为 `Media*`（EmbyItem→MediaItem 等 12 个），刻意保留 `EmbyProvider`/`embyApiProvider`（那是具体实现，名字里带 Emby 是对的）。做法：词边界正则 + **最长优先**排序（避免 `EmbyItem` 吃掉 `EmbyItemDetail` 前缀），动手前先确认 `media_kit` 未导出同名符号。**验收：analyze 0 error/warning 一次通过，263 例测试全绿（改名不改行为）** | — |

---

## 相关

| 想知道 | 看 |
|---|---|
| **当前未修复**的缺陷 | [`AGENTS.md`](../AGENTS.md) §7 |
| 某轮具体改了什么 | [`AI-MEMORY.md`](AI-MEMORY.md)（变更台账） |
| 提交前逐条打勾 | [`review-checklist.md`](review-checklist.md) |
| 验证纪律（避免"假绿"） | [`VERIFICATION-DISCIPLINE.md`](VERIFICATION-DISCIPLINE.md) |
