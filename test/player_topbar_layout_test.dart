// 顶栏左上角定位 —— 位置断言（用真实布局测量，不靠像素猜测）。
//
// ## 为什么需要它
// 用户要求"返回按钮 + 集数标题固定在屏幕左上角：
//   SafeArea + Align(topLeft)，顶部 12dp、左侧 24dp，
//   且顶栏高度仅为内容高度（不拉伸）"。
//
// 真机像素反推只能给"大致对"，无法区分"24dp 还是 57dp"——
// 因为叠加了 IconButton 的 tapTargetSize / SafeArea / 状态栏等多层。
// **直接测渲染出来的矩形**才是可判定的。
//
// ## 守的缺陷
// 2026-10-09 实测发现：`BarScrim(120dp)` 被当成 `Column` 的子节点，
// 把顶栏**向下推了 120dp** ⇒ 横屏（1080px 高）下返回键 y 占屏 **31.6%**，
// 观感上"飘在屏幕中间"。改成 `Stack`（渐变作背景）后应为 ~3%。
//
// ## 为什么直接测 `PlayerTopBar` 而不是整个 `PlayerUiPage`
// 整页要构造内核替身 + 24 个回调，噪声大且脆弱。
// 而本缺陷的**位置**由"外层容器怎么摆"决定 —— 用同样的
// `Positioned + Stack + Padding + SafeArea` 包法就能精确覆盖，
// 且**不依赖**内核/网络/控制器。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/keys.dart';
import 'package:cineflow/player/presentation/widgets/player_bars.dart';

/// 读源码并**剥掉注释行**（否则断言可能被注释满足 —— AGENTS §8.4 第 1 条）。
String _readCode(String path) {
  final raw = File(path).readAsStringSync();
  return raw
      .split('\n')
      .where((l) {
        final t = l.trimLeft();
        return !t.startsWith('//') && !t.startsWith('///') && !t.startsWith('*');
      })
      .join('\n');
}

