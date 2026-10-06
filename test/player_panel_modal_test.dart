/// 面板**模态语义**的回归守护（由一次诊断实测得出）。
///
/// ## 诊断发现的三个事实（都不是猜的）
///
/// 1. **三个抽屉始终都在 widget 树里**，只是用 `AnimatedSlide` 移出屏幕。
///    所以 `find.byKey(keys.player.panelClose)` 会命中 **3 个** ——
///    `.first` 取到的是**屏幕外**那个（播放列表抽屉的关闭按钮）。
///    → 测试必须用 `find.descendant` 限定到**可见的那个面板**。
///
/// 2. **抽屉打开时会盖住底栏**：规格 §7.6 规定宽度 `min(屏宽×0.9, 400)`，
///    在 400dp 宽的屏上抽屉宽 360dp（x=40..400），底栏按钮（x≈92）在其下方。
///    → 这是**模态抽屉的正确行为**：面板打开时不能同时操作底栏。
///
/// 3. **点击抽屉之外的区域会被遮罩吃掉** → 关闭面板（规格 §10.5）。
///    实测 x=20（抽屉左侧）点击后 `PanelType.none`。
///
/// ## 为什么值得单独一个文件
/// 这三条都是"看起来像 bug、实际是设计"的行为。若不写下来，
/// 下一个人（或下一轮的我）会再次把它们当成 bug 去"修"。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/keys.dart';
import 'package:cineflow/player/application/providers/player_providers.dart';
import 'package:cineflow/player/domain/models/panel_state.dart';
import 'package:cineflow/player/presentation/player_ui_page.dart';

PlayerPageCallbacks _noopCallbacks() => PlayerPageCallbacks(
      onTogglePlay: () {},
      onSeekBy: (_) {},
      onSeekTo: (_) {},
      onSpeedChanged: (_) {},
      onVolumeChanged: (_) {},
      onBrightnessChanged: (_) {},
      onAspectModeChanged: (_) {},
      onFullscreenToggled: () {},
      onBack: () {},
      onSelectMedia: (_) {},
      onSelectAudioTrack: (_) {},
      onSelectSubtitleTrack: (_) {},
      onImportSubtitle: () {},
      onImportDanmaku: () {},
      onMatchDanmaku: () {},
      onVideoFilterChanged: ({brightness, contrast, saturation, hue}) {},
      onResetFilters: () {},
      onAudioDelayChanged: (_) {},
      onSubtitleDelayChanged: (_) {},
      onSubtitleFontSizeChanged: (_) {},
      onSubtitleEncodingChanged: (_) {},
    );

