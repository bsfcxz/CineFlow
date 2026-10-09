# 双内核播放：完整思维链与优化链

> **本文档记录 CineFlow 双内核（mpv / Media3）从"为什么这样设计"到"还能怎么优化"的完整推导。**
>
> 与 [`DUAL-KERNEL.md`](DUAL-KERNEL.md) 的分工：
> · 那篇是**架构说明书**（现状是什么、改代码前必读什么）
> · 本篇是**推导过程 + 优化路线**（每一步为什么这么定、代价是什么、下一步做什么）
>
> ⚠️ 本文所有数字**都有出处**（实测日志或台账轮次）。未实测的标注为"待验证"。
> 这是本仓库的纪律：`AGENTS.md` §8.4「数字必须来自实际输出，不得推算」。

---

## 第一部分 · 思维链：为什么走到今天这个形态

### 1.1 起点：一个无法两全的取舍

选播放内核时，面对的是**结构性冲突**，不是"哪个更好"：

| 维度 | mpv（libmpv） | Media3（ExoPlayer） |
|---|---|---|
| 格式覆盖 | ✅ 几乎通吃（自带 ffmpeg 解封装）| ❌ 依赖系统 MediaCodec |
| HDR / DV | ✅ 软件回退 + tone-mapping | ⚠️ 依机型，多数只解基础层 |
| 画面滤镜 | ✅ `vo=gpu` shader | ❌ 需自叠 GL 层 |
| 音视频延迟 | ✅ `audio-delay`/`sub-delay` | ❌ 无等价属性 |
| 运行中切硬/软解 | ✅ `hwdec` + video-reload | ❌ 需重建 RenderersFactory |
| HLS / 分片续播 | ⚠️ 可用但非强项 | ✅ 成熟 |
| 系统集成（通知栏/耳机键）| ⚠️ 需自己做 | ✅ 官方栈（`media3-session`）|

**判断**：没有一侧能全胜。⇒ **不是二选一，而是各管各的场景。**

### 1.2 决策一：抽象在前，实现在后

**做法**：先定 `PlayerKernel` 抽象接口（`kernel.dart`，397 行），
UI 只依赖它，**不 import 任何具体实现**。

**为什么**（代价写在每一条后面）：

| 决定 | 收益 | 代价 |
|---|---|---|
| 抽 `PlayerKernel` 接口 | 换内核不改 UI；测试可注入假内核 | 多一层间接 |
| **能力协商** `supports(EngineFeature)` | UI 据此**置灰**入口，而非"点了没反应" | 每个能力要如实声明 |
| **事件形状统一** | 两内核共用 Dart 侧解析器 | Kotlin 侧必须**迁就** mpv 的字段名 |
| `KernelFactory` 唯一实例化点 | 防止别处 `new NativeKernel()` 绕过调试注入 | — |

**★ 事件形状统一是最容易被低估的一条。**
`Media3Channel.emitTracks` 刻意按 mpv 的字段名输出
（`demux-channels` / `ff-index`…）—— 否则"两个内核两套 UI 逻辑"。
代价是：**改任一边的字段名都要同步改另一边**。

### 1.3 决策二：默认必须是 mpv

**推理链**：

1. "能播"是底线 —— 播不了的话，其他优点都没意义
2. mpv 的格式覆盖是**超集**（自带 ffmpeg）
3. Media3 的优势（HLS/系统集成）是**体验增量**，不是底线

⇒ **默认 mpv，只在它明确更强或明确不行时才上 Media3。**

### 1.4 决策三：渲染出口统一为 Flutter 纹理

**两种方案**：

| 方案 | 说明 | 结论 |
|---|---|---|
| `PlatformView` + `mpv_render_context` | Dart 侧管理 GL 上下文 | ❌ 上游（mpv-android）**根本不用 render API** |
| **纹理**：`attachSurface → wid`，mpv 自建 EGL | 与 mpv-android 同款 | ✅ 采用 |

**为什么纹理更好**（实测验证过）：
· 纹理是**普通 Flutter 图层** ⇒ 弹幕 `CustomPainter`、手势、控制层**直接叠在上面**
· 两内核输出方式一致（都是 `Texture(textureId:)`）⇒ **Dart 渲染代码无需分支**

