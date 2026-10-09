# CineFlow 全流程技术与实现细节

> **本文档回答一个问题：这个 App 从冷启动到播放一集剧，中间到底发生了什么。**
>
> **写作纪律**（本仓库要求）：所有涉及行号、通道名、参数值、耗时的地方，
> 均**取自代码或实测**，不凭记忆。标注 `（实测）` 的来自真机日志或 `dumpsys`。
> 未能证实的写"未验证"。
>
> 与其它文档的分工：
> · 本文 —— **全流程串联**（一次播放的完整链路 + 关键技术决策）
> · [`DUAL-KERNEL.md`](DUAL-KERNEL.md) —— 双内核架构说明书
> · [`DUAL-KERNEL-OPTIMIZATION.md`](DUAL-KERNEL-OPTIMIZATION.md) —— 为什么这么设计 + 还能优化什么
> · [`AGENTS.md`](../AGENTS.md) —— 作业手册（坑、缺陷台账、验收基线）

---

## 0. 技术栈总览（实测版本）

| 层 | 选型 | 版本 | 说明 |
|---|---|---|---|
| UI | Flutter + Material 3 | **3.47.5 stable** | Dart SDK `^3.13.4` |
| 状态管理 | flutter_riverpod | **3.x** | 计划书写 2.x，实际 3.x |
| 路由 | go_router | ADR 0005 | 路由表 `lib/core/router.dart` |
| 网络 | dio | 5.x | 拦截器注入认证头 |
| 本地库 | drift + sqlite3 | **drift 2.31.x / sqlite3 2.x** | 钉死版本（3.x 需 native assets） |
| 凭据存储 | flutter_secure_storage | — | Android Keystore |
| **播放内核** | **原生 mpv**（自持 `libmpv.so`） | **v0.36.0-549-g78d43740f5** | 非插件，见 §4 |
| **第二内核** | **Media3 / ExoPlayer** | **1.4.1** | `media3-exoplayer` + `media3-session` |
| **Go 核心层** | Go + FFI | Go 1.27.0 | 零 cgo，编译为 `libcineflow_go.so` |
| 原生桥 | Kotlin + JNI | NDK 27/28 | 10 个 Kotlin 文件 / 2345 行 |

**代码规模**：Dart `lib/` 98 文件 32369 行 · 测试 64 文件 13202 行 ·
Go 26 文件 5815 行 · Kotlin 10 文件 2345 行

---

## 1. 冷启动链路

### 1.1 启动顺序（`lib/main.dart`）

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();   // ← 必须先于任何插件调用

  final themeIdx = int.tryParse(await SessionStore().getPref('theme_index') ?? '') ?? 0;
  final go = GoCore.tryLoad();                 // ← FFI 加载，失败可降级
  if (go != null) {
    final ping = GoCore.ping();                // 自检：{pong: cineflow-go, version: 1}
    final sort = go.sortParams('DateCreated'); // 自检：排序参数拼装
    final norm = go.normalizeLatest([...]);    // 自检：/Latest 归一化
  }
  final container = ProviderContainer();
  await container...;                          // 预热 provider
  runApp(UncontrolledProviderScope(...));
}
```

**关键设计：Go 层自检在启动时跑，把结论打到日志**
```
I/flutter : [GoCore] 已加载，ping={pong: cineflow-go, version: 1}
I/flutter : [DB] 就绪，清理过期缓存 0 条，现有 1 条 / 30442 字符
```
（实测）

**为什么必须自检**：Go 编译器会**合并字符串常量**，
⇒ **无法用 `strings`/grep 扫 `.so` 确认某个方法是否编进去了**（实测：
`media.sortParams` 扫不到但运行正常）。
**唯一可靠的验证是运行时调用**。

### 1.2 启动时的后台任务（不阻塞 UI）

`_CineFlowAppState.build` 里以 `_dbChecked` 为门，只跑一次：
```dart
Future<void>(() async {
  final db = ref.read(appDbProvider);
  final purged = await db.cachePurgeExpired();   // 清过期缓存
  final stats = await db.cacheStats();           // 统计
});
```
⇒ **故意不 await** —— 缓存清理不该拖慢首帧。

### 1.3 `runApp` 之后到首帧的实测耗时

| 阶段 | 耗时（中位，3 次采样）| 性质 |
|---|---|---|
| `prefRead` | **245 ms** | 读偏好（Keystore 解密）|
| `kernelCreate` + `texture` | 4 ms | |
| `resolve` | 33 ms | Emby 取直链 |
| `open` | 36 ms | |
| `seek` + `rate` | 8 ms | |
| **Dart 命令链合计** | **314 ms** | |

⚠️ 这是**进播放页**的埋点，不含冷启动到首页。

---

## 2. 数据层：Emby 接入

### 2.1 分层（架构承诺）

```
UI（pages/）
  ↓ 只依赖抽象
