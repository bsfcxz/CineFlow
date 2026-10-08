/// 播放列表控制器（播放列表面板 + 上一项/下一项）。
///
/// ## 与 CineFlow 现有播放模型的关系
/// CineFlow 的"列表"来自 Emby（剧集列表 / 合集）。规格里是本地文件列表。
/// 两者结构相同（有序条目 + 当前下标 + 播放模式），故本控制器
/// **只依赖一个中立的 `PlaylistEntry`**，由调用方把 Emby 剧集
/// 或本地文件都映射进来 —— 这样播放器 UI 不用知道数据从哪来。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 播放列表里的一个条目（中立模型，不含任何来源词汇）。
class PlaylistEntry {
  const PlaylistEntry({
    required this.id,
    required this.title,
    this.subtitle,
    this.episodeLabel,
    this.progressLabel,
  });

  final String id;
  final String title;

  /// 副标题（大小 / 格式 / 时长等，由调用方决定内容）。
  final String? subtitle;

  /// **集数标签**，如 `第 11 集` / `S1 E11`。
  ///
  /// ## 为什么单独一个字段（而不是让调用方拼进 title）
  /// 用户反馈（2026-10-07）："播放剧集和综艺时播放列表并没有显示当前集数"。
  /// 实测原因：流程页只填了 `title: e.name` + `subtitle: seriesName`，
  /// **集号根本没进列表** —— 于是 5 集剧在列表里看起来是 5 个无编号的名字，
  /// 用户无法判断"当前播到第几集"。
  ///
  /// 单独成字段的理由：
  ///   · 面板可以**加粗/高亮**它（比混在 title 里更醒目）
  ///   · 电影没有集号 → 传 null，面板自动不显示（不出现空行）
  ///   · 与旧页「选集」的展示口径一致（`第 N 集` + 剧名 + 进度）
  final String? episodeLabel;

  /// **观看进度标签**，如 `已看` / `看到 37%`。
  ///
  /// 对齐旧页选集抽屉的 `sub:`（`player_page.dart` 的 `_sheetRow`）：
  /// 让用户在列表里就能看出"哪几集看过、看到哪"，
  /// 而不是只能看到一堆并列的名字。
  final String? progressLabel;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaylistEntry &&
          other.id == id &&
          other.title == title &&
          other.subtitle == subtitle &&
          other.episodeLabel == episodeLabel &&
          other.progressLabel == progressLabel;

  @override
  int get hashCode =>
      Object.hash(id, title, subtitle, episodeLabel, progressLabel);
}

/// 播放模式（规格 §5 `PlayMode`）。
enum PlayMode {
  sequence('顺序'),
  shuffle('随机'),
  single('单曲');

  const PlayMode(this.label);
  final String label;
}

/// 播放列表状态。
class PlaylistState {
  const PlaylistState({
    this.entries = const [],
    this.currentIndex = 0,
    this.mode = PlayMode.sequence,
  });

  final List<PlaylistEntry> entries;
  final int currentIndex;
  final PlayMode mode;

  bool get isEmpty => entries.isEmpty;

  PlaylistEntry? get current =>
      (currentIndex >= 0 && currentIndex < entries.length)
          ? entries[currentIndex]
          : null;

  bool get hasPrevious => currentIndex > 0;

  bool get hasNext => currentIndex < entries.length - 1;

  PlaylistState copyWith({
    List<PlaylistEntry>? entries,
    int? currentIndex,
    PlayMode? mode,
  }) =>
      PlaylistState(
        entries: entries ?? this.entries,
        currentIndex: currentIndex ?? this.currentIndex,
        mode: mode ?? this.mode,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaylistState &&
          other.currentIndex == currentIndex &&
          other.mode == mode &&
          other.entries.length == entries.length;

  @override
  int get hashCode => Object.hash(currentIndex, mode, entries.length);
}

class PlaylistController extends Notifier<PlaylistState> {
  @override
  PlaylistState build() => const PlaylistState();

  /// 切歌回调（UI 层注入 → 通知播放层打开新条目）。
  void Function(PlaylistEntry entry)? onSelect;

  /// 设置整个列表（打开播放器时调用）。
  ///
  /// [startIndex] 越界会被钳制 —— 列表来源多样（按 id 匹配当前条目等），
  /// 调用方算错下标时**不该让播放器崩**，退化为第 0 项即可。
  void setEntries(List<PlaylistEntry> entries, {int startIndex = 0}) {
    final idx = entries.isEmpty ? 0 : startIndex.clamp(0, entries.length - 1);
    state = PlaylistState(
      entries: entries,
      currentIndex: idx,
      mode: state.mode,
    );
  }

  /// 选择某一项（面板点击）。
  /// **只同步索引，不触发 `onSelect` 回调**。
  ///
  /// ## 为什么必须与 [select] 分开（真机 bug，2026-10-09）
  /// 宿主（`PlayerFlowPage`）在 `_playEpisode` 里已经决定了"现在播第几集"，
  /// 它只需要把列表的 `currentIndex` **对齐**过去。
  ///
  /// 若用 [select]，会触发 `onSelect` 回调 → 宿主又调 `_playEpisode`
  /// → **递归换集**（且下标可能来回抖动）。
  ///
  /// 单一职责：**[select] = 用户点选**（改索引 + 通知宿主）；
  /// **[setCurrentIndex] = 宿主对齐**（只改索引）。
  void setCurrentIndex(int index) {
    if (index < 0 || index >= state.entries.length) return;
    if (index == state.currentIndex) return;
    state = state.copyWith(currentIndex: index);
  }

  void select(int index) {
    if (index < 0 || index >= state.entries.length) return;
    if (index == state.currentIndex) return;
    state = state.copyWith(currentIndex: index);
    onSelect?.call(state.entries[index]);
  }

  /// 上一项。到头则不动（规格原型：`if (currentIndex <= 0) return;`）。
  void previous() {
    if (!state.hasPrevious) return;
    state = state.copyWith(currentIndex: state.currentIndex - 1);
    onSelect?.call(state.entries[state.currentIndex]);
  }

  /// 下一项。到头则不动 —— **自动连播的"播完最后一集"由上层决定**
  /// 是否循环，本控制器不擅自回绕（否则用户手动点下一项会被意外带回开头）。
  void next() {
    if (!state.hasNext) return;
    state = state.copyWith(currentIndex: state.currentIndex + 1);
    onSelect?.call(state.entries[state.currentIndex]);
  }

  void setMode(PlayMode mode) {
    if (state.mode == mode) return;
    state = state.copyWith(mode: mode);
  }

  /// 循环切换播放模式。
  void cycleMode() {
    const order = PlayMode.values;
    final i = order.indexOf(state.mode);
    setMode(order[(i + 1) % order.length]);
  }

  /// 自动连播的下一条：`single` 返回当前项，其余顺序前进
  /// （`shuffle` 由调用方传随机下标进来，本控制器不做随机源 —— 保持可测）。
  PlaylistEntry? autoNextEntry({int? shuffleIndex}) {
    if (state.entries.isEmpty) return null;
    switch (state.mode) {
      case PlayMode.single:
        return state.current;
      case PlayMode.shuffle:
        final i = (shuffleIndex ?? 0).clamp(0, state.entries.length - 1);
        return state.entries[i];
      case PlayMode.sequence:
        return state.hasNext ? state.entries[state.currentIndex + 1] : null;
    }
  }
}