**踩过的坑（见 `AGENTS.md` §6.2）**：
· `wid` 必须在 `mpv_initialize` **之前**设 —— 之后设置**不再生效**
· Surface 必须 `NewGlobalRef`（局部引用 JNI 返回即失效）
· `av_jni_set_java_vm` 必须注册 —— 不注册时现象极误导：
  **解封装完全正常**（能列出全部轨道）但 GPU 上下文初始化失败 ⇒
  **"能解析出轨道"不等于"能播"**

### 1.5 决策四：内核选择做成**纯函数**

`KernelAutoSelect` 无状态、无 IO。**为什么值得**：

· 每条规则可**精确断言**，不必起真实播放器
· 决策理由（`reason`）能直接展示给用户 —— 用户看到"为什么用了这个内核"

**实际规则（代码里的顺序，`kernel_auto_select.dart`）**：

| 优先级 | 条件 | 选谁 | 理由 |
|---|---|---|---|
| **0** | `isHdr`（含 DV）| **mpv** | 见 §1.6 |
| 1 | mpv 独占容器 | mpv | RMVB/WMV/ASF/VOB/FLV — 系统解码器通常没有 |
| 2 | HLS / 转码流 | Media3 | 分片续播、码率切换更成熟 |
| 3 | `shortSide >= 2000` | Media3 | 高分辨率走系统硬解能效更好 |
| 4 | 有外挂字幕 | mpv | GBK/BIG5、ASS 特效、字体回退更好 |
| 5 | 其余 | mpv | 保守：格式覆盖最全 |

> ⚠️ **注意 1 与 2 的相对顺序**：mpv 独占容器**在 HLS 之前**。
> 冷门格式即便走 HLS，也**播放优先于体验**。
> （我曾在 `DUAL-KERNEL.md` 里把这条写成"规则 2 前置"，表述不清 ——
> 以**代码顺序**为准。）

### 1.6 决策五：HDR/DV 优先 mpv（规则 0）

**引入背景**：用户给了 `zzzwannasleep/LinPlayer` 作为参考。
该仓库 LICENSE 是 **AGPL-3.0** ⇒ 按 `AGENTS.md` §6.8/§10.6
**只提取架构思路、零代码拷贝**。

**它给的唯一有用一条**：「HDR / 杜比视界自动切软解」。

**为什么这条值得采纳**（自己推导，不是照搬）：
· **MediaCodec 的 DV 支持依设备而异** —— 多数机器只解"基础层"
  （画面**发灰/偏暗**），少数直接解不了
· mpv 在 `hwdec=no` 时有**软件回退 + tone-mapping**
· ⇒ 对 DV/HDR：**宁可软解，也不要硬解出错误画面**

**这与本仓库既有原则一致**：**画面正确 > 性能**。

**为什么放最前面**：DV 片源若走 Media3 且设备不支持，会得到**错误画面** ——
那比"用哪个内核"严重得多。

**⚠️ 判定必须防"元数据缺失"**：
```dart
videoRange == null ⇒ isHdr = false
```
否则会把所有 4K 片源都推给 mpv，反而伤害"能效更好的硬解通路"。

### 1.7 决策六：会话层命令**回 Dart 执行**

K3（媒体会话层）时面对的关键选择：

| 方案 | 问题 |
|---|---|
| 会话层**直接**控制原生播放器 | ❌ **两个主** —— Dart 也控制播放器（UI 按钮/手势/自动连播），两边各自改状态必然不同步 |
| **会话层把命令转发给 Dart**，走既有控制器 | ✅ **单一事实源** |

**本项目选后者。** 但**这里踩了一个大坑**（见下）。

### 1.8 ★ 踩坑：`PlaybackController` 是**纯状态机**

按"唯一控制入口"的思路，我把会话命令接到了
`PlaybackController.pause()` —— 结果：

```
媒体键命令一路走到 Dart（日志有 `会话命令: pause`）
但**画面毫无变化**      ← 排查了整整一轮
```

**根因**：`PlaybackController.play()/pause()` 是**纯状态机**
（其注释明确写着"与引擎解耦，便于单测"）——
**只翻标志位，内核收不到任何指令**。

