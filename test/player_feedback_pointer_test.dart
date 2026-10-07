/// **反馈层不得吞掉指针事件** —— 真机事故的回归测试。
///
/// ## 这个测试防的是什么（2026-10-07 真机实测事故）
///
/// `PlayerFeedbackLayer` 曾经只在"非长按"分支包 `IgnorePointer`：
/// ```dart
/// if (isLongPressing) {
///   return _CenterSlot(...);        // ← 漏了 IgnorePointer
/// }
/// return IgnorePointer(child: ...);  // ← 只有这里有
/// ```
/// `_CenterSlot` 是 `Center(child:)`，在 `Positioned.fill` 下**撑满全屏**，
/// 于是它把整屏的指针事件全吃掉。
///
/// 后果是**链式卡死**（用户实测现象）：
///   1. 长按 500ms → `isLongPressing = true` → 反馈层用 `Center` 盖住全屏
///   2. 全屏被盖 → 手势层收不到 `pointerUp` → 长按**永远结束不了**
///   3. 状态永久停在长按 → **UI 从此再也点不动**（单击/双击/滑动/按钮全失效）
///
/// 用户看到的是屏幕常驻「3.0x 快进中」，然后"整个播放器没反应"。
///
/// ## 为什么必须用 widget 测试守（静态分析抓不到）
/// `IgnorePointer` 漏包一处**语法完全合法**、analyze 零告警，
/// 单测状态机也全绿（因为控制器逻辑是对的，是**布局层**吞了事件）。
/// 唯一能抓住它的方法是**真的**在 widget 树上发指针事件，
/// 断言底下的手势层收到了。
///
/// ## 测试策略：从"被遮挡者的视角"断言
/// 不直接断言 `PlayerFeedbackLayer` 里有 `IgnorePointer`（那是实现细节），
/// 而是：把反馈层和手势层按**真实层序**叠起来，
/// 在反馈层正在显示指示器的**各种状态下**发点击，
/// 断言手势层**仍然收到**事件。
///
/// 这样即使将来换了别的实现方式（比如改用 `ExcludeSemantics`），
/// 只要"不吞事件"这个**契约**成立，测试就继续有效。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/player/domain/models/gesture_state.dart';
import 'package:cineflow/player/presentation/widgets/player_feedback.dart';

