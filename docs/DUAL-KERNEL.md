# 双内核播放处理方案

> **本文档描述 CineFlow 播放器的双内核（mpv / Media3）架构、选择逻辑与迁移机制。**
> 所有内容**与代码逐条对齐**，不是设计愿景。
>
> - 涉及文件：`lib/player/kernel.dart`、`kernel_factory.dart`、
>   `kernel_auto_select.dart`、`kernel_traits_adapter.dart`、
>   `native/native_kernel.dart`、`media3/media3_kernel.dart`、
>   `player_flow_page.dart`
> - 相关 ADR：[`0009-native-mpv-kernel.md`](decisions/0009-native-mpv-kernel.md)
> - 相关测试：`kernel_auto_select_test.dart`、`kernel_hdr_select_test.dart`、
>   `kernel_hdr_wiring_test.dart`、`player_dual_kernel_test.dart`

---

## 1. 为什么要双内核

单个内核无法同时满足"**什么都能播**"与"**系统集成好**"，两者是**结构性冲突**：

| 维度 | mpv（原生 libmpv） | Media3（ExoPlayer） |
|---|---|---|
| 格式覆盖 | **几乎通吃**（自带 ffmpeg 解封装） | 依赖**系统 MediaCodec**，冷门容器/编码播不了 |
| HDR / 杜比视界 | ✅ 有**软件回退 + tone-mapping** | ⚠️ **依机型而异**，多数只解基础层 |
| 画面滤镜（亮度/对比度/饱和度/色相） | ✅ 走 `vo=gpu` shader | ❌ 需自叠 GL 层 |
| 音频 / 字幕延迟 | ✅ `audio-delay` / `sub-delay` | ❌ 无等价属性 |
| 运行中切硬/软解 | ✅ `hwdec` + 重载视频轨 | ❌ 需重建 `RenderersFactory` |
| HLS 分片续播 / 码率切换 | ⚠️ 可用但非强项 | ✅ **成熟**（引入它的主要价值） |
| 系统媒体会话（通知栏/蓝牙键/音频焦点） | ⚠️ 需自己做 | ✅ 官方栈，集成顺畅 |

**结论**：mpv 是**默认**（"能播"是底线），Media3 在它**明确更强**的场景（HLS/系统集成）才上。

---

## 2. 架构总览

```
                    ┌─────────────────────────────┐
                    │      UI 层（presentation）    │
                    │  只认 PlayerKernel 抽象接口     │
                    └──────────────┬──────────────┘
                                   │ supports(EngineFeature) 能力协商
                    ┌──────────────▼──────────────┐
                    │   PlayerKernelFactory        │ ← 唯一的实例化点
                    │   create(type) / canHandle() │
                    └──────────────┬──────────────┘
                                   │
              ┌────────────────────┴────────────────────┐
              ▼                                          ▼
    ┌──────────────────┐                      ┌──────────────────┐
    │  NativeKernel    │                      │  Media3Kernel    │
    │  （mpv，默认）    │                      │  （ExoPlayer）    │
    │  Kotlin+C / JNI  │                      │  Kotlin          │
    │  Flutter Texture │                      │  Flutter Texture │
    └──────────────────┘                      └──────────────────┘
                                   │
                    ┌──────────────▼──────────────┐
                    │   KernelAutoSelect（纯函数）   │ ← 决策点
                    │   traits + preference → 决策   │
                    └─────────────────────────────┘
```

### 设计要点（每条都有代价，不是随手写的）

| 决定 | 理由 |
|---|---|
| **抽象接口 `PlayerKernel`**，UI 不 import 具体实现 | 换内核不改 UI；测试可注入假内核 |
| **能力协商 `supports(EngineFeature)`** | UI 据此**置灰**入口，而不是"点了没反应" |
| **决策是纯函数**（`KernelAutoSelect`，无状态） | 可精确断言每条规则，不必起真实播放器 |
| **两者事件形状完全一致** | 共用 Dart 侧状态解析，避免"两个内核两套 UI 逻辑" |
| **`KernelFactory` 是唯一实例化点** | 防止别处 `new NativeKernel()` 绕过调试注入 |

---

## 3. 抽象接口 `PlayerKernel`

### 3.1 能力枚举 `EngineFeature`

