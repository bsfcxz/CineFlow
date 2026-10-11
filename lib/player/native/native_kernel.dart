/// 安卓原生 mpv 内核（MethodChannel 命令 + EventChannel 事件 + Flutter 纹理输出）。
///
/// 原生端：android/app/src/main/kotlin/com/cineflow/app/player/
///   MPVLib.kt       —— JNI 桥（Surface → wid）
///   PlayerChannel.kt—— 通道与纹理管理
/// C 端：android/app/src/main/cpp/cineflow_mpv.c
///
/// 参考实现：
///   - mpv-android   https://github.com/mpv-android/mpv-android
///   - media_kit_video VideoOutput.java（Flutter 纹理 → wid）
///
/// ## 视频输出为什么用纹理而不是 PlatformView
///
/// `createTexture` 让原生侧建一个 Flutter 纹理并把它的 Surface 交给 mpv，
/// Dart 侧用 `Texture(textureId:)` 显示。这样视频就是**普通 Flutter 图层**，
/// 弹幕 CustomPainter / 手势 GestureDetector / 控制层全部天然叠在上面，
/// 既没有 PlatformView 的手势仲裁问题，也不需要自己写 EGL。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../domain/player_constants.dart' show DecodeMode;
import '../kernel.dart';
import '../kernel_event_parser.dart';
import '../track_aligner.dart' show TrackAligner;

class NativeKernel implements PlayerKernel {
  NativeKernel() {
    _method = const MethodChannel('cineflow/player');
    _event = const EventChannel('cineflow/player/events');
    _eventSub = _event.receiveBroadcastStream().listen(
      _onNativeEvent,
      onError: (Object e, StackTrace st) {
        _errorController.add('原生事件错误：$e');
      },
    );
  }

  late final MethodChannel _method;
  late final EventChannel _event;
  StreamSubscription? _eventSub;

  /// Flutter 纹理 id（VideoView 用它渲染）；未创建时为 null
  int? _textureId;
  @override
  int? get textureId => _textureId;

  /// 视频原始尺寸（宽高比）；未知时为 null，UI 侧回退 16:9
  int _videoWidth = 0;
  int _videoHeight = 0;
  @override
  double? get aspectRatio =>
      (_videoWidth > 0 && _videoHeight > 0) ? _videoWidth / _videoHeight : null;

  KernelState _state = const KernelState(
    position: Duration.zero,
    duration: Duration.zero,
    buffer: Duration.zero,
    playing: false,
    buffering: false,
    rate: 1.0,
  );
  KernelTracks _tracks = const KernelTracks();
  KernelSelection _selection =
      const KernelSelection(audioId: 'auto', subtitleId: 'auto');

  final _stateController = StreamController<KernelState>.broadcast();
  final _tracksController = StreamController<KernelTracks>.broadcast();
  final _selectionController = StreamController<KernelSelection>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _completedController = StreamController<bool>.broadcast();
  final _videoSizeController = StreamController<void>.broadcast();

  /// 视频尺寸变化（UI 需要 setState 重算宽高比）
  @override
  Stream<void> get videoSizeStream => _videoSizeController.stream;

  /// ★ 位置推送限流（真机卡顿的根因修复，2026-10-08）
  ///
  /// ## 问题
  /// mpv 的 `time-pos` 是**原生观察属性**：每次值变化就发一次
  /// `MPV_EVENT_PROPERTY_CHANGE`，播放中约 **30–60 次/秒**（每帧）。
  /// 原来每次变化都 `_pushState` → 事件流 → Riverpod 状态变 →
  /// `PlayerUiPage.build` 重跑（它 watch 整个 `playbackStateProvider`）
  /// → **整页 Stack**（视频层/弹幕层/手势层/反馈层/控制层）重建 60 次/秒。
  ///
  /// 真机 `dumpsys gfxinfo` 实测：
  /// ```
  /// Janky frames: 6 (33.33%)     Number Slow UI thread: 3
  /// 90th percentile: 97ms        95th percentile: 150ms
  /// ```
  /// `Slow UI thread`（而非 `Slow issue draw commands`）⇒ 瓶颈是 **Dart 重建**。
  ///
  /// ## 为什么限流是安全的
  /// · **进度条**：250ms 刷新一次，肉眼完全看不出（60Hz 屏上是 15 帧一更新，
  ///   而进度条一次只移动几十像素，人眼无法分辨"每帧"与"每 250ms"）
  /// · **时间文字**：本来就是秒级显示，250ms 已经远超需要
  /// · **其他字段**（playing/duration/buffer/rate/volume）：**立即推送**，
  ///   它们的**变化频率天然很低**（用户操作才变），且**必须及时**
  ///   （比如 playing 翻转要立刻更新播放按钮图标）
  ///
  /// ## 实现要点
  /// 只在"**仅有位置变化**"时限流；其他字段变化一律立即推送，
  /// 否则会出现"点暂停后图标 250ms 才变"的可感知延迟。
  ///
  /// ⚠️ 末尾**必须补发一次**（flush）：否则限流窗口内最后一次位置变化
  ///    会丢失，seek 后进度条可能停在旧位置。
  void _pushState(KernelState s, {bool isPositionOnly = false}) {
    _state = s;
    if (_stateController.isClosed) return;

    if (!isPositionOnly) {
      // 非位置字段变化 → 立即推送（并重置限流窗口起点）
      _lastPositionPushAt = DateTime.now();
      _stateController.add(s);
      return;
    }

    final now = DateTime.now();
    final since = _lastPositionPushAt;
    if (since != null && now.difference(since) < _positionThrottle) {
      // 窗口内：不推送，但要记下"有待补发"
      _pendingPosition = s.position;
      return;
    }
    _lastPositionPushAt = now;
    _pendingPosition = null;
    _stateController.add(s);
  }