MediaProvider（lib/data/media_provider.dart，抽象接口）
  ↓ 实现
EmbyProvider（lib/data/emby_provider.dart）
```

**为什么**：多源可插拔。115 网盘走**独立页面**而非 `MediaProvider`
（它的播放模型是文件夹树 + `pick_code`，与 Emby 的库/季/集根本不同，
强行统一会造出无意义概念 —— ADR 0007）。

⚠️ **已知未收敛**：6 个 `pages/` 文件仍直接 `import 'emby_provider.dart'`
（主要为 `MediaException`），见缺陷 §7.13。

### 2.2 `MediaProvider` 接口全清单

```dart
Future<List<MediaView>>   getViews();
Future<List<MediaItem>>   getLatest({int limit});
Future<List<MediaItem>>   getResume({int limit});
String                    imageUrl(String itemId, ...);
Future<List<MediaItem>>   search(String keyword, {int limit});
Future<ItemPage>          getItems({...});        // 服务端分页/筛选/排序
Future<MediaItemDetail>   getItemDetail(String itemId);
Future<List<String>>      getGenres({String? parentId});
Future<(int, int)?>       getYearRange({...});
Future<List<MediaItem>>   getSeasons(String seriesId);
Future<List<MediaItem>>   getEpisodes(String seriesId, String seasonId);
Future<List<MediaItem>>   getNextUp(String seriesId, {int limit = 1});
Future<List<MediaItem>>   getSimilar(String itemId);
Future<List<MediaChapter>> getChapters(String itemId);
Future<bool>              toggleFavorite(String itemId, {required bool favorite});
Future<bool>              togglePlayed(String itemId, {required bool played});
Future<PlaybackLaunch>    resolvePlayback(String itemId, {String? mediaSourceId});
void                      reportPlaybackStart(...);      // 不 await
void                      reportPlaybackProgress(...);   // 不 await
void                      reportPlaybackStop(...);       // 不 await
void                      reportItemProgress({...});
```

### 2.3 实际用到的 Emby 端点（代码实测）

| 用途 | 端点 |
|---|---|
| 登录 | `POST /Users/AuthenticateByName` |
| 媒体库视图 | `GET /Users/{uid}/Views` |
| 最新添加 | `GET /Users/{uid}/Items/Latest` |
| 继续观看 | `GET /Users/{uid}/Items/Resume` |
| 列表/筛选/排序 | `GET /Users/{uid}/Items` |
| 详情 | `GET /Users/{uid}/Items/{id}` |
| 类型 | `GET /Genres` |
| 季 / 集 | `GET /Shows/{id}/Seasons` · `GET /Shows/{id}/Episodes` |
| 下一集 | `GET /Shows/NextUp` |
| 相似 | `GET /Items/{id}/Similar?userId=` |
| 收藏 toggle | `POST /emby/Users/{uid}/FavoriteItems/{id}`（取消加 `/Delete`）|
| 看过 toggle | `POST /emby/Users/{uid}/PlayedItems/{id}`（同上）|
| **播放信息** | `GET /Items/{id}/PlaybackInfo?userId=` |
| 进度上报 | `POST /Sessions/Playing` · `/Playing/Progress` · `/Playing/Stopped` |
| 用户数据 | `POST /Users/{uid}/Items/{id}/UserData` |

### 2.4 ★ 认证头（缺一段就 500）

```dart
// emby_provider.dart:42
return token == null ? base : '$base, Token="$token"';
```
`base` 含四段，**缺 `Version` 服务端直接 500**（实测踩过，写进 §9 禁止事项）：
```
MediaBrowser Client="CineFlow", Device="Android", DeviceId="<uuid>", Version="..."
```

### 2.5 实测出的协议坑（都写进代码注释）

| 现象 | 真相 |
|---|---|
| `/Latest` 返回**裸数组** | 解析要兼容 map/List 两种形状 |
| 服务端**无视类型筛选** | 必须客户端 `isPlayable` 复筛 |
| `Series` 也是 `IsFolder=true` | **不能**用 `IsFolder` 判断剧集 |
| Similar 带 `/Users/{uid}` → **404** | 路径是 `/Items/{id}/Similar?userId=` |
| 这台服务器**没有** `/Favorites/` 路径 | 必须用 `/emby/...` 前缀 |
| 指定 `MediaSourceId` 后**仍返回全部** MediaSources | 客户端按 id 复选 |

---

## 3. 播放流程：从点剧集到出画面

### 3.1 总链路

```
用户点「继续观看」卡片
  ↓
