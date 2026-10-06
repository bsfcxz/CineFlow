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
                                  fontSize: 16, fontWeight: FontWeight.w800)),
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

  /// 头部海报宽度（高度按 2:3 比例推出）。
  ///
  /// ## 为什么要按断点（审计 U7）
  /// 原为写死的 `96×142`：Compact 上合适，但 Medium/Expanded 下
  /// 96dp 的海报躺在一片空白里显得可怜 —— 大屏有空间就该给足主视觉。
  ///
  /// 抽成 `public static` 纯函数便于单测边界（与 `PlayerPage` 的
  /// `drawerWidthFor` 同一约定）。
  static double posterWidthFor(int windowClass) => switch (windowClass) {
        CfBreakpoints.expanded => 132.0,
        CfBreakpoints.medium => 112.0,
        _ => 96.0, // Compact（原值，保持不变）
      };

  /// 多版本缩略图宽度（高度按 16:9 推出）。
  ///
  /// 原为写死的 `128×72`。同样按断点放大，理由同上。
  static double versionThumbWidthFor(int windowClass) => switch (windowClass) {
        CfBreakpoints.expanded => 172.0,
        CfBreakpoints.medium => 148.0,
        _ => 128.0, // Compact（原值）
      };

  /// 演职员横向行的**固定高度**。
  ///
  /// ## 这个 110 为什么不改大，而是改"钳制里面的字"
  ///
  /// 实测内容高（Roboto 行高系数 1.171875）：
  ///   1.0x 字缩 → 62 + 7 + 12.89 + 10.55 = **92.44**（富余 17.6）
  ///   1.5x      → **104.16**（仍未溢出）
  ///   2.0x      → **115.88 → 溢出 5.9dp**
  ///
  /// 所以默认字号下行高是**合适的**，把 110 改大会在默认场景留下多余空白。
  /// 真正的问题是"2.0x 时文字撑破固定高容器" → 正确解法是
  /// **钳制那两行文字**（`CfText(clamp: true)`，已在 `_cast` 里落地）。
  ///
  /// 保留常量只是为了让测试能断言"钳制后不会再溢出"。
  static const double castRowHeight = 110;

  /// 演职员行在给定字缩下的内容高度（供测试断言"钳制后不再溢出"）。
  ///
  /// 与 `_cast` 的实际布局一一对应：
  /// 头像 62 + 间距 7 + 姓名行 + 角色行。
  static double castContentHeight({
    double headerSize = 62,
    double gap = 7,
    double nameFontSize = 11,
    double roleFontSize = 9,
    double textScale = 1.0,
  }) {
    const lineHeight = 1.171875; // Roboto 默认行高系数（Flutter 未指定 height 时）
    return headerSize +
        gap +
        nameFontSize * lineHeight * textScale +
        roleFontSize * lineHeight * textScale;
  }

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

  /// 分集区的定位锚点：剧集的「选集播放」按钮靠它滚过去。
  final _seriesKey = GlobalKey();

  /// 剧集起播中（下钻分季/分集要发两次请求，需要禁重入 + 显示 loading）
  bool _resolvingPlay = false;

  /// 剧集续播文案（如「继续播放 第 3 集」）。
  ///
  /// 由 `_prefetchSeriesProgress` 在进详情页时预取，
  /// 这样**首帧就能显示正确文案**，用户不必先点一次才知道看到哪了。
  String? _seriesResumeLabel;

  /// 预取剧集进度：进详情页时问一次服务端"该看哪一集"。
  ///
  /// ## 改造（用户指出的"致命问题"）
  ///
  /// 原来是：`getSeasons` → `getEpisodes` → 自己遍历分集 `UserData` 推断
  /// （`SeriesProgress.resolve`），**2 次请求 + 自己写的推断逻辑**。
  ///
  /// 现在是：**1 次请求** `getNextUp(seriesId)`，由服务端直接给出答案。
  /// 服务端有完整观看历史，比客户端遍历更准（能正确处理
  /// "跳着看""看完最后一集""看了几分钟就退出"等边界）。
  Future<void> _prefetchSeriesProgress(MediaItem item) async {
    if (item.type != 'Series') return;
    final api = ref.read(embyApiProvider);
    if (api == null) return;
    try {
      final next = await api.getNextUp(item.id, limit: 1);
      if (!mounted) return;
      if (next.isEmpty) {
        // 服务端表示"没有下一集了"。两种情况要区分：
        //   · **该剧已全部看完** → 用户预期是"重播最后一集"（不是跳回第 1 集！）
        //   · **一集都没看过** → 从第 1 集开始
        // 判据：剧集的 `unplayedItemCount`（实测服务端会给，如 16）。
        // 若它 == 0，说明一集不剩（= 全看完了）。
        // ⚠️ 早期版本这里写死"重播第 1 集"，对"已看完"的用户是**语义回归**：
        //    他会莫名其妙跳回开头。（审计发现）
        final allWatched =
            item.unplayedItemCount != null && item.unplayedItemCount == 0;
        setState(() => _seriesResumeLabel =
            allWatched ? '已看完 · 重播最后一集' : '立即播放');
        return;
      }
      final ep = next.first;
      final n = ep.indexNumber;
      setState(() {
        _seriesResumeLabel =
            n != null ? '继续播放 第 $n 集' : '继续播放 ${ep.displayTitle}';
      });
    } catch (e) {
      // 预取失败不影响使用：回落到「立即播放」，真正点击时还会重试
      debugPrint('[Detail] 预取剧集进度失败（非致命）: $e');
    }
  }

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
      // 剧集：详情一到位就预取"看到第几集"，让按钮首帧就是「继续播放 第 N 集」。
      // 放这里而不是 initState —— 那时 item 还没加载出来，拿不到 id。
      // 用 Future.microtask 避免在 build 期间直接 setState。
      if (isSeries) {
        _seriesResumeLabel = null;
        Future.microtask(() => _prefetchSeriesProgress(item));
      }
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
              icon: Icon(Icons.ios_share_rounded, size: 20),
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
                          fontSize: 13,
                          color: Cf.text2,
                          height: 1.75)),
                ],
                if (isSeries) ...[
                  // 用 ValueKey 让「选集播放」能滚到这里（见 _scrollToEpisodes）
                  KeyedSubtree(key: _seriesKey, child: _seriesSection(api, item)),
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
    final posterW = DetailPage.posterWidthFor(
        CfBreakpoints.of(MediaQuery.sizeOf(context).width));
    // Container 不支持负 margin，悬浮效果用 Transform.translate 实现
    return Transform.translate(
      offset: const Offset(0, -46),
      child: Container(
      // 海报尺寸按断点：大屏给大一点，否则在 Medium/Expanded 的
      // 一片空白里 96dp 显得可怜（审计 U7 点名 142/128 写死）。
      width: posterW,
      height: posterW * 1.48, // 保持 2:3 海报比例
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Cf.radiusMd),
        border: Border.all(color: Cf.border),
        boxShadow: const [
          BoxShadow(blurRadius: 36, offset: Offset(0, 12), color: Colors.black54)
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Cf.radiusSm),
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
              fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: -.5)),
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
                  borderRadius: BorderRadius.circular(8),
                  color: const Color(0x14FFFFFF),
                  border: Border.all(color: const Color(0x22FFFFFF)),
                ),
                child: Text(t,
                    style: TextStyle(
                        fontSize: 10, fontWeight: FontWeight.w600)),
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

  /// 把详情页滚到分集区。
  ///
  /// 用 `GlobalKey` + `ensureVisible` 而不是算 offset：
  /// **分集区高度随季数/集数变化**，硬编码 offset 必然错位。
  void _scrollToEpisodes() {
    final ctx = _seriesKey.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(ctx,
        duration: Cf.durSlow, curve: Cf.curve, alignment: 0.05);
  }

  /// 剧集的主动作：**真正起播**，并且**接着上次看到的那一集**继续。
  ///
  /// ## 背景（用户三轮反馈）
  /// 1. "剧集详情页应该是播放/立即播放按钮，而不是选集"
  /// 2. "剧集是否'看过'，得分析看到第几集了，还是显示继续播放按钮"
  /// 3. **"这些东西本来你应该能够从 emby 服务端全部拿到"** ← 最关键的一条
  ///
  /// ## 改造前 vs 现在
  ///
  /// | | 改造前（错） | 现在（对） |
  /// |---|---|---|
  /// | 请求数 | 2 次（getSeasons + getEpisodes） | **1 次**（getNextUp） |
  /// | 判断"看到第几集" | 自己遍历分集 `UserData` 推断 | **服务端直接给** |
  /// | 边界情况 | 自己处理，容易错 | 服务端有完整观看历史 |
  ///
  /// 服务端的 `/Shows/NextUp?SeriesId=` 就是干这个的（实测返回 S1E9/E10/E11）。
  /// 我自己写的 `SeriesProgress.resolve` 属于**重新发明轮子且更差**。
  ///
  /// ## 起播链路
  ///   1. 问服务端"该看哪一集"（`getNextUp`）；已看完则回退第一集
  ///   2. 取该集所属季的分集列表（供播放器的「选集」抽屉与自动连播用）
  ///   3. 起播，**并把整个 episodes 列表一并传给播放器**
  ///
  /// 任一步失败 → **回退到滚动分集列表**并提示，不静默失败。
  Future<void> _playSeries(MediaItem item) async {
    final api = ref.read(embyApiProvider);
    if (api == null) return;
    setState(() => _resolvingPlay = true);
    try {
      // ① 服务端给出"该看哪一集"
      final next = await api.getNextUp(item.id, limit: 1);
      if (!mounted) return;

      // ② 取分集列表（播放器的选集/自动连播需要完整列表）。
      //    优先用 nextUp 那一集所属的季；已看完（next 为空）时用第一季。
      final seasons = await api.getSeasons(item.id);
      if (!mounted) return;
      if (seasons.isEmpty) {
        _fallbackToEpisodes('该剧集暂无可播放的分集');
        return;
      }
      final target = next.isEmpty ? null : next.first;
      // nextUp 的条目带 SeasonId；用它定位季，找不到则退回第一季
      final seasonId = target?.seasonId != null &&
              seasons.any((s) => s.id == target!.seasonId)
          ? target!.seasonId!
          : (seasons.any((s) => s.id == _selectedSeasonId)
              ? _selectedSeasonId!
              : seasons.first.id);
      final episodes = await api.getEpisodes(item.id, seasonId);
      if (!mounted) return;
      if (episodes.isEmpty) {
        _fallbackToEpisodes('该季暂无可播放的分集');
        return;
      }

      // ③ 定目标集：
      //    · 服务端推荐了且在本季 → 用它
      //    · 已全部看完（next 为空）→ **重播最后一集**（不是第 1 集，见下方注释）
      //    · 推荐集不在本季 → 用本季第一集
      final allWatched =
          item.unplayedItemCount != null && item.unplayedItemCount == 0;
      final MediaItem targetEp;
      if (target != null && episodes.any((e) => e.id == target.id)) {
        targetEp = episodes.firstWhere((e) => e.id == target.id);
      } else if (allWatched) {
        targetEp = episodes.last;
      } else {
        targetEp = episodes.first;
      }

      setState(() {
        _resolvingPlay = false;
        _seriesResumeLabel = next.isEmpty
            // 已看完 → 重播最后一集；否则是"一集没看"→ 第一集
            ? (allWatched ? '已看完 · 重播最后一集' : '立即播放')
            : (targetEp.indexNumber != null
                ? '继续播放 第 ${targetEp.indexNumber} 集'
                : '继续播放 ${targetEp.displayTitle}');
      });
      // ★ 必须把 episodes + index 一起传给播放器 —— 否则播放器以为
      //   这是个"没有分集上下文的单条视频"，**「选集」按钮与自动连播都会消失**
      //   （用户实测反馈："你将播放视频中的选集按钮给删除了"）。
      openPlayer(context, targetEp,
          episodes: episodes, index: episodes.indexOf(targetEp));
    } catch (e) {
      debugPrint('[Detail] 剧集起播失败: $e');
      if (!mounted) return;
      _fallbackToEpisodes('起播失败，已为你打开分集列表');
    }
  }

  /// 剧集起播失败时的退路：滚到分集区 + 轻提示（不静默）。
  void _fallbackToEpisodes(String msg) {
    if (mounted) {
      setState(() => _resolvingPlay = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
    }
    _scrollToEpisodes();
  }

  Widget _actionButtons(MediaItem item) {
    final isSeries = item.type == 'Series';

    // ★ 按钮文案规则（用户两轮反馈后的最终口径）：
    //
    //   · **电影**：进度来自自身 `UserData` → `progress > 0 && !played` 即续播
    //   · **剧集**：进度**不在剧集上**（实测 `Series.UserData` 恒为
    //     `Played=false, PositionTicks=0`），必须从分集反推"看到第几集"。
    //     反推结果由 `_playSeries` 在拉到分集后写入 `_seriesResumeLabel`。
    //
    //   两者共同点：**保持「立即播放 / 继续播放」的语义，绝不显示"选集"**
    //   （那是上一版的错误做法，用户明确否掉了）。
    final String label;
    if (isSeries) {
      // 分集还没拉到时（首帧）先显示「立即播放」，拉到后自动变「继续播放 第 N 集」
      label = _resolvingPlay
          ? '正在准备…'
          : (_seriesResumeLabel != null
              ? '▶  $_seriesResumeLabel'
              : '▶  立即播放');
    } else {
      final resume = item.progress > 0 && !item.played;
      label = resume
          ? '▶  继续播放 ${(item.progress * 100).round()}%'
          : '▶  立即播放';
    }

    void onPrimary() {
      if (_resolvingPlay) return;
      if (isSeries) {
        _playSeries(item);
      } else {
        // 把「版本」chips 的当前选择带进播放器，否则多版本切换只改展示不改播放
        openPlayer(context, item, mediaSourceId: _selectedVersionId);
      }
    }

    return Row(children: [
      Expanded(
        // 原为裸 GestureDetector：**没有按压反馈**，而且可点区域随文字宽度变化。
        // 改用 InkWell（在 Material 上才有涟漪）+ 固定高度，命中区稳定且 ≥44dp。
        child: SizedBox(
          height: 44,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onPrimary,
              borderRadius: BorderRadius.circular(Cf.radiusSm),
              child: Ink(
                decoration: BoxDecoration(
                  gradient: Cf.primaryGradient,
                  borderRadius: BorderRadius.circular(Cf.radiusSm),
                  boxShadow: [
                    BoxShadow(
                        color: Cf.accent.withValues(alpha: .3),
                        blurRadius: 16,
                        offset: const Offset(0, 4)),
                  ],
                ),
                child: Center(
                  child: Text(label,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: Cf.ink)),
                ),
              ),
            ),
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
                } catch (e) {
                  // ★ 原为 `showComingSoon(context, '收藏失败，请稍后重试')` ——
                  //   用「即将推出」的弹窗去报**失败**，是双重错误：
                  //   ① 用户看到"即将推出"会以为这功能没做（其实做了，只是这次失败了）
                  //   ② 失败原因被吞掉（`catch (_)`），无法判断能否自救
                  //   改为 SnackBar + 真实原因，风格与"操作反馈"语义一致。
                  debugPrint('[Detail] 收藏切换失败: $e');
                  setState(() => _fav = !_fav);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('收藏失败：$e'),
                      duration: const Duration(seconds: 3),
                    ));
                  }
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
                } catch (e) {
                  // 同上：失败不该用「即将推出」弹窗报。
                  debugPrint('[Detail] 看过标记失败: $e');
                  setState(() => _watched = !_watched);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('标记失败：$e'),
                      duration: const Duration(seconds: 3),
                    ));
                  }
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
      // 用 `label`（优先服务端 DisplayTitle，缺失才自拼）——
      // 原来只拼 displayTitle + codec，服务端给的名字里若含 "Atmos"
      // 但 displayTitle 为空就会漏判。
      final t = audio.first.label;
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
        child: Icon(icon, size: 16, color: color),
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
                        borderRadius: BorderRadius.circular(8),
                        color: active
                            ? Cf.accent.withValues(alpha: 0.12)
                            : Cf.surface2,
                        border: Border.all(
                            color: active ? Cf.accent : Cf.border),
                      ),
                      child: Text(s.name,
                          style: TextStyle(
                              fontSize: 12,
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
          borderRadius: BorderRadius.circular(12),
          color: Cf.surface,
          border: Border.all(color: Cf.border),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Stack(children: [
            Container(
              // 版本缩略图同样按断点（原写死 128×72）
              width: DetailPage.versionThumbWidthFor(
                  CfBreakpoints.of(MediaQuery.sizeOf(context).width)),
              height: DetailPage.versionThumbWidthFor(
                      CfBreakpoints.of(MediaQuery.sizeOf(context).width)) *
                  0.5625, // 16:9
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Cf.radiusSm),
                color: Cf.surface2,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Cf.radiusSm),
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
                          fontSize: 9, color: Cf.text2)),
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
                          fontSize: 11,
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
      // 用 `label`（优先服务端 DisplayTitle）——原为 `displayTitle ?? ''`，
      // 服务端没给 DisplayTitle 时会**渲染出空 chip**（占位但无内容）。
      if (video case final v? when v.isNotEmpty) v.first.label,
      if (audio case final a? when a.isNotEmpty) a.first.label,
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
                    borderRadius: BorderRadius.circular(8),
                    color: active ? Cf.accent.withValues(alpha: 0.12) : Cf.surface2,
                    border:
                        Border.all(color: active ? Cf.accent : Cf.border),
                  ),
                  child: Text(m.versionLabel,
                      style: TextStyle(
                          fontSize: 12,
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
              // ⚠️ 必须钳制：本行高固定 110dp，实测 2.0x 字缩下
              //    内容总高 62+7+25.78+21.09 = 115.88 → **溢出 5.9dp**
              //    （1.0x 时 92.44，富余 17.6）。
              //    两行都在**固定高容器**里 → 钳制，而不是把行高改大
              //    （改大行高会在默认字号下留多余空白）。
              CfText(p.name,
                  clamp: true,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w700)),
              if (p.role case final r? when r.isNotEmpty)
                CfText(r,
                    clamp: true,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 9, color: Cf.text3)),
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
