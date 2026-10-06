/// 手势控制器 —— 负责"手指在屏幕上怎么动"这一件事。
///
/// ## 与 HTML 原型的对账（原型 JS 是权威）
/// 原型把状态放在全局 `gesture` 对象、Timer 放在 `gesture.longPressTimer`。
/// 本实现把**状态**放 [GestureState]（不可变、可单测），
/// 把 **Timer** 留在 Controller 内（`_longPressTimer`）并在 [dispose] 释放。
///
/// ## 为什么手势判定要抽成纯函数
/// "左 40% 是亮度、中间 20% 死区、右 40% 是音量"这类分区逻辑，
/// 用 widget 测试验证需要真的模拟滑动（慢且脆）。
/// 抽成 [resolveMode] 纯函数后可以直接断言边界：
/// 0.39→亮度、0.41→死区、0.61→音量 —— 毫秒级、无副作用。
library;

import 'dart:async';
import 'dart:ui' show Offset, Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/gesture_state.dart';
import '../../domain/player_constants.dart';

/// 手势控制器。
class GestureController extends Notifier<GestureState> {
  Timer? _longPressTimer;

  /// 长按触发回调（由 UI 层注入 → 通知 PlaybackController 进入快进）。
  ///
  /// 用回调而不是让本 Controller 直接依赖 PlaybackController：
  /// 那样两个 Controller 会互相引用，单测时必须同时构造。
  void Function()? onLongPressStart;
  void Function()? onLongPressEnd;

  /// seek 结果回调（拖动进度时实时通知播放层）。
  void Function(Duration position)? onSeek;
  void Function(Duration delta)? onSeekPreview;

  @override
  GestureState build() {
    ref.onDispose(_cancelLongPress);
    return const GestureState();
  }

