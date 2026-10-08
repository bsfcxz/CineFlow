/// 播放控制器 —— 负责"播放状态"这一件事。
///
/// ## 职责边界（单一职责）
/// 管：播放/暂停、位置、时长、倍速（含长按临时倍速）、缓冲、完成、错误。
/// **不管**：UI 显隐（[UiVisibilityController]）、手势判定（[GestureController]）、
/// 面板开合（[PanelController]）、播放列表切换（[PlaylistController]）。
///
/// 这样拆的直接收益：手势层只调 `playback.togglePlay()`，
/// 不必知道 UI 该不该隐藏；面板层只调 `panel.open()`，
/// 不必知道播放器状态 —— **改动不会互相波及**。
///
/// ## 与 HTML 原型的对账
/// 原型把 `isPlaying / currentSeconds / totalSeconds / userSpeed /
/// longPressSpeed / isLongPressing` 全塞在一个 `state.playback` 里，
/// 由 `renderPlayState()` 一次性重绘。本实现保留同样的状态集合，
/// 但通过 Riverpod 让**只有关心某字段的 Widget 重建**。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/playback_state.dart';
import '../../domain/player_constants.dart';

/// 播放控制器。
///
/// 用 `Notifier`（不是 `AsyncNotifier`）：状态的加载/错误由
/// **播放引擎**经 Stream 推来，不走 Riverpod 的 AsyncValue 机制。
/// 混用两套异步模型会让"引擎报错"与"状态还没准备好"难以区分。
class PlaybackController extends Notifier<PlaybackState> {
  @override
  PlaybackState build() => const PlaybackState();

  // ---- 引擎回调入口（由 PlayerPage 的 Stream 订阅驱动）----

  void setPlaying(bool playing) {
    if (state.isPlaying == playing) return;
    state = state.copyWith(isPlaying: playing);
  }

  void setPosition(Duration position) {
    // 拖动中不接受引擎位置回推：否则"手指在拖、进度自己跳"
    // （引擎每 100–250ms 推一次，会与拖动值打架）
    if (state.isBuffering && state.position == position) return;
    if (state.position == position) return;
    state = state.copyWith(position: position);
  }

  void setDuration(Duration duration) {
    if (state.duration == duration) return;
    state = state.copyWith(duration: duration);
  }

  void setBuffer(Duration buffer) {
    if (state.buffer == buffer) return;
    state = state.copyWith(buffer: buffer);
  }

  void setBuffering(bool buffering) {
    if (state.isBuffering == buffering) return;
    state = state.copyWith(isBuffering: buffering);
  }

  void setError(String? message) {
    if (state.errorMessage == message) return;
    state = state.copyWith(errorMessage: message);
  }

  void setCompleted(bool completed) {
    if (state.isCompleted == completed) return;
    state = state.copyWith(isCompleted: completed);
  }

  /// 引擎已实际应用的倍速（用于校正：用户在别处改了倍速）。
  ///
  /// ## ⚠️ 长按期间必须跳过（真机 bug，2026-10-07 用户反馈）
  ///
  /// 用户反馈："长按结束后播放速度恢复原来的设置（不改变倍速设置）"。
  ///
  /// 长按快进的实现是：`isLongPressing=true` → UI 监听
  /// `effectiveSpeed` 变化 → 把内核 `setRate(3.0)`。
  /// 内核随后回报 `rate=3.0`，而这条回报会流进 [syncSpeed] ——
  /// 若此时照常写入 `userSpeed`，**长按的临时倍速就被固化成用户偏好**：
  ///
  /// ```
  /// 长按 → effectiveSpeed=3.0 → 内核 setRate(3.0)
  ///      → 内核回报 rate=3.0 → syncSpeed(3.0) ⇒ userSpeed 被改成 3.0 ❌
  /// 松手 → isLongPressing=false → effectiveSpeed = userSpeed = 3.0
  ///      → 用户发现"倍速变成 3.0 且回不去了"
  /// ```
  ///
  /// 修法：`isLongPressing` 期间直接 return —— 那段内核速率是**临时值**，
  /// 不是用户偏好，不该被记录。这与 `effectiveSpeed` 用派生 getter 的
  /// 设计是同一条防线的两半：getter 防"忘了存回"，这里防"反向污染"。
  void syncSpeed(double speed) {
    if (state.isLongPressing) return;
    if (state.userSpeed == speed) return;
    state = state.copyWith(userSpeed: speed);
  }

