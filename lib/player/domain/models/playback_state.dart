/// 播放状态（不可变）—— 播放器 UI 的**唯一真相来源**之一。
///
/// ## 为什么单独一个文件
/// 这个类被手势层、进度条、倍速按钮、反馈层同时读取。
/// 放进 `player_page.dart` 会让"谁改了状态"无从追查；
/// 独立成文件后，**任何状态变更都必须经过 `PlaybackController`**。
///
/// ## 与 HTML 原型的对账
/// 原型 `state.playback` 里含：
///   `isPlaying / currentSeconds / totalSeconds / userSpeed / longPressSpeed /
///    isLongPressing / isLocked`
/// 其中 `isLocked` **不在这里** —— 它属于 [UiVisibilityState]：
/// 锁定影响的是"UI 是否响应"，不是"播放是否进行"。
/// 混在一起会让"锁定时仍应继续播放"这条约束难以表达。
library;

/// 播放状态。
class PlaybackState {
  const PlaybackState({
    this.isPlaying = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.buffer = Duration.zero,
    this.userSpeed = 1.0,
    this.longPressSpeed = 3.0,
    this.isLongPressing = false,
    this.engineSpeed = 1.0,
    this.isBuffering = false,
    this.isCompleted = false,
    this.errorMessage,
  });

  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final Duration buffer;

  /// 用户选择的倍速（1.0 / 1.5 / 2.0 / 2.5 / 3.0）。
  final double userSpeed;

  /// 长按时的临时倍速（原型固定 3.0）。
  final double longPressSpeed;

  /// 是否处于"长按快进"中。
  final bool isLongPressing;

  /// **内核实际生效的倍速**（只读语义，用户规格禁令⑤）。
  ///
  /// ## 为什么必须与 [userSpeed] 分开（禁令①）
  /// | 字段 | 谁写 | 谁看 | 含义 |
  /// |---|---|---|---|
  /// | `userSpeed` | **只有用户操作**（点按钮/设偏好） | 倍速按钮文案 | 用户**想要**的倍速 |
  /// | `engineSpeed` | **只有内核回报**（`syncSpeed`） | 需要展示"实际倍速"的地方 | 引擎**实际在跑**的 |
  /// | `effectiveSpeed` | 派生（不改任何字段） | 下发给引擎的期望值 | "**应该**给引擎什么" |
  ///
  /// ## 历史教训（为什么这个字段是被"逼"出来的）
  /// 重构前 `syncSpeed` 把内核速率写进 `userSpeed`，于是：
  /// · 长按 → 内核回报 3.0 → `userSpeed` 变 3.0 → 用户发现"倍速被改了"
  /// · 修了两轮（长按守卫 / 迟到回报时间窗），**都是补丁**
  /// 用户禁令①句话点破根因：**一个变量兼表两者，就必然互相污染**。
  /// 拆成两个字段后，那两轮守卫可以删掉 —— 因为污染路径不存在了。
  final double engineSpeed;

  final bool isBuffering;
  final bool isCompleted;

  /// 播放错误信息（null = 无错误）。
  final String? errorMessage;

  /// 实际生效的倍速。
  ///
  /// ★ 这个 getter 是"长按快进"能只改一个字段就生效的关键：
  ///   长按只翻 [isLongPressing]，播放速率由本 getter 推导，
  ///   于是"松开必须恢复原倍速"不会漏 —— 不可能忘记恢复。
  ///   若把长按实现成 `userSpeed = 3.0`，就**必须记得**在松开时存回原值，
  ///   而那条路径分支很多（长按中移出屏幕 / 被取消 / 切后台），必漏其一。
  double get effectiveSpeed => isLongPressing ? longPressSpeed : userSpeed;

  /// 播放进度 0.0–1.0。
  double get progress => duration.inMilliseconds == 0
      ? 0.0
      : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);

  /// 剩余时长（不会为负 —— 位置可能因 seek 越界短暂超过总时长）。
  Duration get remaining {
    final r = duration - position;
    return r.isNegative ? Duration.zero : r;
  }

  /// 是否已起播（有总时长且位置已推进）—— 用于判断"该不该显示进度"。
  bool get hasMedia => duration > Duration.zero;

  PlaybackState copyWith({
    bool? isPlaying,
    Duration? position,
    Duration? duration,
    Duration? buffer,
    double? userSpeed,
    double? longPressSpeed,
    bool? isLongPressing,
    double? engineSpeed,
    bool? isBuffering,
    bool? isCompleted,
    // 用哨兵而非 `?? this.errorMessage`：否则**无法把错误清空**
    // （传 null 会被当成"没传"）。这是 copyWith 的经典陷阱。
    Object? errorMessage = _sentinel,
  }) =>
      PlaybackState(
        isPlaying: isPlaying ?? this.isPlaying,
        position: position ?? this.position,
        duration: duration ?? this.duration,
        buffer: buffer ?? this.buffer,
        userSpeed: userSpeed ?? this.userSpeed,
        longPressSpeed: longPressSpeed ?? this.longPressSpeed,
        isLongPressing: isLongPressing ?? this.isLongPressing,
        engineSpeed: engineSpeed ?? this.engineSpeed,
        isBuffering: isBuffering ?? this.isBuffering,
        isCompleted: isCompleted ?? this.isCompleted,
        errorMessage: identical(errorMessage, _sentinel)
            ? this.errorMessage
            : errorMessage as String?,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaybackState &&
          other.isPlaying == isPlaying &&
          other.position == position &&
          other.duration == duration &&
          other.buffer == buffer &&
          other.userSpeed == userSpeed &&
          other.longPressSpeed == longPressSpeed &&
          other.isLongPressing == isLongPressing &&
          other.engineSpeed == engineSpeed &&
          other.isBuffering == isBuffering &&
          other.isCompleted == isCompleted &&
          other.errorMessage == errorMessage;

  @override
  int get hashCode => Object.hash(isPlaying, position, duration, buffer,
      userSpeed, longPressSpeed, isLongPressing, engineSpeed, isBuffering,
      isCompleted, errorMessage);

  @override
  String toString() => 'PlaybackState(playing: $isPlaying, '
      'pos: $position/$duration, speed: $effectiveSpeed)';
}

/// copyWith 的"未传参"哨兵（见 [PlaybackState.copyWith] 的说明）。
const Object _sentinel = Object();
