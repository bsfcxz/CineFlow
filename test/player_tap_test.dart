/// 双击播放/暂停 —— **补上交互清单第 1 条缺失的断言**。
///
/// ## 为什么需要这个文件
/// 自查发现：`player_ui_interaction_test.dart` 里
/// `§18 清单 1：单击显隐 / 双击播放` 这个 group **只有单击一个用例**。
/// **双击路径在全仓零断言** —— 唯一的 `togglePlay` 断言是点**按钮**
/// （`togglePlayButton`），走的不是手势层那条路径。
///
/// 后果：`PlayerUiPage._handleTap()` 里的分支（`_tapCount == 1` 走延时、
/// `else` 走双击）若被改坏，现有 688 例**全绿**，而用户会发现"双击不暂停了"。
///
/// ## 这条路径为什么容易改坏
/// 它依赖一个**跨帧可变计数** `_tapCount` + `Future.delayed`：
///   · 计数没重置 → 第三次点击被误判成第二次双击
///   · 延时窗写错 → 双击退化成"两次单击"（UI 闪两下）
///   · `mounted` 检查漏掉 → 页面已退出仍触发回调
/// 这些静态分析全看不出来。
///
/// ## 复用既有 harness
/// `pumpPlayer` 与回调记录器都在 `player_ui_interaction_test.dart` 里，
/// 直接 import 复用（**不复制**一份，避免两处 harness 漂移）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/player/application/providers/player_providers.dart';

import 'player_ui_interaction_test.dart' as base;

/// 点一次画面空白处（避开所有 UI 元素）。
const _blank = Offset(200, 300);

/// 两次点击间隔 **小于** 250ms 判定窗 —— 即双击。
Future<void> _doubleTap(WidgetTester tester, {int gapMs = 100}) async {
  await tester.tapAt(_blank);
  await tester.pump(Duration(milliseconds: gapMs));
  await tester.tapAt(_blank);
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  group('§18 清单 1 · 双击播放/暂停（本轮补上的缺口）', () {
    testWidgets('★ 250ms 内点两次 → 触发 togglePlay', (tester) async {
      final (_, h) = await base.pumpPlayer(tester);

      await _doubleTap(tester);

      expect(h.calls, contains('togglePlay'),
          reason: '250ms 内点两次应触发播放/暂停。\n'
              '若这条红 → `_handleTap()` 的双击分支坏了。');
    });

    testWidgets('★ 双击**不**顺带切换 UI 显隐（否则会闪一下）', (tester) async {
      final (c, h) = await base.pumpPlayer(tester);
      expect(c.read(uiVisibilityProvider).controlsVisible, isTrue);

      await _doubleTap(tester);

      expect(h.calls, contains('togglePlay'));
      expect(c.read(uiVisibilityProvider).controlsVisible, isTrue,
          reason: '双击是"播放/暂停"，不该把控制层藏了。\n'
              '若这条红 → 第一次点击的延时回调没被双击分支抑制。');
    });

    testWidgets('★ 间隔**超过** 250ms → 两次单击，不触发播放', (tester) async {
      final (_, h) = await base.pumpPlayer(tester);

      await tester.tapAt(_blank);
      await tester.pump(const Duration(milliseconds: 400)); // 超窗
      await tester.tapAt(_blank);
      await tester.pump(const Duration(milliseconds: 400));

      expect(h.calls.where((e) => e == 'togglePlay'), isEmpty,
          reason: '间隔超 250ms 是两次独立单击，不该触发播放/暂停');
    });

    testWidgets('★ 延时窗口内连点 3 次 → 只算 1 次双击，不重复播放', (tester) async {
      // ## 为什么用"3 连点"而不是"双击后再点一次"
      //
      // 我最初写的是"双击后再点一次，断言只触发 1 次播放"。
      // **反向注入证明那条测试是假的**：把 `else { _tapCount = 0; }` 删掉后
      // 它**照样全绿**。原因是延时回调末尾也有一句 `_tapCount = 0`，
      // 会在 250ms 时兜底复位 —— 与 else 分支的重置无关。
      //
      // 所以真正值得测的是**同一窗口内的连续点击**：
      // 计数必须累计，不能因为"已经触发过双击"就重置，
      // 否则第 3 次点击会被当成新的第 1 次 → 又多一次播放/暂停。
      final (_, h) = await base.pumpPlayer(tester);

      await tester.tapAt(_blank);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(_blank); // 第 2 次 → 双击 → 播放
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(_blank); // 第 3 次 → 仍在同一窗口内
      await tester.pump(const Duration(milliseconds: 500));

      expect(h.calls.where((e) => e == 'togglePlay').length, 1,
          reason: '三连点只应产生一次播放/暂停（第 2、3 次共用同一次双击判定）。\n'
              '若这条红 → 双击分支把计数重置了，导致第 3 次被当成新一轮单击。');
    });

    testWidgets('★ 锁定时双击不触发播放（锁定屏蔽所有手势）', (tester) async {
      final (c, h) = await base.pumpPlayer(tester);
      c.read(uiVisibilityProvider.notifier).toggleLock();
      await tester.pump(const Duration(milliseconds: 300));
      expect(c.read(uiVisibilityProvider).isLocked, isTrue);

      await _doubleTap(tester);

      expect(h.calls.where((e) => e == 'togglePlay'), isEmpty,
          reason: '锁定后手势层 `enabled=false`，双击不该落到播放');
    });
  });
}
