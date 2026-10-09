# CineFlow 全流程技术与实现细节

> **本文档回答一个问题：这个 App 从冷启动到播放一集剧，中间到底发生了什么。**
>
> **版本基线**：`0.3.2+4`（本轮修复后代码；**注意**：已发布的 v0.3.2 包有已知缺陷，见 §0.2）
>
> **写作纪律**：所有行号、通道名、参数值、耗时均**取自代码或实测**，不凭记忆。
> 标注（实测）的来自真机日志、`dumpsys` 或产物字节分析。未证实的写"未验证"。
>
> **文档分工**：
> · 本文 —— **全流程串联**（一次播放的完整链路 + 关键技术决策）
> · [`DUAL-KERNEL.md`](DUAL-KERNEL.md) —— 双内核架构说明书
> · [`DUAL-KERNEL-OPTIMIZATION.md`](DUAL-KERNEL-OPTIMIZATION.md) —— 为什么这么设计 + 还能优化什么
> · [`AUDIT-2026-10-09.md`](AUDIT-2026-10-09.md) —— 代码审计与修复记录
> · [`AGENTS.md`](../AGENTS.md) —— 作业手册（坑、缺陷台账、验收基线）

---

## 0. 两个必须先知道的事

### 0.1 ★ 默认播放页 = 新页（`PlayerFlowPage`）

```dart
// lib/player/player_flow_page.dart
const useNewPlayerUi =
    bool.fromEnvironment('CF_NEW_PLAYER', defaultValue: true);   // ← 默认 true
```

| 路径 | 条件 | 说明 |
|---|---|---|
| **新页** `PlayerFlowPage`（2209 行）| **默认** | 双内核 / 会话层 / HDR / WakeLock / 音量系统通道 |
| 旧页 `PlayerPage`（2816 行）| `--dart-define=CF_NEW_PLAYER=false` | **仅应急回退**，正常不传 |

⚠️ **回退开关只用于应急**。它存在的原因是：若线上发现新页阻塞缺陷，
能一键回退而不必改代码-重新审查-再构建。
待新页经过若干版本验证后，应连同旧页一起删除（那时这个编译期开关也随之消失）。

### 0.2 ★ 已发布的 v0.3.2 是**旧页**（事故记录，必读）

**这是本仓库最有价值的一课**，理解它能避免重犯。

| 包 | `libapp.so` 里编进去的页面 |
|---|---|
| 本地构建（传了 flag）| 新页 |
| **已发布的 v0.3.2**（CI 未传）| **旧页** |
| **本轮修复后**（CI 命令、无 flag）| **新页 ✅** |

**根因**：`bool.fromEnvironment` 是**编译期**常量，而发布链路四个脚本
（`release.yml` / `ci.yml` / `tool/build_apk.sh` / `tool/build_apk.bat`）
**都没传** `--dart-define=CF_NEW_PLAYER` ⇒ 常量折叠成 `false`
⇒ 新页被 **tree-shaking 删掉**。

**取证方式**（产物字节级，方法已自证有效）：两页各有独有字符串，
Dart AOT 以 **UTF-16LE** 编进 `lib/arm64-v8a/libapp.so`，扫 APK 得：
```
已发布 v0.3.2   旧页串 6/6   新页串 0/7
修复后（无 flag）旧页串 0/6   新页串 6/8
```

**修法为什么不只是"给 CI 补 flag"**：
补 flag 只修**这一次**。真正的问题是"**编译期开关 + 默认值指向旧路径**"这个组合 ——
任何人（含未来的我）只要忘了传，就会**静默**发布一个功能缺失的包，
**而本地测试全绿**（因为本地总记得传）。⇒ 翻转默认值，让**默认路径即正确路径**。

**连带教训**：此前所有真机验证（音量 8/8、会话层 7/7、唤醒锁 5/5）
**全部跑在"传了 flag 的本地包"上** —— 那不是发布给用户的包。
⇒ **"真机验证过"对发布物不成立**，除非验证的是**从 Release 下载的包**。

---

## 1. 技术栈总览（实测版本）

| 层 | 选型 | 版本 | 说明 |
|---|---|---|---|
| UI | Flutter + Material 3 | **3.47.5 stable** | Dart SDK `^3.13.4` |
| 状态管理 | flutter_riverpod | **3.x** | 计划书写 2.x |
| 路由 | go_router | ADR 0005 | 路由表 `lib/core/router.dart` |
| 网络 | dio | 5.x | 拦截器注入认证头 |
| 本地库 | drift + sqlite3 | **drift 2.31.x / sqlite3 2.x** | 钉死版本（3.x 需 native assets）|
| 凭据 | flutter_secure_storage | — | Android Keystore |
| **播放内核** | **原生 mpv**（自持 `libmpv.so`）| **v0.36.0-549-g78d43740f5** | 非插件，见 §4 |
| **第二内核** | **Media3 / ExoPlayer** | **1.4.1** | `media3-exoplayer` + `media3-session` |
| **Go 核心层** | Go + FFI | Go 1.27.0 | 零 cgo，编译为 `libcineflow_go.so` |
| 原生桥 | Kotlin + JNI | NDK 27/28 | 10 文件 / 2345 行 |

**代码规模（本轮实测）**：
Dart `lib/` **98 文件 32715 行** · 测试 **65 文件 13531 行** ·
Go 26 文件 5815 行 · Kotlin 10 文件 2345 行