详情页 / 首页 → route.push('/play/:id', extra: PlayerRouteArgs)
  ↓ go_router
player_routes.playerRoute()  ← ★ 这里有双播放页分支（见 §3.6）
  ↓
PlayerFlowPage（新页，1955 行）
  ↓ _boot()
    ① 读偏好（prefRead 245ms）
    ② KernelFactory.create() → 选内核（见 §3.2）
    ③ ensureTexture() → Flutter 纹理
    ④ provider.resolvePlayback() → 直链（resolve 33ms）
    ⑤ kernel.open(url)（open 36ms）
    ⑥ kernel.seek(续播点) + setRate（8ms）
  ↓
mpv / Media3 开始解码
  ↓ DEMUX_DONE（容器探测完成）
  ↓ FIRST_FRAME（首帧上屏）
  ↓
_Tick（position 限流 250ms）→ 更新进度条
```

### 3.2 内核选择（`kernel_auto_select.dart`，**顺序即优先级**）

**决策是纯函数**（无状态、无 IO）⇒ 每条规则可精确断言，不必起真实播放器。

| 优先级 | 条件 | 选谁 | 理由（代码原文）|
|---|---|---|---|
| **0** | `isHdr`（含 DV）| **mpv** | 设备 MediaCodec 常只解 DV 基础层（画面发灰）|
| 1 | mpv 独占容器 | mpv | RMVB/WMV/ASF/VOB/FLV — 系统解码器通常没有 |
| 2 | `isHlsStream` | **Media3** | 分片续播、码率切换更成熟 |
| 3 | `h >= 2000` | **Media3** | 高分辨率走系统硬解能效更好 |
| 4 | 有外挂字幕 | mpv | 对 GBK/BIG5、ASS 特效、字体回退更好 |
| 5 | 其余 | mpv | 常规片源 mpv 格式覆盖最全；信息不足时保守选 mpv |

> ⚠️ **规则 1 在代码里排在规则 2 之前** —— 冷门格式即便走 HLS，
> 也**播放优先于体验**。
>
> ⚠️ **判定必须防"元数据缺失"**：`videoRange == null ⇒ isHdr = false`，
> 否则会把所有 4K 片源推给 mpv，反而伤害"能效更好的硬解通路"。

**用户可显式覆盖**：`if (preference.isExplicit)` 直接返回用户选择，
理由写"你在设置里指定了「…」"。

### 3.3 双内核共用一个渲染出口

```
        ┌─────────────── Flutter 纹理（Texture widget）───────────────┐
        │                                                              │
   NativeKernel（mpv）                          Media3Kernel（ExoPlayer）
   libmpv.so + JNI                              media3-exoplayer
   attachSurface → wid                          SurfaceTexture
        │                                                              │
        └────────────── 同一条 Dart UI 代码路径 ──────────────────────┘
```

**为什么统一纹理**（见 `DUAL-KERNEL-OPTIMIZATION.md` §1.4）：
· 纹理是**普通 Flutter 图层** ⇒ 弹幕 `CustomPainter`、手势、控制层**直接叠在上面**
· 两内核输出方式一致 ⇒ **Dart 渲染代码无需分支**

### 3.4 Dart ↔ Kotlin ↔ C 契约（实测通道名）

| 层 | MethodChannel | EventChannel |
|---|---|---|
| mpv 内核 | `cineflow/player` | `cineflow/player/events` |
| Media3 内核 | `cineflow/media3` | `cineflow/media3/events` |
| 媒体会话 | `cineflow/session` | — |
| 通知栏 | `com.cineflow.app/notification` | — |
| 亮度 | `com.cineflow.app/brightness` | — |
| 音量 | `com.cineflow.app/volume` | `com.cineflow.app/volume/events` |
| 唤醒锁 | `com.cineflow.app/wakelock` | — |

**两侧常量逐一核对一致**（Dart `MethodChannel(...)` ↔ Kotlin `const val`）。

### 3.5 ★ 事件形状统一（最容易被低估的一条）

`Media3Channel.emitTracks` 刻意按 **mpv 的字段名**输出
（`demux-channels` / `ff-index`…）—— 否则"两个内核两套 UI 逻辑"。

**代价**：改任一边的字段名都要同步改另一边。

### 3.6 ⚠️ 双播放页（当前的真实状态）

```
player_routes.playerRoute():
    if (useNewPlayerUi)  → PlayerFlowPage   ← 新页（双内核/会话层/HDR/音量）
    else                 → PlayerPage       ← 旧页（2816 行）
