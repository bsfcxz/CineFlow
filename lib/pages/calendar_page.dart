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
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../data/calendar_client.dart';
import '../widgets/calendar_detail_sheet.dart';
import '../state/providers.dart'
    show
        calendarClientProvider,
        calendarWeekProvider,
        sessionStoreProvider;

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

  /// **填 TMDB API Key**（国产剧集的唯一可用数据源）。
  ///
  /// ## 为什么必须让用户自己填（安全红线）
  /// TMDB key 属凭据 ⇒ **绝不能硬编码进仓库**。
  /// 与弹幕的 AppSecret 同一策略：用户自己申请、自己填，
  /// 存 `flutter_secure_storage`（Android Keystore）。
  ///
  /// ## 为什么国产剧集只能靠 TMDB（有实测证据）
  /// 用户要求"聚焦腾讯/爱奇艺/B站/优酷"，但实测：
  /// · **B站**时间线只有**动漫**（番剧/国创），没有国产真人剧
  /// · **腾讯** `pbaccess` → HTTP 200 但 **`data` 为 None**（空壳）
  /// · **爱奇艺** `videolib` → `risk_level:2` + **`data` 为 None**（风控）
  /// · **优酷** mtop → 200 但无可用剧集列表
  /// ⇒ 三家**不是"懒得做"，是拿不到数据**（它们的反爬）。
  /// 而 **TMDB** 实测能按 `air_date` 逐天给国产剧（每天 20 条 `lang=zh`）。
  ///
  /// 申请地址：<https://www.themoviedb.org/settings/api>（免费）
  Future<void> _editKey(BuildContext context) async {
    final store = ref.read(sessionStoreProvider);
    final cur = await store.loadTmdbKey() ?? '';
    if (!mounted) return;
    final ctl = TextEditingController(text: cur);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('TMDB API Key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '追剧日历的**国产剧集**数据来自 TMDB。\n'
              '免费申请：themoviedb.org → 设置 → API\n\n'
              '（Key 只存在本机安全存储，不会上传）',
              style: Cf.caption.copyWith(color: Cf.text3),
            ),
            const SizedBox(height: Cf.gap2),
            TextField(
              controller: ctl,
              // 与弹幕 AppSecret 同款处理：输入时遮蔽
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'API Key (v3 auth)',
                hintText: '32 位十六进制',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          // 清空（不再用 TMDB 时）
          if (cur.isNotEmpty)
            TextButton(
              onPressed: () async {
                await store.saveTmdbKey('');
                if (ctx.mounted) Navigator.pop(ctx, true);
              },
              child: const Text('清除'),
            ),
          FilledButton(
            onPressed: () async {
              await store.saveTmdbKey(ctl.text);
              if (ctx.mounted) Navigator.pop(ctx, true);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved == true) {
      ref.invalidate(calendarWeekProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('已保存，正在重新加载'),
          duration: Duration(seconds: 2),
        ));
      }
    }
  }

  /// **平台缓存**（`tmdbId → 中文平台名`）。
  ///
  /// ## 为什么放在 State 而不是依赖 entry 上的字段
  /// 平台是**后到的**（懒加载，见 `CalendarClient.fetchPlatforms`），
  /// 而 `CalendarEntry` 是不可变模型 ⇒ 平台到达后单独存一份，
  /// 由 UI 按 id 查表显示（避免为"补个平台"重建整周数据）。
  final _platforms = <String, String>{};

  /// 已触发过平台补查的天（防同一轮重复触发）。
  final _platformFetched = <int>{};

  /// 给**当前选中日**补查平台（懒加载）。
  ///
  /// ## 为什么必须懒加载（真机 bug 驱动）
  /// 原实现把平台补查放在 `_fetchTmdb` 里，`out.take(24)` 里 `out` 是
  /// **整周 140 条** ⇒ 只覆盖**周一**，用户选周日时永远没有平台
  /// （真机截图确认）。
  /// 且全量补会超过每源 7s deadline ⇒ 整个 TMDB 源被砍。
  Future<void> _ensurePlatforms(WeekCalendar cal, int weekday) async {
    if (_platformFetched.contains(weekday) || !mounted) return;
    _platformFetched.add(weekday);
    try {
      final key = await ref.read(sessionStoreProvider).loadTmdbKey();
      if (key == null || key.isEmpty) return;
      final day = cal.forWeekday(weekday);
      if (day.isEmpty) return;
      final got = await ref
          .read(calendarClientProvider)
          .fetchPlatforms(day, apiKey: key);
      if (!mounted || got.isEmpty) return;
      setState(() => _platforms.addAll(got));
    } catch (e) {
      debugPrint('[Calendar] 平台补查失败（非致命）: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(calendarWeekProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('追剧日历'),
        actions: [
          IconButton(
            tooltip: 'TMDB API Key（国产剧集数据源）',
            icon: const Icon(Icons.key_rounded),
            onPressed: () => _editKey(context),
          ),
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
        data: (cal) {
          // ★ 数据到达后（或切日时）触发**当天**的平台懒加载
          //   —— 用 `addPostFrameCallback` 避免在 build 里 setState
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _ensurePlatforms(cal, _selected);
          });
          return _Body(
            cal: cal,
            selected: _selected,
            platforms: _platforms,
            onSelect: (d) {
              setState(() => _selected = d);
              // 切到新的一天 ⇒ 立刻补那一天的平台
              _ensurePlatforms(cal, d);
            },
            onRefresh: () async {
              _platformFetched.clear();
              ref.invalidate(calendarWeekProvider);
            },
          );
        },
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.cal,
    required this.selected,
    required this.platforms,
    required this.onSelect,
    required this.onRefresh,
  });

  final WeekCalendar cal;
  final int selected;

  /// 平台缓存（`tmdbId → 中文平台名`，后到）。
  final Map<String, String> platforms;
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
            child: Builder(builder: (context) {
            // ★ 按类别分组 + 组内按热度降序（用户要求）
            final grouped = cal.forWeekdayGrouped(selected);
            final total = grouped.values.fold<int>(0, (a, l) => a + l.length);
            return _DayList(
              groups: grouped,
              total: total,
              weekday: selected,
              platforms: platforms,
            );
          }),
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
  const _DayList({
    required this.groups,
    required this.total,
    required this.weekday,
    required this.platforms,
  });

  /// 按类别分组的条目（组内已按热度降序）。
  final Map<CalendarCategory, List<CalendarEntry>> groups;

  /// 总条数（判断空态）。
  final int total;

  /// 当前星期（给"分组标题"用，便于将来加"周X 更新"）。
  final int weekday;

  /// 平台缓存（后到；见 `_CalendarPageState._platforms`）。
  final Map<String, String> platforms;

  @override
  Widget build(BuildContext context) {
    if (total == 0) {
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

    // ★ 按类别分组渲染（用户要求"日期下面按类别区分、综艺、动漫、剧集等"）
    //
    // 用 `ListView` + 预先展平的 children（而不是 `ListView.builder`）
    // —— 因为要在大列表里插入"分组小标题"，展平更直观且便于控制间距。
    // 条目数实测每天 20–30 条 ⇒ 一次性构建无性能问题。
    final children = <Widget>[];
    for (final c in CalendarCategory.values) {
      final list = groups[c] ?? const <CalendarEntry>[];
      if (list.isEmpty) continue;
      children.add(_CategoryHeader(category: c, count: list.length));
      for (final e in list) {
        children.add(_EntryTile(
          entry: e,
          // 平台是后到的 ⇒ 优先用缓存的（模型里的可能为空）
          platform: e.sourceId == null ? e.platform : platforms[e.sourceId] ??
              e.platform,
        ));
        children.add(const Divider(height: 1, indent: 76));
      }
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: Cf.gap3),
      children: children,
    );
  }
}

