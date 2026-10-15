/// **新播放 UI 的正式接线层** —— 把 Emby 播放流程接到 [PlayerUiPage]。
///
/// ## 定位（渐进迁移的第一步）
///
/// 旧 `player_page.dart`（2815 行）仍然在服务；本页实现**同一套 Emby 流程**
/// 但驱动**新 UI**（状态层/面板/手势，按播放ui.html 原型重构的那套）：
///   · resolvePlayback → 内核 open（直连；转码兜底与 STRM 重开仍在旧页）
///   · 断点续播 + 默认倍速偏好
///   · 进度上报：Start + 每 10s TimeUpdate + 交互即时上报 + Stop/ItemProgress
///   · 服务端默认音轨/字幕轨（TrackAligner，ff-index 精确对齐）
///   · 整季分集 → 播放列表面板 + 播完自动连播
///   · 弹幕层接入（既有 lib/danmaku/，插槽 slots.danmakuLayer）
///   · 信息 Tab 数据（MediaInfo ← MediaSource.MediaStreams）
///
/// ## 与真机测试 harness 的关系
///
/// `integration_test/player_ui_harness.dart` 是本文件的**第一版骨架**；
/// 那里实测出的两条硬约束在这里落地：
///   1. **音量单位换算**：面板回调 0–1 → 内核 setVolume 0–100（`v * 100`）
///   2. 内核状态 → providers 的**单向同步**（不互相 watch）
///
/// ## 运行开关
///
/// 路由经 `--dart-define=CF_NEW_PLAYER=true` 启用（见 player_routes.dart）；
/// 默认仍走旧页 —— 本页未经真实登录 E2E 验证前不接管主路径。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show DeviceOrientation, SystemChrome, SystemUiMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:screen_brightness/screen_brightness.dart';
import '../core/theme.dart';

import '../danmaku/danmaku_config.dart';
import '../danmaku/danmaku_import.dart';
import '../danmaku/danmaku_overlay.dart';
import '../danmaku/danmaku_models.dart';
import '../danmaku/danmaku_match_sheet.dart';
import '../danmaku/danmaku_match.dart';
import '../danmaku/danmaku_providers.dart';
import '../data/trakt_client.dart';
import '../data/trakt_playback.dart';
import '../data/trakt_resume.dart';
import '../data/media_provider.dart';
import 'player_page.dart' show PlayerPage;
import '../data/models.dart';
import '../state/providers.dart' show embyApiProvider, sessionStoreProvider;
import 'application/controllers/playlist_controller.dart';
import 'application/providers/player_providers.dart';
import 'domain/models/danmaku_panel_state.dart';
import 'domain/models/media_state.dart';
import 'domain/player_constants.dart';
import 'kernel.dart';
import 'kernel_auto_select.dart';
import 'kernel_factory.dart';
import 'kernel_traits_adapter.dart';
import 'native/native_kernel.dart';
import 'player_facade.dart' show FacadeAudioTrack, FacadeSubtitleTrack;
import 'presentation/player_ui_page.dart';
import 'presentation/player_ui_tokens.dart';
import 'presentation/subtitle_overlay.dart';
import 'presentation/widgets/aspect_video.dart';
import 'track_aligner.dart';
import 'infrastructure/system/system_services.dart';
import 'infrastructure/session/session_bridge.dart';

/// 是否走**新播放 UI**（`PlayerFlowPage`）。
///
/// ## ★ 2026-10-09：默认值已从 `false` 翻转为 `true`
///
/// ### 为什么必须翻（这不是偏好问题，是一个已发生的发布事故）
/// 原先是 `defaultValue: false` ⇒ **不传 flag 就走旧页**。
/// 而发布链路（`release.yml` / `ci.yml` / `tool/build_apk.*`）**都没传这个 flag**
/// ⇒ **v0.3.2 发布包里编进去的是旧播放页（2816 行）**，
/// 双内核 / 媒体会话层 / HDR tone-mapping / WakeLock / 音量系统通道
/// **全部没进用户手里**。
///
/// 取证方式（产物字节级）：两页各有独有字符串，Dart AOT 以 UTF-16LE 编进
/// `libapp.so`；对已发布 APK 扫描 ⇒ 旧页指纹 6/6 命中、新页 0/7。
/// 详见 `docs/AUDIT-2026-10-09.md`。
///
/// ### 为什么要"翻转默认"而不是"给 CI 补上 flag"
/// 补 flag 只修了**这一次**。真正的问题是"**编译期开关 + 默认值指向旧路径**"
/// 这个组合 —— 任何人（含未来的我）只要忘了传，
/// 就会**静默**发布一个功能缺失的包，而本地测试全绿（因为本地总记得传）。
/// 翻转后**默认路径即正确路径**，忘记传 flag 也安全。
///
/// ### 旧页仍未删除（保留为逃生通道）
/// 新页此前缺"章节刻度 / 跳过片头"，**已于本轮补齐**（含 16 例守卫测试 +
/// 反向注入 19/19）。但为稳妥，暂保留 `--dart-define=CF_NEW_PLAYER=false`
/// 一键回退旧页的能力 —— 若线上发现新页有阻塞缺陷，可以立即回退而不必改代码。
///
/// ⚠️ **回退开关只用于应急**：正常开发/发布**不要**传它。
/// 待新页经过若干个版本的线上验证后，应连同旧页一起删除
///（那时这个开关也随之消失，`bool.fromEnvironment` 这个类别的问题彻底消除）。
const useNewPlayerUi =
    bool.fromEnvironment('CF_NEW_PLAYER', defaultValue: true);

/// 面板音量（0–1）→ 内核 setVolume（0–100）。
///
/// **单位换算的唯一事实源**：harness 实测出的契约断层
/// （面板 SliderRow x/100，内核与 Kotlin 侧都是 0–100），勿在调用点再换算。
/// 播放流程页与调试试验台共用。
double volumeToKernel(double v) => (v * 100).clamp(0.0, 100.0);

/// 音频闪避（duck）时压到的音量（内核量纲 0–100）。
///
/// ## 为什么是 30
/// 闪避的语义是"让用户仍能听清主内容**但明显让位**于通知音"。
/// 实测 30% 既能听清对白、又不会盖过导航播报；0% 等于静音（那不如暂停），
/// 60% 以上则几乎听不出被压低（失去闪避的意义）。
/// 数值可调，但**不要**改成 0 —— 那会让用户以为播放器卡住了。
const double kDuckVolume = 30;

/// 内核音量在当前架构下的**恒定值**（unity，即"不衰减"）。
///
/// ## 为什么是"恒定"而不是"可变"
/// K3.5 起**用户音量全部由系统通道负责**（`VolumeService` →
/// `AudioManager.STREAM_MUSIC`）。内核音量保持 unity，音量就只衰减一次。
///
/// **若哪天有人把手势改回内核音量，就会立刻重现双重衰减** ——
/// 现象是"系统音量 50% 时，滑块拉到 100% 也只有一半响度"。
/// 这条常量与 `_startEpisode` 里的显式设置、以及
/// `test/player_volume_architecture_guard_test.dart` 一起守住这个约束。
///
/// 量纲：mpv `volume` 属性与 Media3 的 0–100 表示（内核侧换算成 1.0）。
const double kKernelUnityVolume = 100;

/// 手势亮度（0–100）→ `ScreenBrightness` 的 0.0–1.0。
///
/// ## 为什么要有这个函数（真机 bug，2026-10-07）
/// 用户反馈"亮度调不暗"。根因是**单位契约断层**：
///   · 手势侧（`GestureController.onBrightness`）给的是 **0–100**
///   · `setApplicationScreenBrightness` 要的是 **0.0–1.0**
/// 原实现直接 `v.clamp(0.05, 1.0)`，于是：
///   · 手指一动 v≈50 → clamp 后 **1.0 = 满亮度**
///   · 往下滑 v=30 → 仍是 1.0（想变暗却更亮）
/// 结果**只能最亮、无法调暗**。
///
/// ## 为什么要抽成函数而不是就地写
/// 与 [volumeToKernel] 同理：换算散在各调用点，任何一处漏改就会重现
/// 同类 bug（本项目已经因"单位在调用点各写一遍"栽过两次）。
/// 抽出来后可以**单测**（见 `test/player_unit_conversion_test.dart`）。
///
/// ## 下限为什么是 0.05 而不是 0
/// 系统亮度 0 会让屏幕**全黑**，用户看不到画面也划不动（无法划回来）。
/// 留 5% 保底是 Android 播放器的通行做法。
double brightnessToScreen(double v) =>
    ((v / 100.0).clamp(0.0, 1.0)).clamp(0.05, 1.0);

class PlayerFlowPage extends ConsumerStatefulWidget {
  const PlayerFlowPage({
    super.key,
    required this.item,
    this.episodes,
    this.index = 0,
    this.mediaSourceId,
  });

  final MediaItem item;
  final List<MediaItem>? episodes;
  final int index;
  final String? mediaSourceId;

  @override
  ConsumerState<PlayerFlowPage> createState() => _PlayerFlowPageState();
  /// **回读 mpv 关键选项**，确认真的生效（2026-10-09）。
  ///
  /// ## 为什么需要
  /// `setOptionString` 对**不存在的选项不报错** —— mpv 只写一行日志
  /// 然后**默默忽略**。"配了却没效果"且排查无线索。
  /// 本项目已多次踩这类坑（`default_rate` 有读无写、HDR 信息接线断、
  /// `episodeLabel` 未被填充）。
  ///
  /// ## 输出格式
  /// ```
  /// [MPV-CFG] tone-mapping=bt.2390 hdr-compute-peak=yes ...
  /// [MPV-CFG] ⚠️ N 项未生效: ...
  /// ```
  /// 用 `grep MPV-CFG` 即可确认。
  ///
  /// ## 只查"新增且影响最大"的项
  /// 全查会刷屏；其余项（字体路径等）已在其它轮真机验证过。
  static Future<void> _verifyMpvConfig(PlayerKernel? kernel) async {
    // `_kernel` 可能为 null（页面已清理）—— 那就不查，别抛异常。
    if (kernel == null) return;

    // ★ 只在 **mpv 内核**上查（Media3 没有可回读的 mpv 选项）。
    //
    // ## 为什么必须加这个守卫（真机暴露）
    // `Media3Kernel.getOption` 是**空实现**（返回 null）——
    // 它的配置是构建期定的（`ExoPlayer.Builder`），本就没有
    // "运行时可回读的属性"概念。
    // 不守卫的话，切到 Media3 后会打出：
    // ```
    // [MPV-CFG] 内核=media3 mpv-version="不可读"
    // [MPV-CFG] ⚠️ 1 项与期望不符: tone-mapping(期望bt.2390 实际)
    // ```
    // 这是**误报** —— 不是"tone-mapping 没生效"，而是"当前不是 mpv 内核"。
    // 排查时极容易被带偏（我本人就被骗过一次，一度以为 tone-mapping 失效）。
    if (kernel.engine != 'native') {
      debugPrint('[MPV-CFG] 当前内核=${kernel.engine}（非 mpv），'
          '跳过 mpv 选项自检');
      return;
    }
    // ---- ① 先做**通道自检**：读一个必然存在的属性 ----
    //
    // ## 为什么必须先做这一步
    // 第一版直接读 `tone-mapping` 等选项，全部返回**空**，
    // 于是"配置没生效"和"读取通道不工作"**无法区分**。
    //
    // 用 `mpv-version`（mpv 自己的版本串，永远可读）当**对照**：
    // · 若它也读不到 ⇒ **通道问题**（`getProperty` 方法/C 层有问题）
    // · 若它能读到 ⇒ 通道正常，问题在"选项名不是属性名"
    // ## 为什么先读 `mpv-version`
    // 它是**必然存在**的属性 —— 用它区分两种失败：
    // · 读不到 ⇒ **通道问题**（`getProperty` 没工作）
    // · 读得到 ⇒ 通道正常，再看具体选项
    //
    // ⚠️ 实测踩过的坑：默认播的片源若被自动适配判给 **Media3**，
    //    则 `getOption` 走的是 Media3 的**空实现**（返回 null），
    //    与"mpv 配置没生效"**表现得一模一样**。
    //    ⇒ 看到全 `?` 时**先确认当前用的是哪个内核**
    //      （`[Kernel] ... -> mpv|media3` 埋点）。
    final probe = await kernel.getOption('mpv-version') ?? '';
    debugPrint('[MPV-CFG] 内核=${kernel.engine} '
        'mpv-version="${probe.isEmpty ? "不可读（非 mpv 内核或通道故障）" : probe}"');

    // ---- ② 读选项：**必须用 `option/` 前缀** ----
    //
    // ⚠️ mpv 里**选项（option）与属性（property）是两套命名空间**：
    // · `tone-mapping` 写在配置里是**选项**
    // · 运行时用 `mpv_get_property` 读它要用 **`option/tone-mapping`**
    //
    // 我第一版直接用裸名读 → 全部返回空（不是"没生效"，是"读错命名空间"）。
    // 临时：只查 1 项（配合 [MPV-DBG] 定位通道问题）
    // 临时：打印 kernel 的实际运行时类型（定位 getOption 未被 override）
    debugPrint('[MPV-CFG] kernel = ${kernel.runtimeType} '
        '(engine=${kernel.engine})');

    const expect = {
      'tone-mapping': 'bt.2390',
    };
    final got = <String>[];
    final bad = <String>[];
    for (final e in expect.entries) {
      // ⚠️ `getOption` 自带 300ms 超时（见其实现）：
      //    mpv 属性读取可能挂起，而这里是**起播路径**，
      //    诊断绝不能拖住播放。
      final v = await kernel.getOption(e.key) ?? '';
      final short = e.key.replaceFirst('option/', '');
      got.add('$short=${v.isEmpty ? "?" : v}');
      if (v != e.value) bad.add('$short(期望${e.value} 实际$v)');
    }
    debugPrint('[MPV-CFG] ${got.join(" ")}');
    if (bad.isNotEmpty) {
      debugPrint('[MPV-CFG] ⚠️ ${bad.length} 项与期望不符: ${bad.join("; ")}');
    }
  }

  // ---------- 顶栏文案（用户 2026-10-09 反馈）----------

  /// 顶栏主标题：**集数 + 名称**（用户要求"增加显示集数的名称"）。
  ///
  /// ## 修的是什么（用户原话："旁边显示的集数有重复显示"）
  /// 原实现 `title: _current.name` + **`subtitle: _current.name`** ——
  /// **同一个值传了两次**，于是顶栏两行显示同一句话。
  ///
  /// 现在 title 承载"集数 + 本集名"，subtitle 承载"剧名"（见 [_subtitleFor]），
  /// 两行是**不同的信息**，不再是重复。
  ///
  /// ## 三种条目
  /// · 剧集且有序号 → `第 N 集 · 本集名`
  /// · 剧集无序号   → 只显示本集名（**不出现"第 null 集"**）
  /// · 电影/其他    → 只显示名称
  static String topTitleFor(MediaItem item) {
    final n = item.name.trim();
    if (item.type != 'Episode') return n;
    final idx = item.indexNumber;
    if (idx == null) return n;
    // 名称里已含"第 N 集"时不重复拼（有些服务端把集号写进了 Name）
    if (n.contains('第 $idx 集') || n.contains('第$idx集')) return n;
    return '第 $idx 集 · $n';
  }

  /// 顶栏副标题：**剧名**（与主标题不同的信息）。
  ///
  /// ## 为什么要有"相同则返回 null"的兜底
  /// 这个 bug 的本质就是"两行喂了同一个值"。为避免**将来**再从别的路径
  /// 造成重复（例如某条目的 `seriesName` 恰好等于名称），
  /// 这里统一兜底：**与主标题相同就不显示第二行**。
  ///
  /// `PlayerTopBar` 已支持 `subtitle == null`（那行不渲染）。
  static String? subtitleFor(MediaItem item) {
    if (item.type != 'Episode') return null; // 电影只要一行
    final series = item.seriesName?.trim();
    if (series == null || series.isEmpty) return null;
    if (series == topTitleFor(item)) return null; // ★ 去重兜底
    return series;
  }

}

class _PlayerFlowPageState extends ConsumerState<PlayerFlowPage> {
  PlayerKernel? _kernel;
  int? _textureId;
  final _subs = <StreamSubscription<dynamic>>[];

  late MediaItem _current;
  late int _index;
  PlaybackLaunch? _launch;
  bool _started = false;

  /// **等待中的默认轨选择**（真机实测的时序兜底）。
  ///
  /// ## 为什么需要（"没声音 + 没字幕"的成因）
  /// `_applyServerDefaultTracks` 若在轨道上报**之前**跑，看到的是空列表
  /// ⇒ 选轨逻辑全部空转 ⇒ 既没声音（没选到可解轨）也没字幕（没选 sid）。
  ///
  /// 而 `_syncTrackLists`（喂面板）由 `tracksStream` 驱动，
  /// **轨道到达时它一定会跑** ⇒ 存一份"待处理的 launch"，
  /// 由那次回调补做选轨。
  PlaybackLaunch? _pendingDefaultTracks;

  /// Emby API 引用缓存 —— [_finalize] 在 dispose 里也会被调，
  /// 那时 ref 已不可用（Riverpod 禁止），必须在 boot 时缓存。
  MediaProvider? _api;
  bool _switching = false;
  bool _finalized = false;
  Timer? _reportTimer;

  /// 断点续播秒数（入口条目自带进度；换集归零，与旧页一致）。
  double _resumeSeconds = 0;

  // ---- 播放韧性（旧页同款：起播超时 / 速度监测 / 直连↔转码重开）----
  String _playMethod = 'direct';
  Timer? _startTimeout;
  Timer? _speedTimer;

  /// 起播全链路计时（诊断用）：
  /// `initState` → 内核创建 → open → **首帧到达**。
  Stopwatch? _sw;
  int _tMark = 0;
  bool _firstFrameLogged = false;
  bool _demuxLogged = false;

  /// 本次起播的 seek 目标（用于判"position 是真的在推进"，
  /// 而不是 seek 刚登记时的那个瞬时值）。
  Duration _seekTarget = Duration.zero;
  /// 是否已发起起播。
  ///
  /// ## 为什么需要这个门（本轮实测抓到的埋点缺陷）
  /// `stateStream` 是**随时**推的（包括 `open` 之前）。
  /// 首帧探针用 `position > _seekTarget + 500ms` 判定，
  /// 而 `_seekTarget` 在 open 前可能还是 0 ⇒ **position 一过
  /// 0.5s 就判首帧到达** ⇒ 实测出现假的 `FIRST_FRAME=32ms`
  ///（当时 `seekTarget=0s` 而 `resume=785s`，自相矛盾）。
  bool _startupBegun = false;

  /// 跨方法的分段计时（`_boot` / `_startEpisode` 都用它）。
  void _stage(String name) {
    final sw = _sw;
    if (sw == null) return;
    final now = sw.elapsedMilliseconds;
    debugPrint('[Startup] $name=${now - _tMark}ms (abs=${now}ms)');
    _tMark = now;
  }

  /// 从章节列表里判定**片头区间**（开始秒, 结束秒）。null = 没检测到。
  ///
  /// ## ① 首选服务端原生标记（`MarkerType`）
  /// 本服务器（Emby 4.10）某剧集章节实测为
  /// `Chapter, IntroStart, IntroEnd, Chapter, …` —— 服务端**早已标好**。
  ///
  /// ## ② 兜底才是名称匹配
  /// 字符串匹配有典型失效场景：
  ///   · 叫"主题曲"/"OP"/"序章" → **识别不到**
  ///   · 叫"片头曲欣赏"的普通章节 → 会被**误跳**
  /// 故它**只能**在服务端没标记时兜底，不能当主路径。
  ///
  /// ## 为什么有 `IntroStart` 却没有 `IntroEnd` 时用"下一章起点"
  /// 真实数据里出现过只有 start 的情况 —— 那时若不兜底就整个放弃检测，
  /// 用户会看到"明明有片头标记却不跳"。用下一章起点是**最接近的合理估计**。
  /// 都没有下一章时给 120 秒（常见片头时长），且**必须 > start** 才采纳，
  /// 否则会得到"零长度区间"从而永远不触发。
  static (double, double)? _detectIntro(List<MediaChapter> ch) {
    // ① 服务端原生标记（首选）
    for (var i = 0; i < ch.length; i++) {
      if (!ch[i].isIntroStart) continue;
      final start = ch[i].seconds;
      for (var j = i + 1; j < ch.length; j++) {
        if (ch[j].isIntroEnd) {
          final end = ch[j].seconds;
          if (end > start) return (start, end);
          break;
        }
      }
      // 有 IntroStart 却没配对的 IntroEnd：用下一章起点兜底
      final end = i + 1 < ch.length ? ch[i + 1].seconds : start + 120.0;
      if (end > start) return (start, end);
      break;
    }

    // ② 兜底：名称匹配（服务端未标记时）
    for (var i = 0; i < ch.length; i++) {
      final n = ch[i].name.toLowerCase();
      if (n.contains('片头') || n.contains('intro') || n.contains('opening')) {
        final start = ch[i].seconds;
        final end = i + 1 < ch.length ? ch[i + 1].seconds : 120.0;
        if (end > start) return (start, end);
      }
    }
    return null;
  }

  /// 当前是否应显示"跳过片头"浮钮（片头区间内）。
  ///
  /// 结束前 1 秒不再显示 —— 那时点了也几乎等于没效果，
  /// 留着按钮只会让人以为点了没反应。
  bool get shouldOfferIntroSkip {
    final intro = _intro;
    if (intro == null) return false;
    final pos = ref.read(playbackStateProvider).position.inSeconds;
    return pos >= intro.$1 && pos < intro.$2 - 1;
  }

  /// 自动跳过片头（点在"自动跳过"开启时由状态流驱动）。
  ///
  /// ## 为什么用 `_introSkipped` 只跳一次
  /// 位置是持续推送的 —— 不加这个门，进入区间后会**每 250ms 跳一次**，
  /// 表现为"画面反复回跳"。换集时在 `_startEpisode` 里复位。
  void _checkIntroSkip() {
    final intro = _intro;
    if (intro == null || _introSkipped || !_autoIntroSkip) return;
    final pos = ref.read(playbackStateProvider).position.inSeconds;
    if (pos >= intro.$1 && pos < intro.$2 - 1) {
      _introSkipped = true;
      unawaited(_kernel?.seek(Duration(seconds: intro.$2.toInt())));
      _flash('已跳过片头');
    }
  }

