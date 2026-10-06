/// 手势层单元测试 —— **交互规格的可执行化**。
///
/// ## 为什么手势判定必须做成纯函数并单独测
/// 手势逻辑有三个"看不见的坑"，widget 测试都很难覆盖：
///   1. **分区边界**：0.4 / 0.6 两条线，差一点点就落到死区
///   2. **两段式阈值**：10px 算"移动过"、15px 才"判方向"
///   3. **长按与拖动互斥**：长按触发后必须忽略一切移动
///
/// 抽成 `GestureController.resolveMode / brightnessFor / volumeFor /
/// seekTargetFor` 后，这些边界可以**逐条精确断言**，
/// 而不用真的在屏幕上模拟滑动（慢、脆、且难覆盖边界）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/player/application/controllers/gesture_controller.dart';
import 'package:cineflow/player/domain/models/gesture_state.dart';
import 'package:cineflow/player/domain/player_constants.dart';

void main() {
  const w = 400.0;
  const h = 800.0;

  group('手势分区判定（交互清单第 3/4/5 条）', () {
    test('横向为主 → seek', () {
      expect(
        GestureController.resolveMode(
            delta: const Offset(-40, 10), relativeX: w / 2, width: w),
        GestureMode.seek,
        reason: '向左滑也是 seek（快退），不是亮度',
      );
    });

    test('左 40% 竖滑 → 亮度', () {
      expect(
        GestureController.resolveMode(
            delta: const Offset(2, -30), relativeX: 100, width: w),
        GestureMode.brightness,
      );
    });

    test('右 40% 竖滑 → 音量', () {
      expect(
        GestureController.resolveMode(
            delta: const Offset(2, -30), relativeX: 300, width: w),
        GestureMode.volume,
      );
    });

    test('★ 中间 20% 是死区（0.4–0.6）', () {
      for (final x in [0.41, 0.5, 0.59]) {
        expect(
          GestureController.resolveMode(
              delta: const Offset(2, -30), relativeX: w * x, width: w),
          GestureMode.dead,
          reason: 'x=${w * x} 应落在死区（中间是播放按钮所在区域，\n'
              '手指从这里起滑多半是想点按，误判成亮度/音量更糟）',
        );
      }
    });

    test('★ 分区边界精确：0.39 亮度 / 0.40 亮度 / 0.41 死区', () {
      // 原型：relX < width*0.4 → brightness（严格小于）
      expect(
        GestureController.resolveMode(
            delta: const Offset(2, -30), relativeX: w * 0.39, width: w),
        GestureMode.brightness,
      );
      expect(
        GestureController.resolveMode(
            delta: const Offset(2, -30), relativeX: w * 0.40, width: w),
        GestureMode.dead,
        reason: '0.40 是**严格小于**的边界，等于时进死区（原型语义）',
      );
      // 原型：relX > width*0.6 → volume
      expect(
        GestureController.resolveMode(
            delta: const Offset(2, -30), relativeX: w * 0.61, width: w),
        GestureMode.volume,
      );
      expect(
        GestureController.resolveMode(
            delta: const Offset(2, -30), relativeX: w * 0.60, width: w),
        GestureMode.dead,
        reason: '0.60 同理：等于时进死区',
      );
    });

    test('位移不足 15px → none（等下一次 move）', () {
      expect(
        GestureController.resolveMode(
            delta: const Offset(14, 0), relativeX: 100, width: w),
        GestureMode.none,
      );
      expect(
        GestureController.resolveMode(
            delta: const Offset(15, 0), relativeX: 100, width: w),
        GestureMode.seek,
        reason: '恰好 15px 应判方向（原型是 `< 15` 才 return）',
      );
    });

    test('斜 45° 时按 |dx| > |dy| 优先判 seek（原型严格大于）', () {
      expect(
        GestureController.resolveMode(
            delta: const Offset(30, 29), relativeX: 100, width: w),
        GestureMode.seek,
      );
      // 相等时落到 vertical 分支
      expect(
        GestureController.resolveMode(
            delta: const Offset(30, 30), relativeX: 100, width: w),
        GestureMode.brightness,
        reason: '|dx| == |dy| 时 adx > ady 为 false → 走纵向分支（原型如此）',
      );
    });
  });

  group('亮度映射（交互清单第 3 条）', () {
    test('向上滑增大亮度', () {
      final v = GestureController.brightnessFor(
          start: 50, dy: -h / 2, height: h);
      // -(-400/800)*120 = +60 → 50+60 = 110 → 钳到 100
      expect(v, greaterThan(50), reason: '向上滑应增大');
      expect(v, 100, reason: '50+60=110 超过上限 → 钳到 100');
    });

    test('向下滑减小亮度', () {
      final v = GestureController.brightnessFor(
          start: 50, dy: h / 2, height: h);
      // 50 - 60 = -10 → 钳到 0
      expect(v, lessThan(50), reason: '向下滑应减小');
      expect(v, 0, reason: '50-60=-10 低于下限 → 钳到 0');
    });

    test('未被钳制时是精确的线性映射（+60）', () {
      // 起点 20、上滑半屏 → 20+60 = 80（两个边界都不撞）
      final v = GestureController.brightnessFor(
          start: 20, dy: -h / 2, height: h);
      expect(v, closeTo(80, 0.01));
    });

    test('★ 满屏滑动 ≈ 120 个单位', () {
      // 起点 0、上滑满屏 → 0+120 → 钳到 100
      expect(GestureController.brightnessFor(start: 0, dy: -h, height: h), 100);
      // 起点 0、上滑半屏 → 60（不撞上限，可看到真实灵敏度）
      expect(GestureController.brightnessFor(start: 0, dy: -h / 2, height: h),
          closeTo(60, 0.01));
    });

    test('两端钳制在 0–100', () {
      expect(
          GestureController.brightnessFor(start: 0, dy: -h * 5, height: h), 100);
      expect(
          GestureController.brightnessFor(start: 100, dy: h * 5, height: h), 0);
    });
  });

  group('音量映射（交互清单第 4 条）', () {
    test('与亮度同灵敏度（原型一致）', () {
      expect(
        GestureController.volumeFor(start: 0, dy: -h / 2, height: h),
        GestureController.brightnessFor(start: 0, dy: -h / 2, height: h),
      );
    });

    test('钳制在 0–100', () {
      expect(GestureController.volumeFor(start: 90, dy: -h, height: h), 100);
      expect(GestureController.volumeFor(start: 10, dy: h, height: h), 0);
    });
  });

  group('进度映射（交互清单第 5 条）', () {
    const total = Duration(hours: 2); // 7200s

    test('★ 横向满屏 = 180 秒', () {
      final t = GestureController.seekTargetFor(
        start: const Duration(minutes: 30),
        dx: w,
        width: w,
        total: total,
      );
      expect(t, const Duration(minutes: 30) + const Duration(seconds: 180));
    });

    test('半屏 = 90 秒', () {
      final t = GestureController.seekTargetFor(
        start: Duration.zero,
        dx: w / 2,
        width: w,
        total: total,
      );
      expect(t, const Duration(seconds: 90));
    });

    test('向左滑回退', () {
      final t = GestureController.seekTargetFor(
        start: const Duration(minutes: 30),
        dx: -w / 2,
        width: w,
        total: total,
      );
      expect(t, const Duration(minutes: 30) - const Duration(seconds: 90));
    });

    test('★ 不会越过 0（起点靠前时）', () {
      final t = GestureController.seekTargetFor(
        start: const Duration(seconds: 10),
        dx: -w, // 回退 180s
        width: w,
        total: total,
      );
      expect(t, Duration.zero, reason: '不能出现负位置');
    });

    test('★ 不会越过总时长', () {
      final t = GestureController.seekTargetFor(
        start: const Duration(minutes: 119),
        dx: w, // +180s
        width: w,
        total: total,
      );
      expect(t, total, reason: '不能越过片尾');
    });

    test('基准是"按下时的位置"，不是"当前位置 + 增量"', () {
      // 这条守的是"滑动不加速"：连续两次 move 用同一个 start
      // 应得到与"一次性滑同样距离"相同的结果。
      final once = GestureController.seekTargetFor(
          start: const Duration(minutes: 10), dx: 100, width: w, total: total);
      final twiceFirst = GestureController.seekTargetFor(
          start: const Duration(minutes: 10), dx: 50, width: w, total: total);
      final twiceSecond = GestureController.seekTargetFor(
          start: const Duration(minutes: 10), dx: 100, width: w, total: total);
      expect(once, twiceSecond);
      expect(twiceFirst, isNot(once));
      // 若实现成"累加"，第二次会变成 10min + 50s + 100s 的偏移
      expect(twiceSecond,
          const Duration(minutes: 10) + const Duration(seconds: 45));
    });
  });

  group('长按（交互清单第 2 条）', () {
    test('★ 常量是 500ms', () {
      expect(PlayerGestures.longPressDelay, const Duration(milliseconds: 500));
    });

    test('移动超过 10px 会取消长按（moved = true）', () {
      expect(PlayerGestures.moveSlop, 10);
      // moved 后 resolveMode 才能判方向 —— 两者阈值不同是刻意的：
      // 10px 认定"在动"（取消长按），15px 才"判方向"（避免抖动误判）
      expect(PlayerGestures.moveSlop,
          lessThan(PlayerGestures.directionSlop),
          reason: '两段式：先认定移动、再多挪一点才判方向');
    });
  });

  group('GestureState 不可变语义', () {
    test('reset 回到初始态', () {
      const s = GestureState(
        active: true,
        mode: GestureMode.seek,
        moved: true,
        longPressFired: true,
      );
      final r = s.reset();
      expect(r.active, isFalse);
      expect(r.mode, GestureMode.none);
      expect(r.moved, isFalse);
      expect(r.longPressFired, isFalse);
    });

    test('指示器可见性由 mode 派生', () {
      expect(const GestureState(mode: GestureMode.seek).showingSeek, isTrue);
      expect(const GestureState(mode: GestureMode.seek).showingBrightness, isFalse);
      expect(
          const GestureState(mode: GestureMode.brightness).showingBrightness,
          isTrue);
      expect(const GestureState(mode: GestureMode.volume).showingVolume, isTrue);
      expect(const GestureState(mode: GestureMode.dead).showingSeek, isFalse);
    });

    test('copyWith 保留未指定字段', () {
      const s = GestureState(startBrightness: 42, startVolume: 7);
      final t = s.copyWith(mode: GestureMode.brightness);
      expect(t.startBrightness, 42);
      expect(t.startVolume, 7);
      expect(t.mode, GestureMode.brightness);
    });
  });
}
