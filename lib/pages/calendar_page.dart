/// **追剧日历页**（周视图：周一~周日，多源聚合）。
///
/// ## 用户需求（原话）
/// > "追剧日历构建，按照日期周一-周日的时间，从 Bangumi 获取 api、
/// >  TVmaze、TMDB（apikey）、B站时间线接口、trakt 中获取当日更新的剧集更新。
/// >  爱奇艺、b站、腾讯、优酷等主流平台"
///
/// ## 设计决策（都有实测依据，详见 `docs/CALENDAR-SOURCES.md`）
/// | 决策 | 依据 |
/// |---|---|
/// | **默认周一开头** | 中国习惯；Sonarr 也默认跟随区域文化 |
/// | **周视图而非月视图** | 用户明确要"周一-周日"；且"追剧"关心的是"这周有什么" |
/// | **失败源显式提示** | 一个源挂了不能让整页空白，也不能假装"今天没更新" |
/// | **不做爱奇艺/腾讯/优酷** | 实测风控/无公开接口（见证据文档） |
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../data/calendar_client.dart';
import '../state/providers.dart' show calendarWeekProvider;

/// 中式的星期名（周一开头）。
const _weekdayNames = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

class CalendarPage extends ConsumerStatefulWidget {
  const CalendarPage({super.key});

  @override
  ConsumerState<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends ConsumerState<CalendarPage> {
  /// 当前选中的星期（1=周一 … 7=周日）。默认**今天**。
  ///
  /// ## 为什么默认"今天"而不是"周一"
  /// 用户打开追剧日历，最关心的是"**今天更新什么**"。
  /// 周一作为**视觉起点**（列表从周一开始），但**选中项**是今天。
  late int _selected = DateTime.now().weekday;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(calendarWeekProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('追剧日历'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => ref.invalidate(calendarWeekProvider),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorView(
          message: '$e',
          onRetry: () => ref.invalidate(calendarWeekProvider),
        ),
        data: (cal) => _Body(
          cal: cal,
          selected: _selected,
          onSelect: (d) => setState(() => _selected = d),
          onRefresh: () async => ref.invalidate(calendarWeekProvider),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.cal,
    required this.selected,
    required this.onSelect,
    required this.onRefresh,
  });

  final WeekCalendar cal;
  final int selected;
  final ValueChanged<int> onSelect;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _WeekBar(
          cal: cal,
          selected: selected,
          onSelect: onSelect,
        ),
        // 源状态提示（失败隔离的**可见化** —— 不能让用户以为"今天没更新"）
        if (cal.failedSourceCount > 0) _SourceBanner(cal: cal),
        const Divider(height: 1),
        Expanded(
          child: RefreshIndicator(
            onRefresh: onRefresh,
            child: _DayList(entries: cal.forWeekday(selected)),
          ),
        ),
      ],
    );
  }
}

/// 周一到周日的**横向选择条**（含每天条目数 + 今天高亮）。
class _WeekBar extends StatelessWidget {
  const _WeekBar({
    required this.cal,
    required this.selected,
    required this.onSelect,
  });

  final WeekCalendar cal;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now().weekday;
    return SizedBox(
      height: 84,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Cf.gap2, vertical: 8),
        itemCount: 7,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final d = i + 1; // 1..7
          final n = cal.forWeekday(d).length;
          final isToday = d == today;
          final isSel = d == selected;
          return _DayChip(
            label: _weekdayNames[i],
            count: n,
            isToday: isToday,
            isSelected: isSel,
            // 今天是周日时显示"今天"角标更醒目
            showTodayBadge: isToday,
            onTap: () => onSelect(d),
          );
        },
      ),
    );
  }
}