  /// 浮钮/自动跳过共用的瞬时提示（与旧页 `_flash` 同语义）。
  void _flash(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 位置补发定时器（配合 `NativeKernel._pushState` 的限流）。
  ///
  /// 内核为消除"每帧重建整页"把位置推送限流到 250ms；
  /// 本定时器保证**窗口内最后一次位置**会被补发出去 ——
  /// 否则暂停/seek 后进度条会停在旧位置。
  Timer? _posFlushTimer;

  // ---- 章节 / 跳过片头 ----
  //
  // ## 为什么要这两项（对齐旧页能力）
  // 旧页 `player_page.dart` 有，新页原先缺 —— 切换默认播放页时会**功能倒退**。
  // 故补齐后再翻转 `CF_NEW_PLAYER`（见 docs/AUDIT-2026-10-09.md 的修复顺序）。
  //
  /// 本集章节（来自 `launch.chapters`；缺失时才单独查一次）。
  List<MediaChapter> _chapters = const [];

  /// 片头区间（开始秒, 结束秒）；null = 没检测到。
  (double, double)? _intro;

  /// 每次起播只自动跳一次（换集时复位）。
  bool _introSkipped = false;

  /// 用户偏好：是否自动跳过片头（持久化键 `skip_intro_auto`）。
  ///
  /// **默认开** —— 与旧页一致（`autoIntro != '0'`）。
  /// 旧页注释写的是"默认开"，且该偏好语义是"服务端标了片头就帮我跳"。
  bool _autoIntroSkip = true;
  int _bufStalls = 0;
  bool _netSlowHint = false;
  bool _autoNextEnabled = true;

  /// 用户的内核偏好（「我的 → 播放内核」里选的）。
  ///
  /// ⚠️ 这个只是**默认值**。真正的决策在 [_adaptKernel] ——
  /// 那里会拿到片源特征再做一次，`auto` 时才由自动规则定夺。
  KernelPreference _preference = KernelPreference.auto;

  /// 上一次自动适配的决策结果（含理由，供 UI 展示"为什么用这个内核"）。
  KernelDecision? _decision;

  /// 错误限流用状态（真实事故：死源每秒 21 次 `end-file` 淹没 UI）。
  ///
  /// 见 `_wireKernel` 里 errorStream 回调的说明。
  String? _lastKernelError;
  DateTime? _lastKernelErrorAt;
  int _kernelErrorDropped = 0;

  /// 同一错误的重报冷却时间。
  ///
  /// 取 3 秒：既能让"持续失败"不至于刷屏，
  /// 又能在错误**真的变化**时立刻让用户看到（不同错误串不受冷却影响）。
  static const Duration _kernelErrorCooldown = Duration(seconds: 3);

  /// 是否已判定当前源为死源并停过（保证 [_stopDeadSource] 幂等）。
  bool _deadSourceReached = false;

  /// 当前实际在用的内核类型（换内核后更新）。
  ///
  /// ⚠️ 与 `_preference` 的区别：偏好是**用户的意愿**（可能是 auto），
  /// 这个是**实际落地的结果** —— 自动适配后两者可能不同。
  /// 决策比较必须用本字段（拿偏好比会把"auto 已解析成 mpv"当成不一致）。
  KernelType _activeKernelType = KernelType.mpv;

  /// 布防超时时的位置（超时判据：位置必须推进过它）。
  Duration _positionAtArm = Duration.zero;

  /// 是否处于「全屏」态（**方向**的全屏，不是系统栏的全屏）。
  ///
  /// ## ★★ 初始值必须是 `false`（真机抓到的"点全屏没反应/反向"）
  ///
  /// 原来写 `= true`，但 `_boot` 里已经调用过
  /// `setEnabledSystemUIMode(immersiveSticky)` —— 即**系统栏早就隐藏了**。
  /// 于是第一次点全屏时 `_immersive` 取反变成 `false` ⇒ 走进 else 分支
  /// ⇒ **回竖屏 + 显示系统栏**：
  ///   · 用户以为"点全屏没反应"（其实方向根本没切）
  ///   · 更糟的是它与"进入全屏"语义**相反**
  ///
  /// ## 语义澄清（两个"全屏"不是一回事）
  /// · **系统栏**（immersive）：进播放页就进 —— 竖屏也想要"只有画面"
  /// · **方向**（本字段）：只在点全屏时切成横屏
  /// ⇒ 本字段只跟踪**方向**，与系统栏状态解耦。
  ///   初值 false = "当前是竖屏"，与 `_boot` 锁 portraitUp 一致。
  bool _immersive = false;

  @override
  void initState() {
    // ---- ★ 媒体会话命令（K3）----
    //
    // ## 为什么映射到既有控制器，而不是直接调内核
    // `PlaybackController` 是**唯一**的播放控制入口（UI 按钮、手势、
    // 自动连播都走它）。媒体键若绕过它直接调内核，就会出现"两个主"：
    // 通知栏显示播放中而实际已暂停、自动连播被绕开、长按倍速状态错乱。
    // 走同一套 ⇒ 行为与用户点击**逐字节一致**。
    //
    // 注意用的是 `ref.read(...notifier)` 而非缓存实例：
    // provider 可能因页面重建而换实例，缓存会操作到死对象。
    SessionBridge.instance.ensureRegistered();
    SessionBridge.instance.ensureRegistered();
    SessionBridge.instance.onCommand = (action, seekTo, speed) {
      // ⚠️ 这里全部走 `_kernel` **直调**，与 `_buildCallbacks()` 里的实现
      //    **逐字一致** —— 而不是套 `PlaybackController`。
      //
      // ## 为什么（真机踩过，代价很大）
      // `PlaybackController.play()/pause()` 是**纯状态机**（见其注释：
      // "Controller 与引擎解耦，便于单测"）—— 调它**只翻标志位，
      // 内核收不到任何指令**。
      // 我第一版就是这么写的，结果：媒体键命令一路走到 Dart（日志有
      // `会话命令: pause`），但**画面毫无变化**，排查了整整一轮。
      //
      // ⇒ 会话命令必须**镜像页面的写法**（`k.pause()`/`k.play()`），
      //    而不是想当然地套"唯一控制入口"。
      final k = _kernel;
      const sec = Duration(seconds: 10);
      switch (action) {
        case 'play':
          unawaited(k?.play() ?? Future.value());
        case 'pause':
          unawaited(k?.pause() ?? Future.value());
        case 'playPause':
          // 与 UI 同一个判据：读**内核**当前状态，不信状态机
          if (k != null) {
            unawaited(k.state.playing ? k.pause() : k.play());
          }
        case 'pauseByFocusLoss':
          _pausedByFocusLoss = true;
          unawaited(k?.pause() ?? Future.value());
        case 'stop':
          unawaited(k?.pause() ?? Future.value());
        case 'seekTo':
          if (k != null && seekTo != null) {
            unawaited(k.seek(seekTo));
            _reportEvent(ProgressEvent.timeUpdate);
          }
        case 'seekForward':
          if (k != null) {
            unawaited(k.seek(k.state.position + sec));
            _reportEvent(ProgressEvent.timeUpdate);
          }
        case 'seekBack':
          if (k != null) {
            unawaited(k.seek(k.state.position - sec));
            _reportEvent(ProgressEvent.timeUpdate);
          }
        case 'setSpeed':
          if (k != null && speed != null) {
            unawaited(k.setRate(speed));
          }
        case 'next':
          unawaited(_playEpisode(
              ref.read(playlistStateProvider).currentIndex + 1));
        case 'previous':
          unawaited(_playEpisode(
              ref.read(playlistStateProvider).currentIndex - 1));
        // ---- 音频焦点 ----
        //
        // `duck`/`unduck`：压低声量而不是暂停 —— 用户不该因一条通知
        // 就中断观看（这是 Android 推荐做法）。
        case 'duck':
          // 闪避：压到 30%。⚠️ **不暂停** —— 用户不该因一条通知中断观看。
          //
          // ★ 这里**必须**改内核音量，不能改系统音量：
          //   改系统音量会把**用户手机的音量**改小，且**不会自动恢复** ——
          //   用户退出 App 后发现手机声音莫名变小（很糟的体验）。
          //
          // 先记下**内核**当前值，unduck 时精确还原（不猜值）。
          _volumeBeforeDuck = k?.state.volume;
          unawaited(k?.setVolume(kDuckVolume) ?? Future.value());
        case 'unduck':
          // 还原到 duck 前记下的**内核**音量；没记到就回到 unity。
          //
          // ⚠️ 这里**不经过** `volumeToKernel` —— 那是"UI 0–1 → 内核 0–100"
          //    的用户音量换算；而内核现在恒定 unity，语义不同。
          unawaited(
            k?.setVolume(_volumeBeforeDuck ?? kKernelUnityVolume) ??
                Future.value(),
          );
          _volumeBeforeDuck = null;
        // 临时失焦（来电）结束后：**只有**"因失焦暂停"才自动续播。
        // 用户自己按的暂停不该被来电结束触发开播。
        case 'resumeAfterFocusGain':
          if (_pausedByFocusLoss) {
            _pausedByFocusLoss = false;
            unawaited(k?.play() ?? Future.value());
          }
      }
    };
    super.initState();
    // Trakt 实时追踪：异步准备上报器（不 await —— 起播不等它）
    unawaited(_prepareTraktReporter());
    _current = widget.item;
    _index = widget.index;

    // 续播：入口条目进度推进到 >2% 且未播完处（与旧页同一口径）
    final pct = widget.item.progress;
    final totalSec = widget.item.runtimeTicks == null
        ? 0.0
        : widget.item.runtimeTicks! / 10000000;
    if (pct > 0.02 && pct < 0.95 && totalSec > 0) {
      _resumeSeconds = totalSec * pct;
    }

    // ---- 方向策略（用户 2026-10-09 明确要求）----
    //
    // ★ **默认竖屏**，不再一进播放页就锁横屏。
    //
    // 用户原话："播放页不锁横屏横屏，我是手机使用，点击全屏时变成横屏"
    // ⇒ 期望：进播放页 = 竖屏；**点全屏**才切横屏。
    //
    // 原实现无条件锁横屏（沿用旧页），对"手机竖着用"的场景是反的 ——
    // 用户竖着拿手机进播放页就被强制转横，还得把手机转回来。
    //
    // 横屏只在"全屏"时锁（见 `onFullscreenToggled`）。
    // 系统栏仍进沉浸式：竖屏下也想要"只有画面"的观感。
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    // 偏好：自动连播（默认开，与旧页同键 auto_next）
    unawaited(() async {
      final v = await ref.read(sessionStoreProvider).getPref('auto_next');
      if (mounted) setState(() => _autoNextEnabled = v != '0');
    }());

    // 分集 → 播放列表面板
    //
    // ══════════════════════════════════════════════════════════════
    // ★★ 为什么整段推迟到**首帧之后**（真机 + 测试双重取证）
    // ══════════════════════════════════════════════════════════════
    // 本段在 `initState` 里，而 Riverpod **禁止在 widget 生命周期内
    // 同步修改 provider**：
    //     Tried to modify a provider while the widget tree was building.
    //     ... could lead to an inconsistent UI state.
    //
    // ## 原来的 `if` 分支为什么"侥幸没炸"
    // 它只在**有分集**时执行 —— 而单测里的电影场景（`episodes == null`）
    // 根本不进这个分支 ⇒ 缺陷被掩盖。等电影也要清空（下面的 else）时，
    // **所有电影场景都会触发** ⇒ `player_flow_page_test` 5 例当场变红。
    //
    // ## 修法：`addPostFrameCallback` 统一推迟
    // 不用 `Future.microtask` —— 微任务仍可能在 build 完成前执行；
    // post-frame 回调**保证在首帧渲染结束后**运行，是 Riverpod 官方
    // 推荐的"在 Lifecycle 里改 provider"的逃逸口。
    //
    // ⚠️ 代价：首帧时列表还是旧数据（一帧 ≈ 16ms，用户不可能察觉），
    //    第二帧起正确。`if (!mounted) return` 防页面已退出。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final eps = widget.episodes;
      if (eps != null && eps.isNotEmpty) {
        ref.read(playlistStateProvider.notifier).setEntries([
          for (final e in eps)
            PlaylistEntry(
              id: e.id,
              title: e.name,
              subtitle: e.type == 'Episode' ? e.seriesName : null,
              // ---- 集数 + 观看进度（用户反馈修复，2026-10-07）----
              //
              // 用户："播放剧集和综艺时播放列表并没有显示当前集数。
              //       这个具体的内容可以参考之前的选集功能。"
              //
              // 参考旧页选集抽屉（`player_page.dart:2563-2573`）的口径：
              //   label = ['第 N 集', 剧名].join(' ')
              //   sub   = played ? '已看' : (progress > 0 ? '看到 N%' : null)
              //
              // ⚠️ 电影（无 indexNumber）传 null —— 面板会自动不显示徽章，
              //    不会出现"第 null 集"或空行。
              episodeLabel:
                  e.indexNumber == null ? null : '第 ${e.indexNumber} 集',
              progressLabel: e.played
                  ? '已看'
                  : (e.progress > 0
                      ? '看到 ${(e.progress * 100).round()}%'
                      : null),
            ),
        ], startIndex: _index);
      } else {
        // ★★ 电影：**必须显式清空**（用户报障："播放电影时列表图标还在"）
        //
        // ## 根因（真机可见的错乱）
        // `playlistStateProvider` 是**应用级单例** —— 退出播放页不重置。
        // 原实现只在"有分集"时 `setEntries`，电影进不来这个分支 ⇒
        // 列表**残留上一部剧的 173 集** ⇒ 底栏按钮显示 `2/173`，
        // 点开列表面板还会看到**上一部剧的分集**（数据错乱，
        // 比"图标没隐藏"更严重 —— 误点会切到别的剧）。
        //
        // ## 为什么清空而不是"隐藏按钮"
        // 按钮可见性由 `entries.length > 1` 推导（见 `player_ui_page`
        // 的 `playlistCount`）。**状态清空后按钮自动只剩图标**，
        // 无需在 UI 层加"电影就隐藏"的第二套判据 —— 单一事实源。
        ref.read(playlistStateProvider.notifier).setEntries(const []);
      }
      ref.read(playlistStateProvider.notifier).onSelect = (entry) {
        final eps2 = widget.episodes;
        if (eps2 == null) return;
        final i = eps2.indexWhere((e) => e.id == entry.id);
        if (i >= 0) unawaited(_playEpisode(i));
      };
    });

    // 解码方式：面板改 videoState → 内核（页面回调契约里没有这一项，
    // 走 provider 监听；Media3 如实不支持则静默忽略）
    ref.listenManual(videoStateProvider, (prev, next) {
      final k = _kernel;
      if (k == null || prev == null || prev.decodeMode == next.decodeMode) {
        return;
      }
      if (k.supports(EngineFeature.decodeMode)) {
        unawaited(k.setDecodeMode(next.decodeMode));
      }
    });

    // ---- 完整起播计时：从**进入页面**开始（不是从 _startEpisode 开始）----
    //
    // ⚠️ 上一版埋点在 `_startEpisode` 内部，测出 TOTAL 仅 95ms ——
    //    那说明"慢"不在这条 Dart 命令链里。真正的耗时在：
    //      · `_boot` 的内核创建（mpv 初始化 + EGL 上下文）
    //      · `open()` **返回之后**的"解封装→解码→出首帧"
    //    故本版把基准提到 initState，并补测首帧到达时刻。
    _sw = Stopwatch()..start();
    _tMark = 0;