```

```dart
// player_flow_page.dart:59
const useNewPlayerUi = bool.fromEnvironment('CF_NEW_PLAYER', defaultValue: false);
```

**⚠️ 实测发现（见 [`AUDIT-2026-10-09.md`](AUDIT-2026-10-09.md)）**：

| 包 | 编进去的页面 |
|---|---|
| 本地构建（传了 flag）| **新页** |
| **已发布的 v0.3.2**（CI 未传）| **旧页** |

**根因**：`bool.fromEnvironment` 是**编译期**常量，CI 不传 ⇒ 折叠成 `false`
⇒ 新页被 tree-shaking 删掉。全仓**只有这一个**编译期开关，
而 4 个构建脚本（`release.yml`/`ci.yml`/`build_apk.sh`/`build_apk.bat`）**都没传它**。

**⚠️ 且新页并非旧页的超集** —— 实测缺 4 项：

| 功能 | 旧页 | 新页 |
|---|---|---|
| 跳过片头 | ✅ | ❌ |
| 锁屏按钮 | ✅ | ❌ |
| 章节刻度 | ✅ | ❌ |
| 双击播放/暂停 | ✅ | ❌ |
| （新页独有）投屏 | ❌ | ✅ |

⇒ **删旧页前必须先补这 4 项**（否则是功能倒退）。

---

## 4. 原生层：mpv 集成（最硬的部分）

### 4.1 为什么不用 `PlatformView`

| 方案 | 结论 |
|---|---|
| `PlatformView` + `mpv_render_context` | ❌ 上游（mpv-android）**根本不用 render API** |
| **纹理**：`attachSurface → wid`，mpv 自建 EGL | ✅ 与 mpv-android 同款 |

### 4.2 ★ 顺序约束（错一步就黑屏）

```
createSurface → attachSurface → mpv_initialize
```

**`wid` 必须在 `mpv_initialize` 之前 `mpv_set_option`** ——
之后设置**不再生效**。故 `PlayerChannel.initialize/open` 都会先 `ensureTexture()`。

### 4.3 ★ `av_jni_set_java_vm` 必须注册（现象极误导）

不注册时：
```
✅ 解封装完全正常（logcat 能看到 h264/aac 全部轨道列出来）
❌ [mpv/vo/gpu/android] No Java virtual machine has been registered
   → GPU 上下文初始化失败 → end-file error
