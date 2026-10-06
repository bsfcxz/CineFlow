/// Media3（androidx.media3 / ExoPlayer）内核 —— 双内核的第二实现。
///
/// ## 与 [NativeKernel] 的关系
/// 两者 `implements PlayerKernel`，Dart 侧**接口完全一致**；
/// 差异只体现在 [supports] 返回的能力集合上。
///
/// ```dart
/// final kernel = PlayerKernelFactory.create(KernelType.media3);
/// if (kernel.supports(EngineFeature.videoFilters)) { /* 显示滤镜滑块 */ }
/// ```
///
/// ## ⚠️ 本内核**如实声明**不支持的能力（这是设计的重点）
///
/// | 能力 | mpv | Media3 | 原因 |
/// |---|---|---|---|
/// | 画面滤镜 | ✅ | ❌ | 需自叠 GL 层做像素处理，本内核不做 |
/// | 音频/字幕延迟 | ✅ | ❌ | Media3 无等价属性（mpv 有 `audio-delay`/`sub-delay`） |
/// | 运行中切硬/软解 | ✅ | ❌ | 需重建 `RenderersFactory`，无法热切 |
///
/// **"如实声明"比"假装支持"重要**：UI 会据此把入口置灰，
/// 用户看到"此内核不支持"而不是"点了没反应" —— 后者会让用户以为功能坏了。
/// （本项目已踩过类似坑：`default_rate` 有读无写，用户设了倍速却没生效。）
///
/// ## 事件形状与 mpv 内核**完全一致**
/// 两者共用 Dart 侧的状态解析（`KernelState` / `KernelTracks`）。
/// Kotlin 侧 `Media3Channel.emitTracks` 刻意按 mpv 的字段名输出
/// （`demux-channels` / `ff-index` …），否则其中一边会静默解析出空轨道。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../domain/player_constants.dart' show DecodeMode;
import '../kernel.dart';
import '../kernel_event_parser.dart';