```dart
enum EngineFeature {
  videoFilters,       // 画面滤镜：亮度 / 对比度 / 饱和度 / 色相
  audioDelay,         // 音频延迟调节
  subtitleDelay,      // 字幕延迟调节
  decodeMode,         // 切换硬解/软解
  externalSubtitle,   // 外挂字幕文件
}
```

两内核的 `supports()` 声明（**权威来源，勿凭记忆**）：

| 能力 | mpv | Media3 | Media3 不支持的原因 |
|---|:---:|:---:|---|
| `videoFilters` | ✅ | ❌ | 需自叠 GL 层做像素处理，本内核不做 |
| `audioDelay` | ✅ | ❌ | Media3 无等价属性 |
| `subtitleDelay` | ✅ | ❌ | 同上 |
| `decodeMode` | ✅ | ❌ | 需重建 `RenderersFactory`，无法热切 |
| `externalSubtitle` | ✅ | ✅ | — |

> **"如实声明"比"假装支持"重要。** UI 会据此把入口置灰 ——
> 用户看到"此内核不支持"，而不是"点了没反应"（后者会让人以为功能坏了）。
> 本项目踩过同类坑：`default_rate` 有读无写，用户设了倍速却没生效。

### 3.2 事件形状统一（关键约束）

两个内核**共用** Dart 侧的状态解析（`KernelState` / `KernelTracks`）。
Kotlin 侧 `Media3Channel.emitTracks` **刻意按 mpv 的字段名输出**
（`demux-channels` / `ff-index` …）—— 否则其中一边会**静默解析出空轨道**。

这是"两内核一套 UI"能成立的前提，**改任一边的字段名都要同步改另一边**。

### 3.3 输出方式统一

两者都走 **`setVideoSurface(Flutter Texture)`**：

| | mpv | Media3 |
|---|---|---|
| 渲染 | `vo=gpu` + `gpu-context=android`，mpv 自建 EGL | `ExoPlayer.setVideoSurface()` |
| Dart 侧 | `Texture(textureId:)` | `Texture(textureId:)` |
| `viewType` | 都是 `null` | 都是 `null` |

⇒ **Dart 渲染代码无需分支**（`AspectVideo` 对两个内核完全一样）。

---

## 4. 内核选择：`KernelAutoSelect`

### 4.1 两级决策

```dart
static KernelDecision select(MediaTraits traits, {KernelPreference preference}) {
  if (preference.isExplicit) {
    return KernelDecision(kernel: preference.kernelType,
        reason: '你在设置里指定了「${preference.label}」',
        confidence: KernelConfidence.high);
  }
  return _selectAuto(traits);
}
```

**用户显式指定的优先级最高** —— 自动逻辑不得"聪明"地覆盖它。

### 4.2 自动规则（**顺序即优先级**，改顺序会改变行为）

| # | 条件 | 选择 | 理由 |
|---|---|---|---|
| **0** | **杜比视界 / HDR** | **mpv** | 见下方专节 |
| 1 | HLS / 转码流 | Media3 | 分片续播、码率切换更成熟 |
| 2 | mpv 独占容器（前置） | mpv | RMVB/WMV/ASF/VOB/FLV —— 系统解码器通常没有 |
| 3 | `shortSide >= 2000`（4K+） | Media3 | 走系统硬解，能效与稳定性更好 |
| 4 | 有外挂字幕 | mpv | 对 GBK/BIG5、ASS 特效、字体回退支持更好 |
| 5 | 其余 | mpv | 保守：格式覆盖最全 |

> ⚠️ **规则 2 在代码里排在规则 1 之前**（"前置"）：
> 冷门格式即便走 HLS，也**播放优先于体验**。

### 4.3 ★ 规则 0：HDR / 杜比视界（2026-10-09 新增）

**借鉴来源**：`zzzwannasleep/LinPlayer` 的能力表
（"mpv 播放内核 —— 全格式；**HDR / 杜比视界自动切软解**"）。

> ⚠️ **许可说明**：该仓库 LICENSE 为 **AGPL-3.0**（34,525 字节）。
> 本项目**只提取架构思路，未抄任何代码**（AGENTS §6.8 / §10.6 纪律）。

**原理**（不是照搬结论）：

