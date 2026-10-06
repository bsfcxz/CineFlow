/// U9 Medium / Expanded 的**回归守护**（审计里风险评级最高的一批）。
///
/// # 为什么这批不是纸上谈兵
///
/// 真机实测（Xiaomi M2012K11AC，1080×2400 @440dpi）：
///
///     竖屏：1080px ÷ (440/160) = 392.7 dp → **Compact**
///     横屏：2400px ÷ (440/160) = 872.7 dp → **Expanded**
///
/// **用户把手机横过来就会进到 Expanded 分支。** 所以"侧栏导航""页边距 32"
/// 都是真机上会出现的东西，不是平板专属。
///
/// # 这个批次改了什么
///
/// | 项 | Compact | Medium | Expanded |
/// |---|---|---|---|
/// | 导航形态 | 底部 Tab | 底部 Tab（**审计要求不切侧栏**） | 侧栏 72dp |
/// | 页边距 | 16（原值） | 24 | 32 |
/// | 内容最大宽 | 无限制 | 820 居中 | 820 居中 |
/// | 详情双栏 | 否 | 否 | 是 |
///
/// # 一个自己造出来又修掉的 bug
/// 侧栏第一版**漏了 `keys.shell.tab(i)`** —— 底栏有、侧栏没有。
/// 后果：Patrol 用例在横屏下会找不到 Tab（而竖屏全绿，极难发现）。
/// 已修，并在测试里断言"两种形态共用同一份键"。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/core/theme.dart';

/// 读源码并剥掉整行注释（否则注释里提到键名会造成假绿 —— 实测踩过）。
String _code(String rel) => File(rel)
    .readAsStringSync()
    .split('\n')
    .where((l) {
      final s = l.trimLeft();
      return !s.startsWith('//') && !s.startsWith('*');
    })
    .join('\n');

