/// 豆瓣数据源 providers（排行榜 / 热门搜索）
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/db_provider.dart';
import '../douban/douban_client.dart';
import '../douban/douban_catalog.dart';
import '../douban/douban_http.dart';
import '../douban/douban_models.dart';

/// 豆瓣客户端。
///
/// 缓存走 drift/SQLite（[DriftDoubanCache]）——**这是修复开放缺陷 §7.4 的落点**：
/// 原先注入的 `MemoryDoubanCache.get` 忽略 ttl（永不过期且不落盘），
/// 于是 README 宣称的"榜单 6h / 详情 24h 缓存"在运行期根本不成立：
/// 重启即失效、且同一进程内数据永不刷新。
///
/// 现在 TTL 在**写入时**固化进 `expires_at` 列，读取时由 SQL 判断过期，
/// 不再存在"调用方忘了传 ttl"或"实现方没理会 ttl"的可能。
final doubanClientProvider = Provider<DoubanClient>((ref) {
  return DoubanClient(
    http: DoubanHttp(baseUrl: DoubanClient.kBase),
    cache: DriftDoubanCache(ref.watch(appDbProvider)),
  );
});

/// 某榜单分类的条目（一次 25 条，页内滚动足够）
final doubanRankingsProvider = FutureProvider.autoDispose
    .family<List<DoubanEntry>, String>((ref, categoryId) async {
  final category = DoubanCatalog.byId(categoryId);
  if (category == null) return const [];
  return ref.read(doubanClientProvider).categoryRankings(category, count: 25);
});

/// 豆瓣站内搜索（搜索页「豆瓣结果」用）
final doubanSearchProvider =
    FutureProvider.autoDispose.family<List<DoubanSearchHit>, String>(
        (ref, query) async {
  final q = query.trim();
  if (q.isEmpty) return const [];
  return ref.read(doubanClientProvider).searchSubjects(q, count: 12);
});

/// 豆瓣完整详情（客户端内 24h 缓存）
final doubanDetailProvider =
    FutureProvider.autoDispose.family<DoubanDetail?, (String, bool)>(
        (ref, ids) async {
  return ref
      .read(doubanClientProvider)
      .subjectDetail(ids.$1, isTv: ids.$2);
});

/// 实时热门电影（搜索页「热门搜索」用）
final doubanHotMoviesProvider =
    FutureProvider.autoDispose<List<DoubanEntry>>((ref) async {
  return ref
      .read(doubanClientProvider)
      .rankings('movie_real_time_hotest', count: 10);
});
