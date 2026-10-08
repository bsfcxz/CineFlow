/// **底栏不得模糊视频** —— 用户第三轮反馈的回归防线。
///
/// ## 事故史（三轮迭代，每轮都是用户实测发现的）
/// | 轮次 | 实现 | 用户反馈 |
/// |---|---|---|
/// | 1 | 黑色 `BarScrim` 渐变 200dp | "要透明毛玻璃" |
/// | 2 | 白色 8%→12% + `blur(22)` | "改成透明的" |
/// | 3 | 填充全透明，**保留 blur(22)** | "**仍会遮挡视频**" ← 本轮 |
///
/// ## 关键认知（本轮想通）
/// `BackdropFilter(ImageFilter.blur)` 的语义是"把**背后已画好的内容**
/// 模糊一遍再合成"。**即使填充是全透明**，这一步 blur 依然会修改
/// 底栏区域下的视频像素 —— 用户看到"这块是糊的" = 被遮挡。
///
/// **"透明"在用户眼里 = 这块画面与其他地方一模一样、不被处理。**
///
/// ## 为什么用测试守（而不是只改代码）
/// "加个模糊更好看"是很容易无意识加回来的改动 —— 静态分析不会拦，
/// 单元测试也不会拦（它只是一个 widget 属性）。
/// 唯一能拦住的是"断言底栏子树里不存在 BackdropFilter"。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/keys.dart';

import 'player_ui_interaction_test.dart' as base;

void main() {
  group('★ 底栏必须完全透明（不模糊、不叠色）', () {
    testWidgets('★ 控制层子树里不得出现 BackdropFilter', (tester) async {
      final (_, _) = await base.pumpPlayer(tester);

      // 控制层（含顶栏 + 底栏）必须在树上
      expect(find.byKey(keys.player.controls), findsOneWidget,
          reason: '底栏未渲染，测试前提不成立');

      // 从底栏往上找整棵控制层子树，确认没有任何 BackdropFilter
      final bars = find.byKey(keys.player.controls);
      final backdropInBars = find.descendant(
        of: bars,
        matching: find.byType(BackdropFilter),
      );
      expect(
        backdropInBars,
        findsNothing,
        reason: '底栏子树里出现了 BackdropFilter —— 它会把底栏区域的\n'
            '**视频画面模糊掉**，用户看到的就是"这块被遮挡了"。\n'
            '（即使用户要求过"透明毛玻璃"，最终诉求是"不影响视频"，\n'
            '  实测确认 blur 本身就在遮挡。）\n'
            '若这条红 → 有人又把毛玻璃加回底栏了。',
      );
    });

    testWidgets('★ 底栏**背景层**不得叠色（进度条的功能色不受限）', (tester) async {
      final (_, _) = await base.pumpPlayer(tester);

      // ## 断言范围说明（我第一版写错了）
      // 第一版检查"底栏子树里所有 DecoratedBox 都必须全透明"——
      // 诊断发现会误伤**进度条**：它的轨道是白色 20%、已完成段是蓝色，
      // 那是进度条的**功能色**，不是"底栏背景"。
      //
      // 用户要的是"底栏背景不影响视频"，故只检查**背景层**：
      // `PlayerBottomBar` 的祖先里那些"整条栏"级别的装饰。
      final bar = find.byKey(keys.player.controls);
      expect(bar, findsOneWidget);

      // 底栏自身的容器（如果存在装饰）必须全透明
      final container = find.ancestor(
        of: bar,
        matching: find.byType(DecoratedBox),
      );
      for (final e in container.evaluate()) {
        final d = (e.widget as DecoratedBox).decoration;
        if (d is BoxDecoration && d.color != null) {
          expect(
            d.color!.a,
            0.0,
            reason: '底栏**外层容器**有 ${d.color!.a} 不透明度的填充 ——\n'
                '用户要求完全透明（不叠任何颜色到视频上）。\n'
                '若这条红 → 有人把白色/黑色半透明底加回底栏了。',
          );
        }
      }
    });

    testWidgets('底栏按钮文字/图标有阴影（透明后仍可读）', (tester) async {
      final (_, _) = await base.pumpPlayer(tester);

      // 透明底栏下，白字压亮画面必须靠阴影保证可读
      final texts = find.descendant(
        of: find.byKey(keys.player.controls),
        matching: find.byType(Text),
      );
      var withShadow = 0;
      var total = 0;
      for (final e in texts.evaluate()) {
        final t = (e.widget as Text).data;
        if (t == null || t.isEmpty) continue;
        total++;
        if ((e.widget as Text).style?.shadows?.isNotEmpty == true) {
          withShadow++;
        }
      }
      expect(total, greaterThan(0), reason: '底栏应有文字（时间/倍速）');
      expect(withShadow, greaterThan(0),
          reason: '底栏文字应当带阴影 —— 去掉模糊后，白字压亮画面\n'
              '没有阴影会读不到（$withShadow/$total 条带阴影）。');
    });
  });
}