- **杜比视界在安卓硬解路径上普遍失败或降级**：
  MediaCodec 的 DV 支持**依设备/厂商而异** —— 多数机器只解出"基础层"
  （画面**发灰/偏暗**），少数直接解不了
- mpv 在 `hwdec=no` 时有**软件回退 + tone-mapping**
- ⇒ 对 DV/HDR 片源，**宁可软解也不要硬解出错误画面**

这是本仓库既有原则的延续：**画面正确 > 性能**
（与"冷门容器优先 mpv"同一条）。

**为什么放在最前面（优先于 HLS）**：
DV 片源若走 Media3 且设备不支持 DV 硬解，会得到**错误画面** ——
那比"用哪个内核"严重得多。

**判定逻辑**：

```dart
bool get isDolbyVision {   // 'dovi' / 'dv' / 'dolby'，大小写不敏感
  final v = videoRange?.toLowerCase() ?? '';
  return v.contains('dovi') || v.contains('dv') || v.contains('dolby');
}

bool get isHdr {           // DV 是 HDR 的子集
  if (isDolbyVision) return true;
  final v = videoRange?.toLowerCase() ?? '';
  return v.contains('hdr') || v.contains('hlg') || v.contains('pq');
}
```

**⚠️ 元数据缺失 ≠ HDR**：`videoRange == null` 时两者都是 `false` ——
否则会把所有 4K 片源都推给 mpv，反而伤害"能效更好的硬解通路"。

### 4.4 决策输出的三要素

```dart
class KernelDecision {
  final KernelType kernel;          // 选谁
  final String reason;              // 为什么（**给用户看**）
  final KernelConfidence confidence; // 明确 / 保守
}
```

`reason` 会展示在播放器 UI 上 —— 用户能看到"为什么用了这个内核"，
而不是面对一个没有解释的自动行为。

---

## 5. 特征提取：`traitsFromLaunch`

`PlaybackLaunch`（服务端返回的播放信息）→ `MediaTraits`（决策输入）：

| `MediaTraits` 字段 | 来源 | 备注 |
|---|---|---|
| `container` | `launch.container`，缺失时从 URL 后缀推断 | 服务端不一定给 |
| `videoCodec` / `audioCodec` | `streams` 里对应 `Type` 的 `codec` | |
| `width` / `height` | 同上取 `width` / `height` | |
| `bitrate` | `launch.bitrate` | |
| `isHls` | URL 含 `.m3u8` 或 `isTranscoding` | |
| `hasExternalSubtitle` | 任一 `Subtitle` 流 `isExternal` | |
| **`videoRange`** | **`s.videoRange`**（`VideoRange` / `VideoRangeType`） | ★ 2026-10-09 接通 |

### ★ 一处"数据有、接线断"的真实缺口（已修）

修复前的三段链路：

```
① MediaStream 解析 videoRange（SDR/HDR10/DOVI）   models.dart:538   ✅ 有
② traitsFromLaunch 读它                            ✗ 从未读 s.videoRange
③ KernelAutoSelect 用它判定                         ✗ MediaTraits 无 hdr 字段
```

⇒ HDR 信息在数据层躺着，**从未进入内核决策**。
这与"播放列表不显示集数"是同一类缺陷（数据有、接线断）。

**由 `kernel_hdr_wiring_test.dart` 专守这一段** —— 因为
`kernel_hdr_select_test.dart` 直接构造 `MediaTraits`、**绕过了 adapter**，
中间段断了它照样绿（这是反向注入暴露出的测试盲区）。

---

## 6. 运行中换内核：`_adaptKernel`

### 6.1 触发时机

`_startEpisode` 里，**拿到 `resolvePlayback` 之后**（此时才知道片源特征）：

```dart
final launch = await api.resolvePlayback(...);
final adapted = await _adaptKernel(launch);   // ← 决策点
if (adapted == null) return;                  // 换内核中，本次起播交给新内核
final k2 = adapted;
await k2.open(...);
```

> ⚠️ `_boot` 建内核时**只能按用户偏好**，不能做自动适配 ——
> 适配输入（容器/编码/HLS/HDR）要等 `resolvePlayback` 才有。

### 6.2 换内核流程（7 步，顺序不可乱）

