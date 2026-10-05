# -*- coding: utf-8 -*-
"""批次 C：首页合集板块 + 媒体库筛选行（类型/年份客户端复筛，排序/未观看服务端重查）"""
import io

# ---------- 1) HomeData 加 collections ----------
p = 'lib/data/home_repository.dart'
s = io.open(p, encoding='utf-8').read()
s = s.replace(
    """class HomeData {
  final List<EmbyItem> featured; // 轮播（有背景图的最新条目）
  final List<EmbyItem> resume; // 继续观看
  final List<EmbyItem> latest; // 最近添加

  const HomeData({
    required this.featured,
    required this.resume,
    required this.latest,
  });""",
    """class HomeData {
  final List<EmbyItem> featured; // 轮播（有背景图的最新条目）
  final List<EmbyItem> resume; // 继续观看
  final List<EmbyItem> latest; // 最近添加
  final List<EmbyItem> collections; // 合集（BoxSet）

  const HomeData({
    required this.featured,
    required this.resume,
    required this.latest,
    this.collections = const [],
  });""")
s = s.replace(
    """    final featured =
        latest.where((i) => i.backdropImageTags.isNotEmpty).take(5).toList();

    return HomeData(
      featured: featured,
      resume: resume.take(8).toList(),
      latest: latest.take(18).toList(),
    );""",
    """    final featured =
        latest.where((i) => i.backdropImageTags.isNotEmpty).take(5).toList();

    List<EmbyItem> collections = const [];
    try {
      final page = await api.getItems(
          includeTypes: 'BoxSet',
          sortBy: 'DateCreated',
          recursive: true,
          limit: 12);
      collections = page.items;
    } catch (_) {}

    return HomeData(
      featured: featured,
      resume: resume.take(8).toList(),
      latest: latest.take(18).toList(),
      collections: collections,
    );""")
io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('home_repository ok')

# ---------- 2) 首页：合集板块（横向海报小卡） ----------
p = 'lib/pages/home_page.dart'
s = io.open(p, encoding='utf-8').read()
s = s.replace(
    """                if (d.latest.isNotEmpty)
                  CfSection(
                    title: '最近添加',""",
    """                if (d.collections.isNotEmpty)
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
                        separatorBuilder: (_, _) => const SizedBox(width: 10),
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
                    title: '最近添加',""")
io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('home collections ok')

# ---------- 3) 媒体库筛选行 ----------
p = 'lib/pages/library_page.dart'
s = io.open(p, encoding='utf-8').read()

# 3.1 状态字段
s = s.replace(
    """  bool _gridMode = true;
  String _query = '';""",
    """  bool _gridMode = true;
  String _query = '';
  String _sortBy = 'DateCreated'; // DateCreated / SortName / CommunityRating
  bool _unplayedOnly = false;
  String? _genreFilter; // 客户端复筛
  String? _yearFilter; // 客户端复筛
  bool _showFilters = false;""")

# 3.2 _reload / _loadMore 传入 sortBy + filters
s = s.replace(
    """      final page = await api.getItems(
        parentId: _viewId,
        includeTypes: _includeTypes,
        searchTerm: _query.isEmpty ? null : _query,
        startIndex: 0,
      );""",
    """      final page = await api.getItems(
        parentId: _viewId,
        includeTypes: _includeTypes,
        searchTerm: _query.isEmpty ? null : _query,
        sortBy: _sortBy,
        unplayedOnly: _unplayedOnly,
        startIndex: 0,
      );""")
s = s.replace(
    """      final page = await api.getItems(
        parentId: _viewId ?? widget.fixedParentId,
        includeTypes: _includeTypes,
        searchTerm: _query.isEmpty ? null : _query,
        startIndex: _items.length,
      );""",
    """      final page = await api.getItems(
        parentId: _viewId ?? widget.fixedParentId,
        includeTypes: _includeTypes,
        searchTerm: _query.isEmpty ? null : _query,
        sortBy: _sortBy,
        unplayedOnly: _unplayedOnly,
        startIndex: _items.length,
      );""")

