/// **断言自证**：确认"检测底栏子树里的 BackdropFilter"这个断言逻辑有效。
///
/// ## 为什么单独写这个
/// 反向注入试了两次都不干净（两次都因为注释/import 缺失导致**编译错**，
/// 变红不是断言抓的）。与其反复折腾注入，不如**直接测断言逻辑本身**：
/// 造两个 widget 树（一个有 BackdropFilter、一个没有），
/// 用同一段 finder 断言，看它是否正确区分。
///
/// 这能证明"断言有效"，且不依赖改产品代码。
library;

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 与 `player_bar_transparency_test.dart` 里**完全相同**的 finder 逻辑。
Finder backdropIn(Key root) => find.descendant(
      of: find.byKey(root),
      matching: find.byType(BackdropFilter),
    );

const _root = Key('bars');

Future<void> pump(WidgetTester tester, {required bool withBlur}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Column(
          key: _root,
          children: [
            if (withBlur)
              BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                child: const SizedBox(width: 100, height: 30),
              ),
            const Text('1.0x', style: TextStyle(color: Colors.white)),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('★ 断言自证：BackdropFilter 检测有效', () {
    testWidgets('有 BackdropFilter → finder 找得到（断言会红）', (tester) async {
      await pump(tester, withBlur: true);
      expect(
        backdropIn(_root),
        findsOneWidget,
        reason: '这是**自证**：如果连这里都找不到，那么\n'
            '`player_bar_transparency_test` 的断言就是永远绿的假测试。',
      );
    });

    testWidgets('没有 BackdropFilter → finder 找不到（断言会绿）', (tester) async {
      await pump(tester, withBlur: false);
      expect(
        backdropIn(_root),
        findsNothing,
        reason: '正常（无模糊）时断言应通过 —— 证明断言不是"永远红"',
      );
    });
  });
}