```
⇒ **"能解析出轨道" ≠ "能播"**。

### 4.4 mpv 选项全清单（31 项，`PlayerChannel.kt` 实测）

| 类别 | 选项 |
|---|---|
| 视频输出 | `vo=gpu` · `gpu-context=android` · `opengl-es=yes` |
| 硬解 | `hwdec=mediacodec,mediacodec-copy` · `hwdec-codecs=h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1` |
| 音频输出 | `ao=audiotrack,opensles` |
| **HDR/DV** | `tone-mapping=bt.2390` · `tone-mapping-mode=auto` · `hdr-compute-peak=yes` · `target-peak=auto` · `gamut-mapping-mode=auto` · `target-prim=auto` |
| 流畅度 | `video-sync=display-resample` · `interpolation=yes` · `tscale=box` |
| 丢帧策略 | `framedrop=vo`（只允许渲染端丢，**解码器不丢完整帧**）|
| 音频 | `audio-buffer=0.5`（消爆音）|
| 缓冲 | `cache=yes` · `demuxer-max-bytes=128MiB` · `demuxer-max-back-bytes=64MiB` · `cache-secs=30` |
| **起播** | `demuxer-lavf-analyzeduration=1` · `demuxer-lavf-probesize=2097152` |
| 网络 | `network-timeout=15` |
| 其他 | `config=no` · `save-position-on-quit=no` · `idle=yes` · `force-window=no` |
| 字幕 | `sub-fonts-dir=/system/fonts` · `sub-font=sans-serif` · `sub-codepage=auto` |

**为什么 `analyzeduration=1`**：ffmpeg 默认 5 秒 —— 对网络源是**纯等待**。
实测起播 **9087 → 7584 ms**（−16.5%）。
⚠️ 代价：冷门容器探测准确率下降，遇到"轨道识别不全"**先回调这一项**。

### 4.5 ★ 本构建没有的能力（别写进代码）

```
-Dlibplacebo=disabled -Dvulkan=disabled
```
⇒ **不存在**：`vo=gpu-next`、`target-colorspace-hint`、`vd-queue-*`
（对着 `libmpv.so` 字符串表逐个核实过 —— 加进去是**静默 no-op**）

**libmpv 来源**（二进制指纹确认）：GitHub Actions 构建自
`media-kit/libmpv-android-video-build`（MIT），上游 `jarnedemeulemeester/libmpv-android`。

### 4.6 生命周期：`dispose` 不能同步

```dart
// 退出走：先上报 Stop + pause → 延迟 ≥350ms 释放
unawaited(kernel.dispose());
```
`NativeKernel.dispose` 内部还会 `detachSurface` + **join 事件线程**
（事件线程必须先 join 再 `mpv_terminate_destroy`，否则退出播放器必崩）。

---

## 5. 系统集成层（K3 媒体会话）

### 5.1 四件事一次解决

| 能力 | 实现 |
|---|---|
| 通知栏控制 | `MediaSession` + **`media3-session`** 自带通知 |
| 蓝牙/耳机键 | `MediaSession`（系统按会话路由，**不要求 App 聚焦**）|
| 后台播放 | `MediaSessionService` 前台服务 |
| **音频焦点** | **自研** `AudioFocusManager`（Media3 **不代劳**）|

**★ 通知栏不贴的坑**：`MediaSession.Builder().build()` **只创建会话**，
**不会**纳入通知管理 —— 必须调 **`addSession(session)`**。

**最坑的地方**：它**完全不影响媒体键**（那走 MediaButton 路径）
⇒ 现象是"**媒体键能用，但通知栏什么都没有**"，极易误判为权限问题。

### 5.2 三种失焦分开处理（最易写错）

| 类型 | 场景 | 做法 |
|---|---|---|
| `AUDIOFOCUS_LOSS` | 别的播放器永久接管 | **暂停**，不自动恢复 |
| `LOSS_TRANSIENT` | 来电、导航 | 暂停；焦点回来后**自动续播** |
| `LOSS_TRANSIENT_CAN_DUCK` | 通知音 | **不暂停**，压低音量 |

⇒ **把 `CAN_DUCK` 当 `TRANSIENT`** = 每来一条通知视频都暂停一下。

### 5.3 ★ 会话层命令**回 Dart 执行**

| 方案 | 问题 |
|---|---|
| 会话层**直接**控制原生播放器 | ❌ **两个主** —— Dart 也控播放器，两边状态必然不同步 |
| **会话层把命令转发给 Dart** | ✅ 单一事实源 |

**★ 但这里踩了大坑**：会话命令曾接到 `PlaybackController.pause()` ——
结果是**纯状态机**（只翻标志位，内核收不到指令），**画面毫无变化**。
修法：**镜像页面的写法直调 `_kernel`**。

> **教训**：播放/暂停这类直达内核的原子操作，
> **不要想当然地套抽象，要读实际调用点**。

### 5.4 音量架构（单一事实源）

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

---

## 6. Go 核心层

### 6.1 零 cgo 的分包（否则 `go test` 编不过）

```
go/internal/rpc       ← 纯业务，零 cgo
go/internal/media     ← 纯业务，零 cgo
go/internal/pan115    ← 115 协议
go/bridge.go          ← 唯一的 import "C"（C 边界薄包装）
```
**为什么**：含 cgo 的包在 `CGO_ENABLED=0`（本机默认）时 **`go test`/`go vet` 全部编不过**。

### 6.2 当前职责

| 能力 | 状态 |
|---|---|
| 排序参数拼装 `sortParams` | ✅ |
| `/Latest` 归一化 `normalizeLatest` | ✅ |
| 缓存 KV | 待核实 |
| 115 协议（限速/m115 加解密）| ✅ 见 ADR 0007 |

### 6.3 FFI 契约

「方法名 + JSON」C ABI（**与 Synurang 同构** —— 其代码生成器需 Rust + protoc，
本机没有；替换时只改 Go 侧转发，Dart 契约不变）：

```dart
// lib/core/go_core.dart
GoCore.tryLoad()      // 失败返回 null，不崩
GoCore.ping()         // {pong: cineflow-go, version: 1}
GoCore.invokeAsync()  // ★ 独立 isolate 执行（115 长轮询 30s，否则冻 UI）
```

**纪律**：`try/finally` 释放 `CineFlowCall` 指针（否则每次泄漏一块 C 堆）；
Go 侧 `recover()` 不让 panic 穿过（会直接终止宿主进程）。

---

## 7. 弹幕系统

### 7.1 双源、双认证形态（**不可统一**）

| 源 | 认证 |
|---|---|
| 官方（弹弹play）| 请求头签名 `AppId+Timestamp+Path+AppSecret`（**无分隔符**）|
| 自建（danmu_api / 御坂）| **URL path token**，**不看任何认证头** |

⇒ 写代码时**别统一成一种**，否则必有一边 403。

### 7.2 ★ `p` 字段两种布局（实测 fixture 抓出来的）

| 形态 | 格式 | **颜色位置** |
|---|---|---|
| 弹弹play **原生 4 段** | `时间, 模式, 颜色, 发送者ID` | **index 2** |
| B站 **8 段** | `时间, 模式, 字号, 颜色, …` | **index 3** |

**按 8 段解析官方数据会把字号当颜色、颜色当发送者ID** ——
**弹幕颜色全错但不报错**。

判别：段数 ≥8，或 `index2 ≤64 且 index3 >255`。

### 7.3 轨道分配（必须判"追尾"）

速度模型 `(屏宽+文本宽)/时长` ⇒ **宽弹幕更快**。
· 只判"前一条是否已离开" → 过保守，密集弹幕大量丢弃
· 只判"当前是否重叠" → 宽弹幕**追上并压过**窄弹幕

**正确两条**：① 前一条已完全进屏；② 追上时刻晚于它离开的时刻。

**默认给字幕留一行**（借鉴 MIT 的 `canvas_danmaku` 的 `safeArea`）——
遮挡字幕比少一行弹幕更糟。

### 7.4 其它实测坑

· **业务错误包在 HTTP 200 里**：`{"success":false,...}`
  → 只看状态码会把"服务器内部错误"当"没有弹幕"（**静默空弹幕**）
· **异步状态字面量是 `pending`/`completed`/`failed`**，**没有 `done`**；
  且 `?async=1` **不会立即返回**（仍同步等最多 30s）
· 自建服务未命中返回 **HTTP 404** + `{count:0}` —— 那是"没有弹幕"**不是错误**
· **凭据不入库**：用户填、存 `flutter_secure_storage`，仓库里**连占位符都不放**

---

## 8. 115 网盘

> ⚠️ 走的是**非公开 webapi 接口**（用户明确选择 115driver 路线），
> **有账号风控风险**，已在 ADR 0007 记录并在登录页显著提示。
> 当前状态：**协议层 + 扫码登录 + 文件浏览 + 播放页全部落地**，
> 真机**仅验证到"能拿到二维码"**（无真实账号，未联调真实播放）。

### 8.1 ★ UA 绑定（最容易静默失败）

**取直链时的 UA 必须与播放时逐字节一致** —— 115 的 CDN 与取址 UA **强绑定**。
且取地址响应的 **`Set-Cookie`（`download_token`）必须合并进播放请求**。

两者都**不在 URL 里** ⇒ 只把 URL 交给播放器必然 **403**，
现象是"地址取到了但播不了"，**极难排查**。

⇒ 故 `Pan115Playback` 把 **url 与 headers 绑在同一类型**，不给"只拿 URL"的机会。

### 8.2 ★ m115 不是对称加解密（别"修好"它）

> **全流程只有公开指数 e，没有私钥 d**。`Encode` 与 `Decode` 服务的是
> 两个相反方向，**共用 e 但不是彼此的逆**。`Decode(Encode(x,k),k)` **不还原原文**。

这是上游既定设计（签名式混淆，非保密方案）。
**若有人以为是 bug 并改成往返可逆，那才是引入 bug。**

### 8.3 限速（账号安全，不是性能优化）

全局 **2 请求/秒、严格串行**，且限流放在 `do()` 里
（放各业务方法**必然会在新增方法时漏加**）。**绝不并发翻页。**

上游有几乎一致的实例：WebDAV 挂 115 给 Emby 扫库 → **HTTP 418 WAF**，
维护者明确警告并发"**有封号风险**"。

### 8.4 其它字段陷阱

| 陷阱 | 真相 |
|---|---|
| 文件 vs 目录 | 看 **`fid` 是否为空**，不是 `ico` |
| 字段类型 | 同一字段在不同条目上**可能不同**（目录 `s` 是数字、文件是字符串）|
| 大整数 | 走 `json.Number` 保精度（文件大小可超 2^53）|
| `state` 字段 | 二维码体系是数字 `1`，webapi 是布尔 `true` |
| 错误码拼写 | `errno` 与 `errNo` **两种都用过** |
| 业务错误 | 全包在 **HTTP 200** 里（`state:false` + `errno`）|
| 分页 | 必须用**服务端回显的 offset**，本地累加会**静默跳过内容** |
| 登录 | 必须轮询到 `status==2`（否则 `40101017 老乡验证失败`，**与非法 uid 响应一样**）|

---

## 9. 构建与发布链路

### 9.1 版本号：三处一致（单一权威）

```
VERSION                    ← 唯一权威（只写 "0.3.2" 一行）
pubspec.yaml   version: 0.3.2+4
lib/core/version.dart   const String kAppVersion = '0.3.2';
```
由 `tool/bump_version.ps1 -Version X.Y.Z` 一次改齐，`-Check` 校验。
**代码里不得再出现硬编码版本字面量**。

### 9.2 构建命令

```bash
flutter build apk --release --split-per-abi \
  --obfuscate --split-debug-info=build/symbols
