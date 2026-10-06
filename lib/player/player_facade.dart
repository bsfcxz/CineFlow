/// 播放器门面 —— 对 player_page / pan115_player 暴露与 media_kit `Player`
/// 一致的 API 面，底层转发到 [PlayerKernel]（当前唯一实现：原生 mpv）。
///
/// ## 这一层的意义
///
/// 迁移前 `player_page.dart` 直接 `new Player()`（media_kit），
/// 于是"换内核"= 改 2000 行播放器页。抽出内核接口 + 本门面后：
///   - UI / 手势 / 弹幕 / 进度上报**一行不动**（只认门面的 API 面）；
///   - 换内核 = 新增一个 [PlayerKernel] 实现 + 改本文件一行工厂。
///
/// 成员名刻意与 media_kit 对齐（`state` / `stream` / `open` / `setAudioTrack`
/// 等），就是为了让 `player_page.dart` 的改动量降到最低——这也让"迁移=不改 UI"
/// 这个承诺可验证，而不是一句口号。
library;

import 'dart:async';

import 'package:flutter/widgets.dart' show BoxFit, SizedBox, Widget;

import 'kernel.dart';
import 'native/native_kernel.dart';
import 'native/native_video_view.dart';

// ---------- 门面轨道类型（成员名与 media_kit Track 一致） ----------

class FacadeAudioTrack {
  final String id;
  final String? title;
  final String? language;

  /// 编解码器与声道数 —— 多音轨时靠它们区分（用户要求"显示出名称"）。
  /// 实测常见：`aac 2ch` vs `eac3 6ch`，两者 title 都为空。
  final String? codec;
  final int? channels;

  /// **ffmpeg 全局流索引**（mpv `ff-index`）—— 与 Emby `MediaStream.Index` 同源。
  ///
  /// ⚠️ **不要用 `id` 去匹配 Emby 的 `Index`**：`id`（`aid`）是每种类型
  /// 独立从 1 开始编号的，而 Emby `Index` 是 ffmpeg 全局索引。
  /// 典型 MKV 下数字碰巧相同，多字幕/流顺序不同时就会**错位 → 切错轨**。
  ///
  /// 详见 `kernel.dart` 的 `KernelTrack.ffIndex` 注释。
  final int? ffIndex;

  const FacadeAudioTrack({
    required this.id,
    this.title,
    this.language,
    this.codec,
    this.channels,
    this.ffIndex,
  });
}

class FacadeSubtitleTrack {
  final String id;
  final String? title;
  final String? language;

  /// 外挂 / 强制标记（用户要求显示"中字、双语、繁体"这类区分信息）
  final bool isExternal;
  final bool isForced;

  /// 见 [FacadeAudioTrack.ffIndex]
  final int? ffIndex;

  const FacadeSubtitleTrack({
    required this.id,
    this.title,
    this.language,
    this.isExternal = false,
    this.isForced = false,
    this.ffIndex,
  });

  /// 对齐 media_kit 的 `SubtitleTrack.no()`：关闭字幕
  static const no = FacadeSubtitleTrack(id: 'no');
}

class FacadeTrack {
  final FacadeAudioTrack audio;
  final FacadeSubtitleTrack subtitle;

  const FacadeTrack({required this.audio, required this.subtitle});
}

class FacadeTracks {
  final List<FacadeAudioTrack> audio;
  final List<FacadeSubtitleTrack> subtitle;

  const FacadeTracks({required this.audio, required this.subtitle});
}

// ---------- 门面状态 ----------

class FacadePlayerState {
  final Duration position;
  final Duration duration;
  final Duration buffer;
  final bool playing;
  final bool buffering;
  final double rate;
  final double volume;
  final bool completed;
  final FacadeTrack track;
  final FacadeTracks tracks;

  const FacadePlayerState({
    required this.position,
    required this.duration,
    required this.buffer,
    required this.playing,
    required this.buffering,
    required this.rate,
    required this.volume,
    required this.completed,
    required this.track,
    required this.tracks,
  });
}

