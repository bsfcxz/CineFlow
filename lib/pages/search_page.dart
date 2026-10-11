/// 搜索页 —— Emby 聚合搜索（服务端 SearchTerm + 客户端复筛）
/// 搜索历史（本地存储）+ 热门搜索（豆瓣实时热门电影）
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../data/aggregated_search.dart';
import '../douban/douban_image.dart';
import '../douban/douban_models.dart';
import '../state/douban_providers.dart';
import '../state/providers.dart';
import '../widgets/douban_detail_sheet.dart';
import '../widgets/media_cards.dart';
import 'detail_page.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key, this.initialQuery});
  final String? initialQuery;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _ctrl = TextEditingController();
  List<String> _history = const [];

  /// 聚合结果（按服务器分组；单台失败只影响那一组）。
  ///
  /// ## 为什么从 `List<MediaItem>?` 改成 `List<ServerSearchResult>?`
  /// 多账号下必须知道"每条结果来自哪台" —— 点它时要切到那台去播
  ///（`MediaItem.id` 是各服务器自己的 GUID，跨服务器无意义）。
  /// 单账号时只有一个组，UI 不显示服务器标题（见 `_serverLabel`）。
  List<ServerSearchResult>? _groups;
  bool _searching = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery case final q? when q.isNotEmpty) {
      _ctrl.text = q;
      Future.microtask(() => _search(q));
    }
    _loadHistory();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final h = await ref.read(sessionStoreProvider).loadSearchHistory();
    if (mounted) setState(() => _history = h);
  }

  Future<void> _search(String query) async {
    final q = query.trim();
    if (q.isEmpty || _searching) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      // ★★ 多账号聚合搜索（用户要求："搜索聚合 + 首页保持单服务器切换"）
      //
      // ## 为什么走 provider 而不是直接调 api.search
      // `aggregatedSearchProvider` 会**并行搜所有已登录账号**，
      // 并按服务器分组返回；单台失败只影响那一组（其余照常显示）。
      // 只有一台账号时行为与原来完全一致（一组结果）。
      final groups = await ref.read(aggregatedSearchProvider(q).future);

      // 本地历史 + 服务端上报（只用**当前会话**那台上报 ——
      // 把同一个词报到所有服务器是无意义的多余请求）
      await ref.read(sessionStoreProvider).pushSearchHistory(q);
      ref.read(embyApiProvider)?.reportSearched(q);
      await _loadHistory();

      // 全台都失败才算"搜索失败"（有一台成功就该给结果）
      final ok = groups.where((g) => g.error == null).toList();
      if (ok.isEmpty && groups.isNotEmpty) {
        if (mounted) {
          setState(() => _error = groups.first.error ?? '搜索失败');
        }
        return;
      }
      if (mounted) setState(() => _groups = groups);
    } catch (e, st) {
      // ★★ 兜底 catch **必须落日志**（本轮踩到）
      //
      // ## 原来的写法错在哪
      // ```dart
      // } catch (e) {
      //   if (mounted) setState(() => _error = '搜索失败，请稍后重试');
      // }
      // ```
      // **丢弃 `e` 且不打日志** ⇒ 真机出现"搜索失败"时 logcat
      // **一片空白**，无法定位（本轮实测：抓不到任何异常栈，
      // 只能靠逐段排除法猜）。
      //
      // ⇒ 兜底 catch 也要可见：打日志（含堆栈）+ 把原因带给用户。
      //
      // ⚠️ 不单独 `on MediaException`：它定义在 `emby_provider.dart`
      //    （实现文件 —— 见 AGENTS §7.13 的抽象泄漏缺陷）。
      //    为它 import 实现文件会**加重**那处违反（§5.1 要求 UI 只依赖
      //    `MediaProvider` 抽象）。`e.toString()` 已含 message。
      debugPrint('[Search] 聚合搜索失败: $e\n$st');
      if (mounted) setState(() => _error = '搜索失败：$e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Cf.bg,
      body: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // 搜索栏
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 16, 4),
            child: Row(children: [
              BackButton(color: Cf.text),
              Expanded(
                child: Container(
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 13),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: Cf.surface2,
                    border: Border.all(color: Cf.border),
                  ),
                  child: Row(children: [
                    Icon(Icons.search_rounded,
                        size: 16, color: Cf.text3),
                    SizedBox(width: 9),
                    Expanded(
                      child: TextField(
                        controller: _ctrl,
                        style: TextStyle(fontSize: 13),
                        textInputAction: TextInputAction.search,
                        autofocus: widget.initialQuery == null,
                        onSubmitted: _search,
                        decoration: const InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: '搜索影片 / 剧集 / 演员',
                          hintStyle:
                              TextStyle(fontSize: 13, color: Cf.text3),
                        ),
                      ),
                    ),
                    if (_ctrl.text.isNotEmpty)
                      // ⚠️ 原先是裸 GestureDetector 包 16px 图标 ——
                      // **可点区域仅 16×16**，是 48dp 标准的 1/9，
                      // 手指几乎点不中（而且它就在输入框右缘，容易误触到别处）。
                      // 改成 IconButton + 收敛视觉尺寸：命中区 48dp、图标视觉 18。
                      IconButton(
                        tooltip: '清空',
                        onPressed: () {
                          _ctrl.clear();
                          setState(() {
                            _groups = null;
                          });
                        },
                        icon: const Icon(Icons.close_rounded, size: 20),
                        color: Cf.text3,
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                            minWidth: 40, minHeight: 40),
                        padding: EdgeInsets.zero,
                      ),
                  ]),
                ),
              ),
              SizedBox(width: 10),
              GestureDetector(
                onTap: () => _search(_ctrl.text),
                child: Text('搜索',
                    style: TextStyle(
                        fontSize: 13,
                        color: Cf.accent,
                        fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
          Expanded(
            child: _groups != null || _error != null
                ? _resultView()
                : _idleView(),
          ),
        ]),
      ),
    );
  }

  /// 未搜索：历史 + 热门
  Widget _idleView() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_history.isNotEmpty) ...[
          Row(children: [
            Text('搜索历史', style: Cf.label.copyWith(fontWeight: FontWeight.w700)),
            const Spacer(),
            // 同上：原为 16px 裸 GestureDetector。这是**破坏性操作**
            // （清空历史），点不中/误触的代价更大，且无二次确认。
            IconButton(
              tooltip: '清空搜索历史',
              onPressed: () async {
                // ★ 本地 + 服务端**成对清空**（用户要求第一批第 4 项）
                //
                // ## 为什么必须清服务端
                // 用户点"清空历史"的意图是"让这些记录消失"。
                // 只清本地 ⇒ 记录仍在服务端（官方客户端照样能看到）
                // —— 用户的隐私预期被违背。
                // 先清本地（用户立刻看到消失），服务端 fire-and-forget。
                await ref.read(sessionStoreProvider).clearSearchHistory();
                ref.read(embyApiProvider)?.clearRemoteSearchHistory();
                await _loadHistory();
              },
              icon: const Icon(Icons.delete_outline_rounded, size: 20),
              color: Cf.text3,
              visualDensity: VisualDensity.compact,
              constraints:
                  const BoxConstraints(minWidth: 40, minHeight: 40),
              padding: EdgeInsets.zero,
            ),
          ]),
          const SizedBox(height: Cf.gap3),
          Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final h in _history)
                  GestureDetector(
                    onTap: () {
                      _ctrl.text = h;
                      _search(h);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        color: Cf.surface2,
                        border: Border.all(color: Cf.border),
                      ),
                      child: Text(h,
                          style: TextStyle(
                              fontSize: 11, color: Cf.text2)),
                    ),
                  ),
              ]),
          SizedBox(height: 22),
        ],
        _hotList(),
      ],
    );
  }

  Widget _hotList() {
    final hot = ref.watch(doubanHotMoviesProvider);
    return hot.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (list) {
        if (list.isEmpty) return const SizedBox.shrink();
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('热门搜索',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
          SizedBox(height: 6),
          for (var i = 0; i < list.length; i++)
            GestureDetector(
              onTap: () {
                _ctrl.text = list[i].title;
                _search(list[i].title);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(children: [
                  SizedBox(
                    width: 20,
                    child: Text('${i + 1}',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            fontStyle: FontStyle.italic,
                            color: i < 3 ? Cf.danger : Cf.text3)),
                  ),
                  SizedBox(width: 11),
                  Expanded(
                    child: Text(list[i].title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12)),
                  ),
                  if (list[i].ratingText case final r?)
                    Text('⭐ $r',
                        style: TextStyle(
                            fontSize: 10, color: Cf.warn)),
                ]),
              ),
            ),
        ]);
      },
    );
  }

  Widget _resultView() {
    if (_error != null) {
      return CfErrorView(
          message: _error!,
          onRetry: () => _search(_ctrl.text));
    }
    if (_searching) {
      return Center(
          child: CircularProgressIndicator(color: Cf.accent));
    }
    final groups = _groups!;
    // ★★ 跨服务器**合并去重**（2026-10-11）
    //
    // ## 改之前是什么
    // 按服务器**分组展示**，同一部片在两台都有 ⇒ 用户看到**两条**。
    // 实测（两台真实服务器，重叠 26.7%）：
    // ```
    // 搜「复仇者联盟」：11 条 → 只有 7 部不同的片（重复 4 条）
    // 搜「沙丘」：      36 条 → 20 部（重复 16 条）
    // 搜「海贼王」：    60 条 → 27 部（重复 33 条）
    // ```
    //
    // ## 改之后
    // 用 `groupAcrossServers` 按**外部 ID**（imdb/tmdb/tvdb）合并 ——
    // 实测能识别出「海贼王 / 海贼王真人版 / 海贼王(真人版)」
    // 这种**标题完全不同但同一部片**的情况（靠标题永远匹配不上）。
    // 多台都有时只出一个卡片 + "N 台可选"角标，点开可选源。
    final merged = groupAcrossServers(groups);
    final total = merged.length;
    if (total == 0) {
      return Center(
          child: Text('没有找到与「${_ctrl.text}」相关的内容',
              style: TextStyle(fontSize: 12, color: Cf.text3)));
    }

    // ★ 单账号时不显示服务器标题（避免"一台服务器"的无意义分组头）
    final multiServer = groups.where((g) => g.error == null).length > 1;
    // 失败提示（该台没搜到 ⇒ 必须如实说明，否则用户以为"那台没有"）
    final failed = groups.where((g) => g.error != null).toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (failed.isNotEmpty) ...[
          for (final g in failed)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(children: [
                Icon(Icons.error_outline_rounded, size: 13, color: Cf.danger),
                SizedBox(width: 5),
                Expanded(
                  child: Text('${g.label} 搜索失败：${g.error}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: Cf.danger)),
                ),
              ]),
            ),
          SizedBox(height: 10),
        ],
        // 汇总一行（用户一眼知道"去重后有多少部"）
        if (multiServer)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              '共 $total 部'
              '${merged.any((m) => m.hasMultiple) ? '，'
                  '${merged.where((m) => m.hasMultiple).length} 部多台可选' : ''}',
              style: TextStyle(fontSize: 11, color: Cf.text3),
            ),
          ),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: merged.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 2 / 3.45,
          ),
          itemBuilder: (context, i) {
            final g = merged[i];
            final hit = g.primary;
            // ★ 用**该条所属服务器**的 api 渲染海报 ——
            //   用当前会话的 api 会去错的服务器取图（404/白图）。
            return Stack(
              children: [
                PosterCard(
                  item: hit.item,
                  api: hit.api,
                  onTap: () => g.hasMultiple
                      ? _pickSource(g)
                      : _openHit(hit),
                ),
                // "N 台可选"角标（只在真的多台时有 ⇒ 单服务器用户零噪音）
                if (g.hasMultiple)
                  Positioned(
                    top: 4,
                    left: 4,
                    child: IgnorePointer(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(Cf.radiusXs),
                        ),
                        child: Text('${g.serverCount} 台可选',
                            style: const TextStyle(
                                fontSize: 9, color: Colors.white)),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        SizedBox(height: 18),
        _doubanSection(),
      ],
    );
  }

  /// **选源**：同一部片在多台都有时，让用户挑一台播放。
  ///
  /// ## 为什么不直接取第一台（plezy 的做法是"并组"但默认取首选）
  /// 两台的真实差异很大（实测）：
  /// ```
  /// iLoveHD: mkv 4K HEVC · 1.47 GB · 音轨2/字幕3
  /// HK-Emby: mp4 1080p    · 1.2 GB · 音轨1/字幕0
  /// ```
  /// ⇒ 用户可能想要字幕多的那台，也可能想要小体积的。
  /// **猜错就要用户自己回去换**，不如一次问清。
  ///
  /// ## 为什么放在搜索卡片层（而不是详情页）
  /// 调研（plezy）显示：真做聚合的项目也是**在搜索结果层选源**，
  /// 详情页用"绑定单服务器"的模型 —— 因为把 `(serverId,itemId)`
  /// 穿透详情/播放/上报三层是月级别的改造。我们沿用同一取舍。
  Future<void> _pickSource(AggregatedGroup g) async {
    final picked = await showModalBottomSheet<AggregatedHit>(
      context: context,
      backgroundColor: Cf.surface2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
            top: Radius.circular(Cf.radiusLg)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Row(children: [
                Expanded(
                  child: Text(g.primary.item.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Cf.text)),
                ),
                Text('${g.copies.length} 个来源',
                    style: TextStyle(fontSize: 11, color: Cf.text3)),
              ]),
            ),
            const Divider(height: 1),
            for (final c in g.copies)
              ListTile(
                leading: Icon(Icons.dns_outlined, size: 18, color: Cf.text2),
                title: Text(c.serverLabel,
                    style: TextStyle(fontSize: 13, color: Cf.text)),
                // 副标题用**该条的元数据**帮用户判断（分辨率/大小在详情页才有）
                subtitle: Text(
                  [
                    if (c.item.productionYear != null)
                      '${c.item.productionYear}',
                    c.item.type,
                    if (c.item.communityRating != null)
                      '★${c.item.communityRating!.toStringAsFixed(1)}',
                  ].join(' · '),
                  style: TextStyle(fontSize: 11, color: Cf.text3),
                ),
                onTap: () => Navigator.pop(ctx, c),
              ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
    if (picked != null && mounted) await _openHit(picked);
  }

  /// 打开一条聚合命中 —— **若来自另一台服务器，先切过去**。
  ///
  /// ## 为什么必须切换（而不是直接把 item 传下去）
  /// `MediaItem.id` 是**各服务器自己的 GUID**。详情页取详情、
  /// 播放器取直链、合集解析、进度上报**全部**通过
  /// `embyApiProvider`（= 当前会话）发起 —— 拿 A 服务器的 id 去
  /// B 服务器查必然 404，或者更糟：查到**另一部同 id 的片**。
  ///
  /// ## 切换的代价（如实说明）
  /// 切换会改变"当前会话"，即首页/继续观看随后显示的是新那台。
  /// 这是**有意**的：用户点了一台的资源，就应该在那台上操作。
  /// 若要保持首页不变，需要把 `(serverId, itemId)` 复合标识穿透
  /// 详情页/播放路由/上报三层 —— 风险远大于收益（且语义更绕）。
  Future<void> _openHit(AggregatedHit hit) async {
    final cur = ref.read(sessionProvider).value;
    final same = cur != null &&
        cur.serverUrl == hit.session.serverUrl &&
        cur.user.id == hit.session.user.id;
    if (!same) {
      // 切到该条所属服务器（会 invalidate embyApiProvider）
      await ref.read(sessionProvider.notifier).switchTo(hit.session);
      if (!mounted) return;
    }
    if (!mounted) return;
    openMediaItem(context, hit.item);
  }

  /// 豆瓣站内搜索结果（点开完整详情弹层）
  Widget _doubanSection() {
    final q = _ctrl.text.trim();
    if (q.isEmpty) return const SizedBox.shrink();
    final douban = ref.watch(doubanSearchProvider(q));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('豆瓣结果',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
      SizedBox(height: 10),
      douban.when(
        loading: () => Center(
            child: Padding(
          padding: EdgeInsets.all(14),
          child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(color: Cf.accent)),
        )),
        error: (e, _) => Text('$e',
            style: TextStyle(fontSize: 11, color: Cf.text3)),
        data: (list) {
          if (list.isEmpty) {
            return Text('豆瓣没有匹配的条目',
                style: TextStyle(fontSize: 11, color: Cf.text3));
          }
          return SizedBox(
            height: 172,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: list.length,
              separatorBuilder: (_, _) => SizedBox(width: 10),
              itemBuilder: (context, i) => _DoubanHitCard(hit: list[i]),
            ),
          );
        },
      ),
    ]);
  }
}


/// 豆瓣搜索命中卡（横滑）
class _DoubanHitCard extends StatelessWidget {
  const _DoubanHitCard({required this.hit});
  final DoubanSearchHit hit;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => showDoubanDetail(context,
          id: hit.id, isTv: hit.isTv),
      child: SizedBox(
        width: 88,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          DoubanImage(url: hit.coverUrl ?? '', width: 88, height: 126, radius: 9),
          SizedBox(height: 6),
          Text(hit.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w700)),
          Row(children: [
            if (hit.year != null)
              Text(hit.year!,
                  style: TextStyle(fontSize: 9, color: Cf.text3)),
            const Spacer(),
            if (hit.rate != null && hit.rate!.isNotEmpty)
              Text('⭐ ${hit.rate}',
                  style: TextStyle(
                      fontSize: 9, color: Cf.warn)),
          ]),
        ]),
      ),
    );
  }
}
