/// 长按倍速的**竞态回归测试** —— 用户两次反馈"结束后速度没恢复"。
///
/// ## 这个 bug 的两段历史（说明为什么要两个测试）
///
/// **第一段（用派生 getter 防住了）**：最初想把长按实现成
/// `userSpeed = 3.0`，松手时存回。但松手有 3 条路径
/// （移出屏幕/被取消/切后台），必漏其一 → 改成 `effectiveSpeed`
/// 派生 getter（长按只翻 `isLongPressing`），"松手恢复"成为结构保证。
///
/// **第二段（本轮修的）**：getter 防住了正向，但内核的
/// **异步回报**从反向把污染带了回来 —— `syncSpeed(3.0)` 在
/// `isLongPressing` 已经翻回 false **之后**到达（迟到回报），
/// 第一道守卫（`if (isLongPressing) return`）失效。
///
/// 本文件的两个测试分别钉死这两段。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/player/application/controllers/playback_controller.dart';
import 'package:cineflow/player/application/providers/player_providers.dart';

(ProviderContainer, PlaybackController) make() {
  final c = ProviderContainer();
  final controller = c.read(playbackStateProvider.notifier);
  // 模拟播放中（长按只在播放时生效）
  controller.setPlaying(true);
  return (c, controller);
}

void main() {
  group('★ 长按倍速不污染用户偏好', () {
    test('第一段：长按中 userSpeed 保持 1.0（effectiveSpeed 才是 3.0）', () {
      final (c, ctl) = make();
      addTearDown(c.dispose);

      ctl.startLongPress();
      expect(ctl.state.effectiveSpeed, 3.0, reason: '长按中播放速率应是 3.0');
      expect(ctl.state.userSpeed, 1.0, reason: '但用户偏好不应被改动');
    });

    test('★ 第二段：松手后内核的迟到回报（rate=3.0）不污染 userSpeed',
        () {
      final (c, ctl) = make();
      addTearDown(c.dispose);

      // 长按
      ctl.startLongPress();
      expect(ctl.state.isLongPressing, isTrue);

      // 内核把 3.0 应用并回报（此时仍在长按中 → 被第一道守卫挡住）
      ctl.syncSpeed(3.0);
      expect(ctl.state.userSpeed, 1.0, reason: '长按中的回报不应污染 userSpeed');

      // 松手 → isLongPressing 翻回 false
      ctl.endLongPress();
      expect(ctl.state.isLongPressing, isFalse);

      // ★ 内核的**迟到回报**（rate=3.0）此时才到达
      ctl.syncSpeed(3.0);

      expect(ctl.state.userSpeed, 1.0,
          reason: '松手后迟到的 rate=3.0 是**长按残留**，不是用户操作 ——\n'
              '若 userSpeed 变成 3.0，倍速按钮会显示 3.0x 且回不去。\n'
              '若这条红 → `syncSpeed` 的迟到回报过滤被移除或时间窗太短。');
    });

    test('★ 用户主动循环到 3.0x 仍是合法的（过滤不能永久屏蔽）', () {
      final (c, ctl) = make();
      addTearDown(c.dispose);

      // 用户**主动**点倍速按钮 4 次：1.0→1.5→2.0→2.5→3.0
      ctl.cycleSpeed();
      ctl.cycleSpeed();
      ctl.cycleSpeed();
      ctl.cycleSpeed();
      expect(ctl.state.userSpeed, 3.0,
          reason: '用户主动操作必须生效 —— 迟到回报过滤只针对\n'
              '"长按刚结束后**同一值**的自动回报"，不能变成永久屏蔽 3.0');
    });

    test('松手后：先来一条**别的值**的回报 → 正常写入（窗口不误吞）', () {
      final (c, ctl) = make();
      addTearDown(c.dispose);

      ctl.startLongPress();
      ctl.endLongPress(); // 刚结束

      // 紧接着来一条**不同**值的回报（例如长按前点的倍速按钮，
      // 内核此刻才处理完）→ 应正常写入
      ctl.syncSpeed(1.5);
      expect(ctl.state.userSpeed, 1.5,
          reason: '过滤条件是「值 == longPressSpeed 且在窗口内」——\n'
              '别的值不该被误吞');
    });
  });
}
