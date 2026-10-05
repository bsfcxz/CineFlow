# -*- coding: utf-8 -*-
"""批次 D：我的页统计四格真实化 + 播放设置组；演职员溢出修复"""
import io

# ---------- 1) getItems 泛化 filters ----------
p = 'lib/data/media_provider.dart'
s = io.open(p, encoding='utf-8').read()
s = s.replace("""    bool recursive = true,
    bool unplayedOnly = false,
    int startIndex = 0,
    int limit = 40,
  });""", """    bool recursive = true,
    bool unplayedOnly = false,
    String? filters, // IsPlayed / IsFavorite / IsUnplayed（逗号分隔可多选）
    int startIndex = 0,
    int limit = 40,
  });""")
io.open(p, 'w', encoding='utf-8', newline='\n').write(s)

p = 'lib/data/emby_provider.dart'
s = io.open(p, encoding='utf-8').read()
s = s.replace("""    bool recursive = true,
    bool unplayedOnly = false,
    int startIndex = 0,
    int limit = 40,
  }) async {""", """    bool recursive = true,
    bool unplayedOnly = false,
    String? filters,
    int startIndex = 0,
    int limit = 40,
  }) async {""")
s = s.replace("""          if (unplayedOnly) 'Filters': 'IsUnplayed',""", """          if (unplayedOnly) 'Filters': 'IsUnplayed',
          'Filters': ?filters,""")
io.open(p, 'w', encoding='utf-8', newline='\n').write(s)

# ---------- 2) 演职员行高修复 ----------
p = 'lib/pages/detail_page.dart'
s = io.open(p, encoding='utf-8').read()
s = s.replace("""  Widget _cast(MediaProvider api, EmbyItemDetail d) {
    final actors = d.people.where((p) => p.type == 'Actor').take(12).toList();
    return SizedBox(
      height: 96,""", """  Widget _cast(MediaProvider api, EmbyItemDetail d) {
    final actors = d.people.where((p) => p.type == 'Actor').take(12).toList();
    return SizedBox(
      height: 110,""")
io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('cast height ok')

# ---------- 3) 我的页：统计四格 + 播放设置组 ----------
p = 'lib/pages/profile_page.dart'
s = io.open(p, encoding='utf-8').read()

s = s.replace("""/// 观看统计（TotalRecordCount 查询，Counts 端点部分服务器不可用）
class _Stats {
  final int movies;
  final int series;
  final int episodes;
  final int favorites;
  const _Stats(this.movies, this.series, this.episodes, this.favorites);
}

final _statsProvider = FutureProvider.autoDispose<_Stats>((ref) async {
  final api = ref.watch(embyApiProvider);
  if (api == null) throw const EmbyException('未登录');
  // 库规模统计（Counts 端点部分服务器不可用，改用 TotalRecordCount）

  final movies = await api.getItems(
      includeTypes: 'Movie', recursive: true, limit: 1);
  final series = await api.getItems(
      includeTypes: 'Series', recursive: true, limit: 1);
  return _Stats(movies.total, series.total, 0, 0);
});""", """/// 观看统计四格（全部 TotalRecordCount 真实查询）
class _Stats {
  final int moviesWatched; // 已看电影
  final int seriesWatching; // 追剧中（未看完的剧集）
  final int episodesWatched; // 已看分集
  final int favorites; // 收藏
  final int moviesTotal; // 库内电影
  final int seriesTotal; // 库内剧集
  const _Stats(this.moviesWatched, this.seriesWatching, this.episodesWatched,
      this.favorites, this.moviesTotal, this.seriesTotal);
}

final _statsProvider = FutureProvider.autoDispose<_Stats>((ref) async {
  final api = ref.watch(embyApiProvider);
  if (api == null) throw const EmbyException('未登录');

  Future<int> total(String includeTypes, {String? filters}) async {
    final page = await api.getItems(
        includeTypes: includeTypes,
        recursive: true,
        limit: 1,
        filters: filters);
    return page.total;
  }

  final results = await Future.wait([
    total('Movie', filters: 'IsPlayed'),
    total('Series', filters: 'IsUnplayed'),
    total('Episode', filters: 'IsPlayed'),
    total('Movie,Series,Episode', filters: 'IsFavorite'),
    total('Movie'),
    total('Series'),
  ]);
  return _Stats(results[0], results[1], results[2], results[3], results[4],
      results[5]);
});""")

# 头卡右侧：保留库规模（电影/剧集），统计四格做成独立行
s = s.replace("""            _headCard(context, ref, session, stats),
            const SizedBox(height: 14),""", """            _headCard(context, ref, session, stats),
            const SizedBox(height: 12),
            _statGrid(stats),
            const SizedBox(height: 14),""")

# 统计四格 widget
s = s.replace("""  Widget _settingsGroup(List<_SettingItem> items) {""", """  Widget _statGrid(AsyncValue<_Stats> stats) {
    return stats.when(
      loading: () => const SizedBox(height: 66),
      error: (_, _) => const SizedBox.shrink(),
      data: (s) => Row(children: [
        _statCard('\${s.moviesWatched}', '已看电影'),
        _statCard('\${s.seriesWatching}', '追剧中'),
        _statCard('\${s.episodesWatched}', '已看分集'),
        _statCard('\${s.favorites}', '收藏'),
      ]),
    );
  }

  Widget _statCard(String value, String label) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.only(right: 10),
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: Cf.surface,
          border: Border.all(color: Cf.border),
        ),
        child: Column(children: [
          Text(value,
              style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                  color: Cf.accent)),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(fontSize: 9, color: Cf.text3)),
        ]),
      ),
    );
  }

  Widget _settingsGroup(List<_SettingItem> items) {""")
io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('profile stats ok')
