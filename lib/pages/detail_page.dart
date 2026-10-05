/// 详情页 —— 沉浸式全屏：背景图 + 悬浮海报 + 元信息
/// 剧集模式（季选择器 + 分集列表）/ 电影模式（媒体流信息 + 多版本切换）
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/router.dart';
import '../core/theme.dart';
import '../data/emby_provider.dart';
import '../data/media_provider.dart';
import '../data/models.dart';
import '../player/player_routes.dart';
import '../state/providers.dart';
import '../widgets/media_cards.dart';

final detailProvider = FutureProvider.autoDispose
    .family<MediaItemDetail, String>((ref, itemId) async {
  final api = ref.watch(embyApiProvider);
  if (api == null) throw const MediaException('未登录');
  return api.getItemDetail(itemId);
});

final seasonsProvider =
    FutureProvider.autoDispose.family<List<MediaItem>, String>(
        (ref, seriesId) async {
  final api = ref.watch(embyApiProvider);
  if (api == null) throw const MediaException('未登录');
  return api.getSeasons(seriesId);
});

final episodesProvider = FutureProvider.autoDispose
    .family<List<MediaItem>, (String, String)>((ref, ids) async {
  final api = ref.watch(embyApiProvider);
  if (api == null) throw const MediaException('未登录');
  return api.getEpisodes(ids.$1, ids.$2);
});

final similarProvider =
    FutureProvider.autoDispose.family<List<MediaItem>, String>(
        (ref, itemId) async {
  final api = ref.watch(embyApiProvider);
  if (api == null) throw const MediaException('未登录');
  return api.getSimilar(itemId);
});

/// 统一条目跳转：合集 → 库内浏览；剧集分集 → 剧详情；其余 → 详情页
/// 注意：Emby 里 Series/BoxSet 的 IsFolder 都是 true，只有 BoxSet 走文件夹浏览
///
/// 迁移说明（go_router）：**合集浏览仍用 Navigator.push**——
/// 它是"画廊网格 + 标题栏"的本地组合 widget（`_BrowseInDetail`），
/// 不承载独立 URL 语义，硬塞进路由表只会让路由表变脏。
/// 只有真正需要"可由 id 直达"的详情页才走 go_router。
void openMediaItem(BuildContext context, MediaItem item) {
  final isBrowsableFolder =
      item.type == 'BoxSet' || (item.isFolder && item.type != 'Series');
  if (isBrowsableFolder) {
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => Scaffold(
                  backgroundColor: Cf.bg,
                  body: SafeArea(
                    child: Column(children: [
                      Row(children: [
                        BackButton(color: Cf.text),
                        Expanded(
                          child: Text(item.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w800)),
                        ),
                        SizedBox(width: 44),
                      ]),
                      Expanded(
                        child: _BrowseInDetail(parentId: item.id),
                      ),
                    ]),
                  ),
                )));
  } else if (item.type == 'Episode' && item.seriesId != null) {
    // 分集 → 它的剧详情（用 seriesId，不是 episodeId）
    context.push(Routes.detailOf(item.seriesId!));
  } else {
    context.push(Routes.detailOf(item.id));
  }
}

/// 详情页内的合集浏览（复用分页加载逻辑）
class _BrowseInDetail extends ConsumerStatefulWidget {
  const _BrowseInDetail({required this.parentId});
  final String parentId;

  @override
  ConsumerState<_BrowseInDetail> createState() => _BrowseInDetailState();
}

