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

class _DoubanDetailSheet extends ConsumerWidget {
  const _DoubanDetailSheet({required this.id, required this.isTv, this.entry});
  final String id;
  final bool isTv;
  final DoubanEntry? entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(doubanDetailProvider((id, isTv)));
    final title = entry?.title ?? '';
    final cover = entry?.coverUrl;

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
                      borderRadius: BorderRadius.circular(9),
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
                    if (entry?.ratingText case final r?) ...[
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
                        if (entry?.rateCount case final c?)
                          Text('  $c 人评过',
                              style: TextStyle(
                                  fontSize: 10, color: Cf.text3)),
                      ]),
                    ],
                    if (entry?.subtitle case final sub? when sub.isNotEmpty)
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
                  height: 42,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: Cf.primaryGradient,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text('在媒体库中搜索「$title」',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: Cf.ink)),
                ),
              ),
            ),
            SizedBox(width: 9),
            GestureDetector(
              onTap: () =>
                  launchUrl(
                      Uri.parse('https://movie.douban.com/subject/$id/'),
                      mode: LaunchMode.externalApplication),
              child: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(9),
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
                  borderRadius: BorderRadius.circular(9),
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