  // ---- 用户操作（事件处理器调用）----

  /// 播放/暂停。**只翻转状态，实际播放由监听者调引擎**。
  ///
  /// ## 为什么要这样分（不是多此一举）
  /// 若在这里直接拿引擎引用调 `play()`，Controller 就与引擎**强耦合**，
  /// 单测时必须造一个假引擎。现在 Controller 是纯状态机，
  /// 可以只断言"调用 togglePlay 后 isPlaying 翻转"，
  /// 毫秒级、零依赖 —— 这正是规格要求"可测试性设计"的落点。
  void togglePlay() {
    state = state.copyWith(
      isPlaying: !state.isPlaying,
      // 从"已完成"状态点播放 → 视为重看，清掉完成标记
      isCompleted: state.isCompleted ? false : state.isCompleted,
    );
  }

  void play() => state = state.copyWith(isPlaying: true, isCompleted: false);

  void pause() => state = state.copyWith(isPlaying: false);

  /// 相对跳转（±10s），结果钳制在 [0, duration]。
  void seekBy(Duration delta) => seekTo(state.position + delta);

  /// 绝对跳转。越界自动钳制。
  ///
  /// ★ 钳制必须在这里做（而不是各调用点）：
  ///   手势 seek、进度条拖动、±10s 按钮、自动连播都会调它，
  ///   漏一处就会出现"进度条拖到最右后 position > duration"，
  ///   表现是进度条回弹或百分比异常。
  void seekTo(Duration position) {
    final max = state.duration;
    var target = position;
    if (target.isNegative) target = Duration.zero;
    if (max > Duration.zero && target > max) target = max;
    state = state.copyWith(position: target);
  }

  /// 循环切换到下一个倍速（1.0 → 1.5 → 2.0 → 2.5 → 3.0 → 1.0）。
  void cycleSpeed() {
    state = state.copyWith(userSpeed: PlayerSpeeds.next(state.userSpeed));
  }

  void setUserSpeed(double speed) {
    state = state.copyWith(userSpeed: speed);
  }

  /// 长按开始 → 进入临时快进。
  ///
  /// ⚠️ 只在**播放中**才进入：暂停时长按快进没有意义，
  ///    且会让"松开后倍速恢复"这条路径多一个无用分支。
  ///    原型的 `if (!state.playback.isPlaying) return;` 就是这个意思。
  void startLongPress() {
    if (!state.isPlaying) return;
    if (state.isLongPressing) return;
    state = state.copyWith(isLongPressing: true);
  }

  /// 长按结束 → 恢复用户倍速。
  ///
  /// 因为速率由 `PlaybackState.effectiveSpeed` 推导（见该 getter 的注释），
  /// 这里只需翻 `isLongPressing`，**不可能忘记恢复 userSpeed**。
  void endLongPress() {
    if (!state.isLongPressing) return;
    state = state.copyWith(isLongPressing: false);
  }

  /// 切换媒体时重置与"这一条媒体"绑定的字段。
  ///
  /// ⚠️ **保留 `userSpeed` 与 `longPressSpeed`**：那是用户偏好，
  ///    换一集不该被重置。若整体重建 `PlaybackState()`，
  ///    用户设的 2.0x 会莫名回到 1.0x —— 这是很容易犯的错。
  void resetForNewMedia() {
    state = PlaybackState(userSpeed: state.userSpeed, longPressSpeed: state.longPressSpeed);
  }
}
