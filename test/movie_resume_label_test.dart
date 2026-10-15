// ══════════════════════════════════════════════════════════════════════
//  ★★★ 「电影看了 1 分钟却显示立即播放」的**守卫测试**
// ══════════════════════════════════════════════════════════════════════
//
// ## 缺陷回顾（2026-10-15 用户报障）
// > "在 cineflow 中电影我看了 1 分钟，但是显示的是**立即播放**"
//
// ## 因果链（本次测试逐环锁死）
// ```
// ① 详情请求缺 `Fields=UserData`           ← 根因在这一环
// ② models.dart  final ud = j['UserData']  ⇒ null
// ③ playedPercentage / positionTicks       ⇒ 全 null
// ④ progress getter                        ⇒ 0
// ⑤ resume = progress > 0 && !played       ⇒ false
// ⑥ 按钮文案                                ⇒ 永远「立即播放」
// ```
//
// ## 为什么必须测（只加一个 Fields 字串，很容易被人"顺手删掉"）
// · 漏了它**不报错**、**不崩溃** —— 只是电影的续播文案**永远不出现**
// · 剧集不受影响（它走 `getEpisodes`，那个 Fields 本来就带 UserData）
//   ⇒ 只看剧集的话**测不出这个 bug**
// ⇒ 必须有测试直接断言"详情端点请求了 UserData"。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/data/models.dart';

/// 读源码（结构断言用）。测试工作目录是工程根。
Future<String> _src(String rel) => File(rel).readAsString();

/// **剥掉注释**后的源码。
///
/// ## ⚠️ 为什么必须剥（本文件正好踩过这个坑 —— §8.4 第 1 类假象）
/// 我第一版的断言是：
/// ```dart
/// final seg = s.substring(i, i + 1600);
/// expect(seg.contains("'UserData'"), isTrue);   // ❌ 被**注释**满足了
/// ```
/// 而 `_detailFields` 上面有我写的**大段说明注释**（里面反复出现
/// `UserData` 这个词）⇒ 反向注入（删掉真代码里的 `'UserData'`）
/// 后测试**仍然绿** ⇒ 断言是假的。
///
/// 实测证据（反向注入脚本输出）：
/// ```
/// ② 注入：从 _detailFields 删掉 UserData ⇒ 必须变红
///    ❌ 仍绿 ⇒ **测试是假的**（断言没落到真代码上）
/// ```
/// ⇒ 本仓库 §8.4 明令：**断言前先剥注释**。
String _stripComments(String src) {
  // 去 /* */ 块注释
  var s = src.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  // 去 // 行注释（保留字符串里的 // 会误伤，但对本文件的断言足够）
  s = s.replaceAll(RegExp(r'//[^\n]*'), '');
  return s;
}

void main() {
  group('★★★ 详情端点必须请求 UserData（电影续播的**唯一**数据源）', () {
    test('★★★ `_detailFields` 必须包含 UserData', () async {
      final s = _stripComments(await _src('lib/data/emby_provider.dart'));
      // ⚠️ 剥注释后再取窗口 —— 否则会被我写的说明注释满足（见 _stripComments）
      final i = s.indexOf('_detailFields =');
      expect(i, greaterThan(0));
      final seg = s.substring(i, (i + 900).clamp(0, s.length));
      // 精确断言**字面量**（带引号），而不是裸词
      expect(seg.contains("'UserData'"), isTrue,
          reason: '★★★ 缺它会**静默**导致：\n'
              '    · 电影的「继续播放 x%」永远不出现（用户报障）\n'
              '    · 剧集却正常（它走 getEpisodes，那个 Fields 带 UserData）\n'
              '    ⇒ 只看剧集**测不出来** ⇒ 必须显式断言');
    });

    test('★★★ 剧集的 Fields **也**必须带 UserData（分集列表要显示已看）', () async {
      final s = _stripComments(await _src('lib/data/emby_provider.dart'));
      final i = s.indexOf('Future<List<MediaItem>> getEpisodes(');
      expect(i, greaterThan(0));
      final seg = s.substring(i, (i + 700).clamp(0, s.length));
      expect(seg.contains('UserData'), isTrue,
          reason: '★ 分集列表的「已看」标记与 Trakt 同步都依赖它');
    });
  });

  group('★★★ progress 的取值链（模拟"看了 1 分钟"）', () {
    test('★★★ 有 PlayedPercentage ⇒ progress > 0（按钮应变「继续播放」）', () {
      final it = MediaItem.fromJson({
        'Id': 'm1',
        'Name': '某电影',
        'Type': 'Movie',
        'RunTimeTicks': 72000000000,        // 2 小时（1 tick = 100ns）
        'UserData': {
          'Played': false,
          'PlayedPercentage': 0.83,         // 看了 1 分钟 ≈ 0.83%
          'PositionTicks': 600000000,       // 60 秒
        },
      });
      expect(it.played, isFalse);
      expect(it.playedPercentage, closeTo(0.83, 0.01));
      expect(it.progress, greaterThan(0),
          reason: '★★★ progress > 0 且 !played ⇒ 详情页显示「继续播放 x%」');
    });

    test('★★★ 缺 UserData（旧 bug 的形态）⇒ progress == 0（显示「立即播放」）',
        () {
      // ⚠️ 这就是修复前的响应形态：请求没带 Fields=UserData
      final it = MediaItem.fromJson({
        'Id': 'm1',
        'Name': '某电影',
        'Type': 'Movie',
        'RunTimeTicks': 72000000000,
        // 没有 UserData
      });
      expect(it.progress, 0,
          reason: '★★★ 这条测试**复现**了用户报障的根因：\n'
              '    没有 UserData ⇒ progress 恒 0 ⇒ 永远「立即播放」');
      expect(it.played, isFalse);
    });

    test('★★ 只有 PositionTicks + RunTimeTicks（无百分比）⇒ 也能算进度',
        () {
      final it = MediaItem.fromJson({
        'Id': 'm1',
        'Name': '某电影',
        'Type': 'Movie',
        'RunTimeTicks': 36000000000,      // 1 小时
        'UserData': {
          'Played': false,
          'PositionTicks': 1800000000,    // 3 分钟 ⇒ 5%
        },
      });
      expect(it.progress, closeTo(0.05, 0.001),
          reason: '★ 兜底分支：PlayedPercentage 缺失时用 位置/时长 推算');
    });

    test('★★ 已看完（Played=true）⇒ 按钮显示「立即播放」而非续播', () {
      final it = MediaItem.fromJson({
        'Id': 'm1', 'Name': '某电影', 'Type': 'Movie',
        'UserData': {'Played': true, 'PlayedPercentage': 100},
      });
      // ⚠️ 判定是 `progress > 0 && **!played**` ⇒ 已看完不该显示续播
      expect(it.played, isTrue,
          reason: '★ detail_page 的 resume 判据含 `!item.played`');
    });
  });

  group('★ 结构性守卫：判据本身不能被改错', () {
    test('★ 详情页的续播判据必须是 `progress > 0 && !played`', () async {
      final s = await _src('lib/pages/detail_page.dart');
      expect(s.contains('item.progress > 0 && !item.played'), isTrue,
          reason: '★ 这是电影的判据（剧集走 `_seriesResumeLabel`）:\n'
              '    · 只写 `progress > 0` ⇒ 已看完的还显示「继续播放 100%」\n'
              '    · 只写 `!played` ⇒ 没看过的也显示续播');
    });
  });
}
