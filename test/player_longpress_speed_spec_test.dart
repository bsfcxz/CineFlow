/// **长按倍速的 5 条规格符合性测试**（用户明确给出，2026-10-09）。
///
/// 用户原话：
/// ```
/// 1. 长按只影响"实际播放倍速"，不修改"用户选择的倍速"
/// 2. 长按结束后，倍速按钮回到用户之前选择的值
/// 3. 倍速按钮点击循环永远只操作 userSpeed，与长按无关
/// 4. 长按期间，倍速按钮显示不变（仍显示用户选择的值）
/// 5. 长按期间，只有长按反馈浮层显示 longPressSpeed
/// ```
///
/// ## 为什么单独写一个文件
/// 这个需求**已经反复出过两次 bug**（见 `playback_speed_race_test.dart` 的文件头）：
/// · 第一次：差点把长按实现成 `userSpeed = 3.0`（用派生 getter 规避了）
/// · 第二次：内核的**迟到回报**通过 `syncSpeed` 把 3.0 写进了 `userSpeed`
///
/// 两次都是"污染用户偏好"这一类。所以这次把用户的规格**逐条固化成断言**，
/// 而不是靠某个测试间接覆盖 —— 规格本身值得有一份可执行的表述。
///
/// ## 两条线的区分（本文件的组织方式）
/// · **引擎线**：`effectiveSpeed`（长按期间 = longPressSpeed）→ 下发给内核
/// · **用户线**：`userSpeed`（长按期间**不变**）→ 按钮文案
/// 混淆这两条线就是那两次 bug 的共同根因。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/player/application/controllers/playback_controller.dart';
import 'package:cineflow/player/application/providers/player_providers.dart';
import 'package:cineflow/player/domain/player_constants.dart';

(ProviderContainer, PlaybackController) make() {
  final c = ProviderContainer();
  final ctl = c.read(playbackStateProvider.notifier);
  ctl.setPlaying(true); // 长按只在播放中生效
  return (c, ctl);
}

