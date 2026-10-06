/// 真机**肉眼走查**用的临时用例：把播放页停在几个关键状态上，
/// 由外部脚本用 `adb exec-out screencap` 抓图。
///
/// ## 为什么需要它（Patrol 断言证明不了的东西）
///
/// `player_page_test.dart` 守的是**接线**（控件在、点了走对分支），
/// 但它**看不到画面**：
///   · 控制层布局有没有重叠/溢出
///   · 弹幕层是否压在按钮上（层级错）
///   · 进度条刻度、玻璃质感、图标大小是否协调
///   · 中文字号在横屏 1080 高下是否可读
///
/// 这些都是"人眼一看就知道、断言写不出来"的东西。
///
/// ## 做法
/// 每个状态停留 `_hold` 秒（默认 12s），外部脚本在这段时间里抓图。
/// **不写断言** —— 本文件只负责"把画面摆出来"，判定交给人。
///
/// ⚠️ 本文件是**临时走查工具**，不是回归测试；
///    跑完后若不想留在仓库，删掉即可（它不参与 `check-dev`）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `find`（CommonFinders）来自 flutter_test；Patrol 的 `$()` 建在它之上。
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'package:cineflow/data/models.dart';
import 'package:cineflow/keys.dart';
import 'package:cineflow/player/player_page.dart';
import 'package:cineflow/state/providers.dart';

import 'fake_media_provider.dart';

/// 每个状态停留时长：给外部 `screencap` 留出抓图窗口。
const _hold = Duration(seconds: 14);

MediaItem _movie() => const MediaItem(
      id: 'walk-item-1',
      name: '走查用影片',
      type: 'Movie',
      productionYear: 2024,
      runtimeTicks: 72000000000,
    );

List<MediaItem> _episodes() => List.generate(
      3,
      (i) => MediaItem(
        id: 'walk-ep-${i + 1}',
        name: '第 ${i + 1} 话·走查',
        type: 'Episode',
        seriesId: 'walk-series',
        seasonId: 'walk-season',
        parentIndexNumber: 1,
        indexNumber: i + 1,
      ),
    );

void main() {
  patrolTest(
    '走查：把播放页停在"控制层可见"状态供抓图',
    ($) async {
      await $.pumpWidgetAndSettle(
        ProviderScope(
          overrides: [embyApiProvider.overrideWithValue(FakeMediaProvider())],
          child: MaterialApp(
            home: PlayerPage(item: _movie(), episodes: _episodes()),
          ),
        ),
      );

      await $(keys.player.page).waitUntilVisible();

      // 确保控制层可见（初始 6 秒后会自动隐藏）
      final size = $.tester.view.physicalSize / $.tester.view.devicePixelRatio;
      Future<void> tapIdle() async {
        await $.tester.tapAt(Offset(size.width * 0.25, size.height * 0.3));
        await $.tester.pump(const Duration(milliseconds: 400));
        await $.pumpAndSettle();
      }

      final ancestors = find.ancestor(
        of: find.byKey(keys.player.controls),
        matching: find.byType(AnimatedOpacity),
      );
      double opacity() {
        final l = $.tester.widgetList<AnimatedOpacity>(ancestors).toList();
        return l.isEmpty ? -1 : l.first.opacity;
      }

      if (opacity() != 1.0) await tapIdle();

      // ---- 状态 1：控制层可见（顶栏 + 中央按钮 + 底栏 + 进度条）----
      await _holdFor($, _hold);

      // ⚠️ hold 期间 `_armHide(6s)` 的定时器已经吃掉了这段时间 → 控制层已自动隐藏。
      //    **必须重新唤回**，否则下一句 `$(...).tap()` 会因 not hit-testable 失败
      //    （实测踩过：`WaitUntilVisibleTimeoutException`，看起来像"按钮没了"）。
      await tapIdle();

      // ---- 状态 2：倍速弹层 ----
      await $(keys.player.rateButton).tap();
      await $.tester.pump(const Duration(milliseconds: 500));
      await _holdFor($, _hold);
      await $.tester.tapAt(const Offset(20, 20));
      await $.pumpAndSettle();
      await tapIdle();

      // ---- 状态 3：选集弹层（多集列表）----
      await $(keys.player.episodeButton).tap();
      await $.tester.pump(const Duration(milliseconds: 500));
      await _holdFor($, _hold);
      await $.tester.tapAt(const Offset(20, 20));
      await $.pumpAndSettle();
      await tapIdle();

      // ---- 状态 4：锁定态（左上角锁图标 + 控制层隐藏）----
      await $(keys.player.lockButton).tap();
      await $.tester.pump(const Duration(milliseconds: 700));
      await _holdFor($, _hold);
    },
  );
}

/// 只推进时间、不做断言 —— 目的是让画面**停在屏幕上**供外部抓图。
///
/// ## 为什么不用 `pumpAndSettle`
/// 它会一直推进到没有待处理帧，**时间可能瞬间跳过整段停留**，
/// 外部脚本根本来不及截图。必须逐 100ms 步进，让停留"真实发生"。
///
/// ## ⚠️ 副作用（必须知道）
/// `_holdFor` 推进的是**仿真时间**，而 `initState` 里 `_armHide(seconds: 6)` 的
/// 自动隐藏定时器也吃这条时间线 —— 停留 14 秒必然超过 6 秒，
/// 于是**控制层会在 hold 期间自动隐藏**，导致之后的 `$(...).tap()` 失败
/// （`WaitUntilVisibleTimeoutException: not hit-testable`，实测踩过）。
/// 故每个 hold 之后都要重新 `tapIdle()` 唤回控制层。
Future<void> _holdFor(PatrolIntegrationTester $, Duration d) async {
  final steps = d.inMilliseconds ~/ 100;
  for (var i = 0; i < steps; i++) {
    await $.tester.pump(const Duration(milliseconds: 100));
  }
}