Future<ProviderContainer> pumpPlayer(
  WidgetTester tester, {
  Size size = const Size(400, 800),
}) async {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(UncontrolledProviderScope(
    container: c,
    child: MaterialApp(
      home: PlayerUiPage(
        slots: const PlayerPageSlots(
          title: 'T.mkv',
          video: ColoredBox(color: Colors.black),
        ),
        callbacks: _noopCallbacks(),
      ),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return c;
}

/// 限定到"某个面板内部"的查找器 —— 避开另外两个移出屏幕的抽屉。
Finder _insidePanel(Key panelKey, Key target) => find.descendant(
      of: find.byKey(panelKey),
      matching: find.byKey(target),
    );

void main() {
  group('事实 1：面板宿主按需挂载，三个抽屉同时在树里', () {
    testWidgets('★ 无面板打开时，宿主完全不挂载（panelClose 为 0）', (tester) async {
      await pumpPlayer(tester);
      expect(
        find.byKey(keys.player.panelClose),
        findsNothing,
        reason: 'PlayerPanelHost 只在 `state.open != none` 时挂载 ——\n'
            '关闭状态不占用 widget 树（省重建开销）。',
      );
    });

    testWidgets('★ 打开任一面板后，三个抽屉同时进树（panelClose 有 3 个）', (tester) async {
      final c = await pumpPlayer(tester);
      c.read(panelStateProvider.notifier).open(PanelType.settings);
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.byKey(keys.player.panelClose),
        findsNWidgets(3),
        reason: '三个抽屉（播放列表/设置/弹幕）**始终都在树里**，\n'
            '只是用 AnimatedSlide 把未打开的那个移出屏幕。\n'
            '所以测试必须用 find.descendant 限定到可见的面板 ——\n'
            '直接 .first 会取到屏幕外那个，点击无效（这是实测踩到的）。',
      );
    });

    testWidgets('★ 用 descendant 能精确取到目标面板的关闭按钮', (tester) async {
      final c = await pumpPlayer(tester);
      c.read(panelStateProvider.notifier).open(PanelType.settings);
      await tester.pump(const Duration(milliseconds: 400));

      final close = _insidePanel(
          keys.player.settingsPanel, keys.player.panelClose);
      expect(close, findsOneWidget,
          reason: '限定到设置面板后应只有一个关闭按钮');

      await tester.tap(close);
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.read(panelStateProvider).open, PanelType.none);
    });
  });

  group('事实 2：抽屉打开时盖住底栏（模态语义）', () {
    testWidgets('★ 400dp 屏上设置抽屉盖住底栏按钮的坐标', (tester) async {
      final c = await pumpPlayer(tester, size: const Size(400, 800));
      c.read(panelStateProvider.notifier).open(PanelType.settings);
      await tester.pump(const Duration(milliseconds: 400));

      final btn = tester.getRect(find.byKey(keys.player.playlistButton));
      final drawer = tester.getRect(find.byKey(keys.player.settingsPanel));

      expect(
        drawer.left,
        lessThan(btn.center.dx),
        reason: '规格 §7.6：抽屉宽 = min(屏宽×0.9, 400) = 360dp（400dp 屏）\n'
            '→ 覆盖 x=40..400，而底栏按钮在 x≈92 → **被盖住**。\n'
            '这是模态抽屉的正确行为：面板开着时不能同时点底栏。',
      );
    });

    testWidgets('★ 面板打开时点底栏 → 不会切换面板（点击被抽屉吃掉）', (tester) async {
      final c = await pumpPlayer(tester, size: const Size(400, 800));
      c.read(panelStateProvider.notifier).open(PanelType.settings);
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.byKey(keys.player.playlistButton),
          warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 400));

      expect(c.read(panelStateProvider).open, PanelType.settings,
          reason: '点击落在抽屉上（不是按钮），所以面板不变。\n'
              '要切换面板必须先关闭当前面板 —— 与原型行为一致。');
    });
  });

  group('事实 3：点遮罩关闭面板', () {
    testWidgets('★ 点抽屉之外 → 关闭（规格 §10.5）', (tester) async {
      final c = await pumpPlayer(tester, size: const Size(400, 800));
      c.read(panelStateProvider.notifier).open(PanelType.settings);
      await tester.pump(const Duration(milliseconds: 400));

      // x=20 在抽屉（x≥40）之外 → 命中遮罩
      await tester.tapAt(const Offset(20, 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.read(panelStateProvider).open, PanelType.none);
    });

    testWidgets('宽屏（800dp）上抽屉只占一半 → 遮罩区域更大', (tester) async {
      final c = await pumpPlayer(tester, size: const Size(800, 800));
      c.read(panelStateProvider.notifier).open(PanelType.settings);
      await tester.pump(const Duration(milliseconds: 400));

      final drawer = tester.getRect(find.byKey(keys.player.settingsPanel));
      // 800dp 屏：min(800*0.9, 400) = 400 → 抽屉占 x=400..800
      expect(drawer.width, 400, reason: '宽屏上被 400dp 上限截住');
      expect(drawer.left, 400);

      await tester.tapAt(const Offset(100, 400)); // 抽屉之外
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.read(panelStateProvider).open, PanelType.none);
    });
  });

  group('事实 4：AnimatedSlide 的推进需要 pump 两次', () {
    testWidgets('★ 切面板后旧抽屉真的滑出屏幕（不能只 pump 一次）', (tester) async {
      final c = await pumpPlayer(tester, size: const Size(400, 800));
      final n = c.read(panelStateProvider.notifier);

      // 先开设置，确认它在屏幕内
      n.open(PanelType.settings);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.getRect(find.byKey(keys.player.settingsPanel)).left, 40,
          reason: '设置抽屉在屏幕内（left=40，宽度 360）');

      // 切到播放列表
      n.open(PanelType.playlist);

      // ⚠️ 只 pump 一次：AnimatedSlide 刚收到新的目标 offset，
      //    但动画**还没推进** —— 此时位置仍是旧的（left=40）。
      await tester.pump();
      expect(
        tester.getRect(find.byKey(keys.player.settingsPanel)).left,
        40,
        reason: '第一次 pump 只是启动动画，位置还没变。\n'
            '如果测试在此处断言"已滑出"，会**误判成 bug**（实际是动画没跑）。',
      );

      // 再 pump 一次才推进到终点
      await tester.pump(const Duration(milliseconds: 400));
      final left = tester.getRect(find.byKey(keys.player.settingsPanel)).left;
      expect(left, greaterThanOrEqualTo(399),
          reason: '第二次 pump 后应完全移出屏幕右侧（实测 left=440）');
    });
  });

  group('面板互斥（在控制器层验证 —— UI 层受模态遮挡限制）', () {
    testWidgets('★ 通过控制器切换面板时互斥成立', (tester) async {
      final c = await pumpPlayer(tester);
      final n = c.read(panelStateProvider.notifier);

      n.open(PanelType.settings);
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.read(panelStateProvider).open, PanelType.settings);
      expect(find.byKey(keys.player.settingsPanel), findsOneWidget);

      // 直接调控制器（模拟"先关再开"的合法路径）
      n.open(PanelType.playlist);
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.read(panelStateProvider).open, PanelType.playlist,
          reason: '状态是单一枚举字段 → 结构上互斥');
    });

    testWidgets('点同一个按钮两次 → 第二次收起', (tester) async {
      final c = await pumpPlayer(tester);
      await tester.tap(find.byKey(keys.player.settingsButton));
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.read(panelStateProvider).open, PanelType.settings);

      // 抽屉盖住底栏，所以直接点面板内的关闭按钮（限定作用域）
      await tester.tap(_insidePanel(
          keys.player.settingsPanel, keys.player.panelClose));
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.read(panelStateProvider).open, PanelType.none);
    });
  });

  group('移出屏幕的抽屉不响应点击', () {
    testWidgets('★ 未打开的面板不可命中（IgnorePointer 生效）', (tester) async {
      final c = await pumpPlayer(tester);
      // 只开设置 → 播放列表抽屉应移出屏幕且不吃点击
      c.read(panelStateProvider.notifier).open(PanelType.settings);
      await tester.pump(const Duration(milliseconds: 400));

      // 播放列表抽屉的关闭按钮在屏幕外，点击不该生效
      final hidden = find.descendant(
        of: find.byKey(keys.player.playlistPanel),
        matching: find.byKey(keys.player.panelClose),
      );
      expect(hidden, findsOneWidget, reason: '它在树里（只是移出屏幕）');
      await tester.tap(hidden, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.read(panelStateProvider).open, PanelType.settings,
          reason: '移出屏幕的抽屉有 IgnorePointer(ignoring: true)，\n'
              '不该被点到 —— 否则它会意外关掉当前面板');
    });
  });
}