**播放器分层行数**（理解维护成本）：
```
player_flow_page.dart                  2209   ← 宿主/逻辑（默认页）
player_page.dart                       2816   ← 旧页（应急回退）
presentation/player_ui_page.dart        676   ← UI 装配
presentation/widgets/*.dart            ~2500  ← 组件
native/native_kernel.dart               514   ← mpv 内核
media3/media3_kernel.dart               303   ← Media3 内核
kernel_auto_select.dart                 367   ← 内核选择（纯函数）
```

---

## 2. 冷启动链路

### 2.1 启动顺序（`lib/main.dart`）

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();   // ← 必须先于任何插件调用
  final themeIdx = int.tryParse(await SessionStore().getPref('theme_index') ?? '') ?? 0;
  final go = GoCore.tryLoad();                 // ← FFI 加载，失败可降级
  if (go != null) {
    final ping = GoCore.ping();                // 自检
    final sort = go.sortParams('DateCreated');
    final norm = go.normalizeLatest([...]);
  }
  final container = ProviderContainer();
  await container...;                          // 预热 provider
  runApp(UncontrolledProviderScope(...));
}
```

**Go 层自检必须跑**：Go 编译器会**合并字符串常量** ⇒
**无法用 `strings`/grep 扫 `.so` 确认某方法是否编进去**（实测：
`media.sortParams` 扫不到但运行正常）。**唯一可靠的验证是运行时调用。**

启动后日志（实测）：
```
I/flutter : [GoCore] 已加载，ping={pong: cineflow-go, version: 1}
I/flutter : [DB] 就绪，清理过期缓存 0 条，现有 1 条 / 30442 字符
```

### 2.2 不阻塞首帧的后台任务

`_CineFlowAppState.build` 里以 `_dbChecked` 为门只跑一次，
清缓存**故意不 await** —— 缓存清理不该拖慢首帧。

### 2.3 进播放页的分段耗时（实测，3 次采样中位）

| 阶段 | 耗时 | 性质 |
|---|---|---|
| `prefRead` | **245 ms** | 读偏好（Keystore 解密）|
| `kernelCreate` + `texture` | 4 ms | |
| `resolve` | 33 ms | Emby 取直链 |
| `open` | 36 ms | |
| `seek` + `rate` | 8 ms | |
| **Dart 命令链合计** | **314 ms** | |

---

## 3. 数据层：Emby 接入

### 3.1 分层（架构承诺 §5.1）

```
UI（pages/）
  ↓ 只依赖抽象
MediaProvider（lib/data/media_provider.dart）
  ↓ 实现
EmbyProvider（lib/data/emby_provider.dart）
```

**为什么**：多源可插拔。115 网盘走**独立页面**（播放模型是文件夹树 + `pick_code`，
与 Emby 的库/季/集根本不同，强行统一会造出无意义概念 —— ADR 0007）。

⚠️ **已知未收敛**：6 个 `pages/` 文件仍直接 `import 'emby_provider.dart'`
（主要为 `MediaException`），见缺陷 §7.13。

### 3.2 `MediaProvider` 接口全清单

```dart
Future<List<MediaView>>    getViews();
Future<List<MediaItem>>    getLatest({int limit});
Future<List<MediaItem>>    getResume({int limit});
String                     imageUrl(String itemId, ...);
Future<List<MediaItem>>    search(String keyword, {int limit});
Future<ItemPage>           getItems({...});          // 服务端分页/筛选/排序
Future<MediaItemDetail>    getItemDetail(String itemId);
Future<List<String>>       getGenres({String? parentId});
Future<(int, int)?>        getYearRange({...});
Future<List<MediaItem>>    getSeasons(String seriesId);
Future<List<MediaItem>>    getEpisodes(String seriesId, String seasonId);
Future<List<MediaItem>>    getNextUp(String seriesId, {int limit = 1});
Future<List<MediaItem>>    getSimilar(String itemId);
Future<List<MediaChapter>> getChapters(String itemId);
Future<bool>               toggleFavorite(String itemId, {required bool favorite});
Future<bool>               togglePlayed(String itemId, {required bool played});
Future<PlaybackLaunch>     resolvePlayback(String itemId, {String? mediaSourceId});
void                       reportPlaybackStart(...);      // 不 await
void                       reportPlaybackProgress(...);   // 不 await
void                       reportPlaybackStop(...);       // 不 await
void                       reportItemProgress({...});
```

### 3.3 实际用到的 Emby 端点（代码实测）

| 用途 | 端点 |
|---|---|
| 登录 | `POST /Users/AuthenticateByName` |
| 媒体库视图 | `GET /Users/{uid}/Views` |
| 最新添加 | `GET /Users/{uid}/Items/Latest` |
| 继续观看 | `GET /Users/{uid}/Items/Resume` |
| 列表/筛选/排序 | `GET /Users/{uid}/Items` |
| 详情 | `GET /Users/{uid}/Items/{id}` |
| 类型 / 年份 | `GET /Genres` · `/Users/{uid}/Items`（年份聚合）|
| 季 / 集 | `GET /Shows/{id}/Seasons` · `/Shows/{id}/Episodes` |
| 下一集 | `GET /Shows/NextUp` |
| 相似 | `GET /Items/{id}/Similar?userId=` |
| 收藏 toggle | `POST /emby/Users/{uid}/FavoriteItems/{id}`（取消加 `/Delete`）|
| 看过 toggle | `POST /emby/Users/{uid}/PlayedItems/{id}`（同上）|
| **播放信息** | `GET /Items/{id}/PlaybackInfo?userId=` |
| 进度上报 | `POST /Sessions/Playing` · `/Playing/Progress` · `/Playing/Stopped` |
| 用户数据 | `POST /Users/{uid}/Items/{id}/UserData` |

### 3.4 ★ 认证头（缺一段就 500）

```dart
// emby_provider.dart:42
return token == null ? base : '$base, Token="$token"';
```
`base` 含四段，**缺 `Version` 服务端直接 500**（实测踩过）：
```
MediaBrowser Client="CineFlow", Device="Android", DeviceId="<uuid>", Version="..."
```

### 3.5 实测出的协议坑（都写进代码注释）

| 现象 | 真相 |
|---|---|
| `/Latest` 返回**裸数组** | 解析要兼容 map/List 两种形状 |
| 服务端**无视类型筛选** | 必须客户端 `isPlayable` 复筛 |
| `Series` 也是 `IsFolder=true` | **不能**用 `IsFolder` 判断剧集 |
| Similar 带 `/Users/{uid}` → **404** | 路径是 `/Items/{id}/Similar?userId=` |
| 这台服务器**没有** `/Favorites/` 路径 | 必须用 `/emby/...` 前缀 |
| 指定 `MediaSourceId` 后**仍返回全部** MediaSources | 客户端按 id 复选 |
| **转码不可用** | 实测判定本服务器不支持，故只做直连 |

### 3.6 章节数据的来源（本轮新增用到的）

```dart
// PlaybackLaunch.chapters —— 服务端把章节放在 MediaSource.Chapters 里
// 故**不需要**再单独发一次 getChapters 请求（省一次往返）
```

```dart
class MediaChapter {
  final String name;
  final int startPositionTicks;
  final String? markerType;      // Chapter | IntroStart | IntroEnd | CreditsStart
  double get seconds => startPositionTicks / 10000000;
  bool get isIntroStart   => markerType == 'IntroStart';
  bool get isIntroEnd     => markerType == 'IntroEnd';
  bool get isCreditsStart => markerType == 'CreditsStart';
}
```

**★ `markerType` 是 Emby 的原生片头检测** ——
旧注释曾写"Emby 无原生片头检测，用名称匹配"，**那是错的**。
实测本服务器章节为 `Chapter, IntroStart, IntroEnd, Chapter, …`。

**为什么必须用 markerType 而不是猜章节名**：
· 叫"主题曲"/"OP"/"序章" → 名称匹配**识别不到**
· 叫"片头曲欣赏"的普通章节 → 会被**误跳**

---

## 4. 播放流程：从点剧集到出画面

### 4.1 总链路

```
用户点「继续观看」卡片
  ↓
