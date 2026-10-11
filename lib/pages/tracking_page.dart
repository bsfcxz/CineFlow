/// **追剧**（一级 Tab）—— 用户要求：
/// "在底栏首页的右侧增加一个底栏追剧中，将我的追剧中的追剧日历和
///  首页的继续观看放在这儿"。
///
/// ## 结构（对齐参考稿 `page-tracking` 的 seg-tabs）
/// ```
/// 我的追剧                        ← 标题
/// 已连接 Emby · 自动同步播出日历…    ← 副标题
/// [📅 追剧日历 N] [▶️ 继续观看 N]    ← 两栏分页
/// ──────────────
/// ```
///
/// ## ★★ 两个子页的数据来源**刻意不同**（别合并）
/// | 子页 | 数据源 | 性质 |
/// |---|---|---|
/// | 追剧日历 | `subscriptionsProvider`（**本地** drift） | 用户**主动订阅** |
/// | 继续观看 | Emby `Resume`（服务端） | 系统**被动记录** |
///
/// 用户明确："追剧底栏中的追剧日历中的剧集则为首页我的追剧里的内容"
/// ⇒ 日历那栏**只显示订阅的**，不是整周热播榜。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../widgets/media_cards.dart';
import '../data/calendar_client.dart' show ShowWeek;
import '../data/db/app_database.dart' show CalendarSubscription;
import '../data/db/db_provider.dart' show appDbProvider;
import '../state/providers.dart';
import 'history_page.dart';

class TrackingPage extends ConsumerStatefulWidget {
  const TrackingPage({super.key});

  @override
  ConsumerState<TrackingPage> createState() => _TrackingPageState();
}

class _TrackingPageState extends ConsumerState<TrackingPage> {
  /// 当前子页：0=追剧日历，1=继续观看（与参考稿的 seg-tabs 一致）。
  int _seg = 0;

  @override
  Widget build(BuildContext context) {
    final subs = ref.watch(subscriptionsProvider);
    final subCount = subs.maybeWhen(data: (l) => l.length, orElse: () => 0);

    return Scaffold(
      backgroundColor: Cf.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 标题 + 副标题（参考稿有这两行）──
            const Padding(
              padding: EdgeInsets.fromLTRB(Cf.gap4, Cf.gap4, Cf.gap4, 2),
              child: Text('我的追剧',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Cf.gap4, 0, Cf.gap4, Cf.gap3),
              child: Text(
                subCount == 0
                    ? '去追剧日历点星标订阅，这里会自动同步'
                    : '已订阅 $subCount 部 · 与追剧日历同步',
                style: Cf.caption,
              ),
            ),

            // ── 两栏分页（参考稿的 seg-tabs）──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Cf.gap4),
              child: Row(children: [
                _SegTab(
                  icon: Icons.calendar_month_rounded,
                  label: '追剧日历',
                  badge: subCount,
                  active: _seg == 0,
                  onTap: () => setState(() => _seg = 0),
                ),
                const SizedBox(width: Cf.gap2),
                _SegTab(
                  icon: Icons.play_circle_outline_rounded,
                  label: '继续观看',
                  active: _seg == 1,
                  onTap: () => setState(() => _seg = 1),
                ),
              ]),
            ),
            const SizedBox(height: Cf.gap2),
            const Divider(height: 1),

            // ── 内容 ──
            Expanded(
              child: _seg == 0
                  ? const _SubscribedCalendar()
                  // 复用 `HistoryPage`（它已实现加载/空态/错误态/下拉刷新）
                  // ⚠️ `HistoryPage` 自带 ClimbAppBar（含返回按钮）——
                  //    在一级 Tab 里不需要返回。见 `_EmbeddedHistory` 的处理。
                  : const HistoryPage(embedded: true),
            ),
          ],
        ),
      ),
    );
  }
}