/// 按**真实层序**搭一个最小场景：
/// 底层 = 手势接收者，上层 = 反馈层（`Positioned.fill` 铺满）。
///
/// 层序取自 `player_ui_page.dart` 的 Stack：
///   1 视频 → 2 弹幕 → 3 手势层 → 4 反馈层 → 5 控制层
/// 即**反馈层在手势层之上** —— 这正是事故的成因。
Future<List<String>> pumpStack(
  WidgetTester tester, {
  required GestureState gesture,
  required bool isLongPressing,
}) async {
  final received = <String>[];

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            // ---- 手势层（底层）----
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (_) => received.add('down'),
                onPointerUp: (_) => received.add('up'),
                child: const SizedBox.expand(),
              ),
            ),
            // ---- 反馈层（上层，铺满）----
            Positioned.fill(
              child: PlayerFeedbackLayer(
                gesture: gesture,
                isLongPressing: isLongPressing,
                longPressSpeed: 3.0,
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
  return received;
}

void main() {
  const idle = GestureState();

  group('★ 反馈层绝不吞指针事件（真机事故回归）', () {
    testWidgets('★ 长按态：点击必须穿到下层手势层', (tester) async {
      // 这是**事故的精确复现**：长按态曾漏包 IgnorePointer，
      // 导致全屏被 Center 吃掉。
      final got = await pumpStack(
        tester,
        gesture: idle,
        isLongPressing: true,
      );

      await tester.tapAt(const Offset(200, 300));
      await tester.pumpAndSettle();

      expect(got, contains('down'),
          reason: '长按态下反馈层吃掉了 pointerDown —— 这正是让整个播放器\n'
              '「永久卡死」的那个 bug：手势层收不到事件 → 长按结束不了。\n'
              '若这条红，说明 IgnorePointer 又被挪进分支里了。');
      expect(got, contains('up'), reason: '长按态下连 pointerUp 也被吞');
    });

    testWidgets('亮度指示器态：点击必须穿到下层', (tester) async {
      final got = await pumpStack(
        tester,
        gesture: const GestureState(
          mode: GestureMode.brightness,
          currentBrightness: 60,
        ),
        isLongPressing: false,
      );
      await tester.tapAt(const Offset(200, 300));
      await tester.pumpAndSettle();
      expect(got, contains('down'),
          reason: '亮度指示器（圆形，居中央）曾是最可能吃事件的形态');
    });

    testWidgets('音量指示器态：点击必须穿到下层', (tester) async {
      final got = await pumpStack(
        tester,
        gesture: const GestureState(
          mode: GestureMode.volume,
          currentVolume: 40,
        ),
        isLongPressing: false,
      );
      await tester.tapAt(const Offset(200, 300));
      await tester.pumpAndSettle();
      expect(got, contains('down'));
    });

    testWidgets('seek 胶囊态：点击必须穿到下层', (tester) async {
      final got = await pumpStack(
        tester,
        gesture: const GestureState(
          mode: GestureMode.seek,
          startPositionInVideo: Duration(seconds: 100),
          currentSeekTarget: Duration(seconds: 130),
        ),
        isLongPressing: false,
      );
      await tester.tapAt(const Offset(200, 300));
      await tester.pumpAndSettle();
      expect(got, contains('down'));
    });

    testWidgets('★ 四个角落都要能穿（Center 是全屏覆盖，不是只有中间）', (tester) async {
      // 事故的特征是"**整屏**失效"，不只是中央。
      // 只测中心点会漏掉"Center 撑满"这个事实。
      final got = await pumpStack(
        tester,
        gesture: idle,
        isLongPressing: true, // 用最危险的那个状态
      );

      final corners = <Offset>[
        const Offset(20, 20),
        const Offset(780, 20),
        const Offset(20, 580),
        const Offset(780, 580),
      ];
      for (final c in corners) {
        await tester.tapAt(c);
        await tester.pumpAndSettle();
      }

      // 4 次点击 → 期望 4 个 down（若被吞则少于 4）
      final downs = got.where((e) => e == 'down').length;
      expect(downs, 4,
          reason: '只有 $downs/4 个角落的点击穿到了手势层。\n'
              '说明反馈层仍覆盖部分屏幕 —— "整屏卡死"会复现。');
    });

    testWidgets('空闲态（无指示器）也不该吃事件', (tester) async {
      final got = await pumpStack(
        tester,
        gesture: idle,
        isLongPressing: false,
      );
      await tester.tapAt(const Offset(200, 300));
      await tester.pumpAndSettle();
      expect(got, contains('down'));
    });
  });

  group('★ 指示器必须有语义标签（无障碍 + 可验证）', () {
    // ⚠️ **必须显式开启语义树**（实测踩过，白费两轮）
    //
    // `find.bySemanticsLabel` 依赖语义树；widget 测试**默认不生成**它，
    // 于是查找恒返回 0 —— 而 0 会被误读成"组件没写 Semantics"。
    //
    // 我正是这样误判了两次：先以为"嵌套顺序错"，改了代码；
    // 又以为"外层 IgnorePointer 丢弃语义"，再改一次 —— **两次都不对**。
    // 最后写最小实验（裸 Semantics / Center / IgnorePointer 各种套法）才查明：
    // **所有结构都能找到，唯一区别是实验里调了 ensureSemantics**。

    testWidgets('★ 亮度指示器带 Semantics 标签', (tester) async {
      final semantics = tester.ensureSemantics();

      await pumpStack(
        tester,
        gesture: const GestureState(
          mode: GestureMode.brightness,
          currentBrightness: 60,
        ),
        isLongPressing: false,
      );

      // ⚠️ 必须用 **RegExp** 而不是精确字符串（实测踩过，白费两轮）
      //
      // 真实语义树里 label 是 `"亮度\n60"` ——
      // Flutter 把 `Semantics(label:…, value:…)` 的 label 与 value
      // **合并成一个 label**（中间是换行）。
      // 而 `find.bySemanticsLabel('亮度')` 是**精确匹配** → 恒返回 0。
      //
      // 三种查法实测对比（同一次运行）：
      //   精确 '亮度'       -> 0 个
      //   RegExp('亮度')    -> 1 个   ✅
      //   RegExp('^亮度')   -> 1 个   ✅
      expect(
        find.bySemanticsLabel(RegExp('亮度')),
        findsOneWidget,
        reason: '亮度指示器应有语义标签 —— 读屏用户需要听到"亮度 60"，\n'
            '同时真机 uiautomator 也靠它确认指示器确实显示了。',
      );
      // 值也要能被读到
      expect(find.bySemanticsLabel(RegExp('60')), findsOneWidget,
          reason: '语义里应含当前数值（合并进 label 了）');

      // ⚠️ 必须**在测试体内**释放 —— 用 addTearDown 会晚于框架校验，
      //    报 "A SemanticsHandle was active at the end of the test"。
      semantics.dispose();
    });

    testWidgets('★ 音量指示器带 Semantics 标签', (tester) async {
      final semantics = tester.ensureSemantics();

      await pumpStack(
        tester,
        gesture: const GestureState(
          mode: GestureMode.volume,
          currentVolume: 40,
        ),
        isLongPressing: false,
      );
      expect(find.bySemanticsLabel(RegExp('音量')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('40')), findsOneWidget);

      semantics.dispose();
    });

    testWidgets('无手势时不应出现亮度/音量语义（避免误报）', (tester) async {
      final semantics = tester.ensureSemantics();

      await pumpStack(
        tester,
        gesture: const GestureState(),
        isLongPressing: false,
      );
      expect(find.bySemanticsLabel(RegExp('亮度')), findsNothing);
      expect(find.bySemanticsLabel(RegExp('音量')), findsNothing);

      semantics.dispose();
    });
  });

  group('结构性保证：IgnorePointer 在根节点', () {
    testWidgets('★ 根节点必须是 IgnorePointer（不依赖分支）', (tester) async {
      // 上一条 group 测"行为契约"，这条测"结构保证"——
      // 即使将来某个新分支忘了思考命中问题，只要根节点是 IgnorePointer，
      // 行为契约就自动成立。
      //
      // ⚠️ 断言方式：`PlayerFeedbackLayer` 的**直接子节点**必须是
      //    `IgnorePointer`。用 `find.descendant(...).first` 会撞到别的
      //    IgnorePointer（Flutter 内部很多组件自己带），故改为
      //    通过 Element 树取第一个子 widget。
      for (final longPress in [true, false]) {
        await pumpStack(
          tester,
          gesture: idle,
          isLongPressing: longPress,
        );

        final layerFinder = find.byType(PlayerFeedbackLayer);
        expect(layerFinder, findsOneWidget);

        // 取 PlayerFeedbackLayer 元素下的第一个 RenderObjectWidget 子节点
        final layerEl = tester.element(layerFinder);
        Widget? firstChild;
        layerEl.visitChildren((child) {
          firstChild ??= child.widget;
        });

        expect(
          firstChild,
          isA<IgnorePointer>(),
          reason: 'PlayerFeedbackLayer(${longPress ? "长按态" : "普通态"}) 的\n'
              '**直接子节点**应为 IgnorePointer，实际是 ${firstChild.runtimeType}。\n'
              '本项目原 bug 就是"只在部分分支包 IgnorePointer、漏了长按分支"，\n'
              '把命中过滤放在根节点能从结构上杜绝再犯。',
        );
      }
    });
  });
}