route.push('/play/:id', extra: PlayerRouteArgs)
  ↓ go_router → player_routes.playerRoute()
  ↓ if (useNewPlayerUi) → PlayerFlowPage     ← ★ 默认走这里
  ↓
_boot() / _startEpisode()
    ① 读偏好（prefRead 245ms）—— 含内核偏好 + skip_intro_auto
    ② KernelFactory.create() → 选内核（见 §4.2）
    ③ ensureTexture() → Flutter 纹理
    ④ provider.resolvePlayback() → 直链 + **章节**（resolve 33ms）
    ⑤ 章节/片头区间就绪（见 §4.5）
    ⑥ kernel.open(url)（open 36ms）
    ⑦ kernel.seek(续播点) + setRate（8ms）
  ↓
mpv / Media3 开始解码
  ↓ DEMUX_DONE（容器探测完成）
  ↓ FIRST_FRAME（首帧上屏）
  ↓
_Tick（position 限流 250ms）→ 更新进度条
  ↓
核对：自动跳过片头 / 章节刻度 / 会话同步 / 唤醒锁
```

### 4.2 内核选择（`kernel_auto_select.dart`，**顺序即优先级**）

**决策是纯函数**（无状态、无 IO）⇒ 每条规则可精确断言。

| 优先级 | 条件 | 选谁 | 理由（代码原文）|
|---|---|---|---|
| **0** | `isHdr`（含 DV）| **mpv** | 设备 MediaCodec 常只解 DV 基础层（画面发灰）|
| 1 | mpv 独占容器 | mpv | RMVB/WMV/ASF/VOB/FLV |
| 2 | `isHlsStream` | **Media3** | 分片续播、码率切换更成熟 |
| 3 | `h >= 2000` | **Media3** | 高分辨率走系统硬解能效更好 |
| 4 | 有外挂字幕 | mpv | GBK/BIG5、ASS 特效、字体回退更好 |
| 5 | 其余 | mpv | 格式覆盖最全；信息不足时保守选 mpv |

> ⚠️ **规则 1 在代码里排在规则 2 之前** —— 冷门格式即便走 HLS，
> **播放优先于体验**。
> ⚠️ **`videoRange == null ⇒ isHdr = false`** —— 否则会把所有 4K 推给 mpv，
> 反而伤害"能效更好的硬解通路"。

### 4.3 双内核共用一个渲染出口

```
        ┌─────────── Flutter 纹理（Texture widget）───────────┐
   NativeKernel（mpv）                      Media3Kernel（ExoPlayer）
   libmpv.so + JNI                          media3-exoplayer
   attachSurface → wid                      SurfaceTexture
        └────────── 同一条 Dart UI 代码路径 ──────────────────┘
