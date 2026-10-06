/// U4 卡片组件的**回归守护**。
///
/// # 这个批次修了什么
///
/// 1. **按压反馈**：`PosterCard` / `ContinueCard` 原为裸 `GestureDetector` ——
///    点了毫无视觉变化。这在"点了要等一下才跳页"的海报场景里最难受：
///    用户不确定有没有点上，会重复点。
///    这是本项目"按键没用"观感的主要来源之一（`UI-DESIGN.md` §3.3.2）。
/// 2. **无障碍语义**：海报/继续观看卡片原先**零语义**，读屏只能念出
///    一个无名可点区域。现在会念「《片名》，2024 年，电影，评分 8.5，已看」。
/// 3. **字缩钳制**：角标（9sp / 季集号）在 200% 字号下 → 18sp，
///    而角标容器只有 15px 高 → 文字被裁。已改 `CfText(clamp: true)`。
/// 4. **写死宽度**：`ContinueCard` 原写死 `width: 200`（审计 §2.1 点名）——
///    Compact 上占 55% 宽、大屏上只占 25%，显得稀疏。改为按断点给宽度。
///
/// # 断言分寸
/// 用**源码断言**（剥注释）+ **widget 测试**。
/// 卡片需要 `MediaProvider`（联网取图），故 widget 测试只覆盖不依赖网络的
/// 纯结构部分（`widthFor` 的断点行为），其余用源码断言守住"接线"。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/core/theme.dart';
import 'package:cineflow/widgets/media_cards.dart';

/// 读源码并**剥掉整行注释**。
///
/// ⚠️ 必须剥：注释里提到 `InkWell` / `Semantics` 会造成**假绿**
/// （这个坑在 `test/shell_tab_test.dart` 实测踩过 —— 当时
/// `SafeArea(top: false)` 写在注释里，导致反向注入失效）。
String _code(String rel) => File(rel)
    .readAsStringSync()
    .split('\n')
    .where((l) {
      final s = l.trimLeft();
      return !s.startsWith('//') && !s.startsWith('*');
    })
    .join('\n');