**而 UI 的播放按钮走的是页面自己的方法**：
```dart
if (k.state.playing) { await k.pause(); } else { await k.play(); }  // 直调内核
```

⇒ **修法**：会话命令**镜像页面的写法**直调 `_kernel`。

**教训（值得写进手册级）**：
> "唯一控制入口"这个抽象**在宏事件（换集/seek 上报）上成立**，
> 但**播放/暂停这类直达内核的原子操作**，页面用的是 `_kernel` 直调。
> ⇒ **不要想当然地套抽象，要读实际调用点。**

### 1.9 ★ 踩坑：通知栏不贴 = 没调 `addSession()`

K3 完成后真机验证，发现：MediaSession 已注册、权限已给，
**但通知栏什么都没有**。

**逐段加日志才定位到**：
```
Dart updateState 到达          ✅
  → bridge.onStateChanged 触发  ✅
    → invalidateState()         ✅
      → getState() 每秒被调用    ✅
        → 但 onUpdateNotification **从不被调用** ❌
```

**根因**：`MediaSession.Builder().build()` **只创建会话**，
**不会**把它纳入通知管理。注册要靠 `addSession()`，
而它只由 `onStartCommand`（带特定 intent 时）或**显式调用**触发。

**★ 最坑的地方**：它**完全不影响媒体键**（那走 MediaButton 路径）⇒
现象是"**媒体键能用，但通知栏什么都没有**"，极易误判为权限问题。

**关键认知**：`dumpsys media_session` 显示 `active=true` 与"能贴通知"是**两回事**。

### 1.10 ★ 踩坑：验证对象搞错（自检查的是旧内核）

`_verifyMpvConfig(kernel)` 传的是 `_boot` 里的**局部变量**，
而 `_adaptKernel` 会**替换** `_kernel` ⇒ 换内核后自检查的是**旧对象**：

```
[Kernel] 换内核 mpv -> media3（2160p 高分辨率…）
[MPV-CFG] kernel = JK (engine=native)      ← 仍报 mpv！
[MPV-CFG] ⚠️ tone-mapping 未生效           ← 误报
```

**我本人被这条误报骗了一次**（一度以为 tone-mapping 失效）。

**修了三处**：
1. 传 `_kernel`（当前内核）
2. **两个分支都自检** —— "决策未变"分支原先提前 `return`，
   导致**正常起播根本没有自检日志**
3. 加**引擎守卫**：Media3 上跳过 mpv 选项检查
   （`Media3Kernel.getOption` 是空实现，查它必然误报）

**这条与"两个变量表示同一个东西"同源** ——
与第 39 轮 `_index` vs `playlist.currentIndex` 是**同一类**缺陷。

---

## 第二部分 · 优化链：做了什么、为什么、效果多少

### 2.1 起播优化（第 34–35 轮）

**第一步：先埋点，不猜**（第 34 轮）

真机 3 次采样（中位）：

| 阶段 | 耗时 | 说明 |
|---|---|---|
| `prefRead` | 245 ms | 读偏好（Keystore 解密）|
| `kernelCreate` | 4 ms | |
| `resolve` | 33 ms | Emby 取直链 |
| `open` | 36 ms | |
| `seek`+`rate` | 8 ms | |
| **Dart 命令链合计** | **314 ms** | ← **只占 3%** |
| `DEMUX_DONE` | 4255 ms | 容器探测完成 |
| `FIRST_FRAME` | 4513 ms | 首帧渲染 |
| **点到出画面** | **9087 ms** | |

**★ 结论（反直觉）**：Dart 侧只占 314ms ⇒ **慢在 mpv 内部，不在网络请求层。**

**第二步：改 ffmpeg 分析窗口**（第 35 轮）

**根因**：ffmpeg 默认 `analyzeduration` = **5 秒** ——
要读够 5 秒数据才确定流信息（轨道/编码/时长）。
对**网络源**这就是纯等待，与实测的 4.2 秒高度吻合。

**改动**：
```
demuxer-lavf-analyzeduration = 5 → 1
demuxer-lavf-probesize       = 5MB → 2MB
```