```

**为什么统一纹理**：纹理是**普通 Flutter 图层** ⇒
弹幕 `CustomPainter`、手势、控制层**直接叠在上面**；
且两内核输出方式一致 ⇒ **Dart 渲染代码无需分支**。

### 4.4 Dart ↔ Kotlin ↔ C 契约（实测通道名，双侧核对）

| 层 | MethodChannel | EventChannel |
|---|---|---|
| mpv 内核 | `cineflow/player` | `cineflow/player/events` |
| Media3 内核 | `cineflow/media3` | `cineflow/media3/events` |
| 媒体会话 | `cineflow/session` | — |
| 通知栏 | `com.cineflow.app/notification` | — |
| 亮度 | `com.cineflow.app/brightness` | — |
| 音量 | `com.cineflow.app/volume` | `com.cineflow.app/volume/events` |
| 唤醒锁 | `com.cineflow.app/wakelock` | — |

### 4.5 ★ 章节刻度与跳过片头（本轮新增）

#### 章节刻度

```
服务端 PlaybackInfo.MediaSource.Chapters
  ↓ resolvePlayback 解析
PlaybackLaunch.chapters（List<MediaChapter>）
  ↓ 宿主 _startEpisode 存入 _chapters（优先读 launch，缺失才回退单独查）
  ↓ slots: chapters: [for (final c in _chapters) c.seconds]
PlayerPageSlots.chapters（List<double>，**秒**）
  ↓ player_ui_page: chapters: widget.slots.chapters
PlayerBottomBar.chapters → PlayerProgressBar.chapters + duration
  ↓ duration > 0 时换算成 0–1
进度条 Stack 里画刻度（跳过首尾 0.002/0.998）
```

**★ 为什么传秒而不是 0–1 分数**：
分数依赖 `duration`，而 `duration` 在起播早期是 **0**（容器还没探测完）——
若由调用方换算，就会把"duration 未知"和"章节在第 0 秒"混为一谈。
传原值 + 在进度条内现算，**换算只发生在一个地方**。

**★ `duration <= 0` 时不画**：否则除法得 Infinity/NaN，画出错位的线或抛异常。

**真机像素级确证**（实测）：
```
刻度条数 = 11
轨道高度 = 8 px（≈2.9 dp，匹配 progressTrackHeight = 3）
刻度高度 = 8 px（与轨道**等高**，符合 Positioned(top:0,bottom:0) 的写法）
```

#### 跳过片头

```dart
// ① 判定片头区间 —— **优先服务端 MarkerType**
static (double, double)? _detectIntro(List<MediaChapter> ch) {
  for (var i = 0; i < ch.length; i++) {
    if (!ch[i].isIntroStart) continue;
    final start = ch[i].seconds;
    for (var j = i + 1; j < ch.length; j++) {
      if (ch[j].isIntroEnd) { /* 配对成功 */ }
    }
    // 有 IntroStart 却没配对的 IntroEnd：用下一章起点兜底
  }
  // ② 兜底才是名称匹配（服务端未标记时）
}

// ③ 自动跳过 —— 挂在 stateStream（所有状态变化的汇聚点）
void _checkIntroSkip() {
  if (intro == null || _introSkipped || !_autoIntroSkip) return;
  if (pos >= intro.$1 && pos < intro.$2 - 1) {
    _introSkipped = true;                       // ★ 一集只跳一次
    unawaited(_kernel?.seek(Duration(seconds: intro.$2.toInt())));
    _flash('已跳过片头');
  }
}
```

**★ 三个容易漏的细节**：
1. **`_introSkipped` 只跳一次** —— 位置是 250ms 推一次的，不加门会**每 250ms 回跳**
2. **换集必须重置该标志** —— 否则只有第 1 集会跳（用户会以为坏了）
3. **偏好判据是 `!= '0'`（默认开）** —— 与旧页一致；
   写成 `== '1'` 会让老用户升级后**静默不再跳片头**

**★ 浮钮**：`Positioned(right:16, bottom:108)`，用 `Material` + `InkWell`
（涟漪反馈 + ≥48dp 命中区）；结束前 1 秒停止显示
（那时点了几乎没效果，留着会让人以为按钮坏了）。

### 4.6 ★ 会话层命令**回 Dart 执行**

| 方案 | 问题 |
|---|---|
| 会话层**直接**控制原生播放器 | ❌ **两个主** —— Dart 也控播放器，状态必然不同步 |
| **会话层把命令转发给 Dart** | ✅ 单一事实源 |

**★ 但这里踩了大坑**：会话命令曾接到 `PlaybackController.pause()` ——
结果是**纯状态机**（只翻标志位，内核收不到指令），**画面毫无变化**。
修法：**镜像页面的写法直调 `_kernel`**。

> **教训**：播放/暂停这类直达内核的原子操作，
> **不要想当然地套抽象，要读实际调用点**。

---

## 5. 原生层：mpv 集成

### 5.1 为什么不用 `PlatformView`

| 方案 | 结论 |
|---|---|
| `PlatformView` + `mpv_render_context` | ❌ 上游（mpv-android）**根本不用 render API** |
| **纹理**：`attachSurface → wid`，mpv 自建 EGL | ✅ 与 mpv-android 同款 |

### 5.2 ★ 顺序约束（错一步就黑屏）

```
createSurface → attachSurface → mpv_initialize
```
**`wid` 必须在 `mpv_initialize` 之前 `mpv_set_option`** —— 之后设置**不再生效**。

### 5.3 ★ `av_jni_set_java_vm` 必须注册（现象极误导）

不注册时：
```
✅ 解封装完全正常（logcat 能看到 h264/aac 全部轨道）
❌ [mpv/vo/gpu/android] No Java virtual machine has been registered
   → GPU 上下文初始化失败 → end-file error
