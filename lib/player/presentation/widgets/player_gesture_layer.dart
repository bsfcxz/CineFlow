/// 手势层（规格 §9）—— 用 `Listener` 捕获原始指针事件。
///
/// ## 为什么用 `Listener` 而不是 `GestureDetector`
/// 规格要求"长按 500ms 进 3.0x 快进 + 同时支持横滑 seek + 竖滑调亮度/音量"。
/// `GestureDetector` 的识别器之间会**竞争**（长按与拖拽同一个 pointer 上有
/// 排他性，某个识别器赢了其他就收不到后续事件），而这里需要
/// **自己精确控制"何时取消长按"**（原型：移动超 10px 即取消）。
/// 用 `Listener` 拿到原始 down/move/up/cancel 后，这套状态机才能照原型实现。
///
/// ## UI 元素命中判定（规格 §9.1）
/// 手势必须**不从按钮/面板/进度条上起手**，否则点按钮会顺带触发亮度变化。
/// 原型用 `target.closest('button, .side-panel, ...')`。
///
/// ## ⚠️ 真正起作用的机制（已用测试实证，别记错）
///
/// 我最初在这段注释里写的是"UI 元素的 Listener 先于手势层执行，
/// 所以手势层读到 `consumed` 已是 true"。**那个说法是错的** ——
/// `test/player_gesture_mechanism_test.dart` 实测证明真实机制是：
///
/// ```
/// Stack 命中顺序：从**最后一个子节点**（最上层）往前测
///   · HitTestBehavior.opaque      → 命中后返回 true → **停止**测试下层
///   · HitTestBehavior.translucent → 命中后返回 false → **继续**测试下层
/// ```
///
/// 因为 [UiElementDetector] 用的是 `opaque`，而**手势层放在 Stack 最下面**，
/// 所以点在 UI 元素上时**手势层根本不在命中路径里** ——
/// 它的 `onPointerDown` 压根不会被调用（不是"被 consumed 挡住"）。
///
/// **这带来一条硬约束**：
/// > [PlayerGestureLayer] **必须**是 Stack 的第一个子节点（最底层）。
///
/// 若有人把它挪到最上面，`translucent` 会让它先派发，此时 `consumed`
/// 尚未置位 → **点播放按钮会同时改变亮度**。
/// 那个反例也被上述测试固化下来了（它断言"手势层在上时先收到事件"），
/// 所以这个错误布局**不会静默通过**。
library;

import 'package:flutter/material.dart';

/// 标记"这是 UI 元素"—— 手势层会忽略从它上面开始的按下。
///
/// ## ⚠️ 本类**不是**主要防线（别误以为它兜住了一切）
/// 真正起作用的是 `Stack` 命中顺序 + [UiElementDetector] 的 `opaque`
/// （见本文件头部的机制说明）。本标记是一个**补充保险**：
/// 当 UI 元素用的是 `translucent`（例如某些自绘控件需要让事件穿透），
/// `opaque` 的截断就不成立，此时靠这个标记仍能挡住手势层。
///
/// 两条防线同时存在，但**主防线是布局顺序**。若把手势层挪到最上面，
/// 本标记会因为"派发顺序早于置位"而失效。
class UiElementHitTest {
  /// 本次指针序列是否命中过 UI 元素。
  bool _consumed = false;

  /// 由 UI 元素在 pointerDown 时调用。
  void consume() => _consumed = true;

  /// 手势层在 pointerDown 时查询（重置在 [reset]，由手势层负责）。
  bool get consumed => _consumed;

  /// 一次指针序列结束时重置（在 up/cancel 后调用）。
  void reset() => _consumed = false;
}

/// 包在 UI 元素外层，声明"这里的按下归我"。
///
/// 用法：把手势层作为**底层**（`Stack` 最下面），UI 元素叠在上面并各包一层
/// [UiElementDetector]。这样点按钮时按钮的 Listener 先跑（命中测试从上往下），
/// 标记被置位，底层手势层读到后直接 return。
class UiElementDetector extends StatelessWidget {
  const UiElementDetector({
    super.key,
    required this.hitTest,
    required this.child,
  });

  final UiElementHitTest hitTest;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => hitTest.consume(),
      child: child,
    );
  }
}

/// 手势层：铺满视频区域，把原始指针事件翻译成 `GestureController` 的调用。
///
/// ## 关键：`behavior` 必须是 `translucent`
/// · `opaque` → 吃掉所有事件，上面的 UI 按钮就点不到了
/// · `deferToChild` → 子节点（视频纹理）不参与命中时会漏掉手势
/// · `translucent` → **自己收到事件的同时仍让上层 UI 拿到** —— 正确选择
class PlayerGestureLayer extends StatelessWidget {
  const PlayerGestureLayer({
    super.key,
    required this.hitTest,
    required this.onPointerDown,
    required this.onPointerMove,
    required this.onPointerUp,
    required this.onPointerCancel,
    this.enabled = true,
  });

  final UiElementHitTest hitTest;
  final void Function(Offset local) onPointerDown;
  final void Function(Offset local) onPointerMove;
  final VoidCallback onPointerUp;
  final VoidCallback onPointerCancel;

  /// 锁定时置 false（规格 §9.5：PointerDown 直接 return）。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        if (!enabled) return;
        // 本次序列起始时重置标记（上一次的 consume 不该影响这一次）
        hitTest.reset();
        // ⚠️ UI 元素的 Listener 在命中测试中**先于**本层执行，
        //    故这里读到的 consumed 已经反映了"是否点在 UI 上"。
        if (hitTest.consumed) return;
        onPointerDown(e.localPosition);
      },
      onPointerMove: (e) {
        if (!enabled) return;
        if (hitTest.consumed) return;
        onPointerMove(e.localPosition);
      },
      onPointerUp: (_) {
        if (!enabled) {
          // 锁定状态下也要复位，否则解锁后残留 active 手势
          onPointerCancel();
          return;
        }
        onPointerUp();
      },
      onPointerCancel: (_) => onPointerCancel(),
      child: const SizedBox.expand(),
    );
  }
}
