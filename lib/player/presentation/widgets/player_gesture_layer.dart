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
///
/// ## ★ 双指缩放/平移（用户 2026-10-09 要求第 5 条）
/// `Listener` 天然收**每一个**指针的独立事件（down/move/up 各带
/// `pointer` 标识），这里维护 `Set<int> _pointers`：
/// · 第 1 根手指按下 → 照旧走单指手势
/// · 第 2 根手指落下 → `onPinchStart`（宿主进 pinch 模式，
///   单指手势与长按计时**全部短路**）
/// · 进行中 → 每次 move 用"两指间距比值 + 中点位移"回调
/// · 最后一根抬起 → `onPinchEnd`
///
/// ## 为什么不用 `GestureDetector.onScaleUpdate`
/// 它与本层的 `Listener` 会形成**识别器竞争**（同一 pointer 上排他），
/// 一旦 scale 识别器赢走事件，单击/长按/拖动全失效 —— 那正是本仓库
/// 当初从 `GestureDetector` 换到 `Listener` 的原因（见文件头）。
/// 直接在原始指针流上算 pinch，零竞争。
class PlayerGestureLayer extends StatefulWidget {
  const PlayerGestureLayer({
    super.key,
    required this.hitTest,
    required this.onPointerDown,
    required this.onPointerMove,
    required this.onPointerUp,
    required this.onPointerCancel,
    this.onPinchStart,
    this.onPinchUpdate,
    this.onPinchEnd,
    this.enabled = true,
  });

  final UiElementHitTest hitTest;
  final void Function(Offset local) onPointerDown;
  final void Function(Offset local) onPointerMove;
  final VoidCallback onPointerUp;
  final VoidCallback onPointerCancel;

  /// 双指开始/更新/结束（见类注释）。单指场景不触发。
  final VoidCallback? onPinchStart;
  final void Function(double scaleRatio, Offset focalDelta)? onPinchUpdate;
  final VoidCallback? onPinchEnd;

  /// 锁定时置 false（规格 §9.5：PointerDown 直接 return）。
  final bool enabled;

  @override
  State<PlayerGestureLayer> createState() => _PlayerGestureLayerState();
}

class _PlayerGestureLayerState extends State<PlayerGestureLayer> {
  /// 当前按下的指针集合（**含**第 1 根；size ≥ 2 = pinch 中）。
  final Set<int> _pointers = {};

  /// 各指针最近位置（算间距与中点用）。
  final Map<int, Offset> _positions = {};

  /// pinch 起始时两指间距（比值基准，避免首帧抖动）。
  double _startSpan = 0;

  /// pinch 起始时两指中点（平移基准）。
  Offset _startFocal = Offset.zero;

  bool get _pinching => _pointers.length >= 2;

  void _down(PointerDownEvent e) {
    _pointers.add(e.pointer);
    _positions[e.pointer] = e.localPosition;
    if (_pointers.length == 2) {
      // 第 2 根手指落下：进入 pinch。
      // ⚠️ 此刻必须**取消**单指语义（含长按计时器）——
      //    由宿主在 onPinchStart 里调 `gestureStateProvider.notifier.abort()`。
      _startSpan = _span;
      _startFocal = _focal;
      widget.onPinchStart?.call();
      return; // pinch 态下不派发单指 down
    }
    if (!_pinching) widget.onPointerDown(e.localPosition);
  }

  void _move(PointerMoveEvent e) {
    _positions[e.pointer] = e.localPosition;
    if (_pinching) {
      if (_startSpan <= 0) return; // 尚未成对（首帧保护）
      widget.onPinchUpdate?.call(_span / _startSpan, _focal - _startFocal);
      return;
    }
    widget.onPointerMove(e.localPosition);
  }

  void _up(PointerUpEvent e) {
    _pointers.remove(e.pointer);
    _positions.remove(e.pointer);
    if (_pinching) return; // 还有手指在屏上，继续 pinch
    if (_startSpan > 0) {
      // 最后一根手指抬起且之前在 pinch ⇒ 结束 pinch
      _startSpan = 0;
      widget.onPinchEnd?.call();
      return;
    }
    widget.onPointerUp();
  }

  void _cancel(PointerCancelEvent e) {
    final wasPinch = _pinching || _startSpan > 0;
    _pointers.remove(e.pointer);
    _positions.remove(e.pointer);
    if (wasPinch) {
      _startSpan = 0;
      widget.onPinchEnd?.call();
      return;
    }
    widget.onPointerCancel();
  }

  double get _span {
    final it = _pointers.toList();
    if (it.length < 2) return 0;
    return (_positions[it[0]]! - _positions[it[1]]!).distance;
  }

  Offset get _focal {
    final it = _pointers.toList();
    if (it.length < 2) return _positions[it.first] ?? Offset.zero;
    return Offset(
      (_positions[it[0]]!.dx + _positions[it[1]]!.dx) / 2,
      (_positions[it[0]]!.dy + _positions[it[1]]!.dy) / 2,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        if (!widget.enabled) return;
        // 本次序列起始时重置标记（上一次的 consume 不该影响这一次）
        widget.hitTest.reset();
        // ⚠️ 这里读 `consumed` **只在[手势层不在最底层]时才有意义**。
        //
        // 正常布局下（本层是 Stack 第一个子节点）点在 UI 元素上时，
        // `UiElementDetector` 的 `opaque` 会**截断命中路径**，
        // 本层的 `onPointerDown` 根本不会被调用 —— 也就是走不到这一行。
        //
        // 所以这一句是**补充保险**（见 `UiElementHitTest` 的类注释）：
        // 当某个 UI 元素用了 `translucent`（opaque 截断不成立），
        // 本层会被派发，此时靠这个标记挡住。
        //
        // ❌ 曾经的错说法：「UI 元素的 Listener 先于本层执行，故 consumed 已置位」。
        //    那是错的，且与文件头的机制说明自相矛盾 —— 已由
        //    `test/player_gesture_mechanism_test.dart` 实证纠正。
        if (widget.hitTest.consumed) return;
        _down(e);
      },
      onPointerMove: (e) {
        if (!widget.enabled) return;
        if (widget.hitTest.consumed) return;
        _move(e);
      },
      onPointerUp: (e) {
        if (!widget.enabled) {
          // 锁定状态下也要复位，否则解锁后残留 active 手势
          widget.onPointerCancel();
          return;
        }
        _up(e);
      },
      onPointerCancel: (e) => _cancel(e),
      child: const SizedBox.expand(),
    );
  }
}