/// 分页标签（参考稿的 `.seg-tab`）。
class _SegTab extends StatelessWidget {
  const _SegTab({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  /// 角标数字（0 时不显示）。
  final int? badge;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Cf.radiusMd),
        child: Container(
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active
                ? Cf.accent.withValues(alpha: 0.14)
                : Cf.surface,
            border: Border.all(
                color: active
                    ? Cf.accent.withValues(alpha: 0.45)
                    : Cf.border),
            borderRadius: BorderRadius.circular(Cf.radiusMd),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: Cf.iconSm,
                  color: active ? Cf.accent : Cf.text2),
              const SizedBox(width: 6),
              Text(label,
                  style: Cf.label.copyWith(
                      fontWeight: FontWeight.w600,
                      color: active ? Cf.accent : Cf.text2)),
              if (badge != null && badge! > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: Cf.accent,
                    borderRadius: BorderRadius.circular(Cf.radiusXs),
                  ),
                  child: Text('$badge',
                      style: Cf.micro.copyWith(
                          color: Cf.ink, fontWeight: FontWeight.w700)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 「追剧日历」子页 —— **周历 + 按天筛选的订阅剧**。
///
/// ## 用户要求
/// > "追剧日历这儿显示周一-周日所更新的内容，增加日历哇"
/// > "订阅的剧集如果是已完结的，记得显示已完结，连载中的为连载中"
///
/// ## 数据来源（两次不同性质的请求，别混）
/// · **哪天更新** ← `fetchWeekEpisodes`（TMDB 分集 `air_date`，本地缓存 6h）
/// · **进度** ← Emby `UserData`（订阅条目**可能不在 Emby 库里** ⇒ 匹配不到就不显示）
///
/// ## 为什么"今天"默认选中
/// 用户打开追剧页最关心"今天更新什么"。周一是**视觉起点**，但选中项是今天。
class _SubscribedCalendar extends ConsumerStatefulWidget {
  const _SubscribedCalendar();

  @override
  ConsumerState<_SubscribedCalendar> createState() =>
      _SubscribedCalendarState();
}

class _SubscribedCalendarState extends ConsumerState<_SubscribedCalendar> {
  /// 当前选中的星期（1=周一 … 7=周日）。默认**今天**。
  late int _sel = DateTime.now().weekday;

  /// `sourceId → 本周播出情况 + 状态`（拉取后缓存到这里）。
  ///
  /// ## 为什么不放 provider
  /// 它是"订阅列表 × TMDB"的**派生结果**，且带 6h 缓存（在 CalendarClient 层）。
  /// 放 State 里即可 —— 重新进页面时重拉一次，
  /// 顺带把最新状态**回写**订阅表（见 `_loadAll`）。
  Map<String, ShowWeek> _weeks = {};

  /// `sourceId → (未看集数, 总集数)`。
  ///
  /// ⚠️ 总集数是 **-1 表示未知**（`MediaItem` 目前没映射 `ChildCount`）
  /// ⇒ UI 只显示"剩 N 集"，**不编造分母**（"已看 8/12" 里的 12 拿不到）。
  /// 要给 `MediaItem` 加 `ChildCount` 解析才能显示完整进度。
  Map<String, (int, int)> _progress = {};

  bool _loading = true;

  /// 已回写过状态的 sourceId（防同一轮重复写库）。
  final _syncedStatus = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAll());
  }

  Future<void> _loadAll() async {
    final subs = ref.read(subscriptionsProvider).value ?? const [];
    if (subs.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final key = await ref.read(sessionStoreProvider).loadTmdbKey();
    if (key == null || key.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final client = ref.read(calendarClientProvider);

    // ① 并发拉每部订阅剧的本周播出（TMDB）
    final weeks = <String, ShowWeek>{};
    await Future.wait(subs.map((s) async {
      if (s.source != 'tmdb') return;
      final w = await client.fetchWeekEpisodes(s.sourceId, apiKey: key);
      weeks[s.sourceId] = w;
      // ★ 状态**回写**订阅表：剧的「连载中 → 已完结」是必然发生的，
      //   不回写的话断网时永远显示旧状态。
      final cn = w.statusCn;
      if (cn != null && cn.isNotEmpty && cn != s.status &&
          !_syncedStatus.contains(s.sourceId)) {
        _syncedStatus.add(s.sourceId);
        await ref.read(appDbProvider).updateSubscriptionMeta(
              source: s.source,
              sourceId: s.sourceId,
              mediaType: s.mediaType,
              status: cn,
            );
      }
    }));

    // ② 拉 Emby 进度（尽力而为：匹配不到就不显示进度）
    final prog = <String, (int, int)>{};
    try {
      final api = ref.read(embyApiProvider);
      if (api != null) {
        // ⚠️ `getItems` 没有 `fields` 参数（它不是薄封装）；
        //    `ProviderIds` 已在 `search`/`getItems` 内部按需带上。
        final page = await api.getItems(
          includeTypes: 'Series',
          recursive: true,
          limit: 500,
        );
        for (final it in page.items) {
          final tmdb = it.providerIds['tmdb'];
          if (tmdb == null || tmdb.isEmpty) continue;
          // 实测：unplayedItemCount = 未看集数（1/8/12/38），
          //       childCount       = 总集数（1/8/12，语义正确）
          // ⇒ 能算出「已看 8/12 · 剩 4 集」
          final unplayed = it.unplayedItemCount;
          final total = it.childCount;
          if (unplayed != null) prog[tmdb] = (unplayed, total ?? -1);
        }
      }
    } catch (_) {
      // 进度是"锦上添花"，失败不影响周历
    }

    if (!mounted) return;
    setState(() {
      _weeks = weeks;
      _progress = prog;
      _loading = false;
    });
  }

  /// 某天有更新的订阅数（给周历小红点用）。
  int _countOn(int weekday) {
    var n = 0;
    for (final w in _weeks.values) {
      if (w.days.containsKey(weekday)) n++;
    }
    return n;
  }

  @override
  Widget build(BuildContext context) {
    final subs = ref.watch(subscriptionsProvider);
    return subs.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => CfErrorView(
        message: '$e',
        onRetry: () => ref.invalidate(subscriptionsProvider),
      ),
      data: (list) {
        if (list.isEmpty) return const _EmptySubs();
        final today = DateTime.now().weekday;
        // 该天要显示的订阅（按"今天/更新集号"排）
        final onDay = <CalendarSubscription>[];
        for (final s in list) {
          final w = _weeks[s.sourceId];
          if (w != null && w.days.containsKey(_sel)) onDay.add(s);
        }
        return Column(children: [
          _WeekBar(
            selected: _sel,
            today: today,
            loading: _loading,
            countOn: _countOn,
            onSelect: (d) => setState(() => _sel = d),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : onDay.isEmpty
                    ? Center(
                        child: Text('这一天没有订阅剧更新',
                            style: Cf.caption.copyWith(color: Cf.text3)))
                    : RefreshIndicator(
                        color: Cf.accent,
                        backgroundColor: Cf.surface,
                        onRefresh: () async {
                          setState(() => _loading = true);
                          await _loadAll();
                        },
                        child: ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.only(bottom: Cf.gap3),
                          itemCount: onDay.length,
                          itemBuilder: (_, i) => _SubTile(
                            sub: onDay[i],
                            week: _weeks[onDay[i].sourceId],
                            progress: _progress[onDay[i].sourceId],
                            isToday: _sel == today,
                          ),
                        ),
                      ),
          ),
        ]);
      },
    );
  }
}

/// 周一~周日的**周历横条**（含日期 + 今天高亮 + 有更新的小红点）。
class _WeekBar extends StatelessWidget {
  const _WeekBar({
    required this.selected,
    required this.today,
    required this.loading,
    required this.countOn,
    required this.onSelect,
  });

