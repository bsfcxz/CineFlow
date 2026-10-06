# ADR 0009：播放内核迁移到「安卓原生 mpv」（Flutter 纹理 + `Surface→wid`）

- 状态：**已接受**（2026-10-05，K0–K4 已完成并真机验证）
- 决策者：Captain + Architect
- 影响范围：`lib/player/`、`lib/pan115/pan115_player.dart`、`lib/main.dart`、
  `android/app/src/main/{kotlin,cpp}/`、`pubspec.yaml`、`docs/`、`AGENTS.md`

## 背景与问题

原内核是 `media_kit`（Flutter 插件形态封装 libmpv）。三个痛点：

1. **调参受限**：`vo` / `gpu-context` / `hwdec` / `demuxer-*` 这类启动期选项
   只能经插件 API 间接设置，插件没暴露的就够不到。
2. **依赖面大**：media_kit 三件套带各平台预编译库，版本与上游解耦，
   升级节奏不由我们决定。
3. **会话层缺位**：通知栏/蓝牙键/后台播放要另找方案。

用户明确要求：**播放内核改为「安卓原生 + mpv」**，参考
[androidx/media](https://github.com/androidx/media) 与
[mpv-android](https://github.com/mpv-android/mpv-android)。

## 决策

**用 Flutter 纹理（`TextureRegistry.SurfaceProducer`）+ mpv `wid` 作为渲染出口**，
Kotlin/JNI 薄桥直连 libmpv，自持 `libmpv.so`；UI 经 `PlayerFacade` 与内核解耦。

### 关键实现约定（能指到文件）

| 约定 | 位置 |
|---|---|
| 内核抽象（UI 只认它） | `lib/player/kernel.dart` |
| 门面：镜像 media_kit `Player.state/stream` | `lib/player/player_facade.dart` |
| 原生实现（Method/EventChannel） | `lib/player/native/native_kernel.dart` |
| 视频输出层（`Texture(textureId)`） | `lib/player/native/native_video_view.dart` |
| JNI 桥（`attachSurface`/`detachSurface`） | `android/app/src/main/kotlin/com/cineflow/app/player/MPVLib.kt` |
| 纹理 + 通道 + **顺序** | `.../player/PlayerChannel.kt` |
| C 侧：事件线程、JSON 转义、`wid` | `android/app/src/main/cpp/cineflow_mpv.c` |
| 真机验收 | `integration_test/player_kernel_test.dart` |

三条不可动摇的顺序/生命周期约束：

1. `av_jni_set_java_vm` 必须在任何 mpv 调用前注册（放 `JNI_OnLoad`）。
2. `wid` 必须在 `mpv_initialize` **之前** `mpv_set_option`。
   → Kotlin：`createSurface → attachSurface → initialize`。
3. `Surface` 必须 `NewGlobalRef`；事件线程必须在 `mpv_terminate_destroy` 前 join。

### 替代方案（及未选原因）

| 方案 | 为什么没选 |
|---|---|
| `PlatformView` + `GLSurfaceView` + `mpv_render_context`（初版方案） | ① 上游 mpv-android **根本不用 render API**，Android 上无范例可对照；② render API 要求 GL 上下文"调用线程 current 且与创建时同源"，而 PlatformView 合成时序不受控；③ 弹幕叠加要走混合合成，手势仲裁是原方案自己点名的头号风险 |
| `SurfaceView` + `wid`（mpv-android 原样） | 可行，但 SurfaceView 与 Flutter 图层合成更麻烦；纹理方案已被 media_kit_video 在本项目验证过 |
| 继续用 media_kit，只加配置项 | 解决不了"依赖面/版本自控"；且用户明确要求迁移 |
| androidx/media3 **ExoPlayer** 全量替换 | 格式面（MKV/HEVC/DV/PGS）不如 libmpv，且本项目 Emby 库大量依赖直连 |

## 影响范围

- **不破坏 `MediaProvider` 抽象**：本次只换播放内核，媒体库/详情/进度上报不动。
- `player_page.dart`：**零 media_kit 引用**（K4 目标达成），
  仅把 `Player()/VideoController/Video` 换成 `PlayerFacade`。
- `pan115_player.dart`：`Media(url, httpHeaders:)` → `openUrl(url, headers:)`，
  **headers 语义不变**（115 的 UA 绑定 + `download_token` 依赖它）。
- `pubspec.yaml`：移除 `media_kit` / `media_kit_video` / `media_kit_libs_video`。
- `main.dart`：移除 `MediaKit.ensureInitialized()`（新内核按需初始化）。
- `--split-per-abi` 体积策略不再由插件决定：libmpv.so 自持于 `jniLibs/arm64-v8a/`。

## 回退条件

- 真机上出现 libmpv.so 无法覆盖的片源回归（杜比视界/PGS），**且**短期内修不动 →
  恢复 media_kit 依赖（门面 API 面刻意与 media_kit 对齐，回退半径限制在
  `player_facade.dart` + `native_*` 三个文件）。
- 推翻时要更新：`docs/PLAYER-KERNEL.md`、本 ADR（标"被 NNNN 取代"）、
  `AGENTS.md` §1/§6.2、`docs/decisions/README.md` 索引。

## 参考

| 项目 | 许可 | 借鉴点 |
|---|---|---|
| [mpv-android](https://github.com/mpv-android/mpv-android) | MIT | `render.cpp` 的 `Surface→wid`；`MPVView.kt` 的 Android 默认选项（`profile=fast`/`gpu-context=android`/`hwdec=mediacodec,mediacodec-copy`/`ao=audiotrack,opensles`/`demuxer-max-bytes=64MiB`）；`BackgroundPlaybackService` 只做"防杀+通知" |
| [androidx/media](https://github.com/androidx/media) | Apache-2.0 | M3 会话层；`SimpleBasePlayer` 包自定义 player；**音频焦点不代劳** |
| [media-kit/media-kit](https://github.com/media-kit/media-kit) | MIT | `VideoOutput.java` 的 `TextureRegistry.SurfaceProducer → wid`（本项目纹理路线直接参照） |
| [mpv-player/mpv](https://github.com/mpv-player/mpv) | LGPL-2.1+ | `client.h`：`wid` 只能在 initialize 前设 |
| [jarnedemeulemeester/libmpv-android](https://github.com/jarnedemeulemeester/libmpv-android) | MIT | 预编译 libmpv 的获取途径（本项目最终自带 .so） |

## 变更日志

| 版本 | 日期 | 变更 |
|---|---|---|
| v1.0 | 2026-10-05 | 初版：记录内核迁移决策、渲染出口选型（纹理 vs PlatformView）、三条顺序约束、回退条件与参考项目 |
