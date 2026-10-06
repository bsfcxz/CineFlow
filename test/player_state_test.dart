/// 播放器状态层的单元测试。
///
/// ## 为什么这一层必须先测
/// 上层（手势 / UI / 面板）**全部依赖这些状态与纯函数**。
/// 若 `effectiveSpeed` 或 `seekTo` 的钳制错了，UI 写得再对也是错的 ——
/// 而且症状会表现为"画面行为诡异"，极难定位到状态层。
///
/// ## 测试策略：把"交互规格"变成可执行断言
/// 用户给的交互清单（单击显隐/双击播放/长按3.0x/倍速循环…）
/// 逐条对应一个断言。这样交互规格**不会随时间腐烂** ——
/// 有人改坏了立刻红，而不是等用户发现"长按不快进了"。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/player/domain/models/playback_state.dart';
import 'package:cineflow/player/domain/models/ui_visibility_state.dart';
import 'package:cineflow/player/domain/player_constants.dart';

void main() {
  group('PlaybackState · 长按快进（交互清单第 2 条）', () {
    test('长按前 effectiveSpeed = userSpeed', () {
      const s = PlaybackState(userSpeed: 1.5);
      expect(s.effectiveSpeed, 1.5);
    });

    test('长按中 effectiveSpeed = longPressSpeed(3.0)', () {
      const s = PlaybackState(userSpeed: 1.5, isLongPressing: true);
      expect(s.effectiveSpeed, 3.0);
      expect(s.longPressSpeed, 3.0);
    });

    test('★ 松开后必然恢复 userSpeed（不可能忘记恢复）', () {
      // 这条是"用派生 getter 而不是直接改 userSpeed"的核心理由：
      // 只需翻 isLongPressing，恢复是结构保证的。
      final pressed =
          const PlaybackState(userSpeed: 2.5).copyWith(isLongPressing: true);
      expect(pressed.effectiveSpeed, 3.0);
      final released = pressed.copyWith(isLongPressing: false);
      expect(released.effectiveSpeed, 2.5,
          reason: '松开后必须回到用户设的 2.5x，而不是 3.0 或 1.0');
    });

    test('连续长按/松开多次不会漂移', () {
      var s = const PlaybackState(userSpeed: 2.0);
      for (var i = 0; i < 5; i++) {
        s = s.copyWith(isLongPressing: true);
        expect(s.effectiveSpeed, 3.0);
        s = s.copyWith(isLongPressing: false);
        expect(s.effectiveSpeed, 2.0, reason: '第 $i 轮后漂移了');
      }
    });
  });

  group('PlaybackState · progress / remaining', () {
    test('时长 0 时 progress = 0（不除零）', () {
      const s = PlaybackState(position: Duration(seconds: 5));
      expect(s.progress, 0.0);
    });

    test('正常进度', () {
      const s = PlaybackState(
          position: Duration(minutes: 30), duration: Duration(minutes: 60));
      expect(s.progress, closeTo(0.5, 0.001));
    });

    test('位置超过时长时 progress 钳到 1.0（不出现 >1）', () {
      const s = PlaybackState(
          position: Duration(minutes: 90), duration: Duration(minutes: 60));
      expect(s.progress, 1.0);
    });

    test('remaining 不会为负', () {
      const s = PlaybackState(
          position: Duration(minutes: 90), duration: Duration(minutes: 60));
      expect(s.remaining, Duration.zero,
          reason: 'seek 越界后 remaining 若为负，UI 会显示 "-30:00"');
    });
  });

  group('PlaybackState · copyWith 的 null 语义', () {
    test('errorMessage 可以被显式清空（哨兵模式）', () {
      const s = PlaybackState(errorMessage: 'boom');
      final cleared = s.copyWith(errorMessage: null);
      expect(cleared.errorMessage, isNull,
          reason: '若用 `?? this.errorMessage`，这里会保留 "boom" —— '
              '错误一旦出现就永远清不掉');
    });

    test('不传 errorMessage 时保持原值', () {
      const s = PlaybackState(errorMessage: 'boom');
      expect(s.copyWith(isPlaying: true).errorMessage, 'boom');
    });
  });

  group('PlaybackState · 相等性（Riverpod 靠它决定是否重建）', () {
    test('相同内容相等', () {
      expect(const PlaybackState(position: Duration(seconds: 1)),
          const PlaybackState(position: Duration(seconds: 1)));
    });

    test('不同内容不等', () {
      expect(const PlaybackState(position: Duration(seconds: 1)) ==
          const PlaybackState(position: Duration(seconds: 2)), isFalse);
    });

    test('hashCode 与 == 一致', () {
      const a = PlaybackState(position: Duration(seconds: 1), userSpeed: 2.0);
      const b = PlaybackState(position: Duration(seconds: 1), userSpeed: 2.0);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('PlayerSpeeds · 倍速循环（交互清单第 6 条）', () {
    test('★ 1.0 → 1.5 → 2.0 → 2.5 → 3.0 → 1.0', () {
      var s = 1.0;
      const expected = [1.5, 2.0, 2.5, 3.0, 1.0];
      for (final e in expected) {
        s = PlayerSpeeds.next(s);
        expect(s, e);
      }
      // 再走一圈确认稳定
      expect(PlayerSpeeds.next(3.0), 1.0);
    });

    test('循环列表与规格一致', () {
      expect(PlayerSpeeds.cycle, [1.0, 1.5, 2.0, 2.5, 3.0]);
    });

    test('自定义倍速（1.25）能落回最近的下一档', () {
      expect(PlayerSpeeds.next(1.25), 1.5);
      expect(PlayerSpeeds.next(2.9), 3.0);
    });

    test('超过最大值时回到 1.0', () {
      expect(PlayerSpeeds.next(3.5), 1.0);
    });

    test('按钮文案为一位小数 + x', () {
      expect(PlayerSpeeds.label(1.0), '1.0x');
      expect(PlayerSpeeds.label(2.5), '2.5x');
    });
  });

  group('UiVisibilityState · 锁定与显隐（交互清单第 15/16/20 条）', () {
    test('可见且未锁定 → 控制层可见', () {
      const s = UiVisibilityState(visible: true, isLocked: false);
      expect(s.controlsVisible, isTrue);
    });

    test('★ 锁定后强制隐藏控制层（无论 visible 是什么）', () {
      const s = UiVisibilityState(visible: true, isLocked: true);
      expect(s.controlsVisible, isFalse,
          reason: '锁定时必须强制隐藏 —— 这是"锁定"的核心语义。\n'
              '若漏了这条，锁上后控制层还在，用户仍能误操作。');
    });

    test('★ 锁按钮永远可见（否则锁上后无法解锁）', () {
      const locked = UiVisibilityState(isLocked: true);
      const unlocked = UiVisibilityState(isLocked: false);
      expect(locked.lockButtonVisible, isTrue);
      expect(unlocked.lockButtonVisible, isTrue,
          reason: '锁按钮若在锁定后不可见，用户只能杀进程才能解锁');
    });

    test('不可见且未锁定 → 控制层不可见', () {
      const s = UiVisibilityState(visible: false);
      expect(s.controlsVisible, isFalse);
    });
  });

  group('PlayerGestures · 常量与规格一致', () {
    test('源自 HTML 原型 JS 的实测值', () {
      expect(PlayerGestures.longPressDelay,
          const Duration(milliseconds: 500)); // LONG_PRESS_DELAY
      expect(PlayerGestures.tapDelay,
          const Duration(milliseconds: 250)); // TAP_DELAY
      expect(PlayerGestures.uiHideDelay, const Duration(seconds: 3)); // UI_HIDE_DELAY
      expect(PlayerGestures.moveSlop, 10); // Math.abs(dx) > 10
      expect(PlayerGestures.directionSlop, 15); // adx < 15 && ady < 15
      expect(PlayerGestures.verticalSensitivity, 120);
      expect(PlayerGestures.horizontalSeekSeconds, 180);
      expect(PlayerGestures.step, const Duration(seconds: 10));
    });

    test('★ 分区合计 100%（规格文档写 40/60/20 合计 120%，以原型为准）', () {
      // 原型：relX < 0.4 → 亮度；relX > 0.6 → 音量；中间 → dead
      expect(PlayerGestures.brightnessZoneRight, 0.4);
      expect(PlayerGestures.volumeZoneLeft, 0.6);
      expect(PlayerGestures.brightnessZoneRight,
          lessThan(PlayerGestures.volumeZoneLeft),
          reason: '亮度区右边界必须小于音量区左边界，否则没有死区');
      expect(
        PlayerGestures.brightnessZoneRight +
            (1 - PlayerGestures.volumeZoneLeft),
        lessThanOrEqualTo(1.0),
        reason: '左右两区加起来不能超过 100%',
      );
    });
  });

  group('面板常量', () {
    test('抽屉宽度按 min(屏宽×比例, 上限)', () {
      // 规格 §7.6：min(screenWidth * 0.9, 400)
      expect(PlayerPanels.settingsWidth(360), closeTo(324, 0.1));
      expect(PlayerPanels.settingsWidth(1000), 400,
          reason: '超宽屏应被上限截住');
      // 规格 §7.8：min(screenWidth * 0.8, 340)
      expect(PlayerPanels.playlistWidth(360), closeTo(288, 0.1));
      expect(PlayerPanels.playlistWidth(1000), 340);
    });

    test('动画时长与规格一致', () {
      expect(PlayerPanels.drawerDuration, const Duration(milliseconds: 350));
      expect(PlayerPanels.tabDuration, const Duration(milliseconds: 200));
    });
  });

  group('AspectMode / DecodeMode 文案（规格 §7.6）', () {
    test('画面比例五档，文案与规格一致', () {
      expect(AspectMode.values.map((e) => e.label).toList(),
          ['适应', '拉伸', '裁剪', '16:9', '4:3']);
    });

    test('16:9 与 4:3 有固定比例，其余由引擎决定', () {
      expect(AspectMode.ratio16x9.ratio, closeTo(16 / 9, 0.001));
      expect(AspectMode.ratio4x3.ratio, closeTo(4 / 3, 0.001));
      expect(AspectMode.contain.ratio, isNull);
      expect(AspectMode.fill.ratio, isNull);
      expect(AspectMode.cover.ratio, isNull);
    });

    test('解码方式两档', () {
      expect(DecodeMode.values.map((e) => e.label).toList(), ['硬解', '软解']);
    });
  });
}