**实测效果**：`点到出画面` **9087 → 7584 ms（−16.5%）**。

> ⚠️ **附带修正**：首帧探针原来是错的 —— 旧判据 `position > 0`
> 在**有续播进度时给假值**。改为 `position` **变化** ≥ 500ms 才算首帧。
> **所以 −16.5% 这个数字本身也有探针修正的贡献，不能全归因于 analyzeduration。**
> （第 35 轮台账明确记了这一点。）

**⚠️ 取舍（如实说）**：分析窗口越短，**冷门容器/异常流的探测准确率越低**。
1 秒对 Emby 直连的常见容器（mp4/mkv）足够；
若将来遇到"轨道识别不全/时长不对"，**先回调这一项**。

### 2.2 卡顿优化（第 32 轮）

**第一步：拿硬数据**（不是感觉）

```
真机 dumpsys gfxinfo 实测:
  Janky frames    6/18 = 33.33%
  Slow UI thread  3
  p90             97 ms
  p95             150 ms
```

**根因**：mpv 的 `time-pos` 是**原生观察属性**（每帧推送，30–60 次/秒）。
原来每次 `_pushState` → **整页 Stack 重建**
（视频层/弹幕层/手势层/反馈层/控制层）。

**改动**：位置推送**限流到 250ms**（每秒最多 4 次）。
· **其他字段**（playing/duration/buffer/rate/volume）**立即推送** ——
  它们频率天然低且必须及时（否则点暂停后按钮 250ms 才变）
· 补发机制 `flushPendingPosition()`：由 UI 侧 250ms 定时器驱动，
  否则暂停/seek 后进度条**停在旧位置**

**实测效果**：`p50 6ms / p90 12ms / p95 12ms`（p95 从 150ms 降下来）。

**回归验证**：进度条真机确认推进 `06:36 → 06:43 → 06:50 → 06:57`。

### 2.3 音画/画质优化（第 43 轮）

**背景**：我们把 DV/HDR 路由给 mpv，**却一项 tone-mapping 都没配** ——
等于"把片送过去却不给工具"。

**逐条核实建议（不凭印象）**：对着 `libmpv.so` 字符串表查每个选项，
发现那份建议有 **5 处事实错误**（`hwdec-codecs`/`demuxer-max-back-bytes` 我们已设；
`vd-queue-max-bytes`/`target-colorspace-hint`/`vo=gpu-next` **该构建里不存在**）。

**实际加的（全部实测存在于本构建）**：

| 类别 | 选项 |
|---|---|
| tone-mapping 链路 | `tone-mapping=bt.2390`、`tone-mapping-mode=auto`、`hdr-compute-peak=yes`、`target-peak=auto`、`gamut-mapping-mode=auto`、`target-prim=auto` |
| 流畅度 | `video-sync=display-resample`、`interpolation=yes`、`tscale=box` |
| 丢帧策略 | `framedrop=vo`（只允许渲染端丢，**解码器不丢完整帧**）|
| 音频 | `audio-buffer=0.5`（消爆音）|
| 缓冲分档 | `demuxer-max-bytes` 64→**128MiB**、`demuxer-max-back-bytes` 32→**64MiB**、`cache-secs=30` |

**真机验证**：`[MPV-CFG] tone-mapping=bt.2390`（零告警）。

### 2.4 会话层（第 44 轮，K3）

**一次解决四件事**：

| 能力 | 实现 |
|---|---|
| 通知栏控制 | `MediaSession` + `media3-session` 自带通知 |
| 蓝牙/有线耳机键 | `MediaSession`（系统按会话路由，**不要求 App 聚焦**）|
| 后台播放 | `MediaSessionService` 前台服务 |
| **音频焦点** | **自研** `AudioFocusManager`（Media3 **不代劳**）|

**为什么焦点必须自研**（上游明确不提供）：
不做焦点的后果**用户可感知**：
· 来电/微信语音进来时视频**不停**
· 别的 App 放音乐，两边**同时响**
· 拔耳机时**外放突然出声**

