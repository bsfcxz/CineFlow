// ══════════════════════════════════════════════════════════════════════
//  Trakt「同步已看」的**安全约束**测试（最重要的一组）
// ══════════════════════════════════════════════════════════════════════
//
// ## 为什么这组测试比"功能对不对"更重要
// 本仓库有过**真实事故**（§6.9.1）：我在"取数失败"的状态下执行了删除，
// 删掉了用户 11 部订阅，**不可恢复**。
// 本次的 `TraktWatchedSyncer` 会**写用户的 Emby 观看状态** ⇒
// 必须证明"取数失败时一个写操作都不做"。
//
// ## 测试策略：用**假 sync/client**（不联网）
// 关键断言是"**markPlayed 被调用的次数**"—— 这是可数的硬证据。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/data/trakt_client.dart';
import 'package:cineflow/data/trakt_watched.dart';

// ══════════════════════════════════════════════════════════════════
//  测试替身
// ══════════════════════════════════════════════════════════════════

/// 假的 `TraktSync`：只覆写本测试用到的两个方法。
///
/// ⚠️ **不能用 mockito**：本仓库没有该依赖，且"手写替身"能让
///    "调用了什么"一目了然（测试本身也是文档）。
class _FakeSync implements TraktSync {
  _FakeSync({this.watched, this.throwOnGet = false});

  /// `getWatchedShows` 的返回值（`traktShowId → {'S1E1', ...}`）。
  final Map<int, Set<String>>? watched;

  /// 模拟**网络失败**（用于验证"失败时绝不写"）。
  final bool throwOnGet;

  @override
  Future<Map<int, Set<String>>> getWatchedShows() async {
    if (throwOnGet) throw Exception('模拟网络失败');
    return watched ?? const {};
  }

  /// ⚠️ **加 `TraktSync` 的新方法时必须同步补这里**
  ///（`_FakeDio` / `_FakeStore` / `_FakeSync` 都踩过同一坑 —— 第 N 次了）。
  ///
  /// ## 这里的语义（让旧测试仍然有效）
  /// `pull()` 现在**优先查 history**。本替身让 history 返回
  /// **watched 里这部剧的集合** ⇒ 旧测试（只设 `watched`）测的仍是同一件事，
  /// 且能顺带验证"history 命中就不查 watched"。
  @override
  Future<Set<String>?> getShowHistory(int traktShowId) async {
    if (throwOnGet) throw Exception('模拟网络失败');
    return (watched ?? const {})[traktShowId];
  }

  // ---- 以下都是接口要求但本测试不用 ----
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('测试替身未实现: ${i.memberName}');
}

/// 假的 `TraktClient`：`findByTmdb` 返回预设值。
class _FakeClient implements TraktClient {
  _FakeClient({this.show});

  /// `findByTmdb` 的返回值（null = Trakt 上没这部剧 / 错配被拦下）。
  final TraktShow? show;

  @override
  Future<TraktShow?> findByTmdb(String tmdbId,
          {String? expectCnTitle, int? expectYear}) async =>
      show;

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('测试替身未实现: ${i.memberName}');
}

TraktShow _show(int traktId) => TraktShow(traktId: traktId, title: 'X');