```
**`--split-per-abi` 是唯一能把 libmpv 按架构拆开的手段**：
三架构合并 91.6MB → arm64 单架构约 39MB。
`--target-platform` / `ndk.abiFilters` 对 libmpv **不生效**
（且在 `build.gradle.kts` 加 `ndk.abiFilters` 会与 splits **互斥导致构建失败**）。

**⚠️ 混淆符号表必须与 APK 成对保留** —— 没有它，线上崩溃堆栈就是一堆 `a.b.c`。

### 9.3 签名

```kotlin
// android/app/build.gradle.kts:139
signingConfig = if (cfHasReleaseKey) {
    signingConfigs.getByName("release")
} else {
    signingConfigs.getByName("debug")   // 无密钥时退回 debug（CI 会拦）
}
```
**密钥在仓库外**：`%USERPROFILE%/cineflow-keystore/` 或 `CF_KEY_PROPERTIES` 环境变量。
`android/.gitignore` 已忽略 `key.properties` / `*.jks` / `*.keystore`。

**实测证书**：`CN=CineFlow, OU=Mobile, O=CineFlow, C=CN`
SHA-256 `088fef287233ed59832f1bfa75d956b1d67286bc39e7021eab0e763981881245`

### 9.4 发布通道（`release.yml`）

```
push tag v*  →
  build-apk:  装 Flutter/Java → 还原 keystore → 校验 tag==VERSION
              → analyze + test → 构建三 ABI → 守卫(非 debug 签名)
              → 生成 checksums.txt → 上传 artifact
  publish:    environment: release   ← ★ 审批门（Required reviewers）
              → 守卫(目标 Release 尚不存在，只增不删)
              → 建草稿 + 上传 → 校验齐全后转正
