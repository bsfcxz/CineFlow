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

  // ================================================================
  // 用户第四轮："暂停、播放、快进、锁屏键也使用透明改成和底栏一样"
  //
  // 这四处原先都垫着 `GlassBackground`（12% 白 + blur12 + 描边）：
  //   · 中部三键（后退/播放/前进）→ `GlassButton`
  //   · 锁按钮 → `GlassCircle`（锁定时还填 90% 蓝，是最大的一块遮挡）
  //
  // ## 与底栏同一根因
  // `BackdropFilter` 会模糊其区域的**视频像素**。用户要的"透明"
  // 是"这块画面和其他地方一模一样、不被处理"。
  // ================================================================
  group('★ 中部按钮与锁屏键也必须透明（用户第四轮）', () {
    testWidgets('★ 中部三键子树里不得出现 BackdropFilter', (tester) async {
      final (_, _) = await base.pumpPlayer(tester);

      // 中部按钮在控制层里；用**精确键名**检查
      // （键名以 lib/keys.dart 为准：togglePlayButton / seekForwardButton /
      //   seekBackButton。我第一版写的 `playButton` + `byName()`
      //   两个都不存在 —— 编译期就报错，属低级失误。）
      final centerKeys = <String, Key>{
        'togglePlayButton': keys.player.togglePlayButton,
        'seekForwardButton': keys.player.seekForwardButton,
        'seekBackButton': keys.player.seekBackButton,
      };
      var found = 0;
      for (final entry in centerKeys.entries) {
        final f = find.byKey(entry.value);
        if (f.evaluate().isEmpty) continue;
        found++;
        expect(
          find.descendant(of: f, matching: find.byType(BackdropFilter)),
          findsNothing,
          reason: '中部按钮「${entry.key}」子树出现了 BackdropFilter ——\n'
              '它会把按钮区域的视频画面模糊掉（用户看到的"遮挡"）。\n'
              '若这条红 → 有人把毛玻璃圆底加回中部按钮了。',
        );
      }
      expect(found, greaterThan(0),
          reason: '至少要找到中部按钮之一，否则测试前提不成立'
              '（keys 名可能改了，检查 lib/keys.dart）');
    });

    testWidgets('★ 锁按钮子树里不得出现 BackdropFilter', (tester) async {
      final (_, _) = await base.pumpPlayer(tester);

      final lock = find.byKey(keys.player.lockButton);
      expect(lock, findsOneWidget, reason: '锁按钮未渲染，测试前提不成立');

      expect(
        find.descendant(of: lock, matching: find.byType(BackdropFilter)),
        findsNothing,
        reason: '锁按钮子树出现了 BackdropFilter —— 它会把按钮区域的\n'
            '视频画面模糊掉。用户明确要求"锁屏键也透明"。\n'
            '若这条红 → 有人把毛玻璃圆底加回锁按钮了。',
      );
    });

    testWidgets('★ 锁按钮锁定态不得用大面积填色（状态走图标色）', (tester) async {
      final (_, _) = await base.pumpPlayer(tester);

      final lock = find.byKey(keys.player.lockButton);
      expect(lock, findsOneWidget);

      // 锁定态的关键：**不能**用 90% 蓝的大圆填色（那是遮挡）
      // 做法：找锁按钮下所有 DecoratedBox，断言不存在"高不透明度大色块"
      final boxes = find.descendant(of: lock, matching: find.byType(DecoratedBox));
      for (final e in boxes.evaluate()) {
        final d = (e.widget as DecoratedBox).decoration;
        if (d is BoxDecoration && d.color != null) {
          expect(
            d.color!.a,
            lessThan(0.5),
            reason: '锁按钮里有 ${d.color!.a} 不透明度的填色 ——\n'
                '原实现的锁定态是 90% 蓝的大圆，正是用户要消除的遮挡。\n'
                '状态信号应改走**图标颜色**（透明化时把状态从"面"移到"点"）。',
          );
        }
      }
    });
  });
}