class Media3Kernel implements PlayerKernel {
  Media3Kernel() {
    _method = const MethodChannel('cineflow/media3');
    _event = const EventChannel('cineflow/media3/events');
    _eventSub = _event.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object e, StackTrace st) {
        _errorController.add('Media3 事件错误：$e');
      },
    );
  }

  late final MethodChannel _method;
  late final EventChannel _event;
  StreamSubscription? _eventSub;

  int? _textureId;
  int? get textureId => _textureId;

  int _videoWidth = 0;
  int _videoHeight = 0;

  /// 视频宽高比；未知时 null（UI 回退 16:9）。
  double? get aspectRatio => (_videoWidth > 0 && _videoHeight > 0)
      ? _videoWidth / _videoHeight
      : null;

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

  void _pushState(KernelState s) {
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  /// 事件解析 —— 形状与 mpv 内核一致（见文件头说明）。
  void _onEvent(dynamic raw) {
    if (raw is! String || raw.isEmpty) return;
    try {
      final m = jsonDecodeMap(raw);
      switch (m['type']) {
        case 'state':
          _pushState(KernelState(
            position: Duration(milliseconds: (m['position'] as num?)?.toInt() ?? 0),
            duration: Duration(milliseconds: (m['duration'] as num?)?.toInt() ?? 0),
            buffer: Duration(milliseconds: (m['buffer'] as num?)?.toInt() ?? 0),
            playing: m['playing'] == true,
            buffering: m['buffering'] == true,
            rate: (m['rate'] as num?)?.toDouble() ?? 1.0,
          ));
        case 'tracks':
          // 共用解析器（与 mpv 内核同一份）—— 见 kernel_event_parser.dart
          // 的说明：两边各写一份解析，任何一处改字段名都会造成
          // "其中一边静默解析出空轨道"（不报错、不崩溃，极难发现）。
          _tracks = KernelEventParser.parseTracks(m['data']);
          if (!_tracksController.isClosed) _tracksController.add(_tracks);
        case 'property':
          if (m['name'] == 'video-size') {
            final d = m['data'];
            if (d is Map<String, dynamic>) {
              _videoWidth = (d['width'] as num?)?.toInt() ?? 0;
              _videoHeight = (d['height'] as num?)?.toInt() ?? 0;
            }
          }
        case 'end-file':
          if (m['reason'] == 'eof') _completedController.add(true);
        case 'log':
          if (m['level'] == 'error') {
            _errorController.add((m['text'] as String?) ?? 'Media3 播放错误');
          }
      }
    } catch (_) {
      // 单条事件坏掉不影响播放（与 mpv 内核同策略）
    }
  }

  // ---------------- PlayerKernel 实现 ----------------

  @override
  String get engine => 'media3';

  /// 走 Flutter 纹理（不用 PlatformView）→ 与 mpv 内核一致，返回 null。
  @override
  String? get viewType => null;

  @override
  bool supports(EngineFeature feature) => switch (feature) {
        // Media3 无等价属性 —— 如实声明不支持
        EngineFeature.videoFilters => false,
        EngineFeature.audioDelay => false,
        EngineFeature.subtitleDelay => false,
        EngineFeature.decodeMode => false,
        // 这两个 Media3 原生支持
        EngineFeature.externalSubtitle => true,
        EngineFeature.aspectMode => true,
      };

  /// 建纹理（幂等）。Media3 也走 `setVideoSurface(Flutter Texture)`。
  Future<void> ensureTexture({int width = 1920, int height = 1080}) async {
    if (_textureId != null) return;
    final id = await _method.invokeMethod<int>('createTexture', {
      'width': width,
      'height': height,
    });
    _textureId = id;
  }

  @override
  Future<void> open(
    String url, {
    bool play = true,
    Duration? start,
    Map<String, String>? headers,
  }) async {
    await ensureTexture();
    _videoWidth = 0;
    _videoHeight = 0;
    await _method.invokeMethod('open', {
      'url': url,
      if (headers != null && headers.isNotEmpty) 'headers': headers,
    });
    if (!play) await _method.invokeMethod('pause');
    if (start != null && start.inSeconds > 3) await seek(start);
  }

  @override
  Future<void> play() => _method.invokeMethod('play');

  @override
  Future<void> pause() => _method.invokeMethod('pause');

  @override
  Future<void> togglePlay() =>
      _state.playing ? pause() : play();

  @override
  Future<void> seek(Duration position) =>
      _method.invokeMethod('seek', position.inMilliseconds / 1000.0);

  @override
  Future<void> setRate(double rate) => _method.invokeMethod('setRate', rate);

  /// ⚠️ 传 0–100（与 Dart 侧统一），Kotlin 侧除以 100。
  @override
  Future<void> setVolume(double volume) =>
      _method.invokeMethod('setVolume', volume);

  @override
  Future<void> setAudioTrack(String id) async {
    await _method.invokeMethod('setAudioTrack', id);
    _selection = KernelSelection(audioId: id, subtitleId: _selection.subtitleId);
    if (!_selectionController.isClosed) _selectionController.add(_selection);
  }

  @override
  Future<void> setSubtitleTrack(String id) async {
    await _method.invokeMethod('setSubtitleTrack', id);
    _selection = KernelSelection(audioId: _selection.audioId, subtitleId: id);
    if (!_selectionController.isClosed) _selectionController.add(_selection);
  }

  // ---------------- 能力受限的项：不抛异常，静默忽略 ----------------
  //
  // UI 已据 supports() 禁用入口；万一有代码路径直接调用，
  // 也不该让播放中断（健壮性 > 严格性）。

  @override
  Future<void> setVideoFilters({
    double? brightness,
    double? contrast,
    double? saturation,
    double? hue,
  }) async {
    // Media3 无画面滤镜能力 —— 调用被忽略（不是错误）
  }

  @override
  Future<void> setAudioDelay(Duration delay) async {}

  @override
  Future<void> setSubtitleDelay(Duration delay) async {}

  @override
  Future<void> setDecodeMode(DecodeMode mode) async {}

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
    } catch (_) {}
    await _stateController.close();
    await _tracksController.close();
    await _selectionController.close();
    await _errorController.close();
    await _completedController.close();
  }
}

/// 从 JSON 字符串解析 map（与 `native_kernel` 同样的容错）。
Map<String, dynamic> jsonDecodeMap(String raw) {
  final decoded = jsonDecode(raw);
  return decoded is Map<String, dynamic> ? decoded : const {};
}
