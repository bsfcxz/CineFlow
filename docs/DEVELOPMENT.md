# CineFlow 开发思路与技术栈

> 面向开发者的架构说明与决策记录。产品视角见 [README](../README.md)，AI 代理指引见 [AGENTS.md](../AGENTS.md)。

## 1. 设计思路

### 1.1 三条主线

1. **内容优先，控件退后** —— 所有页面以海报/背景图为主角，深蓝夜色 `#0B1020`
   为底、极光青 `#00D4FF` 只做强调（播放键、进度、选中态），主按钮用
   `青→蓝` 渐变 + 柔和辉光。设计令牌集中在 `lib/core/theme.dart`（`Cf` 抽象类），
   与《CineFlow UI 设计文档》2.1 节一一对应。
2. **真实数据优先** —— 每个页面直接驱动自 Emby REST API；没有可用的真实接口时
   才用占位（如跳过片头用章节名匹配）。UI 不允许出现"假数据驱动的功能"。
3. **抽象层预留** —— 计划书定义的「统一媒体源抽象层」在代码里就是
   `MediaProvider` 接口：UI 只依赖它。当前实现 `EmbyProvider`；
   未来 115 网盘 `Pan115Provider` 落地时 UI 零改动。

### 1.2 架构：轻量分层 + 单向数据流

```
UI (pages/player/widgets)
   │  watch / read
   ▼
riverpod providers (state/)
   │  FutureProvider / AsyncNotifier
   ▼
MediaProvider 抽象  ──►  EmbyProvider (data/)  ──►  Emby Server REST
                  └─►  (Pan115Provider 预留)     豆瓣 rexxar API (douban/)
   ▼
SessionStore (flutter_secure_storage)
```

选型理由：

- **riverpod 而非 setState/BLoC**：会话是全局异步单例（`AsyncNotifier` 启动恢复
  持久化会话），页面间派生（`embyApiProvider` 由会话派生 API 实例）用 provider
  图表达最自然；未引入代码生成，控制复杂度。
- **dio 拦截器承担协议细节**：`X-Emby-Authorization`（Client/Device/DeviceId/Version）
  与 `X-Emby-Token` 双头在拦截器统一注入，业务代码只见 REST 语义。
- **media_kit (libmpv) 而非 video_player**：Emby 库里 MKV/HEVC/DV/PGS 常见，
  ExoPlayer 格式面不够；libmpv 全格式 + 音轨/字幕/倍速原生可控。
- **feature 路由用 Navigator 而非 go_router**：当前 8 页 + 全屏推入的导航足够简单，
  先少一个依赖；深度链接需求出现时再迁移（成本可控）。

### 1.3 会话与凭据

- 登录 `POST /Users/AuthenticateByName`，凭据与 AccessToken 存
  `flutter_secure_storage`（Android Keystore）。
- 设备 ID 首启生成 UUID v4 持久化——Emby 用它识别设备与会话。
- 根级 `SessionGate`：启动时恢复会话 → 直接进主框架；未登录 → 登录页。
  登录成功顺带把服务器写入「已存服务器」列表（下次一键回填）。

## 2. 关键实现决策

### 2.1 Emby 协议：以实测为准，不以文档为准

本项目 curl 实测锁定的行为（均在代码注释标注）：

| 现象 | 对策 |
|---|---|
| 认证头缺 `Version` → 服务端 500 | `authHeader` 恒定带 `Version` |
| `/Latest` 返回**裸数组** | 解析兼容 map/List 两种形状 |
| `IncludeItemTypes` 服务端可能无视 | 客户端 `isPlayable` 复筛 |
| Items/搜索服务端过滤不可信 | 客户端类型/收藏等二次过滤 |
| Similar 路径不带 `/Users/{uid}`（带则 404） | 用 `/Items/{id}/Similar?userId=` |
| 收藏/看过 toggle 路径 | `POST /emby/Users/{uid}/FavoriteItems/{id}`（取消加 `/Delete`）、`PlayedItems` 同构 |
| 多版本/音轨选择 | `PlaybackInfo` → MediaSources[0]，直链 `static=true` |

### 2.2 首页聚合：单区块失败不拖垮整页

`HomeRepository.fetch` 并发拉取 Latest/Resume/Collections，单个区块异常吞掉并
降级为空列表（教训：一个分面挂掉不能拖垮整块面板）。
轮播数据 = Latest 中有背景图的条目，无真实背景时退化为渐变占位。

