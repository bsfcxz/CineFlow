/// 长按倍速的**竞态回归测试** —— 用户两次反馈"结束后速度没恢复"。
///
/// ## ⚠️ 本文件已按"5 条禁令"重构（2026-10-09）
///
/// ### 重构前的历史（保留，因为它解释了禁令为什么存在）
/// **第一段**：最初想把长按实现成 `userSpeed = 3.0`，松手时存回。
/// 但松手有 3 条路径（移出屏幕/被取消/切后台），必漏其一 →
/// 改成 `effectiveSpeed` 派生 getter（长按只翻 `isLongPressing`）。
///
/// **第二段**：getter 防住了正向，但内核的**异步回报**从反向把污染带回来 ——
/// `syncSpeed(3.0)` 在 `isLongPressing` 已翻回 false **之后**到达。
/// 我当时加了第二道守卫（"值 == longPressSpeed 且在 2 秒窗口内"则忽略）。
///
/// ### 为什么现在把两道守卫都删了
/// 用户 2026-10-09 给出的禁令①点破了根因：
/// > 禁止用同一个变量同时表示"用户倍速"和"实际倍速"
///
/// `syncSpeed` 的入参是**内核回报的实际速率**，却写进 `userSpeed`
/// （用户偏好）—— **那条写回路径本身就是缺陷**。我加的两道守卫是
/// "在补丁上打补丁"：能挡住已知的两种污染场景，挡不住第三种。
///
/// 按禁令⑤拆出只读的 `engineSpeed` 后：
/// · `syncSpeed` **只写 engineSpeed**，永不碰 userSpeed
/// · `userSpeed` **只有用户操作能写**
/// ⇒ 污染路径从结构上消失，守卫不再需要。
///
/// 本文件因此改为断言**新契约**（两条线互不干扰）。
///
/// ## 相关文件
/// · `player_speed_architecture_guard_test.dart` —— 5 条禁令的**静态守卫**
/// · `player_longpress_speed_spec_test.dart` —— 5 条**行为规格**
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/player/application/controllers/playback_controller.dart';
import 'package:cineflow/player/application/providers/player_providers.dart';

(ProviderContainer, PlaybackController) make() {
  final c = ProviderContainer();
  final controller = c.read(playbackStateProvider.notifier);
  controller.setPlaying(true); // 长按只在播放时生效
  return (c, controller);
}

void main() {
  group('★ 两条线互不污染（userSpeed=用户偏好 / engineSpeed=内核实际）', () {
    // ---- 用户线：长按不得改变用户偏好 ----
    test('长按中 userSpeed 保持 1.0（effectiveSpeed 才是 3.0）', () {
      final (c, ctl) = make();
      addTearDown(c.dispose);

      ctl.startLongPress();
      expect(ctl.state.effectiveSpeed, 3.0, reason: '长按中播放速率应是 3.0');
      expect(ctl.state.userSpeed, 1.0, reason: '但用户偏好不应被改动');
    });

    // ---- 引擎线：内核回报只写 engineSpeed ----
    test('★ 内核回报只更新 engineSpeed，绝不碰 userSpeed', () {
      final (c, ctl) = make();
      addTearDown(c.dispose);

      ctl.syncSpeed(1.5);
      expect(ctl.state.engineSpeed, 1.5,
          reason: '内核回报应落到 engineSpeed（这是它的唯一去向）');
      expect(ctl.state.userSpeed, 1.0,
          reason: '★ 禁令①：内核回报**不得**改写 userSpeed。\n'
              '    若这条红 → syncSpeed 又写回 userSpeed 了，\n'
              '    那么"长按临时倍速被固化成用户偏好"的老 bug 会原样复发。');
    });

    test('★ 长按期间的回报（3.0）不会污染 userSpeed', () {
      final (c, ctl) = make();
      addTearDown(c.dispose);

      ctl.startLongPress();
      ctl.syncSpeed(3.0); // 内核把长按的 3.0 应用并回报
      expect(ctl.state.userSpeed, 1.0, reason: '用户偏好不受影响');
      expect(ctl.state.engineSpeed, 3.0, reason: '引擎实际速率是 3.0');
    });

    test('★ 松手后的迟到回报（3.0）依然不污染 userSpeed', () {
      // 这是"第二段历史"的场景：过去要靠 2 秒时间窗才能挡住。
      // 拆字段后**不需要窗口** —— 因为根本不写 userSpeed。
      final (c, ctl) = make();
      addTearDown(c.dispose);

      ctl.startLongPress();
      ctl.endLongPress();
      ctl.syncSpeed(3.0); // 迟到的 3.0

      expect(ctl.state.userSpeed, 1.0,
          reason: '★ 旧实现需要"时间窗"才能挡住这一条；\n'
              '    新实现因为**不写 userSpeed**，天然挡住 ——\n'
              '    连"迟到多久"都不用关心。');
      expect(ctl.state.engineSpeed, 3.0,
          reason: '引擎确实在跑 3.0（如实记录，即使松手了，\n'
              '    内核可能还没切回来 —— 那是引擎的真实状态）');
    });

    test('★ 用户主动循环不受内核回报影响（两条线不打架）', () {
      final (c, ctl) = make();
      addTearDown(c.dispose);

      // 内核先报了一个值
      ctl.syncSpeed(1.5);
      // 用户点按钮：应基于 **userSpeed** 前进，而不是基于 engineSpeed
      ctl.cycleSpeed();
      expect(ctl.state.userSpeed, 1.5,
          reason: '1.0 → 1.5（基于用户自己的值，与内核报了什么无关）');
      expect(ctl.state.engineSpeed, 1.5,
          reason: 'engineSpeed 不被用户操作改写（禁令⑤）');
    });

    test('★ 倍速按钮文案永远走 userSpeed（长按期间不变）', () {
      final (c, ctl) = make();
      addTearDown(c.dispose);

      ctl.setUserSpeed(2.0);
      expect(c.read(speedLabelProvider), '2.0x');

      ctl.startLongPress();
      expect(c.read(speedLabelProvider), '2.0x',
          reason: '★ 禁令④：长按期间按钮文案不得变成 3.0x');

      ctl.syncSpeed(3.0); // 内核回报 3.0
      expect(c.read(speedLabelProvider), '2.0x',
          reason: '内核回报也不得影响按钮文案');
    });
  });
}