**三种失焦分开处理**：
| 类型 | 场景 | 做法 |
|---|---|---|
| `AUDIOFOCUS_LOSS` | 别的播放器永久接管 | **暂停**，不自动恢复 |
| `LOSS_TRANSIENT` | 来电、导航 | 暂停；焦点回来后**自动续播** |
| `LOSS_TRANSIENT_CAN_DUCK` | 通知音 | **不暂停**，压低音量 |

**⚠️ 最易写错的一条**：把 `CAN_DUCK` 当 `TRANSIENT` 处理 ⇒
每来一条通知视频都暂停一下。

**真机验证 7/7**：媒体键双向（暂停→播放→暂停）、
通知栏内容正确（`第 14 集 · 秦明…` + 剧名 + 3 个按钮）、焦点已持。

### 2.5 音量架构重构（第 46 轮）

**问题**（旧实现）：手势改的是**内核音量** ⇒
· 按手机侧边键时 App 滑块**不动**（看起来像坏了）
· 两者**相乘**：系统 50% × 内核 50% = 实际 **25%**（双重衰减）

**参考实现核实**（读了源码，不凭描述）：
· **mpv-android** `MPVActivity.kt:2102` → `setStreamVolume(STREAM_MUSIC)`
· **Next Player** `VolumeState.kt:169` → 同样走系统音量

**新架构**：手势/滑块/侧边键**全部**落到系统媒体音量；
内核音量**恒定 unity** ⇒ 消除双重衰减。

**★ 唯一例外：`duck` 必须走内核** ——
若 duck 改系统音量，会把**用户手机的媒体音量**改小
且**不会自动恢复**（退出 App 后声音莫名变小）。

**回环防护三层**（缺一即回环）：
1. `VolumeService.set()` **先更新本地值再调原生** ⇒ 自触发广播被去重
2. 监听回调**按值去重**
3. `AudioController.syncFromSystem` **故意不调 `_emit()`** ⇒ 不回写系统

**真机验证 8/8**：侧边键上 → 系统音量 `10→40`，
App 收到 **3 条同步日志** `13.33 → 20.0 → 26.67`（逐次跟随）。

### 2.6 其他修复（都是真机发现）

| 缺陷 | 根因 |
|---|---|
| 点退出箭头**卡死** | `PopScope(canPop:false)` + `maybePop()` **无限递归** |
| 三个按钮"点了没反应" | `PlayerPageCallbacks` **根本没有** `onPrevious/onNext` 字段 |
| 顶栏集数**重复显示** | `title` 和 `subtitle` 传了**同一个值** |
| 播放中**屏幕熄灭** | `WakelockService` 写好了但**零调用** |
| 亮度手势不生效 | 只改了 state，没人应用到窗口 |

---

## 第三部分 · 还能优化什么（按「收益 ÷ 代价」排序）

> ⚠️ 以下每条都**标注了验证方式**。
> 未实测的写"待验证"，不编造数字。

### 🟢 P0：`loadfile` 合并 open + seek（立即可做，低风险）

**现状**（实测代码）：
```kotlin
// PlayerChannel.kt:371
MPVLib.command(arrayOf("loadfile", url, "replace"))   // ① 打开
// 然后 Dart 侧再发一次 seek:
await k2.seek(_seekTarget);                            // ② 跳转
```

**问题**：续播时是**两次 Dart↔原生往返 + 两次 mpv 命令**。
而且**第二次 seek 发生在容器还没探测完的时候** ——
可能触发 mpv 内部的"seek 后再探测"。

**优化**：mpv 的 `loadfile` **支持 `start=` 选项**（已实测该字符串在本构建中）：
```kotlin
MPVLib.command(arrayOf("loadfile", url, "replace",
                       "start=${startSeconds}"))
```

**收益**：省一次往返 + 让 mpv **在加载时就带上起始位置**（内部路径更优）。
**风险**：低（mpv 官方支持的用法）。
**验证方式**：真机对比 `[Startup]` 埋点的 `open` + `seek` 两段耗时之和。

> ⚠️ 注意：`NativeKernel.open` **已有** `start` 参数分支
> （`if (start != null && start.inSeconds > 3) await seek(start)`），
> 但它走的是**两次调用**，不是 `loadfile` 的 `start=`。
> ⇒ 改动点是把它换成单次命令。

