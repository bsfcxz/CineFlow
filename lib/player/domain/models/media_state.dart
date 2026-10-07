/// 画面参数 + 音视频轨道状态模型。
///
/// 说明：规格要求"每个状态一个文件"（`video_state.dart` / `audio_state.dart`
/// / `subtitle_state.dart`）。本实现把它们放在**同一个文件**里，理由：
/// 三者的字段结构高度同构（都是 `tracks + activeId + 若干调节值`），
/// 拆三个文件会让"加一个共同字段"要改三处。
///
/// 若将来某一族显著膨胀（如字幕要加样式/位置/自定义字体），
/// 再单独拆出去 —— 那时拆分才有信息量。
library;

import '../player_constants.dart';

/// 字幕字号档（规格 §7.6）。
enum SubtitleFontSize {
  small('小', 0.8),
  medium('中', 1.0),
  large('大', 1.3),
  huge('超大', 1.6);

  const SubtitleFontSize(this.label, this.scale);
  final String label;
  final double scale;
}

/// 字幕编码（规格 §7.6）。
enum SubtitleEncoding {
  auto('自动'),
  utf8('UTF-8'),
  gbk('GBK'),
  big5('BIG5');

  const SubtitleEncoding(this.label);
  final String label;
}

/// 字幕轨道。
class SubtitleTrack {
  const SubtitleTrack({
    required this.id,
    required this.name,
    this.language,
    this.format,
    this.isExternal = false,
    this.filePath,
    this.isEmbedded = false,
  });

  final String id;
  final String name;
  final String? language;

  /// `srt` / `ass` / `vtt` / `ssa`。
  final String? format;

  /// 是否外挂（用户导入的文件）。
  final bool isExternal;

  /// 外挂字幕的本地路径。
  final String? filePath;

  /// 是否内封在容器里。
  final bool isEmbedded;

  /// 显示用副标题（原型：名称 + 格式）。
  String get subtitle {
    final parts = <String>[
      if (format != null && format!.isNotEmpty) format!.toUpperCase(),
      if (isExternal) '外挂' else if (isEmbedded) '内嵌',
    ];
    return parts.join(' · ');
  }

  /// 「关闭字幕」选项（规格 §7.6 字幕轨道列表里应有）。
  static const off = SubtitleTrack(id: 'no', name: '关闭字幕');

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SubtitleTrack &&
          other.id == id &&
          other.name == name &&
          other.isExternal == isExternal &&
          other.filePath == filePath;

  @override
  int get hashCode => Object.hash(id, name, isExternal, filePath);
}

/// 音轨。
class AudioTrack {
  const AudioTrack({
    required this.id,
    required this.name,
    this.language,
    this.codec,
    this.channels,
    this.isDefault = false,
  });

  final String id;
  final String name;
  final String? language;
  final String? codec;
  final int? channels;
  final bool isDefault;

  /// 显示用副标题（原型：编码 / 声道）。
  String get subtitle {
    final parts = <String>[
      if (codec != null && codec!.isNotEmpty) codec!,
      if (channels != null) _channelsLabel(channels!),
      if (language != null && language!.isNotEmpty) language!,
    ];
    return parts.join(' · ');
  }

