/// 反馈层（规格 §7.1 的 `FeedbackLayer`）—— 手势过程中显示的各项指示器。
///
/// ## 四类反馈与它们的出现时机
///
/// | 指示器 | 触发 | 位置 |
/// |---|---|---|
/// | 亮度 | 左半屏上下滑 | 屏幕中央圆形 |
/// | 音量 | 右半屏上下滑 | 屏幕中央圆形 |
/// | 快进/快退 | 横向滑动 | 屏幕中央胶囊 |
/// | 长按倍速 | 长按 500ms | 屏幕中央胶囊（**持续显示**） |
///
/// ## 为什么全部忽略指针事件
/// 它们盖在画面正中 —— 若吃掉手势，用户滑动到一半松手再滑会失效。
/// 统一 `IgnorePointer`（本项目弹幕层也踩过同一个坑）。
///
/// ## ⚠️ 真实事故（2026-10-07 真机实测，**视频完全无法操作**）
///
/// 本文件曾**只在非长按分支**包 `IgnorePointer`：
/// ```dart
/// if (isLongPressing) {
///   return _CenterSlot(...);        // ← 没有 IgnorePointer！
/// }
/// return IgnorePointer(child: ...);  // ← 只有这里有
/// ```
/// 而 `_CenterSlot` 是 `Center(child: ...)`，在 `Positioned.fill` 下会
/// **撑满全屏并吃掉所有指针事件**。
///
/// 于是只要 `isLongPressing` 为 true，**整个播放页的点击/滑动全部失效** ——
/// 而长按本身又因为收不到 `pointerUp` 无法结束 → 状态永久卡在长按 →
/// **UI 从此再也点不动**（用户实测现象：屏幕常驻"3.0x 快进中"，
/// 单击、双击、滑动、按钮**全部无反应**）。
///
/// **教训**：反馈层是"纯展示层"，它**任何分支**都不能参与命中测试。
/// 故现在把 `IgnorePointer` 提到**最外层统一包**，而不是在各分支里各写一遍 ——
/// 后者必然漏（本次就是漏在长按分支）。
library;

import 'package:flutter/material.dart';

import '../../domain/models/gesture_state.dart';
import '../player_ui_tokens.dart';

/// 反馈层容器：根据手势状态决定显示哪个指示器。
///
/// ⚠️ **根节点永远是 `IgnorePointer`**（见文件头的事故说明）——
/// 任何新增分支都不要绕过它。
class PlayerFeedbackLayer extends StatelessWidget {
  const PlayerFeedbackLayer({
    super.key,
    required this.gesture,
    required this.isLongPressing,
    required this.longPressSpeed,
    this.volumePercent,
  });

  final GestureState gesture;

  /// 长按快进中（优先于其他指示器显示）。
  final bool isLongPressing;
  final double longPressSpeed;

  /// 音量显示用 0–100（与手势的 0–100 一致）。
  final double? volumePercent;

  @override
  Widget build(BuildContext context) {
    // ⚠️ `IgnorePointer` 必须在**最外层**（见文件头的事故说明）。
    //
    // 曾经的写法是「长按分支直接 return，其他分支才包 IgnorePointer」——
    // 结果长按分支返回的 `Center` 撑满全屏、吃掉所有指针事件，
    // 而长按又因收不到 pointerUp 无法结束 → **UI 永久卡死**。
    //
    // 现在改成：外层的 IgnorePointer 是**唯一入口**，
    // 里面的分支只管"显示什么"，**不可能绕过**命中过滤。
    // 新增分支时也不会再犯同样的错。
    return IgnorePointer(child: _buildIndicator(context));
  }