# 3.3 展示列表套上客户端复筛
s = s.replace("    final shown = _items;",
    """    // 客户端复筛（LinPlayer 语料：服务端过滤不可信，此处针对已加载页做类型/年份过滤）
    final shown = _items.where((it) {
      if (_genreFilter != null && !it.genres.contains(_genreFilter)) {
        return false;
      }
      if (_yearFilter != null && '${it.productionYear}' != _yearFilter) {
        return false;
      }
      return true;
    }).toList();""")

# 3.4 工具栏：筛选行开关 + 筛选行插入
s = s.replace(
    """        return Column(children: [
          _toolbar(),
          if (widget.fixedParentId == null) _chips(list),
          const SizedBox(height: 8),
          Expanded(child: _results(api)),
        ]);""",
    """        return Column(children: [
          _toolbar(),
          if (widget.fixedParentId == null) _chips(list),
          _filterBar(list.isEmpty ? const [] : list),
          const SizedBox(height: 8),
          Expanded(child: _results(api)),
        ]);""")

# 3.5 _filterBar 实现（插到 _results 前）
old_results = "  Widget _results(MediaProvider api) {"
new_results = """  Widget _filterBar(List<EmbyView> views) {
    // 类型 / 年份选项来自已加载条目（客户端复筛）
    final genres = <String>{};
    final years = <String>{};
    for (final it in _items) {
      genres.addAll(it.genres);
      if (it.productionYear != null) years.add('\${it.productionYear}');
    }
    final genreList = genres.toList()..sort();
    final yearList = years.toList()..sort((a, b) => b.compareTo(a));
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: Row(children: [
          GestureDetector(
            onTap: () => setState(() => _showFilters = !_showFilters),
            child: Row(children: [
              Text('筛选',
                  style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: _showFilters ? Cf.accent : Cf.text3)),
              const SizedBox(width: 3),
              Icon(Icons.expand_more_rounded,
                  size: 14,
                  color: _showFilters ? Cf.accent : Cf.text3),
            ]),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () {
              setState(() => _sortBy = 'DateCreated');
              _reload();
            },
            child: _filterChip(
                '排序：\${_sortBy == 'DateCreated'
                    ? '最近添加'
                    : _sortBy == 'CommunityRating'
                        ? '评分'
                        : '名称'}',
                active: _sortBy != 'SortName' && _sortBy != 'DateCreated'),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () {
              setState(() => _unplayedOnly = !_unplayedOnly);
              _reload();
            },
            child: _filterChip('✓ 未观看', active: _unplayedOnly),
          ),
          const Spacer(),
          Text('显示 \${_items.length} / \${_total > 0 ? _total : _items.length}',
              style: const TextStyle(fontSize: 10, color: Cf.text3)),
        ]),
      ),
      if (_showFilters)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            if (genreList.isNotEmpty)
              _optionRow('类型', genreList, _genreFilter, (v) {
                setState(() => _genreFilter = v);
              }),
            if (yearList.isNotEmpty)
              _optionRow('年份', yearList, _yearFilter, (v) {
                setState(() => _yearFilter = v);
              }),
          ]),
        ),
    ]);
  }

  Widget _filterChip(String label, {bool active = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(7),
        color: active ? const Color(0x1F00D4FF) : Cf.surface2,
        border: Border.all(color: active ? Cf.accent : Cf.border),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 10.5,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active ? Cf.accent : Cf.text2)),
    );
  }

  Widget _optionRow(String label, List<String> options, String? selected,
      ValueChanged<String?> onSelect) {
    return SizedBox(
      height: 34,
      child: Row(children: [
        SizedBox(
          width: 34,
          child: Text(label,
              style: const TextStyle(
                  fontSize: 10, color: Cf.text3, fontWeight: FontWeight.w700)),
        ),
        Expanded(
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: options.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (context, i) {
              final opt = options[i];
              final active = selected == opt;
              return GestureDetector(
                onTap: () => onSelect(active ? null : opt),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(7),
                    color: active ? const Color(0x1F00D4FF) : Cf.surface2,
                    border: Border.all(
                        color: active ? Cf.accent : Cf.border),
                  ),
                  child: Text(opt,
                      style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: active
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: active ? Cf.accent : Cf.text2)),
                ),
              );
            },
          ),
        ),
      ]),
    );
  }

  Widget _results(MediaProvider api) {"""
assert old_results in s, 'results anchor not found'
s = s.replace(old_results, new_results, 1)
io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('library filter ok')