// ---------- 门面流容器 ----------

class FacadePlayerStream {
  final Stream<Duration> position;
  final Stream<Duration> duration;
  final Stream<Duration> buffer;
  final Stream<bool> playing;
  final Stream<bool> buffering;
  final Stream<double> rate;
  final Stream<bool> completed;
  final Stream<FacadeTrack> track;
  final Stream<FacadeTracks> tracks;
  final Stream<String> error;

  const FacadePlayerStream({
    required this.position,
    required this.duration,
    required this.buffer,
    required this.playing,
    required this.buffering,
    required this.rate,
    required this.completed,
    required this.track,
    required this.tracks,
    required this.error,
  });
}

// ---------- 门面实现 ----------

class PlayerFacade {
  PlayerFacade(this._kernel) {
    _subs.addAll([
      _kernel.stateStream.listen((s) {
        _position = s.position;
        _duration = s.duration;
        _buffer = s.buffer;
        _playing = s.playing;
        _buffering = s.buffering;
        _rate = s.rate;
        _volume = s.volume;
        // 换片后 completed 必须复位，否则上一集播完的状态会带到下一集
        if (s.position == Duration.zero && !s.playing) _completed = false;
        _stateController.add(this);
      }),
      _kernel.tracksStream.listen((t) {
        _audioTracks = [
          for (final a in t.audio)
            FacadeAudioTrack(
                id: a.id,
                title: a.title,
                language: a.language,
                // ★ 必须带上 codec/channels：多音轨时 title 常为空，
                //   只传 title/language 会让界面上出现几条一模一样的"音轨"。
                codec: a.codec,
                channels: a.channels,
                // ffIndex 是与服务端 MediaStream.Index 对齐的唯一键
                ffIndex: a.ffIndex),
        ];
        _subtitleTracks = [
          for (final sub in t.subtitle)
            FacadeSubtitleTrack(
              id: sub.id,
              title: sub.title,
              language: sub.language,
              isExternal: sub.isExternal,
              isForced: sub.isForced,
              ffIndex: sub.ffIndex,
            ),
        ];
        _tracksController.add(
          FacadeTracks(audio: _audioTracks, subtitle: _subtitleTracks),
        );
      }),
      _kernel.selectionStream.listen((sel) {
        _selection = sel;
        _trackController.add(
          FacadeTrack(
            audio: FacadeAudioTrack(id: sel.audioId),
            subtitle: FacadeSubtitleTrack(id: sel.subtitleId),
          ),
        );
      }),
      _kernel.errorStream.listen((e) {
        if (e.isNotEmpty) _errorController.add(e);
      }),
      _kernel.completedStream.listen((done) {
        _completed = done;
        _completedController.add(done);
      }),
      if (_kernel is NativeKernel)
        _kernel.videoSizeStream.listen((_) {
          // 只转发"尺寸变了"这个信号，Dart 侧重新 setState 取新宽高比
          _videoSizeController.add(null);
        }),
    ]);
  }

  final PlayerKernel _kernel;
  final _subs = <StreamSubscription>[];

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffer = Duration.zero;
  bool _playing = false;
  bool _buffering = false;
  double _rate = 1.0;
  double _volume = 100;
  bool _completed = false;

  List<FacadeAudioTrack> _audioTracks = const [];
  List<FacadeSubtitleTrack> _subtitleTracks = const [];
  KernelSelection _selection =
      const KernelSelection(audioId: 'auto', subtitleId: 'auto');

  final _stateController = StreamController<PlayerFacade>.broadcast();
  final _tracksController = StreamController<FacadeTracks>.broadcast();
  final _trackController = StreamController<FacadeTrack>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _completedController = StreamController<bool>.broadcast();
  final _videoSizeController = StreamController<void>.broadcast();

  /// 原生内核
  NativeKernel? get nativeKernel => _kernel is NativeKernel ? _kernel : null;