/// 复刻 `player_ui_page.dart` 里顶栏的外层包法（保持同构）。
///
/// ⚠️ 若有人改了那边的包法而没改这里，**本测试就失去意义** ——
/// 故在下方加了一条"源码结构"断言，确保两边同构（见最后一组）。
Widget _wrapTopBar({required String title, String? subtitle}) {
  return MaterialApp(
    home: Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 背景渐变：`Stack` 子节点**不参与彼此布局**（这正是修复点）
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(height: 120, color: Colors.black54),
          ),
          // 顶栏内容
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Stack(
              alignment: Alignment.topLeft,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 12, left: 24),
                  child: SafeArea(
                    bottom: false,
                    left: false,
                    right: false,
                    child: Row(
                      key: keys.player.topBar,
                      children: [
                        Expanded(
                          child: PlayerTopBar(
                            title: title,
                            subtitle: subtitle,
                            onBack: () {},
                            onBackKey: keys.player.backButton,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

void main() {
  group('★ 顶栏贴左上角（横屏回归）', () {
    testWidgets('返回按钮必须在左上角，不能被背景层推下来', (tester) async {
      tester.view.physicalSize = const Size(880, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _wrapTopBar(title: '第 1 集 · 星斗初涉', subtitle: '斗罗大陆Ⅱ绝世唐门'),
      );
      await tester.pump();

      final back = tester.getRect(find.byKey(keys.player.backButton));

      // ## 核心断言：顶部不能有 100dp 级的推力
      // 曾被 `BarScrim(120)` 推下 120dp ⇒ 400dp 高的屏上 y 从 120 起步。
      // 修好后应只有 padding(12) + SafeArea(0) 的量级。
      expect(back.top, lessThan(40),
          reason: '★ 返回按钮 top=${back.top} —— 被背景层挤下来了。\n'
              '    根因：BarScrim 若是 Column 子节点会占 120dp 布局高度\n'
              '    修法：放进 Stack 当背景层（子节点互不挤压）');

      expect(back.left, lessThan(80),
          reason: '★ 返回按钮 left=${back.left} —— 应在左上角，不是居中');
    });

    testWidgets('顶栏高度仅为内容高度（不拉伸占满）', (tester) async {
      tester.view.physicalSize = const Size(880, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_wrapTopBar(title: '短标题'));
      await tester.pump();

      final bar = tester.getRect(find.byKey(keys.player.topBar));
      expect(bar.height, lessThan(120),
          reason: '★ 顶栏高度 ${bar.height} —— 不该被拉伸占满屏幕');
    });

    testWidgets('竖屏下同样贴左上角', (tester) async {
      tester.view.physicalSize = const Size(400, 880);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_wrapTopBar(title: '第 1 集'));
      await tester.pump();

      final back = tester.getRect(find.byKey(keys.player.backButton));
      expect(back.left, lessThan(80), reason: '★ 竖屏下也必须在左侧');
      expect(back.top, lessThan(80),
          reason: '★ 竖屏下要考虑状态栏安全区，但不应夸张到几百');
    });

    testWidgets('★ 返回按钮命中区 ≥48dp（用户要求）', (tester) async {
      tester.view.physicalSize = const Size(880, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_wrapTopBar(title: 'x'));
      await tester.pump();

      final back = tester.getRect(find.byKey(keys.player.backButton));
      expect(back.width, greaterThanOrEqualTo(48),
          reason: '★ 命中宽 ${back.width} < 48dp（U5/U8 已确立的纪律）');
      expect(back.height, greaterThanOrEqualTo(48),
          reason: '★ 命中高 ${back.height} < 48dp');
    });
  });

  group('★ 标题单行合并', () {
    testWidgets('title + subtitle 合并为一行', (tester) async {
      await tester.pumpWidget(
        _wrapTopBar(title: '第 1 集 · 星斗初涉', subtitle: '斗罗大陆Ⅱ绝世唐门'),
      );
      await tester.pump();

      expect(find.text('第 1 集 · 星斗初涉 · 斗罗大陆Ⅱ绝世唐门'), findsOneWidget,
          reason: '★ 顶栏应合并成一行（用户要求）');
    });

    testWidgets('无 subtitle 时不留孤立间隔符', (tester) async {
      await tester.pumpWidget(_wrapTopBar(title: 'Interstellar.mkv'));
      await tester.pump();

      expect(find.text('Interstellar.mkv'), findsOneWidget);
      expect(find.text('Interstellar.mkv · '), findsNothing,
          reason: '★ subtitle 为空时不能留下 ` · ` 尾巴');
    });

    testWidgets('subtitle 与 title 相同时只显示一次', (tester) async {
      // 防御重复（第 46 轮修过"顶栏集数重复显示"）
      await tester.pumpWidget(_wrapTopBar(title: '同名', subtitle: '同名'));
      await tester.pump();

      expect(find.text('同名'), findsOneWidget,
          reason: '★ 两者相同时不应出现 `同名 · 同名`');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // ★★ 防"测试与真实源码脱钩"（反向注入实测暴露的真实弱点）
  // ══════════════════════════════════════════════════════════════════
  //
  // ## 为什么必须单独守这一组
  // 上面的布局测试用的是**复刻的包装**（`_wrapTopBar`）——
  // 它断言"这种包法是正确的"，但**不保证真实页面用的是这种包法**。
  //
  // **反向注入实测**：把 `player_ui_page.dart` 里的
  // `Stack(背景) + Padding(顶栏)` 改回 `Column(BarScrim, Padding)`
  // （即恢复修复前的缺陷结构）后 ——
  // 布局测试**仍然全绿**（因为它测的是复刻包装，没碰真实源码）。
  // ⇒ **那是假防线**。故用源码结构断言把两边钉死。
  group('★★ 真实源码必须与测试同构（防脱钩）', () {
    late String ui;

    setUpAll(() {
      ui = _readCode('lib/player/presentation/player_ui_page.dart');
    });

    test('★ 顶栏背景必须放在 Stack 里（不能是 Column 子节点）', () {
      // 缺陷形态：Column(children:[BarScrim, Padding(顶栏)])
      //   ⇒ BarScrim 占 120dp 布局高度 ⇒ 顶栏被推下 ⇒ 横屏飘到 1/3 处
      // 正确形态：Stack(children:[Positioned(BarScrim), Padding(顶栏)])
      //   ⇒ Stack 子节点互不挤压
      expect(ui.contains('child: Stack(\n            alignment: Alignment.topLeft,'),
          isTrue,
          reason: '★ 顶栏容器必须用 Stack（背景层不占布局）。\n'
              '    若改回 Column，BarScrim 会占 120dp 把顶栏推下去。');

      // 背景层必须是 Positioned（在 Stack 里才有意义）
      expect(
          ui.contains('child: BarScrim(height: PlayerUi.topBarFade, '
              'fromTop: true),'),
          isTrue,
          reason: '★ BarScrim 必须被 Positioned 包住（作为背景层）');

      // 反向：不能出现"BarScrim 直接跟在 Column 的 children 后面"
      expect(
          ui.contains('child: Column(\n            children: [\n'
              '              const BarScrim(height: PlayerUi.topBarFade'),
          isFalse,
          reason: '★★ 这是**修复前的缺陷结构** —— BarScrim 成了 Column 子节点，\n'
              '    会占 120dp 布局高度，把顶栏推到屏幕 1/3 处\n'
              '    （真机实测 y 占屏 31.6%，用户报"返回键飘在半空"）。');
    });

    test('★ 顶栏必须贴左上角（Padding 显式给 top/left）', () {
      expect(ui.contains('top: 12 + MediaQuery.paddingOf(context).top'), isTrue,
          reason: '★ 顶部要含安全区（否则竖屏被状态栏压住）');
      expect(ui.contains('left: 24'), isTrue,
          reason: '★ 左侧 24dp（用户要求"贴左上角"）');
    });

    test('★ 必须用 SafeArea + topLeft（用户明确要求）', () {
      expect(ui.contains('SafeArea('), isTrue,
          reason: '★ 用户要求用 SafeArea 包裹（避开刘海/挖孔）');
      expect(ui.contains('alignment: Alignment.topLeft'), isTrue,
          reason: '★ 用户明确要求 Alignment.topLeft（不要 Center / centerLeft）');
    });

    test('★ 返回按钮必须有≥48dp 命中区 + 圆底（无 BackdropFilter）', () {
      final bars = _readCode('lib/player/presentation/widgets/player_bars.dart');
      expect(bars.contains('BoxConstraints(minWidth: 48, minHeight: 48)'), isTrue,
          reason: '★ 用户要求返回按钮命中区最小 48dp');

      // ⚠️ **不能有 BackdropFilter**（第 31/33 轮三轮迭代的结论：
      //    模糊会处理其区域的视频像素 ⇒ 用户看到"这块是糊的" = 被遮挡）
      final backStart = bars.indexOf('key: onBackKey');
      expect(backStart, greaterThanOrEqualTo(0), reason: '找不到返回按钮');
      final backCtx = bars.substring(backStart,
          (backStart + 900).clamp(0, bars.length));
      expect(backCtx.contains('BackdropFilter'), isFalse,
          reason: '★ 返回按钮**不得**用 BackdropFilter ——\n'
              '    用户曾三轮反馈"模糊本身就是遮挡视频的根源"，\n'
              '    连"填充全透明但保留 blur"都被否掉。\n'
              '    正确做法：Colors.black26 半透明填充（不处理背后像素）。');
      expect(backCtx.contains('Colors.black26'), isTrue,
          reason: '★ 应有半透明圆底（用户要求"半透明圆形背景"）');
    });
  });
}