```dart
if (decision.kernel == _activeKernelType) return current;  // ① 决策未变 → 零开销沿用

final resumeAt = current.state.position;   // ② 记住进度（换完续播，不能从头）

_switching = true;
for (final sub in _subs) unawaited(sub.cancel());  // ③ 先摘订阅
_subs.clear();                                     //    （旧内核 dispose 后流会关闭）
await current.dispose();                           // ④ 销毁旧内核
final next = PlayerKernelFactory.create(...);
await next.ensureTexture();                        // ⑤ 建新内核 + 纹理
_kernel = next; _activeKernelType = ...; _textureId = next.textureId;
_wireKernel(next);                                 // ⑥ 重挂状态回流
setState(() {});                                   //    纹理 id 变了，视频层必须重建
_switching = false;
// ⑦ 用新内核重新起播（保持进度）
```

**每一步的理由**：

| 步 | 不做会怎样 |
|---|---|
| ① 决策未变沿用 | 每集都重建内核 → 几百 ms 无谓开销 |
| ② 记进度 | 换内核后从头播（用户感知极差）|
| ③ 先摘订阅 | 旧内核 `dispose` 后流关闭 → **未捕获错误** |
| ④ 先 dispose | 两个内核同时持有原生播放器 → 资源冲突/崩溃 |
| ⑤ `ensureTexture` | mpv 的 `wid` **必须在 `mpv_initialize` 之前**设好 |
| ⑥ 重挂 + `setState` | 状态回流断掉；纹理 id 变了但 UI 仍用旧 id → 黑屏 |

### 6.3 `_activeKernelType` vs `_preference`

| 字段 | 含义 |
|---|---|
| `_preference` | **用户的意愿**（可能是 `auto`）|
| `_activeKernelType` | **实际落地的结果**（`auto` 解析后）|

⚠️ **决策比较必须用 `_activeKernelType`** ——
拿偏好比会把"`auto` 已解析成 mpv"误判成不一致，导致每集都重建内核。

---

## 7. 各内核的实现要点

### 7.1 mpv 内核（`NativeKernel`，默认）

**Java/Kotlin 侧初始化顺序（钉死）**：

```kotlin
MPVLib.nativeCreate()
MPVLib.setOptionString("vo", "gpu")            // ← 必须先于 initialize
MPVLib.setOptionString("gpu-context", "android")   // mpv 自建 EGL
MPVLib.setOptionString("hwdec", "mediacodec,mediacodec-copy")
MPVLib.setOptionString("demuxer-max-bytes", "64MiB")
MPVLib.setOptionString("demuxer-lavf-analyzeduration", "1")   // 起播优化
MPVLib.nativeInit()                            // = mpv_initialize
```

| 项 | 值 | 理由 |
|---|---|---|
| `vo` | `gpu` | 保留 shader 能力（画面滤镜/色调映射）。**不用 `mediacodec_embed`** —— 它会绕开 GPU 管线，导致画面调节/字幕 OSD/`video-sync` **全部失效** |
| `hwdec`（**初始**） | `mediacodec,mediacodec-copy` | 与 mpv-android 同款组合；`mediacodec-copy` 作为回退（拷回内存，兼容性更好） |
| `hwdec`（**运行时切换**） | `auto-safe` ↔ `no` | `auto-safe` 只挑已知安全的后端（`auto` 会试所有后端含不稳定的）|
| `hwdec` 生效 | 需 `video-reload` | mpv 的行为：切 `hwdec` 要重载视频轨（**不重开文件**，播放位置保持）|
| `analyzeduration` | **1**（默认 5） | ffmpeg 默认要读够 5 秒数据才定流信息；对网络源是纯等待。**实测起播"点到出画面" 9087 → 7584 ms** |
| `probesize` | `2097152`（2MB，默认 5MB） | 同上：网络源读满 5MB 也要时间 |

**性能：位置推送限流**（真机 Janky 33% 的根因修复）

mpv 的 `time-pos` 是**原生观察属性**（每帧推送，30–60 次/秒）。
原来每次 `_pushState` → 整页 Stack 重建（视频层/弹幕层/手势层/反馈层/控制层）。

