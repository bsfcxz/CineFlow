/// U3 轮播的**回归守护**。
///
/// # 这个批次修了什么（三条）
///
/// 1. **标题字缩钳制**：原为裸 `fontSize: 24`，200% 系统字号下 → 48sp 单行，
///    而轮播高只有屏高的 34%（夹 230–420）—— 48sp 会把简介与标签挤出可视区，
///    且 `maxLines: 1 + ellipsis` 会**静默截断片名**（用户以为"名字被吃了"）。
/// 2. **页码指示器此前完全没有**：轮播每 5 秒自动翻页，界面上零反馈 ——
///    用户不知道"共几张、现在第几张"，也判断不出还有没有下一张。
///    新增可点圆点（视觉 6px，命中 32dp，带语义）。
/// 3. **断点高度**：Medium/Expanded 下主视觉放大 15%（夹到 480）——
///    这是 `CfBreakpoints` 的**首次真实采用**。
///
/// # 为什么分两类断言（widget + 源码）
/// · **widget 测试**证明"渲染出来的行为"：命中区多大、语义能不能被找到、
///   标题在 2.0x 下到底缩到多少 —— 这些**源码看不出来**。
/// · **源码断言**证明"轮播真的用了这些件"：轮播是私有 `_Carousel`，
///   无法直接构造；而"有没有接线"正是本项目反复踩过的坑
///   （`HistoryPage` 做好了却没注册路由、`default_rate` 有读无写）。
///
/// ⚠️ 源码断言**必须先剥注释** —— 否则注释里提到 `CfText` 会造成假绿。
///    这个坑在 `test/shell_tab_test.dart` 里实测踩过（当时是 `SafeArea(top: false)`
///    写在注释里导致反向注入失效）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/core/theme.dart';

/// 读源码并剥掉整行注释（见文件头说明）。
String _code(String rel) => File(rel)
    .readAsStringSync()
    .split('\n')
    .where((l) {
      final s = l.trimLeft();
      return !s.startsWith('//') && !s.startsWith('*');
    })
    .join('\n');

void main() {
  group('U3 · CfTapTarget（指示器命中的基础）', () {
    testWidgets('命中区是 size × size，且视觉子元素居中不被拉伸', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: CfTapTarget(
              size: 48,
              onTap: () {},
              semanticLabel: '测试',
              child: const SizedBox(width: 6, height: 6),
            ),
          ),
        ),
      ));
      final box = tester.getSize(find.byType(CfTapTarget));
      expect(box.width, 48, reason: '命中区宽度应为 size');
      expect(box.height, 48, reason: '命中区高度应为 size');

      // 视觉子元素仍是 6×6 —— 没被 SizedBox 拉伸（这是"直接把尺寸改大"做不到的）
      final inner = tester.getSize(find.byType(SizedBox).last);
      expect(inner.width, 6, reason: '视觉元素被拉伸了：应居中而非填满');
      expect(inner.height, 6);
    });

    testWidgets('带 semanticLabel 时暴露可读语义（读屏可用）', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: CfTapTarget(
              size: 48,
              onTap: () {},
              semanticLabel: '第 1 张，共 3 张',
              child: const SizedBox(width: 6, height: 6),
            ),
          ),
        ),
      ));
      expect(
        find.bySemanticsLabel('第 1 张，共 3 张'),
        findsOneWidget,
        reason: '指示器缺少可读语义 —— 读屏用户不知道自己在第几张',
      );
      handle.dispose();
    });

    testWidgets('onTap 在命中区边缘也能触发（视觉只有 6px）', (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: CfTapTarget(
              size: 48,
              onTap: () => taps++,
              child: const SizedBox(width: 6, height: 6),
            ),
          ),
        ),
      ));
      // 点命中区边缘（离中心 20px）—— 那里视觉上是"空白"
      final c = tester.getCenter(find.byType(CfTapTarget));
      await tester.tapAt(c + const Offset(20, 0));
      await tester.pump();
      expect(taps, 1, reason: '命中区边缘点不中 —— HitTestBehavior 没设对');
    });
  });

  group('U3 · CfText 字缩钳制（轮播标题靠它）', () {
    testWidgets('标题（≥14sp）在 2.0x 系统字号下被钳到 1.3x', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
          child: const Scaffold(
            body: Center(child: CfText('片名', style: Cf.pageTitle)),
          ),
        ),
      ));
      final t = tester.widget<Text>(find.text('片名'));
      expect(t.textScaler?.scale(20), closeTo(26.0, 0.01),
          reason: '20sp 标题在 2.0x 下应被钳到 20×1.3=26，而不是 40');
    });

    testWidgets('正文（<14sp）跟随系统，不钳制', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
          child: const Scaffold(
            body: Center(child: CfText('正文', style: Cf.body)),
          ),
        ),
      ));
      final t = tester.widget<Text>(find.text('正文'));
      expect(t.textScaler, isNull,
          reason: '正文不该被钳制 —— 用户调大字号是真实需求（无障碍原则）');
    });
  });

  group('U3 · 轮播源码约束（剥注释后断言）', () {
    final src = _code('lib/pages/home_page.dart');

    test('轮播标题用 CfText（带字缩钳制），不是裸 Text', () {
      expect(
        RegExp(r'CfText\(item\.displayTitle').hasMatch(src),
        isTrue,
        reason: '轮播标题改回了裸 Text。\n'
            '24sp 在 200% 字号下 → 48sp，而轮播高只有屏高的 34%，\n'
            '会把简介与标签挤出可视区，且 maxLines:1 会**静默截断片名**。',
      );
    });

    test('轮播有页码指示器，每个点走 CfTapTarget（命中区达标）', () {
      expect(src.contains('CfTapTarget('), isTrue,
          reason: '指示器丢了，或改回了裸 GestureDetector ——\n'
              '6px 的圆点裸放是**点不中**的（审计实测最小可点元素仅 16×16）。');
      expect(
        RegExp(r'semanticLabel:').hasMatch(src),
        isTrue,
        reason: '指示器缺可读语义 —— 读屏用户不知道自己在第几张',
      );
    });

    test('轮播高度走断点（Compact 基准，Medium/Expanded 放大）', () {
      expect(
        RegExp(r'CfBreakpoints\.of\(').hasMatch(src),
        isTrue,
        reason: '轮播高度又变成不分断点的定值了 —— 大屏上主视觉会显得局促。\n'
            '这是 CfBreakpoints 的首次真实采用，删掉等于让断点工具继续闲置。',
      );
    });
  });
}
