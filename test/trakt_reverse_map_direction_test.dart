// ══════════════════════════════════════════════════════════════════════
//  守卫测试：`seedReverseMap` 的**方向**必须是 `seriesId → tmdbId`
// ══════════════════════════════════════════════════════════════════════
//
// ## 用户报障（2026-10-15）
// > "光阴之外和仙逆未同步"
//
// ## 真机证据（**决定性**）
// ```
// 19:42:22  [Trakt] 反向映射已预热: 5713 条（seriesId → tmdb）  ← 条数**完全正常**
// 19:45:18  [TraktTrack] 反向映射**未预热** ⇒ 本次跳过          ← 其实"查不到"
// ```
// ⚠️ **条数是 5713（正确）** ⇒ 只看"预热成功没"**永远发现不了**这个 bug。
//
// ## 真根因：**方向反转了两次**（抵消）
// ```dart
// // providers.dart:289（调用方）—— rev 已经是 seriesId → tmdb
// rev[e.value.seriesId] = e.key;
// TraktEpisodeResolver.seedReverseMap(rev);
//
// // trakt_client.dart:825（旧实现）—— **又反转一次**
// static void seedReverseMap(Map<String, String> tmdbToSeriesId) {
//   for (final e in tmdbToSeriesId.entries) {
//     out[e.value] = e.key;      // ← ★ 转两次 = 回到 tmdb → series
//   }
// }
// ```
// ⇒ `tmdbIdForSeries(seriesId)` **永远查不到** ⇒ 播放时实时追踪**静默跳过**
// ⇒ Emby 里永远"已看 0 集" ⇒ 同步时"没有可推的记录"。
//
// ⚠️ 成因是**参数名与实际语义相反**（`tmdbToSeriesId` vs 实传 series→tmdb）
//    ⇒ 两边各自"纠正"一次 ⇒ 抵消。现在参数名改为 `seriesToTmdb`。
//
// ## 为什么必须测
// 这个 bug **不报错、analyze 全绿、既有测试全绿**，
// 唯一症状是"功能静默不工作"（且日志条数看起来对）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/data/trakt_client.dart';

void main() {
  group('★★★ 反向映射的方向必须正确（转两次 = 抵消的真 bug）', () {
    test('★★★ `seedReverseMap` 收 `seriesId → tmdbId`，`tmdbIdForSeries` 能查到',
        () {
      // 调用方（providers.dart）传的就是这个方向
      TraktEpisodeResolver.seedReverseMap({
        'emby-series-123': '223911',
        'emby-series-456': '1399',
      });
      // 喂进去的方向 = 取出来的方向
      expect(TraktEpisodeResolver.tmdbIdForSeries('emby-series-123'), '223911',
          reason: '★★★ 旧实现**又反转一次** ⇒ 这里会得到 null：\n'
              '    · 喂 `{seriesId: tmdbId}` ⇒ 内部存成 `{tmdbId: seriesId}`\n'
              '    · 再用 seriesId 去查 ⇒ **必然查不到**\n'
              '    ⇒ 播放时 `[TraktTrack] 反向映射未预热 ⇒ 本次跳过`\n'
              '    ⇒ 实时追踪静默失效 ⇒ Emby 永远"已看 0 集"');
      expect(TraktEpisodeResolver.tmdbIdForSeries('emby-series-456'), '1399');
    });

    test('★★★ 反方向**不该**能查到（确认没有"两边都能查"的假通过）', () {
      TraktEpisodeResolver.seedReverseMap({'sid-1': 'tmdb-9'});
      // 若实现反转了，用 tmdbId 当 key 反而能查到 —— 那正是 bug 的形态
      expect(TraktEpisodeResolver.tmdbIdForSeries('tmdb-9'), isNull,
          reason: '★★★ 用 tmdbId 去查**必须**返回 null：\n'
              '    若它返回了值，说明缓存被存成了 `tmdbId → seriesId`\n'
              '    （即"转两次"的 bug 仍在）');
    });

    test('★★★ 日志里的条数**不能**作为"方向正确"的证据', () {
      // 这个测试本身是"元测试"：提醒后人别用条数判断
      TraktEpisodeResolver.seedReverseMap({
        'a': '1', 'b': '2', 'c': '3',
      });
      // 条数对（3 条）不等于方向对
      expect(TraktEpisodeResolver.tmdbIdForSeries('a'), '1',
          reason: '★ 5713 条那次日志**完全正常**，但方向是反的\n'
              '    ⇒ 断言必须落在**取值**上，不是"有没有预热"');
    });

    test('★★ 空输入不应污染缓存（也不该抛）', () {
      TraktEpisodeResolver.seedReverseMap(const {});
      expect(TraktEpisodeResolver.tmdbIdForSeries('whatever'), isNull);
      // 空 key/value 应被过滤
      TraktEpisodeResolver.seedReverseMap({'': 'x', 'y': ''});
      expect(TraktEpisodeResolver.tmdbIdForSeries('y'), isNull,
          reason: '★ 空值项要被滤掉（原实现已有此过滤，保留）');
    });

    test('★★ 空 seriesId 查询返回 null（不抛）', () {
      TraktEpisodeResolver.seedReverseMap({'sid': '9'});
      expect(TraktEpisodeResolver.tmdbIdForSeries(''), isNull);
      expect(TraktEpisodeResolver.tmdbIdForSeries('   '), isNull);
    });
  });
}
