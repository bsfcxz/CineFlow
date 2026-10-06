# 播放内核迁移：安卓原生 + mpv

> 状态：**K0–K4 已完成并真机验证**（2026-10-05）｜关联 ADR：
> [0004](decisions/0004-go-core-layer.md)（Go 核心层）、[0002](decisions/0002-pure-dart-mvp.md)（纯 Dart MVP）、
> [0009](decisions/0009-native-mpv-kernel.md)（本次迁移决策）
>
> ## 参考项目（开发方案指定）
> | 项目 | 许可 | 用于 | 地址 |
> |---|---|---|---|
> | **androidx/media**（AndroidX Media3） | Apache-2.0 | M3 会话层：`MediaSession` / 通知栏 / 后台播放 | https://github.com/androidx/media |
> | **mpv-android** | MIT | 原生 libmpv 集成：JNI 桥 / `Surface→wid` / 选项组合 | https://github.com/mpv-android/mpv-android |
> | **media-kit/media-kit** | MIT | **纹理输出参考**：`VideoOutput.java` 的 `TextureRegistry.SurfaceProducer → wid` | https://github.com/media-kit/media-kit |
> | **mpv-player/mpv** | LGPL-2.1+ | `client.h` 语义权威（`wid` 必须在 `initialize` 前设） | https://github.com/mpv-player/mpv |

## 0. 结论速览（实测）

真机（Xiaomi M2012K11AC / Android 13 / arm64）logcat 证据：

```
av_jni_set_java_vm -> 0 (0=成功)
attachSurface: wid=14182
createTexture: id=0 1280x720
wid 已设定 = 14182
mpv_initialize 成功，client API 版本=131074
[mpv/vd] Using hardware decoding (mediacodec).
AO: [audiotrack] 44100Hz stereo 2ch float
VO: [gpu] 1920x1080 mediacodec
```

集成测试（`integration_test/player_kernel_test.dart`）：**1 passed**。

## 1. 为什么迁移

| 维度 | media_kit（旧） | 安卓原生 mpv（新） |
|---|---|---|
| 调参 | 经插件 API 间接触达 | `MPVLib.command/property` 直达 mpv |
| 依赖面 | 三件套插件（含各平台 lib） | 自持 `jniLibs/libmpv.so` + 一个薄桥 |
| 会话/后台 | 需自行集成 | 预留 Media3 `MediaSessionService`（M3） |
| 版本 | 随插件更新 | 与 mpv-android 上游对齐，自控节奏 |

**不迁移的东西**：Flutter 控制层 UI、手势体系、弹幕 overlay、Emby 进度上报
——全部保留，只换"播放内核 + 渲染出口"。

## 2. 最终架构（与初版方案的关键差异）

```
Flutter（lib/player/player_page.dart —— 控制层/手势/弹幕 overlay 不变）
   │  只依赖 PlayerFacade 的 API 面（成员名刻意对齐 media_kit Player）
   ▼
lib/player/
   ├─ kernel.dart          PlayerKernel 抽象（UI 只认它）
   ├─ native/native_kernel.dart   MethodChannel + EventChannel 实现
   ├─ native/native_video_view.dart  Texture(textureId) 输出层
   └─ player_facade.dart   门面：镜像 Player.state / Player.stream
   │  MethodChannel  cineflow/player        （createTexture/open/play/pause/
   │                                          seek/setRate/setVolume/track…）
   │  EventChannel   cineflow/player/events （property / end-file / log）
   ▼
Android 原生（android/app/src/main/kotlin/com/cineflow/app/player/）
   ├─ MPVLib.kt       JNI 桥：attachSurface / detachSurface / command / property
   └─ PlayerChannel.kt 纹理管理 + 通道分发
C（android/app/src/main/cpp/cineflow_mpv.c）
   └─ 事件线程 + JSON 转义 + Surface→wid 生命周期
   ▼
libmpv.so（自持，gpu-context=android 自建 EGL）
```

### ★ 与初版方案（PlatformView + `mpv_render_context`）的差异及原因

初版方案打算用 `PlatformViewLink` + `GLSurfaceView` + `mpv_render_context`。
**调研后改为 Flutter 纹理 + `Surface→wid`**，理由：

