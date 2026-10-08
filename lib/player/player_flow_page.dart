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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show DeviceOrientation, SystemChrome, SystemUiMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_brightness/screen_brightness.dart';

import '../danmaku/danmaku_config.dart';
import '../danmaku/danmaku_overlay.dart';
import '../danmaku/danmaku_providers.dart';
import '../data/media_provider.dart';
import 'player_page.dart' show PlayerPage;
import '../data/models.dart';
import '../state/providers.dart' show embyApiProvider, sessionStoreProvider;
import 'application/controllers/playlist_controller.dart';
import 'application/providers/player_providers.dart';
import 'domain/models/danmaku_panel_state.dart';
import 'domain/models/media_state.dart';
import 'kernel.dart';
import 'kernel_auto_select.dart';
import 'kernel_factory.dart';
import 'kernel_traits_adapter.dart';
import 'player_facade.dart' show FacadeAudioTrack, FacadeSubtitleTrack;
import 'presentation/player_ui_page.dart';
import 'presentation/widgets/aspect_video.dart';
import 'track_aligner.dart';

/// `--dart-define=CF_NEW_PLAYER=true` 时路由切到新播放 UI。
const useNewPlayerUi =
    bool.fromEnvironment('CF_NEW_PLAYER', defaultValue: false);

/// 面板音量（0–1）→ 内核 setVolume（0–100）。
///
/// **单位换算的唯一事实源**：harness 实测出的契约断层
/// （面板 SliderRow x/100，内核与 Kotlin 侧都是 0–100），勿在调用点再换算。
/// 播放流程页与调试试验台共用。
double volumeToKernel(double v) => (v * 100).clamp(0.0, 100.0);

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
}

class _PlayerFlowPageState extends ConsumerState<PlayerFlowPage> {
  PlayerKernel? _kernel;
  int? _textureId;
  final _subs = <StreamSubscription<dynamic>>[];

  late MediaItem _current;
  late int _index;
  PlaybackLaunch? _launch;
  bool _started = false;

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

  /// 跨方法的分段计时（`_boot` / `_startEpisode` 都用它）。
  void _stage(String name) {
    final sw = _sw;
    if (sw == null) return;
    final now = sw.elapsedMilliseconds;
    debugPrint('[Startup] $name=${now - _tMark}ms (abs=${now}ms)');
    _tMark = now;
  }

  /// 位置补发定时器（配合 `NativeKernel._pushState` 的限流）。
  ///
  /// 内核为消除"每帧重建整页"把位置推送限流到 250ms；
  /// 本定时器保证**窗口内最后一次位置**会被补发出去 ——
  /// 否则暂停/seek 后进度条会停在旧位置。
  Timer? _posFlushTimer;
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

  bool _immersive = true;