void main() {
  group('U4 · 卡片交互（源码约束）', () {
    final src = _code('lib/widgets/media_cards.dart');

    test('PosterCard / ContinueCard 不再用裸 GestureDetector', () {
      expect(
        src.contains('GestureDetector'),
        isFalse,
        reason: '卡片又用回了 GestureDetector —— 它**没有按压反馈**，\n'
            '用户点海报后没有任何视觉变化，会以为没点上而重复点。\n'
            '请用 InkWell（内含 Material，自带 ripple）。',
      );
    });

    test('卡片带无障碍语义（Semantics + 可读 label）', () {
      expect(src.contains('Semantics('), isTrue,
          reason: '卡片缺语义 —— 读屏只能念出无名可点区域');
      expect(
        RegExp(r"label:\s*\[").hasMatch(src),
        isTrue,
        reason: 'Semantics 的 label 应是拼装的（片名+年份+类型+评分），\n'
            '只写死一个词读屏信息量不足',
      );
    });

    test('角标/季集号用 CfText(clamp: true) —— 防 200% 字号被裁', () {
      // 角标容器高 15px、季集号容器高 ~18px；
      // 200% 下 9sp→18sp / 11sp→22sp 都会溢出。
      //
      // ⚠️ 正则**不能**写 `CfText\([^)]*clamp:` —— 第一版就是这么写的，
      //    结果只匹配到 1 处：因为角标那行的字符串里含 `⭐ ${r.toStringAsFixed(1)}`，
      //    **里面的 `)` 会提前终止 `[^)]*`**。改用 `.` + 非贪婪跨行匹配，
      //    并限制长度避免匹配到别处。
      final n = RegExp(r'CfText\([\s\S]{0,160}?clamp:\s*true').allMatches(src).length;
      expect(
        n,
        greaterThanOrEqualTo(2),
        reason: '角标与季集号的钳制丢了（当前匹配到 $n 处，期望 ≥2）。\n'
            '两者都在**固定高容器**里，200% 字号下会被裁掉文字。',
      );
    });

    test('ContinueCard 宽度按断点，不再写死 200', () {
      expect(
        RegExp(r'static double widthFor\(BuildContext').hasMatch(src),
        isTrue,
        reason: 'ContinueCard 宽度又写死了。原为 200：Compact 上占 55% 宽、\n'
            '大屏上只占 25%，显得稀疏零落（审计 §2.1 点名）。',
      );
      expect(
        RegExp(r'CfBreakpoints\.of\(').hasMatch(src),
        isTrue,
        reason: 'widthFor 没有用断点判断',
      );
    });
  });

  group('U4 · ContinueCard.widthFor 的断点行为', () {
    Future<double> widthAt(WidgetTester tester, double screenW) async {
      late double w;
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: Size(screenW, 800)),
          child: Builder(builder: (ctx) {
            w = ContinueCard.widthFor(ctx);
            return const SizedBox();
          }),
        ),
      ));
      return w;
    }

    testWidgets('Compact(<600dp) → 200', (tester) async {
      expect(await widthAt(tester, 400), 200.0);
    });

    testWidgets('Medium(600–840dp) → 230（比 Compact 宽）', (tester) async {
      final w = await widthAt(tester, 700);
      expect(w, 230.0);
      expect(w > 200.0, isTrue, reason: '大屏上卡片应更大，而不是维持小尺寸');
    });

    testWidgets('Expanded(≥840dp) → 260（再宽一档）', (tester) async {
      final w = await widthAt(tester, 1000);
      expect(w, 260.0);
      expect(w > 230.0, isTrue, reason: 'Expanded 应比 Medium 更宽');
    });

    testWidgets('断点边界：599→200，600→230（不跳档也不会卡在中间）', (tester) async {
      expect(await widthAt(tester, 599), 200.0);
      expect(await widthAt(tester, 600), 230.0);
    });
  });

  group('U9 · ContinueCard.heightFor —— 宽度涨了高度必须跟着涨', () {
    // 这是 U9 widget 测试抓到的**真 bug**：U4 把宽度改成断点相关后，
    // home_page 的容器高度仍是写死的 165，而缩略图是 16:9（高度随宽度涨）。
    // 实测：Medium 溢出 11.4dp、Expanded 溢出 28.3dp ——
    // 横屏直接报 `RenderFlex overflowed by 27 pixels on the bottom`。
    test('★ 高度必须容得下 16:9 缩略图 + 两行文字（1.3x 字缩下）', () {
      const lineHeight = 1.171875; // Roboto 默认行高系数
      for (final wc in [
        CfBreakpoints.compact,
        CfBreakpoints.medium,
        CfBreakpoints.expanded,
      ]) {
        final w = ContinueCard.widthForClass(wc);
        final h = ContinueCard.heightForClass(wc);
        // 1.3x = CfText 的钳制上限（标题/副标题都已 clamp）
        final need = w * 9 / 16 + 9 + 13 * lineHeight * 1.3 + 3 + 10 * lineHeight * 1.3;
        expect(
          h,
          greaterThanOrEqualTo(need),
          reason: '窗口类 $wc：卡宽 $w 需要至少 ${need.toStringAsFixed(1)}dp，'
              '但 heightFor 只给了 $h —— **会溢出**（横屏时文字被裁）。',
        );
      }
    });

    test('高度随断点单调不减，且 Compact 保持原值 165', () {
      final c = ContinueCard.heightForClass(CfBreakpoints.compact);
      final m = ContinueCard.heightForClass(CfBreakpoints.medium);
      final e = ContinueCard.heightForClass(CfBreakpoints.expanded);
      expect(c, 165.0, reason: 'Compact 应保持原值 —— 竖屏观感不能变');
      expect(m, greaterThanOrEqualTo(c));
      expect(e, greaterThanOrEqualTo(m));
      expect(e, greaterThan(c), reason: 'Expanded 卡片更宽，高度必须更大');
    });

    test('高度有上限（防公式失控把容器撑到整屏）', () {
      // 即使窗口类取值异常，也不该返回荒谬的大值
      expect(ContinueCard.heightForClass(999), lessThanOrEqualTo(400.0));
    });
  });

  group('U4 · CfBreakpoints 本身', () {
    test('三档边界与 M3 WindowSizeClass 一致', () {
      expect(CfBreakpoints.of(359), CfBreakpoints.compact);
      expect(CfBreakpoints.of(599), CfBreakpoints.compact);
      expect(CfBreakpoints.of(600), CfBreakpoints.medium);
      expect(CfBreakpoints.of(839), CfBreakpoints.medium);
      expect(CfBreakpoints.of(840), CfBreakpoints.expanded);
      expect(CfBreakpoints.of(1600), CfBreakpoints.expanded);
    });

    test('宽度为 0/负（布局尚未完成）时退化为 compact，不崩', () {
      expect(CfBreakpoints.of(0), CfBreakpoints.compact);
      expect(CfBreakpoints.of(-1), CfBreakpoints.compact);
    });

    test('columnsFor 夹在 [min, max] 且对 0 宽安全', () {
      expect(CfBreakpoints.columnsFor(0), 3);
      expect(CfBreakpoints.columnsFor(-100), 3);
      expect(CfBreakpoints.columnsFor(100000), 6);
    });
  });
}