  static String _channelsLabel(int n) => switch (n) {
        1 => '单声道',
        2 => '立体声',
        6 => '5.1',
        8 => '7.1',
        _ => '$n 声道',
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioTrack && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// 视频参数状态。
class VideoState {
  const VideoState({
    this.aspectMode = AspectMode.contain,
    this.decodeMode = DecodeMode.hardware,
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.hue = 0,
  });

  final AspectMode aspectMode;
  final DecodeMode decodeMode;

  /// 亮度 −100…+100（0 = 不调整）。
  final double brightness;
  final double contrast;
  final double saturation;

  /// 色相 −180…+180。
  final double hue;

  /// 是否所有画面参数都是中性值（用于"重置"按钮的可用态）。
  bool get isNeutral =>
      brightness == 0 && contrast == 0 && saturation == 0 && hue == 0;

  VideoState copyWith({
    AspectMode? aspectMode,
    DecodeMode? decodeMode,
    double? brightness,
    double? contrast,
    double? saturation,
    double? hue,
  }) =>
      VideoState(
        aspectMode: aspectMode ?? this.aspectMode,
        decodeMode: decodeMode ?? this.decodeMode,
        brightness: brightness ?? this.brightness,
        contrast: contrast ?? this.contrast,
        saturation: saturation ?? this.saturation,
        hue: hue ?? this.hue,
      );

  VideoState reset() => VideoState(
        aspectMode: aspectMode,
        decodeMode: decodeMode,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoState &&
          other.aspectMode == aspectMode &&
          other.decodeMode == decodeMode &&
          other.brightness == brightness &&
          other.contrast == contrast &&
          other.saturation == saturation &&
          other.hue == hue;

  @override
  int get hashCode => Object.hash(
      aspectMode, decodeMode, brightness, contrast, saturation, hue);
}

/// 音频状态。
class AudioState {
  const AudioState({
    this.tracks = const [],
    this.activeTrackId,
    this.delay = Duration.zero,
    this.volume = 0.7,
  });

  final List<AudioTrack> tracks;
  final String? activeTrackId;

  /// 音频延迟 −5s…+5s（规格 §7.6）。
  final Duration delay;

  /// 音量 0.0–1.0（原型默认 70%）。
  final double volume;

  AudioTrack? get activeTrack {
    if (activeTrackId == null) return null;
    for (final t in tracks) {
      if (t.id == activeTrackId) return t;
    }
    return null;
  }

  AudioState copyWith({
    List<AudioTrack>? tracks,
    String? activeTrackId,
    Duration? delay,
    double? volume,
  }) =>
      AudioState(
        tracks: tracks ?? this.tracks,
        activeTrackId: activeTrackId ?? this.activeTrackId,
        delay: delay ?? this.delay,
        volume: volume ?? this.volume,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioState &&
          other.activeTrackId == activeTrackId &&
          other.delay == delay &&
          other.volume == volume &&
          other.tracks.length == tracks.length;

  @override
  int get hashCode =>
      Object.hash(activeTrackId, delay, volume, tracks.length);
}

/// 字幕状态。
class SubtitleState {
  const SubtitleState({
    this.tracks = const [],
    this.activeTrackId,
    this.delay = Duration.zero,
    this.fontSize = SubtitleFontSize.medium,
    this.encoding = SubtitleEncoding.auto,
    this.isExternalLoading = false,
  });

  final List<SubtitleTrack> tracks;
  final String? activeTrackId;

  /// 字幕延迟 −5s…+5s（规格 §7.6）。
  final Duration delay;

  final SubtitleFontSize fontSize;
  final SubtitleEncoding encoding;

  /// 是否正在解析外挂字幕（解析要读文件 + 探测编码，可能慢）。
  final bool isExternalLoading;

  SubtitleTrack? get activeTrack {
    if (activeTrackId == null) return null;
    for (final t in tracks) {
      if (t.id == activeTrackId) return t;
    }
    return null;
  }

  SubtitleState copyWith({
    List<SubtitleTrack>? tracks,
    Object? activeTrackId = _unset,
    Duration? delay,
    SubtitleFontSize? fontSize,
    SubtitleEncoding? encoding,
    bool? isExternalLoading,
  }) =>
      SubtitleState(
        tracks: tracks ?? this.tracks,
        activeTrackId: identical(activeTrackId, _unset)
            ? this.activeTrackId
            : activeTrackId as String?,
        delay: delay ?? this.delay,
        fontSize: fontSize ?? this.fontSize,
        encoding: encoding ?? this.encoding,
        isExternalLoading: isExternalLoading ?? this.isExternalLoading,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SubtitleState &&
          other.activeTrackId == activeTrackId &&
          other.delay == delay &&
          other.fontSize == fontSize &&
          other.encoding == encoding &&
          other.isExternalLoading == isExternalLoading &&
          other.tracks.length == tracks.length;

  @override
  int get hashCode => Object.hash(activeTrackId, delay, fontSize, encoding,
      isExternalLoading, tracks.length);
}

/// `copyWith` 哨兵：允许把 `activeTrackId` 显式设为 null（关闭字幕）。
const Object _unset = Object();

/// 媒体信息（信息 Tab 用）。
///
/// 字段来自内核（mpv 的 `track-list` / Media3 的 `Format`），
/// 不同内核能提供的字段不完全一致 → **全部可空**，
/// UI 对缺失字段显示「—」而不是编造。
class MediaInfo {
  const MediaInfo({
    this.fileName = '',
    this.filePath,
    this.sizeBytes,
    this.duration,
    this.width,
    this.height,
    this.frameRate,
    this.videoCodec,
    this.videoBitrate,
    this.hdrFormat,
    this.audioCodec,
    this.audioChannels,
    this.audioSampleRate,
    this.container,
    this.kernelLabel,
    this.kernelReason,
  });

  final String fileName;
  final String? filePath;
  final int? sizeBytes;
  final Duration? duration;
  final int? width;
  final int? height;
  final double? frameRate;
  final String? videoCodec;
  final int? videoBitrate;
  final String? hdrFormat;
  final String? audioCodec;
  final int? audioChannels;
  final int? audioSampleRate;
  final String? container;

  /// 当前使用的**播放内核**名（如 `mpv 内核` / `Media3 内核`）。
  ///
  /// 为什么放进"媒体信息"：用户排查"播不了"时，第一件要知道的就是
  /// "这次用的哪个内核" —— 两个内核能力不同（见 `kernel_auto_select.dart`），
  /// 换一个往往就能播。
  final String? kernelLabel;

  /// 选这个内核的**理由**（自动适配的决策说明）。
  ///
  /// 显示出来是为了让用户理解"为什么这次不是我以为的那个内核"，
  /// 而不是面对一个不可解释的结果。
  final String? kernelReason;

  /// 分辨率文案（如 `3840 × 2160`）；缺失返回 null。
  String? get resolutionLabel =>
      (width == null || height == null) ? null : '$width × $height';

  MediaInfo copyWith({
    String? fileName,
    String? filePath,
    int? sizeBytes,
    Duration? duration,
    int? width,
    int? height,
    double? frameRate,
    String? videoCodec,
    int? videoBitrate,
    String? hdrFormat,
    String? audioCodec,
    int? audioChannels,
    int? audioSampleRate,
    String? container,
    String? kernelLabel,
    String? kernelReason,
  }) =>
      MediaInfo(
        fileName: fileName ?? this.fileName,
        filePath: filePath ?? this.filePath,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        duration: duration ?? this.duration,
        width: width ?? this.width,
        height: height ?? this.height,
        frameRate: frameRate ?? this.frameRate,
        videoCodec: videoCodec ?? this.videoCodec,
        videoBitrate: videoBitrate ?? this.videoBitrate,
        hdrFormat: hdrFormat ?? this.hdrFormat,
        audioCodec: audioCodec ?? this.audioCodec,
        audioChannels: audioChannels ?? this.audioChannels,
        audioSampleRate: audioSampleRate ?? this.audioSampleRate,
        container: container ?? this.container,
        kernelLabel: kernelLabel ?? this.kernelLabel,
        kernelReason: kernelReason ?? this.kernelReason,
      );
}