### 🟢 P0：`cache-pause-wait` 收紧（低风险）

**现状**：未设（默认 3 秒）。

**含义**：起播前**等待缓冲 3 秒**才开始播。对已快速就绪的源是纯等待。

**优化**：`cache-pause-wait=1`（或更小）。
**收益**：可能直接砍掉起播路径上的固定等待。
**风险**：低 —— 网络差时会更早开始"转圈等待"，但那是真实状态。
**验证方式**：对比 `[Startup] DEMUX_DONE → FIRST_FRAME` 段。

### 🟡 P1：`demuxer-readahead-secs` 加大（中收益，需权衡内存）

**现状**：未设（默认 1 秒左右）。

**含义**：mpv 预读多少内容。网络源抖动时，预读不足会导致反复 `cache-pause`。

**优化**：`demuxer-readahead-secs=3~5`。
**代价**：配合 `demuxer-max-bytes=128MiB`，内存占用上升。
**验证方式**：播放中制造网络抖动（`adb shell` 限速），统计 `cache-pause` 次数。

### 🟡 P1：`vd-lavc-dr`（直接渲染，省一次拷贝）

**现状**：未设。该选项在本构建中存在。

**含义**：解码后**直接渲染**，省一次内存拷贝。对 4K 高码率有意义。
**风险**：某些解码器组合下可能有问题 ⇒ **需要真机 A/B 验证**。
**验证方式**：对比 `dumpsys gfxinfo` 的 `p95`，以及观察是否有绿色/花屏。

### 🟡 P1：Media3 侧 `LoadControl` 调优

**现状**：未设 ⇒ 默认 `bufferForPlaybackMs = 2500`。

**优化**：
```kotlin
DefaultLoadControl.Builder()
  .setBufferDurationsMs(3000, 15000, 1000, 2000)
```
即**起播门槛从 2.5s 降到 1s**。
**⚠️ 不要**设 `setTargetBufferBytes`（会迫使高码率片源降低缓冲时长）。
**验证方式**：Media3 内核起播耗时对比。

### 🔵 P2：`deband`（画质，需做成开关）

**现状**：未设。

**含义**：去色带。**对 HDR→SDR 后的暗部色带**特别有效。
**代价**：GPU 开销 ⇒ 建议做成**用户开关，默认关**。
**验证方式**：HDR 片源暗场景截图对比（肉眼）。

### 🔵 P2：`vo=gpu-next`（需重建 libmpv，**见下**）

**现状**：**用不了**。已实测二进制：
```
-Dlibplacebo=disabled -Dvulkan=disabled
```
⇒ `gpu-next` 需要 libplacebo，本构建没有。

**影响**：HDR tone-mapping 走的是 `vo=gpu` 内置实现，**精度不如 gpu-next**。

**重建成本**（已调研）：
· 上游 `media-kit/libmpv-android-video-build`（MIT，GitHub Actions 构建）
· 改动：`mpv.sh` 两行 + **新增 `libplacebo.sh`**（上游没有这个脚本，是主要工作量）
· 该仓库**已有 `shaderc.sh`**（Vulkan shader 编译器）
· K40 支持 Vulkan 1.0 ⇒ 硬件可行
· **本机无 bash/meson/ninja ⇒ 必须走云 CI**

**风险**：中高 —— 换内核库要重验**所有播放路径**。

### 🔵 P2：内核预热（改善"切换"而非"首次起播"）

**现状**：切换内核 = dispose 旧的 → 建新的 → `ensureTexture` → 再 open。

**优化**：**提前建纹理**（`ensureTexture` 只是创建 Flutter Surface，
与 `mpv_initialize` 无关）⇒ 可提前。
**收益**：黑屏时长从几百 ms 降到一两百 ms。
**为什么不做双内核预创建**：两个内核同时活着 = **两份解码器+缓冲**
（K40 上有内存风险）；而且对**首次起播**没帮助。

### ⚪ P3：待验证项（我没实测，不敢下结论）