**但降级不等于掩盖**（2026-10 补）：四个区块**全失败**时把首个错误放进
`HomeData.fatalError`，由 UI 显示错误页 + 重试。否则网络断开时用户看到的是
"空首页"，会误以为自己的媒体库是空的。此前 `/Latest` 是最外层裸 await
（失败整页错误）而 resume/collections 有 try，属于典型的降级不一致。

媒体库同理：`_reload` 失败时保留 `_error`，空列表时优先渲染错误页而不是
"该库暂无内容"。两者的共同原则：**「加载失败」与「真的没有内容」必须可区分**。

### 2.3 模型层：防御式解析

Emby 服务器版本繁多，字段缺失/为空是常态（`PlayedPercentage` 可能为 null、
电影/剧集榜单条目形状不同、人物字段是 `{name: xx}` 对象数组……）。
`models.dart` 全部手动 `fromJson`，null 安全 + 兜底推算
（进度 = PlayedPercentage ?? PositionTicks/RunTimeTicks）。

### 2.4 播放器：把「像原生播放器」做进手势层

- **控制层自绘**：`media_kit_video` 的 `NoVideoControls` 关掉默认 UI，
  控制层 = 顶栏(渐变) + 底部(进度条+控制行+中央三键) + 浮层，全部按原型样式。
- **进度条**：自绘 `Stack`（底轨/缓冲段/渐变播放段/**真实章节刻度**/发光手柄），
  拖拽用 `LayoutBuilder` + 手势，不引第三方进度条组件。
- **手势分区**：单击=显隐；双击按横向三分区=-10s/播放暂停/+10s；长按=2.5x 松开恢复；
  竖滑按左右半屏=亮度(`screen_brightness` 应用级)/音量(mpv volume)，
  反馈用居中 flash 覆盖层（650ms 自动消失）。
- **跳过片头**：Emby 无服务端片头检测，
  退而求其次按章节名匹配 `片头/intro/opening`，取该章节区间；
  偏好开启时到点自动 seek，关闭时显示浮钮手动跳。
- **进度上报**：起播 `Sessions/Playing`，每 10s `Progress`，退出/换集 `Stopped`；
  fire-and-forget（`unawaited` + 吞错），绝不阻塞 UI。
- **播放策略**：直连原文件优先；直连失败自动切换
  `master.m3u8` HLS 转码兜底（每次播放只自动降级一次，避免循环）；
  起播后 30s 内采样缓冲水位，持续 <4s 触发「切换转码」提示卡。
  转码 URL = Emby 标准 `master.m3u8`（h264/aac 1080p 限制），libmpv 原生可播。
- **换集弹幕**：`_playEpisode` 成功后必须重载弹幕——换集沿用旧弹幕会导致
  时间轴完全错位（曾为此修过一个真 bug）。
  （起播上报曾长期缺失——`reportPlaybackStart` 有实现无调用，2026-10 已修复并真机验证：
  起播 8s 时服务器会话即带 `PositionTicks`，而 Progress 周期为 10s，故该会话只能来自 Start。）
- **多版本**：`PlaybackInfo` 的 `MediaSources[]` 即多版本列表。实测该端点**始终返回全部
  MediaSources**（传 `MediaSourceId` 也只作参考），因此客户端必须按 id 自行复选；
  详情页「版本」chips 的选择经 `openPlayer(mediaSourceId:)` 透传到 `resolvePlayback`。
- **转码**：**当前未实现**。实测本服务器（Emby 4.10.0.40 免费版）不具备转码能力：
  带 DeviceProfile 的 `PlaybackInfo` POST 返回 `SupportsTranscoding=false` 且无
  `TranscodingUrl`；`master.m3u8` 虽返回 200，但播放列表 `CODECS` 仍是源编码（hvc1），
  即服务端只重封装、未真正转码。接入支持转码的服务器时需重新 curl 实测后再实现。
- **生命周期坑**：播放中在 dispose 里同步 `_player.dispose()` 会原生崩溃
  （实测 SIGSEGV 闪退）。解法 = `PopScope` 拦截返回先上报 Stop + pause，
  dispose 里延迟 300ms 异步销毁；同时恢复应用内亮度与竖屏方向。

### 2.5 豆瓣接入：公开接口 + 防盗链

