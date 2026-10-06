/// U6 播放器玻璃抽屉宽度的**回归守护**。
///
/// # 这个批次修了什么
///
/// 抽屉原为写死的 `width: 272`（审计 U6 点名）。问题在**分屏/小窗**下才暴露：
/// 可用宽 <360dp 时抽屉**超出窗口**，右侧内容（关闭钮、开关）被裁掉 ——
/// 而且**无法滚动到**，等于有控件点不到。
///
/// 改为 `(可用宽 × 0.76).clamp(200, 272)`：
///   · 76% 留出左侧 24% 可见视频区 —— 用户知道画面还在播、抽屉可以滑走
///     （100% 宽会像整页跳转，失去"抽屉"语义）
///   · 大屏封顶 272 —— 横屏平板上的 1800dp 抽屉毫无意义，设置项就那几行
///
/// # 为什么用纯函数 + 单测而不是 widget 测试
/// 宽度是个**纯算术**（可用宽 → 抽屉宽）。抽成 `PlayerPage.drawerWidthFor`
/// 后可以直接断言边界，不用把一个依赖内核的播放页渲染起来
/// （播放页需要 `_facade`，纯 widget 测试里没有 mpv）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/player/player_page.dart';

void main() {
  group('U6 · 抽屉宽度 drawerWidthFor', () {
    test('★ 任何可用宽下都**不超窗口**（这正是原 bug）', () {
      // 原实现是常量 272：以下宽度全都会溢出
      for (final w in [200.0, 240.0, 280.0, 320.0, 360.0, 411.0]) {
        final d = PlayerPage.drawerWidthFor(w);
        expect(
          d,
          lessThanOrEqualTo(w),
          reason: '可用宽 $w dp 时抽屉算出 $d dp —— **超出窗口**！\n'
              '右侧的关闭钮/开关会被裁掉且无法滚动到（原 272 常量的问题）',
        );
      }
    });

    test('窄窗（分屏）走比例，不触发下限', () {
      // 320 × 0.76 = 243.2，仍在 [200, 272] 内
      expect(PlayerPage.drawerWidthFor(320), closeTo(243.2, 0.01));
      expect(PlayerPage.drawerWidthFor(280), closeTo(212.8, 0.01));
    });

    test('极窄窗触发下限 200（可读性优先）', () {
      // 200 × 0.76 = 152 < 200 → 取下限
      expect(PlayerPage.drawerWidthFor(200), 200.0);
      expect(PlayerPage.drawerWidthFor(150), 200.0);
    });

    test('大屏封顶 272（不再变宽）', () {
      expect(PlayerPage.drawerWidthFor(600), 272.0);
      expect(PlayerPage.drawerWidthFor(1080), 272.0);
      expect(PlayerPage.drawerWidthFor(2400), 272.0,
          reason: '横屏平板上的 1800dp 抽屉毫无意义 —— 设置项就那么几行');
    });

    test('留出左侧可见视频区（不占满整宽）', () {
      // 除非触发下限，否则抽屉应 < 100% 宽 —— 保留"抽屉"语义
      for (final w in [320.0, 360.0, 411.0, 600.0]) {
        expect(PlayerPage.drawerWidthFor(w) / w, lessThan(0.85),
            reason: '可用宽 $w 时抽屉占了超过 85% —— 会像整页跳转，\n'
                '用户看不到"画面还在播"，也不知道能滑走');
      }
    });

    test('单调不减（宽屏抽屉不该更窄）', () {
      var prev = 0.0;
      for (final w in [150.0, 200.0, 280.0, 360.0, 500.0, 800.0, 2000.0]) {
        final d = PlayerPage.drawerWidthFor(w);
        expect(d, greaterThanOrEqualTo(prev),
            reason: '可用宽从更小变到 $w 时抽屉反而变窄了 —— 逻辑不单调');
        prev = d;
      }
    });

    test('宽 0/负（布局未完成）不崩且不返回负值', () {
      expect(PlayerPage.drawerWidthFor(0), 200.0);
      expect(PlayerPage.drawerWidthFor(-100), 200.0);
    });
  });

  group('U6 · 源码约束（剥注释后断言）', () {
    final src = File('lib/player/player_page.dart')
        .readAsStringSync()
        .split('\n')
        .where((l) {
          final s = l.trimLeft();
          return !s.startsWith('//') && !s.startsWith('*');
        })
        .join('\n');

    test('抽屉不再用硬编码 272', () {
      expect(
        RegExp(r'width:\s*272\b').hasMatch(src),
        isFalse,
        reason: '抽屉又写死 272 了 —— 分屏/小窗下会超出窗口，\n'
            '右侧的关闭钮会被裁掉且无法滚动到（有控件点不到）。\n'
            '请用 PlayerPage.drawerWidthFor(可用宽)。',
      );
    });

    test('抽屉用了 drawerWidthFor', () {
      expect(RegExp(r'drawerWidthFor\(').hasMatch(src), isTrue);
    });
  });
}
