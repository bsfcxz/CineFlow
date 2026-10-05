# CineFlow 影流

<img src="docs/assets/icon.png" alt="CineFlow 图标" width="128" align="right">

> 一款 Material 风格的 Emby 第三方播放器（Flutter），深蓝夜色 × 极光青设计语言。
> 万影成流 · 一触即映。

![Flutter](https://img.shields.io/badge/Flutter-3.47+-02569B?logo=flutter) ![Android](https://img.shields.io/badge/Android-7.0+-3DDC84?logo=android) ![media_kit](https://img.shields.io/badge/Player-libmpv%20(media_kit)-FF0000) ![License](https://img.shields.io/badge/License-Apache--2.0-blue)

## 下载安装

已构建的 release APK 见 [**Releases**](https://github.com/1357980024/CineFlow/releases/latest) 页面（arm64-v8a，约 30MB）。

- 支持 **Android 7.0+（API 24+）**，仅 arm64 设备；装前请确认机型架构
- APK 使用 **debug 签名**（见 [AGENTS.md](AGENTS.md) §7.16），仅供自用与体验，**不要用于正式分发**
- 首次启动输入你自己的 Emby 服务器地址 + 账号密码；凭据只存在设备安全存储里

也可以自己构建：

```bash
flutter pub get
bash tool/build_apk.sh        # Windows: tool\build_apk.bat
# 产物 build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

> 发布脚本固定产出 **arm64 单架构 + 符号混淆** 的 APK（约 30MB）。
> media_kit 的 libmpv 必须靠 `--split-per-abi` 才能按架构拆开，
> 三架构合并版约 92MB——详见脚本内注释。

## 项目定位

CineFlow 是一款 **Emby 第三方客户端**，目标是做出比官方客户端更优秀的浏览与播放体验：

- **内容优先**：封面即 UI，沉浸式浏览
- **透明播放**：直连/转码、分辨率、音轨、硬解状态全量展示
- **真实数据**：全部页面直接驱动自 Emby Server REST API，无自建后端
- **豆瓣生态**：排行榜、热门搜索、条目详情接入豆瓣公开数据（仅供学习与个人使用）

## 功能

### 首页 / 详情
- 多服务器登录（`AuthenticateByName`）、会话持久化、服务器凭据回填
  （注：token 失效暂无 401 自愈，见 AGENTS.md §7.7）
- 首页：精选轮播（自动翻页）、继续观看（真实进度）、最近添加、合集（BoxSet）
- 详情页：沉浸式背景、剧集模式（季选择 + 分集列表）、电影模式（媒体流信息 + 多版本）、
  演职员（导演/编剧摘要 + 演员头像横滑）、相似推荐
- 收藏 / 看过：一键 toggle，实时同步服务器
- 搜索：聚合搜索（服务端 SearchTerm + 客户端复筛）+ 搜索历史 + 豆瓣热门

> 一级 Tab 为 **首页 / 排行榜 / 我的** 三项。「媒体库」页已于 ADR 0003 移除——
> 相关数据层能力（服务端类型/年份筛选、排序）保留，供后续列表页重构复用。

### 播放器（media_kit / libmpv）
- Emby 直连播放（`static=true` 原文件流，支持 4K Dolby Vision HEVC 硬解）
- 控制层：章节刻度进度条（缓冲段/渐变播放段/拖拽手柄）、倍速、音轨、字幕、画面比例
- 手势：单击显隐、双击三分区（-10s / 播放暂停 / +10s）、长按 2.5x、竖滑左亮度右音量
- 锁屏防误触、选集上下文、自动连播倒计时、跳过片头（按章节名识别）
- 多版本条目：详情页「版本」选择会带入播放（`PlaybackInfo` + `mediaSourceId` 复选）
- Emby 播放进度上报：`Sessions/Playing` → `Progress`（10s 周期）→ `Stopped`
- 转码：**暂未实现**——当前服务器为 Emby 免费版（无 Premiere），实测带 DeviceProfile 的
  `PlaybackInfo` 返回 `SupportsTranscoding=false` 且无 `TranscodingUrl`，故只做直连

### 排行榜 / 豆瓣
- 电影 / 电视剧 / 动漫全分类榜单（影院热映、口碑榜、高分经典、热门/最新国产·日本动画…）
- 金银铜排名、豆瓣评分与评价人数、条目完整详情（简介/导演/主演）
- 「在媒体库中搜索」——榜单条目与本地库联动的直线动线
- 榜单 / 详情缓存：**SQLite（drift）持久化，TTL 6h / 24h 真实生效**。
  过期时刻在写入时固化进 `expires_at` 列，由 SQL 判断，重启后仍命中缓存。
  （此前是进程内 `MemoryDoubanCache`，**忽略 ttl 且不落盘**，即缺陷 §7.4，已修复）

### 弹幕
- **两种弹幕源**，在「我的 → 弹幕设置」里切换：
  - **弹弹play 官方**：直连 `api.dandanplay.net`，走官方请求头签名
    （`base64(sha256(AppId + Timestamp + Path + AppSecret))`）
  - **自建服务**：兼容 [danmu_api](https://github.com/huangxd-/danmu_api) 与
    [misaka_danmu_server](https://github.com/l429609201/misaka_danmu_server)（URL token 认证）
- **本仓库不含任何凭据**（官方第 7 节要求开源客户端不硬编码 AppSecret）。
  需自行在设置页填写，凭据只存在设备安全存储（Android Keystore）里
- 异步弹幕生成：`?async=1` → 挂起则按 **1.5s 间隔轮询、总上限 5 分钟**，
  完成后自动取回（御坂服务 2.7.0+）
- 渲染：自绘 `CustomPainter`，轨道分配带**追尾判据**（宽弹幕更快，会追上窄弹幕）、
  默认给字幕留一行；支持不透明度/字号/显示区域调节与屏蔽词
- 失败**不影响播放**：没配源、网络不通、该片无弹幕都只提示，视频照常播

> ⚠️ 官方 API 在部分网络环境下不可达（本项目开发机实测 `api.dandanplay.net`
> HTTPS 连接失败，同域 `doc.`/`dev.` 却正常）。协议实现有 161 例单元测试覆盖，
> 但**未做过真实联调**。自建服务需自行部署后填地址。

### 我的
- 真实头像 / 服务器状态 / 观看统计四格（已看电影、追剧中、已看分集、收藏）
- 播放偏好持久化（默认倍速、自动跳片头、自动连播）——默认倍速在播放器右侧
  设置抽屉的「默认倍速（下次起播）」中调整

## 参与开发

提交前请先读 [CONTRIBUTING.md](CONTRIBUTING.md)。几条最容易踩的：
**不要跑 `dart format`**、不要把「加载失败」显示成「暂无内容」、
UI 不要新增对 `emby_provider.dart` 的直接依赖。

门禁（本地与 CI 一致，见 [.github/workflows/ci.yml](.github/workflows/ci.yml)）：

```bash
flutter analyze                                  # 0 error / 0 warning
flutter test                                     # 25 例全绿
powershell -File scripts/check-secrets.ps1 --staged
powershell -File scripts/check-docs.ps1
pwsh -File tool/bump_version.ps1 -Check          # 版本号三处一致
```

发版流程与发布说明规范见 `.github/skills/cineflow-release/SKILL.md`；
各版本发布说明在 [docs/changelog/](docs/changelog/README.md)。

## 技术栈

| 层 | 选型 | 说明 |
|---|---|---|
| 框架 | Flutter 3.35+ / Dart 3.9+ | 单代码库，当前 Android，架构预留 iOS/桌面 |
| 状态管理 | flutter_riverpod 3.x | AsyncNotifier 会话管理 + FutureProvider 数据流 |
| 路由 | **go_router 18.x** | 声明式路由表；`/detail/:id`、`/play/:id` 可直达（[ADR 0005](docs/decisions/0005-go-router-and-drift.md)） |
| **核心逻辑层** | **Go + FFI** | 媒体规则/排序参数在 Go 侧（`go/`），编译为 `libcineflow_go.so`（[ADR 0004](docs/decisions/0004-go-core-layer.md)） |
| 本地数据库 | **SQLite (drift)** | 豆瓣缓存（TTL 落库）+ 本机播放历史（[ADR 0005](docs/decisions/0005-go-router-and-drift.md)） |
| 网络 | dio 5.x | 拦截器统一注入 `X-Emby-Authorization` / `X-Emby-Token` |
| 播放内核 | media_kit (libmpv) | 全格式硬解直连；字幕/音轨/倍速/音量原生控制 |
| 安全存储 | flutter_secure_storage | Token / 服务器凭据 / 设备 ID（Android Keystore） |
| 系统集成 | screen_brightness / url_launcher | 亮度手势 / 豆瓣页面跳转 |
| UI | Material 3 + 自建设计系统 | 深蓝夜色 #0B1020 × 极光青 #00D4FF × 渐变主按钮 |

详细架构与开发思路见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。

## 开发者文档（先读这些）

| 文件 | 内容 |
|---|---|
| [AGENTS.md](AGENTS.md) | ★ AI 代理作业手册：安全红线、已知的坑、缺陷台账、验收基线、DoD |
| [docs/architecture.md](docs/architecture.md) | ★ 分层与 `MediaProvider` 契约（按实际代码写） |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | 架构决策与踩坑实录 |
| [docs/decisions/](docs/decisions/README.md) | ADR：0002 纯 Dart MVP（现行）、0001（已废弃） |
| [docs/CHANGELOG-GUIDE.md](docs/CHANGELOG-GUIDE.md) | 变更日志写作法 |
| [docs/lessons/](docs/lessons/README.md) | 踩坑经验索引 |

## 常用门禁

```bash
flutter analyze                                   # 0 error / 0 warning
flutter test                                      # 25 例全绿
powershell -File scripts/check-secrets.ps1        # 敏感信息（可加 --staged）
powershell -File scripts/check-docs.ps1           # 必需文档 + Markdown 断链
python scripts/discover_oss.py --verify owner/repo # 引用开源前必核
```

> ⚠️ 门禁脚本是 **PowerShell 版**（本机 bash 在沙箱下不可执行）。
> `flutter analyze` 在只有 info 级问题时也返回退出码 1——**判定标准是输出里的
> "0 error / 0 warning"，不是退出码**。

## 约定速览

- 版本号唯一权威：`VERSION`；变更日志写作法见 [docs/CHANGELOG-GUIDE.md](docs/CHANGELOG-GUIDE.md)
- 提交信息：Conventional Commits；分支：`feat/` `fix/` `chore/` `docs/`
- 注释解释"为什么"，中文写清关键设计；日志中文、可读、脱敏
- 任何真实 Token / Cookie / 服务器地址 / 内网地址不得进提交
- **不要跑 `dart format`**（会改动 24/26 文件，制造数千行无关 diff）
- 已知缺陷与未实现功能见 [AGENTS.md](AGENTS.md) §7——**别把它们当成已完成**

## 开发环境

```bash
# 环境：Flutter SDK 3.35+ / Dart 3.9+ + Android SDK（API 24+）
#      + Go 1.2x（核心逻辑层，见下）+ Android NDK（交叉编译 .so 用）

# ★ 首次必做：本项目依赖 drift，而 drift_flutter 传递依赖的 objective_c
#   要求启用 Dart native assets（这是**全局 Flutter 设置**，不在仓库里）
flutter config --enable-native-assets

flutter pub get
flutter run                    # 调试运行（需连真机或模拟器）
flutter analyze && flutter test  # 提交前必过：0 error/0 warning + 测试全绿
```

**Go 核心逻辑层**（ADR 0004）：媒体规则、排序参数拼装等在 Go 侧实现，
编译为 `libcineflow_go.so` 经 FFI 调用。改动 `go/` 后需重新编译：

```bash
bash tool/build_go.sh          # 默认 arm64-v8a；产物进 android/app/src/main/jniLibs/
cd go && go test ./... && go vet ./...   # Go 侧 23 例单测（零 cgo 依赖，无需 NDK）
```

> `.so` 已入库（`.gitattributes` 标为 `binary`，防止行尾转换破坏 ELF）。
> **只改 Dart 时不需要 Go 工具链**——`GoCore.tryLoad()` 失败会降级到纯 Dart 路径。

真机调试与自动化验证手法（含 `adb` 坐标陷阱、断网验降级、FFI/SQLite 坑）见
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) 与 [AGENTS.md](AGENTS.md) §6。

## 目录结构

```
lib/
├── main.dart               # 入口 + 会话门控（自动登录）
├── core/                   # 设计系统（色彩令牌/渐变/Logo）+ 工具
├── data/                   # 数据层
│   ├── media_provider.dart # 统一媒体源抽象（115 网盘预留位）
│   ├── emby_provider.dart  # Emby REST 实现
│   ├── models.dart         # 防御式解析模型（字段缺失是常态）
│   ├── session_store.dart  # 凭据/服务器/偏好安全存储
│   ├── home_repository.dart# 首页聚合（单区块失败不拖垮整页）
│   └── douban/             # 豆瓣客户端（榜单/搜索/详情 + 图床防盗链）
├── state/                  # riverpod providers（会话/首页/豆瓣）
├── pages/                  # 登录/首页/媒体库/详情/排行榜/搜索/我的
├── player/                 # 播放器（media_kit + 自绘控制层）
└── widgets/                # 公共卡片组件 / 豆瓣详情弹层
```

## 开源依赖

本项目通过包管理器直接依赖若干开源软件包（清单见 `pubspec.yaml` / `go.mod`），
**未合并任何第三方源码**；依赖与数据来源声明见 [NOTICE](NOTICE)。

## 路线图

- [ ] 转码播放（PlaybackInfo TranscodingUrl 分支 + 画质码率切换）
- [ ] 下载管理（离线缓存 + 存储占用统计）
- [ ] 投屏（DLNA / Chromecast）
- [ ] 弹幕（弹弹play 数据源）
- [ ] 平板 / TV 布局（侧栏 + 焦点引擎）
- [ ] 115 网盘 Provider（统一媒体源抽象层已预留）

## 免责声明

本项目仅供学习与个人使用。Emby 是 Emby Corp. 的商标，豆瓣数据来自其公开页面接口，
本项目与两者均无 affiliation。请遵守目标服务器的服务条款，控制请求频率。

## License

[Apache License 2.0](LICENSE) © 2026 CineFlow contributors

第三方依赖与借鉴来源的声明见 [NOTICE](NOTICE)。