/// 类别小标题（"动漫 · 11"）。
class _CategoryHeader extends StatelessWidget {
  const _CategoryHeader({required this.category, required this.count});

  final CalendarCategory category;
  final int count;

  static const _colors = {
    CalendarCategory.anime: Color(0xFF9B59B6),
    CalendarCategory.variety: Color(0xFFE67E22),
    CalendarCategory.series: Color(0xFF3498DB),
  };

  static const _icons = {
    CalendarCategory.anime: Icons.animation_rounded,
    CalendarCategory.variety: Icons.celebration_rounded,
    CalendarCategory.series: Icons.theaters_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final color = _colors[category] ?? Cf.text2;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Cf.gap2, Cf.gap2, Cf.gap2, 6),
      child: Row(
        children: [
          Icon(_icons[category], size: 15, color: color),
          const SizedBox(width: 6),
          Text(category.label,
              style: Cf.body.copyWith(
                  fontWeight: FontWeight.w700, color: color)),
          const SizedBox(width: 6),
          Text('$count',
              style: Cf.micro.copyWith(color: Cf.text3)),
        ],
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry, this.platform});

  final CalendarEntry entry;

  /// **播放平台**（可能来自后到的缓存，故不走 `entry.platform`）。
  final String? platform;

  @override
  Widget build(BuildContext context) {
    // ★ 整行可点 ⇒ 打开详情（用户：“增加点击可以查看到剧集、综艺、动漫等的简介”）
    //
    // ⚠️ 平台 chip 内部**自己**有 InkWell ⇒ 点 chip 只跳平台，
    //    不会冒泡到这一层（Flutter 内层手势优先）。
    return InkWell(
      onTap: () => showCalendarDetail(context, entry),
      child: Padding(
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
                // ★ 来源 + 集数 + **播放平台**（用户要求"也显示播放平台"）
                Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _SourceTag(source: entry.source),
                    if (entry.episode case final ep?)
                      Text(ep,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Cf.micro.copyWith(color: Cf.accent)),
                    // 平台 chip：**可点** → 跳该平台的搜索页
                    if (platform case final p?)
                      _PlatformChip(platform: p, title: entry.displayTitle),
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
                    // 热度（用户要求"按热度显示" ⇒ 让用户看到依据）
                    if (entry.popularity case final pop?
                        when pop >= 1) ...[
                      const SizedBox(width: 8),
                      const Icon(Icons.local_fire_department_rounded,
                          size: 13, color: Color(0xFFFF7043)),
                      const SizedBox(width: 2),
                      Text(pop >= 100 ? pop.toStringAsFixed(0)
                              : pop.toStringAsFixed(1),
                          style: Cf.micro.copyWith(color: Cf.text3)),
                    ],
                  ]),
                ],
              ],
            ),
          ),
          ],
        ),
      ),
    );
  }
}

