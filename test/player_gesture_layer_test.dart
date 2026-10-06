/// 手势层的**命中顺序验证** —— 这是整套手势系统的承重假设。
///
/// ## 要验证的假设
/// 我在 `player_gesture_layer.dart` 的注释里写了：
/// > "UI 元素的 Listener 在命中测试中**先于**本层执行，
/// >  故这里读到的 `consumed` 已经反映了'是否点在 UI 上'"
///
/// **这是个假设，不是已知事实。** 若顺序反了（手势层先跑），
/// 那么点按钮时 `consumed` 还是 false → 手势层认为"点在空白处" →
/// **用户点播放按钮会同时触发亮度变化**。
/// 这种 bug 在真机上表现为"点一下就变暗"，很难归因。
///
/// 所以先写测试确认顺序，再往下建。若假设错了，就改用别的机制
/// （如 `Stack` 层级调整，或把 UI 命中判定改成基于坐标的区域表）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/player/presentation/widgets/player_gesture_layer.dart';

void main() {
  group('UiElementHitTest 标记机制', () {
    test('初始未消费', () {
      final h = UiElementHitTest();
      expect(h.consumed, isFalse);
    });

    test('consume 后为真，reset 后复原', () {
      final h = UiElementHitTest();
      h.consume();
      expect(h.consumed, isTrue);
      h.reset();
      expect(h.consumed, isFalse);
    });
  });

  group('★ 命中顺序：UI 元素是否先于手势层收到 pointerDown', () {
    testWidgets('点在 UI 按钮上 → 手势层不应收到 pointerDown', (tester) async {
      final hitTest = UiElementHitTest();
      var gestureDowns = 0;
      var buttonTaps = 0;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              // 底层：手势层铺满
              PlayerGestureLayer(
                hitTest: hitTest,
                onPointerDown: (_) => gestureDowns++,
                onPointerMove: (_) {},
                onPointerUp: () {},
                onPointerCancel: () {},
              ),
              // 上层：UI 按钮，包在 UiElementDetector 里
              Align(
                alignment: Alignment.center,
                child: UiElementDetector(
                  hitTest: hitTest,
                  child: GestureDetector(
                    onTap: () => buttonTaps++,
                    child: Container(
                      key: const ValueKey('btn'),
                      width: 80,
                      height: 80,
                      color: Colors.red,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ));

      // 点按钮中心
      await tester.tap(find.byKey(const ValueKey('btn')));
      await tester.pumpAndSettle();

      expect(buttonTaps, 1, reason: '按钮应被点到');
      expect(
        gestureDowns,
        0,
        reason: '★ 点在 UI 按钮上时手势层**不该**收到 pointerDown。\n'
            '若这里是 1，说明命中顺序与假设相反 →\n'
            '点播放按钮会同时触发亮度/音量手势（真机上极难归因）。',
      );
    });

    testWidgets('点在空白处 → 手势层收到 pointerDown', (tester) async {
      final hitTest = UiElementHitTest();
      var downs = 0;
      Offset? at;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              PlayerGestureLayer(
                hitTest: hitTest,
                onPointerDown: (p) {
                  downs++;
                  at = p;
                },
                onPointerMove: (_) {},
                onPointerUp: () {},
                onPointerCancel: () {},
              ),
              // UI 按钮放在角落，避免干扰
              Align(
                alignment: Alignment.topLeft,
                child: UiElementDetector(
                  hitTest: hitTest,
                  child: GestureDetector(
                    onTap: () {},
                    child: Container(width: 60, height: 60, color: Colors.blue),
                  ),
                ),
              ),
            ],
          ),
        ),
      ));

      // 点屏幕中下部（远离角落按钮）
      await tester.tapAt(const Offset(200, 500));
      await tester.pumpAndSettle();

      expect(downs, 1, reason: '空白处应触发手势');
      expect(at, isNotNull);
    });

    testWidgets('★ 上一次的 consume 不会影响下一次（每次 down 都 reset）', (tester) async {
      final hitTest = UiElementHitTest();
      var downs = 0;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              PlayerGestureLayer(
                hitTest: hitTest,
                onPointerDown: (_) => downs++,
                onPointerMove: (_) {},
                onPointerUp: () {},
                onPointerCancel: () {},
              ),
              Align(
                alignment: Alignment.topLeft,
                child: UiElementDetector(
                  hitTest: hitTest,
                  child: GestureDetector(
                    onTap: () {},
                    child: Container(
                      key: const ValueKey('b'),
                      width: 60,
                      height: 60,
                      color: Colors.blue,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ));

      // 先点按钮（置位 consumed）
      await tester.tap(find.byKey(const ValueKey('b')));
      await tester.pumpAndSettle();
      expect(downs, 0, reason: '点在按钮上不该触动手势');

      // 再点空白（应能触动手势 —— 若忘了 reset，这里会仍是 0）
      await tester.tapAt(const Offset(200, 500));
      await tester.pumpAndSettle();
      expect(downs, 1,
          reason: '第二次点空白必须能触动手势 —— \n'
              '若为 0，说明 consumed 标记没被重置，\n'
              '用户点过一次按钮后手势会永久失效。');
    });

    testWidgets('锁定时（enabled=false）手势层完全不响应', (tester) async {
      final hitTest = UiElementHitTest();
      var downs = 0;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              PlayerGestureLayer(
                hitTest: hitTest,
                enabled: false, // 锁定
                onPointerDown: (_) => downs++,
                onPointerMove: (_) {},
                onPointerUp: () {},
                onPointerCancel: () {},
              ),
            ],
          ),
        ),
      ));

      await tester.tapAt(const Offset(200, 400));
      await tester.pumpAndSettle();
      expect(downs, 0, reason: '锁定后必须屏蔽所有手势（规格 §9.5）');
    });
  });

  group('手势层事件转发', () {
    testWidgets('down → move → up 全链路', (tester) async {
      final hitTest = UiElementHitTest();
      final events = <String>[];
      final moves = <Offset>[];

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(children: [
            PlayerGestureLayer(
              hitTest: hitTest,
              onPointerDown: (_) => events.add('down'),
              onPointerMove: (p) => moves.add(p),
              onPointerUp: () => events.add('up'),
              onPointerCancel: () {},
            ),
          ]),
        ),
      ));

      final g = await tester.startGesture(const Offset(100, 300));
      await tester.pump();
      await g.moveTo(const Offset(140, 340));
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();

      expect(events, ['down', 'up']);
      expect(moves, isNotEmpty, reason: 'move 应被转发（坐标用于判定方向）');
    });

    testWidgets('cancel 被转发', (tester) async {
      final hitTest = UiElementHitTest();
      var cancels = 0;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(children: [
            PlayerGestureLayer(
              hitTest: hitTest,
              onPointerDown: (_) {},
              onPointerMove: (_) {},
              onPointerUp: () {},
              onPointerCancel: () => cancels++,
            ),
          ]),
        ),
      ));

      final g = await tester.startGesture(const Offset(100, 300));
      await tester.pump();
      await g.cancel();
      await tester.pumpAndSettle();
      expect(cancels, greaterThanOrEqualTo(1));
    });
  });
}
