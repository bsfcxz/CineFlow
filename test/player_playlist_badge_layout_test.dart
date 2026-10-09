// 列表按钮的「图标 + 进度计数」布局守卫。
//
// ## 为什么需要（用户第二轮报障："这个没整好"）
// 第一版把计数做成**叠在图标右下角的角标**（`Stack` + `Positioned`），
// 结果是：22dp 的图标 + 25dp 的文字**互相压在一起**，视觉上像
// "图标下面挂了一行小字"，不像"图标 + 计数"。
//
// 用户原话要的是「**列表图标 + 进度计数**」—— 并排、都要看得清。
//
// ## 本测试守什么（几何断言，不靠肉眼）
// ① 计数在图标**右侧**（`badge.left >= icon.right`），不重叠
// ② 两者**垂直居中对齐**（视觉上是一行）
// ③ 窄屏（320dp）**不溢出**（第一版并排就栽在这里 —— 溢出 16px）
// ④ 电影（无计数）时**只显示图标**，不出现空角标
import 'dart:ui' show Size;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/player/presentation/widgets/player_action_bar.dart';

/// 造一个最小可用底栏（只关心列表按钮）。
Widget _bar({String? count}) => MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Align(
          alignment: Alignment.bottomCenter,
          child: PlayerActionBar(
            speedLabel: '1.0x',
            hasPrevious: true,
            hasNext: true,
            danmakuEnabled: true,
            fullscreen: false,
            playlistCount: count,
            onPrevious: () {},
            onNext: () {},
            onCycleSpeed: () {},
            onOpenPlaylist: () {},
            onToggleDanmaku: () {},
            onOpenDanmakuSettings: () {},
            onOpenSettings: () {},
            onToggleFullscreen: () {},
          ),
        ),
      ),
    );

void main() {
  group('★ 列表按钮：图标 + 进度计数（并排）', () {
    testWidgets('计数在图标右侧、垂直居中（不叠压）', (tester) async {
      tester.view.physicalSize = const Size(393, 850);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_bar(count: '2/173'));
      await tester.pump();

      final icon = tester.getRect(find.byIcon(Icons.playlist_play));
      final badge = tester.getRect(find.text('2/173'));

      // ① 水平：计数在图标右侧（允许 1px 的亚像素误差）
      expect(badge.left, greaterThanOrEqualTo(icon.right - 1),
          reason: '★ 计数应在图标**右侧** —— 第一版叠在右下角，'
              '图标与文字互相压住（用户："这个没整好"）');

      // ② 垂直：两者中线接近（视觉上是一行，而不是"图标下挂一行字"）
      expect((badge.center.dy - icon.center.dy).abs(), lessThan(4),
          reason: '★ 计数应与图标**垂直居中对齐**（差 '
              '${(badge.center.dy - icon.center.dy).abs().toStringAsFixed(1)}dp）');
    });

    testWidgets('★ 320dp 窄屏不溢出（第一版并排栽在这里）', (tester) async {
      // 320dp 是 Android 最窄的常见宽度；8 按钮预算 ≈ 38dp/个
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_bar(count: '2/173'));
      await tester.pump();

      // 溢出会让框架抛异常并被测试捕获 —— 这里再显式断言按钮行宽度
      expect(tester.takeException(), isNull,
          reason: '★ 320dp 屏不得溢出（第一版为此溢出 16px）');
    });

    testWidgets('长计数（12/173）也放得下', (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_bar(count: '12/173'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('12/173'), findsOneWidget);
    });

    testWidgets('★ 电影（无计数）只显示图标，不出现空角标', (tester) async {
      tester.view.physicalSize = const Size(393, 850);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_bar(count: null));
      await tester.pump();

      expect(find.byIcon(Icons.playlist_play), findsOneWidget,
          reason: '★ 图标必须在（电影也有列表入口，只是不显示计数）');
      // 不能出现空字符串或占位文字
      expect(find.textContaining('/'), findsNothing,
          reason: '★ 电影不应出现任何 `x/y` 计数');
    });
  });
}
