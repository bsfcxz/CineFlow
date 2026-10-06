/// UI 显隐与锁定控制器。
///
/// ## 自动隐藏的三条规则（规格 §8.2）
/// 1. 3 秒无操作 **且** 播放中 **且** 无面板打开 **且** 未锁定 → 隐藏
/// 2. 暂停时**不**自动隐藏（用户可能正要操作）
/// 3. 面板打开时**不**自动隐藏
///
/// ## 为什么这些规则要集中在这里
/// 原型把它们散在 `scheduleHideUI()` 里，靠调用方自觉传对前置条件。
/// 本实现把三条规则写成 [scheduleHide] 内部的守卫 ——
/// **调用方只管调，不用判断**，漏判的风险归零。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/ui_visibility_state.dart';
import '../../domain/player_constants.dart';

class UiVisibilityController extends Notifier<UiVisibilityState> {
  Timer? _hideTimer;

  /// 由 [PanelController] 注入：是否有面板打开（决定能否自动隐藏）。
  bool Function()? hasOpenPanel;

  /// 由 [PlaybackController] 注入：是否正在播放。
  bool Function()? isPlaying;

  @override
  UiVisibilityState build() {
    ref.onDispose(_cancelTimer);
    return const UiVisibilityState();
  }

  void _cancelTimer() {
    _hideTimer?.cancel();
    _hideTimer = null;
  }

  /// 显示控制层并**重新计时**。
  void show() {
    _cancelTimer();
    if (!state.visible) state = state.copyWith(visible: true);
    scheduleHide();
  }

  /// 隐藏控制层（立即，不等待）。
  void hide() {
    _cancelTimer();
    if (state.visible) state = state.copyWith(visible: false);
  }

  /// 单击切换显隐。
  void toggle() => state.visible ? hide() : show();

  /// 安排自动隐藏。
  ///
  /// ★ 三条守卫集中在此（见文件头）。任何一处不满足就**不排计时器** ——
  ///   而不是"排了再取消"，后者在快速连续操作下容易出现
  ///   "取消晚了导致闪一下"。
  void scheduleHide() {
    _cancelTimer();
    if (state.isLocked) return; // 锁定 → 由 controlsVisible 强制隐藏，无需计时
    if (isPlaying?.call() != true) return; // 暂停中不隐藏
    if (hasOpenPanel?.call() == true) return; // 面板打开不隐藏
    _hideTimer = Timer(PlayerGestures.uiHideDelay, () {
      // 计时器触发时再判一次：3 秒内状态可能已变（暂停/开面板）
      if (state.isLocked) return;
      if (isPlaying?.call() != true) return;
      if (hasOpenPanel?.call() == true) return;
      hide();
    });
  }

  /// 标记手势提示已展示（原型 `hintShown`：只提示一次）。
  void markHintShown() {
    if (state.hintShown) return;
    state = state.copyWith(hintShown: true);
  }

  /// 切换锁定。
  ///
  /// 锁定时**立即隐藏控制层**（规格 §8.4：锁定后 UI 强制隐藏）。
  /// 解锁后重新显示并计时。
  void toggleLock() {
    final locked = !state.isLocked;
    _cancelTimer();
    state = state.copyWith(isLocked: locked, visible: !locked);
    if (!locked) scheduleHide();
  }

  void setFullscreen(bool value) {
    if (state.fullscreen == value) return;
    state = state.copyWith(fullscreen: value);
  }
}
