# 任务看板 · CineFlow

> 当前阶段：**阶段三收尾（播放内核迁移 K0–K4 已完成）** → 剩余：**K3 Media3 会话层** + 迁移片源回归
> 完整任务卡 YAML 放 `docs/tasks/CF-<ID>.md`；模板见 `cineflow-workflow/references/task-cards.md`。
> 状态机：`todo → doing → verify → done`（另有 `blocked` / `canceled`）。状态变化与合并同一次提交。
> 路线图进度总表见 `AGENTS.md` §1——**那里是权威**，本表只列可执行的任务卡。

## 阶段三（播放内核迁移：安卓原生 + mpv）—— K0–K4 已完成

> 2026-10-05 落地：弃用 media_kit，改为 **Flutter 纹理 + `Surface→wid`** 直连 libmpv。
> 决策与实测坑见 **ADR 0009** 与 `docs/PLAYER-KERNEL.md`。
> 参考项目：androidx/media https://github.com/androidx/media ·
> mpv-android https://github.com/mpv-android/mpv-android ·
> media-kit/media-kit https://github.com/media-kit/media-kit
>
> **真机证据**（Xiaomi M2012K11AC / Android 13 / arm64）：
> `av_jni_set_java_vm -> 0` · `wid 已设定 = 14182` · `mpv_initialize 成功，client API 版本=131074`
> · `[mpv/vd] Using hardware decoding (mediacodec).` · `VO: [gpu] 1920x1080 mediacodec`
> · 集成测试 `integration_test/player_kernel_test.dart` **1 passed**

| ID | 阶段 | 标题 | owner | 状态 | 验收要点 | 更新 |
|---|---|---|---|---|---|---|
| **CF-P3-KERNEL-004** | P3 | ★ **K3：Media3 会话层**（通知栏 / 蓝牙耳机键 / 后台播放 / 音频焦点） | ui | todo | `media3-session:1.11.1`（Google Maven）+ `SimpleBasePlayer` 包 mpv（抽象方法只有 `getState()`），**不需要** exoplayer/ui。manifest 加 `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MEDIA_PLAYBACK` + `foregroundServiceType="mediaPlayback"`。⚠️ **音频焦点与拔耳机暂停必须自研**（Media3 的焦点实现在 ExoPlayer 里，session 层不做——已核实 `MediaSession*.java` 零 `AudioManager` 命中）。mpv 的 JNI 回调必须 post 回创建 session 的应用线程 Looper | 2026-10-05 |
| CF-P3-KERNEL-005 | P3 | 迁移前后片源对照回归（4K DV HEVC / PGS 字幕 / 多音轨） | ui | todo | 用同一批片源比对：直连起播、硬解生效、字幕渲染、音轨切换。**K4 遗留的唯一验证缺口**（K4 只证明了"能播 + 硬解 + 音画出得来"） | 2026-10-05 |
| CF-P3-KERNEL-006 | P3 | 播放中 WakeLock（缺陷 7.11） | ui | todo | 现有内核仍无 WakeLock；K3 的 Media3 会话层会顺带解决，或先用 `wakelock_plus`（依赖已在树里） | 2026-10-05 |

## 阶段八（115 网盘）—— 进行中

> 2026-10-05 落地：协议层（Go）+ 扫码登录/文件浏览/播放 UI，见 **ADR 0007**。
> 走的是 **webapi（非公开接口）**，有风控风险，已在登录页向用户明示。
> **真机已验证到"能拿到二维码"**；**列文件/取直链/真实播放全部未联调**（无真实账号）。

| ID | 阶段 | 标题 | owner | 状态 | 验收要点 | 更新 |
|---|---|---|---|---|---|---|
| **CF-P8-115-030** | P8 | ★ **真实 115 账号联调**（最高优先级） | ui | todo | 有账号后逐项确认：① **`aps.115.com` 登录成功后的响应形状**（ADR 0007 标注的最大缺口，不符则回退 `http://web.api.115.com/files`）② 列文件 ③ 取直链 ④ **真实播放**（验证 UA 绑定与 Set-Cookie 合并是否真的生效）。**必须打日志确认，不要照抄协议文档** | 2026-10-05 |
| CF-P8-115-031 | P8 | m115 解密对真实响应是否可用 | core | todo | 协议调研结论标注"只能证明管线自洽，不能证明线上可用"。需一份真实 `downurl` 响应样本（脱敏）验证前缀长度与多块拼接 | 2026-10-05 |
| CF-P8-115-032 | P8 | 115 播放进度（本地存储） | ui | todo | 取证结论：webapi **没有**可用的进度接口 → 本地存。**主键用 `sha1` 而非 `pick_code`**（跨账号/跨分享都能对上） | 2026-10-05 |
| CF-P8-115-033 | P8 | 115 按后缀筛视频（走 `/files/search`） | ui | todo | 该端点实测**未被 WAF 拦**，`type=4` + `suffix` 过滤；比客户端筛更省流量 | 2026-10-05 |
| CF-P8-115-034 | P8 | 115 会话失效的自动引导 | ui | todo | 错误码已分类（`needsRelogin`/`needsVIP`）。需让 UI 在收到"必须重新登录"时**主动跳登录页**而不是只弹提示 | 2026-10-05 |