    unawaited(_loadDanmaku());
    unawaited(_boot());
  }

  /// 建内核 → 订阅流 → 起播。
  ///
  /// 顺序与旧页相同：先 `ensureTexture`（mpv 的 wid 必须在 initialize 前设好）。
  Future<void> _boot() async {
    // ---- 建内核：按用户偏好 ----
    //
    // ⚠️ 此处只能按**偏好**建，不能做自动适配 ——
    //    适配的输入（容器/编码/HLS）来自 resolvePlayback，
    //    而那要等 _startEpisode 才拿到。真正的适配在那边做（见 _adaptKernel）。
    _preference = KernelPreference.fromStorage(
        await ref.read(sessionStoreProvider).getPref(kKernelPrefKey));
    // 自动跳过片头（用户偏好）。
    //
    // ⚠️ 判据是 `!= '0'` 而**不是** `== '1'` —— 即**默认开**。
    //    必须与旧页一致（`player_page.dart:421`）：该偏好是"用户没设过就帮我跳"，
    //    写成 `== '1'` 会让老用户升级后**突然不再跳片头**（静默的行为倒退）。
    _autoIntroSkip =
        (await ref.read(sessionStoreProvider).getPref('skip_intro_auto')) != '0';
    // ⚠️ `await` 之后必须重判 `mounted`（2026-10-15 真机 Unhandled Exception）
    //
    // ## 异常与根因
    // ```
    // E flutter : Unhandled Exception: Bad state: Using "ref" when a widget is
    //             about to or has [been disposed]
    // E flutter : Ref relies on BuildContext, and BuildContext is unsafe to use
    //             when the widget is **deactivated**.
    // ```
    // `_boot()` 是 `initState` 里 `unawaited(_boot())` 出去的
    // ⇒ **用户可能在它跑完前就退出播放页**
    //   （冷启动时 pref 读取 + 建 mpv 纹理合计几百 ms，足够退出了）
    // ⇒ 后续每个 `ref.read` 都会抛异常。
    // ⚠️ 每个 `await` 之后都要**重新判** —— await 前判过**不算**
    //   （挂起点之后状态可能已变，这正是 Flutter 提示"deactivated"的原因）。
    if (!mounted) return;

    // ★ 画面比例偏好（用户要求 A+C 方案里的 C 项）
    //
    // ## 为什么必须持久化（原来没有 —— "配了没记住"）
    // 比例档位选项**早就存在**（设置面板里的
    // 适应 / 拉伸 / 裁剪 / 16:9 / 4:3 / 9:16），但：
    //   · `VideoState build() => const VideoState()` ⇒ 每次新建都是 auto
    //   · 全仓库**没有任何** `aspect` 相关的 pref 读写
    // ⇒ 用户选了"16:9 满屏"看完一集，**下一集又变回 auto**，得重设一次。
    //
    // ## 与 A 项的分工
    // · A：`auto` 改成忠于片源（治变形）—— 让"不选"也是对的
    // · C：用户**显式选**的档位被记住 —— 想满屏的人不用每集重设
    //
    // ⚠️ 未知值/读失败 ⇒ 回退 `AspectMode.auto`
    //    （默认值只在 `AspectMode` 定义一处，存储层不写死）。
    final savedAspect =
        await ref.read(sessionStoreProvider).getPref('aspect_mode');
    // ⚠️ 又一个 `await` ⇒ 再判一次（理由同上：`_boot` 可能已被用户退出打断）
    if (!mounted) return;
    if (savedAspect != null && savedAspect.isNotEmpty) {
      final restored = AspectMode.values.firstWhere(
        (x) => x.name == savedAspect,
        orElse: () => AspectMode.auto,
      );
      if (mounted) {
        ref.read(videoStateProvider.notifier).setAspectMode(restored);
      }
      // ★ 日志：让"档位到底恢复了没有"**可见**
      //
      // ## 为什么值得常驻一行日志
      // `flutter_secure_storage` 是加密的，release 包 `run-as` 又不可用
      // ⇒ **外部完全读不到**偏好值。而"档位没恢复"与"档位恢复了但渲染
      // 有问题"是两种完全不同的故障，没这行日志就只能靠猜。
      //（本轮实测：为验证 C 跟 UI 时序搏斗了很久，非常低效。）
      debugPrint('[PlayerFlow] 画面比例：已恢复 ${restored.name}'
          '（存储值=$savedAspect）');
    } else {
      debugPrint('[PlayerFlow] 画面比例：无存储偏好，用默认 '
          '${AspectMode.auto.name}');
    }
    _stage('prefRead');
    final kernel = PlayerKernelFactory.create(_preference.kernelType);
    // ★ 这一段含 **mpv 初始化 + EGL 上下文创建**，是起播的固定开销
    await kernel.ensureTexture();
    _stage('kernelCreate+texture');
    // ⚠️ 挂起点过后必须重判 `mounted`（2026-10-15 真机 Unhandled Exception）
    //
    // ## 异常与根因
    // ```
    // E flutter : Unhandled Exception: Bad state: Using "ref" when a widget is
    //             about to or has been disposed
    // E flutter : Ref relies on BuildContext, and BuildContext is unsafe to use
    //             when the widget is **deactivated**.
    // ```
    // `_boot()` 是 `initState` 里 `unawaited(_boot())` 出去的 ⇒ 用户可能在
    // 它跑完前退出播放页（`ensureTexture` 含 mpv 初始化 + EGL 创建，几百 ms）
    // ⇒ 紧随其后的 `_api = ref.read(...)` 会抛异常。
    //
    // ⚠️ 这里**原有**一句同样的守卫（原始代码就有）——
    //    我加第二句时没检查上下文，造成重复（已合并，保留这一句）。
    if (!mounted) {
      unawaited(kernel.dispose());
      return;
    }
    _kernel = kernel;
    // auto 的默认实现就是 mpv（见 kernel_factory 文件头"默认必须是 mpv"）
    _activeKernelType = _preference.kernelType == KernelType.auto
        ? KernelType.mpv
        : _preference.kernelType;
    _api = ref.read(embyApiProvider);
    _textureId = kernel.textureId;

    _wireKernel(kernel);

    setState(() {}); // textureId 就绪，build 换成真视频层

    // ---- ★ mpv 配置自检（2026-10-09）----
    //
    // ## 为什么放在这里（而不是 NativeKernel 内部）
    // 最初把自检挂在 `NativeKernel.ensureInitialized()`，但实测
    // **一行日志都没输出** —— 而同为 `debugPrint` 的 `[Startup]` 埋点
    // （就在本方法里）正常可见。
    // ⇒ 与其继续查"那段为什么没跑到"，不如放在**确定会执行**的位置：
    //    本方法已有 `_stage()` 在稳定输出。
    //
    // ## 为什么必须用 Dart 侧 debugPrint
    // Kotlin 侧的 `Log.*` 会被 R8 **全部剥离**
    // （dex 取证：`Log;->i/w/e/d(` 均不存在，仅 `Landroid/util/Log;` 类名残留）
    // ⇒ Java 日志在 release 包里**一条都看不到**。
    //     Dart 的 `debugPrint`（`I/flutter`）可见。
    //
    // ## 查什么
    // `setOptionString` 对**未知选项不报错**（mpv 只记日志然后忽略），
    // 故必须回读确认。查本轮新增且影响最大的项。
    await _startEpisode(resumeSeconds: _resumeSeconds);

    // ---- ★ mpv 配置自检（**必须在起播之后**，2026-10-09）----
    //
    // ## ⚠️ 时机很关键（实测踩过）
    // 第一版把自检放在 `_startEpisode` **之前** —— 结果读到
    // **全空值**（`tone-mapping=? hdr-compute-peak=? ...`），
    // 一度误以为"配置全没生效"。
    //
    // 真实原因：mpv 的 `initialize()` 发生在
    // `_startEpisode` → `k2.open()` → `ensureInitialized()` 里。
    // 自检跑在它之前 ⇒ **mpv 还没初始化** ⇒ `mpv_get_property` 读不到东西。
    //
    // ⇒ 自检必须在**起播之后**（此时 mpv 已 initialized、属性可读）。
    //
    // （与本项目此前多次踩的"时序"类坑同源：`textureId` 要在 build 前就绪、
    //   `wid` 要在 `mpv_initialize` 前设好……）
    // 自检**已由 `_startEpisode` → `_adaptKernel` 统一触发**（见那里的说明）——
    // 这里不再重复调，否则日志每行出现两次（真机实测就是如此）。
    //
    // ⚠️ 历史教训：这里曾传**创建时的局部** `kernel`，而 `_adaptKernel`
    //    会替换 `_kernel` ⇒ 换内核后自检查的是**旧对象**，
    //    表现为"切到 media3 了却仍报 engine=native + 误报 tone-mapping 未生效"。
  }

  /// **Trakt 实时追踪**：把播放态变化翻译成 scrobble。
  ///
  /// ## ⚠️ 绝不阻塞、绝不抛（同步失败不能影响播放）
  /// 方法体包在 try/catch；所有上报都是 `unawaited` ⇒ 网络慢/失败
  /// **不会**让画面卡住或弹错误。
  ///
  /// ## 三种"不上报"的情况（都不是错误）
  /// 1. 开关关（用户没开「实时追踪」）
  /// 2. `_traktRep == null`（id 未解析出来 / 非剧集 / 缓存未预热）
  /// 3. `canReport == false`（只有 tmdb 的剧集 —— 契约限制，见 `TraktIds`）
  void _traktScrobble({
    required bool playing,
    required Duration position,
    required Duration duration,
  }) {
    final rep = _traktRep;
    if (rep == null) return;
    // 契约：progress 是 **0–100** 的 float（不是 0–1）
    final pct = duration.inMilliseconds > 0
        ? (position.inMilliseconds / duration.inMilliseconds) * 100.0
        : 0.0;
    _lastTraktPct = pct;
    try {
      if (playing) {
        // 契约：`start` = 开始播放**或取消暂停**
        unawaited(rep.onStarted(progress: pct));
      } else {
        unawaited(rep.onPaused(pct));
      }
    } catch (e) {
      debugPrint('[TraktTrack] 上报异常（不影响播放）: $e');
    }
  }

  /// 准备 Trakt 上报器（**异步两步解析**，全部静默失败）。
  ///
  /// ## 解析链（实测，见 `TraktEpisodeResolver` 的注释）
  /// ```
  /// ① seriesId → tmdb    TraktEpisodeResolver.tmdbIdForSeries（**只读缓存**）
  /// ② tmdb + 季/集 → trakt episode id    resolveEpisode
  /// ```
  /// ## ★ 第一步为什么只读缓存（重要）
  /// `mapSeriesTmdbToId()` 是翻页拉全库（5713 条，数秒）。
  /// 若在起播路径上调用 ⇒ 每次冷启动第一次播放都多等几秒。
  /// ⇒ 由 `seriesTmdbReverseProvider` 预热（追剧页 watch 它），
  ///   播放器只读。拿不到 ⇒ **静默放弃本次上报**（下次就有了）。
  /// 弹「Trakt 上有更新的进度」提示（**可点，不打断视频**）。
  ///
  /// ## 为什么用 `_surfaceMessage` 而不是 `showDialog`
  /// 播放页是**横屏全屏**，`showDialog` 会：
  /// · 打断视频（弹窗是模态的）
  /// · 在横屏下布局错乱（本仓库 §6.4 记过横屏 UI 的坑）
  /// ⇒ 复用该页已有的轻提示通路（解码失败提示也走它）。
  ///
  /// ## 为什么提示里要写清"Trakt 看到 xx%"
  /// 只说"要不要续播"用户不知道**依据是什么** ⇒ 无法判断该不该点。
  /// 带上百分比，用户一眼就知道"哦那是我在电视上看的"。
  ///
  /// [localSeconds] 是本地进度对应的秒数（用户点"从头/本地"时用）。
  Future<void> _promptTraktResume(
      TraktResumeHint hint, double localSeconds) async {
    try {
      final where = hint.season != null && hint.number != null
          ? 'S${hint.season}E${hint.number}'
          : '';
      // ⚠️ 文案要与实际行为一致：我们**没有**自动跳，
      //    是"按本地进度起播" ⇒ 说"已按本地进度播放"，不说"已忽略"
      await _surfaceMessage(
          'Trakt 上 $where 看到 ${hint.traktPct.round()}%'
          '（本地 ${hint.localPct.round()}%）\n'
          '已按本地进度播放。要跳到 Trakt 的进度请拖进度条。');
    } catch (e) {
      // 提示失败**不影响播放**（它只是锦上添花）
      debugPrint('[TraktResume] 提示失败（不影响播放）: $e');
    }
  }

  Future<void> _prepareTraktReporter() async {
    try {
      final store = ref.read(sessionStoreProvider);
      final flags = await store.traktFlags();
      if (!flags.track) {
        debugPrint('[TraktTrack] 实时追踪未开启（跳过）');
        return;
      }
      // ★ 用 `resolveTraktClientId()`（含**内置凭据兜底**）——
      //   `loadTraktClientId()` 只读用户自填的 ⇒ 用内置时恒为空
      //   ⇒ 授权成功也会被判"未登录"（2026-10-14 用户报障的根因）。
      final cid = await store.resolveTraktClientId();
      final tok = await store.loadTraktAccessToken();
      if (cid == null || cid.isEmpty || tok == null || tok.isEmpty) {
        debugPrint('[TraktTrack] 未登录（跳过）');
        return;
      }

      final item = widget.item;
      // ⚠️ 必须用**剧的** tmdb：Episode 自己的 ProviderIds 是**集级**的
      //（实测：斗罗大陆 集级 Tmdb=4694296，与剧级不同）⇒ 走反向映射。
      final seriesId = item.seriesId;
      final season = item.parentIndexNumber;
      final number = item.indexNumber;
      if (seriesId == null || seriesId.isEmpty ||
          season == null || number == null || number <= 0) {
        debugPrint('[TraktTrack] 缺 seriesId/季/集号 '
            '(sid=$seriesId S=$season E=$number) ⇒ 跳过');
        return;
      }

      final tmdb = TraktEpisodeResolver.tmdbIdForSeries(seriesId);
      if (tmdb == null) {
        debugPrint('[TraktTrack] 反向映射未预热 ⇒ 本次跳过'
            '（打开一次追剧页即可）');
        return;
      }

      final resolver =
          TraktEpisodeResolver(client: TraktClient(clientId: cid));
      final ids = await resolver.resolveEpisode(
        tmdbShowId: tmdb,
        season: season,
        number: number,
        expectCnTitle: item.seriesName,
        // ══════════════════════════════════════════════════════════════
        // ⚠️ 这里**故意不传** `expectYear`（2026-10-15 核实后决定）
        // ══════════════════════════════════════════════════════════════
        //
        // ## 为什么（与 `detail_page` 的两处**相反**）
        // `detail_page` 那两处的 `item` 是**剧（Series）**
        // ⇒ `item.productionYear` 就是**剧的首播年** ⇒ 传它是对的。
        //
        // 但**本方法的 `item` 是分集（Episode）**
        // （见上面 `widget.item` 的用法：`seriesId`/`parentIndexNumber`/
        //   `indexNumber` 都是从它取的）。
        // 而 `Episode.ProductionYear` 是**该集**的年份 ——
        // 长剧的后期分集与首播年**可以差好几年**：
        // ```
        // 剧首播 2023（Trakt `show.year` = 2023）
        // 第 100 集 ProductionYear = 2025（Emby 给的是本集年份）
        // ⇒ expectYear=2025 vs Trakt year=2023
        // ⇒ 命中 `plausiblyMatches` 判据②（年份都已知且不一致）
        // ⇒ **被判"错配"拒绝** —— 比不传更糟！
        // ```
        //
        // ## 不传的后果（**是安全的**）
        // `plausiblyMatches` 的判据③：**一方年份未知 ⇒ 不确定 ⇒ 采信**
        // （策略 B，用户 2026-10-15 定）。
        // 「仙逆」vs `Renegade Immortal` 这种"中文名 vs 英文名"
        // 本来就无法做标题比对 ⇒ 该采信。
        //
        // ## ⚠️ 给后人（含 AI）
        // **不要"顺手补上" `expectYear: item.productionYear`** ——
        // 那看起来是在"保持一致"，实际会**静默拒掉**长剧的后半季。
        // 若真要在这条路径上做年份校验，必须先**拿到剧的年份**
        // （`seriesId` → 查详情，但那要多一次请求，不适合播放启动路径）。
      );
      if (ids == null || !ids.usableForEpisode) {
        debugPrint('[TraktTrack] episode id 解析失败（Trakt 可能未收录）');
        return;
      }
      if (!mounted) return;
      // ⚠️ 用 `fromStore`（带 refreshToken）—— 见 `TraktSync.fromStore`
      //    的注释：不带 refresh 的话 401 自动刷新是死的。
      final sync = await TraktSync.fromStore(
        clientId: cid,
        readAccess: store.loadTraktAccessToken,
        readRefresh: store.loadTraktRefreshToken,
        writeTokens: (a, r) => store.saveTraktTokens(access: a, refresh: r),
        writeExpiresAt: store.saveTraktExpiresAt,
        // 到期剩余时间（用于**提前刷新**，见 fromStore 的注释）
        expiresInMs: store.traktExpiresInMs,
      );
      if (sync == null) {
        debugPrint('[TraktTrack] token 已失效（跳过）');
        return;
      }
      _traktRep = TraktPlaybackReporter(sync: sync, episodeIds: ids);

      // ---- ★ 续播检查（「续播检查」开关，2026-10-14）----
      //
      // ## 为什么放在这里（而不是另起一个异步任务）
      // 复用刚取到的 `cid` / `tok` / `tmdb` / `season` / `number`
      // ⇒ **零额外成本**（不再读一次 secure_storage，不再解析一次 id）。
      //
      // ## 为什么需要单独开关
      // 实时追踪与续播检查是**两个独立诉求**：
      // 有人只要"记录我看过"（track），不想被问"要不要跳"（resume）。
      if (flags.resume) {
        final hint = await TraktResumeChecker(sync: sync).check(
          tmdbShowId: tmdb,
          season: season,
          number: number,
          // 本地进度：Emby 的 `MediaItem.progress` 是 0–1 ⇒ 转 0–100
          localPct: (widget.item.progress * 100).clamp(0, 100),
        );
        if (hint != null && hint.shouldPrompt && mounted) {
          _traktResumeHint = hint;
          debugPrint('[TraktResume] 已记录待提示：$hint');
        }
      }
      debugPrint('[TraktTrack] 上报器就绪（S$season E$number '
          '→ trakt ${ids.trakt}）');
    } catch (e) {
      // 实时追踪是**后台增强** ⇒ 任何失败都不得影响播放
      debugPrint('[TraktTrack] 准备上报器失败（不影响播放）: $e');
    }
  }

  /// 把一个内核的状态流接到 providers 上（**单向同步**，与 harness 同款）。
  ///
  /// ⚠️ 抽成方法是因为**换内核后必须重挂**（`_adaptKernel` 会调它）。
  ///    订阅统一记在 `_subs`，换内核前全部 cancel
  ///    （否则旧内核 dispose 后其流关闭，会产生未捕获错误）。
  void _wireKernel(PlayerKernel kernel) {
    bool? lastPlaying;
    // ---- 位置补发定时器（配合内核的推送限流）----
    //
    // 内核把位置推送限流到 250ms 以消除"每帧重建整页"。
    // 本定时器每 250ms 调一次 `flushPendingPosition()` ——
    // 内核侧**只在有挂起位置时**才真正发事件（空调用无开销），
    // 保证限流窗口内的最后一次位置不丢（暂停/seek 后进度条不停住）。
    _posFlushTimer?.cancel();
    _posFlushTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => kernel.flushPendingPosition(),
    );

    _subs.add(kernel.stateStream.listen((s) {

      // ---- ★ 会话状态同步（K3，2026-10-09）----
      //
      // 把状态推给原生会话 → 刷新通知栏（标题/进度/播放中）。
      // 放在这里的原因：**所有**状态变化都经过这个 listen，
      // 挂在别处（如播放/暂停按钮）必然会漏掉手势、自动连播等路径。
      //
      // `SessionStateSync` 内部做**秒级去重**：进度是每 250ms 推一次的，
      // 不去重会让通知栏被刷爆（CPU 白耗 + 通知闪烁）。
      _sessionSync.sync(s);

      // ---- ★ 自动跳过片头（对齐旧页）----
      //
      // 挂这里的原因与 `_sessionSync` / 唤醒锁相同：这是**所有**状态变化的
      // 汇聚点。挂到"播放按钮"里会漏掉手势、自动连播、媒体键等路径
      // —— 而那些正是"换个片头"最常发生的时机。
      //
      // 内部用 `_introSkipped` 保证**一集只跳一次**（位置是 250ms 推一次的，
      // 不加门会反复回跳）。`_autoIntroSkip` 是用户偏好，默认关。
      _checkIntroSkip();

      // ---- ★ 唤醒锁：跟随"是否在播"（K3.6）----
      //
      // 播放中 → 屏幕常亮；暂停 → 允许熄屏。
      //
      // 为什么挂在这里：这里是**所有**状态变化的汇聚点（与 `_sessionSync`
      // 同一位置）。挂到播放/暂停按钮里会漏掉手势、自动连播、媒体键等路径。
      //
      // ⚠️ 只在实际变化时调：`enable/disable` 是 MethodChannel 往返，
      //    每次状态推送都调会白耗（进度是 250ms 推一次的）。
      if (_wakelock.enabled != s.playing) {
        unawaited(s.playing ? _wakelock.enable() : _wakelock.disable());
      }
      // ---- ★ 首帧到达计时（用户感知的"起播时间"）----
//
// ## 实测数据（3 次有效采样，2026-10-08，真机 K40）
// ```
// prefRead        234 ms   ← 读一个偏好（secure_storage / Keystore 解密）
// resolve          88 ms   ← Emby 要直链（首次冷连 5778ms）
// kernelCreate      4 ms
// open             43 ms   ← 只等 loadfile 命令下发，**不等画面**
// seek / rate       5 ms
// ───────────────────────
// Dart 命令链合计   314 ms  ← 只占 6%
// FIRST_FRAME     4754 ms  ← ★ 94% 的时间在这
// ```
// ⇒ **"起播慢"确认存在，但不在 Dart 侧**。慢在"mpv 打开 URL →
//    解封装 → 解码器就绪 → 首帧送显"这一段（Dart 只占 6%）。
//
// ## ⚠️ 本探针有已知缺陷（下一轮必须换掉判据）
// 判据用 `position > 0`，**有续播进度时会给出假值**：
// 因为会先 `seek(resume)` → mpv 立刻回报 `time-pos=63`（seek 目标位置），
// 此时画面还没出来，却被判成"首帧到达"。
//
// 实测对照（第 4 次采样暴露）：
//   · `resume=63s`（触发 seek）→ FIRST_FRAME=**5ms**              ← 假值
//   · `resume<3s`（不 seek）   → FIRST_FRAME=**4754/4503/5758ms** ← 真值
//
// **正确判据**：mpv 的 `vo-configured` 属性或 `video-reconfig` 事件 ——
// 它们只在渲染器真正拿到首帧时触发，与 seek 无关。
// （mpv 自身日志在 release 包里不输出：实测 logcat 中 mpv 相关行数 = **0**，
//   故只能走"属性/事件"路线，不能靠 `--msg-level` 日志。）
//
// 引用本数据时**只用不触发 seek 的那几次**，或先修好探针再量。
      // ① 解封装探测完成：duration 首次拿到（此前一直是 0）
      //
      // 它意味着**容器已识别、时长已知** —— 网络读取 + 解封装这一阶段结束。
      // 用它能区分"慢在网络/容器探测"与"慢在解码器初始化"。
      if (!_demuxLogged && s.duration > Duration.zero) {
        _demuxLogged = true;
        _stage('DEMUX_DONE');
      }

      // ② ★ 首帧真正渲染：position **超过** seek 目标
      //
      // ## 为什么不是 `position > 0`（旧判据的错）
      // seek 后 mpv **立刻**回报 `time-pos = 目标值`（如 63.000s）——
      // 那只是"跳转已登记"，画面还没出来。旧判据在此时就判"首帧到达"，
      // 于是测出假的 5ms（实测第 4 次采样暴露的矛盾）。
      //
      // 正确判据：位置**越过**目标继续推进 ⇒ 解码器已就绪、首帧已送显。
      // 容忍 0.5s 误差，避免把 seek 后的微抖当推进。
      //
      // ## ⚠️ 还必须等"起播已发起"（本轮补的门）
      // `stateStream` 是**随时**推的（包括 `open` 之前）。若此时
      // `_seekTarget` 尚未设好（=0），`position > 0.5s` 会立刻成立
      // ⇒ 测出假的首帧（实测抓到 `FIRST_FRAME=32ms` 而
      // `seekTarget=0s`/`resume=785s` 自相矛盾）。
      // ⇒ 只在"确实发起过起播"之后才判定（`_startupBegun`）。
      final past = s.position > _seekTarget + const Duration(milliseconds: 500);
      if (_startupBegun && !_firstFrameLogged && past) {
        _firstFrameLogged = true;
        _stage('FIRST_FRAME');
        debugPrint('[Startup] ===== 点到出画面 '
            '${_sw?.elapsedMilliseconds ?? 0}ms '
            '(seekTarget=${_seekTarget.inSeconds}s) =====');
      }

      final p = ref.read(playbackStateProvider.notifier);
      p.setPlaying(s.playing);
      p.setPosition(s.position);
      p.setDuration(s.duration);
      p.setBuffer(s.buffer);
      p.setBuffering(s.buffering);
      p.syncSpeed(s.rate);
      // 播放状态变化 → 即时上报（旧页同款：Unpause / Pause）
      if (lastPlaying != null && _started && lastPlaying != s.playing) {
        _reportEvent(s.playing ? ProgressEvent.unpause : ProgressEvent.pause);
        // ---- ★ Trakt 实时追踪（复用同一个"播放态变化"判据）----
        //
        // ## 为什么挂这里而不是播放/暂停按钮
        // 与上面 `_reportEvent` 同理：这里是**所有**状态变化的汇聚点，
        // 挂按钮会漏掉手势、媒体键、自动连播等路径。
        //
        // ## 与 Emby 上报的区别（不能合并）
        // · `_reportEvent` 发给 **Emby**（它自己的进度体系）
        // · 这里发给 **Trakt**（契约要求 progress 是 0–100）
        // ⇒ 两个体系独立开关（用户可能只开一个）。
        if (_traktRep != null) {
          _traktScrobble(playing: s.playing, position: s.position,
              duration: s.duration);
        }
      }
      lastPlaying = s.playing;
    }));
    _subs.add(kernel.tracksStream.listen((t) {
      // 轨道列表：内核轨道 + 服务端名字由 TrackAligner 对齐；
      // 这里的列表仅含内核侧（对齐版在 _applyServerDefaultTracks 后
      // 以 AlignedTrack.label 替换 —— 见 _syncTrackLists）。
      _syncTrackLists(launch: _launch, kernel: t);

      // ★★ **补做默认轨选择**（真机实测的时序兜底）
      //
      // ## 为什么必须在这里
      // `_applyServerDefaultTracks` 可能在内核上报轨道**之前**就跑了
      // （4K 片源 demuxer 分析要 3–5s）⇒ 它看到空列表、逻辑空转
      // ⇒ 现象就是"没声音 + 没字幕"（用户上报的两个问题）。
      //
      // 而本回调**一定在轨道到达时触发** ⇒ 用它补做，只做一次。
      final pending = _pendingDefaultTracks;
      if (pending != null &&
          (t.audio.isNotEmpty || t.subtitle.isNotEmpty)) {
        _pendingDefaultTracks = null; // 先清，防重入
        debugPrint('[PlayerFlow] 轨道已到达 ⇒ 补做默认轨选择'
            '（音频 ${t.audio.length} / 字幕 ${t.subtitle.length}）');
        unawaited(_applyServerDefaultTracks(pending));
      }
    }));
    // ---- 错误处理：**必须限流 + 去重**（真机事故）----
    //
    // ## 为什么不能每次事件都 setError + 弹 SnackBar
    // 真机实测（2026-10-07）：一个**死源 STRM** 片源切到转码 HLS 后，
    // mpv 对每个分片都失败一次，48 秒内抛出 **1024 次 `end-file error`
    // （21.3 次/秒）**。原实现每次都：
    //   1. `setError(...)` → 触发 playbackStateProvider 重建
    //   2. `showSnackBar(...)` → 入队一个 SnackBar
    // 结果是 **UI 被淹没**：SnackBar 排成长队、整页持续重建，
    // 用户点什么都没反应 —— 现象就是"新 UI 的功能全都用不了"。
    //
    // ## 修法：**同一错误只在首次上报 + 冷却期内不重复**
    // 保留"要报错"的语义（真错误必须让用户知道），
    // 但把**冗余的重复**去掉（同一个源连续失败 1000 次，用户只需要知道一次）。
    _subs.add(kernel.errorStream.listen((e) {
      final now = DateTime.now();
      final isSame = e == _lastKernelError;
      final withinCooldown = _lastKernelErrorAt != null &&
          now.difference(_lastKernelErrorAt!) < _kernelErrorCooldown;
      if (isSame && withinCooldown) {
        _kernelErrorDropped++;
        return; // 同一条错误、冷却期内 → 丢弃（不重建 UI、不弹提示）
      }
      _lastKernelError = e;
      _lastKernelErrorAt = now;
      if (_kernelErrorDropped > 0) {
        // 让用户知道"刚才刷了很多次"，而不是以为只错了一次
        debugPrint('[PlayerFlow] 已抑制 $_kernelErrorDropped 条重复错误');
        _kernelErrorDropped = 0;
      }
      ref.read(playbackStateProvider.notifier).setError(e);
      // ★★ **解码失败 → 自动换到可播的音轨**（不能只报错就停在那）
      //
      // ## 为什么必须自动恢复（真机实测的死局）
      // 《复仇者联盟》在 **Media3** 内核下：
      // ```
      // CF-Media3: 播放错误: ERROR_CODE_DECODER_INIT_FAILED
      //            MediaCodecAudioRenderer error, index=1,
      //            format=Format(3, 国语, ..., truehd)
      // ```
      // Media3 的 `AudioRenderer` 初始化失败 ⇒ **整个播放停住**
      //（不是"静音继续播"）。用户看到的是黑屏/卡住 + 一条报错。
      //
      // ## 为什么"只报错"不够
      // 该片有 6 条音轨，其中 **4 条可播**（DTS 核心 / AC3）。
      // 报错时用户并不知道"换一条就有声音了"。
      // ⇒ 自动退到可播轨（保留语言意图），并**告诉用户已经换了**。
      //
      // ⚠️ 只在**音频**解码失败时做；字幕失败不换轨（字幕失败不阻塞播放）。
      // ⚠️ 每次播放只自动恢复**一次**（`_autoRecoveredAudio`）——
      //    否则若所有轨都不可播，会无限循环切轨。
      if (!_autoRecoveredAudio && _looksLikeAudioDecoderFailure(e)) {
        _autoRecoveredAudio = true;
        unawaited(_recoverAudioTrack(e));
      }
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(e), behavior: SnackBarBehavior.floating),
        );
      }
    }));
    _subs.add(kernel.completedStream.listen((_) => _onCompleted()));
    // ★★ 字幕 cue（Media3 内核的**唯一**字幕显示通路）
    //
    // ## 为什么必须接这条流（真机取证）
    // Media3 把 PGS 等内嵌字幕解析成 cue 后，官方渲染靠 `media3-ui`
    // 的 `SubtitleView`；本项目不引它（视频走 Flutter 纹理，
    // 没有 View 层）⇒ cue 解析出来了却**无人绘制**
    //（真机：`选轨成功` + `mime=application/x-media3-cues` 但画面空白）。
    //
    // ## 为什么做指纹去重（性能）
    // PGS 是逐帧位图，Media3 会在每次 cue 变化时重发；
    // 连续帧**常完全相同** ⇒ 不去重会每帧 setState 整页（控制层/面板全重算）。
    _subs.add(kernel.cuesStream.listen((cues) {
      final fp = _fingerprintOf(cues);
      if (fp == _cuesFingerprint) return; // 内容未变 → 不重建
      _cuesFingerprint = fp;
      if (!mounted) return;
      setState(() => _cues = cues);
      // 诊断：能一眼看出"cue 到了没 / 是图形还是文本 / 比例字段有没有到"
      //
      // ⚠️ 必须打 `size`/`bitmapHeight` —— 只打宽高像素**证明不了**
      //    "比例字段到达 Dart"（真机排查时正是这个盲区：字幕不显示，
      //    无法判断是"字段没到"还是"公式算错"）。
      if (cues.isNotEmpty) {
        final graphic = cues.where((c) => c.pngBytes != null).length;
        final f = cues.first;
        debugPrint('[PlayerFlow] 字幕 cue：${cues.length} 条'
            '（图形 $graphic / 文本 ${cues.length - graphic}）'
            '${f.pngBytes != null ? "px=${f.width}x${f.height}"
                " size=${f.size} bh=${f.bitmapHeight}"
                " line=${f.line} lt=${f.lineType} la=${f.lineAnchor}"
                " pos=${f.position} pa=${f.positionAnchor}" : " «${f.text}»"}');
      } else {
        debugPrint('[PlayerFlow] 字幕 cue：清屏');
      }
    }));
    // 视频分辨率解析完成 → 重算宽高比（首帧时触发一次）
    _subs.add(kernel.videoSizeStream.listen((_) {
      // ★★ 同步把**渲染画布**设成视频尺寸（真机实测抓到的"画面被压扁两次"）
      //
      // ## 为什么必须在这里做
      // `videoSizeStream` 正是 `dwidth`/`dheight` 到齐时触发的 ——
      // 这是唯一能拿到"视频显示尺寸"的时刻，也是设置画布尺寸的正确时机。
      //
      // ## 不设会怎样（实测数据）
      // 画布恒为 `ensureTexture` 的 1920×1080（16:9），而片源可能是
      // 2.39:1 ⇒ mpv 先把画面 letterbox 进 16:9 画布（黑边**进纹理**），
      // Dart 侧 `AspectVideo` 又按片源比例内接一次 ⇒ **双重黑边**：
      // ```
      //   片源 3840x1608（2.388:1），竖屏视口 1080x2400
      //   理论应显示高          452 px
      //   实际（用户截屏实测）   335 px = 452 × 74.4%（画布内占比）
      // ```
      //
      // ## 做法（对齐 media_kit，已读其源码核实）
      // `media_kit_video/.../android_video_controller/real.dart` 直接拿
      // `dw`/`dh` 当画布尺寸。我们也传显示尺寸 ⇒ 画布与视频同比例
      // ⇒ **画布里只有画面、没有黑边** ⇒ 比例由 Dart 层唯一决定。
      //
      // ⚠️ 用 `unawaited`：设置画布是**尽力而为**，不该阻塞 UI 重绘。
      //    失败时画面仍能看，只是比例不准（见 kernel 里的 catch）。
      final r = kernel.aspectRatio;
      if (r != null && r > 0) {
        // 从比例反推一个**尺寸**：宽固定 1920（够清晰且不过大），
        // 高按比例算 —— 这与 media_kit "用较小尺寸提性能"的建议一致
        // （其源码注释：specifying a small width & height
        //   "may yield substantial performance improvements"）。
        //
        // 为什么不直接用 3840x1608：4K 画布的 GPU 纹理开销明显更大，
        // 而画布只是**中转**，最终显示尺寸由视口决定（1080 宽足矣）。
        const canvasW = 1920;
        final canvasH = (canvasW / r).round().clamp(1, 8192);
        unawaited(setSurfaceSizeSafe(kernel, canvasW, canvasH));
      }
      if (mounted) setState(() {});
    }));
  }

  /// 安全设置画布尺寸（吞掉异常 + 日志），供 `videoSizeStream` 调用。
  ///
  /// ## 为什么单独包一层
  /// `unawaited` 出去的 Future 若抛异常会变成**未捕获异步错误**
  /// （本仓库栽过：`_tracksController` 关闭后 add 导致未捕获异常）。
  /// 这里显式 catch，保证"设画布失败"永远不会影响播放。
  static Future<void> setSurfaceSizeSafe(
      PlayerKernel kernel, int w, int h) async {
    try {
      await kernel.setSurfaceSize(w, h);
    } catch (e) {
      debugPrint('[PlayerFlow] 设置画布尺寸失败（非致命）: $e');
    }
  }

  // ---------- 起播 / 换集 ----------

  Future<void> _startEpisode({required double resumeSeconds}) async {
    final k = _kernel;
    if (k == null || _switching) return;
    // 换集时重置首帧标记（否则第 2 集起不再计时）
    _firstFrameLogged = false;
    _startupBegun = false; // 门：本次起播尚未发起（见字段说明）
    _demuxLogged = false;
    final api = ref.read(embyApiProvider);
    if (api == null) {
      ref.read(playbackStateProvider.notifier).setError('未登录');
      return;
    }
    try {
      final launch = await api.resolvePlayback(_current.id,
          mediaSourceId: widget.mediaSourceId);
      _stage('resolve');
      if (!mounted) return;
      _launch = launch;
      // ★ 换集/换片必须清掉"待处理默认轨"—— 否则
      //   会用上一集的默认轨编号去选这一集的轨道（选错）
      _pendingDefaultTracks = null;
      ref
          .read(playbackStateProvider.notifier)
          .setDuration(Duration(milliseconds: _current.runtimeTicks ?? 0));

      // ★★★ 起播前把**渲染画布**设成片源比例（真机实测：修"画面被压扁两次"）
      //
      // ## 为什么必须在这里（不能等 `videoSizeStream`）
      // 真机时序取证（logcat）：
      // ```
      // 17:50:27.671  createTexture: 1920x1080      ← 画布建成 16:9（默认）
      // 17:50:39.003  Video --vid=1 (3840x1608)     ← 12.7s 后内核才知道尺寸
      // 17:50:39.400  setSurfaceSize: 1920x804      ← 此时才改 = **太晚**
      // ```
      // mpv 的 VO 已按 16:9 建立 viewport，改属性不会重建 ⇒ **改了等于没改**
      //（实测：修复前后画面都是 335px，比例 3.224 ≠ 2.388）。
      //
      // ## 为什么这里能拿到尺寸
      // `resolvePlayback` 已经从 Emby 的 `PlaybackInfo` 解析出
      // `MediaStreams[]`，视频流带 **`width`/`height`**（服务端元数据，
      // 不需要解码）⇒ **起播前就知道真实分辨率**。
      //
      // ## 传什么
      // 画布宽固定 1920（够清晰；画布只是中转，最终尺寸由视口决定），
      // 高按片源比例算 ⇒ **画布与片源同比例** ⇒ 画布里只有画面、无黑边
      // ⇒ 比例由 Dart 的 `AspectVideo` 唯一决定。
      //
      // ⚠️ 与 media_kit 一致（其 android 控制器直接用 `dw`/`dh` 当画布尺寸，
      //    源码 `android_video_controller/real.dart`；其注释还提到用小尺寸
      //    "may yield substantial performance improvements"）。
      final vs = launch.streams
          .where((s) => s.type == 'Video')
          .toList();
      final kCanvas = _kernel;
      // 无条件打一行：把"到底为什么没设"直接暴露出来
      //（首版只有成功分支的日志 ⇒ 失败时**一片空白**，无法定位）
      debugPrint('[PlayerFlow] 画布预判：视频流 ${vs.length} 条'
          '${vs.isNotEmpty ? "，尺寸 ${vs.first.width}x${vs.first.height}" : ""}'
          '，kernel=${kCanvas != null}');
      if (vs.isNotEmpty && kCanvas != null) {
        final vw = vs.first.width ?? 0;
        final vh = vs.first.height ?? 0;
        if (vw > 0 && vh > 0) {
          const canvasW = 1920;
          final canvasH = (canvasW * vh / vw).round().clamp(1, 8192);
          debugPrint('[PlayerFlow] 起播前设画布：片源 ${vw}x$vh '
              '→ 画布 ${canvasW}x$canvasH');
          // ★★ 必须**重建**纹理，不能只改尺寸/属性（真机实测）
          //
          // 首版只调 setSurfaceSize（改 SurfaceProducer 声明 + mpv 属性），
          // 日志显示都成功了，但**画面仍是 334px（应 452）**：
          // ```
          // _boot():         createTexture: 1920x1080      ← buffer 定为 16:9
          // _startEpisode(): android-surface-size=1920x804 ← 属性改了
          // ```
          // ⇒ `SurfaceProducer` 的 **buffer 尺寸在创建时固定**，改声明不重建
          //    已分配的 buffer。必须销毁 + 按新尺寸重建。
          //
          // ⚠️ 重建会让视频层闪一下（一帧到几帧）—— 故 `recreateTexture`
          //    内部**按尺寸去重**：同比例连播不重建。
          final changed = await kCanvas.recreateTexture(
              width: canvasW, height: canvasH);
          if (changed && mounted) {
            // 纹理 id 变了 ⇒ 刷新（build 用 `_textureId` 决定渲染哪张纹理）
            setState(() => _textureId = kCanvas.textureId);
          }
        } else {
          debugPrint('[PlayerFlow] 画布预判跳过：宽高无效 '
              '(${vs.first.width}x${vs.first.height})');
        }
      }

      // ---- 章节 + 片头区间（对齐旧页能力）----
      //
      // ## 为什么优先读 launch 而不是单独发请求
      // 服务端把章节放在 `PlaybackInfo` 的 `MediaSource.Chapters` 里
      // （已在 `resolvePlayback` 解析进 `launch.chapters`）——
      // 再调一次 `getChapters` 是**纯浪费的一次往返**。
      // 只有 launch 里确实没有时才回退单独查（老服务器/异常情况）。
      //
      // ⚠️ 换集必须**重置** `_introSkipped`，否则第 2 集不再自动跳片头。
      _introSkipped = false;
      if (launch.chapters.isNotEmpty) {
        _chapters = launch.chapters;
        _intro = _detectIntro(launch.chapters);
      } else {
        _chapters = const [];
        _intro = null;
        // 回退路径：不 await（章节只影响刻度与跳片头，不该拖慢起播）
        unawaited(api.getChapters(_current.id).then((ch) {
          if (!mounted) return;
          setState(() {
            _chapters = ch;
            _intro = _detectIntro(ch);
          });
        }).catchError((Object _) {
          // 章节拿不到不影响播放 —— 不弹错，静默即可
        }));
      }

      // ---- 自动适配：拿到片源特征后再决定一次 ----
      //
      // 若决策结果与当前内核不同 → 换内核（保持进度）。
      // 这是"根据视频自动适配"的落点：决策输入全部来自 launch。
      final adapted = await _adaptKernel(launch);
      _stage('adapt');
      if (adapted == null) return; // 换内核中，本次起播交给新内核
      final k2 = adapted;

      // ★★ 续播位置**随 open 一起下发**（起播优化，2026-10-10）
      //
      // ## 原来错在哪（这段优化曾经是"死代码"）
      // 内核的 `open()` **早就支持** `start` 参数（并会传给原生的
      // `loadfile ... start=`），但**宿主从来没传过它** ——
      // 而是在 open 之后单独调一次 `k2.seek(_seekTarget)`（见下方
      // `_stage('seek')` 那段）。于是"合并 open+seek"的优化
      // **一行都没被执行**（真机埋点里 `seek=4ms` 说明走了老路径）。
      //
      // ⇒ 这里把续播位置交给 open；**保留**下面的显式 seek 作为
      //    **兜底**（`start=` 在 mpv 0.38+ 的签名变化下会静默失效，
      //    见 `NativeKernel.open` 的说明与
      //    `docs/DUAL-KERNEL-OPTIMIZATION.md` 的版本陷阱）。
      //
      // ⚠️ 兜底仍然只在 `resumeSeconds > 3` 时做 —— 与原来一致。
      // ⚠️ **必须在 open 之前**把 seekTarget 记下来（本轮踩到的埋点缺陷）
      //
      // ## 原来的错
      // `_seekTarget` 只在下面 `if (resumeStart != null)` 分支里赋值，
      // 而**首帧探针**（`stateStream` 里）用
      // `position > _seekTarget + 500ms` 判定首帧。续播时若探针在
      // 赋值之前先跑（stateStream 是**随时**推的，包括 open 之前），
      // `_seekTarget` 还是 0 ⇒ **position 一过 0.5s 就判"首帧到达"**
      // ⇒ 测出假的 `FIRST_FRAME=32ms`（真机实测抓到，而当时
      // `seekTarget=0s` 与 `resume=785s` 自相矛盾）。
      //
      // ⇒ 在 open 之前无条件设好；首帧探针另加 `_expectSeekTarget` 门，
      //    确保"还没开始起播就不判定"。
      // ---- ★ Trakt 续播检查：只提示，**不静默覆盖**本地进度 ----
      //
      // ## 为什么在这里（而不是起播前）
      // 起播前 `_traktResumeHint` 可能还没查回来（它是异步的）
      // ⇒ 在**真正决定 seek 目标**的这一刻读它，时机最准。
      //
      // ## 为什么要"每集只问一次"
      // 自动连播会让 `_startEpisode` 对同一集再跑一遍
      //（重试、切音轨后重建也会）⇒ 不去重会连弹多次。
      final hint = _traktResumeHint;
      if (hint != null && hint.shouldPrompt) {
        final key = '${_current.id}';
        if (_traktAskedFor != key) {
          _traktAskedFor = key;
          // 异步弹提示（不 await —— 起播照常进行）
          unawaited(_promptTraktResume(hint, resumeSeconds));
        }
        // ★ 关键：**把 resumeSeconds 归零**，即"按本地进度起播"。
        //   理由见 lib/data/trakt_resume.dart 的文件头：
        //   两个来源的进度会打架，静默用 Trakt 的覆盖 ⇒ 用户"跳着看"。
        resumeSeconds = 0;
      }
      _seekTarget = resumeSeconds > 3
          ? Duration(seconds: resumeSeconds.toInt())
          : Duration.zero;

      final resumeStart = resumeSeconds > 3
          ? Duration(seconds: resumeSeconds.toInt())
          : null;
      await k2.open(
        launch.url,
        play: true,
        headers: launch.headers,
        start: resumeStart,
      );

      // ---- ★ 媒体会话（K3）：起播即启动（2026-10-09）----
      //
      // ## 为什么必须显式启动
      // `MediaSessionService.onCreate` 只在本服务被 startService 时执行，
      // 不启动 ⇒ 没有 MediaSession ⇒ **通知栏与媒体键静默失效**
      //（不报错，只在 logcat 有一行，极难排查）。
      //
      // ## 为什么在这里（open 之后）
      // 此时才知道"放的是哪一集" —— 标题要进通知栏。
      // ---- ★ 内核音量固定为 unity（K3.5）----
      //
      // ## 为什么必须显式设
      // 音量现在**全部**由系统通道负责（`VolumeService`）。
      // 若内核音量还留着旧值，就会变成"系统音量 × 内核音量"的**双重衰减**。
      //
      // ## 为什么不是"不管它"
      // 内核默认确实是 unity（mpv `volume=100`、Media3 `volume=1.0`），
      // 但**上一次播放可能把它改低了**（尤其换内核/换集时）。
      // 显式设置才能保证每次起播都回到干净状态。
      //
      // ⚠️ 唯一会临时改它的地方是**音频焦点 duck**（见 `case 'duck'`），
      //    那个路径结束时会还原到 unity。
      // ⚠️ 用 `_kernel` 而不是局部 `k`：此处 `k` 尚未定义
      //    （`k` 在 `_startEpisode` 的稍后位置才赋值）。
      unawaited(_kernel?.setVolume(kKernelUnityVolume) ?? Future.value());

      // ---- ★ 系统音量：读初值 + 开始监听（K3.5）----
      //
      // ## 为什么必须读初值
      // 进播放页前系统音量可能是任意值（用户刚才调过、或上次播放留下的）。
      // 不读 ⇒ 滑块显示默认 70，与**实际响度不符** —— 用户会以为 App 坏了。
      //
      // ## 为什么必须监听
      // 用户按**手机侧边音量键**时系统音量变了，而 App 的滑块不动 ⇒
      // UI 与实际不一致。监听后同步（这是本轮的**核心需求**）。
      //
      // ⚠️ 回环防护在 `VolumeService` 内部（按值去重），
      //    且 `syncFromSystem` **故意不触发 onChanged**（见其注释）——
      //    两者缺一就会形成"系统→UI→系统"回环。
      unawaited(() async {
        await _volumeService.init();
        if (!mounted) return;
        ref
            .read(audioStateProvider.notifier)
            .syncFromSystem(_volumeService.value / 100);
        _volumeService.onSystemChanged = (v) {
          if (!mounted) return;
          ref.read(audioStateProvider.notifier).syncFromSystem(v / 100);
        };
        _volumeService.startListening();
      }());

      unawaited(SessionBridge.instance.start());
      if (mounted) {
        // 复用与页面顶栏**同一对纯函数**（`topTitleFor` / `subtitleFor`）——
        // 通知栏与页面显示的标题因此逐字一致，不会出现
        // "通知栏写第 3 集、顶栏写第 4 集"这类不一致。
        //
        // ⚠️ 不用 `mediaInfoProvider`：`MediaInfo` 是**技术信息容器**
        //    （fileName/codec/width/height…），没有"这一集叫什么"。
        final api = _api;
        _sessionSync.setMediaInfo(
          title: PlayerFlowPage.topTitleFor(_current),
          subtitle: PlayerFlowPage.subtitleFor(_current) ?? '',
          // 图片地址需要 `MediaProvider`（Emby 的图片 URL 由服务端地址 +
          // token 拼出，`MediaItem` 自己只有 `imageTags`）。
          // `posterUrl` 已内含"自身图缺失时逐级回退到父级/剧集图"的逻辑，
          // 直接复用，不再自己拼 URL。
          artworkUrl: api == null ? null : _current.posterUrl(api, maxWidth: 480),
        );
      }
            _startupBegun = true;   // 门：此后 stateStream 的推进才算首帧
_stage('open');
      // ---- 续播位置的**兜底** seek ----
      //
      // `open(start:)` 已把位置交给原生（`loadfile ... start=`），
      // 正常情况下**这里不需要再 seek**（省一次往返 = 起播更快）。
      //
      // 但两种情况下必须补：
      //  ① 内核没实现 `start`（如未来的非纹理内核）——
      //     只有 mpv/Media3 支持，其他内核靠这里兜住
      //  ② `start=` 静默失效（mpv 0.38+ 的 `loadfile` 参数位变化，
      //     见 docs/DUAL-KERNEL-OPTIMIZATION.md 的版本陷阱）
      //
      // ⇒ 判据：`NativeKernel` 会在 open 内部核对位置并在必要时
      //    自行补 seek（见其 `_startApplied` 逻辑）；这里只在
      //    "内核报告 start 未生效"时补，避免重复跳转。
      if (resumeStart != null) {
        // 记下目标 —— 首帧探针要用它区分"seek 刚登记"与"真的在推进"
        //（`_seekTarget` 已在 open 之前设好，这里只做兜底 seek）
        final appliedByOpen = k2 is NativeKernel
            ? k2.startAppliedByLoadfile
            : true; // 非 mpv 内核（Media3）在 open 内部已处理
        if (!appliedByOpen) {
          await k2.seek(_seekTarget);
        }
      }
      _stage('seek');
      // 默认倍速偏好
      final savedRate = double.tryParse(
          await ref.read(sessionStoreProvider).getPref('default_rate') ?? '');
      if (!mounted) return;
      if (savedRate != null && savedRate != 1) {
        await k2.setRate(savedRate);
      }
      _stage('rate');
      debugPrint('[Startup] TOTAL=${_sw?.elapsedMilliseconds ?? 0}ms '
          '(resume=${resumeSeconds.toInt()}s)');
      _reportStart(launch);
      unawaited(_applyServerDefaultTracks(launch));
      // ★ 外挂字幕（Emby IsExternal）—— 必须在 open 之后
      //（内核看不到容器外的字幕流，只能由 App 主动加载）
      unawaited(_loadExternalSubtitles(launch));
      _fillMediaInfo(launch);
      // 服务端流列表先喂轨道面板（内核轨道随后到达时会再对齐一次）
      _syncTrackLists(launch: launch, kernel: k2.tracks);
      // 韧性布防：起播超时 + 速度监测（初始与换集都要布，旧页同款）
      _startSpeedWatch();
      _armStartTimeout();
    } catch (e) {
      if (!mounted) return;
      ref.read(playbackStateProvider.notifier).setError('起播失败：$e');
    }
  }

  // ---------- 内核自动适配 ----------

  /// **根据片源特征决定内核**，必要时换内核。返回应用来起播的内核。
  ///
  /// ## 为什么在这里（而不是 `_boot`）
  /// 适配输入（容器/编码/分辨率/HLS）**全部来自 `resolvePlayback`**，
  /// 而 `_boot` 执行时还没拿到它。故 `_boot` 只按用户偏好建默认内核，
  /// 真正的适配在拿到 launch 之后。
  ///
  /// ## 换内核为什么要重建实例（不能复用）
  /// 两个内核持有**各自的**原生播放器与 Flutter 纹理。
  /// 在同一个实例上切类型是不可能的；必须 dispose 旧的、建新的。
  ///
  /// ⚠️ 纹理 id 会变 —— 必须 `setState` 让 build 用新 id，
  ///    否则视频层显示的是**已释放的旧纹理**（现象：黑屏但声音正常）。
  ///
  /// ## 返回 null 的含义
  /// 表示"正在换内核，本次起播中止" —— 调用方必须**直接 return**，
  /// 由换内核后的流程重新起播（否则会往旧内核上 open，白白起一次流）。
  Future<PlayerKernel?> _adaptKernel(PlaybackLaunch launch) async {
    final current = _kernel;
    if (current == null) return null;

    final traits = traitsFromLaunch(launch);
    final decision =
        KernelAutoSelect.select(traits, preference: _preference);

    // 决策未变 → 沿用（绝大多数情况走这条，零开销）
    if (decision.kernel == _activeKernelType) {
      _decision = decision;
      debugPrint('[Kernel] $traits -> ${decision.kernel.name}'
          '（${decision.reason}）');
      // ★ 这条路径**也要自检**。
      //
      // ## 为什么（真机踩过）
      // 绝大多数情况走这条（同分辨率同格式的连续剧集内容）——
      // 若只在"换内核"时自检，则**正常起播根本没有自检日志**，
      // 真机实测就是如此（只有切 4K 那次有日志，看起来像"自检没跑"）。
      //
      // ⚠️ 必须在 `return` **之前**调 —— 放到 return 后面就是死代码
      //    （本项目已有"写在 return 后"的同类疏忽）。
      unawaited(PlayerFlowPage._verifyMpvConfig(current));
      return current;
    }

    // ---- 需要换内核 ----
    debugPrint('[Kernel] 换内核 ${_activeKernelType.name} -> '
        '${decision.kernel.name}（${decision.reason}）');

    // 记住当前进度，换完续播（不能从头开始）
    final resumeAt = current.state.position;

    _switching = true;
    try {
      // 先摘事件订阅：旧内核 dispose 后这些流会关闭
      for (final sub in _subs) {
        unawaited(sub.cancel());
      }
      _subs.clear();
      await current.dispose();

      final next = PlayerKernelFactory.create(decision.kernel);
      await next.ensureTexture();
      if (!mounted) {
        unawaited(next.dispose());
        return null;
      }
      _kernel = next;
      _activeKernelType = decision.kernel;
      _decision = decision;
      _textureId = next.textureId;
      _wireKernel(next); // 重新挂状态回流

      setState(() {}); // 纹理 id 变了，必须重建视频层
    } finally {
      _switching = false;
    }

    // ★ 换内核后**必须自检**：配置属于新实例，旧结论不再适用。
    //   放在 `try` **之后**（此时 `_kernel` 确已是 `next`，且 `_switching` 已复位）。
    unawaited(PlayerFlowPage._verifyMpvConfig(_kernel));

    // 用新内核重新起播（进度保持）；递归调用会命中"决策未变"分支
    final k = _kernel;
    if (k != null && resumeAt > const Duration(seconds: 3)) {
      _resumeSeconds = resumeAt.inSeconds.toDouble();
    }
    // 返回 null 让调用方中止本次 open —— 因为这里已经重新起播了
    unawaited(_startEpisode(resumeSeconds: _resumeSeconds));
    return null;
  }

  // ---------- 播放韧性（旧页三件套移植）----------

  /// **主动停掉已判定为死源的播放**（真机事故的关键修复）。
  ///
  /// ## 为什么需要"停"而不只是"报错"
  /// 真机实测（2026-10-07）：死源 STRM 切到转码 HLS 后，mpv 会对**每个
  /// 分片**分别尝试并失败，48 秒内抛 **1024 次 `end-file error`
  /// （21.3 次/秒）**。原实现只 `setError('连接超时…')`，
  /// **mpv 并不知道该放弃**，仍在后台疯狂重试：
  ///   · 事件线程持续刷 `end-file`
  ///   · Dart 侧 errorStream 持续触发 UI 重建
  ///   · 结果：整页卡顿，用户点什么都没反应
  ///
  /// **"报错"与"停止"是两件事** —— 前者面向用户，后者面向内核。
  /// 缺了后者，错误提示再清楚，机器仍在空转。
  ///
  /// ## 这里做什么
  ///   1. 停掉内核（`pause` + `stop` 语义：用 seek(0)+pause 让 mpv 退出重试）
  ///   2. 置错误态（用户可见）
  ///   3. 停掉两个韧性计时器（不再重复判定）
  ///
  /// ⚠️ 不 `dispose` 内核：用户可能想看设置面板/切集，
  ///    把内核拆了会导致后续操作全失效（那是更大的问题）。
  Future<void> _stopDeadSource(String message) async {
    if (_deadSourceReached) return; // 幂等：只停一次
    _deadSourceReached = true;

    _startTimeout?.cancel();
    _speedTimer?.cancel();

    final k = _kernel;
    if (k != null) {
      try {
        // 先暂停：让 mpv 停止"重新打开分片"的循环
        await k.pause();
      } catch (_) {
        // 内核已坏时 pause 可能失败 —— 不影响后续提示
      }
    }
    if (!mounted) return;
    ref.read(playbackStateProvider.notifier).setError(message);
    _snack(message);
  }

  /// 起播超时布防：15s 后若仍"无时长且无进度推进"→ 判定挂死。
  ///
  /// 判据复用 `PlayerPage.shouldTimeout` 纯函数（旧页单测的真值表就是它，
  /// 两页共用一份逻辑，避免测试与实现各自漂移）。
  void _armStartTimeout() {
    _startTimeout?.cancel();
    final k = _kernel;
    if (k == null) return;
    _positionAtArm = k.state.position;
    _startTimeout = Timer(PlayerPage.startTimeoutDuration, () {
      if (!mounted) return;
      final cur = _kernel;
      if (cur == null) return;
      final dead = PlayerPage.shouldTimeout(
        playing: cur.state.playing,
        duration: cur.state.duration,
        position: cur.state.position,
        positionAtArm: _positionAtArm,
      );
      if (!dead) return;
      // ══════════════════════════════════════════════════════════════
      // ⚠️ 2026-10-15：**不要盲目自动切转码**
      // ══════════════════════════════════════════════════════════════
      //
      // ## 用户的实测结论（当轮原话）
      // > "不转码，我这个服务端好像不能转"
      //
      // ## 为什么原来这条是坑
      // 旧逻辑：直连超时 ⇒ 只要 `transcodingUrl` 非空就切转码。
      // 但在**不支持转码**的服务器上（Emby 免费版无 Premiere）：
      // ```
      // master.m3u8 请求返回 200（一个"空转"的播放列表）
      //   → 里面的分段 URL 形如 /hls1/main/265.mp4?PlaySessionId=..
      //   → 服务端**没有转码任务** ⇒ 缺 `runtimeTicks` 等 [Required] 参数
      //   → 每个分段 **HTTP 400** ⇒ mpv `end-file error` ⇒ "播放失败（内核报错）"
      // ```
      // ⇒ 用户看到的错误**指向转码**，而真实原因是**源本身不可用**
      //   （违背本仓库 §5.5"不要把失败伪装成别的东西"的同类问题）。
      //
      // ## 修法
      // 只有**确认服务器能转码**时才自动切；否则直接走"源不可用"分支。
      // 判据：`_transcodeUsable`（`transcodingUrl` 非空**且**服务端声明可转码）。
      if (_playMethod == 'direct' && _transcodeUsable) {
        unawaited(_reopenAs('transcode', reason: '直连超时，已切换转码'));
      } else {
        // 直连与转码都失败 → 判定源已死，**主动停掉内核**。
        //
        // ⚠️ 必须真的停：实测死源会让 mpv 对每个 HLS 分片各失败一次
        //    （48 秒 1024 次），光设错误文案不会让 mpv 停下来，
        //    后台仍会一直刷 `end-file error`，把 UI 拖垮。
        unawaited(_stopDeadSource('连接超时，该视频源可能不可用'));
      }
    });
  }

  /// 起播速度监测：前 30 秒每 2s 采样，缓冲 <4s 累计 3 次 → 提示切转码。
  void _startSpeedWatch() {
    _speedTimer?.cancel();
    _bufStalls = 0;
    var samples = 0;
    _speedTimer = Timer.periodic(const Duration(seconds: 2), (t) {
      if (!mounted) return t.cancel();
      final k = _kernel;
      if (k == null) return t.cancel();
      samples++;
      if (samples > 15 || !k.state.playing) return;
      if (k.state.buffering) return; // 正在缓冲不计
      if (k.state.duration.inSeconds > 0 && k.state.buffer.inSeconds < 4) {
        _bufStalls++;
      } else {
        _bufStalls = 0;
      }
      if (_bufStalls >= 3 && !_netSlowHint) {
        t.cancel();
        _netSlowHint = true;
        _snack('网络速度不足，建议切换转码', action: () {
          unawaited(_reopenAs('transcode', reason: '已切换转码'));
        });
      }
    });
  }

  /// 切换播放方式（直连 / 转码），保持当前进度。
  ///
  /// 切到转码后同样重新布防超时（"直连超时→切转码→转码也超时"不能
  /// 变回灰屏死等，旧页踩过）。
  /// ⚠️ **服务器是否具备转码能力**（2026-10-15，用户实测结论驱动）。
  ///
  /// ## 用户的结论（当轮原话）
  /// > "不转码，我这个服务端好像不能转"
  ///
  /// ## 为什么不能只看 `transcodingUrl` 非空
  /// 我们**自己拼**的 `master.m3u8` URL 永远非空（`emby_provider.dart` 里
  /// 无条件生成），所以"非空"**不代表服务端能转码**：
  /// ```
  /// 不支持转码的服务器：
  ///   master.m3u8 请求 → 200（一个"空转"的列表）
  ///   → 分段 /hls1/main/NNN.mp4?PlaySessionId=.. → **HTTP 400**
  ///     （服务端无转码任务 ⇒ 缺 runtimeTicks 等 [Required] 参数）
  /// ```
  ///
  /// ## 判据
  /// 以 **`MediaSource.supportsTranscoding`**（服务端自报）为准。
  /// ⚠️ 本仓库 2026-10 实测：该字段**会误报 true**
  ///    （`emby_provider.dart:1241` 的实测注释），
  ///    但"误报 true"在**能力探测**场景下是**安全的失败方向**：
  ///    它只会让我们"尝试一下转码"，而**不会**让我们在
  ///    "确实不能转码"时误判为可以（那种才危险）。
  ///    ⇒ 真正的兜底是 `transcodingUrl` 为空时直接拒绝（见 `_reopenAs`）。
  bool get _transcodeUsable {
    final l = _launch;
    if (l == null) return false;
    if ((l.transcodingUrl ?? '').isEmpty) return false;
    if (l.supportsTranscoding == false) return false;
    return true;
  }

  Future<void> _reopenAs(String method, {String? reason}) async {
    final launch = _launch;
    final k = _kernel;
    if (launch == null || k == null || _switching) return;
    if (method == 'transcode') {
      // ══════════════════════════════════════════════════════════════
      // ⚠️ 2026-10-15：**不支持转码的服务器就明确拒绝**（别让用户撞 400）
      // ══════════════════════════════════════════════════════════════
      //
      // ## 用户报障（原话）
      // > "切换转码后还是内核报错"
      // > "不转码，我这个服务端好像不能转"
      //
      // ## 为什么原来只是"无可用转码流"就放过了
      // 旧判断 `(launch.transcodingUrl ?? '').isEmpty` **永远为假**
      // —— 因为那个 URL 是**我们无条件拼的**（`emby_provider.dart`），
      // 不代表服务端真能转码 ⇒ 用户切过去 ⇒ 分段全 400 ⇒ "内核报错"。
      //
      // ## 修法：明确告知 + 不切
      // ⚠️ 文案要说**真实原因**（服务器不具备转码能力），
      //    而不是含糊的"该媒体源没有可用的转码流"
      //    —— 后者会让用户以为是**片源**问题（违背 §5.5 的同类原则）。
      if (!_transcodeUsable) {
        _snack('该服务器未启用转码（Emby 需要 Premiere）；'
            '本片请用直连播放');
        return;
      }
    }
    if (method == _playMethod) return;
    final keepPos = k.state.position;
    setState(() {
      _playMethod = method;
      _switching = true;
    });
    try {
      //
      // ## 为什么要它（不能再靠推断）
      // 已代码级确认（Jellyfin `DynamicHlsController.cs`）：
      // **分段端点**有两个 `[Required]` 查询参数：
      // ```
      // [FromQuery, Required] long runtimeTicks,
      // [FromQuery, Required] long actualSegmentLengthTicks,
      // ```
      // 缺任一个 ⇒ 模型验证失败 ⇒ **400** ← 与真机现象吻合。
      //
      // 但"为什么缺"有两种可能，**修法完全相反**：
      // | 假设 | 修法 |
      // |---|---|
      // | **A：服务端不转码**（免费版无 Premiere）⇒ 播放列表是"假的" | **隐藏转码入口** |
      // | **B：我们请求参数不全** ⇒ 服务端生成的列表不完整 | 补齐请求参数 |
      //
      // ⇒ 判据：**把 `master.m3u8` 的响应体打出来看**。
      //    · 若 `CODECS` 仍是源编码（`hvc1`/`hevc`）⇒ 服务端**没转码** ⇒ 假设 A
      //    · 若分段 URL 里**没有** `runtimeTicks` ⇒ 服务端确实没写 ⇒ 假设 A/B
      //
      // ## 为什么只读、不改行为
      // 只发一次 GET + 打日志；**无论结果如何都继续原来的播放流程**
      // ⇒ 不会让"本来能播的"变得播不了。
      //
      // ## 顺手验证"X-Emby-Token 头"这个假设
      // 同时用**带头**的方式请求一次，对比状态码
      // ⇒ 若"带头仍 400"就证明**不是鉴权问题**（省得我继续在 headers 上白费功夫）。
      // ══════════════════════════════════════════════════════════════
      // ★★ 2026-10-15 修：**转码切换必须带鉴权头**（分段 400 的真根因）
      // ══════════════════════════════════════════════════════════════
      //
      // ## 真机证据（用户："切换转码后还是内核报错"）
      // ```
      // Playing: .../hls1/main/265.mp4?PlaySessionId=3b46bdde-...
      //                                ↑ 有 PlaySessionId（上一轮的修复生效了）
      // http: HTTP error 400 Bad Request         ← ★ 仍然 400
      // ```
      // ⇒ `PlaySessionId` 不是唯一原因。
      //
      // ## 真根因：**`_reopenAs` 是唯一没传 `headers` 的 `open()` 调用**
      // ```
      // 1656|  直连起播   → headers: launch.headers   ✅
      // 2099|  另一处     → headers: launch.headers   ✅
      // 2004|  _reopenAs  → **没有**                  ❌  ← 切转码走的就是这条
      // ```
      // **Emby 生成 HLS 播放列表时不把 `api_key` 透传到分段 URL**
      // （服务端只透传了 `PlaySessionId`）⇒ 分段请求**无鉴权** ⇒ 400。
      // ⇒ **唯一可靠的补法是在请求头里带 token**
      //   （mpv 的 `http-header-fields` 对**所有**后续请求生效，
      //    包括服务端自己生成的分段 URL —— 这正是我们要的）。
      //
      // ## 能力早就有，只是没接上
      // · `PlayerChannel.kt:475` 已实现 `http-header-fields` 的设置
      // · `kernel.dart:349` 的 `open()` 已有 `headers` 参数
      // ⇒ 只需在此处**传进去**。
      //
      // ## token 从哪来（**不新增依赖**）
      // `launch.url` 的注释明确写着"**含 api_key**" ⇒ 直接从直连 URL 里解析，
      // 不必去碰 `EmbyProvider`（符合 §5.1"UI 只依赖 MediaProvider 抽象"）。
      // ⚠️ 不要为此给 `MediaProvider` 加 getter —— 那是无谓的接口扩张。
      final hdrs = <String, String>{...launch.headers};
      if (method == 'transcode' &&
          !hdrs.containsKey('X-Emby-Token') &&
          !hdrs.containsKey('X-Emby-Authorization')) {
        final tok = _tokenFromUrl(launch.url);
        if (tok.isNotEmpty) hdrs['X-Emby-Token'] = tok;
      }
      hdrs.removeWhere((_, v) => v.isEmpty);
      debugPrint('[PlayerFlow] 切 $method：'
          '${hdrs.isEmpty ? "无鉴权头" : "带头 ${hdrs.keys.join(",")}"}');
      await k.open(
          method == 'transcode' ? launch.transcodingUrl! : launch.url,
          play: true,
          headers: hdrs.isEmpty ? null : hdrs);
      _armStartTimeout();
      if (keepPos.inSeconds > 3) {
        await k.seek(keepPos);
      }
      if (reason != null) _snack(reason);
    } catch (_) {
      _snack('切换失败');
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  /// 从**直连 URL** 里取 Emby 的 `api_key`（= 访问令牌）。
  ///
  /// ## 为什么从 URL 取，而不是问 provider 要
  /// `PlaybackLaunch.url` 的注释明确写着"直连流地址（**含 api_key**）"
  /// ⇒ 数据**已经在手上**，不必：
  /// · 给 `MediaProvider` 加 getter（无谓的接口扩张，违反 §5.1 的收敛方向）
  /// · 依赖 `EmbyProvider` 具体类型（UI 层不该 import 实现文件，见 §7.13）
  ///
  /// ## 用途
  /// Emby 的 **HLS 转码分段**由服务端生成，**不会**带上 `api_key`
  /// ⇒ 分段请求无鉴权 ⇒ **400**（真机实测）。
  /// 唯一可靠的补法是把 token 放进**请求头**（mpv `http-header-fields`）。
  ///
  /// ## 容错
  /// 解析失败返回 `''`（调用方会跳过加头）——**绝不抛**
  /// （播放路径上的辅助函数不该因解析问题中断起播）。
  static String _tokenFromUrl(String url) {
    try {
      final q = Uri.parse(url).queryParameters;
      // Emby 两种命名都可能出现（`api_key` 是 URL 里的，`X-Emby-Token` 是头里的）
      return (q['api_key'] ?? q['X-Emby-Token'] ?? '').trim();
    } catch (_) {
      return '';
    }
  }

  void _snack(String message, {VoidCallback? action}) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
        action: action == null
            ? null
            : SnackBarAction(label: '切换转码', onPressed: action),
      ),
    );
  }

  /// 换集 / 自动连播（旧页 `_playEpisode` 同款流程）。
  Future<void> _playEpisode(int index) async {
    final eps = widget.episodes;
    final k = _kernel;
    if (_switching || k == null || eps == null || index < 0 || index >= eps.length) {
      return;
    }
    final api = ref.read(embyApiProvider);
    final old = _launch;
    if (api != null && old != null && _started) {
      api.reportPlaybackStop(
        itemId: old.itemId,
        playSessionId: old.playSessionId,
        mediaSourceId: old.mediaSourceId,
        positionTicks: k.state.position.inMilliseconds * 10000,
      );
      // 会话上报可能被服务端丢弃，条目进度必须单独落库
      api.reportItemProgress(
        itemId: old.itemId,
        positionTicks: k.state.position.inMilliseconds * 10000,
      );
    }
    _started = false;
    _reportTimer?.cancel();
    setState(() {
      _switching = true;
      _current = eps[index];
      _index = index;
      _resumeSeconds = 0; // 与旧页一致：换集不续播
    });
    // ★ 同步播放列表的 currentIndex（真机 bug 的根因修复，2026-10-09）
    //
    // ## 为什么必须同步
    // 本页维护 `_index`，播放列表维护 `playlistStateProvider.currentIndex`
    // —— 两者是**独立的两个状态源**，此前**互不同步**。
    // 而上下集按钮（`onNext/onPrevious`）读的是**列表的** currentIndex：
    // ```
    // onNext → pl.currentIndex + 1 → _playEpisode(...)
    // ```
    // 列表索引若停在旧值，传进来的下标就是错的 ⇒
    // 跳到错误的位置、或原地不动 = 用户说的"上下集按钮无用"。
    //
    // 现在 `_playEpisode` 是**唯一**改"当前第几集"的地方，
    // 它同时对齐两个状态源 ⇒ 单一事实源。
    //
    // ⚠️ 用 `setCurrentIndex` 而非 `select` —— 后者会触发 `onSelect`
    //    回调 → 又调 `_playEpisode` → 递归换集。
    ref.read(playlistStateProvider.notifier).setCurrentIndex(index);
    // 弹幕清空（新集的弹幕在 _loadDanmaku 里重新填充）
    ref.read(danmakuUiProvider.notifier).set(const DanmakuLoadResult());
    // 复位 UI 状态（providers 是应用级单例，换集必须清）
    ref.read(playbackStateProvider.notifier)
      ..setPosition(Duration.zero)
      ..setDuration(Duration.zero)
      ..setBuffer(Duration.zero)
      ..setBuffering(false)
      ..setCompleted(false)
      ..setError(null);
    try {
      // 换集不沿用上一集的版本选择（各集媒体源不同）
      final launch = await api!.resolvePlayback(eps[index].id);
      if (!mounted) return;
      _launch = launch;
      // ★ 换集/换片必须清掉"待处理默认轨"—— 否则
      //   会用上一集的默认轨编号去选这一集的轨道（选错）
      _pendingDefaultTracks = null;
      await k.open(launch.url, play: true, headers: launch.headers);
      _reportStart(launch);
      unawaited(_applyServerDefaultTracks(launch));
      // ★ 外挂字幕（Emby IsExternal）—— 必须在 open 之后
      //（内核看不到容器外的字幕流，只能由 App 主动加载）
      unawaited(_loadExternalSubtitles(launch));
      _fillMediaInfo(launch);
      _syncTrackLists(launch: launch, kernel: k.tracks);
      unawaited(_loadDanmaku());
    } catch (e) {
      if (!mounted) return;
      ref.read(playbackStateProvider.notifier).setError('换集失败：$e');
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  /// 播完 → 自动连播（PlaylistController 按模式取下一条目）。
  void _onCompleted() {
    if (!_autoNextEnabled) return;
    final entry = ref.read(playlistStateProvider.notifier).autoNextEntry();
    if (entry == null) return;
    final eps = widget.episodes;
    if (eps == null) return;
    final i = eps.indexWhere((e) => e.id == entry.id);
    if (i >= 0 && i != _index) unawaited(_playEpisode(i));
  }

  // ---------- 进度上报（旧页同款三段式）----------

  void _reportStart(PlaybackLaunch launch) {
    final api = ref.read(embyApiProvider);
    if (api == null || _started) return;
    _started = true;
    api.reportPlaybackStart(
      itemId: launch.itemId,
      playSessionId: launch.playSessionId,
      mediaSourceId: launch.mediaSourceId,
      positionTicks: _posTicks,
    );
    _reportTimer?.cancel();
    _reportTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      final a = ref.read(embyApiProvider);
      final l = _launch;
      final k = _kernel;
      if (a == null || l == null || k == null) return;
      a.reportPlaybackProgress(
        itemId: l.itemId,
        playSessionId: l.playSessionId,
        mediaSourceId: l.mediaSourceId,
        positionTicks: k.state.position.inMilliseconds * 10000,
        paused: !k.state.playing,
        rate: k.state.rate,
        eventName: ProgressEvent.timeUpdate,
      );
    });
    // ---- ★ Trakt 进度刷新（每 60 秒，与 Emby 的 10 秒**解耦**）----
    //
    // 理由与节流耦合关系见 `_traktTimer` 字段的注释。
    // ⚠️ 只在**播放中**发（暂停时不发 —— 暂停本身已经发过 pause，
    //    再发 start 会让 Trakt 以为用户在继续看）。
    _traktTimer?.cancel();
    _traktTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      final rep = _traktRep;
      if (rep == null || !rep.canReport) return;
      // ⚠️ 用 `playbackStateProvider`（本页唯一的"只读播放状态"入口）——
      //    不要去找 `_pstate` 之类的字段，**本页没有那个字段**
      //    （我第一版凭记忆写了 `_pstate` ⇒ 3 个编译错）。
      //    页面状态一律走 provider，见 §6.2"`_player` 是异步创建的"。
      final st = ref.read(playbackStateProvider);
      // 只在**播放中**发（暂停时已发过 pause，再发 start 会让 Trakt
      // 以为用户在继续看）
      //
      // ⚠️ 字段名是 `isPlaying`（不是 `playing`）—— 见
      //    `lib/player/domain/models/playback_state.dart:33`。
      if (!st.isPlaying) return;
      if (st.duration.inMilliseconds <= 0) return;
      // ⚠️ `_traktScrobble` 是 **void**（它内部自己 `unawaited` 上报）
      //    ⇒ 这里**不能**再包 `unawaited(...)`（会报 use_of_void_result）。
      _traktScrobble(
          playing: true, position: st.position, duration: st.duration);
    });
  }

  /// 用户交互后的即时上报（官方 Check-ins 要求，见旧页长注释）。
  void _reportEvent(String eventName) {
    final a = ref.read(embyApiProvider);
    final l = _launch;
    final k = _kernel;
    if (a == null || l == null || k == null || !_started) return;
    a.reportPlaybackProgress(
      itemId: l.itemId,
      playSessionId: l.playSessionId,
      mediaSourceId: l.mediaSourceId,
      positionTicks: k.state.position.inMilliseconds * 10000,
      paused: !k.state.playing,
      rate: k.state.rate,
      eventName: eventName,
    );
  }

  int get _posTicks =>
      ((_kernel?.state.position.inMilliseconds ?? 0)) * 10000;

  /// 退出/换集前落库（会话 Stop + 条目进度）。
  ///
  /// ⚠️ 本方法会在 `dispose()` 里被调（此时 ref 已不可用，Riverpod 明令
  /// 禁止）—— 所以 API 引用必须是缓存字段，**不能在这里 read provider**。
  void _finalize() {
    // ---- ★ 媒体会话清理（K3）----
    //
    // 不清的话，退出播放器后通知栏还挂着"正在播放某剧"，
    // 点它还会把命令发给一个**已销毁的内核** ⇒ 崩溃或无效操作。
    _sessionSync.clear();
    unawaited(SessionBridge.instance.stop());

    // K3.5：停掉系统音量监听。
    // 不停的话，退出播放器后原生仍注册着 BroadcastReceiver ——
    // 用户每次按侧边键都会唤醒 Flutter 侧回调（无谓开销），
    // 且回调里若用了已 dispose 的 ref 会抛异常。
    _volumeService.onSystemChanged = null;
    unawaited(_volumeService.stopListening());

    // K3.6：退出时**确保**清掉常亮 flag。
    // 虽然 flag 随 Activity 失效，但播放页退出后 Activity 仍在 ——
    // 不清的话首页会一直亮屏（用户会以为手机坏了）。
    unawaited(_wakelock.disable());

    if (_finalized) return;
    _finalized = true;
    final api = _api;
    final l = _launch;
    final k = _kernel;
    _reportTimer?.cancel();
    if (api == null || l == null || k == null || !_started) return;
    api.reportPlaybackStop(
      itemId: l.itemId,
      playSessionId: l.playSessionId,
      mediaSourceId: l.mediaSourceId,
      positionTicks: k.state.position.inMilliseconds * 10000,
    );
    api.reportItemProgress(
      itemId: l.itemId,
      positionTicks: k.state.position.inMilliseconds * 10000,
    );
  }

  // ---------- 轨道 / 媒体信息 / 弹幕 ----------

  /// 内核轨道 ↔ 服务端流对齐后喂给面板（TrackAligner，ff-index 精确桥）。
  void _syncTrackLists({PlaybackLaunch? launch, required KernelTracks kernel}) {
    final serverAudio = launch?.streams.where((s) => s.type == 'Audio').toList() ??
        const <MediaStream>[];
    final serverSub = launch?.streams.where((s) => s.type == 'Subtitle').toList() ??
        const <MediaStream>[];

    // ★★ 轨道诊断日志（**用户报"没识别到音频/字幕"时的唯一自查手段**）
    //
    // ## 为什么必须打（这条日志的由来）
    // 用户报障："播放吞噬星空时没识别到音频（它有 3 个音频编码）"
    //           "播放复仇者联盟时没识别出字幕（它有多个字幕）"
    // 但当时**全仓库零条轨道日志** ⇒ 无法区分是
    //   ① 服务端没给  ② 内核没上报  ③ 对齐逻辑丢了
    // ⇒ 现在把三段数据都打出来，一次就能定位在哪一段丢的。
    debugPrint('[Tracks] 服务端：音频 ${serverAudio.length} 条 / '
        '字幕 ${serverSub.length} 条'
        '（默认音 ${launch?.defaultAudioIndex} / '
        '默认字 ${launch?.defaultSubtitleIndex}）');
    for (final a in serverAudio) {
      debugPrint('[Tracks]   srv.audio idx=${a.index} '
          '«${a.displayTitle ?? a.label}» codec=${a.codec}');
    }
    for (final sb in serverSub) {
      debugPrint('[Tracks]   srv.sub   idx=${sb.index} '
          '«${sb.displayTitle ?? sb.label}» '
          'ext=${sb.isExternal} forced=${sb.isForced}');
    }
    debugPrint('[Tracks] 内核：音频 ${kernel.audio.length} 条 / '
        '字幕 ${kernel.subtitle.length} 条');
    for (final a in kernel.audio) {
      debugPrint('[Tracks]   k.audio id=${a.id} ff=${a.ffIndex} '
          '«${a.title ?? '-'}» codec=${a.codec}');
    }
    for (final sb in kernel.subtitle) {
      debugPrint('[Tracks]   k.sub   id=${sb.id} ff=${sb.ffIndex} '
          '«${sb.title ?? '-'}»');
    }

    // KernelTrack → FacadeTrack（TrackAligner 的入参类型；facade 内部同款映射）
    final kAudio = [
      for (final a in kernel.audio)
        FacadeAudioTrack(
          id: a.id,
          title: a.title,
          language: a.language,
          codec: a.codec,
          channels: a.channels,
          ffIndex: a.ffIndex,
        ),
    ];
    final kSub = [
      for (final s in kernel.subtitle)
        FacadeSubtitleTrack(
          id: s.id,
          title: s.title,
          language: s.language,
          isExternal: s.isExternal,
          isForced: s.isForced,
          ffIndex: s.ffIndex,
        ),
    ];

    final alignedAudio = TrackAligner.alignAudio(serverAudio, kAudio,
        defaultIndex: launch?.defaultAudioIndex);
    final alignedSub = TrackAligner.alignSubtitle(serverSub, kSub,
        defaultIndex: launch?.defaultSubtitleIndex);

    ref.read(audioStateProvider.notifier).setTracks([
      for (final a in alignedAudio)
        AudioTrack(
          id: a.kernelId,
          name: a.label,
          isDefault: a.isDefault,
        ),
    ]);
    // ★★ **不要在这里加「关闭字幕」**（真机实测：面板里出现了两条）
    //
    // ## 为什么删掉这一行
    // `SubtitleTrack.off`（`id: 'no'`）由**面板自己渲染**：
    // `player_settings_panel.dart` 的字幕 Tab 里有一条固定的
    // `_TrackRow(name: SubtitleTrack.off.name, ...)`。
    // 而这里 `setTracks([...])` 又插了一条 ⇒ **面板里两条"关闭字幕"**
    //（用户报障："字幕轨道的关闭字幕关闭字幕有两个"）。
    //
    // ## 职责归属（哪一层该加）
    // 「关闭字幕」不是**数据**（它不是服务端或内核上报的轨道），
    // 而是 **UI 的一个动作**（"不选任何字幕"）。
    // ⇒ 归 UI 层（面板）拥有；数据层（setTracks）只放真实轨道。
    //
    // ⚠️ 删掉后要确认「选关闭」仍然可用：面板那条 `off` 的 `onTap` 调
    //    `onSubtitleTrack(null)` ⇒ 最终传到内核 `setSubtitleTrack('no')`
    //    （`SubtitleTrack.off.id` 就是 `'no'`）⇒ 语义不变。
    ref.read(subtitleStateProvider.notifier).setTracks([
      for (final s in alignedSub)
        SubtitleTrack(
          id: s.kernelId,
          name: s.label,
          isExternal: s.isExternal,
        ),
    ]);

    // ★ 对齐结果（能一眼看出"服务端有 3 条但面板只显示 1 条"）
    debugPrint('[Tracks] 对齐后 → 面板：音频 ${alignedAudio.length} 条 / '
        '字幕 ${alignedSub.length} 条（面板会另加一条「关闭字幕」）');
    for (final a in alignedAudio) {
      debugPrint('[Tracks]   ui.audio «${a.label}» '
          'id=${a.kernelId} 精确=${a.matchedByIndex}');
    }
    for (final sb in alignedSub) {
      debugPrint('[Tracks]   ui.sub   «${sb.label}» '
          'id=${sb.kernelId} 精确=${sb.matchedByIndex}');
    }
  }

  /// 服务端指定的默认轨（旧页同款：等内核轨道到达后按 isDefault 应用）。
  /// 应用默认轨（音轨用服务端的；字幕**服务端没给就自动选中文**）。
  ///
  /// ## ★ 2026-10-10 修"字幕没有显示在画面中"（用户报障）
  ///
  /// ### 原来的两个问题
  /// **① 早退**：方法开头 `if (wantAudio == null && wantSub == null) return;`
  /// 《复仇者联盟》有 6 音轨（`wantAudio=1`，不为 null）故没早退；
  /// 但若某片**只有字幕没有默认音频**，字幕逻辑就完全不会执行。
  ///
  /// **② 服务端 `DefaultSubtitleStreamIndex = null` 时直接跳过**
  /// ```
  /// // 服务端未指定字幕 → 不主动关（尊重内核/用户习惯，旧页同款）
  /// if (wantSub != null) { ... }
  /// ```
  /// 而这部片的默认字幕**就是 null** ⇒ **mpv 不选任何字幕**
  /// ⇒ 画面里没有任何字幕（用户报障）。
  ///
  /// 真机 mpv 日志（8 条字幕，**没有一条带 `(*)` 选中标记**）：
  /// ```
  /// Subs --sid=5 --slang=chi '简体中字' (hdmv_pgs_subtitle)
  /// ```
  ///
  /// ### 修法
  /// 服务端没给默认字幕 ⇒ 按 `autoPickSubtitle` 选一条（**中文优先**）。
  /// 用户仍可在设置面板里改或关（`关闭字幕` 是第一项）。
  Future<void> _applyServerDefaultTracks(PlaybackLaunch launch) async {
    final k = _kernel;
    if (k == null) return;
    // ⚠️ 只对**当前**这次起播生效 —— 换集后旧 launch 已失效，
    //    用它去选这一集的轨道会选错（编号空间不同）。
    if (!identical(launch, _launch)) {
      debugPrint('[PlayerFlow] 默认轨：launch 已过期（换集了），跳过');
      return;
    }
    final wantAudio = launch.defaultAudioIndex;
    final wantSub = launch.defaultSubtitleIndex;
    // ⚠️ 不能在这里早退 —— 字幕需要"服务端没给也要自动选"的分支。

    // ★★ 等内核上报轨道（最多 6s，每 150ms 探一次）
    //
    // ## 为什么从 3s 延长到 6s（真机实测的时序问题）
    // 实测《复仇者联盟》两个现象**互相矛盾**：
    // · `[Tracks] 内核：音频 6 条 / 字幕 8 条` ← 对齐器拿到了
    // · `[PlayerFlow] 音轨：0 条全部编码不可解` ← 这里却是 0 条
    // ⇒ 本方法**跑得比内核首次上报更早**，那次探测看到空列表就继续往下走，
    //   于是 `aligned` 为空 ⇒ 选轨逻辑全部空转。
    //
    // ## 为什么要"轮询到真有轨道"而不是单次 sleep
    // 首次上报的耗时取决于：demuxer 分析 + 网络（4K 片源实测 3–5s）。
    // 固定 sleep 要么太长（拖慢起播）要么太短（拿到空）。
    // ⇒ 轮询：一旦有轨道**立即**继续（正常片源 200ms 内就走了）。
    //
    // ## 拿到空列表后的兜底（关键：不能再"空转"）
    // 超时仍为空 ⇒ **交给 `tracksStream` 的回调再试一次**
    //（见 `_wireKernel` 里的 `_pendingDefaultTracks`）。
    // 否则一旦这里错过，就**永远**不会选轨 —— 这正是"没声音/没字幕"的成因。
    var tracksReady = false;
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (!mounted) return;
      // ⚠️ 每次都读 `k.tracks`（内核的**当前**值），不是捕获的快照
      if (k.tracks.audio.isNotEmpty || k.tracks.subtitle.isNotEmpty) {
        tracksReady = true;
        break;
      }
    }
    if (!mounted) return;
    if (!tracksReady) {
      // 还没上报 ⇒ 挂起，等 `tracksStream` 第一次非空时再执行
      debugPrint('[PlayerFlow] 轨道未及时上报（等待超时）⇒ '
          '挂起默认轨选择，待 tracksStream 到达后重试');
      _pendingDefaultTracks = launch;
      return;
    }

    try {
      if (launch.streams.any((s) => s.type == 'Audio') ||
          k.tracks.audio.isNotEmpty) {
        final server = launch.streams.where((s) => s.type == 'Audio').toList();
        final aligned = TrackAligner.alignAudio(
            server, _facadeAudio(k.tracks.audio),
            defaultIndex: wantAudio);
        // ★★ 必须**过滤掉内核解不了的编码**（真机实测的"没声音"根因）
        //
        // ## 事故复盘（《复仇者联盟》）
        // 服务端 `DefaultAudioStreamIndex=1` = **English TRUEHD 7.1**，
        // 而 mpv 在 Android 上解不了 TRUEHD：
        // ```
        // [mpv/ad] Failed to initialize a decoder for codec 'truehd'.
        // [mpv/cplayer] Audio: no audio          ← 播放无声
        // ```
        // ⇒ "忠实选服务端默认轨" = 选了一条**播不出来的轨**。
        //
        // ## 为什么以前反而有声（关键）
        // 修好 `parseTracks` 之前轨道列表恒为空 ⇒ 本方法**从不执行**
        // ⇒ mpv 用自己的策略（自动跳过 truehd）⇒ 恰好有声。
        // **修好解析后忠实选轨，才暴露了这个真问题。**
        //
        // ## 修法
        // 服务端默认轨**编码可解**才用它；不可解则退到**同语言可解轨**
        // （保住"用户想听国语/英语"的意图），再退到任意可解轨。
        final want = wantAudio != null
            ? aligned.where((a) => a.isDefault).firstOrNull
            : null;
        // ★ 按**当前内核**判定可播性（真机实测：两内核能力不同）
        //
        // ## 为什么必须传（《复仇者联盟》真机取证）
        // Media3 内核下 truehd 音轨：
        // ```
        // CF-Media3: 播放错误: ERROR_CODE_DECODER_INIT_FAILED
        //            MediaCodecAudioRenderer error, format=(国语, truehd)
        // ```
        // 而 mpv 内核下同一编码是 `Failed to initialize a decoder`。
        // ⇒ 两个内核都解不了 truehd（**Android 平台能力**），但
        //   dtshd 之类只有 mpv 缺、Media3 可能能放 ⇒ 表必须区分。
        final isMpv = k is NativeKernel;
        final pick = TrackAligner.pickPlayableAudio(
          aligned,
          preferred: want,
          codecOf: (t) => t.codec,
          kernelMpv: isMpv,
        );
        if (pick != null) {
          await k.setAudioTrack(pick.kernelId);
          // ⚠️ await 后必须判 mounted（否则 ref 抛 Bad state，真机实证）
          if (!mounted) return;
          ref.read(audioStateProvider.notifier).selectTrack(pick.kernelId);
          if (want != null && pick.kernelId != want.kernelId) {
            debugPrint('[PlayerFlow] 音轨：服务端默认«${want.label}»编码'
                '${want.codec} 在内核上不可解 ⇒ 自动退到«${pick.label}»');
          } else {
            debugPrint('[PlayerFlow] 音轨：选中«${pick.label}»'
                '（codec=${pick.codec}）');
          }
        } else {
          // 全部不可解 ⇒ **不设 aid**，让 mpv 自己挑（它至少会试）
          debugPrint('[PlayerFlow] 音轨：${aligned.length} 条全部编码不可解 '
              '⇒ 不指定 aid，交给 mpv 自行选择');
        }
      }

      // ---- 字幕：服务端指定优先，没指定则**自动选中文** ----
      final serverSub =
          launch.streams.where((s) => s.type == 'Subtitle').toList();
      if (k.tracks.subtitle.isNotEmpty) {
        final aligned = TrackAligner.alignSubtitle(
            serverSub, _facadeSub(k.tracks.subtitle),
            defaultIndex: wantSub);
        // ★★ 服务端指定**也要校验可播性**（真机二次报障的根因）
        //
        // ## 事故复盘
        // 修好"服务端没默认就自动选中文"之后，用户仍报
        // "字幕没有在播放画面中"。真机取证：
        // ```
        // srv.sub idx=2 «Chinese Simplified (默认 PGSSUB)»
        // [PlayerFlow] 字幕：自动选中«简体中文» id=1     ← 选中了 PGS
        // [mpv/sub] Could not find subtitle decoder for format 'hdmv_pgs_subtitle'.
        // ```
        // ⇒ **选中了但永远不显示**（UI 显示已勾选 ⇒ 比"没选中"更难查）
        //
        // ## 规则
        // · 服务端指定且**可播** → 用它（尊重服务端）
        // · 服务端指定但**不可播** → 退到可播轨；全不可播则不选
        // · 服务端未指定 → `autoPickSubtitle`（内部已按"先可播再中文"排序）
        final wantTrack = wantSub != null
            ? aligned.where((a) => a.isDefault).firstOrNull
            : null;
        final wantPlayable = wantTrack != null &&
            TrackAligner.isSubtitleCodecLikelyPlayable(
                wantTrack.codec ?? _serverCodecFor(serverSub, wantTrack));
        final pick = wantPlayable
            ? wantTrack
            : TrackAligner.autoPickSubtitle(aligned,
                codecOf: (t) => t.codec ?? _serverCodecFor(serverSub, t));
        if (pick != null) {
          await k.setSubtitleTrack(pick.kernelId);
          // ⚠️ await 后必须判 mounted（同 `_applyServerDefaultTracks` 的音轨分支）
          if (!mounted) return;
          ref.read(subtitleStateProvider.notifier).selectTrack(pick.kernelId);
          if (wantTrack != null && pick.kernelId != wantTrack.kernelId) {
            debugPrint('[PlayerFlow] 字幕：服务端默认«${wantTrack.label}»'
                '编码 ${wantTrack.codec ?? "?"} 当前内核不支持 '
                '⇒ 自动退到«${pick.label}»');
          } else {
            debugPrint('[PlayerFlow] 字幕：'
                '${wantSub != null ? "服务端指定" : "自动选中"}'
                '«${pick.label}» id=${pick.kernelId}');
          }
        } else {
          // ★ 全部不可播 ⇒ **明确告诉用户**（而不是静默"勾了不显示"）
          final codecs = aligned
              .map((a) => a.codec ?? '?')
              .toSet()
              .join('/');
          final msg = '该片源的字幕格式（$codecs）当前播放内核无法解码'
              '（缺 PGS 解码器），无法显示字幕。请换带 SRT/ASS 字幕的片源。';
          debugPrint('[PlayerFlow] 字幕：${aligned.length} 条全部不可播（$codecs）'
              '⇒ 不选任何字幕，并提示用户');
          // 走已有的可见通路提示用户（复用 `_surfaceMessage`）
          unawaited(_surfaceMessage(msg));
        }
      } else if (serverSub.isNotEmpty) {
        // 服务端有字幕但内核没上报 ⇒ 说明是**外挂**（不在容器里），
        // 由 `_loadExternalSubtitles` 负责加载。
        debugPrint('[PlayerFlow] 字幕：服务端 ${serverSub.length} 条但内核未上报 '
            '⇒ 应为外挂字幕，交给 _loadExternalSubtitles');
      }
    } catch (e) {
      debugPrint('[PlayerFlow] 应用服务端默认轨失败（非致命）: $e');
    }
  }

  /// 是否已做过一次"音频解码失败 → 自动换轨"（**防止无限循环**）。
  ///
  /// ⚠️ 必须限制次数：若该片**所有**音轨都不可播，
  /// 不限次会导致"切轨→失败→再切轨"死循环（用户看到画面不断重载）。
  bool _autoRecoveredAudio = false;

  /// ★ 当前要显示的字幕 cue（Media3 内核专用，见 `cuesStream` 说明）。
  ///
  /// ## 为什么用 setState 而不是 provider
  /// cue 的更新频率**很高**（PGS 常每几百毫秒一帧），而它只影响
  /// **画面上的这一层**。走全局 provider 会让整页重建（控制层/面板
  /// 全部重算）—— 与弹幕层"用 ValueNotifier 局部刷新"是同一考虑。
  /// ⚠️ 但也不能每帧 setState 到整页：下面做了**内容比对**，
  ///    只有 cue 真的变了才 setState（PGS 连续帧常完全相同）。
  List<SubtitleCue> _cues = const [];

  /// cue 的轻量指纹（避免"相同内容重复 setState"）。
  int _cuesFingerprint = 0;

  static int _fingerprintOf(List<SubtitleCue> cues) {
    var h = cues.length;
    for (final c in cues) {
      h = h * 31 + (c.text?.length ?? 0);
      h = h * 31 + (c.pngBytes?.length ?? 0);
    }
    return h;
  }

  /// 这条错误是否像"**音频解码器起不来**"。
  ///
  /// ## 判据来自两个内核的**真实报错原文**
  /// | 内核 | 真机原文 |
  /// |---|---|
  /// | Media3 | `ERROR_CODE_DECODER_INIT_FAILED` + `MediaCodecAudioRenderer error` |
  /// | mpv | `Failed to initialize a decoder for codec '<x>'` |
  ///
  /// ⚠️ 用 `||` 而非"必须都匹配"：两个内核文案完全不同。
  bool _looksLikeAudioDecoderFailure(String e) {
    final s = e.toUpperCase();
    if (s.contains('ERROR_CODE_DECODER_INIT_FAILED') &&
        s.contains('AUDIORENDERER')) {
      return true;
    }
    if (e.contains('Failed to initialize a decoder')) return true;
    return false;
  }

  /// **音频解码失败后自动退到一条可播音轨**。
  ///
  /// ## 为什么不只是"报错给用户看"
  /// 实测：Media3 的 `AudioRenderer` 初始化失败会让**整个播放停住**
  ///（不是静音继续）。而该片 6 条音轨里有 4 条可播
  ///（DTS `dca` / AC3）⇒ 换一条就正常了。
  /// 用户不该自己猜到这件事。
  ///
  /// ## 语言意图要保留
  /// 失败那条若是"国语"，优先在同一语言里找可播轨
  ///（`pickPlayableAudio` 已实现该策略）。
  Future<void> _recoverAudioTrack(String err) async {
    final k = _kernel;
    final launch = _launch;
    if (k == null || launch == null) return;
    try {
      final serverAudio =
          launch.streams.where((s) => s.type == 'Audio').toList();
      final aligned = TrackAligner.alignAudio(
              serverAudio, _facadeAudio(k.tracks.audio))
          .where((a) => !a.isExternal)
          .toList();
      if (aligned.isEmpty) return;
      // 当前选中的那条（把它排除，避免又选回同一个）
      final cur = ref.read(audioStateProvider).activeTrackId;
      final pick = TrackAligner.pickPlayableAudio(
        aligned.where((a) => a.kernelId != cur).toList(),
        codecOf: (t) => t.codec ?? _serverCodecFor(serverAudio, t),
        kernelMpv: k is NativeKernel,
      );
      if (pick == null) {
        debugPrint('[PlayerFlow] 音频解码失败且**没有可播的替代音轨** ⇒ '
            '保持报错（$err）');
        return;
      }
      await k.setAudioTrack(pick.kernelId);
      // ⚠️ `await setAudioTrack` 之后要判 mounted 才能碰 `ref`
      //（该 await 可能跨越用户退出播放页的时刻 —— 真机 logcat 有实证）
      if (!mounted) return;
      ref.read(audioStateProvider.notifier).selectTrack(pick.kernelId);
      final msg = '该音轨编码当前内核解不了，已自动切到«${pick.label}»';
      debugPrint('[PlayerFlow] $msg');
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
      );
    } catch (ex) {
      debugPrint('[PlayerFlow] 自动恢复音轨失败（非致命）: $ex');
    }
  }

  /// 从服务端流里取该对齐轨对应的 `codec`（`AlignedTrack.serverIndex` 反查）。
  ///
  /// ## 为什么需要这个反查
  /// `AlignedTrack.codec` 已由 `serverCodecAt` 填充，理论上直接可用；
  /// 但**旧的对齐结果**（或走了启发式匹配的轨）可能没填
  /// ⇒ 这里按 `serverIndex` 再查一次作为兜底，避免"codec 为 null
  /// ⇒ 判为可播 ⇒ 又选到 PGS"。
  String? _serverCodecFor(List<MediaStream> server, AlignedTrack t) {
    final idx = t.serverIndex;
    if (idx == null) return null;
    for (final s in server) {
      if (s.index == idx) return s.codec;
    }
    return null;
  }

  /// 把一条消息送到用户可见处（复用内核错误流 → 已有 SnackBar 通路）。
  ///
  /// ⚠️ 不能直接 `showSnackBar` —— 本方法可能在内核回调里被调，
  /// 那时 widget 树状态不确定；走 `playbackStateProvider.setError`
  /// 是既有的、已验证的可见通路。
  Future<void> _surfaceMessage(String msg) async {
    if (!mounted) return;
    ref.read(playbackStateProvider.notifier).setError(msg);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  /// **加载服务端的外挂字幕**（Emby `IsExternal=true`）。
  ///
  /// ## 为什么必须有这一步（自查 Emby API 时发现的缺口）
  /// Emby 的外挂字幕是**媒体库里的独立文件**（或用户上传的），
  /// **不在视频容器里** ⇒ 播放内核打开视频时，它的 `track-list`
  /// **根本看不到这些轨道**（mpv 只列容器内的流；Media3 同理）。
  ///
  /// ⇒ 必须由 App 主动把 `DeliveryUrl` 交给内核加载。
  ///
  /// ## 与"内嵌字幕丢失"的区别（用户报障的两个不同原因）
  /// · **内嵌**（`IsExternal=false`）丢失 = `parseTracks` 的解析 bug
  ///   （已修：整个列表包一个 try ⇒ 任一条坏轨就让全部变空）
  /// · **外挂**（`IsExternal=true`）看不到 = **缺这条加载逻辑**（本方法）
  ///
  /// ## 时机
  /// 在 `open` **之后**（内核已就绪）调用。mpv 的 `sub-add` 可随时加；
  /// Media3 会重建 `MediaItem`（有短暂中断，见其实现注释）。
  Future<void> _loadExternalSubtitles(PlaybackLaunch launch) async {
    final k = _kernel;
    if (k == null) return;
    if (!k.supports(EngineFeature.externalSubtitle)) {
      debugPrint('[PlayerFlow] 当前内核不支持外挂字幕，跳过');
      return;
    }
    final ext = launch.streams
        .where((s) =>
            s.type == 'Subtitle' &&
            s.isExternal &&
            (s.deliveryUrl?.isNotEmpty ?? false))
        .toList();
    if (ext.isEmpty) {
      debugPrint('[PlayerFlow] 无外挂字幕（内嵌字幕由内核直接上报）');
      return;
    }
    // 服务端指定的默认字幕若是外挂的 → 加载时直接选中
    final wantSub = launch.defaultSubtitleIndex;
    var okCount = 0;
    for (final s in ext) {
      final isDefault = wantSub != null && s.index == wantSub;
      final ok = await k.addExternalSubtitle(
        url: s.deliveryUrl!,
        title: s.displayTitle ?? s.label,
        language: s.language,
        select: isDefault,
      );
      if (ok) okCount++;
    }
    debugPrint('[PlayerFlow] 外挂字幕：加载 $okCount/${ext.length} 条'
        '（默认字 ${wantSub ?? '无'}）— url 含凭据故不打印');
    // 加载后内核会重发 track-list ⇒ `_syncTrackLists` 自动把它们并入面板
  }

  List<FacadeAudioTrack> _facadeAudio(List<KernelTrack> list) => [
        for (final a in list)
          FacadeAudioTrack(
            id: a.id,
            title: a.title,
            language: a.language,
            codec: a.codec,
            channels: a.channels,
            ffIndex: a.ffIndex,
          ),
      ];

  List<FacadeSubtitleTrack> _facadeSub(List<KernelTrack> list) => [
        for (final s in list)
          FacadeSubtitleTrack(
            id: s.id,
            title: s.title,
            language: s.language,
            isExternal: s.isExternal,
            isForced: s.isForced,
            ffIndex: s.ffIndex,
          ),
      ];

  /// 信息 Tab：MediaSource.MediaStreams → MediaInfo。
  ///
  /// 只填服务端实际给出的字段（MediaStream 没有 frameRate/bitrate/
  /// sampleRate，这些留空 —— 内核侧的对应属性属于后续增强）。
  void _fillMediaInfo(PlaybackLaunch launch) {
    final video = launch.streams.where((s) => s.type == 'Video').toList();
    final audio = launch.streams.where((s) => s.type == 'Audio').toList();
    final v = video.isEmpty ? null : video.first;
    final a = audio.isEmpty ? null : audio.first;
    ref.read(mediaInfoProvider.notifier).set(MediaInfo(
          fileName: _current.name,
          duration: _current.runtimeTicks == null
              ? null
              : Duration(milliseconds: _current.runtimeTicks! ~/ 10000),
          width: v?.width,
          height: v?.height,
          videoCodec: v?.codec,
          hdrFormat: v?.videoRange,
          audioCodec: a?.codec,
          audioChannels: a?.channels,
          container: launch.container,
          // 内核 + 决策理由：让"为什么用这个内核"可见（可解释性）。
          // 用户排查"播不了"时这两行最该先看 —— 两个内核能力不同，
          // 换一个往往就能播。
          kernelLabel: _decision?.kernel.label,
          kernelReason: _decision?.reason,
        ));
  }

  Future<void> _loadDanmaku() async {
    // ★★ 必须**等配置加载完**（真机抓到的静默失败）
    //
    // ## 原来的写法错在哪
    // ```dart
    // final cfg = ref.read(danmakuConfigProvider).value;
    // if (cfg == null || cfg.kind == off) return;   // ← 静默 return
    // ```
    // `danmakuConfigProvider` 是 **AsyncNotifier**（要去
    // `flutter_secure_storage` 解密读配置）。而本方法在 `initState`
    // 里被直接调用（`unawaited(_loadDanmaku())`）——
    // **此刻 `.value` 必为 null**（首次加载还没完成）⇒ 直接 return。
    //
    // 后果：**弹幕永远不加载**，且**一行日志都没有**
    //（真机实测：logcat 里零条弹幕日志、也没对公共代理发过请求）。
    // 这是本仓库反复记录的最难查形态 —— 不报错、不崩溃、就是没有。
    //
    // ## 修法：用 `.future` 等它，而不是读 `.value`
    final cfg = await ref.read(danmakuConfigProvider.future);
    if (!mounted) return;
    if (cfg.kind == DanmakuProviderKind.off) {
      debugPrint('[PlayerFlow] 弹幕已关闭（kind=off），跳过加载');
      return;
    }
    if (!cfg.isUsable) {
      // 配了但缺必填项（如官方源没填凭据）⇒ **要说出来**，
      // 否则用户只会看到"没有弹幕"，以为片源没有
      debugPrint('[PlayerFlow] 弹幕配置不完整（kind=${cfg.kind.name}），跳过');
      return;
    }
    try {
      // ⚠️ `await` 之后必须重新判 `mounted`：
      //   网络（弹幕接口）可能几百 ms~数秒才回，期间用户可能已退出播放页
      //   ⇒ 直接用 ref 会抛 `Bad state: Using "ref" when a widget is
      //     about to or has been disposed`（真机 logcat 实证的 Unhandled Exception）
      if (!mounted) return;
      final result = await ref.read(danmakuForItemProvider(_current).future);
      if (!mounted) return;
      if (!mounted) return;
      if (result.error != null) {
        // 弹幕错误不阻断播放（旧页同款"尽力而为"），记录到 UI 供面板展示
        debugPrint('[PlayerFlow] 弹幕：${result.error}');
      } else {
        debugPrint('[PlayerFlow] 弹幕：拉到 ${result.items.length} 条'
            '（匹配到「${result.matchedTitle ?? '?'}」，'
            'episodeId=${result.episodeId ?? '无'}）');
      }
      if (!mounted) return;
      ref.read(danmakuUiProvider.notifier).set(result);
    } catch (e) {
      debugPrint('[PlayerFlow] 弹幕加载失败（非致命）: $e');
    }
  }

  // ---------- 导入本地弹幕文件 ----------

  /// 让用户选一个弹幕文件并加载（**真功能**，用户要求"接真功能"）。
  ///
  /// ## 支持格式（自动判定，不只看扩展名）
  /// `.xml`（B站）/ `.json`（弹弹play）/ `.ass`（尽力而为）
  /// —— 解析在 `parseDanmakuFile`（纯函数，有单测）。
  ///
  /// ## 加载后的行为
  /// **替换**当前弹幕（而不是追加）—— 用户导入本地文件通常是想
  /// "用这个文件而不是自动匹配的"，追加会混在一起反而更乱。
  ///
  /// ## 失败处理（不静默）
  /// 解析失败 / 没选中文件 / 读取异常 ⇒ 都给明确的 SnackBar 文案。
  /// 解析成功但有跳过的行 ⇒ 也如实告知条数（不假装"全部成功"）。
  Future<void> _importLocalDanmaku() async {
    DanmakuImportResult res;
    try {
      // ⚠️ **file_picker 13.x 是静态 API**（不是 5.x 的 `FilePicker.platform`）
      //   实测：`FilePicker.pickFile(...)` 直接返回 `PlatformFile?`，
      //   且没有 `withData` 参数 —— 字节要走 `readAsBytes()`（异步读）。
      //   故**不再需要**"withData 会占内存"的顾虑（读的时候才分配）。
      final f = await FilePicker.pickFile(
        dialogTitle: '选择弹幕文件',
        type: FileType.any,
      );
      if (f == null) {
        // 用户主动取消 ⇒ **不提示**（提示会显得像出错）
        debugPrint('[PlayerFlow] 导入弹幕：用户取消');
        return;
      }
      final bytes = await f.readAsBytes();
      if (bytes.isEmpty) {
        _snack('文件是空的：${f.name}');
        return;
      }
      // 10MB 上限：弹幕文本文件通常几百 KB，超过说明选错了文件
      // （放到**读之后**判断：`PlatformFile.size` 在某些平台可能不准）
      if (bytes.length > 10 * 1024 * 1024) {
        _snack('文件过大（${(bytes.length / 1048576).toStringAsFixed(1)}MB），'
            '弹幕文件通常 < 1MB');
        return;
      }
      // 优先 UTF-8；失败再试 latin1（B站老导出文件常是 GBK，
      // 没有内置 GBK 解码器，latin1 至少不抛异常、能保留字节不崩）
      String content;
      try {
        content = utf8.decode(bytes);
      } catch (_) {
        content = latin1.decode(bytes, allowInvalid: true);
        debugPrint('[PlayerFlow] 导入弹幕：非 UTF-8，按 latin1 容错解码');
      }
      res = parseDanmakuFile(content, fileName: f.name);
    } catch (e, st) {
      _snack('选择文件失败：$e');
      debugPrint('[PlayerFlow] 导入弹幕异常：$e\n$st');
      return;
    }

    if (!mounted) return;

    if (!res.ok) {
      _snack('导入失败：${res.error}');
      debugPrint('[PlayerFlow] 导入弹幕失败：${res.error}');
      return;
    }

    // ★ 替换当前弹幕（见方法头说明）
    ref.read(danmakuUiProvider.notifier).set(DanmakuLoadResult(
          items: res.items,
          // 顶部信息显示文件名 —— 用户能一眼确认"用的是哪个文件"
          matchedTitle: res.fileName,
          fromCache: false,
        ));
    final extra = res.skipped > 0 ? '，跳过 ${res.skipped} 行' : '';
    _snack('已导入 ${res.items.length} 条弹幕'
        '（${res.format}：${res.fileName}）$extra');
    debugPrint('[PlayerFlow] 导入弹幕成功：${res.format} '
        '${res.fileName} ${res.items.length} 条，跳过 ${res.skipped} 行');
  }

  // ---------- 手动匹配弹幕 ----------

  /// 打开手动匹配面板，选中后**立即替换当前弹幕**。
  ///
  /// ## 为什么必须有（外部成熟项目一致结论 + 本项目实测印证）
  /// 自动匹配必然猜错的两类情况（dd-danmaku / RyoLee 的 README 都列了）：
  /// 1. **译名不同**：Emby《彻夜之歌》vs 弹弹play《夜曲》
  /// 2. **多季/OVA 归档**：`OVERLORD/S4E1.mkv` 这类结构
  ///
  /// 本项目**实测印证**：
  /// · 搜「斗罗大陆」→ **8 个候选**（第二季 / 昊天扬威 / 铅华洗净…）
  /// · 搜「我推的孩子」→ **3 个候选**（第一/二/三季）
  /// ⇒ 自动取第一个必然在多数情况下**选错季**，而用户原先毫无办法。
  ///
  /// ## 为什么走"用户选 → 直接生效"（不回设置页）
  /// 用户是在**看片时**发现"匹配错了"才来点的 ——
  /// 任何"请去设置页重新配置"都会中断观看。
  ///
  /// ## 预填关键词从哪来
  /// 用**当前条目解析出的番剧名**（`parseDanmakuQuery`）——
  /// 与自动匹配**同一个关键词**，用户只需微调，不用从零输入。
  Future<void> _openMatchSheet() async {
    final q = parseDanmakuQuery(
      name: _current.name,
      seriesName: _current.seriesName,
      indexNumber: _current.indexNumber,
      parentIndexNumber: _current.parentIndexNumber,
      itemType: _current.type,
    );
    if (!mounted) return;

    final picked = await showModalBottomSheet<DanmakuManualMatch>(
      context: context,
      backgroundColor: Cf.surface,
      isScrollControlled: true,
      // 高度留白：集列表可能很长（实测有 176 集的番剧）
      constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.75),
      builder: (_) => DanmakuMatchSheet(initialKeyword: q.anime),
    );
    if (picked == null || !mounted) return;

    await _loadDanmakuWithEpisode(picked);
  }

  /// 用手动指定的 episodeId 拉弹幕并**替换**当前显示。
  ///
  /// ## 为什么不复用 `danmakuForItemProvider`
  /// 那个 provider 是 `family(item)` —— 它内部**自己算关键词再搜**，
  /// 拿不到用户指定的 episodeId。故这里直接走 client（唯一出口）。
  Future<void> _loadDanmakuWithEpisode(DanmakuManualMatch m) async {
    final client = ref.read(danmakuClientProvider);
    if (client == null) {
      _snack('弹幕源不可用（请先在设置里选择弹幕源）');
      return;
    }
    try {
      final batch = await client.comments(m.episodeId);
      if (!mounted) return;
      ref.read(danmakuUiProvider.notifier).set(DanmakuLoadResult(
            items: batch.items,
            matchedTitle: m.animeTitle,
            episodeId: m.episodeId,
            fromCache: false,
          ));
      _snack('已手动匹配：${m.display}（${batch.items.length} 条）');
      debugPrint('[PlayerFlow] 手动匹配成功：${m.display} '
          'episodeId=${m.episodeId} 共 ${batch.items.length} 条');
    } on DanmakuException catch (e) {
      if (mounted) _snack('该集弹幕加载失败：${e.message}');
    } catch (e) {
      if (mounted) _snack('该集弹幕加载失败：$e');
    }
  }

  // ---------- 退出 ----------

  /// 会话状态同步器（K3：把状态推给通知栏，见 session_bridge.dart）。
  ///
  /// ## 为什么用独立对象而不是直接在页面里调 channel
  /// "什么时候推状态"容易漏（改一处忘一处）—— 本项目多次踩过
  /// "配了没接线"的坑。抽成 `SessionStateSync` 后**一个地方**决定推什么，
  /// 且能被单测覆盖（见 test/player_session_sync_test.dart）。
  final SessionStateSync _sessionSync = SessionStateSync();

  /// 系统媒体音量服务（K3.5：音量的**唯一事实源**）。
  ///
  /// ## 为什么音量统一走它，而不是内核
  /// 旧实现手势改**内核音量** ⇒ 两个后果：
  /// · 按手机侧边键时，App 的滑块**不动**（用户以为坏了）
  /// · 系统音量 × 内核音量 = **双重衰减**（系统 50% × 内核 50% = 实际 25%）
  ///
  /// 参考实现（mpv-android `MPVActivity.kt:2102`、Next Player
  /// `VolumeState.kt:169`）都把手势落到系统音量。本项目 2026-10-09 对齐。
  ///
  /// ⚠️ **唯一例外**：音频焦点 `duck` 仍走内核（见 `case 'duck'` 的说明）——
  /// 改系统音量会把用户手机的音量改小且**不会自动恢复**。
  final VolumeService _volumeService = VolumeService();

  /// 唤醒锁：**播放中保持屏幕常亮**。
  ///
  /// ## 为什么必须接线（曾被遗漏）
  /// Kotlin 侧早已实现该通道，但 Dart 侧**零调用** ⇒ 播放中屏幕照常熄灭。
  /// 看剧时每隔几十秒黑屏是很明显的体验问题。
  ///
  /// ## 语义：跟随"是否在播"，不是"是否在播放页"
  /// 暂停时**允许熄屏**（用户可能在回消息/看弹幕）；
  /// 恢复播放时再点亮。故挂在 `stateStream` 的 `playing` 变化上，
  /// 而不是在 `initState`/`dispose` 里一刀切。
  final WakelockService _wakelock = WakelockService();

  /// 闪避前的**内核**音量（`duck` 时记下，`unduck` 时精确还原）。
  ///
  /// ⚠️ 记的是**内核**音量（K3.5 起恒定 unity），**不是**系统音量 ——
  /// 用户音量现在由系统通道负责，与这里无关。见 `case 'duck'` 的说明。
  double? _volumeBeforeDuck;

  /// 本次暂停是否**因失焦造成**（音频焦点路径设置）。
  ///
  /// ## 为什么必须区分
  /// 来电结束（焦点恢复）时，只有"因失焦暂停"才该自动续播。
  /// 若用户是**自己**按的暂停，被来电结束触发开播会很突兀
  /// —— 这是 Android 的推荐行为，也是主流播放器的做法。
  bool _pausedByFocusLoss = false;

  // ---- ★ Trakt 实时追踪（用户开关「实时追踪」，2026-10-14）----
  //
  // ## 为什么延迟创建（不是 initState 里建）
  // 需要 **trakt 的 episode id**，而它要两步解析
  //（seriesId → tmdb → trakt episode）。契约明确集级只认 trakt/tvdb。
  // ⇒ 解析完成前 `_traktRep` 为 null，上报被静默跳过（**不影响播放**）。
  TraktPlaybackReporter? _traktRep;

  /// 上次上报的进度（0–100）。`dispose` 时内核可能已不可用 ⇒ 用最后已知值。
  double _lastTraktPct = 0;

  /// **续播检查结果**（Trakt 上的进度 vs 本地）。
  ///
  /// ## 生命周期
  /// · `_prepareTraktReporter` 里异步查一次（只查**当前这一集**）
  /// · `_startEpisode` 读它：`shouldPrompt == true` ⇒ **不自动 seek**，
  ///   改为弹提示让用户选（**不静默覆盖本地进度**，理由见
  ///   `lib/data/trakt_resume.dart` 的文件头）
  /// · 用户点过"继续/从头"后置 null（避免连播时重复弹）
  TraktResumeHint? _traktResumeHint;

  /// **Trakt 进度刷新定时器**（播放中每 60 秒重发一次 `start`）。
  ///
  /// ## 为什么必须有它（真机实测的缺口）
  /// 原来只在"播放态变化"时上报 ⇒ 播 2 小时 Trakt 只收到起播那一次
  /// ⇒ Trakt 上的进度**永远停在起播点** ⇒ 「续播检查」拿到错误进度。
  ///
  /// ## 为什么 60 秒（不是照抄 Emby 的 10 秒）
  /// · Trakt 的 scrobble 是**事件语义**（start/pause/stop），不是心跳
  /// · 官方文档明确 `start` = "video initially starts playing **or is
  ///   unpaused**" ⇒ 播放中重发 `start` 是**契约允许**的进度刷新方式
  /// · 续播检查阈值是 5%（≈2 分钟）⇒ 60 秒的精度**绰绰有余**
  /// · Trakt 有限流（每 5 分钟 1000 次）⇒ 60 秒 = 每小时 60 次，安全
  ///
  /// ## ⚠️ 与 `TraktPlaybackReporter.minInterval` 的耦合
  /// 那个节流会**跳过"同一 action 在 minInterval 内"** 的调用。
  /// 本定时器 60 秒 > 默认 minInterval 10 秒 ⇒ 不会被拦。
  /// **若将来把 minInterval 调大到 >60 秒，这个刷新会被静默丢弃**
  ///（症状：进度又停在起播点）⇒ 改那个值时必须回来检查这里。
  Timer? _traktTimer;

  /// 已就"这一集"问过用户（防连播时同一集弹两次）。
  String? _traktAskedFor;

  /// 是否允许真正 pop（见 `_finalizeAndExit` 的说明）。
  ///
  /// `PopScope.canPop` 绑定它：平时 false（拦系统返回，走我们的清理），
  /// 清理完成后置 true 再 pop —— **否则会无限递归**。
  bool _allowPop = false;

  void _finalizeAndExit() {
    _finalize();
    // provider 清理必须在 unmount 前做（dispose 里 ref 不可用）
    ref.read(playlistStateProvider.notifier).onSelect = null;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    unawaited(ScreenBrightness().resetApplicationScreenBrightness());

    // ★ 必须先解除 PopScope 的拦截，否则 pop 会被再次拒绝 ——
    //   而 `onPopInvokedWithResult` 又会调回本方法 ⇒ **无限递归**
    //   ⇒ UI 线程卡死（用户反馈"点退出箭头直接卡住"）。
    //
    // 递归链：
    //   maybePop() → canPop=false ⇒ 拒绝 → onPopInvokedWithResult(didPop:false)
    //   → _finalizeAndExit() → maybePop() → …… 同步死循环
    //
    // 修法：置 `_allowPop = true` 后再 pop。`setState` 是为了让
    // `PopScope.canPop` 在下一次 build 时读到新值 —— 故要先 setState
    // 再在下一帧 pop，否则本次 pop 读到的仍是旧值。
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).maybePop();
    });

    // ---- ★ 延迟兜底复位（真机实测必要，2026-10-08）----
    //
    // 真机取证（verify_orient_v2 判 BAD）：上面 pop **之前**的复位 +
    // `dispose` 里的复位，都没能让窗口转回竖屏（`cur` 仍 2400x1080）。
    //
    // 推断：pop 根路由时 Activity 进入 stopping，与 Flutter 的平台通道
    // 交互正被拆解，复位请求**不被应用**；等主页重新 resumed 时，
    // 没有人再发一次（HomeShell.initState 只在冷启动跑一次）。
    //
    // 故在 pop 之后排一个兜底：那时主页已恢复显示、Activity 已 resumed，
    // 平台调用会被应用。幂等 —— 与前两次设置同样的值，无副作用。
    unawaited(Future<void>.delayed(const Duration(milliseconds: 600), () {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }));
  }

  @override
  void dispose() {
    // Trakt：退出播放页 = stop（契约：>80% 视为看完，
    // 1%–79% 服务端降级为 pause，<1% 返回 422 被忽略）
    // 先停 Trakt 的刷新节拍（否则 dispose 后回调仍会触发）
    _traktTimer?.cancel();
    _traktTimer = null;
    final rep = _traktRep;
    if (rep != null && rep.canReport) {
      unawaited(rep.onStopped(_lastTraktPct));
    }
    _finalize();
    _startTimeout?.cancel();
    _speedTimer?.cancel();
    _posFlushTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    // ---- 恢复系统 UI / 方向 / 应用内亮度（用户实测 bug，2026-10-07）----
    //
    // ## 为什么必须在 dispose 里（而不只在 `_finalizeAndExit`）
    // 复位原来只挂在 **onBack 回调**上。但退出播放页的路径不止那一条：
    //   · **系统返回手势**（横屏下从屏幕边缘滑，MIUI 上很常用）
    //   · 路由被程序化弹出
    //   · App 在后台被回收
    // 这些都**不经过** `_finalizeAndExit`，于是方向残留横屏、
    // 亮度残留很暗 —— 用户实测退出后"首页也是横的"。
    //
    // `dispose()` 是**所有退出路径的必经点**（unmount 必然发生），
    // 旧页（`player_page.dart:1135`）正是在这里做的 —— 新页没对齐。
    //
    // ## 为什么这里能调 SystemChrome
    // `SystemChrome` 是静态平台通道 API，**不依赖 `ref`** ——
    // 与下面"dispose 里不能用 ref"的约束不冲突。
    //
    // ## 幂等性
    // `_finalizeAndExit`（onBack 路径）也做一次同样的事，随后 `maybePop`
    // 触发本 dispose 再做一次 —— 平台调用幂等，重复设置无副作用。
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    unawaited(ScreenBrightness().resetApplicationScreenBrightness());
    // ⚠️ 这里不能用 ref（Riverpod 禁止 unmount 后访问）：
    //  - playlistStateProvider.onSelect 已在 _finalizeAndExit 置空；
    //  - providers 里残留的播放状态/媒体信息由下一次进页时的 boot 全量覆盖。
    // 延迟销毁：避免在路由销毁帧内同步释放解码器（旧页踩过的原生崩溃坑）
    final k = _kernel;
    _kernel = null;
    if (k != null) {
      unawaited(Future<void>.delayed(const Duration(milliseconds: 300))
          .then((_) => k.dispose()));
    }
    super.dispose();
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    final tid = _textureId;
    if (_kernel == null || tid == null) {
      // 内核还在建纹理：黑屏（与旧页一致，避免手势层收到空树）
      return const Scaffold(backgroundColor: Colors.black, body: ColoredBox(color: Colors.black));
    }

    return PopScope<Object?>(
      // ★ 绑定 `_allowPop`（**不是**恒 false）—— 见 `_finalizeAndExit` 的说明。
      //
      // 恒 false + 在 `onPopInvokedWithResult` 里调 `maybePop()` = **无限递归**：
      //   maybePop() → canPop=false ⇒ 被拒 → onPopInvokedWithResult(didPop:false)
      //   → _finalizeAndExit() → maybePop() → …… 同步死循环 ⇒ UI 线程卡死。
      // 用户反馈"点左侧的退出箭头直接卡住"就是这个。
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _finalizeAndExit();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        // Stack 顺序：播放 UI 在下，跳过片头浮钮在上。
        //
        // ⚠️ 浮钮必须**在 PlayerUiPage 之后**（Stack 后者在上），
        //    否则控制层显示时会把浮钮盖住 —— 而"控制层刚弹出来"
        //    恰恰是用户最想点"跳过片头"的时刻。
        body: Stack(
          children: [
            PlayerUiPage(
          slots: PlayerPageSlots(
            // ★ 顶栏文案（用户反馈修复，2026-10-09）
            //
            // ## 修的是什么
            // 原实现是 `title: _current.name` + **`subtitle: _current.name`**
            // —— **同一个值传了两次**，顶栏两行显示同一句话
            //（用户："旁边显示的集数有重复显示"）。
            //
            // 实机语义树也印证过：`返回 | 第 7 集 | 第 7 集 | 快退 10 秒`
            // 或 `返回 | 剧名 | 剧名 | ...`。
            //
            // ## 现在
            // · title    = `第 N 集 · 本集名`（用户要的"集数名称"）
            // · subtitle = 剧名（**与 title 不同的信息**）
            // · 电影/无剧名 → subtitle 为 null，**不显示第二行**
            // 取值逻辑在 `topTitleFor` / `subtitleFor`（纯函数，可单测）。
            title: PlayerFlowPage.topTitleFor(_current),
            video: AspectVideo(
              textureId: tid,
              videoRatio: _kernel?.aspectRatio ?? 16 / 9,
            ),
            subtitle: PlayerFlowPage.subtitleFor(_current),
            danmakuLayer: const _DanmakuLayer(),
            // ★★ **字幕层**（只对 Media3 内核传；mpv 传 null）
            //
            // ## 为什么两个内核处理不同（真机取证）
            // · **mpv**：字幕由 `vo=gpu` 的 OSD 画进**视频帧** ⇒
            //   纹理像素里已含字幕 ⇒ 再叠一层会**画两遍**
            // · **Media3**：cue 解析出来后**等外部绘制**（本项目不引
            //   `media3-ui` 的 `SubtitleView`）⇒ 必须 Flutter 补这一层，
            //   否则真机现象是"选轨成功但画面里什么都没有"
            //
            // `_cues` 为空时层内返回 `SizedBox.shrink()`（零开销），
            // 故 mpv 下即便传了也无副作用；但**显式判空更清晰**。
            subtitleLayer: _cues.isEmpty
                ? null
                : SubtitleOverlay(cues: _cues),
            // 章节刻度：服务端已在 `PlaybackInfo` 里给好章节，
            // 这里只把起点（秒）透传给进度条（换算在进度条内做）。
            chapters: [for (final c in _chapters) c.seconds],
          ),
          callbacks: _buildCallbacks(),
        ),
            // 跳过片头浮钮（区间内才显示；见 `_introSkipButton`）
            _introSkipButton(),
          ],
        ),
      ),
    );
  }

  /// 「跳过片头」浮钮。
  ///
  /// ## 为什么单独拿出来而不是塞进 `slots`
  /// 它是**宿主页的状态**（`_intro` 只有宿主知道），
  /// 且要能**压在整个播放 UI 之上**（含控制层）—— 放进 slots 就被
  /// 控制层的 Stack 顺序管住了，会在控制层显示时被盖住。
  ///
  /// ## 与旧页的差异（有意为之）
  /// 旧页是 `Positioned(bottom: N)` 手工定位、自绘圆角按钮；
  /// 这里用 `Material` + `InkWell` 以获得**涟漪反馈与 ≥48dp 命中区**
  /// （AGENTS §6.4.1：本仓库曾有 5 处裸 `GestureDetector` 包图标，
  /// 最小仅 16×16，既点不中又无反馈）。
  Widget _introSkipButton() {
    if (!shouldOfferIntroSkip) return const SizedBox.shrink();
    final intro = _intro!;
    final pos = ref.read(playbackStateProvider).position.inSeconds;
    final remain = (intro.$2 - pos).round();
    return Positioned(
      // 放右下：不遮字幕（字幕在底部中间）、不压顶栏返回键
      right: 16,
      bottom: 108,
      child: Material(
        // 用 `panelBg`（半透明深色）而不是纯黑 —— 亮画面下也能看清，
        // 且与面板体系同源（令牌唯一来源，AGENTS §5.4）。
        color: PlayerUi.panelBg,
        borderRadius: BorderRadius.circular(PlayerUi.feedbackRadius),
        child: InkWell(
          borderRadius: BorderRadius.circular(PlayerUi.feedbackRadius),
          onTap: () {
            _introSkipped = true;
            unawaited(_kernel?.seek(Duration(seconds: intro.$2.toInt())));
            _flash('已跳过片头');
          },
          child: Padding(
            // 命中区 ≥48dp（视觉高度靠 padding 撑起）
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.fast_forward_rounded,
                    color: Colors.white, size: 18),
                const SizedBox(width: 6),
                Text(
                  '跳过片头 ${remain}s',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: PlayerUi.valueSize,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  PlayerPageCallbacks _buildCallbacks() {
    Future<void> togglePlay() async {
      final k = _kernel;
      if (k == null) return;
      if (k.state.playing) {
        await k.pause();
      } else {
        await k.play();
      }
    }

    return PlayerPageCallbacks(
      onTogglePlay: togglePlay,
      onSeekBy: (d) async {
        final k = _kernel;
        if (k == null) return;
        await k.seek(k.state.position + d);
        _reportEvent(ProgressEvent.timeUpdate);
      },
      onSeekTo: (d) async {
        final k = _kernel;
        if (k == null) return;
        await k.seek(d);
        _reportEvent(ProgressEvent.timeUpdate);
      },
      onSpeedChanged: (v) async {
        final k = _kernel;
        if (k == null) return;
        await k.setRate(v);
        _reportEvent(ProgressEvent.playbackRateChange);
      },
      // ⚠️ 单位换算：面板 0–1 → 内核 0–100（harness 实测约束，勿删）
      // ★ K3.5：音量走**系统通道**（不再改内核）
      //
      // 契约：`onVolumeChanged` 收 **0.0–1.0**，`VolumeService.set` 要 **0–100**。
      //
      // 为什么改：旧实现改内核音量 ⇒ 侧边键与 App 滑块脱节 + 双重衰减。
      // 内核音量已固定为 100（unity），见 `_startEpisode` 里的说明。
      onVolumeChanged: (v) => _volumeService.set(v * 100),
      // ⚠️ **单位契约**：`onBrightnessChanged` 收的是**手势的 0–100**
      //    （见 `GestureController.onBrightness`），
      //    而 `ScreenBrightness.setApplicationScreenBrightness` 要 **0.0–1.0**。
      //
      // ## 这里曾有一个真机 bug（用户反馈"亮度调不暗"，2026-10-07）
      // 原实现直接 `v.clamp(0.05, 1.0)` —— 把手势的 0–100 当成 0–1 用：
      //   · 手指刚一动，v≈50 → clamp 后 **1.0 = 满亮度**
      //   · 往下滑想变暗，v=30 → 仍是 1.0
      //   结果：**只能最亮，无法调暗**（且任何滑动都会瞬间跳到最亮）。
      //
      // 正确做法是**先归一化再钳制**，并用同一个函数保证口径一致。
      onBrightnessChanged: (v) {
        final normalized = brightnessToScreen(v);
        ScreenBrightness()
            .setApplicationScreenBrightness(normalized)
            .catchError((_) {});
      },
      onAspectModeChanged: (m) {
        ref.read(videoStateProvider.notifier).setAspectMode(m);
        // ★ 持久化画面比例（A+C 方案的 C 项）
        //
        // ## 为什么必须存（原来没存 —— "配了没记住"）
        // 比例档位是**用户偏好**，不是"本次会话的临时状态"。
        // 不存 ⇒ 用户选了"16:9 满屏"，下一集又回到 auto，得每集重设。
        //
        // fire-and-forget：写偏好走 Keystore 加解密，
        // 不该阻塞 UI 切换（用户已经看到画面变了）。
        unawaited(ref
            .read(sessionStoreProvider)
            .setPref('aspect_mode', m.name));
      },
      onFullscreenToggled: () {
        // ★ 全屏 = **切横屏 + 沉浸式**（用户明确要求）
        //
        // 用户原话："点击全屏时变成横屏" ⇒ 全屏的语义就是**转横屏**。
        //
        // 原实现只切系统栏不切方向，而播放页**本来就锁横屏**，
        // 所以点了看不出任何变化 —— 用户说的"点击全屏好像没用"。
        // 更要命的是 `_boot` 初始即 `immersiveSticky`，
        // 第一次点会**退出**沉浸式（露出系统栏），与"进入全屏"相反。
        _immersive = !_immersive;
        if (_immersive) {
          // 进全屏：锁横屏 + 沉浸式
          SystemChrome.setPreferredOrientations([
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]);
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        } else {
          // 退全屏：回竖屏 + 显示系统栏
          SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        }
      },
      onBack: _finalizeAndExit,
      // ★ 选集/上下集 → **真正切集**（用户反馈"点了没用"）
      //
      // ## 修的是什么（根因是同一个 bug）
      // 原实现只调 `select(i)` —— 那只是**改列表高亮**，
      // **没有任何人调用 `_playEpisode`**，所以画面永远不换 = "没用"。
      // 而且 `select()` 内部**已经调过** `onSelect` 回调，
      // 这里再调一次是**递归自我调用**
      // （第二次因 `index == currentIndex` 提前 return 才没死循环）。
      //
      // ## 为什么直接调 `_playEpisode`
      // 它是**已存在的、自动连播在用的**切集路径（L826），
      // 会做全流程：上报服务端 Stop → 落库条目进度 → 换集起播 → 重载弹幕。
      // 走同一条路 ⇒ "手动选集"与"自动连播"行为必然一致。
      onSelectMedia: (i) => unawaited(_playEpisode(i)),
      // 上下集：与选集走**同一条切集路径**（见 onSelectMedia 的说明）
      onPrevious: () {
        final idx = ref.read(playlistStateProvider).currentIndex;
        if (idx <= 0) return; // 到头不动（与 PlaylistState.hasPrevious 一致）
        unawaited(_playEpisode(idx - 1));
      },
      onNext: () {
        final pl = ref.read(playlistStateProvider);
        if (!pl.hasNext) return;
        unawaited(_playEpisode(pl.currentIndex + 1));
      },
      onSelectAudioTrack: (id) async {
        final k = _kernel;
        if (k == null) return;
        await k.setAudioTrack(id);
        ref.read(audioStateProvider.notifier).selectTrack(id);
        _reportEvent(ProgressEvent.audioTrackChange);
      },
      onSelectSubtitleTrack: (id) async {
        final k = _kernel;
        if (k == null) return;
        await k.setSubtitleTrack(id ?? 'no');
        ref.read(subtitleStateProvider.notifier).selectTrack(id);
        _reportEvent(ProgressEvent.subtitleTrackChange);
      },
      // 文件选择器未接（task-board 有独立任务卡）；回调已到接线层，先记录
      onImportSubtitle: () =>
          debugPrint('[PlayerFlow] 导入字幕：待接 file_picker（CF-P4 任务卡）'),
      // ★★ 导入本地弹幕文件 —— **接真功能**（用户要求："接真功能"）
      //
      // ## 原来这里是死按钮
      // ```dart
      // onImportDanmaku: () =>
      //     debugPrint('[PlayerFlow] 导入弹幕：待接 file_picker（CF-P4 任务卡）'),
      // ```
      // 点了只有一行日志 ⇒ 用户报障"这个导入本地弹幕文件好像点不开"。
      // 违反 AGENTS §5.8（"未接入统一用 showComingSoon，不要留死按钮"）。
      onImportDanmaku: () => unawaited(_importLocalDanmaku()),
      // ★★ 在线匹配弹幕 —— **手动选**（用户要求"增加搜弹幕方便自动匹配，
      //    防止有些弹幕匹配错误"）
      //
      // ## 原来这里是死按钮
      // ```dart
      // onMatchDanmaku: () =>
      //     debugPrint('[PlayerFlow] 在线匹配弹幕：待接手动匹配面板（CF-P5-023）'),
      // ```
      // 点了只有一行日志 ⇒ 用户**没有任何纠错出路**。
      //
      // ## 为什么必须有（外部成熟项目一致结论 + 本项目实测印证）
      // 自动匹配必然猜错的两类情况（dd-danmaku / RyoLee 的 README 都列了）：
      // 1. **译名不同**：Emby《彻夜之歌》vs 弹弹play《夜曲》
      // 2. **多季/OVA 归档**：`OVERLORD/S4E1.mkv` 这类结构
      //
      // 本项目实测：搜「斗罗大陆」返回 **8 个候选**（第二季/昊天扬威/
      // 铅华洗净…）、搜「我推的孩子」返回 **3 个**（第一/二/三季）
      // ⇒ 自动取第一个必然在多数情况下**选错季**。
      onMatchDanmaku: () => unawaited(_openMatchSheet()),
      onVideoFilterChanged: ({brightness, contrast, saturation, hue}) {
        final k = _kernel;
        // UI 状态 + 内核双写（Media3 不支持 → 内核侧静默忽略）
        final c = ref.read(videoStateProvider.notifier);
        if (brightness != null) c.setBrightness(brightness);
        if (contrast != null) c.setContrast(contrast);
        if (saturation != null) c.setSaturation(saturation);
        if (hue != null) c.setHue(hue);
        if (k != null) {
          unawaited(k.setVideoFilters(
            brightness: brightness,
            contrast: contrast,
            saturation: saturation,
            hue: hue,
          ));
        }
      },
      onResetFilters: () {
        ref.read(videoStateProvider.notifier).resetFilters();
        unawaited(_kernel?.setVideoFilters(
            brightness: 0, contrast: 0, saturation: 0, hue: 0));
      },
      onAudioDelayChanged: (d) {
        ref.read(audioStateProvider.notifier).setDelay(d);
        unawaited(_kernel?.setAudioDelay(d));
      },
      onSubtitleDelayChanged: (d) {
        ref.read(subtitleStateProvider.notifier).setDelay(d);
        unawaited(_kernel?.setSubtitleDelay(d));
      },
      onSubtitleFontSizeChanged: (s) {
        ref.read(subtitleStateProvider.notifier).setFontSize(s);
      },
      onSubtitleEncodingChanged: (e) {
        ref.read(subtitleStateProvider.notifier).setEncoding(e);
      },
    );
  }
}

/// 视频层：内核纹理 + 画幅模式（页面本身不做 aspect，由接线层决定）。
/// 弹幕层：配置（全局）+ 面板状态（本次会话）+ 弹幕数据 → DanmakuOverlay。
///
/// 位置用 select 只订阅 position，避免控制层状态变化连带弹幕重建。
class _DanmakuLayer extends ConsumerWidget {
  const _DanmakuLayer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(danmakuUiProvider);
    final panel = ref.watch(danmakuPanelProvider);
    final cfg = ref.watch(danmakuConfigProvider).value;
    final position =
        ref.watch(playbackStateProvider.select((s) => s.position));
    // ★ 播放状态：暂停时弹幕必须**停止外推**（否则画面停住弹幕还在飞）
    final playing =
        ref.watch(playbackStateProvider.select((s) => s.isPlaying));

    if (data.items.isEmpty) return const SizedBox.shrink();

    return DanmakuOverlay(
      items: data.items,
      position: position,
      playing: playing,
      enabled: panel.enabled,
      // ★★ 以下四项**只从 panel 取**（不再乘 cfg 的同类值）
      //
      // ## 原来错在哪（"同一个值被应用两次"）
      // ```dart
      // fontScale: (cfg?.fontScale ?? 1.0) * _fontScaleOf(panel.fontSize),
      // ```
      // `cfg.fontScale` 是**持久化的**用户设置，而 panel 的档位
      // 也是从它同步来的（`syncFromConfig`）⇒ 乘两次 = 字号被平方。
      // 例：用户设 1.5 ⇒ 面板同步成"大"(1.3) ⇒ 实际 1.5 × 1.3 = **1.95**。
      //
      // 现在 panel 是唯一真源（它在启动时从 cfg 同步、改动时写回 cfg），
      // 故直接取 panel 的百分比即可。
      opacity: panel.opacity / 100,
      fontScale: panel.fontPercent / 100,
      blockedWords: cfg?.blockedWords ?? const [],
      showArea: panel.showArea / 100,
      modes: switch (panel.area) {
        DanmakuArea.scroll =>
          const DanmakuDisplayModes(scroll: true, top: false, bottom: false),
        DanmakuArea.top =>
          const DanmakuDisplayModes(scroll: false, top: true, bottom: false),
        DanmakuArea.bottom =>
          const DanmakuDisplayModes(scroll: false, top: false, bottom: true),
      },
      speed: DanmakuPanelState.speedToConfig(panel.speedLevel),
      bold: cfg?.bold ?? false,
      avoidSubtitle: cfg?.avoidSubtitle ?? true,
      // ★ 过滤等级（用户设置的一键降密）
      filterLevel: cfg?.filterLevel ?? 0,
    );
  }
}

/// 弹幕 UI 数据中转（flow page 写、弹幕层读）。
///
/// 为什么不放进页面 setState：DanmakuOverlay 需要随 position 每 250ms
/// 刷新，若整层由页面 build 传入，控制条状态也会连带重建。
class DanmakuUiNotifier extends Notifier<DanmakuLoadResult> {
  @override
  DanmakuLoadResult build() => const DanmakuLoadResult();

  void set(DanmakuLoadResult value) => state = value;
}

final danmakuUiProvider =
    NotifierProvider<DanmakuUiNotifier, DanmakuLoadResult>(
        DanmakuUiNotifier.new);