  /// 位置推送间隔（见 [_pushState] 的长注释）。
  static const Duration _positionThrottle = Duration(milliseconds: 250);
  DateTime? _lastPositionPushAt;

  /// 限流窗口内被抑制的最后一个位置（待补发）。
  Duration? _pendingPosition;

  /// 补发挂起的位置（由 UI 侧定时调用，或下次事件到来时）。
  ///
  /// ⚠️ 不补发会丢失"最后一次位置"：例如用户 seek 后立刻松手，
  ///    进度条会停在旧位置直到下一次 time-pos 到来。
  @override
  void flushPendingPosition() {
    final p = _pendingPosition;
    if (p == null || _stateController.isClosed) return;
    _pendingPosition = null;
    _lastPositionPushAt = DateTime.now();
    _stateController.add(_state.copyWith(position: p));
  }


  KernelState _copy({
    Duration? position,
    Duration? duration,
    Duration? buffer,
    bool? playing,
    bool? buffering,
    double? rate,
    double? volume,
  }) {
    return _state.copyWith(
      position: position,
      duration: duration,
      buffer: buffer,
      playing: playing,
      buffering: buffering,
      rate: rate,
      volume: volume,
    );
  }

  /// 原生事件的 JSON 解析。
  ///
  /// C 侧已做 JSON 转义（见 cineflow_mpv.c 的 sb_json_string）；
  /// 这里对**每一条**都 try/catch：单条事件坏掉不该影响播放。
  void _onNativeEvent(dynamic raw) {
    if (raw is! String || raw.isEmpty) return;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      switch (m['type']) {
        case 'property':
          _onProperty(m['name'] as String? ?? '', m['data']);
        case 'end-file':
          final reason = m['reason'];
          if (reason == 'eof') {
            _completedController.add(true);
          } else if (reason == 'error') {
            // end-file(error) 时 mpv 不总是给可读原因，UI 侧另有兜底文案
            _errorController.add('播放失败（内核报错）');
          }
        case 'log':
          // ★★ 日志**不再全部丢弃**（真机实测的关键缺口 + 开源对照）
          //
          // ## 为什么必须看日志（用户报障的两个问题都在日志里）
          // 我们的 libmpv.so 缺解码器，而**只有 mpv 日志会说**：
          // ```
          // [mpv/ad]  Failed to initialize a decoder for codec 'truehd'.
          // [mpv/sub] Could not find subtitle decoder for format
          //           'hdmv_pgs_subtitle'.
          // ```
          // 而原来的 `break;` 把它们**全部丢掉** ⇒ 用户只感到
          // "没声音/没字幕"，**没有任何提示**，也不知道原因。
          //
          // ## 为什么不能把所有日志都弹给用户
          // mpv 日志量极大（播放中每秒数条）。⇒ 只挑**可行动的那几条**：
          // 解码器缺失 / 字幕解码器缺失 —— 它们意味着"这条轨永远播不出来"，
          // 必须让用户知道（换轨或换内核），而不是静默失败。
          _maybeSurfaceDecodeFailure(
              m['level'] as String?, m['text'] as String?);

        // ★ Media3 侧的同类上报（`AnalyticsListener` 发出）
        case 'trackUnsupported':
          final msg = m['message'] as String? ?? '该轨道编码不受支持';
          if (!_errorController.isClosed) _errorController.add(msg);
          debugPrint('[Kernel] 轨道不受支持：$msg');
      }
    } catch (_) {
      // 单条事件解析失败不影响播放
    }
  }

  /// 已上报过的解码失败（**去重**用）。
  ///
  /// ## 为什么必须去重
  /// mpv 在切轨/重试时会把同一条错误**重复打印多次**
  ///（真机实测：切一次音轨就刷 2–3 条）。不去重会连弹多个提示。
  final _reportedDecodeFailures = <String>{};

  /// **把"解码器缺失"这类日志变成用户可见的提示**。
  ///
  /// ## 为什么只挑这两类（而不是所有日志）
  /// | 日志特征 | 含义 | 用户能做什么 |
  /// |---|---|---|
  /// | `Failed to initialize a decoder for codec 'X'` | 该音轨/视频**永远播不出来** | 换一条轨 |
  /// | `Could not find subtitle decoder for format 'X'` | 该字幕**永远显示不了** | 换一条字幕 |
  ///
  /// 其余日志（缓存、丢帧、时序）都是**过程性**的，弹给用户只会造成噪音。
  ///
  /// ## 根因说明（如实告诉用户"为什么"）
  /// 这两类的根因都一样：**自持 libmpv.so 是白名单编译，缺解码器**
  ///（实测缺 `truehd`/`mlp`/`pgssub`/`mov_text`）。
  /// ⇒ 文案里要给出**可行动的下一步**（换轨 / 换内核），而不是"出错了"。
  void _maybeSurfaceDecodeFailure(String? level, String? text) {
    if (text == null || text.isEmpty) return;

    String? msg;
    // ① 音频/视频解码器初始化失败
    final m1 = RegExp(
            r"Failed to initialize a decoder for codec '([^']+)'")
        .firstMatch(text);
    if (m1 != null) {
      final codec = m1.group(1)!;
      // ★ 记入**运行时能力表**（供后续换轨时自动跳过同一编码）
      TrackAligner.markSubtitleCodecUnsupported(codec);
      msg = '该轨道的编码（$codec）当前播放内核无法解码，已跳过。'
          '请换一条音轨（或切换到另一个播放内核）。';
    }
    // ② 字幕解码器缺失
    final m2 = RegExp(
            r"Could not find subtitle decoder for format '([^']+)'")
        .firstMatch(text);
    if (m2 != null) {
      final fmt = m2.group(1)!;
      // ★★ **记入运行时能力表**（本轮的关键设计修正）
      //
      // ## 为什么必须是"运行时记录"而不是"代码里硬编码"
      // 用户两次指正："mpv 也能解码 PGS"。核实后确认**他是对的**：
      // · mpv 上游（全量 ffmpeg）**支持 PGS**
      // · Media3 有 `PgsParser`（已核实 aar 里有该类）⇒ 也能显示
      // 我们这份 `.so` 缺 `ff_pgssub_decoder` **只是当前这份构建的问题**。
      //
      // ⇒ 若把 `pgssub` 硬编码进黑名单，**修好 .so 之后反而是坏的**
      //   （字幕能显示了却被代码禁用）。
      // ⇒ 改为：**这次进程里报错了 → 记下来 → 本次会话后续跳过**；
      //   下次启动（或换了 .so）自然恢复。
      //
      // ⚠️ `hdmv_pgs_subtitle` 与 `pgssub` 是同一个解码器的两种叫法
      //   （前者是 `AVCodecDescriptor` 名、后者是 `AVCodec.name`）
      //   ⇒ 两个都记，避免"报了 A 却按 B 判断"。
      TrackAligner.markSubtitleCodecUnsupported(fmt);
      if (fmt.contains('pgs')) {
        TrackAligner.markSubtitleCodecUnsupported('pgssub');
        TrackAligner.markSubtitleCodecUnsupported('pgs');
      }
      // 把编码名转成人话（PGS 是图形字幕，用户看到名字也不知道）
      final human = fmt.contains('pgs')
          ? 'PGS 图形字幕（蓝光原盘常用）'
          : fmt;
      msg = '该字幕是 $human，当前播放内核不支持，无法显示。'
          '请换一条文本字幕（如 SRT/ASS）。';
    }
    if (msg == null) return;

    // 去重：同一条只报一次
    if (!_reportedDecodeFailures.add(msg)) return;
    debugPrint('[Kernel] $msg');
    if (!_errorController.isClosed) _errorController.add(msg);
  }

  void _onProperty(String name, Object? data) {
    switch (name) {
      case 'time-pos':
        final v = (data as num?)?.toDouble() ?? -1;
        // ★ 标记为"仅位置变化" → 走限流路径（每秒最多 4 次，不是 60 次）
        if (v >= 0) {
          _pushState(
            _copy(position: Duration(milliseconds: (v * 1000).round())),
            isPositionOnly: true,
          );
        }
      case 'duration':
        final v = (data as num?)?.toDouble() ?? -1;
        if (v > 0) {
          _pushState(_copy(duration: Duration(milliseconds: (v * 1000).round())));
        }
      case 'demuxer-cache-time':
        final v = (data as num?)?.toDouble() ?? -1;
        if (v >= 0) {
          _pushState(_copy(buffer: Duration(milliseconds: (v * 1000).round())));
        }
      case 'pause':
        _pushState(_copy(playing: data != true));
      case 'paused-for-cache':
        // mpv 的缓冲状态：比"buffer < 4s"的猜测准确得多
        _pushState(_copy(buffering: data == true));
      case 'eof-reached':
        if (data == true) _completedController.add(true);
      case 'speed':
        final v = (data as num?)?.toDouble();
        if (v != null) _pushState(_copy(rate: v));
      case 'volume':
        final v = (data as num?)?.toDouble();
        if (v != null) _pushState(_copy(volume: v));
      case 'aid':
        _selection = KernelSelection(
          audioId: '${data ?? 'auto'}',
          subtitleId: _selection.subtitleId,
        );
        if (!_selectionController.isClosed) _selectionController.add(_selection);
      case 'sid':
        _selection = KernelSelection(
          audioId: _selection.audioId,
          subtitleId: '${data ?? 'no'}',
        );
        if (!_selectionController.isClosed) _selectionController.add(_selection);
      case 'track-list':
        // ★ 诊断（用户报"没识别到音频/字幕"时定位用）
        //
        // ## 为什么要打（真机取证的结论）
        // 实测《复仇者联盟》：服务端给出 **6 音频 / 8 字幕**，
        // mpv 原生侧日志也确认有 `Audio --aid=1` + 13 条 `Subs --sid=*`，
        // **但 Dart 侧收到 0 条** ⇒ 问题在事件链路。
        // 只打"收到几条"不够 —— 还要知道 data 的**类型与形状**
        // （`null`？空 list？还是 JSON 字符串但字段名不符？）
        final parsed = _parseTracks(data);
        debugPrint('[Kernel] track-list 事件：data 类型='
            '${data.runtimeType}，长度='
            '${data is List ? data.length : '非List'} '
            '→ 解析出 音频${parsed.audio.length}/字幕${parsed.subtitle.length}');
        // ★★ 形状诊断：把**第一条**轨道的原始 JSON 打出来
        //
        // ## 为什么必须打原始内容（真机实测踩到）
        // 长度=16 却解析出 0 条 ⇒ 字段名不符。只有看到**真实 key**
        // 才能知道是 `type`/`id`/`ff-index` 中的哪个对不上。
        // （盲猜字段名在本仓库栽过多次。）
        if (data is List && data.isNotEmpty) {
          debugPrint('[Kernel] track-list[0] 原始 = ${data.first}');
        }
        _tracks = parsed;
        if (!_tracksController.isClosed) _tracksController.add(_tracks);
      // ★ 2026-10-09：`width/height` → `dwidth/dheight`（C 层已同步改观察名）
      //
      // ## 为什么必须用显示尺寸
      // `width/height` 是**编码**尺寸 —— 手机竖拍视频常是 1920x1080 +
      // rotate=90，按它算出 16:9，画面被横置拉宽（方向适配无从谈起）。
      // `dwidth/dheight` 是 mpv **已应用旋转与像素宽高比(SAR)** 的
      // 显示尺寸 ⇒ 竖屏视频得到 9:16，横屏得到 16:9，与"显示"一致。
      case 'dwidth':
      case 'dheight':
        final v = (data as num?)?.toInt() ?? 0;
        if (v <= 0) return;
        final before = aspectRatio;
        if (name == 'dwidth') {
          _videoWidth = v;
        } else {
          _videoHeight = v;
        }
        // 两个都拿到且比例真的变了才通知（避免分辨率切换时刷两次）
        if (aspectRatio != null && aspectRatio != before) {
          if (!_videoSizeController.isClosed) _videoSizeController.add(null);
        }
    }
  }

  /// mpv `track-list`（JSON 字符串）→ KernelTracks
  ///
  /// ## 为什么要取这么多字段（用户要求）
  /// > "多音轨多字幕这种，我在选择的时候你显示出名称，像字幕的话
  /// >  有中字、双语、繁体等"
  ///
  /// mpv 的 `track-list` 本来就有这些字段，原实现只取 `id`/`title`/`lang`，
  /// **其余全丢了** —— 于是多音轨场景下（实测 `aid=1 aac 2ch` vs
  /// `aid=3 eac3 6ch`，两者 title 都为空）界面上两条完全一样的"音轨 开"，
  /// 用户无法区分。这里补齐 `codec` / `demux-channels` / `default` /
  /// `external` / `forced`，交给 `KernelTrack.displayName` 拼成可读名称。
  ///
  /// ★ 2026-10：实现**已移到共用解析器** [KernelEventParser.parseTracks]，
  ///   与 Media3 内核共用一份。原因：两边各写一份时，任何一处改字段名
  ///   都会造成"其中一边静默解析出空轨道" —— 现象是"看不到音轨"，
  ///   不报错、不崩溃，极难发现。保留本方法作为薄转发（不改调用点）。
  KernelTracks _parseTracks(Object? data) =>
      KernelEventParser.parseTracks(data);

  /// 建纹理（幂等）。必须在 open 之前完成，否则 mpv 没有渲染目标。
  @override
  Future<void> ensureTexture({int width = 1920, int height = 1080}) async {
    if (_textureId != null) return;
    final id = await _method.invokeMethod<int>('createTexture', {
      'width': width,
      'height': height,
    });
    _textureId = id;
    // ★★ 必须**记账已建尺寸**（真机实测抓到的"去重失效"）
    //
    // ## 不记会怎样
    // `recreateTexture` 靠 `_surfaceW/_surfaceH` 判断"尺寸是否变了"。
    // 这里建了纹理却不记账 ⇒ 那两个字段仍是 0 ⇒ 首次 `recreateTexture`
    // **必然认为尺寸变了** ⇒ 即使画布已是目标尺寸也会重建。
    //
    // 真机日志（同比例连播时）：
    // ```
    // 起播前设画布：片源 1920x1080 → 画布 1920x1080
    // [Kernel] 重建画布纹理 → 1920x1080 （id=3）   ← 尺寸没变也重建了
    // ```
    // ⇒ 每次换集都白重建一次（视频层闪一下）。
    _surfaceW = width;
    _surfaceH = height;
  }

  /// 设置渲染画布尺寸（mpv 的 `wid` Surface 的 buffer 大小）。
  ///
  /// ## 为什么必须接线（真机实测：画面被压扁两次）
  /// Kotlin 侧早有 `setSurfaceSize` 通道（`PlayerChannel.kt`），
  /// 但 **Dart 侧从未调用** ⇒ 画布恒为 `ensureTexture` 传的 1920×1080（16:9）。
  /// 而 mpv 会把宽银幕画面 letterbox 进这个 16:9 画布 ⇒ 黑边进纹理，
  /// Dart 再嵌一次 ⇒ **双重黑边**（2.388:1 片源实测只剩 74.4% 高度）。
  ///
  /// ## 传什么值（对齐 media_kit）
  /// media_kit 的 android 控制器直接拿 `dw`/`dh` 当画布尺寸
  /// （源码 `android_video_controller/real.dart`）。
  /// 我们也传**显示尺寸** —— 这样画布与视频同比例，
  /// **画布里只有画面、没有黑边**，比例由 Dart 层唯一决定。
  ///
  /// ## 幂等 + 去抖
  /// `dwidth`/`dheight` 是**两个事件**，先到那个时另一个可能还是 0；
  /// 且换片/切分辨率会重复设置。故：
  /// · 任一边 ≤ 0 时**直接返回**（等另一边到齐）
  /// · 与上次相同则**不重发**（避免无谓的 MethodChannel 往返）
  @override
  Future<void> setSurfaceSize(int width, int height) async {
    if (width <= 0 || height <= 0) return;
    if (_surfaceW == width && _surfaceH == height) return;
    _surfaceW = width;
    _surfaceH = height;
    try {
      await _method.invokeMethod('setSurfaceSize', {
        'width': width,
        'height': height,
      });
      debugPrint('[Kernel] 画布尺寸 → ${width}x$height'
          '（ratio=${(width / height).toStringAsFixed(3)}）');
    } catch (e) {
      // 设置失败不该影响播放（画布退回默认尺寸，画面仍能看，只是比例不准）
      debugPrint('[Kernel] 设置画布尺寸失败（非致命）: $e');
    }
  }

  /// 上次设置的画布尺寸（去重用）
  int _surfaceW = 0;
  int _surfaceH = 0;

  /// 按新尺寸**重建纹理**（真机实测：光改属性/尺寸不够）。
  ///
  /// ## 为什么必须重建（时序取证）
  /// ```
  /// _boot():         createTexture: 1920x1080      ← buffer 定为 16:9
  /// _startEpisode(): android-surface-size=1920x804 ← 属性改了，buffer 没变
  /// ⇒ 画面仍 334px（应 452）
  /// ```
  /// `SurfaceProducer` 的 **buffer 尺寸在创建时固定**，之后改声明**不会**
  /// 重建已分配的 buffer ⇒ 必须销毁 + 重建。
  ///
  /// ## 去重（同尺寸不重建 ⇒ 无闪烁）
  /// 同比例片源连播（如整季都是 16:9）不会重建。
  ///
  /// ## 重建顺序由 Kotlin 保证
  /// `createTexture` 内部先 `disposeTexture()`（detachSurface + release），
  /// 再按新尺寸建 producer 并 attachSurface ⇒ Dart 只需调一次。
  @override
  Future<bool> recreateTexture({
    required int width,
    required int height,
  }) async {
    if (width <= 0 || height <= 0) return false;
    if (_surfaceW == width && _surfaceH == height && _textureId != null) {
      return false;
    }
    _surfaceW = width;
    _surfaceH = height;
    try {
      final id = await _method.invokeMethod<int>('createTexture', {
        'width': width,
        'height': height,
      });
      _textureId = id;
      debugPrint('[Kernel] 重建画布纹理 → ${width}x$height '
          '（id=$id, ratio=${(width / height).toStringAsFixed(3)}）');
      return true;
    } catch (e) {
      debugPrint('[Kernel] 重建纹理失败（非致命，沿用旧画布）: $e');
      return false;
    }
  }

  Future<void> ensureInitialized() async {
    await ensureTexture();
    await _method.invokeMethod('initialize');
    // ⚠️ 用 `unawaited`：自检是**诊断**，不该阻塞起播。
    //    （`ensureInitialized` 在 `open()` 里被 await，
    //      若自检挂起会直接拖慢起播 —— 实测就是这个现象。）
    // （自检已移至 PlayerFlowPage._verifyMpvConfig —— 此处会阻塞 open()，见该方法的说明）
  }


  /// 读回 mpv 属性（见 `PlayerKernel.getOption` 的说明）。
  ///
  /// ⚠️ **必须加超时**：实测不加时 `getProperty` 会挂起不返回，
  ///    导致依赖它的日志永远打不出来（排查花了好几轮）。
  ///    300ms 足够正常读取；超时返回 null（记为"读不到"）。
  @override
  Future<String?> getOption(String name) async {
    try {
      // 300ms 超时：mpv 的 `mpv_get_property` 对某些属性可能阻塞，
      // 而这是**起播路径上的诊断调用**，绝不能拖住播放。
      return await _method
          .invokeMethod<String>('getProperty', {'name': name})
          .timeout(const Duration(milliseconds: 300));
    } catch (_) {
      // 读不到就返回 null —— 调用方据此判定"未生效"，
      // **不该因为诊断失败而影响播放**。
      return null;
    }
  }

  @override
  String get engine => 'native';

  /// 原生引擎不再有 PlatformView；视频由 Texture(textureId) 呈现
  @override
  String? get viewType => null;

  @override
  Future<void> open(
    String url, {
    bool play = true,
    Duration? start,
    Map<String, String>? headers,
  }) async {
    await ensureInitialized();
    // 换片时清掉上一部的尺寸，避免沿用旧宽高比
    _videoWidth = 0;
    _videoHeight = 0;

    // ★★ 续播位置随 open 一起下发（起播优化，2026-10-10）
    //
    // ## 改了什么
    // 原来：`open`（从头）→ 再单独 `seek`。两次命令 + 两次往返。
    // 现在：把 `start` 交给原生，由 `loadfile` 的第 3 参数
    //（`start=`，mpv 文件局部选项）一次到位。
    //
    // ## ⚠️★ 为什么仍然"可能"再补一次 seek（防静默失败）
    // mpv **0.38.0 改了 `loadfile` 的参数位**：原来的第 3 参数
    // （options）变成第 4 个，中间插入 index。我们的构建是
    // `v0.36.0-549` ⇒ 3 参数写法正确；**但将来重建 libmpv 升到 0.38+**
    // 时，那个写法**不报错、不崩溃，只是静默不跳转**（从 0:00 播）。
    //
    // ⇒ 不赌"原生一定跳对了"：open 之后**核对一次**位置。
    //    核对方式：给一个短暂窗口，若上报的 position 与目标相差过大
    //    （说明 start= 没生效），补一次显式 seek 兜底。
    //
    //    ⚠️ 不能用"等 position>0"当判据 —— 那是**旧探针的错**
    //    （seek 后 mpv 立刻回报 time-pos=目标值，画面还没出来）。
    //    这里只判断"当前 position 是否已接近目标或已越过":
    //    它们能区分"跳转未生效（还在 0 附近）"与"跳转已登记"。
    final wantStart = start != null && start.inSeconds > 3;
    _startApplied = false;

    await _method.invokeMethod('open', {
      'url': url,
      if (headers != null && headers.isNotEmpty) 'headers': headers,
      // 原生侧 > 3s 才使用（见 PlayerChannel 的说明）
      if (wantStart) 'start': start.inMilliseconds / 1000.0,
    });
    if (!play) await _method.invokeMethod('pause');

    if (wantStart) {
      // 给 mpv 一个短窗口应用 `start=`（属性变化要经事件线程回传）
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final pos = _state.position;
      // 判定：位置是否已接近目标（±3s）或越过
      final near = (pos - start).abs() < const Duration(seconds: 3);
      final past = pos > start;
      if (near || past) {
        _startApplied = true;
      } else {
        // start= 未生效（如将来升级到 mpv 0.38+ 的签名变化）
        // ⇒ 补一次显式 seek，保证续播位置正确
        await seek(start);
        _startApplied = true;
      }
    }
  }

  /// 是否由 `loadfile` 的 `start=` 应用了续播位置（诊断用）。
  bool get startAppliedByLoadfile => _startApplied;

  bool _startApplied = false;

  @override
  Future<void> play() => _method.invokeMethod('play');

  @override
  Future<void> pause() => _method.invokeMethod('pause');

  @override
  Future<void> togglePlay() => _state.playing
      ? _method.invokeMethod('pause')
      : _method.invokeMethod('play');

  @override
  Future<void> seek(Duration position) =>
      _method.invokeMethod('seek', position.inMilliseconds / 1000.0);

  @override
  Future<void> setRate(double rate) => _method.invokeMethod('setRate', rate);

  @override
  Future<void> setVolume(double volume) =>
      _method.invokeMethod('setVolume', volume);

  /// 切换音轨。
  ///
  /// ## ★★ 必须**校验 id**（真机实测的"没声音"事故）
  /// mpv 的 `aid` 只接受**整数**或 `auto`/`no`。
  /// 若传 `"1.0"`（曾因 C 层 `%.6f` 把 INT64 序列化成 `1.000000`），
  /// mpv 视为非法值 ⇒ 直接 `Audio: no audio` ⇒ **播放无声**。
  ///
  /// 真机证据（《复仇者联盟》）：
  /// ```
  /// 22:10:51.586  Audio --aid=1 ... truehd 8ch   ← 6 条音轨都在
  /// 22:10:51.672  Audio: no audio                 ← 0.086s 后被关掉
  /// ```
  ///
  /// ⇒ 这里做**最后一道防御**：非法的 id 一律不发给 mpv（宁可保持现状，
  ///    也不要把音频关掉 —— "没声音"比"音轨没切"严重得多）。
  @override
  Future<void> setAudioTrack(String id) async {
    final safe = _safeTrackId(id);
    if (safe == null) {
      debugPrint('[Kernel] 拒绝非法 aid "$id"（mpv 只接受整数/auto/no）'
          '—— 保持当前音轨，避免"没声音"');
      return;
    }
    await _method.invokeMethod('setAudioTrack', safe);
  }

  /// 校验并归一化 mpv 的轨 id。
  ///
  /// 允许：纯整数、`auto`、`no`。
  /// 返回 null = 非法（调用方应跳过，不要发给 mpv）。
  ///
  /// ⚠️ `1.0` 这种"浮点形状的整数"要**修好**而不是拒绝 ——
  /// 那是上游序列化问题，语义上就是 `1`。
  static String? _safeTrackId(String id) {
    final s = id.trim();
    if (s.isEmpty) return null;
    if (s == 'auto' || s == 'no') return s;
    // 纯整数
    if (int.tryParse(s) != null) return s;
    // 浮点形状但值是整数（"1.0" → "1"）——上游 bug，这里兜住
    final d = double.tryParse(s);
    if (d != null && d == d.roundToDouble()) return '${d.toInt()}';
    return null;
  }

  /// 加载外挂字幕（mpv 的 `sub-add`）。
  ///
  /// ## 为什么用 `sub-add`（mpv 官方手册 `command.rst`）
  /// ```
  /// sub-add <url> [<flags> [<title> [<lang>]]]
  ///   flags: select / auto / cached / remove / ...
  /// ```
  /// 外挂字幕不在容器里 ⇒ 必须显式添加。
  ///
  /// ## 为什么走通用的 `command` 通道（而不是新增 Kotlin 分支）
  /// `PlayerChannel.kt` 早有 `"command" -> MPVLib.command(args)` 通用分支
  /// ⇒ 不需要改原生层、不需要重新协商契约，直接发命令即可。
  /// （少一处原生改动 = 少一处可能忘记同步双内核的地方。）
  ///
  /// ## URL 里的 api_key 不能进日志（安全红线）
  /// 只打"添加了第几条 + title"，**绝不打 url**。
  @override
  Future<bool> addExternalSubtitle({
    required String url,
    String? title,
    String? language,
    bool select = false,
  }) async {
    if (url.isEmpty) return false;
    try {
      // ⚠️ `sub-add` 的参数顺序：url, flags, title, lang
      //    flags 为空时 mpv 会拒绝 → 显式给 `select` 或 `auto`
      final args = <String>[
        'sub-add',
        url,
        select ? 'select' : 'auto',
        if (title != null && title.isNotEmpty) title,
        if (language != null && language.isNotEmpty) language,
      ];
      await _method.invokeMethod('command', args);
      debugPrint('[Kernel] 外挂字幕已添加（title=${title ?? '-'}，'
          'select=$select）— url 含凭据故不打印');
      return true;
    } catch (e) {
      debugPrint('[Kernel] 外挂字幕添加失败: $e');
      return false;
    }
  }

  /// 移除全部外挂字幕（mpv 的 `sub-remove` 不带参数 = 移除全部）。
  ///
  /// ⚠️ **换集/换片必须调** —— 否则上一集的外挂字幕会留在播放器里，
  /// 用户看到"第 2 集却显示第 1 集的字幕"。
  @override
  Future<void> removeExternalSubtitles() async {
    try {
      await _method.invokeMethod('command', ['sub-remove']);
    } catch (e) {
      debugPrint('[Kernel] 移除外挂字幕失败（非致命）: $e');
    }
  }

  @override
  /// 切换字幕轨。与 [setAudioTrack] 同款校验（`sid` 也只接受整数/auto/no）。
  @override
  Future<void> setSubtitleTrack(String id) async {
    final safe = _safeTrackId(id);
    if (safe == null) {
      debugPrint('[Kernel] 拒绝非法 sid "$id"（mpv 只接受整数/auto/no）');
      return;
    }
    await _method.invokeMethod('setSubtitleTrack', safe);
  }

  // ---------------- 引擎能力：mpv 全都支持 ----------------
  //
  // 实现方式：**直接走 mpv 的 property 接口**，不新增 Kotlin 代码 ——
  // `PlayerChannel.kt` 已有通用的 `setProperty`（见其 when 分支），
  // 传 `name` + `value` 即可。这样双内核改造对 Android 侧是零风险。

  @override
  bool supports(EngineFeature feature) => switch (feature) {
        // mpv 原生提供这四组：画面滤镜、音频延迟、字幕延迟、硬/软解切换
        EngineFeature.videoFilters => true,
        EngineFeature.audioDelay => true,
        EngineFeature.subtitleDelay => true,
        EngineFeature.decodeMode => true,
        EngineFeature.externalSubtitle => true,
        EngineFeature.aspectMode => true,
      };

  /// 画面滤镜。
  ///
  /// ⚠️ 这是 **mpv 的 `brightness`/`contrast`/`saturation`/`hue` property**，
  ///    取值范围是 **−100…100**（与规格 §7.6 一致），不是 0–1。
  ///    mpv 文档里这几个默认值都是 0，作用在**视频输出阶段**（不改像素源）。
  ///
  /// 只下发非 null 的项 —— 避免"改亮度把用户设的对比度重置了"。
  @override
  Future<void> setVideoFilters({
    double? brightness,
    double? contrast,
    double? saturation,
    double? hue,
  }) async {
    // mpv 的 property 名与我们的参数名一一对应
    if (brightness != null) {
      await _setProperty('brightness', '${brightness.clamp(-100, 100)}');
    }
    if (contrast != null) {
      await _setProperty('contrast', '${contrast.clamp(-100, 100)}');
    }
    if (saturation != null) {
      await _setProperty('saturation', '${saturation.clamp(-100, 100)}');
    }
    if (hue != null) {
      await _setProperty('hue', '${hue.clamp(-180, 180)}');
    }
  }

  /// 音频延迟。mpv 的 `audio-delay` 单位是**秒**（浮点），正 = 音频延后。
  @override
  Future<void> setAudioDelay(Duration delay) =>
      _setProperty('audio-delay', _seconds(delay));

  /// 字幕延迟。mpv 的 `sub-delay` 单位是**秒**（浮点），正 = 字幕延后。
  @override
  Future<void> setSubtitleDelay(Duration delay) =>
      _setProperty('sub-delay', _seconds(delay));

  /// 解码方式。
  ///
  /// mpv 用 `hwdec` 控制硬解：
  ///   · 硬解 → `auto-safe`（自动挑安全的硬解后端）
  ///   · 软解 → `no`
  ///
  /// ⚠️ 用 `auto-safe` 而不是 `auto`：`auto` 会尝试所有后端（含不稳定的），
  ///    `auto-safe` 只挑已知安全的 —— 这是 mpv 官方推荐给普通播放器的值。
  ///
  /// ⚠️ 切换 `hwdec` **需要重新加载视频轨**才生效（mpv 的行为）：
  ///    这里用 `video-reload` 命令强制重载，否则用户切了没反应。
  @override
  Future<void> setDecodeMode(DecodeMode mode) async {
    final v = mode == DecodeMode.hardware ? 'auto-safe' : 'no';
    await _setProperty('hwdec', v);
    // 重载视频轨让 hwdec 生效（不重新打开文件，播放位置保持）
    await _method.invokeMethod('command', ['video-reload']);
  }

  /// 秒数的字符串形式（mpv property 是字符串接口）。
  ///
  /// 保留 3 位小数（毫秒精度）：0.1s 步进需要精确到 0.1，
  /// 而用户可能把延迟调到 0.1 的整数倍，3 位足够且不会出现浮点噪声。
  String _seconds(Duration d) =>
      (d.inMicroseconds / Duration.microsecondsPerSecond)
          .toStringAsFixed(3);

  Future<void> _setProperty(String name, String value) =>
      _method.invokeMethod('setProperty', {'name': name, 'value': value});

  @override
  KernelState get state => _state;

  @override
  KernelTracks get tracks => _tracks;

  @override
  KernelSelection get selection => _selection;

  @override
  Stream<KernelState> get stateStream => _stateController.stream;

  @override
  Stream<KernelTracks> get tracksStream => _tracksController.stream;

  @override
  Stream<KernelSelection> get selectionStream => _selectionController.stream;

  @override
  Stream<String> get errorStream => _errorController.stream;

  @override
  Stream<bool> get completedStream => _completedController.stream;

  @override
  Future<void> dispose() async {
    await _eventSub?.cancel();
    _eventSub = null;
    try {
      await _method.invokeMethod('dispose');
    } catch (_) {
      // 原生已销毁 / 通道已断：不该让退出流程炸掉
    }
    _textureId = null;
    await _stateController.close();
    await _tracksController.close();
    await _selectionController.close();
    await _errorController.close();
    await _completedController.close();
    await _videoSizeController.close();
  }
}