## 当前任务

| ID | 阶段 | 标题 | owner | 状态 | 验收要点 | 更新 |
|---|---|---|---|---|---|---|
| CF-P4-UI-019 | P4 | 列表页 UI 全量重构（媒体库浏览） | ui | todo | 按 ADR 0003 重新设计信息架构与筛选交互；服务端分页/排序/筛选参数直接复用（已有单测） | 2026-10-04 |
| CF-P2-EMBY-011 | P2 | 401 统一处理：token 失效自愈（缺陷 7.7） | ui | todo | 拦截器识别 401 → 清理会话 → 回登录页；不弹裸错误；补单测 | 2026-10-04 |
| CF-P4-DOCS-012 | P4 | 修正文档与代码不符处（缺陷 7.10） | docs | todo | README 不再宣称"自动重连"；缓存 TTL 说明已随 §7.4 修复更新（剩余：自动重连） | 2026-10-04 |
| CF-P7-RELEASE-013 | P7 | release 签名流程（缺陷 7.16） | release | todo | 引入 `key.properties` 签名；版本号一致性已由 `bump_version.ps1` 覆盖 | 2026-10-04 |
| CF-P4-ARCH-014 | P4 | 收敛 UI 对 `emby_provider.dart` 的直接依赖（缺陷 7.13） | ui | todo | `EmbyException` 上移到 `media_provider.dart`；8 处 import 减少 | 2026-10-04 |
| CF-P1-OSS-009 | P1 | 每季度重跑 `--verify` 复核 `docs/OSS-SOURCES.md` | architect | todo | 停更超 30 个月的行降级；失效引用移入「已作废」区 | 2026-10-04 |
| CF-P1-GO-020 | P1 | 接入 Synurang 替换当前 JSON-over-FFI | core | todo | 装 Rust + protoc → `cargo install --path cmd/protoc-gen-synurang-ffi` → 生成 typed binding；**Dart 契约不变**（见 ADR 0004 的替换约定） | 2026-10-04 |
| CF-P1-GO-021 | P1 | Go 层承载更多核心逻辑 | core | todo | 候选：Emby HTTP 客户端、排序/筛选参数拼装的唯一事实源、115driver 预留位。**每次迁移都要补 Go 侧单测** | 2026-10-04 |
| CF-P5-DANMAKU-022 | P5 | 弹幕发送（官方 `POST /api/v2/comment/{episodeId}`） | ui | todo | 官方第 8 节要求先登录拿 token，且**不得高频**；需 UI 输入框 + 失败提示 | 2026-10-05 |
| CF-P5-DANMAKU-023 | P5 | 手动匹配面板（自动匹配失败时） | ui | todo | 当前搜不到只显示"该片暂无弹幕"；应给"手动搜索番剧/选集"入口（Cmby 的做法） | 2026-10-05 |
| CF-P5-DANMAKU-024 | P5 | 弹幕密度折线图（"高能进度条"） | ui | todo | 借鉴 Cmby `_DanmakuWavePainter`；已有 `DanmakuBatch` 可直接统计分桶 | 2026-10-05 |
| CF-P5-DANMAKU-025 | P5 | 大弹幕池解析移入 isolate | perf | todo | 末集 7628 条时主线程解析可能有可感知卡顿；需真机确认后再决定（别过早优化） | 2026-10-05 |

## 阶段五（弹幕）—— 已完成主体

> 2026-10-05 落地：协议、渲染、设置、持久化全部完成（161 例单测）。
> **仍缺真实联调**：官方 `api.dandanplay.net` 在本机网络不可达；
> 自建服务需用户自行部署。详见 ADR 0006 与 AGENTS.md §6.7。

| ID | 阶段 | 标题 | owner | 状态 |
|---|---|---|---|---|
| ~~CF-P5-DANMAKU-001~~ | P5 | ~~弹幕渲染选型~~ | architect | **done**（ADR 0006：自绘 CustomPainter，轨道算法按 MIT 的 canvas_danmaku 思路） |
| ~~CF-P5-DANMAKU-015~~ | P5 | ~~弹幕数据源选型 + ADR~~ | architect | **done**（ADR 0006：官方直连 + 自建兼容双形态） |
| ~~CF-P5-DANMAKU-016~~ | P5 | ~~弹幕匹配~~ | ui | **done**（`danmaku_match.dart`，30 例；失败显式提示，**手动面板见 023**） |
| ~~CF-P5-DANMAKU-017~~ | P5 | ~~渲染与屏蔽~~ | ui | **done**（`danmaku_layout.dart` + 屏蔽词，34 例；**不做 ASS 生成**，自绘层更可控） |

## 已完成

