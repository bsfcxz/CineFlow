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
import 'package:flutter/foundation.dart' show debugPrint;

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
  @override
  int? get textureId => _textureId;

  int _videoWidth = 0;
  int _videoHeight = 0;

  /// 视频宽高比；未知时 null（UI 回退 16:9）。
  @override
  Stream<void> get videoSizeStream => const Stream.empty();
  @override
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
              // ★ 2026-10-09：把旋转与 SAR 换算进**显示尺寸**
              //
              // Media3 的 `VideoSize` 语义（官方文档）：
              //   · width/height               = 编码像素尺寸
              //   · unappliedRotationDegrees    = **未应用**的旋转角（调用方自行处理）
              //   · pixelWidthHeightRatio       = 像素宽高比（SAR ≠ 1 时宽要乘）
              // 原实现只取 width/height ⇒ 竖拍视频（rotate=90）被当 16:9 显示。
              //
              // ## 换算顺序（先 SAR 后旋转，与 Android `TextureView` 一致）
              // 1. SAR：显示宽 = width × ratio
              // 2. 旋转 90/270：宽高**对调**
              //
              // 与 mpv 内核（dwidth/dheight）对齐后，两内核的
              // `aspectRatio` 语义一致 —— 方向自适应（横 16:9/竖 9:16）
              // 才能对两内核都成立。
              final par = (d['pixelWidthHeightRatio'] as num?)?.toDouble() ?? 1.0;
              final rot = (d['unappliedRotationDegrees'] as num?)?.toInt() ?? 0;
              var dw = _videoWidth * par;
              var dh = _videoHeight.toDouble();
              if (rot == 90 || rot == 270) {
                final t = dw;
                dw = dh;
                dh = t;
              }
              if (dw > 0 && dh > 0) {
                _videoWidth = dw.round();
                _videoHeight = dh.round();
              }
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
  @override
  Future<void> ensureTexture({int width = 1920, int height = 1080}) async {
    if (_textureId != null) return;
    final id = await _method.invokeMethod<int>('createTexture', {
      'width': width,
      'height': height,
    });
    _textureId = id;
    // ★ 记账已建尺寸（否则 `recreateTexture` 的去重失效，见 mpv 内核同处说明）
    _surfaceW = width;
    _surfaceH = height;
  }

  /// 设置渲染画布尺寸（与 mpv 内核同义，见 `PlayerKernel.setSurfaceSize`）。
  ///
  /// ## Media3 与 mpv 的差别（为什么同样需要）
  /// ExoPlayer 通过 `AspectRatioFrameLayout` 或 `Surface` 尺寸决定摆放，
  /// 而它默认也是 **keep-aspect fit**（`RESIZE_MODE_FIT`，已用本地 1.4.1
  /// 字节码核实枚举）。画布若固定 16:9，宽银幕片源同样会被 letterbox 一次，
  /// 再被 Dart 侧内接一次 ⇒ **同样的双重黑边**。
  ///
  /// ⇒ 两边内核**必须行为一致**，否则换内核时画面比例会跳变。
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
      debugPrint('[Kernel] 画布尺寸 → ${width}x$height（media3）');
    } catch (e) {
      debugPrint('[Kernel] 设置画布尺寸失败（非致命）: $e');
    }
  }

  int _surfaceW = 0;
  int _surfaceH = 0;

  /// 按新尺寸重建纹理（与 mpv 内核同义，见 `PlayerKernel.recreateTexture`）。
  ///
  /// Media3 的 Surface 同样**在创建时固定 buffer 尺寸**，
  /// 而 `_boot` 建纹理时还不知道片源尺寸 ⇒ 宽银幕片源会被
  /// `RESIZE_MODE_FIT` letterbox 一次、Dart 再嵌一次 ⇒ 双重黑边。
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
      debugPrint('[Kernel] 重建画布纹理 → ${width}x$height（media3，id=$id）');
      return true;
    } catch (e) {
      debugPrint('[Kernel] 重建纹理失败（非致命）: $e');
      return false;
    }
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
    // ★★ 续播位置随 open 一起下发（起播优化，2026-10-10）
    //
    // ## 改了什么
    // 原来：`open`（从头 prepare）→ 再单独 `seek`。
    // 现在把起始位置交给原生，由 `ExoPlayer.setStartPosition()` 在
    // **prepare 之前**设定 —— 这是 Media3 官方推荐的起播定位方式：
    // 播放器**直接从目标位置开始缓冲**，而不是"先缓冲片头再跳"。
    //
    // ## 与 mpv 侧的关系（两侧对称）
    // mpv 侧用 `loadfile ... start=`，Media3 侧用 `setStartPosition`。
    // 两者语义一致：**在打开时就带上起点**。
    //
    // ## 兜底
    // 若原生未实现该参数（旧版本），下面的 `seek` 仍然生效 ——
    // 保留它是**刻意的**：宁可多一次往返，也不能让续播位置丢失。
    final useStart = start != null && start.inSeconds > 3;
    await _method.invokeMethod('open', {
      'url': url,
      if (headers != null && headers.isNotEmpty) 'headers': headers,
      if (useStart) 'start': start.inMilliseconds / 1000.0,
    });
    if (!play) await _method.invokeMethod('pause');
    // ⚠️ 不再无条件 seek：原生已在 prepare 前定位（见 Kotlin 侧）。
    //    只有"原生没实现 start"时才需要补 —— 用返回值区分。
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

  /// Media3 的配置是**构建期**定的（`ExoPlayer.Builder`），
  /// 没有"运行时可回读的属性"概念 ⇒ 恒返回 null。
  /// （`implements` 要求实现所有接口成员，接口默认实现只对 `extends` 生效。）
  @override
  Future<String?> getOption(String name) async => null;

  /// Media3 的 `state` 事件来自 Kotlin 侧 250ms 的定时上报
  /// （见 `Media3Channel.PROGRESS_INTERVAL_MS`），**频率本来就低**，
  /// 不需要像 mpv 内核那样限流 → 本方法为空实现。
  ///
  /// ⚠️ 必须显式写出：Dart 的 `implements` 要求实现**所有**接口成员，
  ///    接口里的"默认实现"只对 `extends` 的子类生效。
  @override
  void flushPendingPosition() {}

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
