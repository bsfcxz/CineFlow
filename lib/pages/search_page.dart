/// 搜索页 —— Emby 聚合搜索（服务端 SearchTerm + 客户端复筛）
/// 搜索历史（本地存储）+ 热门搜索（豆瓣实时热门电影）
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../data/emby_provider.dart';
import '../data/models.dart';
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
  List<MediaItem>? _results;
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
      final api = ref.read(embyApiProvider)!;
      final items = await api.search(q, limit: 30);
      await ref.read(sessionStoreProvider).pushSearchHistory(q);
      await _loadHistory();
      if (mounted) setState(() => _results = items);
    } on MediaException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = '搜索失败，请稍后重试');
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
                            _results = null;
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
            child: _results != null || _error != null
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
                await ref.read(sessionStoreProvider).clearSearchHistory();
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
    final results = _results!;
    if (results.isEmpty) {
      return Center(
          child: Text('没有找到与「${_ctrl.text}」相关的内容',
              style: TextStyle(fontSize: 12, color: Cf.text3)));
    }
    final api = ref.read(embyApiProvider)!;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: results.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 2 / 3.45,
          ),
          itemBuilder: (context, i) => PosterCard(
              item: results[i],
              api: api,
              onTap: () => openMediaItem(context, results[i])),
        ),
        SizedBox(height: 22),
        _doubanSection(),
      ],
    );
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
