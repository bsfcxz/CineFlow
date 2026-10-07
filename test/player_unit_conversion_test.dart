/// **单位换算**的测试 —— 两个真机 bug 的回归防线。
///
/// ## 为什么这类 bug 必须用测试守
/// 单位换算错误**编译通过、静态分析零告警、UI 也"有反应"**：
///   · 指示器圆环照常转动（它用的是手势侧 0–100）
///   · 只是**效果不对**（画面不变亮/不调暗、音量一调就满）
/// 唯一的发现途径是"人肉试出来"—— 而本项目已经栽过**两次**
/// （第一次是面板音量 0–1 vs 内核 0–100，第二次是这次的手势亮度）。
///
/// 所以把换算抽成纯函数并钉死边界值，是唯一能防第三次的办法。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/player/player_flow_page.dart'
    show brightnessToScreen, volumeToKernel;

void main() {
  group('★ brightnessToScreen：手势 0–100 → 屏幕 0.0–1.0', () {
    test('★ 回归：30 不再被钳成 1.0（真机 bug 的核心）', () {
      // 原实现是 `v.clamp(0.05, 1.0)` —— 直接拿 0–100 当 0–1 用，
      // 于是 v=30 被钳到 **1.0 = 满亮度**，用户"越滑越亮、调不暗"。
      final r = brightnessToScreen(30);
      expect(r, closeTo(0.30, 0.001),
          reason: '30% 亮度应换算成 0.30。\n'
              '若返回 1.0 → `v.clamp(0.05, 1.0)` 那个 bug 又回来了。');
      expect(r, isNot(1.0));
    });

    test('★ 单调性：越往下滑越暗（不被钳成常数）', () {
      final values = [0.0, 10.0, 30.0, 50.0, 70.0, 100.0]
          .map(brightnessToScreen)
          .toList();
      for (var i = 1; i < values.length; i++) {
        expect(values[i], greaterThan(values[i - 1]),
            reason: '亮度必须随输入单调递增：$values\n'
                '若出现相等 → 说明被钳制成常数（原 bug 就是 30~100 全变 1.0）');
      }
    });

    test('100 → 1.0（满亮度）', () {
      expect(brightnessToScreen(100), closeTo(1.0, 0.001));
    });

    test('★ 下限保底 0.05：不能全黑（否则用户看不到画面也划不动）', () {
      expect(brightnessToScreen(0), closeTo(0.05, 0.001),
          reason: '屏幕亮度 0 会让画面全黑，用户无法划回来。\n'
              '留 5% 保底是 Android 播放器的通行做法。');
    });

    test('越界输入不崩（负数 / 超 100）', () {
      expect(brightnessToScreen(-50), closeTo(0.05, 0.001));
      expect(brightnessToScreen(999), closeTo(1.0, 0.001));
    });
  });

  group('★ volumeToKernel：面板 0–1 → 内核 0–100', () {
    test('0.7 → 70（默认音量）', () {
      expect(volumeToKernel(0.7), closeTo(70.0, 0.001));
    });

    test('0 → 0、1 → 100（两端）', () {
      expect(volumeToKernel(0), closeTo(0.0, 0.001));
      expect(volumeToKernel(1), closeTo(100.0, 0.001));
    });

    test('单调递增', () {
      final values = [0.0, 0.25, 0.5, 0.75, 1.0].map(volumeToKernel).toList();
      for (var i = 1; i < values.length; i++) {
        expect(values[i], greaterThan(values[i - 1]));
      }
    });

    test('★ 钳制在 0–100（越界不崩）', () {
      expect(volumeToKernel(-1), closeTo(0.0, 0.001));
      expect(volumeToKernel(2), closeTo(100.0, 0.001));
    });

    test('★ 与 brightnessToScreen 是**不同**的口径（防混淆）', () {
      // 两者都做"0–1 ↔ 0–100"的换算，但方向与用途不同：
      //   volumeToKernel: 输入 0–1  → 输出 0–100
      //   brightnessToScreen: 输入 0–100 → 输出 0.05–1.0
      // 若有人把两者接反，下面的断言会立刻抓到。
      expect(volumeToKernel(1), closeTo(100.0, 0.001),
          reason: 'volumeToKernel 的输出是 0–100 量级');
      expect(brightnessToScreen(1), closeTo(0.05, 0.001),
          reason: 'brightnessToScreen 的输入是 0–100 量级，\n'
              '故输入 1 表示"1% 亮度"→ 输出下限 0.05。\n'
              '若这里返回 0.01 或 1.0 → 两个函数的输入口径接反了。');
    });
  });
}