1. **上游根本不用 render API**：mpv-android 的 `render.cpp` 是
   `attachSurface → mpv_set_option("wid", int64)`，由 mpv 自己建 EGL。
   没有 Android 上的 render API 范例可对照。
2. **弹幕叠加**：纹理是普通 Flutter 图层，`CustomPainter` 弹幕、手势、控制层
   直接叠上去即可；PlatformView 要走混合合成，手势仲裁是原方案自己
   在 §4 点名的头号风险。
3. **少一层自研 GL 代码**：不需要自己写 `EGLContextFactory`、管理 GL 线程。
4. **已验证**：media_kit_video 在本项目一直用这条路（`VideoOutput.java`）。

## 3. 实施分期（含状态）

### K0 · libmpv.so 采购 ✅
`jniLibs/arm64-v8a/libmpv.so`（12,369,680 B）。
ELF 头 `7F 45 4C 46`、机器 `0xB7`(AArch64)、类型 `3`(ET_DYN)、`SONAME=libmpv.so`。
`DT_NEEDED` 只依赖系统库（`libm/libandroid/libOpenSLES/libEGL/libdl/libc`）——
**ffmpeg 是静态链进去的**，故只需这一个文件。

### K1 · 原生 spike ✅
- `cineflow_mpv.c`：JNI 桥 + 事件线程 + `Surface→wid`。
- `MPVLib.kt` / `PlayerChannel.kt`：纹理与通道。
- **验收**：真机起播成功（见 §0 证据）。

### K2 · API 全量对齐 ✅
- 时长/位置/缓冲/暂停/缓冲中/倍速/音量/音轨/字幕/分辨率 → 属性观察 → 事件。
- `track-list` JSON → `KernelTracks`（audio/sub）。
- 音轨字幕切换映射 mpv 的 `aid`/`sid`（`"no"` = 关闭）。

### K3 · Media3 会话与后台 ⏳ 未开始
`media3-session:1.11.1`（Google Maven）：
- 用 `SimpleBasePlayer` 包 mpv（抽象方法只有 `getState()`），
  只依赖 `media3-session`（不需要 exoplayer/ui）。
- `MediaSessionService` + `onGetSession`；manifest 需
  `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MEDIA_PLAYBACK`
  + `foregroundServiceType="mediaPlayback"`。
- 默认通知用 `DefaultMediaNotificationProvider`（渠道自动创建）。
- ⚠️ **音频焦点与拔耳机暂停必须自己写**：Media3 的焦点处理在 ExoPlayer 里，
  `MediaSession` 层**不做**（已核实：`MediaSession*.java` 里零 `AudioManager` 命中）。

### K4 · 收尾 ✅
- 移除 `media_kit` / `media_kit_video` / `media_kit_libs_video` 三个依赖。
- 删除 `lib/player/mediakit_kernel.dart`、`MpvFlutterView.kt`（PlatformView 方案作废）。
- `flutter analyze`：**0 issue**；`flutter test`：**286 例全绿**。

## 4. ★ 实测踩到的坑（全部已修，改动前必读）

### 4.1 `av_jni_set_java_vm` —— 不注册就"解封装正常但播不了"
**现象**（最误导人的一个）：
```
[mpv/cplayer]  (+) Video --vid=5 (h264 1920x1080 60fps)   ← 轨道全都解析出来了
[mpv/vo/gpu/android] No Java virtual machine has been registered
[mpv/vo/gpu/android] Could not attach java VM.
[mpv/vo/gpu] Failed initializing any suitable GPU context!
[mpv/cplayer] Error opening/initializing the selected video_out (--vo) device.
→ end-file error: error (error=-20 something happened)
```
**原因**：`gpu-context=android` 要用 `ANativeWindow_fromSurface(JNIEnv*, jobject)`
把 `wid` 转成原生窗口，而它需要 JNIEnv；mpv 通过 FFmpeg 的 `av_jni_*` 拿 JavaVM，
**必须由宿主注册**（mpv-android 的 `main.cpp` 做的就是这件事）。
**修法**：`JNI_OnLoad` 里 `av_jni_set_java_vm(vm, NULL)`。
> 教训：**"能解析出轨道"不等于"能播"**。只看轨道列表会误判成网络问题。

