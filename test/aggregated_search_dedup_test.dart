// 跨服务器聚合去重（多账号聚合的核心正确性）。
//
// ## 为什么必须有这组测试
// "聚合"的价值全在**去重准确**：
// · 去重不足 ⇒ 用户看到同一部片重复 N 次（体验差）
// · 去重过度 ⇒ 用户**看不到某部片**（更严重，且不报错）
// 两者都不会崩溃，只会让界面难以理解 ⇒ 只能靠断言守。
//
// ## 实测依据（2026-10-11，两台真实 Emby）
// · 内容重叠 **26.7%**（578/2163 部剧两台都有）⇒ 必须去重
// · ProviderIds 填充率：Tmdb 87–100% / Imdb 75–95% / Tvdb 67–76%
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/data/aggregated_search.dart';
import 'package:cineflow/data/media_provider.dart';
import 'package:cineflow/data/models.dart';

/// 造一个 MediaItem（只填测试关心的字段）。
MediaItem item(
  String name, {
  String id = 'x',
  String type = 'Movie',
  int? year,
  Map<String, String> providerIds = const {},
}) =>
    MediaItem(
      id: id,
      name: name,
      type: type,
      productionYear: year,
      providerIds: providerIds,
    );

void main() {
  group('★★★ 外部 ID 是去重主键（标题匹配无效的真实场景）', () {
    test('★★★ 中英文名不同但 imdb 相同 ⇒ 必须识别为同一部', () {
      // 实测真实场景：两台服务器同一部剧的中英文名完全不同
      final a = item('Re：从零开始的异世界生活',
          id: '1', type: 'Series', providerIds: {'tmdb': '65943'});
      final b = item('Re:ZERO -Starting Life in Another World-',
          id: '9', type: 'Series', providerIds: {'tmdb': '65943'});
      final ka = crossServerIdentityKeys(a);
      final kb = crossServerIdentityKeys(b);
      expect(ka.any(kb.contains), isTrue,
          reason: '★★★ 标题完全不同（中文名 vs 英文名），但 tmdb 相同\n'
              '    ⇒ 必须能识别为同一部（这是外部 ID 的唯一价值）');
    });

    test('★★★ 返回**全部**可用外部 ID（多键任一命中）', () {
      final it = item('某片', providerIds: {
        'imdb': 'tt4205768',
        'tmdb': '477063',
        'tvdb': '292550',
      });
      final keys = crossServerIdentityKeys(it);
      expect(keys, contains('imdb:tt4205768'));
      expect(keys, contains('tmdb:477063'));
      expect(keys, contains('tvdb:292550'));
      expect(keys.length, greaterThanOrEqualTo(4),
          reason: '★★ 三外部 ID + 标题兜底 = 至少 4 个键\n'
              '    （多键策略：避免"某台只有 tmdb、另一台只有 imdb"匹配失败）');
    });

    test('★★ 只有一边有外部 ID ⇒ 靠标题兜底仍能命中', () {
      final a = item('复仇者联盟', id: '1', year: 2012,
          providerIds: {'imdb': 'tt0848228'});
      final b = item('复仇者联盟', id: '2', year: 2012); // 无外部 ID
      final ka = crossServerIdentityKeys(a);
      final kb = crossServerIdentityKeys(b);
      expect(ka.any(kb.contains), isTrue,
          reason: '★★ 实测约 0–25% 条目没有外部 ID ⇒ 必须有标题兜底');
    });

    test('★★★ 同名但 type 不同**不得**合并', () {
      // 《切尔诺贝利》既有电影也有剧集
      final movie = item('切尔诺贝利', type: 'Movie', year: 2019);
      final series = item('切尔诺贝利', type: 'Series', year: 2019);
      final ka = crossServerIdentityKeys(movie);
      final kb = crossServerIdentityKeys(series);
      expect(ka.any(kb.contains), isFalse,
          reason: '★★★ 标题兜底必须**带 type** —— 否则同名电影/剧集被错合并');
    });

    test('★★ 年份不同不合并（同名不同版）', () {
      final a = item('沙丘', year: 1984);
      final b = item('沙丘', year: 2021);
      expect(crossServerIdentityKeys(a).any(
          crossServerIdentityKeys(b).contains), isFalse);
    });

    test('★ 无任何身份信息 ⇒ 只返回空（宁可重复不误合并）', () {
      final it = item('', providerIds: const {});
      expect(crossServerIdentityKeys(it), isEmpty);
    });
  });

  group('★★★ 跨服务器分组', () {
    test('★★★ 同一部片在两台 ⇒ **一个组、两个副本**', () {
      // 这是"聚合"的核心语义：只出一个槽位，但保留可切换的来源
      final results = [
        ServerSearchResult(
          session: _sess('http://a:8096'),
          hits: [
            AggregatedHit(
                item: item('复仇者联盟', id: '1', year: 2012,
                    providerIds: {'imdb': 'tt0848228'}),
                session: _sess('http://a:8096'),
                api: _api()),
          ],
        ),
        ServerSearchResult(
          session: _sess('http://b:8096'),
          hits: [
            AggregatedHit(
                item: item('复仇者联盟', id: '2', year: 2012,
                    providerIds: {'imdb': 'tt0848228'}),
                session: _sess('http://b:8096'),
                api: _api()),
          ],
        ),
      ];
      final groups = groupAcrossServers(results);
      expect(groups.length, 1,
          reason: '★★★ 同一部片在两台 ⇒ 只该出一个槽位');
      expect(groups.first.copies.length, 2,
          reason: '★★ 但要**保留两个副本**（不贪心丢弃）——\n'
              '    用户可能想选画质更好的那台（plezy 的做法）');
      expect(groups.first.serverCount, 2);
      expect(groups.first.hasMultiple, isTrue);
      expect(groups.first.alternatives.length, 1);
    });

    test('★★★ 主副本 = **第一台**（账号顺序，当前会话在最前）', () {
      final s1 = _sess('http://a:8096');
      final s2 = _sess('http://b:8096');
      final groups = groupAcrossServers([
        ServerSearchResult(session: s1, hits: [
          AggregatedHit(item: item('X', id: '1'), session: s1, api: _api()),
        ]),
        ServerSearchResult(session: s2, hits: [
          AggregatedHit(item: item('X', id: '2'), session: s2, api: _api()),
        ]),
      ]);
      expect(groups.first.primary.session.serverUrl, s1.serverUrl,
          reason: '★★ 主副本取第一个服务器的（用户最可能想用它播放）');
    });

    test('★★ 不同片各自成组', () {
      final s = _sess('http://a:8096');
      final groups = groupAcrossServers([
        ServerSearchResult(session: s, hits: [
          AggregatedHit(item: item('A', id: '1'), session: s, api: _api()),
          AggregatedHit(item: item('B', id: '2'), session: s, api: _api()),
        ]),
      ]);
      expect(groups.length, 2);
    });

    test('★★ 失败源不参与分组（但不影响其他源）', () {
      // ⚠️ `ServerSearchResult.session` 非空（类型约束）⇒
      //    失败源也要带 session，只是 `error != null`、`hits` 为空。
      final bad = _sess('http://down:8096');
      final ok = _sess('http://a:8096');
      final groups = groupAcrossServers([
        ServerSearchResult(session: bad, error: '超时'),
        ServerSearchResult(session: ok, hits: [
          AggregatedHit(item: item('A', id: '1'), session: ok, api: _api()),
        ]),
      ]);
      expect(groups.length, 1,
          reason: '★ 失败源 hits 为空 ⇒ 不影响分组');
    });

    test('★ 空结果 ⇒ 空组（不崩）', () {
      expect(groupAcrossServers(const []), isEmpty);
      expect(
          groupAcrossServers([ServerSearchResult(session: _sess('http://a'))]),
          isEmpty);
    });
  });

  group('★★★ 搜索必须请求 ProviderIds（否则去重失效）', () {
    test('★★★ emby_provider 的搜索请求必须带 Fields=ProviderIds', () {
      // ## 为什么必须有这条守卫（反向注入自查发现）
      // 把 `'ProviderIds'` 从 Fields 里去掉后，**所有测试仍全绿** ——
      // 因为单测用的是自己构造的 `MediaItem`（providerIds 手动填），
      // 走不到真实请求。
      //
      // 但真机上后果严重：Emby **默认不返回** `ProviderIds`
      // ⇒ `MediaItem.providerIds` 恒空 ⇒ 跨服去重只剩"标题+年份"兜底
      // ⇒ 中英文混排的片名匹配不上 ⇒ **跨服去重失效**（用户看到重复）。
      //
      // ## 实测依据（2026-10-11，两台真实 Emby）
      // 带 `Fields=ProviderIds` 时填充率：
      // ```
      // iLoveHD: Tmdb 87% / Tvdb 76% / Imdb 75.5%
      // HK-Emby: Tmdb 100% / Imdb 95% / Tvdb 67%
      // ```
      final src = File('lib/data/emby_provider.dart').readAsStringSync();
      // 剥注释（§8.4：这里的 `ProviderIds` 在注释里也出现，
      // 裸 contains 会被注释满足 ⇒ 假绿）
      final code = src
          .split('\n')
          .where((l) {
            final t = l.trimLeft();
            return !t.startsWith('//') && !t.startsWith('///') &&
                !t.startsWith('*');
          })
          .join('\n');
      expect(code.contains("'ProviderIds',"), isTrue,
          reason: '★★★ Emby **默认不返回** ProviderIds ⇒ 不显式请求\n'
              '    则 `MediaItem.providerIds` 恒空 ⇒ 跨服去重退回标题匹配\n'
              '    ⇒ 实测「海贼王 / 海贼王真人版 / 海贼王(真人版)」\n'
              '       三个不同片名会被当成三部不同的剧');
    });

    test('★★ MediaItem 必须解析 ProviderIds 且 key 归一化小写', () {
      // 实测：**同一台服务器**的数据里同时有 `Imdb` 与 `IMDB`
      // ⇒ 不归一化会漏一部分。
      final src = File('lib/data/models.dart').readAsStringSync();
      final code = src
          .split('\n')
          .where((l) {
            final t = l.trimLeft();
            return !t.startsWith('//') && !t.startsWith('///') &&
                !t.startsWith('*');
          })
          .join('\n');
      expect(code.contains('_parseProviderIds'), isTrue,
          reason: '★★ 必须解析 ProviderIds');
      expect(code.contains('.toLowerCase()'), isTrue,
          reason: '★★ key 必须归一化为小写 —— 实测同台服务器\n'
              '    同时存在 `Imdb` 与 `IMDB`');
    });
  });
}

// ── 测试替身 ──

MediaSession _sess(String url) => MediaSession(
      serverUrl: url,
      accessToken: 't',
      deviceId: 'dev-1',
      user: const MediaUser(id: 'u', name: 'n'),
    );

/// 最小 MediaProvider 替身（分组逻辑不调用它）。
MediaProvider _api() => _FakeApi();

class _FakeApi implements MediaProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('分组测试不应调用 API');
}
