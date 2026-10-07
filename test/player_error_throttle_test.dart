/// **内核错误洪水的限流** —— 真机事故的回归测试。
///
/// ## 事故现象（2026-10-07 真机实测）
/// 用户报"新 UI 的功能全都用不了"。logcat 揭示了根因：
/// ```
/// [mpv/stream] Failed to open .../hls1/main/755
/// end-file error: error=-13 loading failed
/// [mpv/stream] Failed to open .../hls1/main/756
/// ... 48 秒内 1024 次（21.3 次/秒）
/// ```
/// 一个**死源 STRM** 切到转码 HLS 后，mpv 对每个分片都失败一次。
/// 而 `PlayerFlowPage` 的 errorStream 回调**每次都**：
///   1. `setError(...)` → 触发 provider 重建
///   2. `showSnackBar(...)` → 入队一个 SnackBar
///
/// 结果是 SnackBar 排成长队、页面持续重建 → **用户点什么都没反应**。
///
/// ## 为什么要用测试守（而不是只靠改代码）
/// "限流"是**容易被无意识改掉**的：
///   · 后来有人为了"错误更及时"把冷却去掉 → 洪水复现
///   · 或者把条件从 `&&` 改成 `||` → 不同错误也被吞掉（用户看不到真错误）
/// 两种都要能被抓住，所以本文件**同时测两个方向**：
///   ① 重复错误必须被抑制（防洪水）
///   ② **不同**错误必须立刻上报（防"该报的没报"）
library;

import 'package:flutter_test/flutter_test.dart';

/// 把限流逻辑抽成纯函数来测 —— 与 `PlayerFlowPage._wireKernel` 里的
/// 判定条件**逐字对应**。
///
/// ⚠️ 若改了页面里的条件，必须同步改这里；两处不一致时
/// `test/player_flow_page_test.dart` 的集成用例会发现行为不符。
///
/// 返回 true = 应当上报（放行）；false = 应被抑制。
bool shouldReportError({
  required String incoming,
  required String? lastError,
  required DateTime? lastAt,
  required DateTime now,
  Duration cooldown = const Duration(seconds: 3),
}) {
  final isSame = incoming == lastError;
  final withinCooldown =
      lastAt != null && now.difference(lastAt) < cooldown;
  if (isSame && withinCooldown) return false;
  return true;
}

void main() {
  final t0 = DateTime(2026, 10, 7, 21, 22, 3);

  group('★ 内核错误限流（真机事故回归）', () {
    test('★ 同一错误在冷却期内被抑制（防洪水）', () {
      const err = '播放失败（内核报错）';
      // 模拟真机：21.3 次/秒，间隔约 47ms
      var lastAt = t0;
      var reported = 1;
      for (var i = 0; i < 20; i++) {
        final now = t0.add(Duration(milliseconds: 47 * (i + 1)));
        if (shouldReportError(
          incoming: err,
          lastError: err,
          lastAt: lastAt,
          now: now,
        )) {
          reported++;
          lastAt = now;
        }
      }
      // 1 秒内 20 次 → 冷却 3s → 最多报 1 次
      expect(reported, 1,
          reason: '同一错误 1 秒内来 20 次，只该上报 1 次。\n'
              '若这条红 → 洪水会复现：UI 被 SnackBar 与重建淹没。');
    });

    test('★ 冷却期外允许重报（持续失败仍会提示）', () {
      const err = '播放失败（内核报错）';
      expect(
        shouldReportError(
          incoming: err,
          lastError: err,
          lastAt: t0,
          now: t0.add(const Duration(seconds: 4)),
        ),
        isTrue,
        reason: '超过冷却期应允许再报 —— 不能变成"永远只报一次"，\n'
            '否则用户切集后又失败时会以为没问题',
      );
    });

    test('★ 不同错误必须立刻上报（不能被当成重复吞掉）', () {
      expect(
        shouldReportError(
          incoming: '连接超时，该视频源可能不可用',
          lastError: '播放失败（内核报错）',
          lastAt: t0,
          now: t0.add(const Duration(milliseconds: 10)),
        ),
        isTrue,
        reason: '错误**内容变了**说明情况变了，必须让用户看到。\n'
            '若这条红 → 真错误被静默吞掉，用户只会看到旧提示。',
      );
    });

    test('首次错误立即上报', () {
      expect(
        shouldReportError(
          incoming: '任意错误',
          lastError: null,
          lastAt: null,
          now: t0,
        ),
        isTrue,
      );
    });

    test('边界：恰好等于冷却时间 → 放行', () {
      expect(
        shouldReportError(
          incoming: 'e',
          lastError: 'e',
          lastAt: t0,
          now: t0.add(const Duration(seconds: 3)),
        ),
        isTrue,
        reason: '判据是 `difference < cooldown`（严格小于）；\n'
            '恰好等于视为已过冷却期 —— 与页面实现一致。',
      );
    });

    test('★ 真机规模模拟：48 秒 1024 次 → 应降到个位数', () {
      const err = '播放失败（内核报错）';
      // 21.3 次/秒 × 48 秒 ≈ 1022 次
      var lastAt = t0;
      var reported = 1;
      const total = 1022;
      for (var i = 1; i <= total; i++) {
        // 每次间隔约 47ms
        final now = t0.add(Duration(milliseconds: (47000 * i / total).round()));
        if (shouldReportError(
          incoming: err,
          lastError: err,
          lastAt: lastAt,
          now: now,
        )) {
          reported++;
          lastAt = now;
        }
      }
      expect(reported, lessThan(20),
          reason: '真机 1024 次错误经限流后应降到 20 次以下'
              '（48 秒 / 3 秒冷却 ≈ 16 次）。实际 $reported 次。\n'
              '若这条红 → 限流没生效，UI 仍会被淹没。');
    });
  });
}