### 4.2 `wid` 必须在 `mpv_initialize` **之前**设
`client.h` 对 `mpv_create` 的说明：只有 initialize **前**才能 `mpv_set_option`。
故 Kotlin 顺序被钉死：**先 createSurface → attachSurface → 再 initialize**。
`PlayerChannel` 的 `initialize`/`open` 都会先 `ensureTexture()`。

### 4.3 Surface 必须是 **JNI 全局引用**
`wid` 传的是 `NewGlobalRef(surface)` 的地址。用局部引用的话，
JNI 调用一返回就失效，mpv 后面拿它取窗口会拿到野指针。

### 4.4 事件 JSON 必须转义 + `aid`/`sid` 要当字符串
mpv 的日志与 `track-list` 里带 `"` 与换行；`aid` 关掉时字面量是 `no`。
早期版本直接 `snprintf` 拼 `"data":%s` → 非法 JSON → Dart 侧 `jsonDecode`
抛异常后被 `catch` 静默丢弃，**表现为"音轨切换事件全丢"但不报错**。
现统一走 `sb_json_string()`（转义 + 动态扩容）。

### 4.5 事件线程必须在 `mpv_terminate_destroy` **之前** join
反过来做 = 线程还在 `mpv_wait_event`，句柄已释放 → 退出播放器必崩。

### 4.6 `#if` 不是 `#ifdef`（ABI 桩构建）
CMake 对无 libmpv 的 ABI 传 `-DCINEFLOW_HAS_MPV=0`。
`#ifdef` 只判断"是否定义"，**值为 0 也算定义** → 桩代码被编成真实现。
必须 `#if CINEFLOW_HAS_MPV`。

### 4.7 跨 ABI 链接：`JNI_OnLoad` 里的调用也要包在 `#if` 内
只构建 arm64 时通过；全 ABI 构建时 v7a/x86_64（无 libmpv）会报
`undefined symbol: av_jni_set_java_vm`。**单 ABI 构建验证不出这个问题。**

### 4.8 Flutter 纹理 id 从 **0** 开始
第一个纹理合法地拿到 `0`。断言 `textureId > 0` 是错的（写集成测试时踩过）；
要验证"纹理可用"应改为渲染一个 `Texture(textureId:)` 看是否抛异常。

## 5. 与既有铁律的衔接

- **§6.2 dispose 崩溃**：已从 media_kit 时期延续到新内核——
  退出仍走"先停止上报 → 延迟释放"，`nativeDestroy` 内部先 join 事件线程。
- **§5.1 UI 只依赖抽象**：本页现在只依赖 `PlayerFacade`，**零 media_kit 引用**。
- **K4 之后 `pubspec.yaml` 不再有 `media_kit*`**；`--split-per-abi`
  体积策略不再由插件决定，libmpv.so 已自持。

## 6. 风险与对策（更新）

| 风险 | 对策 | 状态 |
|---|---|---|
| ~~PlatformView 手势仲裁~~ | 改纹理输出，风险消失 | 已消除 |
| libmpv.so 与 NDK/ABI 匹配 | 只出 arm64-v8a（与 Go 层一致）；CMake 按 `${ANDROID_ABI}` 取 | 已落地 |
| 多 Surface 生命周期 | `onSurfaceCleanup` → `detachSurface`；`dispose` 先解绑再拆 mpv | 已落地 |
| 事件风暴（position ~16ms） | Dart 侧派生流**去重**（`_mapState` 比对上次值） | 已落地 |
| 杜比视界/PGS 等格式回归 | 待用同批片源做迁移前后对照播放 | **待办** |
| 音频焦点/耳机拔出 | M3 必须自研（Media3 不代劳） | **待办（K3）** |

## 7. 参考

- androidx/media（Media3）https://github.com/androidx/media
- mpv-android —— 关键文件 `MPVLib.kt`、`app/src/main/jni/render.cpp`（`Surface→wid`）、
  `MPVView.kt`（Android 默认选项）、`BackgroundPlaybackService.kt`：
  https://github.com/mpv-android/mpv-android
- media_kit_video `VideoOutput.java`（`TextureRegistry.SurfaceProducer → wid`）：
  https://github.com/media-kit/media-kit
- libmpv `client.h` / `render.h`：
  https://github.com/mpv-player/mpv/blob/master/include/mpv/client.h