class _DayChip extends StatelessWidget {
  const _DayChip({
    required this.label,
    required this.count,
    required this.isToday,
    required this.isSelected,
    required this.showTodayBadge,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool isToday;
  final bool isSelected;
  final bool showTodayBadge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bg = isSelected ? Cf.accent : Cf.surface2;
    final fg = isSelected ? Colors.white : Cf.text2;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Cf.radiusMd),
      // ★ 可点区域 ≥48dp（§6.4.1 硬性要求）
      child: Container(
        width: 62,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(Cf.radiusMd),
          border: isToday && !isSelected
              ? Border.all(color: Cf.accent, width: 1.5)
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(label,
                style: Cf.caption.copyWith(
                    color: fg, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text('$count',
                style: Cf.micro.copyWith(
                    color: isSelected ? Colors.white70 : Cf.text3)),
            if (showTodayBadge) ...[
              const SizedBox(height: 2),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: isSelected ? Colors.white24 : Cf.accent,
                  borderRadius: BorderRadius.circular(Cf.radiusXs),
                ),
                child: Text('今天',
                    style: Cf.micro.copyWith(
                        fontSize: 9,
                        color: isSelected ? Colors.white : Colors.white)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 失败的源提示（**必须显式**：否则用户以为"今天真没更新"）。
class _SourceBanner extends StatelessWidget {
  const _SourceBanner({required this.cal});

  final WeekCalendar cal;

  @override
  Widget build(BuildContext context) {
    final bad = cal.sources.where((s) => !s.ok).toList();
    return Container(
      width: double.infinity,
      color: Cf.surface2,
      padding: const EdgeInsets.symmetric(horizontal: Cf.gap2, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded, size: 15, color: Cf.text3),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${bad.map((s) => s.label).join("、")} 暂不可用'
              '（结果可能不完整）',
              style: Cf.micro.copyWith(color: Cf.text3),
            ),
          ),
        ],
      ),
    );
  }
}

/// 某一天的更新列表。
class _DayList extends StatelessWidget {
  const _DayList({required this.entries});

  final List<CalendarEntry> entries;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return ListView(
        // 必须有可滚动子项，否则 RefreshIndicator 无法下拉
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.25),
          Center(
            child: Column(
              children: [
                Icon(Icons.event_busy_rounded, size: 44, color: Cf.text3),
                const SizedBox(height: Cf.gap2),
                Text('这一天没有更新', style: Cf.caption.copyWith(color: Cf.text3)),
                const SizedBox(height: 4),
                Text('下拉可刷新', style: Cf.micro.copyWith(color: Cf.text3)),
              ],
            ),
          ),
        ],
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: Cf.gap1),
      itemCount: entries.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 76),
      itemBuilder: (context, i) => _EntryTile(entry: entries[i]),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});

  final CalendarEntry entry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: Cf.gap2, vertical: Cf.gap1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Poster(url: entry.posterUrl),
          const SizedBox(width: Cf.gap2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.displayTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Cf.body.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    _SourceTag(source: entry.source),
                    if (entry.episode case final ep?) ...[
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(ep,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Cf.micro.copyWith(color: Cf.accent)),
                      ),
                    ],
                  ],
                ),
                if (entry.rating != null && entry.rating! > 0) ...[
                  const SizedBox(height: 4),
                  Row(children: [
                    const Icon(Icons.star_rounded,
                        size: 13, color: Color(0xFFF2C94C)),
                    const SizedBox(width: 2),
                    Text(entry.rating!.toStringAsFixed(1),
                        style: Cf.micro.copyWith(color: Cf.text3)),
                  ]),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 海报（失败时显示占位，**不显示破图**）。
class _Poster extends StatelessWidget {
  const _Poster({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    const w = 52.0;
    const h = 72.0;
    final u = url;
    if (u == null || u.isEmpty) return const _PosterFallback(w: w, h: h);
    return ClipRRect(
      borderRadius: BorderRadius.circular(Cf.radiusSm),
      child: Image.network(
        u,
        width: w,
        height: h,
        fit: BoxFit.cover,
        // ★ 加载失败必须**降级为占位**，不能留破图（§6.4.1）
        errorBuilder: (_, __, ___) => const _PosterFallback(w: w, h: h),
        loadingBuilder: (context, child, p) =>
            p == null ? child : const _PosterFallback(w: w, h: h),
      ),
    );
  }
}

class _PosterFallback extends StatelessWidget {
  const _PosterFallback({required this.w, required this.h});

  final double w;
  final double h;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: Cf.surface2,
        borderRadius: BorderRadius.circular(Cf.radiusSm),
      ),
      child: Icon(Icons.movie_outlined, size: 20, color: Cf.text3),
    );
  }
}

/// 来源标签（让用户知道"这条来自哪个源"）。
class _SourceTag extends StatelessWidget {
  const _SourceTag({required this.source});

  final String source;

  static const _labels = {
    'bangumi': ('BGM', Color(0xFFF09199)),
    'tvmaze': ('TVM', Color(0xFF3C948B)),
    'bilibili': ('B站', Color(0xFFFB7299)),
    'tmdb': ('TMDB', Color(0xFF01B4E4)),
  };

  @override
  Widget build(BuildContext context) {
    final v = _labels[source] ?? (source, Cf.text3);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: v.$2.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(Cf.radiusXs),
      ),
      child: Text(v.$1,
          style: Cf.micro.copyWith(fontSize: 9, color: v.$2)),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Cf.gap4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded, size: 46, color: Cf.text3),
            const SizedBox(height: Cf.gap2),
            Text('追剧日历加载失败',
                style: Cf.body.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(message,
                textAlign: TextAlign.center,
                style: Cf.micro.copyWith(color: Cf.text3)),
            const SizedBox(height: Cf.gap3),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