```

**铁律 D1–D10**（`docs/AI-DISTRIBUTION.md`）：
**未经用户当轮明确审批，绝不打 tag、绝不创建/修改/删除任何 Release**；
上传**只增不删**（旧版本是用户回滚的唯一退路）。

### 9.5 覆盖率边界（必须知道）

| 手段 | 能覆盖 | **不能覆盖** |
|---|---|---|
| `flutter test`（866 例）| Dart 纯逻辑 | MethodChannel / JNI / 硬解 / 手势 / 布局 |
| `integration_test`（1 个）| Dart→Kotlin→JNI→libmpv 整链路 | 同上之外的一切 |
| 真机走查 | 手势 / 硬解 / 布局 | 需人工 |

⚠️ **`flutter test` 跑在桌面 VM 上，碰不到 MethodChannel 与 JNI** ——
**链路断了也照样全绿**。故改了播放内核**必须**跑 integration_test。

---

## 10. 质量保障体系

### 10.1 一条命令跑完（退出码 0 才算过）

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check-dev.ps1
```
覆盖：静态分析 / 单测 / go vet / go test / 敏感信息 / 文档 / 版本号 /
产物完整性（ELF 头、ABI）/ **真机冒烟**（安装→启动→存活→Dart 日志→截图）。

### 10.2 ★ 反自欺三原则（`AGENTS.md` §8.4）

