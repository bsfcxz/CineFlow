# 开源参考项目清单（开发文档）

> **本文件回答一个问题**：CineFlow 借鉴了哪些开源项目、借鉴的是什么、许可能不能抄代码。
>
> 与 [`OSS-SOURCES.md`](OSS-SOURCES.md) 的分工：
> - **本文件**是**面向开发者的参考索引**，按「用在哪一层」组织，写清**具体借鉴点**
> - `OSS-SOURCES.md` 是**核实台账**（stars / 最近提交 / 许可的实测记录），
>   新增引用前必须先跑 `python scripts/discover_oss.py --verify <owner/repo>`
>
> 核实日期：**2026-10-05**（标 ✅ 的是当日实测；标「沿用」的引自 `OSS-SOURCES.md` 既有核实记录）

---

## 0. 许可红线（先读这一段）

| 许可 | 能做什么 | 红线 |
|---|---|---|
| **MIT / BSD / Apache-2.0** | 可借鉴实现，**可少量抄并保留版权声明**（Apache 还要带 NOTICE） | 抄之前保留原始版权头 |
| **GPL-2/3 / AGPL-3** | **只能借鉴架构、流程、协议理解** | ❌ **不得把源码并入本仓库**（传染） |
| **NOASSERTION**（无明确许可） | 只读想法 | ❌ 默认禁止复制任何代码 |

本项目自身许可是 **Apache-2.0**。**只要还要发布或换许可，就一律不许合并 GPL/AGPL 代码** —— 这是不可逆的决定。

> ⚠️ 下表里有多个 GPL-3.0 项目（`plezy` / `boxplayer` / `LinPlayer` / `NipaPlay`）。
> 它们的价值在于**协议事实与工程决策**，**不是代码**。用之前先看"能不能抄"一列。

---

## 1. ★ 播放内核（本项目最核心的参考）

内核迁移到「安卓原生 mpv」时，这四个项目是直接依据。