  @override
  void initState() {
    super.initState();
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
    }
    ref.read(playlistStateProvider.notifier).onSelect = (entry) {
      final eps = widget.episodes;
      if (eps == null) return;
      final i = eps.indexWhere((e) => e.id == entry.id);
      if (i >= 0) unawaited(_playEpisode(i));
    };

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
    _stage('prefRead');
    final kernel = PlayerKernelFactory.create(_preference.kernelType);
    // ★ 这一段含 **mpv 初始化 + EGL 上下文创建**，是起播的固定开销
    await kernel.ensureTexture();
    _stage('kernelCreate+texture');
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
    await _startEpisode(resumeSeconds: _resumeSeconds);
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
      final past = s.position > _seekTarget + const Duration(milliseconds: 500);
      if (!_firstFrameLogged && past) {
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
      }
      lastPlaying = s.playing;
    }));
    _subs.add(kernel.tracksStream.listen((t) {
      // 轨道列表：内核轨道 + 服务端名字由 TrackAligner 对齐；
      // 这里的列表仅含内核侧（对齐版在 _applyServerDefaultTracks 后
      // 以 AlignedTrack.label 替换 —— 见 _syncTrackLists）。
      _syncTrackLists(launch: _launch, kernel: t);
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
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(e), behavior: SnackBarBehavior.floating),
        );
      }
    }));
    _subs.add(kernel.completedStream.listen((_) => _onCompleted()));
    // 视频分辨率解析完成 → 重算宽高比（首帧时触发一次）
    _subs.add(kernel.videoSizeStream.listen((_) {
      if (mounted) setState(() {});
    }));
  }

  // ---------- 起播 / 换集 ----------

  Future<void> _startEpisode({required double resumeSeconds}) async {
    final k = _kernel;
    if (k == null || _switching) return;
    // 换集时重置首帧标记（否则第 2 集起不再计时）
    _firstFrameLogged = false;
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
      ref
          .read(playbackStateProvider.notifier)
          .setDuration(Duration(milliseconds: _current.runtimeTicks ?? 0));

      // ---- 自动适配：拿到片源特征后再决定一次 ----
      //
      // 若决策结果与当前内核不同 → 换内核（保持进度）。
      // 这是"根据视频自动适配"的落点：决策输入全部来自 launch。
      final adapted = await _adaptKernel(launch);
      _stage('adapt');
      if (adapted == null) return; // 换内核中，本次起播交给新内核
      final k2 = adapted;

      await k2.open(launch.url, play: true, headers: launch.headers);
      _stage('open');
      if (resumeSeconds > 3) {
        // 记下目标 —— 首帧探针要用它区分"seek 刚登记"与"真的在推进"
        _seekTarget = Duration(seconds: resumeSeconds.toInt());
        await k2.seek(_seekTarget);
      }
      _stage('seek');
      // 默认倍速偏好
      final savedRate = double.tryParse(
          await ref.read(sessionStoreProvider).getPref('default_rate') ?? '');
      if (savedRate != null && savedRate != 1) {
        await k2.setRate(savedRate);
      }
      _stage('rate');
      debugPrint('[Startup] TOTAL=${_sw?.elapsedMilliseconds ?? 0}ms '
          '(resume=${resumeSeconds.toInt()}s)');
      _reportStart(launch);
      unawaited(_applyServerDefaultTracks(launch));
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
      if (_playMethod == 'direct' &&
          (_launch?.transcodingUrl ?? '').isNotEmpty) {
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
  Future<void> _reopenAs(String method, {String? reason}) async {
    final launch = _launch;
    final k = _kernel;
    if (launch == null || k == null || _switching) return;
    if (method == 'transcode' && (launch.transcodingUrl ?? '').isEmpty) {
      _snack('该媒体源没有可用的转码流');
      return;
    }
    if (method == _playMethod) return;
    final keepPos = k.state.position;
    setState(() {
      _playMethod = method;
      _switching = true;
    });
    try {
      await k.open(
          method == 'transcode' ? launch.transcodingUrl! : launch.url,
          play: true);
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
      await k.open(launch.url, play: true, headers: launch.headers);
      _reportStart(launch);
      unawaited(_applyServerDefaultTracks(launch));
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
    ref.read(subtitleStateProvider.notifier).setTracks([
      const SubtitleTrack(id: 'no', name: '关闭字幕'),
      for (final s in alignedSub)
        SubtitleTrack(
          id: s.kernelId,
          name: s.label,
          isExternal: s.isExternal,
        ),
    ]);
  }

  /// 服务端指定的默认轨（旧页同款：等内核轨道到达后按 isDefault 应用）。
  Future<void> _applyServerDefaultTracks(PlaybackLaunch launch) async {
    final k = _kernel;
    if (k == null) return;
    final wantAudio = launch.defaultAudioIndex;
    final wantSub = launch.defaultSubtitleIndex;
    if (wantAudio == null && wantSub == null) return;

    // 等内核上报轨道（最多 3s，每 200ms 探一次）
    for (var i = 0; i < 15; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;
      if (k.tracks.audio.isNotEmpty || k.tracks.subtitle.isNotEmpty) break;
    }
    if (!mounted) return;

    try {
      if (wantAudio != null) {
        final server = launch.streams.where((s) => s.type == 'Audio').toList();
        final aligned = TrackAligner.alignAudio(
            server, _facadeAudio(k.tracks.audio),
            defaultIndex: wantAudio);
        final hit = aligned.where((a) => a.isDefault).toList();
        if (hit.isNotEmpty) {
          await k.setAudioTrack(hit.first.kernelId);
          ref.read(audioStateProvider.notifier).selectTrack(hit.first.kernelId);
        }
      }
      // 服务端未指定字幕 → 不主动关（尊重内核/用户习惯，旧页同款）
      if (wantSub != null) {
        final server = launch.streams.where((s) => s.type == 'Subtitle').toList();
        final aligned = TrackAligner.alignSubtitle(
            server, _facadeSub(k.tracks.subtitle),
            defaultIndex: wantSub);
        final hit = aligned.where((a) => a.isDefault).toList();
        if (hit.isNotEmpty) {
          await k.setSubtitleTrack(hit.first.kernelId);
          ref.read(subtitleStateProvider.notifier).selectTrack(hit.first.kernelId);
        }
      }
    } catch (e) {
      debugPrint('[PlayerFlow] 应用服务端默认轨失败（非致命）: $e');
    }
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
    final cfg = ref.read(danmakuConfigProvider).value;
    if (cfg == null || cfg.kind == DanmakuProviderKind.off) return;
    try {
      final result = await ref.read(danmakuForItemProvider(_current).future);
      if (!mounted) return;
      if (result.error != null) {
        // 弹幕错误不阻断播放（旧页同款"尽力而为"），记录到 UI 供面板展示
        debugPrint('[PlayerFlow] 弹幕：${result.error}');
      }
      ref.read(danmakuUiProvider.notifier).set(result);
    } catch (e) {
      debugPrint('[PlayerFlow] 弹幕加载失败（非致命）: $e');
    }
  }

  // ---------- 退出 ----------

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
        body: PlayerUiPage(
          slots: PlayerPageSlots(
            title: _current.name,
            video: AspectVideo(
              textureId: tid,
              videoRatio: _kernel?.aspectRatio ?? 16 / 9,
            ),
            subtitle: _current.name,
            danmakuLayer: const _DanmakuLayer(),
          ),
          callbacks: _buildCallbacks(),
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
      onVolumeChanged: (v) => _kernel?.setVolume(volumeToKernel(v)),
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
      onImportDanmaku: () =>
          debugPrint('[PlayerFlow] 导入弹幕：待接 file_picker（CF-P4 任务卡）'),
      onMatchDanmaku: () =>
          debugPrint('[PlayerFlow] 在线匹配弹幕：待接手动匹配面板（CF-P5-023）'),
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

    if (data.items.isEmpty) return const SizedBox.shrink();

    return DanmakuOverlay(
      items: data.items,
      position: position,
      enabled: panel.enabled,
      opacity: panel.opacity / 100,
      fontScale: (cfg?.fontScale ?? 1.0) * _fontScaleOf(panel.fontSize),
      blockedWords: cfg?.blockedWords ?? const [],
      showArea: cfg?.showArea ?? 1.0,
      modes: switch (panel.area) {
        DanmakuArea.scroll =>
          const DanmakuDisplayModes(scroll: true, top: false, bottom: false),
        DanmakuArea.top =>
          const DanmakuDisplayModes(scroll: false, top: true, bottom: false),
        DanmakuArea.bottom =>
          const DanmakuDisplayModes(scroll: false, top: false, bottom: true),
      },
      speed: panel.speedLevel / 5,
      bold: cfg?.bold ?? false,
      avoidSubtitle: cfg?.avoidSubtitle ?? true,
    );
  }

  /// 面板字号档 → 缩放系数（与字幕字号同一手感）。
  double _fontScaleOf(DanmakuFontSize size) => switch (size) {
        DanmakuFontSize.small => 0.8,
        DanmakuFontSize.medium => 1.0,
        DanmakuFontSize.large => 1.3,
      };
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