void main() {
  group('U9 · 真机断点换算（把"横屏就是 Expanded"变成断言）', () {
    // 真机 1080×2400 @440dpi —— 这个换算若变了，U9 的前提就变了
    const dpi = 440.0;
    double logicalWidth(int px) => px / (dpi / 160.0);

    test('竖屏 1080px → Compact（392.7dp）', () {
      final w = logicalWidth(1080);
      expect(w, closeTo(392.7, 0.1));
      expect(CfBreakpoints.of(w), CfBreakpoints.compact);
    });

    test('★ 横屏 2400px → Expanded（872.7dp）—— 转个手机就能触发', () {
      final w = logicalWidth(2400);
      expect(w, closeTo(872.7, 0.1));
      expect(
        CfBreakpoints.of(w),
        CfBreakpoints.expanded,
        reason: '横屏逻辑宽 872.7dp 应落 Expanded。\n'
            '若这里是 Compact，说明断点阈值被改过 —— U9 的侧栏/页边距全都失效。',
      );
    });
  });

  group('U9 · 页边距与内容宽度', () {
    test('页边距随窗口类递增，Compact 保持原值 16', () {
      expect(CfLayout.pageMarginFor(CfBreakpoints.compact), 16.0,
          reason: 'Compact 应保持 16 —— 改它会让竖屏观感变化（用户没要求）');
      expect(CfLayout.pageMarginFor(CfBreakpoints.medium), 24.0);
      expect(CfLayout.pageMarginFor(CfBreakpoints.expanded), 32.0);
      expect(
        CfLayout.pageMarginFor(CfBreakpoints.compact) <
            CfLayout.pageMarginFor(CfBreakpoints.medium),
        isTrue,
      );
      expect(
        CfLayout.pageMarginFor(CfBreakpoints.medium) <
            CfLayout.pageMarginFor(CfBreakpoints.expanded),
        isTrue,
      );
    });

    test('未知窗口类退化为 Compact 边距（不崩）', () {
      expect(CfLayout.pageMarginFor(999), 16.0);
      expect(CfLayout.pageMarginFor(-1), 16.0);
    });

    test('内容最大宽度存在且合理（防行长过长）', () {
      expect(CfLayout.maxContentWidth, greaterThan(600.0),
          reason: '太窄会让 Medium 也不够用');
      expect(CfLayout.maxContentWidth, lessThanOrEqualTo(900.0),
          reason: '超过 900dp 时 13sp 正文单行远超 60 字符 —— 眼睛回行易串行');
    });

    testWidgets('pageMarginOf 从 BuildContext 正确推出边距（三种宽度）', (tester) async {
      Future<double> marginAt(double w) async {
        late double m;
        await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: Size(w, 800)),
            child: Builder(builder: (ctx) {
              m = CfLayout.pageMarginOf(ctx);
              return const SizedBox();
            }),
          ),
        ));
        return m;
      }

      expect(await marginAt(400), 16.0, reason: 'Compact 竖屏');
      expect(await marginAt(700), 24.0, reason: 'Medium');
      expect(await marginAt(900), 32.0, reason: 'Expanded（横屏手机就是这一档）');
    });
  });

  group('U9 · 导航形态', () {
    test('Expanded 用侧栏；Compact/Medium 用底部 Tab', () {
      expect(CfLayout.useSideRail(CfBreakpoints.expanded), isTrue);
      expect(
        CfLayout.useSideRail(CfBreakpoints.medium),
        isFalse,
        reason: 'Medium 不该切侧栏 —— 审计明确要求"不切侧栏，\n'
            '避免本阶段引入导航重构"。600–840dp 用侧栏会让内容区变窄。',
      );
      expect(CfLayout.useSideRail(CfBreakpoints.compact), isFalse);
    });

    test('侧栏宽度是原型既定的 72dp', () {
      expect(CfLayout.sideRailWidth, 72.0);
    });

    test('详情双栏只在 Expanded 启用（Medium 两边都会太窄）', () {
      expect(CfLayout.detailTwoColumn(CfBreakpoints.expanded), isTrue);
      expect(CfLayout.detailTwoColumn(CfBreakpoints.medium), isFalse);
      expect(CfLayout.detailTwoColumn(CfBreakpoints.compact), isFalse);
    });
  });

  group('U9 · home_shell 源码约束（剥注释）', () {
    final src = _code('lib/pages/home_shell.dart');

    test('★ 两种导航形态共用同一份 Tab 键（横屏测试才不会失效）', () {
      final n = RegExp(r'keys\.shell\.tab\(i\)').allMatches(src).length;
      expect(
        n,
        greaterThanOrEqualTo(2),
        reason: '只找到 $n 处 keys.shell.tab(i)，期望 ≥2（底栏 + 侧栏）。\n'
            '这是本批**自己造出来又修掉**的 bug：侧栏第一版漏了键，\n'
            '后果是 Patrol 用例在横屏下找不到 Tab —— 而竖屏全绿，极难发现。',
      );
    });

    test('按断点决定导航形态，且 Medium 不切侧栏', () {
      expect(RegExp(r'CfLayout\.useSideRail\(').hasMatch(src), isTrue,
          reason: '导航形态没走断点判断');
      expect(RegExp(r'CfBreakpoints\.of\(').hasMatch(src), isTrue);
    });

    test('侧栏存在且用了 72dp 侧栏宽度令牌', () {
      expect(src.contains('_SideRail'), isTrue, reason: '侧栏被删了');
      expect(RegExp(r'CfLayout\.sideRailWidth').hasMatch(src), isTrue,
          reason: '侧栏宽度没用令牌（原型既定 72dp）');
    });

    test('侧栏也带无障碍语义（button + selected + label）', () {
      // 侧栏的 Semantics 在 _SideRail 里
      final rail = src.substring(src.indexOf('class _SideRail'));
      expect(rail.contains('Semantics('), isTrue,
          reason: '侧栏缺语义 —— 读屏用户不知道有几个 Tab、当前在哪个');
      expect(rail.contains('selected: i == index'), isTrue,
          reason: '侧栏缺 selected 状态');
      expect(rail.contains('label: _tabItems[i].label'), isTrue,
          reason: '侧栏缺 label');
    });
  });

  group('U9 · CfTapTarget 的命中行为（侧栏依赖它）', () {
    testWidgets('命中区边缘可点（opaque）', (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: CfTapTarget(
              size: 56,
              onTap: () => taps++,
              child: const Icon(Icons.home, size: 24),
            ),
          ),
        ),
      ));
      final c = tester.getCenter(find.byType(CfTapTarget));
      await tester.tapAt(c + const Offset(24, 0)); // 图标只有 24 宽，这里是空白
      await tester.pump();
      expect(taps, 1,
          reason: '命中区边缘点不中 —— HitTestBehavior 不是 opaque 时，\n'
              '48dp 的"撑出来的命中区"形同虚设。');
    });

    testWidgets('视觉子元素不被拉伸（Icon 仍是 24）', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: CfTapTarget(
              size: 56,
              onTap: () {},
              child: const Icon(Icons.home, size: 24),
            ),
          ),
        ),
      ));
      expect(tester.getSize(find.byType(Icon)), const Size(24, 24),
          reason: '图标被拉伸成 56×56 了 —— 应 Center 居中而非填满');
    });
  });
}