  void _cancelLongPress() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
  }

  // ---------------- 纯函数：手势判定 ----------------

  /// 依据位移与横向位置判定手势模式。
  ///
  /// **原型的原样翻译**（`pointermove` 里的判定块）：
  /// ```js
  /// if (adx < 15 && ady < 15) return;        // 还没动够
  /// if (adx > ady) mode = 'seek';            // 横向为主 → 进度
  /// else if (relX < rect.width * 0.4) mode = 'brightness';
  /// else if (relX > rect.width * 0.6) mode = 'volume';
  /// else mode = 'dead';                      // 中间死区
  /// ```
  ///
  /// ⚠️ 注意 `adx > ady` 用的是**严格大于**：斜 45° 滑动会落到
  /// 亮度/音量分支。原型如此，保持行为一致。
  static GestureMode resolveMode({
    required Offset delta,
    required double relativeX,
    required double width,
  }) {
    final adx = delta.dx.abs();
    final ady = delta.dy.abs();
    if (adx < PlayerGestures.directionSlop &&
        ady < PlayerGestures.directionSlop) {
      return GestureMode.none;
    }
    if (adx > ady) return GestureMode.seek;
    if (relativeX < width * PlayerGestures.brightnessZoneRight) {
      return GestureMode.brightness;
    }
    if (relativeX > width * PlayerGestures.volumeZoneLeft) {
      return GestureMode.volume;
    }
    return GestureMode.dead;
  }

  /// 亮度映射：`start + (-dy / height) * 120`，钳制 0–100。
  ///
  /// `-dy`：向上滑（dy 为负）应**增大**亮度，符合直觉。
  static double brightnessFor({
    required double start,
    required double dy,
    required double height,
  }) =>
      (start + (-(dy / height) * PlayerGestures.verticalSensitivity))
          .clamp(0.0, 100.0);

  /// 音量映射：同亮度（原型一致）。
  static double volumeFor({
    required double start,
    required double dy,
    required double height,
  }) =>
      (start + (-(dy / height) * PlayerGestures.verticalSensitivity))
          .clamp(0.0, 100.0);

  /// 进度映射：`start + (dx / width) * 180` 秒，钳制 0–总时长。
  ///
  /// 满屏横向滑动 ≈ 180 秒。这是原型选的值：一部 2 小时片
  /// 滑满屏只能移动 2.5% —— 精细但需要滑很多次。
  static Duration seekTargetFor({
    required Duration start,
    required double dx,
    required double width,
    required Duration total,
  }) {
    final deltaSeconds = (dx / width) * PlayerGestures.horizontalSeekSeconds;
    final ms = start.inMilliseconds + (deltaSeconds * 1000).round();
    final clamped = ms.clamp(0, total.inMilliseconds <= 0 ? ms : total.inMilliseconds);
    return Duration(milliseconds: clamped);
  }

  // ---------------- 事件处理（供 UI 的 Listener 调用）----------------

  /// 手指按下。
  ///
  /// [relativeX] 是相对**视频区域**的横坐标（不是屏幕坐标）——
  /// 竖屏下二者不同（视频区可能不占满宽度），用屏幕坐标会让分区偏移。
  void onPointerDown({
    required Offset position,
    required Duration currentPosition,
    required double brightness,
    required double volume,
  }) {
    _cancelLongPress();
    state = GestureState(
      active: true,
      startPosition: position,
      startPositionInVideo: currentPosition,
      startBrightness: brightness,
      startVolume: volume,
      currentBrightness: brightness,
      currentVolume: volume,
      currentSeekTarget: currentPosition,
    );
    _longPressTimer = Timer(PlayerGestures.longPressDelay, _fireLongPress);
  }

  void _fireLongPress() {
    if (!state.active) return;
    // 已经判定成手势（拖动）→ 不是长按
    if (state.moved) return;
    state = state.copyWith(longPressFired: true);
    onLongPressStart?.call();
  }

  /// 手指移动。
  void onPointerMove({
    required Offset position,
    required Size area,
    required Duration total,
  }) {
    if (!state.active) return;

    final delta = position - state.startPosition;
    final movedNow = delta.dx.abs() > PlayerGestures.moveSlop ||
        delta.dy.abs() > PlayerGestures.moveSlop;

    // 原型：一动就取消长按计时器（否则长按与拖动会同时生效）
    if (movedNow && !state.moved) {
      _cancelLongPress();
      state = state.copyWith(moved: true);
    }

    // 长按已触发 → 忽略一切移动（原型 `if (gesture.longPressFired) return;`）
    if (state.longPressFired) return;

    final relativeX = position.dx;
    var mode = state.mode;
    if (mode == GestureMode.none) {
      mode = resolveMode(delta: delta, relativeX: relativeX, width: area.width);
      if (mode == GestureMode.none) return; // 还没动够，等下一次
    }

    switch (mode) {
      case GestureMode.seek:
        final target = seekTargetFor(
          start: state.startPositionInVideo,
          dx: delta.dx,
          width: area.width,
          total: total,
        );
        final deltaSeconds = (delta.dx / area.width) *
            PlayerGestures.horizontalSeekSeconds;
        state = state.copyWith(
          mode: mode,
          currentSeekTarget: target,
          deltaRatio: delta.dx / area.width,
        );
        // 预览（显示 +30s / -15s），实际 seek 由 UI 在结束或实时决定
        onSeekPreview?.call(Duration(milliseconds: (deltaSeconds * 1000).round()));
        onSeek?.call(target);
      case GestureMode.brightness:
        final v = brightnessFor(
          start: state.startBrightness,
          dy: delta.dy,
          height: area.height,
        );
        state = state.copyWith(
          mode: mode,
          currentBrightness: v,
          deltaRatio: -delta.dy / area.height,
        );
      case GestureMode.volume:
        final v = volumeFor(
          start: state.startVolume,
          dy: delta.dy,
          height: area.height,
        );
        state = state.copyWith(
          mode: mode,
          currentVolume: v,
          deltaRatio: -delta.dy / area.height,
        );
      case GestureMode.dead:
        state = state.copyWith(mode: mode);
      case GestureMode.none:
        break;
    }
  }

  /// 手势结束的判定结果。
  ///
  /// 返回 `true` = 这是一次「点击」（未移动且未长按），UI 应据此做单击/双击判定。
  bool onPointerUp() {
    _cancelLongPress();
    if (!state.active) return false;

    final wasLongPress = state.longPressFired;
    final wasMoved = state.moved;
    final wasMode = state.mode;

    if (wasLongPress) onLongPressEnd?.call();

    state = state.reset();

    // 长按过 / 判定过方向 → 不是点击
    if (wasLongPress || wasMoved || wasMode != GestureMode.none) return false;
    return true;
  }

  /// 手势被系统取消（来电、手势冲突等）。
  ///
  /// ⚠️ 必须与 [onPointerUp] 一样做清理：原型在这里也调用了
  /// 恢复倍速的逻辑。若只清状态不通知 [onLongPressEnd]，
  /// 长按中被取消会**永久卡在 3.0x 快进**。
  void onPointerCancel() {
    _cancelLongPress();
    if (state.longPressFired) onLongPressEnd?.call();
    state = state.reset();
  }

  /// 面板打开等场景下强制中断手势（避免"面板开了手势还在跑"）。
  void abort() {
    _cancelLongPress();
    if (state.longPressFired) onLongPressEnd?.call();
    state = state.reset();
  }
}
