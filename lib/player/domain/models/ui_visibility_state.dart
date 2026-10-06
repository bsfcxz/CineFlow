/// UI 显隐与锁定状态（不可变）。
///
/// ## 与 HTML 原型的对账
/// 原型 `state.ui` = `{ visible, hideTimer }`，
/// `state.playback.isLocked` 也在 playback 里。
///
/// **本实现把 `isLocked` 挪到这里**，理由：
/// 锁定的作用是**屏蔽 UI 交互**（原型的 `pointerdown` 第一行就是
/// `if (state.playback.isLocked) return`），而不是改变播放行为 ——
/// 锁定时播放照常继续。语义上它属于"UI 可见性"这一族。
///
/// ⚠️ `hideTimer` 同样**不在状态里**（同 [GestureState] 的理由）：
/// Timer 是不可变状态的敌人，由 Controller 持有并 dispose。
library;

/// UI 显隐 + 锁定。
class UiVisibilityState {
  const UiVisibilityState({
    this.visible = true,
    this.isLocked = false,
    this.hintShown = false,
    this.fullscreen = false,
  });

  /// 控制层是否可见。
  final bool visible;

  /// 是否锁定（锁定后屏蔽一切手势，只保留锁按钮）。
  final bool isLocked;

  /// 手势提示是否已展示过（原型 `hintShown`：只提示一次，避免每次都弹）。
  final bool hintShown;

  /// 是否全屏。
  ///
  /// ⚠️ 这是**本地记录**的期望值，不是"当前是否真的全屏"。
  /// 系统可能因用户手势/分屏而改变实际状态，故 UI 显示全屏图标时
  /// 还应结合 `MediaQuery.orientationOf` 判断（见 PlayerPage 的同步逻辑）。
  final bool fullscreen;

  /// 控制层**实际**是否应渲染。
  ///
  /// ★ 这是"锁定强制隐藏 UI"这条规则的**单点表达**：
  ///   锁定时无论 [visible] 是什么都返回 false。
  ///
  ///   如果不做这个派生 getter，而让每个 Widget 各自判断
  ///   `visible && !isLocked`，则**漏一个地方就会出现"锁定了但某个浮层还在"**。
  ///   原型的 `renderUI()` 也是集中判断的。
  bool get controlsVisible => visible && !isLocked;

  /// 锁按钮是否可见。
  ///
  /// 锁定时**必须常亮** —— 否则用户锁上后没有任何入口能解锁，
  /// 只能杀进程。这是"锁定"最危险的地方，故单列一个 getter 明示。
  bool get lockButtonVisible => true;

  UiVisibilityState copyWith({
    bool? visible,
    bool? isLocked,
    bool? hintShown,
    bool? fullscreen,
  }) =>
      UiVisibilityState(
        visible: visible ?? this.visible,
        isLocked: isLocked ?? this.isLocked,
        hintShown: hintShown ?? this.hintShown,
        fullscreen: fullscreen ?? this.fullscreen,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UiVisibilityState &&
          other.visible == visible &&
          other.isLocked == isLocked &&
          other.hintShown == hintShown &&
          other.fullscreen == fullscreen;

  @override
  int get hashCode => Object.hash(visible, isLocked, hintShown, fullscreen);

  @override
  String toString() => 'UiVisibilityState(visible: $visible, '
      'locked: $isLocked, fullscreen: $fullscreen)';
}