| 项目 | stars | 许可 | 具体借鉴点 | 能不能抄 |
|---|---:|---|---|---|
| ✅ [**mpv-android/mpv-android**](https://github.com/mpv-android/mpv-android) | 3604 | **MIT** | **本项目内核的直接参考**：① `app/src/main/jni/render.cpp` —— 它的"渲染"**根本不是 `mpv_render_context`**，而是 `attachSurface → mpv_set_option("wid", int64)`，由 mpv 自己建 EGL；② `MPVView.kt` 的 Android 默认选项组合（`profile=fast` / `vo=gpu` / `gpu-context=android` / `opengl-es=yes` / `hwdec=mediacodec,mediacodec-copy` / `ao=audiotrack,opensles` / `demuxer-max-bytes=64MiB`）；③ `BackgroundPlaybackService` 只做"防杀 + 通知" | ✅ 可抄（保留版权头） |
| ✅ [**androidx/media**](https://github.com/androidx/media) | 3022 | **Apache-2.0** | **尚未实现的 K3 会话层**参考：`SimpleBasePlayer` 包自定义 player（抽象方法只有 `getState()`）、`MediaSessionService` + `onGetSession`、`DefaultMediaNotificationProvider`。**已核实：音频焦点与拔耳机暂停不在 session 层**（`MediaSession*.java` 零 `AudioManager` 命中），必须自研 | ✅ 可抄（需带 NOTICE） |
| ✅ [**Predidit/canvas_danmaku**](https://github.com/Predidit/canvas_danmaku) | 41 | **MIT** | 弹幕轨道分配算法与 `safeArea`（给字幕留一行）思路。**不引入依赖**——其 API 是"播放器 push 弹幕进引擎"，与本项目"时间轴即事实源"的模型不合，只取算法 | ✅ 可抄 |
| ✅ [**jarnedemeulemeester/libmpv-android**](https://github.com/jarnedemeulemeester/libmpv-android) | 69 | **MIT** | 预编译 libmpv 的获取途径**调研**。**最终未采用**：其产物是 AAR（`dev.jdtech.mpv`，`libmpv.so` 6.4MB **+ 分离的** `libavcodec.so`/`libavformat.so` 等），而本项目需要**单文件自包含**的 `libmpv.so`（12.4MB，ffmpeg 静态链入）—— 两者架构不同，实测 SHA256 不等 | 仅调研 |
| ✅ [**mpv-player/mpv**](https://github.com/mpv-player/mpv) | 37221 | GPL-2.0 | **语义权威**（作依赖引用，不抄源码）：`client.h` 明确 `wid` 只能在 `mpv_initialize` **之前**用 `mpv_set_option` 设置 | ⚠️ 仅查语义 |
| 沿用 [**media-kit/media-kit**](https://github.com/media-kit/media-kit) | 1830 | MIT | **纹理路线的直接参照**：`VideoOutput.java` 的 `TextureRegistry.SurfaceProducer → Surface → newGlobalObjectRef → wid`。本项目迁移前就是跑在它上面，迁移后沿用同一渲染出口 | ✅ 可抄 |
| ✅ [**media-kit/libmpv-android-video-build**](https://github.com/media-kit/libmpv-android-video-build) | 18 | NOASSERTION | **⭐ 本项目 `libmpv.so` 二进制的最可能来源**（见下方「二进制溯源」）。media-kit 的官方 Android 构建仓库，其产出的 `.so` 正是"单文件自包含 ffmpeg"形态 | 仅取产物 |

### ⭐ 二进制溯源：`libmpv.so` 是怎么来的（实测，非推测）

这件事**此前文档里没有记录**，我从二进制里挖出来了。方法：直接扫描 `.so` 中的字符串。

**证据链**：

```
# .so 内嵌的 mpv configure 参数（构建时烧进去的）
--disable-gpl --disable-nonfree --enable-version3 --enable-static --disable-shared
--pkg-config-flags=--static ...

# 内嵌的 CI 构建路径
/home/runner/work/libmpv-android-video-build/libmpv-android-video-build/buildscripts/prefix/arm64-v8a/crossfile.txt
--cross-file=.../crossfile.txt   (target: aarch64, cpu: armv8-a)
```

**由此可确定的三件事**：

| 项 | 结论 | 依据 |
|---|---|---|
| **许可** | **LGPL-3.0**（**不是** GPL） | `--disable-gpl` + `--disable-nonfree` + `--enable-version3` |
| **来源** | GitHub Actions 上名为 `libmpv-android-video-build` 的仓库 | 内嵌 `/home/runner/work/<repo>/<repo>/` 路径 |
| **形态** | 单文件自包含（ffmpeg/libass 静态链入） | `--enable-static --disable-shared` + `DT_NEEDED` 只有系统库 |

> ⚠️ **待确认**：同名仓库在 GitHub 上有 **9 个**（多为 fork）。按路径特征与
> "单文件自包含"形态，**最可能是 `media-kit/libmpv-android-video-build`**
> （media-kit 的官方 Android 构建仓库，18★）。但**尚未 100% 锁定是哪一个**——
> 正式发布前应向该仓库确认，或在 `NOTICE` 中按 LGPL-3.0 履行义务（附许可证全文与获取源码的途径）。

> 💡 **对 `NOTICE` 的影响**：`NOTICE` 目前写"以动态链接方式随 media_kit 分发"——
> 这句话**已经过时**（media_kit 已移除，现在是自持 `.so`）。
> 正确的表述应是：**本产品包含 LGPL-3.0 许可的 libmpv（动态链接），
> 用户有权获取其源代码**。这是合规要求，详见 `NOTICE` 待修项。

**顺带否掉一个假设**：工作区外的 `_mpvsrc/`（45.6MB）含 `libmpv-1.0.0.aar`
（包名 `dev.jdtech.mpv`）+ mpv-android 源码，是**调研素材**，
**不是**本项目的 `.so` 来源（实测两者 SHA256 与体积均不同）。


> **关键结论（反直觉，值得记住）**：Android 上没有 `mpv_render_context` 的范例。
> 上游 mpv-android 用的就是 `wid`，本项目最终也选了这条路 —— 详见 [ADR 0009](decisions/0009-native-mpv-kernel.md)。

---

## 2. Emby 协议与客户端

| 项目 | 许可 | 具体借鉴点 | 能不能抄 |
|---|---|---|---|
| [**dev.emby.media**](https://dev.emby.media/reference/RestAPI.html) | 官方文档 | ★ **最权威**的 REST API 参考，按 Service 分类列全部端点。**新增端点前先在这里查，再 curl 实测** | — |
| [**MediaBrowser/Emby.ApiClients**](https://github.com/MediaBrowser/Emby.ApiClients) | — | ★ **官方多语言 SDK 源码**（含 Go 客户端，生成版本 4.10.1.0，与本项目服务器同代）。字段名/请求体形状的**权威对照**；也印证了"Go 核心层 + 自写 UI"路线 | 仅对照 |
| 沿用 [**zzzwannasleep/LinPlayer**](https://github.com/zzzwannasleep/LinPlayer) | **AGPL-3.0** | `core/cmd/diffcheck/corpus/` 的 Emby 踩坑语料：服务端过滤不可信、`/Latest` 返回裸数组、认证头必带 `Version`。**本仓库多个方法注释直接引用其结论** | ❌ **只读现象结论，禁止合并源码** || 沿用 [**edde746/plezy**](https://github.com/edde746/plezy) | **GPL-3.0** | `fetchSortOptions` 的排序方向约定（`title→asc` / `rating→desc` / `addedAt→desc`）、库查询参数拼装 | ❌ **只借鉴工程决策** |
| 沿用 [**jellyfin/jellyfin-web**](https://github.com/jellyfin/jellyfin-web) | GPL-2.0 | Jellyfin 与 Emby 同源 → 查询参数语义的旁证 | ❌ 只查语义 |
| 沿用 [**Moonfin-Client/Moonfin-Core**](https://github.com/Moonfin-Client/Moonfin-Core) | GPL-2.0 | 播放后端按平台自适应的选型矩阵 | ❌ 只借鉴选型 |
| 沿用 [**MCDFsteve/NipaPlay**](https://github.com/MCDFsteve/NipaPlay) | GPL-3.0 | Flutter 播放器的结构与分层 | ❌ 只借鉴结构 |

---

## 3. 115 网盘

| 项目 | 许可 | 具体借鉴点 | 能不能抄 |
|---|---|---|---|
| 沿用 [**SheltonZhu/115driver**](https://github.com/SheltonZhu/115driver) | **MIT**（GitHub API 误报 NOASSERTION，因其 LICENSE 前段有立场声明，正文是标准 MIT） | ★ **本项目 115 协议层的来源**：webapi 端点选择、**UA 与 CDN 直链强绑定**（issue #80）、`aps.115.com` 绕过 WAF、错误码分类、限速策略。**`go/internal/pan115/m115/` 直接移植其加解密算法，MIT 署名全文已保留在同目录** | ✅ **已移植**（署名齐全） |
| 沿用 [**lvzhenbo/115-plus-desktop**](https://github.com/lvzhenbo/115-plus-desktop) | **MIT** | 基于 **115 官方开放平台**的第三方客户端 —— 许可安全、路线更正规，**是将来"转正"的首选参考** | ✅ 可提取协议事实 |
| 沿用 [**gaozhangmin/boxplayer**](https://github.com/gaozhangmin/boxplayer) | **GPL-3.0**（README 徽章标 MIT 是**错的**） | 115 开放平台调用范例（设备码 + PKCE、`video/play`、UA 绑定注册表） | ⚠️ **强 copyleft：绝不可抄代码** |
| 沿用 [**power721/115driver**](https://github.com/power721/115driver) | 同上游 | **是 `SheltonZhu/115driver` 的 fork**，非独立实现 —— 不作独立证据源 | ❌ |

> ⚠️ 本模块走的是 **115 非公开 webapi 接口**，有**账号风控风险**，已在登录页明示，见 [ADR 0007](decisions/0007-pan115-webapi-route.md)。

---

## 4. 弹幕

| 项目 | 许可 | 具体借鉴点 | 能不能抄 |
|---|---|---|---|
| 沿用 [**huangxd-/danmu_api**](https://github.com/huangxd-/danmu_api) | AGPL-3.0 | 兼容弹弹play 协议的自建服务。**本项目作为调用方**（URL token 认证形态） | ✅ 可作调用方 |
| 沿用 [**l429609201/misaka_danmu_server**](https://github.com/l429609201/misaka_danmu_server) | — | 自建弹幕服务，与上者同属"URL path token"认证形态 | ✅ 可作调用方 |
| 沿用 [**Tony15246/uosc_danmaku**](https://github.com/Tony15246/uosc_danmaku) | MIT | mpv 弹幕扩展：时间轴与样式参数 | ✅ 可抄 |
| 沿用 [**okami-horo/DDPlayTV**](https://github.com/okami-horo/DDPlayTV) | Apache-2.0 | libass ASS 渲染、关键字/正则屏蔽、远端源本地 HTTP 代理改善 seek | ✅ 许可安全（体量小，只取思路） |

> 本项目**不自研渲染引擎之外的轮子**：轨道算法自绘（`CustomPainter`），见 [ADR 0006](decisions/0006-danmaku-source-and-rendering.md)。

---

## 5. 基础依赖（通过包管理器使用，未改源码）

| 依赖 | 许可 | 用途 | 仓库 |
|---|---|---|---|
| Flutter / Dart | BSD-3-Clause | UI 框架 | https://github.com/flutter/flutter |
| flutter_riverpod | MIT | 状态管理与依赖注入 | https://github.com/rrousselGit/riverpod |
| go_router | BSD-3-Clause | 声明式路由 | https://github.com/flutter/packages |
| drift | MIT | SQLite 类型安全 ORM | https://github.com/simolus3/drift |
| dio | MIT | HTTP 客户端 | https://github.com/cfug/dio |
| flutter_secure_storage | BSD-3-Clause | 凭据安全存储（Android Keystore） | https://github.com/juliansteenbakker/flutter_secure_storage |
| screen_brightness | MIT | 播放器亮度手势 | https://github.com/aaassseee/screen_brightness |
| url_launcher | BSD-3-Clause | 打开外部链接 | https://github.com/flutter/packages |
| Go | BSD-3-Clause | 核心逻辑层 | https://github.com/golang/go |

> 完整清单见 `pubspec.lock` 与 `go.mod`。本项目**通过包管理器使用这些依赖，未修改其源码**。

---

## 5.5 UI / 交互设计参考（2026-10-05 新增）

> 这一节记录**设计层面**的参考。设计参考的价值在于**结构与交互思路**，
> 不涉及代码合并 —— 但仍需核对许可，因为"能不能抄"的边界由它决定。

| 项目 | 许可 | stars | 借鉴了什么（**具体**） | 能不能抄 |
|---|---|---|---|---|
| [**mitesh77/Best-Flutter-UI-Templates**](https://github.com/mitesh77/Best-Flutter-UI-Templates) | **MIT**<br>（GitHub API 报 NOASSERTION，读 LICENSE 正文确认是 MIT） | 22.8k | ① **整套 `TextTheme`** 而非散落 fontSize（`design_course_app_theme.dart` / `fitness_app_theme.dart`）；② 卡片 + **渐变兜底图**（海报缺失时不留白）；③ 按可用宽度算**网格列数** | ✅ **MIT，可少量借鉴并署名**<br>（本仓库只借鉴模式，未复制代码） |
| [**zzzwannasleep/LinPlayer**](https://github.com/zzzwannasleep/LinPlayer) | ⚠️ **AGPL-3.0** | 325 | **只有方法论**：`docs/go-migration/PROMPT_MOBILE_UI.md` 里的<br>① **"编译通过 ≠ 交付"**，UI 必须真渲染 + 截图验证；<br>② **空态/错误态/加载态三态都要验**（正常数据下看不到，最容易做砸）；<br>③ **触摸目标 ≥48dp**（其陷阱表原文：横屏播放器 chip 视觉 32dp、命中区撑到 44dp）；<br>④ **风格刻度是枚举不是区间**（要用第五种圆角先改规范表）；<br>⑤ 已知陷阱表（`.so` 未 strip → APK 105MB、libass 缺字体 → 字幕全不显示 等） | ❌ **AGPL：绝不可抄一行代码**（会迫使本项目整体改许可）<br>**只读其公开文档中的结论** |
| [**wasabeef/awesome-android-ui**](https://github.com/wasabeef/awesome-android-ui) | MIT | 57.8k | **清单仓库**（非代码库），用于核对组件/交互模式的行业做法 | ✅ 仅索引 |

> ⚠️ **LinPlayer 的 `docs/DESIGN.md` 是「Apple 官网设计分析」**（浅色 + SF Pro + Action Blue #0066cc），
> 与本项目「深蓝夜色 × 极光青」**方向完全不同**，**不作为配色依据**。
> 该文件自己也承认"播放器内部控件没有文档化"。**不要误把它当播放器设计规范。**


---

## 6. 已作废（核实失败，禁止再引用）

| 仓库 | 结果 | 备注 |
|---|---|---|
| `go-flutter/go-flutter` | HTTP **404** | 旧文档里的桌面 Go 插件方案，仓库不可达 |
| `moonfin/moonfin` | HTTP **404** | 真名是 `Moonfin-Client/Moonfin-Core` |
| `detiam/NipaPlay-Reload` | 存在但 **0 star** | 应引用 `MCDFsteve/NipaPlay` |

> 教训：搜索引擎摘要里的仓库名（尤其镜像站）会失真，**一定 API 核实**。

---

## 7. 维护约定

1. **新增引用前必须核实**：
   ```bash
   python scripts/discover_oss.py --verify <owner/repo>
   ```
   把 stars / 最近提交 / 许可登进 [`OSS-SOURCES.md`](OSS-SOURCES.md)，再引用。
2. **每季度重跑一次复核**（`CF-P1-OSS-009`）：停更超 30 个月的行降级；失效引用移入「已作废」。
3. **许可证要看 LICENSE 原文**，不要信 README 徽章 —— `boxplayer` 的徽章标 MIT，实际是 GPL-3.0。
4. **GPL/AGPL 项目只读不抄**：抄了会传染本项目许可，且**不可逆**。

---

## 变更日志

| 版本 | 日期 | 变更 |
|---|---|---|
| v1.0 | 2026-10-05 | 初版：按分层组织开源参考（内核 / Emby / 115 / 弹幕 / 基础依赖），补录内核迁移的 4 个新参考（mpv-android ✅3604★MIT、androidx/media ✅3022★Apache-2.0、canvas_danmaku ✅41★MIT、jarnedemeulemeester/libmpv-android ✅69★MIT）并标注实测日期；汇总全仓 39 个 GitHub 引用；含许可红线与作废清单 |
