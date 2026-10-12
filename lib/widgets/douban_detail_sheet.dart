/// 豆瓣详情弹层 —— 完整信息（评分/简介/导演/演员）+ 跳转动作
/// 供排行榜条目、豆瓣搜索结果共用；数据来自 subjectDetail（24h 缓存）。
library;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/router.dart';
import '../core/theme.dart';
import '../douban/douban_image.dart';
import '../douban/douban_models.dart';
import '../state/douban_providers.dart';
// `subscribeExternal` / `subscriptionsProvider` —— 订阅（先搜本地库再写）
import '../state/providers.dart';

/// 打开豆瓣详情弹层
/// [entry] 可选：详情加载前的即时信息（榜单条目自带）
void showDoubanDetail(
  BuildContext context, {
  required String id,
  required bool isTv,
  DoubanEntry? entry,
}) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Cf.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => SafeArea(
      child: _DoubanDetailSheet(id: id, isTv: isTv, entry: entry),
    ),
  );
}

class _DoubanDetailSheet extends ConsumerStatefulWidget {
  const _DoubanDetailSheet({required this.id, required this.isTv, this.entry});
  final String id;
  final bool isTv;
  final DoubanEntry? entry;

  @override
  ConsumerState<_DoubanDetailSheet> createState() =>
      _DoubanDetailSheetState();
}