  final int selected;
  final int today;
  final bool loading;

  /// `weekday → 该天更新的订阅数`（>0 时显示小红点）。
  final int Function(int) countOn;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    // 本周日期（周一起，与 CalendarClient._mondayOf 同算法）
    final now = DateTime.now();
    final monday = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday - 1));
    const cn = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return SizedBox(
      height: 64,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Cf.gap3, vertical: 6),
        itemCount: 7,
        itemBuilder: (_, i) {
          final d = monday.add(Duration(days: i));
          final wd = i + 1;
          final on = wd == selected;
          final isToday = wd == today;
          final n = loading ? 0 : countOn(wd);
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: InkWell(
              onTap: () => onSelect(wd),
              borderRadius: BorderRadius.circular(Cf.radiusMd),
              child: Container(
                width: 52,
                decoration: BoxDecoration(
                  // Active：粉紫渐变（用户规格）；这里用主题令牌的
                  // accent→accent3，切主题时自动跟随
                  gradient: on
                      ? LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Cf.accent, Cf.accent3])
                      : null,
                  color: on ? null : Cf.surface,
                  border: Border.all(
                      color: isToday && !on ? Cf.accent : Cf.border),
                  borderRadius: BorderRadius.circular(Cf.radiusMd),
                ),
                child: Stack(children: [
                  Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(cn[i],
                            style: Cf.micro.copyWith(
                                fontSize: 11,
                                color: on ? Cf.ink : Cf.text2)),
                        const SizedBox(height: 2),
                        Text('${d.month}/${d.day}',
                            style: Cf.micro.copyWith(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: on ? Cf.ink : Cf.text)),
                      ],
                    ),
                  ),
                  // 有更新的小红点（用户规格）
                  if (n > 0)
                    Positioned(
                      top: 5,
                      right: 5,
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: on ? Cf.ink : Cf.danger,
                        ),
                      ),
                    ),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 空态（告诉用户**怎么订阅**，否则不知道去哪加）。