/// **播放平台标签**（可点 → 跳转该平台搜索页）。
///
/// ## 为什么用"搜索页"（见 `platformSearchUrl` 说明）
/// TMDB 给的是平台**名**，不是该平台的剧集 id ⇒ 无法拼详情页；
/// 搜索页只要剧名就能定位（用户点一下就到）。
///
/// ## 为什么用 `url_launcher` 还是 `launchUrl`
/// 本项目已有 `url_launcher`（见 pubspec）⇒ 直接用它打开外部浏览器。
class _PlatformChip extends StatelessWidget {
  const _PlatformChip({required this.platform, required this.title});

  final String platform;
  final String title;

  @override
  Widget build(BuildContext context) {
    final url = platformSearchUrl(platform, title);
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Cf.accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Cf.radiusXs),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(platform,
              style: Cf.micro.copyWith(fontSize: 10, color: Cf.accent)),
          if (url != null) ...[
            const SizedBox(width: 2),
            Icon(Icons.open_in_new_rounded, size: 10, color: Cf.accent),
          ],
        ],
      ),
    );
    if (url == null) return chip;
    return InkWell(
      onTap: () => _openPlatform(context, url, platform),
      borderRadius: BorderRadius.circular(Cf.radiusXs),
      child: chip,
    );
  }

  Future<void> _openPlatform(
      BuildContext context, String url, String platform) async {
    // 复制剧名到剪贴板（搜索页打开后用户可直接粘贴，体验更顺）
    final ok = await launchUrl(Uri.parse(url),
        mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('无法打开 $platform')),
      );
    }
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

  // ★ 2026-10-11 按用户要求聚焦国内后调整：
  //   · TMDB 升为**主力**（按 `air_date` 逐天查国产剧；实测每天 20 条 `lang=zh`）
  //   · B站 只覆盖**番剧/国创（动漫）**，实测没有国产真人剧 ⇒ 补充源
  //   · TVmaze **已删**（用户明确不要）
  //   · Bangumi 保留但本机/真机不可达（WAF 拦 TLS 指纹，UI 会显示"暂不可用"）
  //   · 腾讯/爱奇艺/优酷**不做** —— 实测三家接口都返回空壳/风控
  //     （`data` 字段为 None），见 `docs/CALENDAR-SOURCES.md`。
  //     **不是"懒得做"，是拿不到数据。**
  static const _labels = {
    'tmdb': ('TMDB', Color(0xFF01B4E4)),
    'bilibili': ('B站', Color(0xFFFB7299)),
    'bangumi': ('BGM', Color(0xFFF09199)),
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
