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

import 'package:flutter/foundation.dart' show debugPrint;

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
    final list = data is String ? _tryDecode(data) : data;
    if (list is! List) return const KernelTracks();
    final audio = <KernelTrack>[];
    final subs = <KernelTrack>[];
    final types = <String>{};
    // ★★ 逐条 try/catch（**不再让一条坏轨道毁掉整个列表**）
    //
    // ## 原来的 bug（真机实测抓到的"看不到音轨/字幕"）
    // 整个 for 循环包在一个 try 里，任一条轨道取值抛异常
    // ⇒ **整个列表变成空**（`catch` 返回 `const KernelTracks()`）。
    // 真机证据（《复仇者联盟》MKV，16 条轨道）：
    // ```
    // [Kernel] track-list 事件：data 类型=List<dynamic>，长度=16
    //                            → 解析出 音频0/字幕0     ← 全空
    // ```
    // 而 mpv 侧明明有 `Audio --aid=1` + 13 条 `Subs --sid=*`。
    // 服务端也有 6 音频 / 8 字幕。⇒ 是**解析**把它吃掉了。
    //
    // 危险字段（服务端/内核给的类型不保证）：
    // · `title`/`lang`/`codec` —— 可能是数字（如 `lang: 0`）
    // · `demux-channels` —— 可能是字符串（如 `"6"`）
    // ⇒ 一律用宽容转换（`_asString` / `_asInt`），且**逐条独立兜底**。
    for (final t in list.whereType<Map<String, dynamic>>()) {
      try {
        types.add('${t['type']}');
        final track = KernelTrack(
          // ★★ `id` 必须归一化成**整数字符串**（真机实测的"没声音"回归）
          //
          // ## 为什么不能用 `'${t['id']}'`
          // mpv 的 track-list 里 `id` 是 **INT64**，而 C 层曾把 INT64
          // 交给 `%.6f` 序列化 ⇒ JSON 里是 `1.000000` ⇒ Dart 得到 `"1.0"`。
          // 而 **mpv 的 `aid`/`sid` 只接受整数/`auto`/`no`** ——
          // 传 `"1.0"` 是非法值，mpv 直接 `Audio: no audio`（**播放无声**）。
          //
          // 真机时序（《复仇者联盟》）：
          // ```
          // 22:10:51.586  Audio --aid=1 ... truehd 8ch   ← 6 条音轨都在
          // 22:10:51.672  Audio: no audio                 ← 0.086s 后被关掉
          // ```
          //
          // ## 分层防御（C 层已修，这里仍要归一化）
          // C 层 `sb_json_int` 已改成输出真整数；但 Dart 侧**不能依赖**
          // 上游一定正确（Media3 侧也走同一解析器，且未来可能换实现）
          // ⇒ 在解析处统一归一化，是"契约收口"。
          id: _normalizeTrackId(t['id']),
          title: _asString(t['title']),
          language: _asString(t['lang']),
          codec: _asString(t['codec']),
          // mpv 的字段名就是 `demux-channels`（不是 `channels`）；
          // Media3 侧刻意沿用同一名字（见 Media3Channel.emitTracks）。
          channels: _asInt(t['demux-channels']),
          // ★ `ff-index` 才是与 Emby `MediaStream.Index` 同源的编号。
          ffIndex: _asInt(t['ff-index']),
          isDefault: t['default'] == true,
          isExternal: t['external'] == true,
          isForced: t['forced'] == true,
        );
        if (t['type'] == 'audio') {
          audio.add(track);
        } else if (t['type'] == 'sub') {
          subs.add(track);
        }
      } catch (e) {
        // 单条坏轨道跳过，**不影响其余**（并留下可查证据）
        debugPrint('[KernelParser] 单条轨道解析失败（已跳过）: $e');
      }
    }
    // 诊断：把见过的 type 值打出来 —— 长度对但解析为 0 时，
    // 一眼就能看出"type 字段不是预期的 audio/sub"
    if (audio.isEmpty && subs.isEmpty && list.isNotEmpty) {
      debugPrint('[KernelParser] 解析出 0 条轨道，'
          '实际见到的 type 值 = $types（共 ${list.length} 条）');
    }
    return KernelTracks(audio: audio, subtitle: subs);
  }

  static Object? _tryDecode(String s) {
    try {
      return jsonDecode(s);
    } catch (_) {
      return null;
    }
  }

  /// 宽容取字符串：数字也接受（服务端可能给 `lang: 0`）。
  static String? _asString(Object? v) {
    if (v == null) return null;
    if (v is String) return v;
    return '$v';
  }

  /// 宽容取整数：字符串数字也接受（如 `demux-channels: "6"`）。
  static int? _asInt(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  /// **归一化轨道 id 为整数字符串**（详见调用处的说明）。
  ///
  /// · `1` → `"1"`；`1.0` → `"1"`；`"1.0"` → `"1"`；`"1"` → `"1"`
  /// · 非数字（如 Media3 可能给 `"0"`/自定义串）→ 原样 `'$v'`（不猜）
  ///
  /// ⚠️ 只在"确实能解析成整数"时才归一化 —— 否则会把有意义的名字改坏。
  static String _normalizeTrackId(Object? v) {
    if (v == null) return '';
    if (v is int) return '$v';
    if (v is num) {
      // 1.0 → "1"；1.5 → 保留 "1.5"（不该出现，但别丢信息）
      return v == v.roundToDouble() ? '${v.toInt()}' : '$v';
    }
    if (v is String) {
      final n = num.tryParse(v);
      if (n != null && n == n.roundToDouble()) return '${n.toInt()}';
      return v;
    }
    return '$v';
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