class _EmptySubs extends StatelessWidget {
  const _EmptySubs();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.15),
        Center(
          child: Column(children: [
            Icon(Icons.star_border_rounded, size: 44, color: Cf.text3),
            const SizedBox(height: Cf.gap2),
            Text('还没有订阅任何剧', style: Cf.caption.copyWith(color: Cf.text3)),
            const SizedBox(height: 4),
            Text('去「追剧日历」点卡片右上角的星标',
                style: Cf.micro.copyWith(color: Cf.text3)),
          ]),
        ),
      ],
    );
  }
}

/// 订阅剧卡片（周历下方列表用）。
///
/// ## 规格（用户）
/// 左 56x80 海报；右侧剧名 + `[状态] · 平台` + 进度条 + `已看 8/12 · 剩 4 集`
/// 今天更新的卡片左侧有 3px 竖条。
class _SubTile extends StatelessWidget {
  const _SubTile({
    required this.sub,
    this.week,
    this.progress,
    this.isToday = false,
  });

  final CalendarSubscription sub;
  final ShowWeek? week;

  /// `(已看集数, 总集数)`；null = Emby 里没匹配到（**不编数字**）。
  final (int, int)? progress;
  final bool isToday;

  @override
  Widget build(BuildContext context) {
    final cn = week?.statusCn ?? (sub.status.isEmpty ? null : sub.status);
    final eps = week?.days.values.expand((x) => x).toList() ?? const <int>[];
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: Cf.gap4, vertical: Cf.gap2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 今天更新 ⇒ 左侧 3px 竖条（用户规格）
        Container(
          width: 3,
          height: 80,
          margin: const EdgeInsets.only(right: 9),
          decoration: BoxDecoration(
            gradient: isToday
                ? LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Cf.accent, Cf.accent3])
                : null,
            color: isToday ? null : Colors.transparent,
            borderRadius: BorderRadius.circular(Cf.radiusXs),
          ),
        ),
        ClipRRect(
          borderRadius: BorderRadius.circular(Cf.radiusSm),
          child: SizedBox(
            width: 56,
            height: 80,
            child: sub.posterUrl.isEmpty
                ? _fb()
                : Image.network(sub.posterUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _fb(),
                    loadingBuilder: (c, ch, p) => p == null ? ch : _fb()),
          ),
        ),
        const SizedBox(width: Cf.gap3),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(sub.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Cf.title.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 5),
            Wrap(spacing: 6, runSpacing: 3, children: [
              // ★ 状态：连载中 / 已完结（用户明确要求区分）
              if (cn != null) _chip(cn, _statusColor(cn)),
              if (sub.platform.isNotEmpty) _chip(sub.platform, Cf.text2),
              // 替代"20:00"：TMDB 无播出时刻，改显示**集号**（实测有）
              if (eps.isNotEmpty) _chip('更新 E${eps.join("/")}', Cf.accent),
            ]),
            const SizedBox(height: 6),
            _progressBar(),
          ]),
        ),
      ]),
    );
  }

  Color _statusColor(String cn) => switch (cn) {
        '连载中' => Cf.success,
        '已完结' => Cf.text3,
        _ => Cf.text2,
      };

  Widget _chip(String t, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(Cf.radiusXs),
        ),
        child: Text(t, style: Cf.micro.copyWith(fontSize: 10, color: c)),
      );

  Widget _progressBar() {
    final p = progress;
    if (p == null) {
      // Emby 里没有这部剧 ⇒ **不编造进度**，如实说明
      return Text('不在媒体库 · 无法显示进度',
          style: Cf.micro.copyWith(fontSize: 10, color: Cf.text3));
    }
    final (unplayed, total) = p;
    // 总集数未知（-1）⇒ 只显示剩余，**不编分母**
    if (total <= 0) {
      return Text(unplayed == 0 ? '已看完' : '剩 $unplayed 集',
          style: Cf.micro.copyWith(
              fontSize: 10,
              color: unplayed == 0 ? Cf.success : Cf.text3));
    }
    final played = (total - unplayed).clamp(0, total);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(Cf.radiusXs),
        child: LinearProgressIndicator(
          value: total == 0 ? 0.0 : (played / total).clamp(0.0, 1.0),
          minHeight: 3,
          backgroundColor: const Color(0x1AFFFFFF),
          valueColor: AlwaysStoppedAnimation(
              unplayed == 0 ? Cf.success : Cf.accent),
        ),
      ),
      const SizedBox(height: 3),
      Text(unplayed == 0 ? '已看 $played/$total · 已追完' : '已看 $played/$total · 剩 $unplayed 集',
          style: Cf.micro.copyWith(fontSize: 10, color: Cf.text3)),
    ]);
  }

  Widget _fb() => Container(
        color: Cf.surface2,
        alignment: Alignment.center,
        child: Icon(Icons.movie_outlined, size: Cf.iconSm, color: Cf.text3),
      );
}