class _BrowseInDetailState extends ConsumerState<_BrowseInDetail> {
  final _items = <MediaItem>[];
  bool _loading = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || _done) return;
    setState(() => _loading = true);
    try {
      final api = ref.read(embyApiProvider)!;
      final page = await api.getItems(
          parentId: widget.parentId,
          includeTypes: 'Movie,Series',
          // 合集内部按名称 A→Z 浏览；显式写出方向，避免依赖服务端默认
          // （实测本服务器 DateCreated+Ascending 会给最旧，见 MediaProvider.getItems 注释）
          sortBy: 'SortName',
          sortOrder: 'Ascending',
          startIndex: _items.length);
      setState(() {
        _items.addAll(page.items);
        _done = _items.length >= page.total || page.items.isEmpty;
      });
    } catch (_) {
      // 静默失败：下滑可重试
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(embyApiProvider)!;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.pixels > n.metrics.maxScrollExtent - 400) {
          Future.microtask(_loadMore); // 避免 build 期间 setState
        }
        return false;
      },
      child: GridView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _items.length + (_done ? 0 : 1),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 2 / 3.45,
        ),
        itemBuilder: (context, i) {
          if (i >= _items.length) {
            return Center(
                child: CircularProgressIndicator(color: Cf.accent));
          }
          return PosterCard(
              item: _items[i],
              api: api,
              onTap: () => openMediaItem(context, _items[i]));
        },
      ),
    );
  }
}

class DetailPage extends ConsumerStatefulWidget {
  const DetailPage({super.key, required this.itemId});
  final String itemId;

  @override
  ConsumerState<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends ConsumerState<DetailPage> {
  String? _selectedSeasonId;
  String? _selectedVersionId;
  String? _syncedItemId;
  bool _fav = false;
  bool _watched = false;
  bool _toggling = false;

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(detailProvider(widget.itemId));
    return Scaffold(
      backgroundColor: Cf.bg,
      body: detail.when(
        loading: () => Center(
            child: CircularProgressIndicator(color: Cf.accent)),
        error: (e, _) => CfErrorView(
          message: e is MediaException ? e.message : '加载失败，请重试',
          onRetry: () => ref.invalidate(detailProvider(widget.itemId)),
        ),
        data: (d) => _buildBody(d),
      ),
    );
  }