| 项 | 为什么不敢下结论 |
|---|---|
| `video-output-levels` | 只在 SDR 有限范围片源上有意义，手上没有此类样本 |
| `temporal-dither` | 与 `deband` 叠加效果未知，需 A/B |
| Media3 `TrackSelector` 是否悄悄选低质量轨 | 需要打印实际选中轨的分辨率才能判断 |
| 弹幕层与视频层的合成开销 | 需要 `--profile` 或 FrameTimeline 细分数据 |

---

## 第四部分 · 我做过的**明确拒绝**（连同理由）

> 记录这些**比记录采纳了什么更有价值** —— 避免后人重复评估。

| 方案 | 拒绝理由 |
|---|---|
| `vo=mediacodec_embed` | 会绕开 GPU 管线 ⇒ 画面调节（滤镜）、字幕 OSD、`video-sync` **全部失效** |
| 双内核**预创建** + Surface 共享 | ① 对首次起播**无帮助** ② 两份解码器/缓冲，K4 有内存风险 |
| Anime4K 等 shader 放大 | 不是当前瓶颈（瓶颈是起播与整页重建，已解决） |
| 引入 `volume_controller` / `screen_brightness` 插件 | 我们**已自研**同等能力；引插件 = 多一棵依赖树（`media_kit` 的教训，ADR 0009）|
| `WRITE_SETTINGS` 全局亮度 | 反方向 —— 我们是播放器，改全局亮度会**影响用户退出后的手机设置** |
| HLS 走 mpv 的 `demuxer-lavf` | Media3 的 HLS 实现更成熟（这也是引入 Media3 的**主要理由**）|
| "统一音量走系统通道"（含 duck） | duck 改系统音量会**改坏用户手机音量且不恢复** —— 必须走内核 |

---

## 第五部分 · 关键数据一览（可溯源）

| 指标 | 数值 | 出处 |
|---|---|---|
| 起播（优化前）| 9087 ms | 第 34 轮，真机 3 次采样中位 |
| 起播（优化后）| 7584 ms | 第 35 轮（**含探针修正贡献**）|
| Dart 命令链占比 | 314 ms / 9087 ms ≈ **3%** | 第 34 轮 |
| Janky（优化前）| 33.33% | 第 32 轮 `dumpsys gfxinfo` |
| 帧耗时（优化后）| p50 6ms / p90 12ms / p95 12ms | 第 32 轮 |
| 音量同步 | `13.33 → 20 → 26.67` 逐次跟随 | 第 46 轮真机 |
| mpv 选项总数 | 31 项 | 本轮实测 |
| 自动规则数 | 6 条（0–5）| 代码实测 |
| 会话层真机验证 | 7/7 | 第 44 轮 |
| 音量架构真机验证 | 8/8 | 第 46 轮 |

---

## 第六部分 · 如果要动手，建议顺序

```
① loadfile 合并 open+seek          ← 收益明确、风险低、改动小
② cache-pause-wait 收紧            ← 同上
③ 真机 A/B 验证 ①② 的实际收益      ← 用 [Startup] 埋点，别凭感觉
④ Media3 LoadControl（只影响 Media3 路径）
⑤ vd-lavc-dr / demuxer-readahead-secs（需权衡内存）
⑥ deband（做成用户开关）
⑦ 重建 libmpv + libplacebo（大工程，独立评估）
```

**每一步都必须**：
· 用 `[Startup]` / `dumpsys gfxinfo` 埋点**量化**，不靠"感觉流畅了"
· 补守卫测试 + **反向注入**（`AGENTS.md` §8.4）
· 真机验证（CI 覆盖不到手势/硬解/布局）

---

## 相关文档

| 想知道 | 看 |
|---|---|
| 架构说明书（改代码前必读）| [`DUAL-KERNEL.md`](DUAL-KERNEL.md) |
| 播放内核的坑（逐条）| [`PLAYER-KERNEL.md`](PLAYER-KERNEL.md) + `AGENTS.md` §6.2 |
| 内核迁移决策背景 | [`decisions/0009-native-mpv-kernel.md`](decisions/0009-native-mpv-kernel.md) |
| 某轮具体怎么修的 | [`AI-MEMORY.md`](AI-MEMORY.md) |
| 验证纪律（避免"假绿"）| [`VERIFICATION-DISCIPLINE.md`](VERIFICATION-DISCIPLINE.md) |