  /// 只决定"显示哪个指示器"，**不负责**命中过滤（外层已统一处理）。
  Widget _buildIndicator(BuildContext context) {
    // 长按倍速优先级最高：它需要"持续可见"让用户知道当前在快进
    if (isLongPressing) {
      return _CenterSlot(
        child: _Pill(
          icon: Icons.fast_forward,
          text: '${longPressSpeed.toStringAsFixed(1)}x 快进中',
          accent: true,
        ),
      );
    }

    return switch (gesture.mode) {
      GestureMode.brightness => _CenterSlot(
          child: _LevelIndicator(
            icon: Icons.brightness_6,
            value: gesture.currentBrightness,
            max: 100,
            label: '亮度',
          ),
        ),
      GestureMode.volume => _CenterSlot(
          child: _LevelIndicator(
            icon: Icons.volume_up,
            value: gesture.currentVolume,
            max: 100,
            label: '音量',
          ),
        ),
      GestureMode.seek => _CenterSlot(
          child: _Pill(
            icon: gesture.deltaRatio >= 0
                ? Icons.fast_forward
                : Icons.fast_rewind,
            text: _seekText(gesture),
          ),
        ),
      // none / dead：不显示任何东西（死区就该"什么都不发生"）
      GestureMode.none || GestureMode.dead => const SizedBox.shrink(),
    };
  }

  /// `+35s` / `-12s`（原型用 `Math.round(deltaSeconds)`）。
  static String _seekText(GestureState g) {
    final start = g.startPositionInVideo;
    final target = g.currentSeekTarget;
    final delta = (target - start).inSeconds;
    final sign = delta > 0 ? '+' : '';
    return '$sign${delta}s';
  }
}

/// 居中放置。
class _CenterSlot extends StatelessWidget {
  const _CenterSlot({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Center(child: child);
}

/// 胶囊型提示（快进/长按倍速）。
class _Pill extends StatelessWidget {
  const _Pill({
    required this.icon,
    required this.text,
    this.accent = false,
  });

  final IconData icon;
  final String text;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: PlayerUi.feedbackBg,
          borderRadius: BorderRadius.circular(PlayerUi.feedbackRadius),
          border: Border.all(
            color: accent ? PlayerUi.progressFilled : Colors.white24,
            width: 0.8,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 22,
                color: accent ? PlayerUi.progressFilled : Colors.white),
            const SizedBox(width: 10),
            Text(
              text,
              style: TextStyle(
                color: accent ? PlayerUi.progressFilled : Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 圆形电量式指示器（亮度/音量）。
///
/// 用 `CircularProgressIndicator` 而不是横向条：
/// 圆形在画面正中不会像横条那样"割裂"画面，也更像系统级的音量提示。
class _LevelIndicator extends StatelessWidget {
  const _LevelIndicator({
    required this.icon,
    required this.value,
    required this.max,
    required this.label,
  });

  final IconData icon;
  final double value;
  final double max;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ratio = (value / max).clamp(0.0, 1.0);
    return IgnorePointer(
      child: Container(
        width: PlayerUi.levelIndicatorSize,
        height: PlayerUi.levelIndicatorSize,
        decoration: const BoxDecoration(
          color: PlayerUi.feedbackBg,
          shape: BoxShape.circle,
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: PlayerUi.levelIndicatorSize - 12,
              height: PlayerUi.levelIndicatorSize - 12,
              child: CircularProgressIndicator(
                value: ratio,
                strokeWidth: 4,
                backgroundColor: Colors.white24,
                valueColor: const AlwaysStoppedAnimation(Colors.white),
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 20, color: Colors.white),
                const SizedBox(height: 2),
                Text(
                  '${value.round()}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                Text(
                  label,
                  style: const TextStyle(color: Colors.white60, fontSize: 10),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 首次进入的手势提示（原型 `flashGestureHint`）。
///
/// 只在**第一次**进入播放器时显示一次 ——
/// 每次都弹会干扰用户（原型用 `hintShown` 标记，只展示一次）。
class PlayerGestureHint extends StatelessWidget {
  const PlayerGestureHint({super.key});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: PlayerUi.feedbackBg,
            borderRadius: BorderRadius.circular(PlayerUi.feedbackRadius),
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _HintRow(icon: Icons.brightness_6, text: '左半屏上下滑调亮度'),
              SizedBox(height: 8),
              _HintRow(icon: Icons.volume_up, text: '右半屏上下滑调音量'),
              SizedBox(height: 8),
              _HintRow(icon: Icons.swipe, text: '横向滑动快进/快退'),
            ],
          ),
        ),
      ),
    );
  }
}

class _HintRow extends StatelessWidget {
  const _HintRow({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.white70),
          const SizedBox(width: 8),
          Text(text,
              style: const TextStyle(color: Colors.white, fontSize: 13)),
        ],
      );
}