- `m.douban.com/rexxar/api/v2` 公开接口，**必须带移动端 UA + Referer**（否则 418）。
- 图床 `img*.doubanio.com` 防盗链更严：Flutter `Image.network` 即使带 headers
  也 418（默认 UA 策略差异），因此 `DoubanImage` 组件用 dio 显式带双头拉字节 +
  进程内字节缓存。
- 榜单/搜索/详情缓存走 **SQLite（drift）**：TTL 在**写入时**固化进 `expires_at` 列，
  过期判断在 SQL 里完成（榜单 6h / 详情 24h）。此前的 `MemoryDoubanCache`
  忽略了 ttl 且不落盘（缺陷 §7.4），**已修复**。
- 调用方自律限频（榜单一次 25 条不分页）。
- 榜单条目 id 是豆瓣的，与本地库无关——点条目开完整详情弹层，
  主按钮「在媒体库中搜索」是找到片源的直线动线。

### 2.6 媒体库排序：方向必须由客户端显式指定

`/Users/{uid}/Items` 的 `SortBy`/`SortOrder` 有两个反直觉之处，均已实测确认：

1. **方向不能省**：本服务器 `SortBy=DateCreated&SortOrder=Ascending` 返回的是**最旧**的条目，
   想要"最近添加"必须显式传 `Descending`。曾因 `SortOrder` 被硬编码为 `Ascending`，
   导致媒体库排序看起来"点了没反应"，实际是方向反了。
2. **支持多字段**：`SortBy`/`SortOrder` 都是逗号分隔数组
   （如 `SortBy=DateCreated,SortName&SortOrder=Descending,Ascending`）。
   本仓库给主排序键追加 `SortName` 作次级键，避免同值条目在翻页时顺序抖动。

方向取值与实测归纳一致：
`title→asc`、`rating→desc`、`addedAt→desc`。实现见 `LibraryPage.sortOptions`
（public static，便于单元测试断言——「点了没反应」型缺陷静态分析发现不了）。

### 2.7 播放偏好：default_rate 的读写闭环

`cf_pref_default_rate` 曾经"有读无写"——`player_page` 起播时读它，但全项目没有写入入口，
偏好永远停留在默认值。现补上播放设置抽屉的「默认倍速（下次起播）」组，
并把它与「播放速度」区分开：**前者只影响下次起播，后者改当前播放**。
`1.0x` 存空串（等于清除偏好），编解码由 `PlayerPage.parseDefaultRate/encodeDefaultRate` 负责。

## 3. 踩坑实录（节选）

1. **Emby 认证 500**：同一请求 curl（带 Version）200、App（缺 Version）500。
   官方 SDK 都带 Version，补上即愈——协议头要逐字段对齐官方客户端。
2. **Series 的 `IsFolder=true`**：把「IsFolder → 文件夹浏览」判断放在最前，
   导致点剧集进了个空白浏览页。文件夹浏览只认 `BoxSet`。
3. **豆瓣图床 418/403**：带 Referer 不够，UA 也必须是浏览器串；
   Flutter 图片加载器的默认 UA `Dart/x.x` 会被拒——必须整请求替换。
4. **libmpv 播放中 dispose 崩溃**：`Player.dispose()` 必须发生在路由销毁帧之外。
5. **Container 不支持负 margin**：海报悬浮效果用 `Transform.translate`。
6. **横屏 adb 自动化**：`input tap` 在横屏下走竖屏坐标系
   （lx = W - py, ly = px），自动化测试需要换算。

## 4. 质量约定

- `flutter analyze` 保持零 error/warning；第三方引入的代码允许少量 info。
- 冒烟测试：登录页渲染（`test/widget_test.dart`，FakeStore 注入隔离平台通道）。
- 每个里程碑真机（小米 1080×2400）走通：登录 → 浏览 → 详情 → 播放 → 退出存活。
- 协议交互先 curl 锁定响应形状，再写 Dart 解析；新增端点在
  `emby_provider.dart` 注释里记录实测结论。

## 5. 后续方向

- 转码分支：`PlaybackInfo` 的 `TranscodingUrl` + 画质码率选择（抽屉里已有 UI 位）
- 下载管理：离线缓存 + 存储占用（原型已有设计）
- 弹幕：弹弹play 数据源 + canvas 弹幕引擎
- 平板/TV：72px 图标侧栏 / 焦点引擎（原型已定义三端导航策略）
- 主题色切换：设计系统从 `const` 令牌迁移为运行时注入（涉及全组件，独立里程碑）
