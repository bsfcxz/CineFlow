/// 排行榜 —— 豆瓣榜单（数据源：桌面「排行榜数据API」提取的 douban 三件套）
/// 分组 tab（电影/电视剧/动漫）+ 分类 chips + 金银铜排名列表
/// 点击条目 → 详情弹层 → 「在媒体库中搜索」（榜单 id 与本地库无关，搜索才是直线）
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/router.dart';
import '../core/theme.dart';
import '../douban/douban_catalog.dart';
import '../douban/douban_image.dart';
import '../douban/douban_models.dart';
import '../state/douban_providers.dart';
import '../widgets/douban_detail_sheet.dart';

class RankPage extends ConsumerStatefulWidget {
  const RankPage({super.key});

  @override
  ConsumerState<RankPage> createState() => _RankPageState();
}

class _RankPageState extends ConsumerState<RankPage> {
  DoubanGroup _group = DoubanGroup.movie;
  late String _categoryId = DoubanCatalog.defaultCategory.id;

  @override
  Widget build(BuildContext context) {
    final categories =
        DoubanCatalog.categories.where((c) => c.group == _group).toList();
    return Scaffold(
      backgroundColor: Cf.bg,
      body: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: Row(children: [
              Text('排行榜',
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w800)),
              SizedBox(width: 8),
              Text('数据来自豆瓣',
                  style: TextStyle(fontSize: 9.5, color: Cf.text3)),
              const Spacer(),
              GestureDetector(
                onTap: () => context.push(Routes.search),
                child:
                    Icon(Icons.search_rounded, size: 22, color: Cf.text2),
              ),
            ]),
          ),
          // 分组 tab
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              for (final g in DoubanGroup.values)
                Padding(
                  padding: const EdgeInsets.only(right: 14),
                  child: GestureDetector(
                    onTap: () {
                      if (_group == g) return;
                      setState(() {
                        _group = g;
                        _categoryId = DoubanCatalog.categories
                            .firstWhere((c) => c.group == g)
                            .id;
                      });
                    },
                    child: Column(children: [
                      Text(g.label,
                          style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: _group == g
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                              color:
                                  _group == g ? Cf.accent : Cf.text3)),
                      SizedBox(height: 3),
                      Container(
                        width: 18,
                        height: 2.5,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(2),
                          color: _group == g
                              ? Cf.accent
                              : Colors.transparent,
                        ),
                      ),
                    ]),
                  ),
                ),
            ]),
          ),
          // 分类 chips
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              itemCount: categories.length,
              separatorBuilder: (_, _) => SizedBox(width: 8),
              itemBuilder: (context, i) {
                final c = categories[i];
                final active = c.id == _categoryId;
                return GestureDetector(
                  onTap: () => setState(() => _categoryId = c.id),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 13),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: active
                          ? const Color(0x1F00D4FF)
                          : Cf.surface2,
                      border: Border.all(
                          color: active ? Cf.accent : Cf.border),
                    ),
                    child: Text(c.label,
                        style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: active
                                ? FontWeight.w800
                                : FontWeight.w600,
                            color:
                                active ? Cf.accent : Cf.text2)),
                  ),
                );
              },
            ),
          ),
          Expanded(child: _list()),
          Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Center(
              child: Text('数据来自豆瓣公开接口 · 仅供学习与个人使用',
                  style: TextStyle(fontSize: 9, color: Cf.text3)),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _list() {
    final rankings = ref.watch(doubanRankingsProvider(_categoryId));
    return rankings.when(
      loading: () => Center(
          child: CircularProgressIndicator(color: Cf.accent)),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.wifi_off_rounded, size: 40, color: Cf.text3),
            SizedBox(height: 12),
            Text('$e',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 11.5, color: Cf.text2, height: 1.6)),
            SizedBox(height: 16),
            OutlinedButton(
              onPressed: () =>
                  ref.invalidate(doubanRankingsProvider(_categoryId)),
              style: OutlinedButton.styleFrom(
                foregroundColor: Cf.accent,
                side: BorderSide(color: Cf.accent),
              ),
              child: Text('重试'),
            ),
          ]),
        ),
      ),
      data: (list) {
        if (list.isEmpty) {
          return Center(
              child: Text('该榜单暂无数据',
                  style: TextStyle(fontSize: 12, color: Cf.text3)));
        }
        return NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.pixels > n.metrics.maxScrollExtent - 300) {
              // 榜单一次 25 条足够浏览；触底不翻页（豆瓣限频自律）
            }
            return false;
          },
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            itemCount: list.length,
            separatorBuilder: (_, _) => SizedBox(height: 9),
            itemBuilder: (context, i) => _RankRow(
                  entry: list[i],
                  onTap: () => showDoubanDetail(context,
                      id: list[i].id, isTv: list[i].isTv ?? false, entry: list[i])),
          ),
        );
      },
    );
  }

}

/// 排名行：金银铜名次 + 海报 + 标题/元信息 + 豆瓣评分徽标
class _RankRow extends StatelessWidget {
  const _RankRow({required this.entry, required this.onTap});
  final DoubanEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final rankColor = switch (entry.rank) {
      1 => const Color(0xFFFFD34E),
      2 => const Color(0xFFC9D4E8),
      3 => const Color(0xFFE0965A),
      _ => Cf.text3,
    };
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: Cf.surface,
          border: Border.all(color: Cf.border),
        ),
        child: Row(children: [
          SizedBox(
            width: 26,
            child: Text('${entry.rank}',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: entry.rank <= 3 ? 17 : 14,
                    fontWeight: FontWeight.w900,
                    fontStyle: FontStyle.italic,
                    color: rankColor)),
          ),
          SizedBox(width: 6),
          DoubanImage(
            url: entry.coverUrl ?? '',
            width: 52,
            height: 74,
            radius: 8,
          ),
          SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text(entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w800)),
              if (entry.subtitle case final sub? when sub.isNotEmpty) ...[
                SizedBox(height: 2),
                Text(sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 10, color: Cf.text3)),
              ],
              SizedBox(height: 5),
              Row(children: [
                if (entry.ratingText case final r?) ...[
                  Icon(Icons.star_rounded,
                      size: 13, color: Cf.warn),
                  SizedBox(width: 2),
                  Text(r,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: Cf.warn)),
                  if (entry.rateCount case final c?) ...[
                    SizedBox(width: 5),
                    Text('$c 人',
                        style: TextStyle(
                            fontSize: 9, color: Cf.text3)),
                  ],
                  SizedBox(width: 8),
                ],
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 7, vertical: 1),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(5),
                    color: const Color(0x1F52B54B),
                    border: Border.all(color: const Color(0x5952B54B)),
                  ),
                  child: Text('豆瓣',
                      style: TextStyle(
                          fontSize: 8.5,
                          fontWeight: FontWeight.w700,
                          color: Cf.emby)),
                ),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}