**根因相同：验证手段本身没有被验证。危害比"没验证"更大** ——
测试是绿的、脚本是通过的，但**结论是错的**。

1. **断言不得被"注释/文档/相邻代码"满足**
   实测：`contains('s.videoRange')` 命中了**注释**里的同名文本，
   删掉真代码测试仍全绿。
   ⇒ 断言前**先剥注释**（`readCode()`）；断言落在**必然会变的那一行**。

2. **替换/注入要用词边界，且长串优先**
   实测：裸 `§7.1` 命中了 `§7.10` / `§7.19` 的**前缀** ⇒ 制造 **17 处乱码**。
   ⇒ 用 `(?!\d)` 词边界；注入前打印命中次数；注入后确认 `analyze` 仍 0 error。

3. **数字必须来自实际输出，不得推算**
   实测：台账写"859 例 / +19"，实际 **847 / +7** —— 按"两个文件共 19 例"**推算**。

> **一句话判据**：说"已验证"之前先问 ——
> **这个结果，有没有可能在我删掉真代码之后依然成立？**

### 10.3 测量手段的有效性（本轮新踩）

| 手段 | 对 Flutter 有效？ | 说明 |
|---|---|---|
| `dumpsys gfxinfo` | ❌ **无效** | 实测 `Total frames rendered: 0` —— Flutter 不经过 `View.draw()` |
| `SurfaceFlinger --latency` | ❌ **无效** | BLAST 子层不记录 latency 环（实测全 0 或只 1 行）|
| **`SurfaceFlinger --timestats`** | ✅ **有效** | 看 `jankyFrames` / `missedFrames` / `present2present` |
| `dumpsys display` / `settings` | ✅ | 刷新率与 mode |

---

## 11. 全流程一页速查

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
┌─ 播放 ──────────────────────────────────────────────┐
│ /play/:id → playerRoute() ──┬─ 新页（双内核）        │
│                             └─ 旧页（★发布包用的是它）│
│ _boot(): 偏好→选内核→建纹理→取直链→open→seek         │
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
┌─ 系统集成 ──────────────────────────────────────────┐
│ MediaSession（通知栏/耳机键/后台）+ addSession() 必调 │
│ AudioFocusManager（自研；三种失焦分开处理）           │
│ 音量→系统通道（duck 例外走内核）；唤醒锁跟随播放状态  │
└──────────────────────┬───────────────────────────────┘
                       ↓
┌─ 质量与发布 ────────────────────────────────────────┐
│ check-dev.ps1（19–21 项，退出码 0）                  │
│ CI: analyze+test → 三 ABI → 签名守卫 → 审批门 → Release│
└─────────────────────────────────────────────────────┘
```

---

## 12. 当前已知问题（详见 [`AUDIT-2026-10-09.md`](AUDIT-2026-10-09.md)）

| 级别 | 问题 | 影响 |
|---|---|---|
| 🔴 **P0** | **发布包跑旧播放页** | 双内核/会话层/HDR/音量/WakeLock **全未进发布包** |
| 🟡 P1 | 新页缺 4 项旧页功能 | 跳过片头 / 锁屏 / 章节刻度 / 双击播放暂停 |
| 🟡 P1 | 设计令牌采用率 10% | 裸 `fontSize` 253 处 vs 令牌 28 处 |
| 🟡 P1 | `screen_brightness` 插件仍在 | 与新页自研 `BrightnessService` 重复（同能力两套实现）|
| 🟡 P1 | 抽象绕过 13 处 | 6 个 `pages/` 直接 import `emby_provider.dart`（§7.13）|
| 🔵 P2 | 旧页 2816 行、新页 1955 行 | 双页维护成本 |
| 🔵 P2 | 22 处空 `catch` | 故障被静默吞掉 |

**未验证项（如实列出）**：
· 115 真实播放（无账号）
· 官方弹幕 API 联调（本机网络不可达）
· 转码链路（服务器不支持）
· 平板/其它机型适配（仅测过 Redmi K40）