void main() {
  group('★★★ 安全约束：取数失败时**绝不写用户数据**（§6.9.1 的教训）', () {
    test('★★★ Trakt 取数抛异常 ⇒ markPlayed **一次都不能调**', () async {
      var calls = 0;
      final r = await TraktWatchedSyncer(
        client: _FakeClient(show: _show(1)),
        sync: _FakeSync(throwOnGet: true),
      ).pull(
        tmdbShowId: '555',
        episodes: const [
          TraktEpisodeRef(itemId: 'e1', season: 1, number: 1, played: false),
          TraktEpisodeRef(itemId: 'e2', season: 1, number: 2, played: false),
        ],
        markPlayed: (_) async {
          calls++;
          return true;
        },
      );
      expect(calls, 0,
          reason: '★★★ 这是本仓库最贵的一课（§6.9.1 删掉用户 11 部订阅）：\n'
              '    "取数失败" ≠ "数据为空"。\n'
              '    拿不到 Trakt 数据时，一个写操作都不许做。');
      expect(r.failed, isTrue);
      expect(r.fetched, isFalse);
      expect(r.markedNew, 0);
    });

    test('★★ Trakt 上没有这部剧 ⇒ 也不写', () async {
      var calls = 0;
      final r = await TraktWatchedSyncer(
        client: _FakeClient(show: null),      // 没这部剧
        sync: _FakeSync(watched: {1: {'S1E1'}}),
      ).pull(
        tmdbShowId: '555',
        episodes: const [
          TraktEpisodeRef(itemId: 'e1', season: 1, number: 1, played: false),
        ],
        markPlayed: (_) async {
          calls++;
          return true;
        },
      );
      expect(calls, 0);
      expect(r.fetched, isTrue, reason: '取数成功，只是没有这部剧');
      expect(r.note, isNotNull);
    });

    test('★★ 本剧在 Trakt 上没有已看记录 ⇒ 不写', () async {
      var calls = 0;
      final r = await TraktWatchedSyncer(
        client: _FakeClient(show: _show(99)),
        sync: _FakeSync(watched: const {}),   // 全空
      ).pull(
        tmdbShowId: '555',
        episodes: const [
          TraktEpisodeRef(itemId: 'e1', season: 1, number: 1, played: false),
        ],
        markPlayed: (_) async {
          calls++;
          return true;
        },
      );
      expect(calls, 0);
      expect(r.fetched, isTrue);
    });
  });

  group('★★★ 只做加法：绝不把已看改成未看', () {
    test('★★★ 本地已看、Trakt 没看 ⇒ **不动**（不取消已看）', () async {
      var calls = 0;
      final r = await TraktWatchedSyncer(
        client: _FakeClient(show: _show(1)),
        // Trakt 只有 S1E2；本地 E1 已看
        sync: _FakeSync(watched: {1: {'S1E2'}}),
      ).pull(
        tmdbShowId: '555',
        episodes: const [
          // 本地已看，但 Trakt 没有 ⇒ 必须**保持已看**（不调用任何写）
          TraktEpisodeRef(itemId: 'e1', season: 1, number: 1, played: true),
          // 本地未看，Trakt 有 ⇒ 补标
          TraktEpisodeRef(itemId: 'e2', season: 1, number: 2, played: false),
        ],
        markPlayed: (_) async {
          calls++;
          return true;
        },
      );
      expect(calls, 1, reason: '★★★ 只补 S1E2；E1 必须原样保留已看状态');
      expect(r.markedNew, 1);
      expect(r.alreadyWatched, 0);
    });

    test('★★ 两边都已看 ⇒ 不做冗余写（避免无谓的服务器请求）', () async {
      var calls = 0;
      final r = await TraktWatchedSyncer(
        client: _FakeClient(show: _show(1)),
        sync: _FakeSync(watched: {1: {'S1E1', 'S1E2'}}),
      ).pull(
        tmdbShowId: '555',
        episodes: const [
          TraktEpisodeRef(itemId: 'e1', season: 1, number: 1, played: true),
          TraktEpisodeRef(itemId: 'e2', season: 1, number: 2, played: true),
        ],
        markPlayed: (_) async {
          calls++;
          return true;
        },
      );
      expect(calls, 0);
      expect(r.markedNew, 0);
      expect(r.alreadyWatched, 2);
    });
  });

  group('★★ 跨季匹配（S{n}E{m} 的格式必须与服务端一致）', () {
    test('★★★ 第 2 季第 10 集不能被第 1 季的 S1E10 误匹配', () async {
      final marked = <String>[];
      await TraktWatchedSyncer(
        client: _FakeClient(show: _show(1)),
        // Trakt 上只有 S1E10
        sync: _FakeSync(watched: {1: {'S1E10'}}),
      ).pull(
        tmdbShowId: '555',
        episodes: const [
          // 本地这条是 **S2E10**，不该被 S1E10 命中
          TraktEpisodeRef(itemId: 'ep-s2e10', season: 2, number: 10,
              played: false),
        ],
        markPlayed: (id) async {
          marked.add(id);
          return true;
        },
      );
      expect(marked, isEmpty,
          reason: '★★★ 季号必须参与匹配 —— 否则会把"第2季第10集"'
              '当成"第1季第10集"标记，**标错集**比不标更糟');
    });

    test('★ 多季混合：只标命中的那些', () async {
      final marked = <String>[];
      await TraktWatchedSyncer(
        client: _FakeClient(show: _show(1)),
        sync: _FakeSync(watched: {1: {'S1E1', 'S2E3'}}),
      ).pull(
        tmdbShowId: '555',
        episodes: const [
          TraktEpisodeRef(itemId: 'a', season: 1, number: 1, played: false),
          TraktEpisodeRef(itemId: 'b', season: 1, number: 2, played: false),
          TraktEpisodeRef(itemId: 'c', season: 2, number: 3, played: false),
        ],
        markPlayed: (id) async {
          marked.add(id);
          return true;
        },
      );
      expect(marked, ['a', 'c']);
    });
  });

  group('★ 鲁棒性：单集失败不中断整批', () {
    test('★ 中间一集抛异常 ⇒ 后面的仍继续（且计数如实）', () async {
      final marked = <String>[];
      final r = await TraktWatchedSyncer(
        client: _FakeClient(show: _show(1)),
        sync: _FakeSync(watched: {1: {'S1E1', 'S1E2', 'S1E3'}}),
      ).pull(
        tmdbShowId: '555',
        episodes: const [
          TraktEpisodeRef(itemId: 'e1', season: 1, number: 1, played: false),
          TraktEpisodeRef(itemId: 'e2', season: 1, number: 2, played: false),
          TraktEpisodeRef(itemId: 'e3', season: 1, number: 3, played: false),
        ],
        markPlayed: (id) async {
          if (id == 'e2') throw Exception('服务端 500');
          marked.add(id);
          return true;
        },
      );
      expect(marked, ['e1', 'e3'],
          reason: '★ 一集失败不该让整批停止（新集可能服务端暂时不接受）');
      expect(r.markedNew, 2, reason: '★ 计数必须如实（不能把失败算成成功）');
    });

    test('★ markPlayed 返回 false ⇒ 不计入 markedNew', () async {
      final r = await TraktWatchedSyncer(
        client: _FakeClient(show: _show(1)),
        sync: _FakeSync(watched: {1: {'S1E1'}}),
      ).pull(
        tmdbShowId: '555',
        episodes: const [
          TraktEpisodeRef(itemId: 'e1', season: 1, number: 1, played: false),
        ],
        markPlayed: (_) async => false,     // 服务端拒绝
      );
      expect(r.markedNew, 0,
          reason: '★ 服务端拒绝时不能谎报"已同步 N 集"');
    });
  });

  group('★ 输入校验（防呆，不是错误处理）', () {
    test('★ 没有 tmdb id ⇒ 直接返回，不请求 Trakt', () async {
      var calls = 0;
      final r = await TraktWatchedSyncer(
        client: _FakeClient(show: _show(1)),
        sync: _FakeSync(watched: {1: {'S1E1'}}),
      ).pull(
        tmdbShowId: '',                    // 空
        episodes: const [
          TraktEpisodeRef(itemId: 'e1', season: 1, number: 1, played: false),
        ],
        markPlayed: (_) async {
          calls++;
          return true;
        },
      );
      expect(calls, 0);
      expect(r.fetched, isFalse);
      expect(r.note, isNotNull);
    });

    test('★ 没有分集 ⇒ 直接返回', () async {
      final r = await TraktWatchedSyncer(
        client: _FakeClient(show: _show(1)),
        sync: _FakeSync(watched: {1: {'S1E1'}}),
      ).pull(
        tmdbShowId: '555',
        episodes: const [],
        markPlayed: (_) async => true,
      );
      expect(r.fetched, isFalse);
    });
  });

  group('★★★ history 优先 / watched 回退（2026-10-15 用户报障的根因）', () {
    test('★★★ history 有数据 ⇒ **不查 watched**（省一次请求）', () async {
      final sync = _FakeSync2(history: {'S1E6', 'S1E162'});
      final r = await TraktWatchedSyncer(
        client: _FakeClient2(show: _show2(203833)),
        sync: sync,
      ).pull(
        tmdbShowId: '223911',
        episodes: const [
          TraktEpisodeRef(itemId: 'e6', season: 1, number: 6, played: false),
          TraktEpisodeRef(itemId: 'e162', season: 1, number: 162,
              played: false),
        ],
        markPlayed: (_) async => true,
      );
      expect(r.markedNew, 2, reason: '★★ 两集都该被补标');
      expect(sync.watchedCalls, 0,
          reason: '★★★ history 已命中 ⇒ **不该**再查 watched（白费一次请求）');
      expect(sync.historyCalls, 1);
    });

    test('★★★ history 为空 ⇒ **回退查 watched**', () async {
      final sync = _FakeSync2(history: {}, watched: {203833: {'S1E6'}});
      final r = await TraktWatchedSyncer(
        client: _FakeClient2(show: _show2(203833)),
        sync: sync,
      ).pull(
        tmdbShowId: '223911',
        episodes: const [
          TraktEpisodeRef(itemId: 'e6', season: 1, number: 6, played: false),
        ],
        markPlayed: (_) async => true,
      );
      expect(sync.historyCalls, 1);
      expect(sync.watchedCalls, 1, reason: '★ history 空 ⇒ 应回退到 watched');
      expect(r.markedNew, 1);
    });

    test('★★★ history 与 watched **都失败** ⇒ failed=true（不写任何数据）',
        () async {
      // ⚠️ 这是 §6.9.1 的硬要求：取数失败 ⇒ 一个写操作都不做
      var writes = 0;
      final sync = _FakeSync2(history: null, watchedThrow: true);
      final r = await TraktWatchedSyncer(
        client: _FakeClient2(show: _show2(203833)),
        sync: sync,
      ).pull(
        tmdbShowId: '223911',
        episodes: const [
          TraktEpisodeRef(itemId: 'e6', season: 1, number: 6, played: false),
        ],
        markPlayed: (_) async {
          writes++;
          return true;
        },
      );
      expect(writes, 0,
          reason: '★★★ "取数失败" ≠ "数据为空"：\n'
              '    拿不到 Trakt 数据时**一个写操作都不许做**（§6.9.1 的真实事故）');
      expect(r.failed, isTrue);
      expect(r.fetched, isFalse);
    });

    test('★★ history 失败但 watched 成功 ⇒ 用 watched 的数据（不算失败）',
        () async {
      final sync = _FakeSync2(history: null, watched: {203833: {'S1E6'}});
      final r = await TraktWatchedSyncer(
        client: _FakeClient2(show: _show2(203833)),
        sync: sync,
      ).pull(
        tmdbShowId: '223911',
        episodes: const [
          TraktEpisodeRef(itemId: 'e6', season: 1, number: 6, played: false),
        ],
        markPlayed: (_) async => true,
      );
      expect(r.fetched, isTrue, reason: '★ 有一段成功就算取到了数据');
      expect(r.markedNew, 1);
    });

    test('★★★ history 需要 trakt show id（取不到 ⇒ 如实返回，不发请求）',
        () async {
      final sync = _FakeSync2(history: {'S1E6'});
      final r = await TraktWatchedSyncer(
        client: _FakeClient2(show: null),   // findByTmdb 返回 null
        sync: sync,
      ).pull(
        tmdbShowId: '223911',
        episodes: const [
          TraktEpisodeRef(itemId: 'e6', season: 1, number: 6, played: false),
        ],
        markPlayed: (_) async => true,
      );
      expect(sync.historyCalls, 0,
          reason: '★ 没有 trakt id 就不该发 history 请求');
      expect(r.fetched, isTrue);
      expect(r.note, isNotNull);
    });
  });
}