```dart
void _pushState(KernelState s, {bool isPositionOnly = false}) {
  if (!isPositionOnly) { ...; add(s); return; }   // 其他字段立即推送
  // 仅位置变化 → 250ms 窗口限流（每秒最多 4 次）
}
```

- **其他字段**（playing/duration/buffer/rate/volume）**立即推送** ——
  它们频率天然低，且必须及时（否则点暂停后按钮 250ms 才变）
- **补发机制** `flushPendingPosition()`：由 UI 侧 250ms 定时器驱动，
  否则暂停/seek 后进度条停在旧位置

### 7.2 Media3 内核（`Media3Kernel`）

```kotlin
val renderers = DefaultRenderersFactory(context)
    .setEnableDecoderFallback(true)      // 解码器回退（已在用）
val p = ExoPlayer.Builder(context, renderers)
    .setHandleAudioBecomingNoisy(true)   // 拔耳机自动暂停
    .build()
p.setVideoSurface(producer.surface)      // 与 mpv 一致的纹理输出
```

**不引 `media3-ui`**：我们用 `setVideoSurface` 输出，不需要 Media3 自带的
`PlayerView`（引了会多一套 View 层与依赖）。

---

## 8. 设置入口

「我的 → 播放内核」三档：

| 选项 | 行为 |
|---|---|
| **自动**（默认） | 按 §4.2 的规则挑 |
| **mpv** | 强制 mpv |
| **Media3** | 强制 Media3 |

页面还展示**规则表**与**已知局限**（如实告知用户 Media3 不支持哪些能力）。

---

## 9. 测试策略

| 文件 | 守什么 |
|---|---|
| `kernel_auto_select_test.dart` | 5 条自动规则的边界 |
| `kernel_hdr_select_test.dart` | HDR/DV 判定 + 决策 + **不被显式选择覆盖** |
| `kernel_hdr_wiring_test.dart` | **链路完整性**（数据层→adapter→决策）|
| `player_dual_kernel_test.dart` | 两内核事件形状一致、能力声明 |
| `player_dead_button_guard_test.dart` | "点了没反应"型缺陷 |

### 反向注入纪律（每个新测试必须做）

**制造它应该抓住的缺陷，确认变红**。本项目已两次遇到"假绿"：

1. **测试绕过中间层**：`kernel_hdr_select_test` 直接构造 `MediaTraits`，
   把 adapter 的接线删掉它**照样绿** ⇒ 补 `kernel_hdr_wiring_test`
2. **注释误匹配**：断言 `contains('s.videoRange')`，但该字符串
   **还出现在注释里** ⇒ 删掉真代码后注释仍匹配 ⇒ 假绿
   ⇒ 统一用 `readCode()`（**先剥注释再断言**）

> ⚠️ 注入后必须确认 `analyze error=0` ——
> 否则"变红"可能是**编译错**而不是断言抓到的（本项目踩过两次）。

---

## 10. 已知局限（如实记录）

| 局限 | 说明 |
|---|---|
| **HDR 判定依赖服务端元数据** | 服务端不给 `VideoRange` 时无法判定（`null` 不误判为 HDR）|
| **Media3 能力缺口** | 画面滤镜 / 音频字幕延迟 / 运行中切硬软解 —— 已在 UI 置灰 |
| **换内核有短暂黑屏** | 销毁+重建纹理期间（几百 ms），UI 显示黑屏（与首次起播一致）|
| **HLS 走 Media3 是启发式** | 依据是 URL/`isTranscoding`，不是探测实际协议 |
| **未做内核预创建** | 双内核同时活着 = 两份解码器+缓冲，K40 上有内存风险 ⇒ **有意不做** |

---

## 11. 改动本模块前必读

1. **`vo` / `hwdec` 必须在 `mpv_initialize` 之前设** —— 之后设只是 property，无效
2. **改事件字段名要两边同步** —— 否则一边静默解析出空轨道
3. **决策比较用 `_activeKernelType`，不是 `_preference`**
4. **换内核的 7 步顺序不可乱** —— 尤其"先摘订阅再 dispose"
5. **新增自动规则要写进 §4.2 的表**，并补"该规则的边界"测试 + 反向注入
6. **不要为了"看起来更强"声明不支持的能力** —— UI 会据此置灰，假装支持会变成"点了没反应"