void main() {
  group('★ 长按倍速 5 条规格', () {
    // ---- 规格 1 ----
    test('① 长按只影响实际播放倍速，不改用户选择的倍速', () {
      final (c, ctl) = make();
      addTearDown(c.dispose);

      ctl.setUserSpeed(1.5); // 用户选了 1.5x
      ctl.startLongPress();

      expect(ctl.state.userSpeed, 1.5,
          reason: '长按**不得**修改 userSpeed —— 那是用户的偏好');
      expect(ctl.state.effectiveSpeed, ctl.state.longPressSpeed,
          reason: '但实际播放倍速应变成 longPressSpeed（引擎线）');
    });

    // ---- 规格 2 ----
    test('② 长按结束后，实际倍速回到用户之前选择的值', () {
      final (c, ctl) = make();
      addTearDown(c.dispose);

      ctl.setUserSpeed(1.5);
      ctl.startLongPress();
      ctl.endLongPress();

      expect(ctl.state.effectiveSpeed, 1.5,
          reason: '松开后实际播放倍速必须回到 1.5（不是 3.0、不是 1.0）');
      expect(ctl.state.userSpeed, 1.5, reason: '用户偏好始终未被改动');
    });

    test('② 变体：用户选的是 2.5x（非默认值）也要正确回来', () {
      final (c, ctl) = make();
      addTearDown(c.dispose);

      // 防"硬编码回 1.0"这类错误：用一个非 1.0 的用户值
      ctl.setUserSpeed(2.5);
      ctl.startLongPress();
      expect(ctl.state.effectiveSpeed, ctl.state.longPressSpeed);
      ctl.endLongPress();
      expect(ctl.state.effectiveSpeed, 2.5,
          reason: '若这条红 → 有人把"恢复"写成了硬编码的 1.0');
    });

    // ---- 规格 3 ----
    test('③ 倍速按钮循环只操作 userSpeed，与长按状态无关', () {
      final (c, ctl) = make();
      addTearDown(c.dispose);

      // 非长按状态下循环
      final before = ctl.state.userSpeed;
      ctl.cycleSpeed();
      expect(ctl.state.userSpeed, PlayerSpeeds.next(before),
          reason: '循环应按 PlayerSpeeds.cycle 前进一档');

      // 长按状态下循环：**userSpeed 仍应正常前进**
      // （长按不该让按钮失效 —— 规格说"与长按无关"）
      ctl.startLongPress();
      final duringLongPress = ctl.state.userSpeed;
      ctl.cycleSpeed();
      expect(ctl.state.userSpeed, PlayerSpeeds.next(duringLongPress),
          reason: '长按期间点倍速按钮，userSpeed 仍应正常循环\n'
              '（"与长按无关" = 两者互不干扰，不是"长按期间禁用按钮"）');
    });

    // ---- 规格 4（★ 这条最容易漏）----
    test('④ 长按期间，倍速按钮的文案不变（仍显示用户选择的值）', () {
      final (c, ctl) = make();
      addTearDown(c.dispose);

      ctl.setUserSpeed(1.5);
      final labelBefore = c.read(speedLabelProvider);
      expect(labelBefore, '1.5x', reason: '前提：按钮显示用户选的 1.5x');

      ctl.startLongPress();

      expect(c.read(speedLabelProvider), '1.5x',
          reason: '★ 长按期间按钮文案**不得**变成 3.0x。\n'
              '   若这条红 → `speedLabelProvider` 又用了 `effectiveSpeed`。\n'
              '   正确用法：effectiveSpeed 给**引擎**，userSpeed 给**用户看**。');
    });

    test('④ 变体：长按结束后按钮文案仍是用户选择的值', () {
      final (c, ctl) = make();
      addTearDown(c.dispose);

      ctl.setUserSpeed(2.0);
      ctl.startLongPress();
      ctl.endLongPress();

      expect(c.read(speedLabelProvider), '2.0x',
          reason: '长按全流程走完，按钮应回到 2.0x（不是 3.0x、不是 1.0x）');
    });

    // ---- 规格 5 ----
    test('⑤ 长按期间浮层拿到的 longPressSpeed 与用户倍速是两个独立值', () {
      final (c, ctl) = make();
      addTearDown(c.dispose);

      ctl.setUserSpeed(1.25);
      ctl.startLongPress();

      final s = ctl.state;
      // 浮层（PlayerFeedbackLayer）拿的是 longPressSpeed；
      // 按钮拿的是 userSpeed。两者在长按期间**必须不同**，
      // 否则"浮层显示 3.0x 而按钮显示 1.25x"这个视觉区分就没了。
      expect(s.longPressSpeed, 3.0, reason: '长按倍速默认 3.0（与原型一致）');
      expect(s.userSpeed, 1.25);
      expect(s.longPressSpeed == s.userSpeed, isFalse,
          reason: '若两者相等，"浮层显示长按倍速"就失去了视觉意义 ——\n'
              '用户无法从界面判断"现在是临时快进还是我改了倍速"');
    });

    test('⑤ 长按期间浮层可用的值 = longPressSpeed（与 effectiveSpeed 一致）',
        () {
      final (c, ctl) = make();
      addTearDown(c.dispose);

      ctl.setUserSpeed(1.0);
      ctl.startLongPress();
      // 浮层用的是 longPressSpeed 字段；引擎用的是 effectiveSpeed。
      // 长按期间这两者应相等（都代表"现在实际在跑 3.0"）。
      expect(ctl.state.longPressSpeed, ctl.state.effectiveSpeed,
          reason: '长按期间：浮层显示的 = 引擎实际跑的 = longPressSpeed');
    });

    // ---- 端到端：串起 5 条 ----
    test('★ 端到端：完整走一遍长按生命周期，全程守住两条线', () {
      final (c, ctl) = make();
      addTearDown(c.dispose);

      // 用户先点两次倍速按钮 → 1.5x
      ctl.cycleSpeed();
      expect(ctl.state.userSpeed, 1.5);
      expect(c.read(speedLabelProvider), '1.5x');

      // 长按
      ctl.startLongPress();
      expect(ctl.state.userSpeed, 1.5, reason: '规格①：用户倍速不变');
      expect(ctl.state.effectiveSpeed, 3.0, reason: '规格①：实际变 3.0');
      expect(c.read(speedLabelProvider), '1.5x', reason: '规格④：按钮不变');

      // 内核迟到回报（历史上污染过 userSpeed 的那条路径）
      ctl.syncSpeed(3.0);
      expect(ctl.state.userSpeed, 1.5, reason: '规格①：迟到回报不得污染');

      // 松手
      ctl.endLongPress();
      expect(ctl.state.effectiveSpeed, 1.5, reason: '规格②：实际回到 1.5');
      expect(c.read(speedLabelProvider), '1.5x', reason: '规格②：按钮仍是 1.5x');

      // 松手后内核再报一次 3.0（真正的迟到回报）
      ctl.syncSpeed(3.0);
      expect(ctl.state.userSpeed, 1.5,
          reason: '规格①：松手后的迟到回报也不得污染');

      // 规格③：再来点按钮，从 1.5 继续前进
      ctl.cycleSpeed();
      expect(ctl.state.userSpeed, 2.0,
          reason: '规格③：循环基于当前 userSpeed 前进，与长按历史无关');
    });
  });
}
