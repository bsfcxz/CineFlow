/// 确定手势层"UI 元素优先"的**真实机制** —— 不是猜，是测出来。
///
/// ## 为什么要专门测这个
/// 我在 `player_gesture_layer.dart` 的注释里写：
/// > "UI 元素的 Listener 在命中测试中**先于**本层执行"
///
/// **这个说法可能是错的。** Flutter 的规则是：
///   · `HitTestBehavior.opaque` → 命中后 `return true` → **Stack 停止**继续测试下层
///   · `HitTestBehavior.translucent` → 加入结果但 `return false` → **继续**测试下层
///   · 事件按**加入命中结果的顺序**派发
///
/// 若手势层在下（Stack 第一个子节点），UI 元素在上（opaque），
/// 那么 Stack 命中到 UI 元素就**停住**了 —— 手势层根本不在命中路径里，
/// 于是 `onPointerDown` 不是"被 consumed 挡住"，而是**压根没被调用**。
///
/// 这个区别很重要：**若有人把手势层挪到 Stack 最上面，机制就会静默失效**
/// （那时手势层先派发，读到的 consumed 还是 false → 点按钮会同时改亮度）。
/// 本测试把"必须把手势层放在最下面"这个约束固化下来。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/player/presentation/widgets/player_gesture_layer.dart';

/// 记录两个 Listener 的调用顺序。
class _Probe {
  final List<String> order = [];
}

void main() {
  group('★ 机制确认：手势层在下 + UI 元素在上（本项目采用的布局）', () {
    testWidgets('UI 元素 opaque 会截断命中路径 → 手势层完全收不到事件', (tester) async {
      final probe = _Probe();
      final hitTest = UiElementHitTest();

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(children: [
            // 下：手势层
            PlayerGestureLayer(
              hitTest: hitTest,
              onPointerDown: (_) => probe.order.add('gesture'),
              onPointerMove: (_) {},
              onPointerUp: () {},
              onPointerCancel: () {},
            ),
            // 上：UI 元素（UiElementDetector 用 opaque）
            Align(
              alignment: Alignment.center,
              child: UiElementDetector(
                hitTest: hitTest,
                child: GestureDetector(
                  onTap: () => probe.order.add('button-tap'),
                  child: Container(
                    key: const ValueKey('b'),
                    width: 80,
                    height: 80,
                    color: Colors.red,
                  ),
                ),
              ),
            ),
          ]),
        ),
      ));

      await tester.tap(find.byKey(const ValueKey('b')));
      await tester.pumpAndSettle();

      expect(probe.order, contains('button-tap'));
      expect(
        probe.order,
        isNot(contains('gesture')),
        reason: '手势层在下时，UI 元素（opaque）会截断命中路径，\n'
            '手势层收不到 pointerDown。这是本布局能工作的**真正原因**。',
      );
    });
  });

  group('★ 反证：手势层若放到最上面，标记机制就失效了', () {
    testWidgets('手势层在上（translucent）→ 先于 UI 元素派发 → consumed 还没置位', (tester) async {
      final probe = _Probe();
      final hitTest = UiElementHitTest();

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(children: [
            // 下：UI 元素
            Align(
              alignment: Alignment.center,
              child: UiElementDetector(
                hitTest: hitTest,
                child: GestureDetector(
                  onTap: () => probe.order.add('button-tap'),
                  child: Container(
                    key: const ValueKey('b2'),
                    width: 80,
                    height: 80,
                    color: Colors.red,
                  ),
                ),
              ),
            ),
            // 上：手势层（translucent → 不截断，UI 元素仍能被命中）
            PlayerGestureLayer(
              hitTest: hitTest,
              onPointerDown: (_) => probe.order.add('gesture'),
              onPointerMove: (_) {},
              onPointerUp: () {},
              onPointerCancel: () {},
            ),
          ]),
        ),
      ));

      await tester.tap(find.byKey(const ValueKey('b2')));
      await tester.pumpAndSettle();

      // 这条断言记录的是**已知风险**，不是期望的正确行为：
      // 手势层在上时会先派发 `gesture`，此时 consumed 尚未置位。
      expect(
        probe.order.first,
        'gesture',
        reason: '这是**反证**：手势层放在 Stack 最上面时，\n'
            '它的 onPointerDown 会先于 UI 元素派发 → 读到的 consumed=false\n'
            '→ 点按钮会同时触发亮度/音量手势。\n'
            '所以 **PlayerGestureLayer 必须放在 Stack 最下面**，\n'
            '不能靠"标记机制"单独兜住顺序问题。',
      );
    });
  });

  group('正确布局下的完整回归', () {
    testWidgets('点按钮：只有按钮响应；点空白：只有手势响应', (tester) async {
      final probe = _Probe();
      final hitTest = UiElementHitTest();

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(children: [
            PlayerGestureLayer(
              hitTest: hitTest,
              onPointerDown: (_) => probe.order.add('gesture'),
              onPointerMove: (_) {},
              onPointerUp: () {},
              onPointerCancel: () {},
            ),
            Align(
              alignment: Alignment.topLeft,
              child: UiElementDetector(
                hitTest: hitTest,
                child: GestureDetector(
                  onTap: () => probe.order.add('button-tap'),
                  child: Container(
                    key: const ValueKey('b3'),
                    width: 70,
                    height: 70,
                    color: Colors.red,
                  ),
                ),
              ),
            ),
          ]),
        ),
      ));

      probe.order.clear();
      await tester.tap(find.byKey(const ValueKey('b3')));
      await tester.pumpAndSettle();
      expect(probe.order, contains('button-tap'));
      expect(probe.order, isNot(contains('gesture')),
          reason: '点按钮不该触动手势');

      probe.order.clear();
      await tester.tapAt(const Offset(250, 500));
      await tester.pumpAndSettle();
      expect(probe.order, ['gesture'], reason: '点空白只该触动手势');
    });
  });
}