```
⇒ **"能解析出轨道" ≠ "能播"**。

### 5.4 mpv 选项全清单（**31 项**，`PlayerChannel.kt` 实测）

| 类别 | 选项 |
|---|---|
| 视频输出 | `vo=gpu` · `gpu-context=android` · `opengl-es=yes` |
| 硬解 | `hwdec=mediacodec,mediacodec-copy` · `hwdec-codecs=h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1` |
| 音频输出 | `ao=audiotrack,opensles` |
| **HDR/DV** | `tone-mapping=bt.2390` · `tone-mapping-mode=auto` · `hdr-compute-peak=yes` · `target-peak=auto` · `gamut-mapping-mode=auto` · `target-prim=auto` |
| 流畅度 | `video-sync=display-resample` · `interpolation=yes` · `tscale=box` |
| 丢帧 | `framedrop=vo`（只允许渲染端丢，**解码器不丢完整帧**）|
| 音频 | `audio-buffer=0.5` |
| 缓冲 | `cache=yes` · `demuxer-max-bytes=128MiB` · `demuxer-max-back-bytes=64MiB` · `cache-secs=30` |
| **起播** | `demuxer-lavf-analyzeduration=1` · `demuxer-lavf-probesize=2097152` |
| 网络 | `network-timeout=15` |
| 其他 | `config=no` · `save-position-on-quit=no` · `idle=yes` · `force-window=no` |
| 字幕 | `sub-fonts-dir=/system/fonts` · `sub-font=sans-serif` · `sub-codepage=auto` |

**为什么 `analyzeduration=1`**：ffmpeg 默认 5 秒 —— 对网络源是**纯等待**。
实测起播 **9087 → 7584 ms**（−16.5%）。
⚠️ 代价：冷门容器探测准确率下降，遇"轨道识别不全"**先回调这一项**。

### 5.5 ★ 本构建没有的能力（别写进代码）

```
-Dlibplacebo=disabled -Dvulkan=disabled
```
⇒ **不存在**：`vo=gpu-next`、`target-colorspace-hint`、`vd-queue-*`
（对着 `libmpv.so` 字符串表逐个核实过 —— 加进去是**静默 no-op**）

### 5.6 生命周期：`dispose` 不能同步

```
退出走：先上报 Stop + pause → 延迟 ≥350ms 释放
```
`NativeKernel.dispose` 内部还会 `detachSurface` + **join 事件线程**
（事件线程必须先 join 再 `mpv_terminate_destroy`，否则退出必崩）。

---

## 6. 系统集成层（媒体会话）

### 6.1 四件事一次解决

| 能力 | 实现 |
|---|---|
| 通知栏控制 | `MediaSession` + **`media3-session`** 自带通知 |
| 蓝牙/耳机键 | `MediaSession`（系统按会话路由，**不要求 App 聚焦**）|
| 后台播放 | `MediaSessionService` 前台服务 |
| **音频焦点** | **自研** `AudioFocusManager`（Media3 **不代劳**）|

**★ 通知栏不贴的坑**：`MediaSession.Builder().build()` **只创建会话** ——
必须调 **`addSession(session)`**。
**最坑的是**：它**完全不影响媒体键**（那走 MediaButton 路径）
⇒ 现象是"**媒体键能用，但通知栏什么都没有**"，极易误判为权限问题。

### 6.2 三种失焦分开处理

| 类型 | 场景 | 做法 |
|---|---|---|
| `AUDIOFOCUS_LOSS` | 别的播放器永久接管 | **暂停**，不自动恢复 |
| `LOSS_TRANSIENT` | 来电、导航 | 暂停；焦点回来后**自动续播** |
| `LOSS_TRANSIENT_CAN_DUCK` | 通知音 | **不暂停**，压低音量 |

⇒ 把 `CAN_DUCK` 当 `TRANSIENT` = **每来一条通知视频都暂停一下**。

### 6.3 音量架构（单一事实源）

**问题**：旧实现手势改**内核音量** ⇒
· 按手机侧边键时 App 滑块**不动**（看起来像坏了）
· 两者**相乘**：系统 50% × 内核 50% = 实际 **25%**

**新架构**：手势/滑块/侧边键**全部**落到系统媒体音量；内核音量**恒定 unity**。

**★ 唯一例外：duck 必须走内核** —— 若 duck 改系统音量，
会把**用户手机的**媒体音量改小且**不自动恢复**。

**回环防护三层**（缺一即死循环）：
1. `VolumeService.set()` **先更新本地值再调原生**
2. 监听回调**按值去重**
3. `AudioController.syncFromSystem` **故意不调 `_emit()`**

### 6.4 唤醒锁（跟随"是否在播"）

挂在 `stateStream` 上（与 `_sessionSync` 同一汇聚点）——
挂到播放/暂停按钮会漏掉手势、自动连播、媒体键。

**播放中常亮；暂停允许熄屏**（用户可能在回消息/看弹幕）。
加 `_wakelock.enabled != s.playing` 判断，避免每次（250ms 一次的）
状态推送都做 MethodChannel 往返。

**真机验证**：熄屏超时设 15s、播放中等 20s ⇒ `mWakefulness` 仍 `Awake`。

---

## 7. Go 核心层

### 7.1 零 cgo 的分包（否则 `go test` 编不过）

```
go/internal/rpc       ← 纯业务，零 cgo
go/internal/media     ← 纯业务，零 cgo
go/internal/pan115    ← 115 协议
go/bridge.go          ← 唯一的 import "C"（C 边界薄包装）
```
含 cgo 的包在 `CGO_ENABLED=0`（本机默认）时 **`go test`/`go vet` 全部编不过**。

### 7.2 FFI 契约

「方法名 + JSON」C ABI（**与 Synurang 同构** —— 其生成器需 Rust + protoc，
本机没有；替换时只改 Go 侧转发，Dart 契约不变）：

```dart
GoCore.tryLoad()      // 失败返回 null，不崩
GoCore.ping()         // {pong: cineflow-go, version: 1}
GoCore.invokeAsync()  // ★ 独立 isolate（115 长轮询 30s，否则冻 UI）
```

**纪律**：`try/finally` 释放 `CineFlowCall` 指针；
Go 侧 `recover()` 不让 panic 穿过（会直接终止宿主进程）。

---

## 8. 弹幕系统

### 8.1 双源、双认证形态（**不可统一**）

| 源 | 认证 |
|---|---|
| 官方（弹弹play）| 请求头签名 `AppId+Timestamp+Path+AppSecret`（**无分隔符**）|
| 自建（danmu_api / 御坂）| **URL path token**，**不看任何认证头** |

⇒ 统一成一种必有一边 403。签名三处易错：Path **不含查询参数**、
拼接**无分隔符**、Timestamp 是 **UTC 秒级**。

### 8.2 ★ `p` 字段两种布局

| 形态 | 格式 | **颜色位置** |
|---|---|---|
| 弹弹play **原生 4 段** | `时间, 模式, 颜色, 发送者ID` | **index 2** |
| B站 **8 段** | `时间, 模式, 字号, 颜色, …` | **index 3** |

**按 8 段解析官方数据会把字号当颜色、颜色当发送者ID** ——
**弹幕颜色全错但不报错**。判别：段数 ≥8，或 `index2 ≤64 且 index3 >255`。

### 8.3 轨道分配（必须判"追尾"）

速度模型 `(屏宽+文本宽)/时长` ⇒ **宽弹幕更快**。
· 只判"前一条是否已离开" → 过保守，密集弹幕大量丢弃
· 只判"当前是否重叠" → 宽弹幕**追上并压过**窄弹幕

**正确两条**：① 前一条已完全进屏；② 追上时刻晚于它离开的时刻。
**默认给字幕留一行**（遮挡字幕比少一行弹幕更糟）。

### 8.4 其它实测坑

· **业务错误包在 HTTP 200 里** → 只看状态码会把"服务器内部错误"当"没有弹幕"
· **异步状态是 `pending`/`completed`/`failed`**，**没有 `done`**
· 自建服务未命中返回 **HTTP 404** —— 那是"没有弹幕"**不是错误**
· **凭据不入库**：用户填、存 `flutter_secure_storage`

---

## 9. 115 网盘

> ⚠️ 走**非公开 webapi 接口**（用户明确选择 115driver 路线），
> **有账号风控风险**（ADR 0007 记录并在登录页提示）。
> 状态：协议层 + 扫码登录 + 文件浏览 + 播放页落地；
> 真机**仅验证到"能拿到二维码"**（无真实账号，未联调真实播放）。

### 9.1 ★ UA 绑定（最容易静默失败）

**取直链时的 UA 必须与播放时逐字节一致** —— CDN 与取址 UA **强绑定**。
且取地址响应的 **`Set-Cookie`（`download_token`）必须合并进播放请求**。

两者都**不在 URL 里** ⇒ 只把 URL 交给播放器必然 **403**，
现象是"地址取到了但播不了"，**极难排查**。
⇒ `Pan115Playback` 把 **url 与 headers 绑在同一类型**，不给"只拿 URL"的机会。

### 9.2 ★ m115 不是对称加解密（别"修好"它）

> **全流程只有公开指数 e，没有私钥 d**。`Encode` 与 `Decode` 服务的是
> 两个相反方向，**共用 e 但不是彼此的逆**。`Decode(Encode(x,k),k)` **不还原原文**。

这是上游既定设计（签名式混淆，非保密方案）。
**若有人以为是 bug 并改成往返可逆，那才是引入 bug。**

### 9.3 限速（账号安全，不是性能优化）

全局 **2 请求/秒、严格串行**，限流放在 `do()` 里
（放各业务方法**必然会在新增方法时漏加**）。**绝不并发翻页。**

### 9.4 其它字段陷阱

| 陷阱 | 真相 |
|---|---|
| 文件 vs 目录 | 看 **`fid` 是否为空**，不是 `ico` |
| 字段类型 | 同一字段在不同条目上**可能不同** |
| 大整数 | 走 `json.Number` 保精度（可超 2^53）|
| `state` 字段 | 二维码体系是数字 `1`，webapi 是布尔 `true` |
| 错误码拼写 | `errno` 与 `errNo` **两种都用过** |
| 业务错误 | 全包在 **HTTP 200** 里 |
| 分页 | 必须用**服务端回显的 offset**，本地累加会**静默跳过内容** |
| 登录 | 必须轮询到 `status==2`（否则报错**与非法 uid 一样**）|

---

## 10. 构建与发布链路

### 10.1 版本号：三处一致

```
VERSION                    ← 唯一权威
pubspec.yaml   version: 0.3.2+4
lib/core/version.dart   const String kAppVersion = '0.3.2';
```
`tool/bump_version.ps1 -Version X.Y.Z` 一次改齐，`-Check` 校验。

### 10.2 构建命令

```bash
flutter build apk --release --split-per-abi \
  --obfuscate --split-debug-info=build/symbols
