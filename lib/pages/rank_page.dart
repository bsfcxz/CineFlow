/// 排行榜 —— 豆瓣榜单（数据源：桌面「排行榜数据API」提取的 douban 三件套）
/// 分组 tab（电影/电视剧/动漫）+ 分类 chips + 金银铜排名列表
/// 点击条目 → 详情弹层 → 「在媒体库中搜索」（榜单 id 与本地库无关，搜索才是直线）
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/router.dart';
import '../core/theme.dart';
import '../data/calendar_client.dart';
import '../douban/douban_catalog.dart';
import '../douban/douban_image.dart';
import '../douban/douban_models.dart';
import '../state/douban_providers.dart';
import '../state/providers.dart';
import '../widgets/calendar_detail_sheet.dart';
import '../widgets/hot_skeleton.dart';
import '../widgets/douban_detail_sheet.dart';
import '../widgets/media_cards.dart';

class RankPage extends ConsumerStatefulWidget {
  const RankPage({super.key});

  @override
  ConsumerState<RankPage> createState() => _RankPageState();
}

/// **榜单来源**（用户 2026-10-12："豆瓣的还是保持现状分类…新增一个 tmdb 的"）。
enum _Source {
  douban('豆瓣'),
  tmdb('TMDB');

  const _Source(this.label);
  final String label;
}

class _RankPageState extends ConsumerState<RankPage> {
  /// 当前来源（豆瓣栏**保持现状不动**；TMDB 栏是新增的）。
  _Source _source = _Source.douban;

  // ── 豆瓣栏状态（原样）──
  DoubanGroup _group = DoubanGroup.movie;
  late String _categoryId = DoubanCatalog.defaultCategory.id;