class _DoubanDetailSheetState extends ConsumerState<_DoubanDetailSheet> {
  /// 是否已追（本地订阅表 ∪ Emby 收藏）。
  bool _following = false;
  bool _toggling = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncFollowing());
  }

  /// 查本地是否已订阅（**按标题** —— 豆瓣条目没有 tmdbId）。
  ///
  /// ⚠️ 同名不同剧会有误差；但点订阅时 `subscribeExternal` 会**再搜一次库**
  ///    做精确媒体匹配，所以这里的显示误差不影响写入。
  Future<void> _syncFollowing() async {
    try {
      final subs = await ref.read(subscriptionsProvider.future);
      final t = (widget.entry?.title ?? '').trim();
      if (t.isEmpty) return;
      final hit = subs.any((s) => s.title == t || s.titleCn == t);
      if (mounted && hit) setState(() => _following = true);
    } catch (e) {
      debugPrint('[DoubanSheet] 读订阅失败（非致命）: $e');
    }
  }

  /// 订阅切换：**先搜本地库，命中才写**（用户 2026-10-12 要求）。
  ///
  /// ## 用户原话
  /// > "tmdb 和豆瓣的订阅增加后 —— 先搜索本地库是否有，存在的话直接从
  /// >  emby 服务端收藏 = 订阅，没有的话提示，订阅暂未入库。"
  ///
  /// ## 三种结果各自的提示（说清区别，不让用户猜）
  /// · `subscribed`   ⇒ "已加入追剧：《X》"
  /// · `notInLibrary` ⇒ "订阅暂未入库：媒体库里没有《X》"（**什么都没写**）
  /// · `failed`       ⇒ "操作失败：<原因>"
  Future<void> _toggleSubscribe(String title) async {
    setState(() => _toggling = true);
    try {
      final r = await subscribeExternal(
        ref: ref,
        title: title,
        mediaType: widget.isTv ? 'tv' : 'movie',
      );
      if (!mounted) return;
      switch (r.outcome) {
        case SubscribeOutcome.subscribed:
          setState(() => _following = true);
          _toast('已加入追剧：《${r.title}》');
        case SubscribeOutcome.unsubscribed:
          setState(() => _following = false);
          _toast('已取消追剧：《${r.title}》');
        case SubscribeOutcome.notInLibrary:
          // ⚠️ 不写任何东西 —— 库里没有的剧写进「我的追剧」会让用户点进去"找不到"
          _toast('订阅暂未入库：媒体库里没有《${r.title}》');
        case SubscribeOutcome.failed:
          _toast('操作失败：${r.error ?? '未知原因'}');
      }
    } finally {
      if (mounted) setState(() => _toggling = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(seconds: 3),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    final detail =
        ref.watch(doubanDetailProvider((widget.id, widget.isTv)));
    final title = widget.entry?.title ?? '';
    final cover = widget.entry?.coverUrl;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
      maxChildSize: 0.92,
      builder: (context, scrollCtrl) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            cover != null && cover.isNotEmpty
                ? DoubanImage(url: cover, width: 84, height: 120, radius: 9)
                : Container(
                    width: 84,
                    height: 120,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: Cf.surface2,
                    ),
                    alignment: Alignment.center,
                    child: Icon(Icons.movie_outlined, color: Cf.text3),
                  ),
            SizedBox(width: 13),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title.isNotEmpty ? title : '豆瓣条目',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w800)),
                    if (widget.entry?.ratingText case final r?) ...[
                      SizedBox(height: 5),
                      Row(children: [
                        Icon(Icons.star_rounded,
                            size: 16, color: Cf.warn),
                        SizedBox(width: 3),
                        Text(r,
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w900,
                                color: Cf.warn)),
                        if (widget.entry?.rateCount case final c?)
                          Text('  $c 人评过',
                              style: TextStyle(
                                  fontSize: 10, color: Cf.text3)),
                      ]),
                    ],
                    if (widget.entry?.subtitle case final sub? when sub.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Text(sub,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 10, color: Cf.text3, height: 1.5)),
                      ),
                  ]),
            ),
          ]),
          SizedBox(height: 12),
          Expanded(
            child: detail.when(
              loading: () => Center(
                  child: Padding(
                padding: EdgeInsets.all(20),
                child: CircularProgressIndicator(color: Cf.accent),
              )),
              error: (e, _) => Center(
                  child: Text('$e',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12, color: Cf.text2))),
              data: (d) {
                if (d == null) {
                  return Center(
                      child: Text('暂无更多详情',
                          style:
                              TextStyle(fontSize: 12, color: Cf.text3)));
                }
                return ListView(
                  controller: scrollCtrl,
                  children: [
                    if (d.intro case final intro? when intro.isNotEmpty) ...[
                      Text('简介',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w800)),
                      SizedBox(height: 6),
                      Text(intro,
                          style: TextStyle(
                              fontSize: 12,
                              color: Cf.text2,
                              height: 1.7)),
                      SizedBox(height: 14),
                    ],
                    _infoRow('导演', d.directors),
                    _infoRow('主演', d.actors.take(8).toList()),
                    _infoRow('类型', d.genres),
                    _infoRow('制片国家/地区', d.countries),
                    if (d.episodesInfo case final ep? when ep.isNotEmpty)
                      _infoRow('集数', [ep]),
                    SizedBox(height: 8),
                  ],
                );
              },
            ),
          ),
          SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: GestureDetector(
                onTap: () {
                  // 先关掉底部弹窗，再跳搜索页。
                  // 顺序不能反：`context` 是弹窗自己的 BuildContext，
                  // 弹窗一关它就失效，之后再拿它做路由跳转会抛
                  // "Looking up a deactivated widget's ancestor"。
                  final router = GoRouter.of(context);
                  Navigator.pop(context);
                  router.push('${Routes.search}?q=${Uri.encodeComponent(title)}');
                },
                child: Container(
                  height: 46,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: Cf.primaryGradient,
                    borderRadius: BorderRadius.circular(Cf.radiusMd),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.search_rounded, size: 16, color: Cf.ink),
                      SizedBox(width: 6),
                      Flexible(
                        child: Text('在媒体库搜索',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: Cf.ink)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(width: 10),
            // ★ **追剧**（用户 2026-10-12："豆瓣的排行榜也增加一个和 tmdb
            //   一样的订阅按钮"）
            //
            // ## 语义（走公共函数 `subscribeExternal`）
            // **先搜本地库** ⇒ 命中才写（Emby 收藏 + 本地订阅表）；
            // 未命中 ⇒ **什么都不写**，提示"订阅暂未入库"。
            //
            // ⚠️ 豆瓣条目**没有 tmdbId**（两个体系不通）⇒ 只能按**标题**搜库。
            //    `subscribeExternal` 里用的是聚合搜索（并行搜所有已登录服务器）。
            Expanded(
              child: GestureDetector(
                onTap: _toggling ? null : () => _toggleSubscribe(title),
                child: Container(
                  height: 46,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    // 已追 = 粉紫渐变（与日历/Emby 详情页同一约定）
                    gradient: _following ? Cf.primaryGradient : null,
                    color: _following ? null : const Color(0x0FFFFFFF),
                    border: _following
                        ? null
                        : Border.all(color: const Color(0x1FFFFFFF)),
                    borderRadius: BorderRadius.circular(Cf.radiusMd),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                          _following
                              ? Icons.star_rounded
                              : Icons.star_border_rounded,
                          size: 16,
                          color: Cf.ink),
                      SizedBox(width: 6),
                      Text(_following ? '已追' : '追剧',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: Cf.ink)),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(width: 9),
            GestureDetector(
              onTap: () =>
                  launchUrl(
                      Uri.parse('https://movie.douban.com/subject/${widget.id}/'),
                      mode: LaunchMode.externalApplication),
              child: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: Cf.surface2,
                  border: Border.all(color: Cf.border),
                ),
                child: Icon(Icons.open_in_new_rounded,
                    size: 16, color: Cf.text2),
              ),
            ),
            SizedBox(width: 9),
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: Cf.surface2,
                  border: Border.all(color: Cf.border),
                ),
                child: Icon(Icons.close_rounded,
                    size: 20, color: Cf.text2),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _infoRow(String label, List<String> values) {
    final v = values.where((e) => e.trim().isNotEmpty).toList();
    if (v.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 84,
          child: Text(label,
              style: TextStyle(fontSize: 11, color: Cf.text3)),
        ),
        Expanded(
          child: Text(v.join(' / '),
              style: TextStyle(fontSize: 11, color: Cf.text2)),
        ),
      ]),
    );
  }
}