  /// 视频尺寸变化（UI 用它 setState 重算宽高比）
  Stream<void> get videoSizeStream => _videoSizeController.stream;

  String get engine => _kernel.engine;

  /// 当前状态快照（字段面 = media_kit `Player.state` 的使用面）
  FacadePlayerState get state => FacadePlayerState(
        position: _position,
        duration: _duration,
        buffer: _buffer,
        playing: _playing,
        buffering: _buffering,
        rate: _rate,
        volume: _volume,
        completed: _completed,
        track: FacadeTrack(
          audio: FacadeAudioTrack(id: _selection.audioId),
          subtitle: FacadeSubtitleTrack(id: _selection.subtitleId),
        ),
        tracks: FacadeTracks(audio: _audioTracks, subtitle: _subtitleTracks),
      );

  /// 流容器（字段面 = media_kit `Player.stream` 的使用面）
  FacadePlayerStream get stream => FacadePlayerStream(
        position: _positionStream,
        duration: _durationStream,
        buffer: _bufferStream,
        playing: _playingStream,
        buffering: _bufferingStream,
        rate: _rateStream,
        completed: _completedController.stream,
        track: _trackController.stream,
        tracks: _tracksController.stream,
        error: _errorController.stream,
      );

  /// 每个字段一条派生流。
  ///
  /// 先 yield 当前值（对齐 media_kit 的"订阅即拿到现状"语义），
  /// 之后跟随 state 变化。注意**去重**：state 每变一次就广播，
  /// 不去重会让 200ms 一次的状态推送变成几十倍的无谓 setState。
  Stream<T> _mapState<T>(T Function() pick) async* {
    var last = pick();
    yield last;
    await for (final _ in _stateController.stream) {
      final v = pick();
      if (v == last) continue;
      last = v;
      yield v;
    }
  }

  late final _positionStream = _mapState(() => _position);
  late final _durationStream = _mapState(() => _duration);
  late final _bufferStream = _mapState(() => _buffer);
  late final _playingStream = _mapState(() => _playing);
  late final _bufferingStream = _mapState(() => _buffering);
  late final _rateStream = _mapState(() => _rate);

  /// 打开媒体。[headers] 是 115 网盘的生命线（UA 绑定 + download_token Cookie）。
  Future<void> openUrl(
    String url, {
    bool play = true,
    Duration? start,
    Map<String, String>? headers,
  }) =>
      _kernel.open(url, play: play, start: start, headers: headers);

  Future<void> play() => _kernel.play();

  Future<void> pause() => _kernel.pause();

  Future<void> playOrPause() => _kernel.togglePlay();

  Future<void> seek(Duration position) => _kernel.seek(position);

  Future<void> setRate(double rate) => _kernel.setRate(rate);

  Future<void> setVolume(double volume) => _kernel.setVolume(volume);

  Future<void> setAudioTrack(FacadeAudioTrack t) => _kernel.setAudioTrack(t.id);

  Future<void> setSubtitleTrack(FacadeSubtitleTrack t) =>
      _kernel.setSubtitleTrack(t.id);

  /// 视频输出层。
  ///
  /// 原生内核返回 `Texture`；这是它与 media_kit `Video(controller:)` 的对应物。
  /// 调用方把它放进 Stack 即可，弹幕/手势/控制层照旧叠上去。
  Widget videoView({required BoxFit fit, int tick = 0}) {
    final nk = nativeKernel;
    if (nk == null) return const SizedBox.shrink();
    return NativeVideoView(kernel: nk, fit: fit, tick: tick);
  }

  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _stateController.close();
    await _tracksController.close();
    await _trackController.close();
    await _errorController.close();
    await _completedController.close();
    await _videoSizeController.close();
    await _kernel.dispose();
  }
}

/// 播放器工厂：当前只有原生 mpv 一个实现（media_kit 已按 K4 移除）。
Future<PlayerFacade> createPlayerFacade() async {
  final kernel = NativeKernel();
  await kernel.ensureInitialized();
  return PlayerFacade(kernel);
}
