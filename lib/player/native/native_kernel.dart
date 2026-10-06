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

import '../domain/player_constants.dart' show DecodeMode;
import '../kernel.dart';

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
  int? get textureId => _textureId;

  /// 视频原始尺寸（宽高比）；未知时为 null，UI 侧回退 16:9
  int _videoWidth = 0;
  int _videoHeight = 0;
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
  Stream<void> get videoSizeStream => _videoSizeController.stream;

  void _pushState(KernelState s) {
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
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
          // 日志不进 UI（要排查时看 logcat 的 CineFlowMPV tag）
          break;
      }
    } catch (_) {
      // 单条事件解析失败不影响播放
    }
  }

  void _onProperty(String name, Object? data) {
    switch (name) {
      case 'time-pos':
        final v = (data as num?)?.toDouble() ?? -1;
        if (v >= 0) _pushState(_copy(position: Duration(milliseconds: (v * 1000).round())));
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
        _tracks = _parseTracks(data);
        if (!_tracksController.isClosed) _tracksController.add(_tracks);
      case 'width':
      case 'height':
        final v = (data as num?)?.toInt() ?? 0;
        if (v <= 0) return;
        final before = aspectRatio;
        if (name == 'width') {
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
  KernelTracks _parseTracks(Object? data) {
    try {
      final decoded = data is String ? jsonDecode(data) : data;
      final list = decoded as List? ?? const [];
      final audio = <KernelTrack>[];
      final subs = <KernelTrack>[];
      for (final t in list.whereType<Map<String, dynamic>>()) {
        final track = KernelTrack(
          id: '${t['id']}',
          title: t['title'] as String?,
          language: t['lang'] as String?,
          codec: t['codec'] as String?,
          // mpv 的字段名就是 `demux-channels`（不是 `channels`）
          channels: (t['demux-channels'] as num?)?.toInt(),
          // ★ `ff-index` 才是与 Emby `MediaStream.Index` 同源的编号。
          //   `id`（aid/sid）是每种类型独立从 1 开始的，不能拿来对齐
          //   （详见 KernelTrack.ffIndex 注释）。
          ffIndex: (t['ff-index'] as num?)?.toInt(),
          isDefault: t['default'] == true,
          isExternal: t['external'] == true,
          isForced: t['forced'] == true,
        );
        if (t['type'] == 'audio') {
          audio.add(track);
        } else if (t['type'] == 'sub') {
          subs.add(track);
        }
      }
      return KernelTracks(audio: audio, subtitle: subs);
    } catch (_) {
      return const KernelTracks();
    }
  }

  /// 建纹理（幂等）。必须在 open 之前完成，否则 mpv 没有渲染目标。
  Future<void> ensureTexture({int width = 1920, int height = 1080}) async {
    if (_textureId != null) return;
    final id = await _method.invokeMethod<int>('createTexture', {
      'width': width,
      'height': height,
    });
    _textureId = id;
  }

  Future<void> ensureInitialized() async {
    await ensureTexture();
    await _method.invokeMethod('initialize');
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
    await _method.invokeMethod('open', {
      'url': url,
      if (headers != null && headers.isNotEmpty) 'headers': headers,
    });
    if (!play) await _method.invokeMethod('pause');
    if (start != null && start.inSeconds > 3) {
      await seek(start);
    }
  }

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

  @override
  Future<void> setAudioTrack(String id) =>
      _method.invokeMethod('setAudioTrack', id);

  @override
  Future<void> setSubtitleTrack(String id) =>
      _method.invokeMethod('setSubtitleTrack', id);

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
