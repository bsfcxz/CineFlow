/// U5 播放器浮层 z 序 + 进度条语义的**回归守护**。
///
/// # 这个批次修了什么
///
/// ## 1. 三个浮层会互相压住（审计 U5 实测）
///
/// | 浮层 | 原 bottom | 高度约 |
/// |---|---|---|
/// | 网络较慢提示卡 | 110 | 38 |
/// | 跳过片头浮钮 | **110** | 32 |
/// | 自动连播倒计时卡 | **96** | 36 |
///
/// 互斥条件只覆盖了"跳片头 vs 自动连播"（前者要求 `_autoNextSeconds == null`），
/// 另两组没有任何互斥 → 降档卡横贯全宽会把右下角的跳片头**盖住**；
/// 降档卡 110–148 与自动连播 96–132 **纵向重叠 22px**。
///
/// 改为 `CfPlayerOverlay.bottomFor(槽位)`：槽位间距 52 > 浮层典型高度 38，
/// 即便同时出现也是上下堆叠。
///
/// ## 2. 进度条无障碍语义（原先**完全裸奔**）
/// 读屏用户既听不到"播到哪了"，也无法用无障碍手势调整 —— 而它是播放器
/// 最重要的控件。补 `Semantics(slider: true, value:, onIncrease:, onDecrease:)`。
///
/// ## 3. 进度条命中区 26dp → 48dp
/// 26dp 只有 48dp 基线的 54%，躺着操作时很难按住。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/core/theme.dart';

/// 读源码并剥掉整行注释（否则注释里提到令牌会造成假绿 —— 实测踩过）。
String _code(String rel) => File(rel)
    .readAsStringSync()
    .split('\n')
    .where((l) {
      final s = l.trimLeft();
      return !s.startsWith('//') && !s.startsWith('*');
    })
    .join('\n');

void main() {
  group('U5 · 浮层槽位（CfPlayerOverlay）', () {
    test('槽位两两间距 ≥ 浮层典型高度（38dp）—— 保证不会压住', () {
      final bottoms = CfPlayerOverlay.allSlots
          .map(CfPlayerOverlay.bottomFor)
          .toList()
        ..sort();
      for (var i = 1; i < bottoms.length; i++) {
        final gap = bottoms[i] - bottoms[i - 1];
        expect(
          gap,
          greaterThanOrEqualTo(38.0),
          reason: '槽位 $i 与 $i-1 间距只有 $gap dp —— 小于浮层典型高度 38dp，'
              '两个浮层会**纵向重叠**。\n'
              '这正是收敛前的问题：降档卡 110–148 与自动连播 96–132 重叠 22px。',
        );
      }
    });

    test('三个槽位互不相同（没写成同一个值）', () {
      final vals =
          CfPlayerOverlay.allSlots.map(CfPlayerOverlay.bottomFor).toSet();
      expect(vals.length, CfPlayerOverlay.allSlots.length,
          reason: '有槽位算出了相同的 bottom —— 那等于没有分槽');
    });

    test('槽位顺序有语义：待决提示最低、建议最高', () {
      // 自动连播是"必须立刻做决定" → 最低（最显眼、不挡别的）
      // 降档建议是"只是建议"       → 最高（不跟用户正在点的按钮抢）
      expect(
        CfPlayerOverlay.bottomFor(CfPlayerOverlay.autoNext),
        lessThan(CfPlayerOverlay.bottomFor(CfPlayerOverlay.skipIntro)),
      );
      expect(
        CfPlayerOverlay.bottomFor(CfPlayerOverlay.skipIntro),
        lessThan(CfPlayerOverlay.bottomFor(CfPlayerOverlay.netSlow)),
      );
    });
  });

  group('U5 · 播放器源码约束（剥注释后断言）', () {
    final src = _code('lib/player/player_page.dart');

    test('三个浮层都走 CfPlayerOverlay，没有残留硬编码 bottom 96/110', () {
      expect(
        RegExp(r'bottom:\s*(96|110)\b').hasMatch(src),
        isFalse,
        reason: '浮层又用硬编码 bottom 了。\n'
            '收敛前的实测竞争：降档卡与跳片头**同为 110**（水平重叠）、\n'
            '降档卡 110–148 与自动连播 96–132（纵向重叠 22px）。\n'
            '请用 CfPlayerOverlay.bottomFor(槽位)。',
      );
      final n = RegExp(r'CfPlayerOverlay\.bottomFor\(').allMatches(src).length;
      expect(n, greaterThanOrEqualTo(3),
          reason: '应有 3 个浮层走槽位，实际只找到 $n 个');
    });

    test('进度条带 slider 语义（读完播到哪了 + 无障碍手势可调）', () {
      expect(RegExp(r'slider:\s*true').hasMatch(src), isTrue,
          reason: '进度条丢了 slider 语义 —— 读屏用户听不到进度');
      expect(RegExp(r'onIncrease:').hasMatch(src), isTrue,
          reason: '缺 onIncrease —— TalkBack 的"上滑"无法快进');
      expect(RegExp(r'onDecrease:').hasMatch(src), isTrue,
          reason: '缺 onDecrease —— TalkBack 的"下滑"无法快退');
      expect(RegExp(r"value:\s*'已播").hasMatch(src), isTrue,
          reason: 'value 应是「已播 mm:ss，共 mm:ss」这类可理解文本，\n'
              '而不是百分比（读屏念"34%"远不如念时间有用）');
    });

    test('进度条命中区撑到 48dp（视觉仍 26dp）', () {
      // 找 ProgressBar 里 `height: 48` 与 `height: 26` 同时存在
      final seg = src.substring(src.indexOf('class _ProgressBar'));
      expect(
        RegExp(r'height:\s*48').hasMatch(seg) &&
            RegExp(r'height:\s*26').hasMatch(seg),
        isTrue,
        reason: '进度条命中区没撑到 48dp。26dp 只有基线的 54%，\n'
            '躺着看片时很难按住（审计实测本仓库最小可点元素仅 16×16）。',
      );
    });
  });
}
