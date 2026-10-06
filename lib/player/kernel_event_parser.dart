/// 内核事件解析（**两个内核共用**）。
///
/// ## 为什么必须共用一份
/// mpv 与 Media3 的事件形状**刻意保持一致**（Kotlin 侧按相同字段名输出）。
/// 若两边各写一份解析，任何一处改字段名都会造成"其中一边静默解析出空轨道"——
/// 现象是"看不到音轨/字幕"，**不报错、不崩溃**，极难发现。
///
/// 抽成共用函数后：
///   · 形状契约只有一个实现点
///   · 可以直接单测（喂各种 JSON，断言解析结果与容错）
library;

import 'dart:convert';

import 'kernel.dart';

/// 内核事件解析器（纯函数，无状态）。
abstract final class KernelEventParser {
  /// 解析事件 JSON。返回 null 表示"这条事件不需要处理/无法解析"。
  ///
  /// ⚠️ 调用方必须容忍 null：单条事件坏掉不该影响播放
  ///   （C 侧 JSON 转义若出问题，Dart 侧 `jsonDecode` 会抛，
  ///    不能让它把整个事件流打断）。
  static KernelEvent? parse(String raw) {
    if (raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return KernelEvent.fromMap(decoded);
    } catch (_) {
      return null;
    }
  }

  /// 解析 `tracks` 事件的轨道列表。
  ///
  /// 与 [parse] 分开是为了可单独测试（喂一份 tracks JSON 直接断言结果）。
  static KernelTracks parseTracks(Object? data) {
    try {
      final list = data is String ? jsonDecode(data) : data;
      if (list is! List) return const KernelTracks();
      final audio = <KernelTrack>[];
      final subs = <KernelTrack>[];
      for (final t in list.whereType<Map<String, dynamic>>()) {
        final track = KernelTrack(
          id: '${t['id']}',
          title: t['title'] as String?,
          language: t['lang'] as String?,
          codec: t['codec'] as String?,
          // mpv 的字段名就是 `demux-channels`（不是 `channels`）；
          // Media3 侧刻意沿用同一名字（见 Media3Channel.emitTracks）。
          channels: (t['demux-channels'] as num?)?.toInt(),
          // ★ `ff-index` 才是与 Emby `MediaStream.Index` 同源的编号。
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
}

/// 解析后的事件（判别式：由 [type] 决定哪些字段有意义）。
class KernelEvent {
  const KernelEvent({
    required this.type,
    this.state,
    this.tracks,
    this.propertyName,
    this.propertyData,
    this.endReason,
    this.logLevel,
    this.logText,
  });

  final String type;

  /// `type == 'state'`
  final KernelState? state;

  /// `type == 'tracks'`
  final KernelTracks? tracks;

  /// `type == 'property'`
  final String? propertyName;
  final Object? propertyData;

  /// `type == 'end-file'`：`'eof'` / `'error'` / 其他
  final String? endReason;

  /// `type == 'log'`
  final String? logLevel;
  final String? logText;

  /// 是否播放完成。
  bool get isCompleted => type == 'end-file' && endReason == 'eof';

  /// 是否有错误。
  bool get isError =>
      (type == 'end-file' && endReason == 'error') ||
      (type == 'log' && logLevel == 'error');

  /// 错误文案。
  String? get errorText => isError ? (logText ?? '播放失败（内核报错）') : null;

  /// 视频尺寸（`property` 事件里的 `video-size`）。
  (int width, int height)? get videoSize {
    if (type != 'property' || propertyName != 'video-size') return null;
    final d = propertyData;
    if (d is! Map) return null;
    final w = (d['width'] as num?)?.toInt() ?? 0;
    final h = (d['height'] as num?)?.toInt() ?? 0;
    return (w, h);
  }

  static KernelEvent fromMap(Map<String, dynamic> m) {
    final type = (m['type'] as String?) ?? '';
    switch (type) {
      case 'state':
        return KernelEvent(
          type: type,
          state: KernelState(
            position:
                Duration(milliseconds: (m['position'] as num?)?.toInt() ?? 0),
            duration:
                Duration(milliseconds: (m['duration'] as num?)?.toInt() ?? 0),
            buffer:
                Duration(milliseconds: (m['buffer'] as num?)?.toInt() ?? 0),
            playing: m['playing'] == true,
            buffering: m['buffering'] == true,
            rate: (m['rate'] as num?)?.toDouble() ?? 1.0,
          ),
        );
      case 'tracks':
        return KernelEvent(
          type: type,
          tracks: KernelEventParser.parseTracks(m['data']),
        );
      case 'property':
        return KernelEvent(
          type: type,
          propertyName: m['name'] as String?,
          propertyData: m['data'],
        );
      case 'end-file':
        return KernelEvent(type: type, endReason: m['reason'] as String?);
      case 'log':
        return KernelEvent(
          type: type,
          logLevel: m['level'] as String?,
          logText: m['text'] as String?,
        );
      default:
        return KernelEvent(type: type);
    }
  }
}
