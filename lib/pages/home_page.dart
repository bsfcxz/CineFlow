/// 首页：精选轮播 / 继续观看 / 最近添加（全部真实数据）
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/router.dart';
import '../core/theme.dart';
import '../data/emby_provider.dart';
import '../data/models.dart';
import '../player/player_routes.dart';
import '../state/providers.dart';
import '../widgets/media_cards.dart';
import 'detail_page.dart';

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final home = ref.watch(homeProvider);
    return Scaffold(
      body: home.when(
        loading: () => Center(
            child: CircularProgressIndicator(color: Cf.accent)),
        error: (e, _) => CfErrorView(
          message: e is MediaException ? e.message : '加载失败，请检查网络后重试',
          onRetry: () => ref.invalidate(homeProvider),
        ),
        data: (d) => d.fatalError != null
            // 全部区块都失败：显示错误页而不是"空首页"，否则用户会误以为媒体库是空的
            ? CfErrorView(
                message: d.fatalError is MediaException
                    ? (d.fatalError as MediaException).message
                    : '加载失败，请检查网络后重试',
                onRetry: () => ref.invalidate(homeProvider),
              )
            : RefreshIndicator(
          color: Cf.accent,
          backgroundColor: Cf.surface,
          onRefresh: () => ref.refresh(homeProvider.future),
          child: Stack(children: [
            SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              child: Column(children: [
                if (d.featured.isNotEmpty) _Carousel(items: d.featured),
                if (d.resume.isNotEmpty)
                  CfSection(
                    title: '继续观看',
                    trailing: '全部 ›',
                    onTrailing: () =>
                        showComingSoon(context, '播放历史'),
                    child: SizedBox(
                      height: 165,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: d.resume.length,
                        separatorBuilder: (_, _) => SizedBox(width: 13),
                        itemBuilder: (_, i) => ContinueCard(
                            item: d.resume[i],
                            api: ref.read(embyApiProvider)!,
                            onTap: () => openPlayer(context, d.resume[i])),
                      ),
                    ),
                  ),
                if (d.collections.isNotEmpty)
                  CfSection(
                    title: '合集',
                    trailing: '全部 ›',
                    onTrailing: () => showComingSoon(context, '合集库'),
                    child: SizedBox(
                      height: 190,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: d.collections.length,
                        separatorBuilder: (_, _) => SizedBox(width: 10),
                        itemBuilder: (_, i) => SizedBox(
                          width: 112,
                          child: PosterCard(
                              item: d.collections[i],
                              api: ref.read(embyApiProvider)!,
                              onTap: () =>
                                  openMediaItem(context, d.collections[i])),
                        ),
                      ),
                    ),
                  ),
                if (d.latest.isNotEmpty)
                  CfSection(
                    title: '最近添加',
                    // 不再挂「全部 ›」：媒体库页已移除（ADR 0003），
                    // 留一个点进去是"敬请期待"的入口比没有入口更糟。
                    child: PosterGrid(
                      items: d.latest,
                      api: ref.read(embyApiProvider)!,
                      onItemTap: (item) => openMediaItem(context, item),
                    ),
                  ),
                SizedBox(height: 28),
              ]),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: const _HomeTopBar(),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// 顶栏（悬浮于轮播之上）：Logo + 搜索 / 投屏
class _HomeTopBar extends ConsumerWidget {
  const _HomeTopBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xD90B1020), Color(0x000B1020)],
        ),
      ),
      child: Row(children: [
        const Spacer(),
        GestureDetector(
          onTap: () => context.push(Routes.search),
          child: Icon(Icons.search_rounded, size: 22, color: Cf.text2),
        ),
        SizedBox(width: 16),
        GestureDetector(
          onTap: () => ref.read(homeTabProvider.notifier).set(2),
          child: Icon(Icons.settings_rounded, size: 21, color: Cf.text2),
        ),
      ]),
    );
  }
}

/// 精选轮播：5s 自动翻页，真实背景图 + 渐变压暗
class _Carousel extends StatefulWidget {
  const _Carousel({required this.items});
  final List<MediaItem> items;

  @override
  State<_Carousel> createState() => _CarouselState();
}

class _CarouselState extends State<_Carousel> {
  final _controller = PageController();
  Timer? _timer;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _armTimer();
  }

  void _armTimer() {
    _timer?.cancel();
    if (widget.items.length > 1) {
      _timer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (!mounted) return;
        _page = (_page + 1) % widget.items.length;
        _controller.animateToPage(_page,
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeInOutCubic);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 270,
      width: double.infinity,
      child: PageView.builder(
        controller: _controller,
        itemCount: widget.items.length,
        onPageChanged: (i) {
          setState(() => _page = i);
          _armTimer(); // 手动滑动后重新计时
        },
        itemBuilder: (context, i) =>
            _Slide(item: widget.items[i], active: i == _page),
      ),
    );
  }
}

class _Slide extends ConsumerWidget {
  const _Slide({required this.item, required this.active});
  final MediaItem item;
  final bool active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(embyApiProvider)!;
    final url = item.backdropUrl(api);
    final tags = <String>[
      if (item.productionYear != null) '${item.productionYear}',
      if (item.communityRating != null)
        '⭐ ${item.communityRating!.toStringAsFixed(1)}',
      ...item.genres.take(2),
    ];
    return GestureDetector(
      onTap: () => openMediaItem(context, item),
      child: Stack(fit: StackFit.expand, children: [
        if (url != null)
          Image.network(url,
              fit: BoxFit.cover,
              alignment: const Alignment(0, .35),
              errorBuilder: (_, _, _) => Container(decoration: _gradient()))
        else
          Container(decoration: _gradient()),
        // 左右 + 上下双向渐变压暗（对齐原型 .carousel-slide::after）
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              stops: [0, .35, .65, 1],
              colors: [
                Color(0xEB0B1020),
                Color(0x990B1020),
                Color(0x000B1020),
                Color(0x000B1020),
              ],
            ),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              stops: [0, .4, 1],
              colors: [Color(0xF20B1020), Color(0x660B1020), Color(0x000B1020)],
            ),
          ),
        ),
        Positioned(
          left: 18,
          right: 18,
          bottom: 20,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 23,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1,
                      height: 1.15,
                      shadows: [
                        Shadow(blurRadius: 20, color: Colors.black54)
                      ])),
              if (tags.isNotEmpty) SizedBox(height: 9),
              Wrap(spacing: 7, runSpacing: 5, children: [
                for (final t in tags)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 9, vertical: 2),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      color: const Color(0x1FFFFFFF),
                      border:
                          Border.all(color: const Color(0x26FFFFFF)),
                    ),
                    child: Text(t,
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: Cf.text)),
                  ),
              ]),
              if (item.overview case final ov? when ov.isNotEmpty) ...[
                SizedBox(height: 9),
                Text(ov,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 10.5,
                        height: 1.65,
                        color: Cf.text2,
                        shadows: [
                          Shadow(blurRadius: 8, color: Colors.black54)
                        ])),
              ],
            ],
          ),
        ),
      ]),
    );
  }

  BoxDecoration _gradient() {
    const sets = [
      [Color(0xFF1A3A5C), Color(0xFF0B1020)],
      [Color(0xFF3A1A4C), Color(0xFF0B1020)],
      [Color(0xFF1A4C3A), Color(0xFF0B1020)],
    ];
    final c = sets[item.id.hashCode.abs() % sets.length];
    return BoxDecoration(
        gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: c));
  }
}


