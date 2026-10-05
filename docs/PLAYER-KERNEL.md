# 播放内核迁移方案：安卓原生 + mpv

> 状态：方案（待确认后分期实施）｜关联 ADR：0004（Go 核心层）、0002（纯 Dart MVP）
>
> 参考项目（开发方案指定）：
> - **androidx/media**（AndroidX Media3：ExoPlayer / MediaSession / MediaLibraryService）
>   https://github.com/androidx/media
> - **mpv-android**（libmpv 的 Android 原生播放器：JNI 集成 + GL 渲染）
>   https://github.com/mpv-android/mpv-android

## 1. 为什么迁移

当前内核为 media_kit（Flutter 插件形态封装 libmpv）。迁移到「安卓原生 + mpv」后：

| 维度 | media_kit（现状） | 原生 mpv（目标） |
|---|---|---|
| 渲染 | 插件自管 Texture | 原生 GLSurfaceView + mpv render context（mpv-android 方案） |
| 会话/后台 | 需自行集成 | Media3 `MediaSessionService`（通知栏/蓝牙/耳机键开箱即用） |
| 调参 | 经插件 API 间接触达 | `MPVLib.command/property` 直达 mpv（vo/gpu-next/hwdec/alang…） |
| 依赖面 | media_kit 三件套插件 | 自持 jniLibs（libmpv.so）+ 一个薄桥模块 |
| 版本 | 随插件更新 | 与 mpv-android 上游对齐，自控节奏 |

不迁移的东西：Flutter 侧控制层 UI、手势体系、弹幕 overlay、Emby 进度上报——**全部保留**，只换"播放内核 + 渲染出口"。

## 2. 目标架构

```
Flutter（lib/player/player_page.dart —— 控制层/手势/弹幕 overlay 不变）
   │  MethodChannel  cineflow/player        （命令：open/play/pause/seek/rate/
   │                                          volume/audioTrack/subTrack/fit…）
   │  EventChannel   cineflow/player/events （事件：position/duration/buffer/
   │                                          tracks/paused/completed/error）
   ▼
Android 原生（android/app/src/main/kotlin/com/cineflow/app/player/）
   ├─ MpvFlutterView   —— 参考 mpv-android 的 BaseMPVView/MPVView：
   │     GLSurfaceView + mpv_render_context（MPV_RENDER_API_API_OPENGL_ES）
   ├─ MpvBridge（JNI 封装）—— 参考 mpv-android 的 MPVLib：
   │     mpv_create/mpv_initialize/mpv_command/mpv_set_property/observe_property
   ├─ PlayerChannelController —— MethodChannel/EventChannel 处理器，
   │     把 Flutter 命令翻译成 mpv 命令，把 mpv 属性观察翻译成事件
   └─ PlaybackService  —— 参考 androidx/media 的 MediaSessionService：
         MediaSession + 通知栏 + 音频焦点 + 耳机/蓝牙键（后台播放）
```

## 3. 实施分期

### M1 · 原生 spike（先验证渲染与手势叠加）
- 引入 libmpv.so（来源二选一：mpv-android Releases 的 libmpv 压缩包；或按其 build 脚本自编）预置 `jniLibs/arm64-v8a/`。
- 实现 `MpvFlutterView`（GLSurfaceView 子类，mpv render context 初始化与 `MPV_RENDER_PARAM_FBO` 绘制循环）。
- Flutter 侧用 `PlatformViewLink`（hybrid composition）嵌入；最小命令集：open / play-pause / seek / position 事件。
- 验收：真机播放 Emby 直连流；弹幕 overlay 叠加正常；双击三分区/长按倍速手势不冲突（`AndroidView` 需关闭自身点击，手势统一由外层 Flutter GestureDetector 接管）。

### M2 · API 全量对齐
- 音轨/字幕：mpv `track-list` 属性 → 事件回传 Flutter，`setAudioTrack`/`setSubtitleTrack` 映射 mpv 属性写入（替换 media_kit Track API）。
- 倍速 `speed`、音量 `volume`、章节 `chapter-list`、缓冲 `demuxer-cache-time`、错误事件 `mpv event end-file(reason)`。
- 转码兜底/速度监测逻辑保持在 Dart，只换内核调用。
- 移除 `screen_brightness` 之外对 media_kit 的全部引用点（`player_page.dart` 内聚在控制器类中，改动面可控）。

### M3 · Media3 会话与后台（androidx/media）
- `media3-session`：`MediaSessionService` + `MediaSession`，把 mpv 播放状态桥接为 Media3 `Player` 接口的只读实现（通知栏/锁屏控制、音频焦点、耳机拔出暂停）。
- 后台播放开关（原型行为组已有该偏好位）。

### M4 · 收尾
- 移除 media_kit 依赖与插件注册；体积核对（libmpv.so 由插件携带 → 自持，总量不变）。
- 回归：跳过片头/自动连播/选集/弹幕/进度上报（`Sessions/Playing*` 载荷不变）。

## 4. 风险与对策

| 风险 | 对策 |
|---|---|
| PlatformView 手势仲裁（双击/长按可能被原生视图吃掉） | `AndroidView(gestureRecognizers:)` 显式白名单；mpv 视图 `setOnTouchListener` 返回 false |
| libmpv.so 与 NDK 版本/ABI 匹配 | 只出 arm64-v8a（与构建脚本一致）；用 mpv-android 同版 CI 产物 |
| 多 Surface 生命周期（进后台/回前台渲染上下文重建） | 参考 mpv-android 的 `onPause/onResume` 处理；后台只播音频时 `vid=no` |
| 事件风暴（position 每 ~16ms 回传） | EventChannel 侧 200ms 节流（与现有 setState 节奏一致） |
| 杜比视界/PGS 等格式回归 | 迁移前后用同一批片源做对照播放（含 4K DV HEVC 直连案例） |

## 5. 参考

- androidx/media（Media3）—— MediaSession/后台播放框架：https://github.com/androidx/media
- mpv-android —— libmpv 原生集成（JNI/GL 渲染/属性观察）：
  关键文件 `MPVLib.kt`（JNI 桥）、`BaseMPVView.kt`（渲染视图）、`MPVView.kt`（选项初始化）、
  `BackgroundPlaybackService.kt`（后台播放）
- libmpv 官方 render API 文档：https://github.com/mpv-player/mpv/blob/master/libmpv/render.h