```
**`--split-per-abi` 是唯一能把 libmpv 按架构拆开的手段**：
三架构合并 91.6MB → arm64 约 39MB。
**不要传 `--dart-define=CF_NEW_PLAYER`**（默认已是新页；传了反而掩盖默认值是否正确）。

⚠️ **`build.gradle.kts` 里加 `ndk.abiFilters` 会与 splits 互斥导致构建失败**。

⚠️ **混淆符号表必须与 APK 成对保留** —— 没有它线上崩溃堆栈就是一堆 `a.b.c`。

### 10.3 签名

```kotlin
signingConfig = if (cfHasReleaseKey) signingConfigs.getByName("release")
                else signingConfigs.getByName("debug")   // CI 会拦 debug 签名
```
密钥在**仓库外**（`%USERPROFILE%/cineflow-keystore/` 或 `CF_KEY_PROPERTIES`）。
**实测证书**：`CN=CineFlow, OU=Mobile, O=CineFlow, C=CN`
SHA-256 `088fef287233ed59832f1bfa75d956b1d67286bc39e7021eab0e763981881245`

### 10.4 发布通道（`release.yml`）

```
push tag v*  →
  build-apk:  装 Flutter/Java → 还原 keystore → 校验 tag==VERSION
              → analyze + test → 构建三 ABI → 守卫(非 debug 签名)
              → 生成 checksums.txt → 上传 artifact
  publish:    environment: release   ← ★ 审批门（Required reviewers）
              → 守卫(目标 Release 尚不存在，只增不删)
              → 建草稿 + 上传 → 校验齐全后转正