| ID | 阶段 | 标题 | 完成于 |
|---|---|---|---|
| CF-P1-DOCS-006 | P1 | 补齐门禁脚本与文档 | 2026-10-04 |
| CF-P1-OSS-007 | P1 | 开源发现与核实（`discover_oss.py` + `OSS-SOURCES.md`） | 2026-10-04 |
| CF-P3-PLAYER-001 | P3 | 修复 `reportPlaybackStart` 零调用点（缺陷 7.1） | 2026-10-04 |
| CF-P3-PLAYER-002 | P3 | 多版本媒体源选择透传（`mediaSourceId`） | 2026-10-04 |
| CF-P4-UI-003 | P4 | 媒体库排序失效（缺陷 7.2，含 `SortOrder` 硬编码） | 2026-10-04 |
| CF-P4-UI-004 | P4 | 默认倍速 `default_rate` 读写闭环（缺陷 7.5） | 2026-10-04 |
| CF-P4-UI-005 | P4 | `Filters` 键重复写入（缺陷 7.6） | 2026-10-04 |
| CF-P4-UI-006 | P4 | 媒体库加载失败不再伪装空库（缺陷 7.8） | 2026-10-04 |
| CF-P4-UI-007 | P4 | 首页四区块独立降级 + 全失败报错（缺陷 7.9） | 2026-10-04 |
| CF-P4-UI-008 | P4 | 演职员渲染导演（缺陷 7.14） | 2026-10-04 |
| CF-P4-DOCS-009 | P4 | 文档/架构契约按实际代码重写 + 合并规划仓库资产 | 2026-10-04 |
| CF-P4-UI-010 | P4 | 类型/年份筛选改服务端查询（缺陷 7.15） | 2026-10-04 |
| CF-P4-UI-018 | P4 | 移除媒体库一级 Tab（ADR 0003） | 2026-10-04 |
| CF-P1-OSS-008 | P1 | 确定自身开源许可 → Apache-2.0 | 2026-10-04 |
| CF-P2-EMBY-022 | P2 | 条目进度持久化端点（`POST …/UserData`，实测只有 POST） | 2026-10-04 |
| CF-P1-GO-023 | P1 | 引入 Go 核心逻辑层并真机打通（ADR 0004） | 2026-10-04 |
| CF-P4-ROUTE-024 | P4 | 路由迁移到 go_router（ADR 0005） | 2026-10-04 |
| CF-P4-DB-025 | P4 | 引入 drift 本地库（ADR 0005） | 2026-10-04 |
| CF-P2-EMBY-026 | P2 | 豆瓣缓存 TTL 落地（修复缺陷 §7.4，TTL 移到写入时） | 2026-10-04 |
| CF-P2-EMBY-027 | P2 | 播放上报带 `EventName`（官方文档要求：交互后立即上报） | 2026-10-04 |

## 阻塞 / 取消

| ID | 状态 | 原因 |
|---|---|---|
| CF-P3-PLAYER-018 | canceled | 转码播放：经 curl 实测本服务器（Emby 4.10.0.40 免费版）不具备转码能力，`SupportsTranscoding=false` 且无 `TranscodingUrl`。待服务器具备能力后再开卡（缺陷 7.12） |
| ~~CF-P1-115-005~~ | **已重启** | 115 网盘接入：原随 ADR 0002 取消；**2026-10-05 用户明确要求重新启动**，改走 webapi 路线，见 ADR 0007 与 CF-P8-115-030 起 |
| CF-P4-UI-010-UI | canceled | 上表 CF-P4-UI-010 的**页面部分**随 ADR 0003 作废（媒体库页已删除）。数据层实现（`getItems` 的 `genres`/`years`/`sortOrder`、`getGenres`、`getYearRange`）与 `test/server_filter_test.dart` 保留，供 CF-P4-UI-019 重构时直接复用 |

> 阻塞超两个迭代 → Captain 升级或拆卡；取消必须写明原因。历史行只增不改。

## 变更日志

| 版本 | 日期 | 变更 |
|---|---|---|
| v1.0 | 2026-10-04 | 初始版本：阶段一六张卡 + 阶段二预置；含 115 预留层交付卡 CF-P1-115-005 |
| v1.1 | 2026-10-04 | CF-P1-DOCS-006 / CF-P1-OSS-007 完成；新增 CF-P1-OSS-008（决定自身许可）与 CF-P1-OSS-009（季度复核开源清单） |
| v1.2 | 2026-10-04 | **按本仓库真实进度重建**：原阶段一/二卡片（Go module、桥接 Hello World、`Pan115Provider`、go_router 骨架）随 ADR 0002 作废，移入「取消」区；新增阶段四收尾 5 张卡（缺陷 7.15 / 7.7 / 7.10 / 7.16+7.17 / 7.13）与阶段五弹幕 3 张卡；已完成区补录 11 张历史卡 |
| v1.3 | 2026-10-04 | 媒体库页移除（ADR 0003）：CF-P4-UI-010 的页面部分作废（数据层与单测保留），新增 CF-P4-UI-019「列表页 UI 全量重构」；CF-P1-OSS-008（自身许可）已完成 → Apache-2.0；CF-P7-RELEASE-013 缩小为仅签名（版本号一致性已由 `bump_version.ps1` 覆盖） |