  Widget _buildBody(MediaItemDetail d) {
    final api = ref.watch(embyApiProvider)!;
    final item = d.item;
    final isSeries = item.type == 'Series';
    // 按钮状态随条目同步
    if (_syncedItemId != item.id) {
      _syncedItemId = item.id;
      _fav = item.isFavorite;
      _watched = item.played;
    }
    final tags = <String>[
      if (item.productionYear != null) '${item.productionYear}',
      if (item.communityRating != null)
        '⭐ ${item.communityRating!.toStringAsFixed(1)}',
      if (item.officialRating != null && item.officialRating!.isNotEmpty)
        item.officialRating!,
      ...item.genres.take(2),
      // HD 元信息 Tag（从真实媒体流生成，对齐原型 dmeta-tag.hd）
      ..._hdTags(d),
    ];

    return Stack(children: [
      CustomScrollView(slivers: [
        SliverAppBar(
          pinned: true,
          expandedHeight: 260,
          backgroundColor: Cf.bg,
          iconTheme: IconThemeData(color: Colors.white),
          actions: [
            IconButton(
              onPressed: () => showComingSoon(context, '投屏'),
              icon: Icon(Icons.cast_rounded, size: 20),
            ),
            IconButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(
                    text:
                        'https://movie.douban.com/  · 《${item.displayTitle}》'));
                showComingSoon(context, '分享');
              },
              icon: Icon(Icons.ios_share_rounded, size: 19),
            ),
            SizedBox(width: 6),
          ],
          flexibleSpace: FlexibleSpaceBar(
            background: Stack(fit: StackFit.expand, children: [
              if (item.backdropUrl(api, maxWidth: 800) != null)
                Image.network(item.backdropUrl(api, maxWidth: 800)!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(color: Cf.surface))
              else
                Container(color: Cf.surface),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0, .45, 1],
                    colors: [
                      Color(0x660B1020),
                      Color(0x440B1020),
                      Cf.bg
                    ],
                  ),
                ),
              ),
            ]),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  _poster(api, item),
                  SizedBox(width: 13),
                  Expanded(child: _headline(d, tags)),
                ]),
                SizedBox(height: 15),
                _actionButtons(item),
                if (item.overview case final ov? when ov.isNotEmpty) ...[
                  SizedBox(height: 16),
                  Text(ov,
                      style: TextStyle(
                          fontSize: 12.5,
                          color: Cf.text2,
                          height: 1.75)),
                ],
                if (isSeries) ...[
                  _seriesSection(api, item),
                ] else ...[
                  _movieMediaSection(d),
                ],
                if (d.people.actors().isNotEmpty || d.people.crewLine() != null)
                  CfSection(
                    title: '演职员',
                    // 导演/编剧以摘要行呈现（服务器已返回但此前被丢弃，见 §7.14），
                    // 演员保留头像横滑
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (d.people.crewLine() case final line?)
                            Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(16, 0, 16, 12),
                              child: Text(line,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 12, color: Cf.text2)),
                            ),
                          if (d.people.actors().isNotEmpty) _cast(api, d),
                        ]),
                  ),
                CfSection(
                  title: '相似推荐',
                  padding: const EdgeInsets.only(top: 20),
                  child: _similar(api, item),
                ),
                SizedBox(height: 30),
              ],
            ),
          ),
        ),
      ]),
    ]);
  }

  Widget _poster(MediaProvider api, MediaItem item) {
    final url = item.posterUrl(api, maxWidth: 300);
    // Container 不支持负 margin，悬浮效果用 Transform.translate 实现
    return Transform.translate(
      offset: const Offset(0, -46),
      child: Container(
      width: 96,
      height: 142,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: Cf.border),
        boxShadow: const [
          BoxShadow(blurRadius: 36, offset: Offset(0, 12), color: Colors.black54)
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: url != null
            ? Image.network(url, fit: BoxFit.cover, errorBuilder: (_, _, _) => _ph())
            : _ph(),
      ),
    ),
    );
  }

  Widget _ph() => Container(
        color: Cf.surface2,
        alignment: Alignment.center,
        child: Icon(Icons.movie_outlined, color: Cf.text3),
      );

  Widget _headline(MediaItemDetail d, List<String> tags) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (d.tagline case final t? when t.isNotEmpty)
        Text(t,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10, color: Cf.accent)),
      SizedBox(height: 2),
      Text(d.item.displayTitle,
          style: TextStyle(
              fontSize: 21, fontWeight: FontWeight.w900, letterSpacing: -.5)),
      SizedBox(height: 7),
      Wrap(
          spacing: 6,
          runSpacing: 5,
          children: [
            for (final t in tags)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  color: const Color(0x14FFFFFF),
                  border: Border.all(color: const Color(0x22FFFFFF)),
                ),
                child: Text(t,
                    style: TextStyle(
                        fontSize: 9.5, fontWeight: FontWeight.w600)),
              ),
          ]),
      if (d.studios.isNotEmpty) ...[
        SizedBox(height: 7),
        Text(d.studios.join(' / '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10, color: Cf.text3)),
      ],
    ]);
  }

  Widget _actionButtons(MediaItem item) {
    final resume = item.progress > 0 && !item.played;
    final label = resume
        ? '▶  继续播放 ${(item.progress * 100).round()}%'
        : '▶  立即播放';
    return Row(children: [
      Expanded(
        child: GestureDetector(
          // 把「版本」chips 的当前选择带进播放器，否则多版本切换只改展示不改播放
          onTap: () =>
              openPlayer(context, item, mediaSourceId: _selectedVersionId),
          child: Container(
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: Cf.primaryGradient,
              borderRadius: BorderRadius.circular(9),
              boxShadow: [
                BoxShadow(
                    color: Cf.accent.withValues(alpha: .3),
                    blurRadius: 16,
                    offset: const Offset(0, 4)),
              ],
            ),
            child: Text(label,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: Cf.ink)),
          ),
        ),
      ),
      SizedBox(width: 9),
      // 收藏（真实 toggle）
      _roundBtn(
        icon: _fav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
        color: _fav ? Cf.danger : Cf.text,
        onTap: _toggling
            ? null
            : () async {
                final next = !_fav;
                setState(() {
                  _toggling = true;
                  _fav = next;
                });
                try {
                  final api = ref.read(embyApiProvider)!;
                  final result = await api.toggleFavorite(item.id, favorite: next);
                  if (result != next) setState(() => _fav = !next);
                } catch (_) {
                  setState(() => _fav = !_fav);
                  if (mounted) showComingSoon(context, '收藏失败，请稍后重试');
                } finally {
                  if (mounted) setState(() => _toggling = false);
                }
              },
      ),
      SizedBox(width: 9),
      // 看过（真实 toggle）
      _roundBtn(
        icon: _watched ? Icons.visibility_rounded : Icons.visibility_outlined,
        color: _watched ? Cf.warn : Cf.text,
        onTap: _toggling
            ? null
            : () async {
                final next = !_watched;
                setState(() {
                  _toggling = true;
                  _watched = next;
                });
                try {
                  final api = ref.read(embyApiProvider)!;
                  final result = await api.togglePlayed(item.id, played: next);
                  if (result != next) setState(() => _watched = !next);
                } catch (_) {
                  setState(() => _watched = !_watched);
                  if (mounted) showComingSoon(context, '标记失败，请稍后重试');
                } finally {
                  if (mounted) setState(() => _toggling = false);
                }
              },
      ),
      SizedBox(width: 9),
      _roundBtn(
        icon: Icons.download_outlined,
        onTap: () => showComingSoon(context, '下载'),
      ),
    ]);
  }

  /// HD 元信息 Tag：从第一路媒体流生成（4K / HDR / 杜比）
  List<String> _hdTags(MediaItemDetail d) {
    if (d.mediaSources.isEmpty) return const [];
    final video = d.mediaSources.first.streams
        .where((s) => s.type == 'Video')
        .toList();
    final audio = d.mediaSources.first.streams
        .where((s) => s.type == 'Audio')
        .toList();
    final out = <String>[];
    if (video.isNotEmpty) {
      final v = video.first;
      if ((v.width ?? 0) >= 3800 || (v.height ?? 0) >= 2100) out.add('4K');
      final range = (v.videoRange ?? '').toUpperCase();
      if (range.contains('DOVI')) {
        out.add('杜比视界');
      } else if (range.contains('HDR')) {
        out.add('HDR');
      }
    }
    if (audio.isNotEmpty) {
      final t = (audio.first.displayTitle ?? '') + (audio.first.codec ?? '');
      if (t.toUpperCase().contains('ATMOS') || t.contains('全景声')) {
        out.add('杜比全景声');
      }
    }
    return out;
  }

  Widget _roundBtn(
      {required IconData icon,
      required VoidCallback? onTap,
      Color color = Cf.text}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0x14FFFFFF),
          border: Border.all(
              color: onTap == null ? Cf.border : const Color(0x26FFFFFF)),
        ),
        child: Icon(icon, size: 17, color: color),
      ),
    );
  }

  /// 剧集：季选择器 + 分集列表
  Widget _seriesSection(MediaProvider api, MediaItem item) {
    final seasons = ref.watch(seasonsProvider(item.id));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(height: 8),
      seasons.when(
        loading: () => Padding(
          padding: EdgeInsets.all(20),
          child: Center(
              child: CircularProgressIndicator(color: Cf.accent)),
        ),
        error: (e, _) => const SizedBox.shrink(),
        data: (list) {
          if (list.isEmpty) return const SizedBox.shrink();
          _selectedSeasonId ??= list.first.id;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(height: 10),
            SizedBox(
              height: 34,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: list.length,
                separatorBuilder: (_, _) => SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final s = list[i];
                  final active = s.id == _selectedSeasonId;
                  return GestureDetector(
                    onTap: () =>
                        setState(() => _selectedSeasonId = s.id),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(9),
                        color: active
                            ? const Color(0x1F00D4FF)
                            : Cf.surface2,
                        border: Border.all(
                            color: active ? Cf.accent : Cf.border),
                      ),
                      child: Text(s.name,
                          style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: active
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                              color: active ? Cf.accent : Cf.text2)),
                    ),
                  );
                },
              ),
            ),
            SizedBox(height: 12),
            _episodeList(api, item),
          ]);
        },
      ),
    ]);
  }

  Widget _episodeList(MediaProvider api, MediaItem item) {
    final seasonId = _selectedSeasonId!;
    final eps = ref.watch(episodesProvider((item.id, seasonId)));
    return eps.when(
      loading: () => Padding(
        padding: EdgeInsets.all(20),
        child: Center(child: CircularProgressIndicator(color: Cf.accent)),
      ),
      error: (e, _) => const SizedBox.shrink(),
      data: (list) => Column(
        children: [
          for (var i = 0; i < list.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 9),
              child: _episodeCard(api, list[i], episodes: list, index: i),
            ),
        ],
      ),
    );
  }

  Widget _episodeCard(MediaProvider api, MediaItem ep,
      {required List<MediaItem> episodes, required int index}) {
    final url = ep.thumbUrl(api, maxWidth: 300);
    final minutes =
        ep.runtimeTicks != null ? (ep.runtimeTicks! / 600000000).round() : null;
    return GestureDetector(
      onTap: () => openPlayer(context, ep, episodes: episodes, index: index),
      child: Container(
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(11),
          color: Cf.surface,
          border: Border.all(color: Cf.border),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Stack(children: [
            Container(
              width: 128,
              height: 72,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: Cf.surface2,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: url != null
                    ? Image.network(url,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const SizedBox.shrink())
                    : const SizedBox.shrink(),
              ),
            ),
            if (ep.indexNumber != null)
              Positioned(
                top: 5,
                left: 6,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    color: const Color(0xB3000000),
                  ),
                  child: Text('第 ${ep.indexNumber} 集',
                      style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                ),
              ),
            if (minutes != null)
              Positioned(
                bottom: 5,
                right: 6,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    color: const Color(0xB3000000),
                  ),
                  child: Text('$minutes 分钟',
                      style: TextStyle(
                          fontSize: 8.5, color: Cf.text2)),
                ),
              ),
            if (ep.progress > 0)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  height: 2.5,
                  color: const Color(0x33FFFFFF),
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: ep.progress,
                    child: Container(color: Cf.accent),
                  ),
                ),
              ),
          ]),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Text(ep.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
                  if (ep.played)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 0),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: const Color(0x6600E5A0)),
                      ),
                      child: Text('已看',
                          style: TextStyle(
                              fontSize: 9, color: Cf.success)),
                    ),
                ]),
                if (ep.overview case final ov? when ov.isNotEmpty) ...[
                  SizedBox(height: 3),
                  Text(ov,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 10.5,
                          color: Cf.text3,
                          height: 1.55)),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }

  /// 电影：多版本切换 + 媒体流信息
  Widget _movieMediaSection(MediaItemDetail d) {
    if (d.mediaSources.isEmpty) return const SizedBox.shrink();
    _selectedVersionId ??= d.mediaSources.first.id;
    MediaSource? selected;
    for (final m in d.mediaSources) {
      if (m.id == _selectedVersionId) selected = m;
    }
    final video =
        selected?.streams.where((s) => s.type == 'Video').toList();
    final audio =
        selected?.streams.where((s) => s.type == 'Audio').toList();
    final subs =
        selected?.streams.where((s) => s.type == 'Subtitle').toList();

    final chips = <String>[
      if (selected?.container case final c? when c.isNotEmpty)
        c.toUpperCase(),
      if (selected?.sizeLabel case final sz? when sz.isNotEmpty) sz,
      if (video case final v? when v.isNotEmpty)
        v.first.displayTitle ?? '',
      if (audio case final a? when a.isNotEmpty)
        a.first.displayTitle ?? '',
    ];

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(height: 20),
      if (d.mediaSources.length > 1) ...[
        Text('版本',
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                letterSpacing: -.3)),
        SizedBox(height: 10),
        SizedBox(
          height: 34,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: d.mediaSources.length,
            separatorBuilder: (_, _) => SizedBox(width: 8),
            itemBuilder: (context, i) {
              final m = d.mediaSources[i];
              final active = m.id == _selectedVersionId;
              return GestureDetector(
                onTap: () => setState(() => _selectedVersionId = m.id),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(9),
                    color: active ? const Color(0x1F00D4FF) : Cf.surface2,
                    border:
                        Border.all(color: active ? Cf.accent : Cf.border),
                  ),
                  child: Text(m.versionLabel,
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: active
                              ? FontWeight.w800
                              : FontWeight.w600,
                          color: active ? Cf.accent : Cf.text2)),
                ),
              );
            },
          ),
        ),
        SizedBox(height: 12),
      ],
      Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in chips)
              if (c.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 11, vertical: 5),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: Cf.surface2,
                    border: Border.all(color: Cf.border),
                  ),
                  child: Text(c,
                      style: TextStyle(
                          fontSize: 10, color: Cf.text2)),
                ),
            if (subs case final s? when s.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 11, vertical: 5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: Cf.surface2,
                  border: Border.all(color: Cf.border),
                ),
                child: Text('字幕 ${s.length} 条',
                    style: TextStyle(
                        fontSize: 10, color: Cf.text2)),
              ),
          ]),
    ]);
  }

  Widget _cast(MediaProvider api, MediaItemDetail d) {
    final actors = d.people.actors();
    return SizedBox(
      height: 110,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: actors.length,
        separatorBuilder: (_, _) => SizedBox(width: 14),
        itemBuilder: (context, i) {
          final p = actors[i];
          final url = p.primaryImageTag == null
              ? null
              : api.imageUrl(p.id, tag: p.primaryImageTag, maxWidth: 160);
          return SizedBox(
            width: 74,
            child: Column(children: [
              Container(
                width: 62,
                height: 62,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                      colors: [Cf.surface2, Cf.border]),
                  border: Border.all(color: Cf.border, width: 1.5),
                ),
                child: ClipOval(
                  child: url != null
                      ? Image.network(url,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => _personPh(p))
                      : _personPh(p),
                ),
              ),
              SizedBox(height: 7),
              Text(p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 10.5, fontWeight: FontWeight.w700)),
              if (p.role case final r? when r.isNotEmpty)
                Text(r,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(fontSize: 9, color: Cf.text3)),
            ]),
          );
        },
      ),
    );
  }

  Widget _personPh(MediaPerson p) => Center(
        child: Text(p.name.isEmpty ? '?' : p.name.characters.first,
            style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w900,
                color: Cf.text3)),
      );

  Widget _similar(MediaProvider api, MediaItem item) {
    final sim = ref.watch(similarProvider(item.id));
    return sim.when(
      loading: () => SizedBox(height: 100),
      error: (e, _) => const SizedBox.shrink(),
      data: (list) {
        if (list.isEmpty) {
          return Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('暂无相似推荐',
                style: TextStyle(fontSize: 11, color: Cf.text3)),
          );
        }
        return SizedBox(
          height: 195,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: list.length,
            separatorBuilder: (_, _) => SizedBox(width: 10),
            itemBuilder: (context, i) => SizedBox(
              width: 112,
              child: PosterCard(
                  item: list[i],
                  api: api,
                  onTap: () => openMediaItem(context, list[i])),
            ),
          ),
        );
      },
    );
  }
}
