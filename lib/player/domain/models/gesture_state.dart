/// 手势状态（不可变）—— 手势层的**唯一真相来源**。
///
/// ## 与 HTML 原型的对账（原型 JS 是权威）
///
/// 原型 `gesture` 对象：
/// ```
/// { active, startX, startY, startTime, startBrightness, startVolume,
///   mode, longPressFired, moved, longPressTimer }
/// ```
///
/// ⚠️ 其中 `longPressTimer` **不在本状态里**：Timer 属"副作用资源"，
/// 放进不可变状态会导致每次手势更新都重建 Timer（且必须 cancel 旧的，
/// 极易泄漏）。它由 `GestureController` 持有并在 `dispose` 释放。
///
/// ## 中途改过的一处：`startPositionInVideo` 用 Duration
/// 原型用 `currentSeconds`（double 秒）。Dart 侧用 [Duration] 与内核接口
/// (`seek(Duration)`) 一致，避免"秒 ↔ Duration"在各层反复换算出错
/// （本项目已踩过：`positionTicks` 100ns 单位换算错一次就整体偏移）。
library;

import 'dart:ui' show Offset;

/// 手势模式。
///
/// `dead` 是**中间死区**：原型里左右分区各 40%，中间 20% 不响应任何手势。
/// 为什么要有它 —— 中间是播放/暂停按钮所在区域，手指从那里起滑
/// 多半是想点按而非调节；给它一个"什么都不做"的分区，比误判成亮度/音量好。
enum GestureMode {
  none,
  seek,
  brightness,
  volume,
  dead,
}

/// 手势状态。
class GestureState {
  const GestureState({
    this.active = false,
    this.mode = GestureMode.none,
    this.startPosition = Offset.zero,
    this.startPositionInVideo = Duration.zero,
    this.startBrightness = 0,
    this.startVolume = 0,
    this.currentBrightness = 0,
    this.currentVolume = 0,
    this.currentSeekTarget = Duration.zero,
    this.longPressFired = false,
    this.moved = false,
    this.deltaRatio = 0,
  });

  /// 是否处于手势中（pointerdown 到 up 之间）。
  final bool active;

  /// 当前判定出的手势模式。
  final GestureMode mode;

  /// 起点（屏幕坐标）。
  final Offset startPosition;

  /// 起点对应的**视频播放位置**（拖动进度时以此为基准）。
  ///
  /// ⚠️ 必须以「按下那一刻的位置」为基准，而不是"当前位置 + 增量"。
  /// 后者在每次 move 时都会把上一次的增量再算一遍 → **加速度式漂移**
  /// （手指匀速移动，进度却越来越快）。原型用 `startTime + delta` 是对的。
  final Duration startPositionInVideo;

  final double startBrightness;
  final double startVolume;

  /// 手势过程中实时值（供指示器显示）。
  final double currentBrightness;
  final double currentVolume;
  final Duration currentSeekTarget;

  /// 长按是否已触发（触发后**忽略一切移动**，见原型的 `if (longPressFired) return`）。
  final bool longPressFired;

  /// 是否移动过（超过 10px 阈值）—— 用于区分"点击"与"拖动"。
  final bool moved;

  /// 归一化增量（seek 时为 -1..1 的屏宽比例；亮度/音量时为 -1..1 的屏高比例）。
  final double deltaRatio;

  bool get isIdle => !active && mode == GestureMode.none;

  /// 是否应显示"快进/快退"指示器。
  bool get showingSeek => mode == GestureMode.seek;

  /// 是否应显示亮度指示器。
  bool get showingBrightness => mode == GestureMode.brightness;

  /// 是否应显示音量指示器。
  bool get showingVolume => mode == GestureMode.volume;

  GestureState copyWith({
    bool? active,
    GestureMode? mode,
    Offset? startPosition,
    Duration? startPositionInVideo,
    double? startBrightness,
    double? startVolume,
    double? currentBrightness,
    double? currentVolume,
    Duration? currentSeekTarget,
    bool? longPressFired,
    bool? moved,
    double? deltaRatio,
  }) =>
      GestureState(
        active: active ?? this.active,
        mode: mode ?? this.mode,
        startPosition: startPosition ?? this.startPosition,
        startPositionInVideo:
            startPositionInVideo ?? this.startPositionInVideo,
        startBrightness: startBrightness ?? this.startBrightness,
        startVolume: startVolume ?? this.startVolume,
        currentBrightness: currentBrightness ?? this.currentBrightness,
        currentVolume: currentVolume ?? this.currentVolume,
        currentSeekTarget: currentSeekTarget ?? this.currentSeekTarget,
        longPressFired: longPressFired ?? this.longPressFired,
        moved: moved ?? this.moved,
        deltaRatio: deltaRatio ?? this.deltaRatio,
      );

  /// 结束手势：回到初始态（**保留长按前的倍速由上层负责**）。
  GestureState reset() => const GestureState();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GestureState &&
          other.active == active &&
          other.mode == mode &&
          other.startPosition == startPosition &&
          other.startPositionInVideo == startPositionInVideo &&
          other.startBrightness == startBrightness &&
          other.startVolume == startVolume &&
          other.currentBrightness == currentBrightness &&
          other.currentVolume == currentVolume &&
          other.currentSeekTarget == currentSeekTarget &&
          other.longPressFired == longPressFired &&
          other.moved == moved &&
          other.deltaRatio == deltaRatio;

  @override
  int get hashCode => Object.hash(active, mode, startPosition,
      startPositionInVideo, startBrightness, startVolume, currentBrightness,
      currentVolume, currentSeekTarget, longPressFired, moved, deltaRatio);

  @override
  String toString() => 'GestureState(active: $active, mode: $mode, '
      'moved: $moved, longPress: $longPressFired)';
}