```

**铁律 D1–D10**：**未经用户当轮明确审批，绝不打 tag、绝不创建/修改/删除任何 Release**；
上传**只增不删**（旧版本是用户回滚的唯一退路）。

### 10.5 覆盖率边界（必须知道）

| 手段 | 能覆盖 | **不能覆盖** |
|---|---|---|
| `flutter test`（885 例）| Dart 纯逻辑 | MethodChannel / JNI / 硬解 / 手势 / 布局 |
| `integration_test`（1 个）| Dart→Kotlin→JNI→libmpv 整链路 | 同上之外的一切 |
| 真机走查 | 手势 / 硬解 / 布局 | 需人工 |

⚠️ **`flutter test` 跑在桌面 VM 上，碰不到 MethodChannel 与 JNI** ——
**链路断了也照样全绿**。改了播放内核**必须**跑 integration_test。

⚠️ **门禁的"截图"判据会被熄屏骗过**：门禁曾报"release 包截图不可用"，
查实是设备 `mWakefulness=Asleep`（而已修的"暂停允许熄屏"正在生效）。
唤醒后截图 2024KB / 压缩比 799.9 正常。
⇒ 看到该跳过项时**先查屏幕状态**，别急着当成白屏缺陷。

---

## 11. 质量保障体系

### 11.1 一条命令跑完（退出码 0 才算过）

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check-dev.ps1
```
覆盖：静态分析 / 单测 / go vet / go test / 敏感信息 / 文档 / 版本号 /
产物完整性（ELF 头、ABI）/ **真机冒烟**（安装→启动→存活→Dart 日志→截图）。

**有跳过项时必须在汇报里列出"哪些没验证"**。

### 11.2 ★ 反自欺三原则（`AGENTS.md` §8.4）

**根因相同：验证手段本身没有被验证。危害比"没验证"更大** ——
测试是绿的、脚本是通过的，但**结论是错的**。

1. **断言不得被"注释/相邻代码"满足**
   ⇒ 断言前**先剥注释**；断言落在**必然会变的那一行**。
2. **替换/注入要用词边界，且长串优先**
   ⚠️ 实测：裸 `§7.1` 命中 `§7.10`/`§7.19` 的**前缀** ⇒ 制造 **17 处乱码**。
3. **数字必须来自实际输出，不得推算**
   ⚠️ 实测：台账写"859 例"，实际 **847** —— 按"两个文件共 19 例"**推算**。

> **一句话判据**：说"已验证"之前先问 ——
> **这个结果，有没有可能在我删掉真代码之后依然成立？**

### 11.3 ★ 本轮新增的两类实测教训（都是"同型陷阱"）

**① 同一串出现多处 ⇒ 断言只改一处仍为真**
反向注入 v1 只抓到 7/13 —— 因为断言用了裸 `contains()`，
而 `!= '0'` / `_tapCount` / `ui.isLocked` 在文件里**各有 2–4 处**。
收紧为"整行 + 带上下文"后升到 **19/19**。

**② 前缀陷阱**
`PlayerUi.chapterTick` 是 `PlayerUi.chapterTickWidth` 的**前缀** ⇒
裸串断言被另一处满足。**与 `§7.1` 吃掉 `§7.10` 完全同型。**

### 11.4 测量手段的有效性（哪些能用、哪些不能）

| 手段 | 对 Flutter 有效？ | 说明 |
|---|---|---|
| `dumpsys gfxinfo` | ❌ **无效** | 实测 `Total frames rendered: 0` —— Flutter 不经 `View.draw()` |
| `SurfaceFlinger --latency` | ❌ **无效** | BLAST 子层不记录 latency 环（全 0 或仅 1 行）|
| **`SurfaceFlinger --timestats`** | ✅ **有效** | 看 `jankyFrames` / `missedFrames` / `present2present` |
| `screencap` + 像素分析 | ✅ | 但**先确认屏幕是亮的**（`mWakefulness`）|
| APK 内 `libapp.so` 字符串扫描 | ✅ | **UTF-16LE**；探针要排除 `$` 插值 |