/// 假 sync：可精确控制 history / watched 的返回。
class _FakeSync2 implements TraktSync {
  _FakeSync2({this.history, this.watched, this.watchedThrow = false});

  /// `getShowHistory` 的返回值：null = 失败；空集 = 有响应但无记录。
  final Set<String>? history;

  /// `getWatchedShows` 的返回值。
  final Map<int, Set<String>>? watched;

  /// true = `getWatchedShows` 抛异常。
  final bool watchedThrow;

  int historyCalls = 0;
  int watchedCalls = 0;

  @override
  Future<Set<String>?> getShowHistory(int traktShowId) async {
    historyCalls++;
    return history;
  }

  @override
  Future<Map<int, Set<String>>> getWatchedShows() async {
    watchedCalls++;
    if (watchedThrow) throw Exception('模拟网络失败');
    return watched ?? const {};
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('替身未实现: ${i.memberName}');
}

/// 假 client：`findByTmdb` 返回预设值。
class _FakeClient2 implements TraktClient {
  _FakeClient2({this.show});
  final TraktShow? show;

  @override
  Future<TraktShow?> findByTmdb(String tmdbId,
          {String? expectCnTitle, int? expectYear}) async =>
      show;

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('替身未实现: ${i.memberName}');
}

TraktShow _show2(int traktId) => TraktShow(traktId: traktId, title: 'X');