  // ── TMDB 栏状态（新增）──
  BrowseCategory _cat = BrowseCategory.series;
  HotBoard _board = HotBoard.airing;

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
              Text('热播', style: Cf.section),
              const SizedBox(width: Cf.gap2),
              Text(_source == _Source.douban ? '豆瓣榜单' : 'TMDB 榜单',
                  style: Cf.micro),
              const Spacer(),
              // 与首页顶栏同一处缺陷：裸 GestureDetector 的可点区域
              // 只有图标本身（22×22），远小于 48dp，且无按压反馈。
              // ★ TMDB Key 入口（随时可改，不必等空态）
              if (_source == _Source.tmdb)
                IconButton(
                  tooltip: 'TMDB Key',
                  onPressed: () => _editTmdbKey(context, ref),
                  icon: const Icon(Icons.key_rounded, size: 20),
                  color: Cf.text2,
                  visualDensity: VisualDensity.compact,
                ),
              IconButton(
                tooltip: '搜索',
                onPressed: () => context.push(Routes.search),
                icon: const Icon(Icons.search_rounded, size: 24),
                color: Cf.text2,
                visualDensity: VisualDensity.compact,
              ),
            ]),
          ),
          // ★ 来源切换（豆瓣 / TMDB）—— 用户 2026-10-12 要求
          //   "豆瓣的还是保持现状分类…新增一个 tmdb 的"
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
            child: Row(children: [
              for (final sc in _Source.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () => setState(() => _source = sc),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(Cf.radiusSm),
                        color: _source == sc
                            ? Cf.accent.withValues(alpha: 0.14)
                            : Cf.surface2,
                        border: Border.all(
                            color: _source == sc ? Cf.accent : Cf.border),
                      ),
                      child: Text(sc.label,
                          style: Cf.label.copyWith(
                              fontWeight: _source == sc
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: _source == sc ? Cf.accent : Cf.text2)),
                    ),
                  ),
                ),
            ]),
          ),
          // ── 以下为**来源相关的筛选区**（豆瓣栏原样 / TMDB 栏新增）──
          if (_source == _Source.douban) ...[
            // 分组 tab（豆瓣三组，**原样**）
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
                              fontSize: 14,
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
                          borderRadius: BorderRadius.circular(4),
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
                          ? Cf.accent.withValues(alpha: 0.12)
                          : Cf.surface2,
                      border: Border.all(
                          color: active ? Cf.accent : Cf.border),
                    ),
                    child: Text(c.label,
                        style: Cf.label.copyWith(
                            fontWeight: active
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color:
                                active ? Cf.accent : Cf.text2)),
                  ),
                );
              },
            ),
          ),
          ] else ...[
            // ══════════ TMDB 栏（新增，用户 2026-10-12）══════════
            //
            // ## 类别 chips（剧集/综艺/动漫/电影）
            SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                itemCount: BrowseCategory.values.length,
                separatorBuilder: (_, _) => SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final c = BrowseCategory.values[i];
                  final active = c == _cat;
                  return _chip(
                    label: '${c.emoji} ${c.label}',
                    active: active,
                    onTap: () {
                      if (active) return;
                      setState(() {
                        _cat = c;
                        // ⚠️ 切类别**必须重置状态** —— 电影没有"在播/刚完结"
                        //    （见 `_boardsFor`），留着会请求错参数
                        _board = _boardsFor(c).first;
                      });
                    },
                  );
                },
              ),
            ),
            // 状态 chips（在播/将播/刚完结；电影为 正在上映/即将上映）
            SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                itemCount: _boardsFor(_cat).length,
                separatorBuilder: (_, _) => SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final b = _boardsFor(_cat)[i];
                  return _chip(
                    label: b.label,
                    active: b == _board,
                    onTap: () => setState(() => _board = b),
                  );
                },
              ),
            ),
          ],
          Expanded(child: _source == _Source.douban ? _list() : _tmdbGrid()),
          // ⚠️ 底部版权行：真机截图显示它与网格**贴太近**（被最后一行
          //    海报压住）⇒ 加上边距。这是排版细节，但不加就是糊在一起。
          Padding(
            padding: const EdgeInsets.only(top: Cf.gap2, bottom: Cf.gap2),
            child: Center(
              child: Text(
                  _source == _Source.douban
                      ? '数据来自豆瓣公开接口 · 仅供学习与个人使用'
                      : '数据来自 TMDB · 仅供学习与个人使用',
                  style: Cf.micro),
            ),
          ),
        ]),
      ),
    );
  }

  /// 某类别支持的状态榜单。
  ///
  /// ## ⚠️ 电影与剧集**必须分开**（这是真实差异，不是偷懒）
  /// · 剧集/综艺/动漫：TMDB 的 `with_status` 有意义
  ///   （`Returning Series` 在播 / `Planned`+`In Production` 将播 /
  ///    `Ended` 刚完结）
  /// · **电影没有"在播/完结"** ⇒ 只有 `primary_release_date` 窗口
  ///   （正在上映 / 即将上映）
  /// ⇒ 若给电影显示"在播"，点了会得到一批**不相干**的结果。
  static List<HotBoard> _boardsFor(BrowseCategory c) => c == movie
      ? const [HotBoard.showing, HotBoard.upcoming]
      : const [HotBoard.airing, HotBoard.upcoming, HotBoard.recentEnded];

  static const movie = BrowseCategory.movie;

  /// 弹出 **TMDB API Key** 输入框（用户要求）。
  ///
  /// ## ★ 安全（AGENTS.md 安全红线）
  /// **key 绝不入库**（不写 drift、不写日志、不写注释）——
  /// 只进 `flutter_secure_storage`（`SessionStore.saveTmdbKey`，与日历页同款）。
  /// 输入框用 `obscureText` 避免旁人看到。
  ///
  /// ## 保存后立刻重拉
  /// `ref.invalidate(hotBoardProvider(...))`（否则要等缓存过期才见效）。
  Future<void> _editTmdbKey(BuildContext context, WidgetRef ref) async {
    final store = ref.read(sessionStoreProvider);
    final cur = await store.loadTmdbKey() ?? '';
    if (!context.mounted) return;
    final ctl = TextEditingController(text: cur);
    // 'save' / 'clear' / 'cancel'
    final act = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: Cf.surface,
        title: const Text('TMDB API Key'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text(
            'TMDB 榜单需要 API Key。\n'
            '在 themoviedb.org → 设置 → API 免费申请。\n\n'
            'Key 只保存在本机（加密存储），不会上传、不会写进代码。',
            style: TextStyle(fontSize: 12, height: 1.5),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: ctl,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              hintText: '粘贴 API Key',
              isDense: true,
            ),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, 'cancel'),
              child: const Text('取消')),
          if (cur.isNotEmpty)
            TextButton(
                onPressed: () => Navigator.pop(c, 'clear'),
                child: const Text('清除')),
          FilledButton(
              onPressed: () => Navigator.pop(c, 'save'),
              child: const Text('保存')),
        ],
      ),
    );
    final v = ctl.text.trim();
    ctl.dispose();
    if (act == 'cancel' || act == null) return;
    if (act == 'clear') {
      await store.saveTmdbKey('');
      if (context.mounted) _toast(context, '已清除 TMDB Key');
    } else {
      if (v.isEmpty) {
        if (context.mounted) _toast(context, 'Key 为空，未保存');
        return;
      }
      await store.saveTmdbKey(v);
      if (context.mounted) _toast(context, '已保存，正在重新加载');
    }
    // 按新 key 重拉当前那一栏（不 invalidate 其它栏，省一次请求）
    ref.invalidate(hotBoardProvider((_cat, _board)));
  }

  void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 统一的 chip（分类与状态共用，避免两套样式）。
  Widget _chip({
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Cf.radiusSm),
            color: active ? Cf.accent.withValues(alpha: 0.12) : Cf.surface2,
            border: Border.all(color: active ? Cf.accent : Cf.border),
          ),
          child: Text(label,
              style: Cf.label.copyWith(
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: active ? Cf.accent : Cf.text2)),
        ),
      );

  /// TMDB 栏的网格（3 列海报 + 标题 + 评分）。
  ///
  /// ## 点卡片 → 日历详情页（`showCalendarDetail`）
  /// 那里能看简介/导演/平台，**并且能订阅**（走"先搜库"）。
  /// ⚠️ 不能进 Emby 详情页 —— 这些条目**可能不在库里**（点进去"找不到"）。
  Widget _tmdbGrid() {
    final async = ref.watch(hotBoardProvider((_cat, _board)));
    return async.when(
      // ★ 骨架屏（不是转圈）—— 首屏要 12 个请求 ≈ 12 秒，
      //   骨架用**和真实内容同样的布局**，等待期也有信息量。
      loading: () => const HotSkeleton(),
      error: (e, _) => _errorView('$e', () {
        ref.invalidate(hotBoardProvider((_cat, _board)));
      }),
      data: (list) {
        if (list.isEmpty) {
          // ⚠️ 空态要可行动：最常见的空因是**没填 TMDB key**
          return Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.travel_explore_rounded,
                        size: 40, color: Cf.text3),
                    SizedBox(height: 12),
                    // ⚠️ **不能加 `const`** —— `style` 里用了 `Cf.text2`，
                    //    而结构色是**可变 static**（主题切换会改）
                    //    ⇒ 进 const 会报 `invalid_constant`。
                    Text(
                      '这个榜单暂时没有内容',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12, color: Cf.text2, height: 1.6),
                    ),
                    const SizedBox(height: 16),
                    // ★ 主操作：**填 TMDB Key**（用户："在热播中增加
                    //   弹出 apikey 输入的框"）
                    //
                    // ## 为什么必须有这个按钮
                    // 用户已删掉「我的 → 追剧日历」入口 ⇒ TMDB Key 的
                    // **唯一填写入口也没了**，而 TMDB 栏全靠它。
                    //（旧文案还写着"请检查我的→追剧日历"，指向不存在的入口。）
                    FilledButton(
                      onPressed: () => _editTmdbKey(context, ref),
                      child: const Text('填写 TMDB Key'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: () => ref
                          .invalidate(hotBoardProvider((_cat, _board))),
                      child: const Text('重新加载'),
                    ),
                  ]),
            ),
          );
        }
        return GridView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: list.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 12,
            crossAxisSpacing: 10,
            // 海报 2:3 + 标题/评分两行
            childAspectRatio: 0.55,
          ),
          itemBuilder: (_, i) => _HotCard(entry: list[i]),
        );
      },
    );
  }

  Widget _errorView(String msg, VoidCallback onRetry) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.wifi_off_rounded, size: 40, color: Cf.text3),
            SizedBox(height: 12),
            Text(msg,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12, color: Cf.text2, height: 1.6)),
            SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: const Text('重试')),
          ]),
        ),
      );

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
                    fontSize: 12, color: Cf.text2, height: 1.6)),
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
          // 统一空态：给说明 + 可能的下一步，而不是一行冷灰字
          return const CfEmptyView(
            icon: Icons.leaderboard_outlined,
            message: '该榜单暂无数据',
            hint: '换个榜单分组试试，或稍后再来',
          );
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
                      size: 16, color: Cf.warn),
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
                    borderRadius: BorderRadius.circular(4),
                    color: const Color(0x1F52B54B),
                    border: Border.all(color: const Color(0x5952B54B)),
                  ),
                  child: Text('豆瓣',
                      style: TextStyle(
                          fontSize: 9,
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


/// TMDB 热播栏的卡片（3 列海报 + 标题 + 评分/年份）。
///
/// ## 点卡片 → **日历详情页**（`showCalendarDetail`）
/// 那里能看简介/导演/平台，**并且能订阅**（走"先搜库"那条链）。
///
/// ⚠️ **不能**进 Emby 详情页 —— 这些条目来自 TMDB，**可能不在库里**
/// （点进去会"找不到"）。这与首页 hero 正好相反：hero 是 ∩ 库内，
/// 所以那边能直接进 Emby 详情页。
class _HotCard extends StatelessWidget {
  const _HotCard({required this.entry});

  final CalendarEntry entry;

  @override
  Widget build(BuildContext context) {
    final poster = entry.posterUrl;
    return GestureDetector(
      onTap: () => showCalendarDetail(context, entry),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Cf.radiusMd),
              child: SizedBox(
                width: double.infinity,
                child: poster == null || poster.isEmpty
                    ? _fallback()
                    : Image.network(poster,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _fallback(),
                        loadingBuilder: (c, ch, pr) =>
                            pr == null ? ch : _fallback()),
              ),
            ),
          ),
          const SizedBox(height: 5),
          Text(entry.displayTitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Cf.caption.copyWith(height: 1.25)),
          const SizedBox(height: 2),
          Row(children: [
            if (entry.rating case final r? when r > 0) ...[
              const Icon(Icons.star_rounded,
                  size: 11, color: Color(0xFFF5C518)),
              const SizedBox(width: 2),
              Text(r.toStringAsFixed(1),
                  style: Cf.micro.copyWith(fontSize: 10)),
              const SizedBox(width: 5),
            ],
            if (entry.airDate case final d? when d.length >= 4)
              Text(d.substring(0, 4),
                  style: Cf.micro.copyWith(fontSize: 10, color: Cf.text3)),
          ]),
        ],
      ),
    );
  }

  Widget _fallback() => Container(
        color: Cf.surface2,
        alignment: Alignment.center,
        child: Icon(Icons.movie_outlined, color: Cf.text3),
      );
}