> ⚠️ 本仓库**曾用 `gfxinfo` 得到过对 Flutter 不可信的数字**
> （如"Janky 6/18 = 33.33%"很可能是某个原生 View 的残留样本）。

---

## 12. 全流程一页速查

```
┌─ 冷启动 ────────────────────────────────────────────┐
│ main() → ensureInitialized → 读主题 → GoCore.tryLoad │
│        → [GoCore]/[DB] 自检日志 → runApp             │
└──────────────────────┬───────────────────────────────┘
                       ↓
┌─ 路由（go_router）──────────────────────────────────┐
│ redirect 由 SessionGate 决定落点（登录页 or 首页）    │
└──────────────────────┬───────────────────────────────┘
                       ↓
┌─ 数据层 ────────────────────────────────────────────┐
│ UI → MediaProvider（抽象） → EmbyProvider → dio      │
│ 认证头四段（缺 Version → 500）                       │
└──────────────────────┬───────────────────────────────┘
                       ↓
┌─ 播放（/play/:id）──────────────────────────────────┐
│ playerRoute() → if (useNewPlayerUi)  ← 默认 true     │
│   → PlayerFlowPage（2209 行）                        │
│   · 旧页 PlayerPage 仅 --dart-define=false 回退       │
│ _boot/_startEpisode:                                 │
│   偏好 → 选内核 → 建纹理 → 取直链+章节 → 开片头判定   │
│   → open → seek → rate                               │
│ Dart 链 314ms ／ 点到出画面 7584ms                   │
└──────────────────────┬───────────────────────────────┘
                       ↓
┌─ 原生（双内核共用一个 Flutter 纹理）────────────────┐
│ mpv:  attachSurface→wid→initialize                   │
│       av_jni_set_java_vm 必须注册                     │
│       31 个选项（HDR/流畅度/缓冲/字幕）               │
│ Media3: ExoPlayer + media3-session                   │
│ 事件形状统一（Media3 迁就 mpv 字段名）                │
└──────────────────────┬───────────────────────────────┘
                       ↓
┌─ 播放中（都挂在 stateStream 这个汇聚点）─────────────┐
│ 章节刻度（11 条实测）／自动跳过片头（一集一次）        │
│ 会话同步（通知栏标题/进度）／唤醒锁（跟随 playing）   │
│ 音量→系统通道（duck 例外走内核）                     │
└──────────────────────┬───────────────────────────────┘
                       ↓
┌─ 质量与发布 ────────────────────────────────────────┐
│ check-dev.ps1（21 项，退出码 0，无跳过项）            │
│ CI: analyze+test → 三 ABI → 签名守卫 → 审批门 → Release│
│ ⚠️ 构建**不要**传 CF_NEW_PLAYER（默认已是新页）        │
└─────────────────────────────────────────────────────┘
```

---

## 13. 当前状态与遗留问题

### 13.1 已修复（本轮）

| 级别 | 问题 | 修复方式与验证 |
|---|---|---|
| 🔴 **P0** | 发布包跑旧播放页 | 翻转 `CF_NEW_PLAYER` 默认值；**字节级确证**：无 flag 构建 ⇒ 旧页串 0/6、新页串 6/8 |
| 🟡 P1 | 新页缺章节刻度 | 逐层透传 + 令牌；**真机像素测量** 11 条、等高 8px |
| 🟡 P1 | 新页缺跳过片头 | `markerType` 优先 + `stateStream` + 一集一次；守卫测试 + 注入 19/19 |

> ⚠️ **修正上一轮的误报**：曾报"新页缺 4 项"，实际**只缺 2 项** ——
> 双击播放/暂停与锁屏按钮**新页早就有**。
> 原因是只 grep 了 `player_flow_page.dart` 一个文件，
> 而新页是分层的（14 个文件）。

### 13.2 仍未修（如实列出）

| 级别 | 问题 | 影响 |
|---|---|---|
| 🟡 P1 | **v0.3.2 已发布的包是旧页** | 用户下载到的版本**不含**双内核/会话层/HDR/WakeLock/音量系统通道 ⇒ **需要重新发布** |
| 🟡 P1 | 设计令牌采用率 **10%** | 裸 `fontSize` 253 处 vs 令牌 28 处 |
| 🟡 P1 | `screen_brightness` 插件仍在 | 与新页自研 `BrightnessService` 重复（同能力两套实现）|
| 🟡 P1 | 抽象绕过 13 处 | 6 个 `pages/` 直接 import `emby_provider.dart`（§7.13）|
| 🟡 P1 | **退出播放页后屏幕方向不复位** | §7.21，已试 4 种方案失败，下轮入口已写明 |
| 🔵 P2 | 旧页 2816 行仍在 | 双页维护成本（应急回退用）|
| 🔵 P2 | 22 处空 `catch` | 故障被静默吞掉 |

### 13.3 未验证项（如实列出）

· **115 真实播放** —— 无账号，仅验证到"能拿到二维码"
· **官方弹幕 API 联调** —— 本机网络不可达（`api.dandanplay.net` HTTPS 返回 000）
· **转码链路** —— 本服务器不支持
· **平板 / 其它机型** —— 仅测过 Redmi K40（API 33 / 1080×2400）
· **从 Release 下载的包做真机走查** —— 此前做的是本地构建包（见 §0.2）
