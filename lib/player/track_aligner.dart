/// 服务端轨道 ↔ 播放内核轨道的**对齐**。
///
/// ## 为什么需要这个文件（用户指出的"致命问题"的最后一环）
///
/// 同一部片有**两套轨道描述**，各有各的用处，但**编号空间不同**：
///
/// | | 服务端（Emby） | 播放内核（mpv） |
/// |---|---|---|
/// | 数据 | `MediaStream`（`DisplayTitle`/`DisplayLanguage`/`IsDefault`/`IsForced`…） | `track-list[]`（`id`/`ff-index`/`codec`…） |
/// | 强项 | **名字可读**（`Chinese Simplified (PGSSUB)`）、有"默认"标记 | **能真正执行切换**（`aid`/`sid`） |
/// | 编号 | `Index` = **ffmpeg 全局流索引** | `id` = **每类型独立从 1 编号** |
///
/// 于是"用服务端的好名字 + 用内核真正切轨"需要一个**桥**。
/// 这个桥**不能是 `id`**：典型 MKV（video=0, audio=1, sub=2）下
/// 内核的 `sid` 是 **1** 而 Emby 的 `Index` 是 **2** —— **用 id 匹配会切错轨**。
///
/// 唯一正确的桥是 **mpv 的 `ff-index`**（与 Emby `Index` 同源）。
///
/// ## 降级策略（`ff-index` 可能不可用）
///
/// mpv 官方文档明确：`ff-index` 在非 libavformat 解封装时
/// *"can be potentially wrong"* 且 *"May be unavailable"*。故：
///   1. **优先 `ffIndex == server.Index` 精确匹配**
///   2. 缺失时按**同类型内出现顺序**匹配（第 n 条对第 n 条，跳过已占用的）
///   3. 都对不上 → 用内核自带信息兜底（名字差一点，但不崩、不断功能）
library;

import '../data/models.dart';
import 'player_facade.dart';

/// 一条"对齐后"的轨道：**服务端的可读信息 + 内核的可执行 id**。
class AlignedTrack {
  const AlignedTrack({
    required this.kernelId,
    required this.label,
    this.isDefault = false,
    this.isForced = false,
    this.isExternal = false,
    this.matchedByIndex = false,
  });

  /// 交给内核执行切换用的 id（`aid`/`sid`）—— **这是它的唯一用途**
  final String kernelId;

  /// 展示名（**优先服务端 `DisplayTitle`**）
  final String label;

  final bool isDefault;
  final bool isForced;
  final bool isExternal;

  /// 是否为 `ffIndex == Index` 的**精确**匹配。
  /// false = 走了顺序启发式（仅供诊断；UI 上不必区分）。
  final bool matchedByIndex;
}

/// 把服务端流与内核轨道对齐。
///
/// 音轨与字幕**各对齐各的** —— 两套编号互不相干
/// （服务端 `Index` 是全局的，但内核 `aid` 与 `sid` 是两个独立序列）。
abstract final class TrackAligner {
  /// 对齐音轨。[defaultIndex] = 服务端 `DefaultAudioStreamIndex`
  static List<AlignedTrack> alignAudio(
    List<MediaStream> server,
    List<FacadeAudioTrack> kernel, {
    int? defaultIndex,
  }) {
    return _align(
      server: server,
      count: kernel.length,
      serverIndexAt: (i) => server[i].index,
      serverLabelAt: (i) => server[i].label,
      defaultIndex: defaultIndex,
      kernelFfIndexAt: (i) => kernel[i].ffIndex,
      kernelIdAt: (i) => kernel[i].id,
      // 内核自带信息兜底（仅在完全匹配不上时用）
      fallbackLabelAt: (i) {
        final k = kernel[i];
        final parts = <String>[];
        if (k.title != null && k.title!.isNotEmpty) parts.add(k.title!);
        if (k.language != null && k.language!.isNotEmpty) parts.add(k.language!);
        if (k.channels != null && k.channels! > 0) parts.add('${k.channels}ch');
        if (k.codec != null && k.codec!.isNotEmpty) parts.add(k.codec!);
        return parts.isEmpty ? '音轨 ${k.id}' : parts.join(' · ');
      },
    );
  }

  /// 对齐字幕。[defaultIndex] = 服务端 `DefaultSubtitleStreamIndex`
  static List<AlignedTrack> alignSubtitle(
    List<MediaStream> server,
    List<FacadeSubtitleTrack> kernel, {
    int? defaultIndex,
  }) {
    return _align(
      server: server,
      count: kernel.length,
      serverIndexAt: (i) => server[i].index,
      serverLabelAt: (i) => server[i].label,
      defaultIndex: defaultIndex,
      kernelFfIndexAt: (i) => kernel[i].ffIndex,
      kernelIdAt: (i) => kernel[i].id,
      fallbackLabelAt: (i) {
        final k = kernel[i];
        final parts = <String>[];
        if (k.title != null && k.title!.isNotEmpty) parts.add(k.title!);
        if (k.language != null && k.language!.isNotEmpty) parts.add(k.language!);
        if (k.isForced) parts.add('强制');
        if (k.isExternal) parts.add('外挂');
        return parts.isEmpty ? '字幕 ${k.id}' : parts.join(' · ');
      },
    );
  }

  /// 通用对齐逻辑（音轨/字幕共用）。
  ///
  /// 传函数而不是泛型：音轨与字幕的**内核类型不同**且没有公共接口，
  /// 用 3 个访问器函数比引入泛型约束更直观。参数已压到最少。
  static List<AlignedTrack> _align({
    required List<MediaStream> server,
    required int count,
    required int? Function(int) serverIndexAt,
    required String Function(int) serverLabelAt,
    required int? defaultIndex,
    required int? Function(int) kernelFfIndexAt,
    required String Function(int) kernelIdAt,
    required String Function(int) fallbackLabelAt,
  }) {
    final n = server.length;
    final used = List<bool>.filled(n, false);

    // ① 精确匹配：kernel.ffIndex == server.Index
    final labels = List<String?>.filled(count, null);
    final isDefault = List<bool>.filled(count, false);
    final precise = List<bool>.filled(count, false);

    for (var ki = 0; ki < count; ki++) {
      final ff = kernelFfIndexAt(ki);
      if (ff == null) continue;
      for (var si = 0; si < n; si++) {
        if (used[si] || serverIndexAt(si) != ff) continue;
        labels[ki] = serverLabelAt(si);
        isDefault[ki] = defaultIndex != null && serverIndexAt(si) == defaultIndex;
        precise[ki] = true;
        used[si] = true;
        break;
      }
    }

    // ② 未匹配的，用剩下的服务端流按顺序补（启发式）
    var next = 0;
    for (var ki = 0; ki < count; ki++) {
      if (precise[ki]) continue;
      while (next < n && used[next]) {
        next++;
      }
      if (next >= n) break;
      labels[ki] = serverLabelAt(next);
      isDefault[ki] = defaultIndex != null && serverIndexAt(next) == defaultIndex;
      used[next] = true;
      next++;
    }

    // ③ 组装（仍无匹配 → 内核兜底）
    return [
      for (var ki = 0; ki < count; ki++)
        AlignedTrack(
          kernelId: kernelIdAt(ki),
          label: labels[ki] ?? fallbackLabelAt(ki),
          isDefault: isDefault[ki],
          matchedByIndex: precise[ki],
        ),
    ];
  }
}
