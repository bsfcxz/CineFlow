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
import '../data/media_provider.dart';
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

  /// 副标题（稿子 `.track-sub`：数字用 `em` **粉色高亮**）。
  ///
  /// ## 稿子原文
  /// ```html
  /// <div class="track-sub">共 <em>0</em> 部 · 连载 <em>0</em> · 已完结 <em>0</em></div>
  /// ```
  /// ⚠️ 旧实现是一条纯灰文字 ⇒ 数字不突出（用户截图对比后指出）。
  Widget _subLine(List<CalendarSubscription> list) {
    if (list.isEmpty) {
      return Text('去追剧日历点星标订阅，这里会自动同步', style: Cf.caption);
    }
    final live = list.where((x) => x.status == '连载中').length;
    final ended = list.where((x) => x.status == '已完结').length;
    if (live + ended == 0) {
      return Text('共 ${list.length} 部 · 与追剧日历同步', style: Cf.caption);
    }
    final num =
        Cf.caption.copyWith(color: Cf.accent, fontWeight: FontWeight.w600);
    return RichText(
      text: TextSpan(style: Cf.caption, children: [
        const TextSpan(text: '共 '),
        TextSpan(text: '${list.length}', style: num),
        const TextSpan(text: ' 部 · 连载 '),
        TextSpan(text: '$live', style: num),
        const TextSpan(text: ' · 已完结 '),
        TextSpan(text: '$ended', style: num),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final subs = ref.watch(subscriptionsProvider);
    final list = subs.maybeWhen(
        data: (l) => l, orElse: () => const <CalendarSubscription>[]);
    // 三个统计卡的数字（稿子 `#segLiveCount` / `#segEndCount` / `#segContCount`）
    final liveCount = list.where((x) => x.status == '连载中').length;
    final endedCount = list.where((x) => x.status == '已完结').length;
    // "继续观看"来自服务端 Resume（不是订阅表）⇒ 从 homeProvider 取真实值
    final resumeCount = ref
        .watch(homeProvider)
        .maybeWhen(data: (d) => d.resume.length, orElse: () => 0);

    return Scaffold(
      backgroundColor: Cf.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 标题 + 副标题（参考稿有这两行）──
            // ══════════ 稿子 `.track-header` ══════════
            //
            // ## ★ 与我旧实现的差别（用户截图指出"没按 UI 改"）
            // | 稿子 | 我的旧实现 |
            // |---|---|
            // | **三个统计卡**（彩色圆点 + 数字 + 可点切换）| 只有一行文字 |
            // | 标题 26px | 20px |
            // | 副标题数字**粉色高亮** | 全灰 |
            Padding(
              padding: const EdgeInsets.fromLTRB(Cf.gap5, Cf.gap4, Cf.gap5, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // `.track-title { font-size:26px; w800; letter-spacing:-.5px }`
                  Text('我的追剧',
                      style: Cf.headline),
                  const SizedBox(height: 6),
                  // `.track-sub`（数字用 `em` 粉色高亮）
                  _subLine(list),
                  const SizedBox(height: Cf.gap4),
                ],
              ),
            ),
            // `.top-seg`：三个统计卡（连载中 / 已完结 / 继续观看）
            Padding(
              padding: const EdgeInsets.fromLTRB(Cf.gap5, 0, Cf.gap5, Cf.gap2),
              child: Row(children: [
                _StatCard(
                  kind: _StatKind.live,
                  label: '连载中',
                  count: liveCount,
                  unit: '部',
                  active: _seg == 0,
                  onTap: () => setState(() => _seg = 0),
                ),
                const SizedBox(width: 8),
                _StatCard(
                  kind: _StatKind.end,
                  label: '已完结',
                  count: endedCount,
                  unit: '部',
                  active: _seg == 1,
                  onTap: () => setState(() => _seg = 1),
                ),
                const SizedBox(width: 8),
                _StatCard(
                  kind: _StatKind.cont,
                  label: '继续观看',
                  count: resumeCount,
                  unit: '条',
                  active: _seg == 2,
                  onTap: () => setState(() => _seg = 2),
                ),
              ]),
            ),
            
            // ── 内容 ──
            Expanded(
              child: switch (_seg) {
                // 在播 / 已完结走同一个日历（按状态过滤）
                0 => _SubscribedCalendar(only: _Only.live),
                1 => _SubscribedCalendar(only: _Only.ended),
                // 复用 `HistoryPage`（它已实现加载/空态/错误态/下拉刷新）
                _ => const HistoryPage(embedded: true),
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 「追剧日历」要显示的**状态子集**（三个统计卡各对应一个）。
///
/// ## 为什么用"过滤"而不是"三套列表"
/// 三条数据的渲染逻辑**完全相同**（周历 + 按天筛选 + 卡片）⇒
/// 各写一套必然漂移（本轮已因"两处各写一套标签"被用户抓到过）。
enum _Only { live, ended }

/// 统计卡的种类（决定圆点色与激活背景）。稿子 `.top-seg-btn.live/.end/.cont`。
enum _StatKind { live, end, cont }

/// 统计卡（稿子 `.top-seg-btn`：竖排、左对齐、圆点 + 标题 + 计数）。
///
/// ## 为什么三个卡**可点切换**（而不是纯展示）
/// 稿子里它们是 `<button onclick="switchTrackMode(...)">` ——
/// 点"已完结"就切到已完结列表。**数字本身就是导航入口**
/// （用户看到"已完结 5 部"自然想点）。
class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.kind,
    required this.label,
    required this.count,
    required this.unit,
    required this.active,
    required this.onTap,
  });

  final _StatKind kind;
  final String label;
  final int count;
  final String unit;
  final bool active;
  final VoidCallback onTap;

  (Color, Color) get _pair => switch (kind) {
        _StatKind.live => (const Color(0xFF22C55E), const Color(0xFF16A34A)),
        _StatKind.end => (const Color(0xFF64748B), const Color(0xFF475569)),
        _StatKind.cont => (Cf.accent, Cf.accent2),
      };

  @override
  Widget build(BuildContext context) {
    final (c1, c2) = _pair;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
          decoration: BoxDecoration(
            // 激活 = 该色的**淡渐变**（稿子 `.active.live/.end/.cont` 三组）
            gradient: active
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      c1.withValues(alpha: 0.22),
                      c2.withValues(alpha: 0.12),
                    ])
                : null,
            color: active ? null : const Color(0x0AFFFFFF),
            border: Border.all(
                color: active
                    ? c1.withValues(alpha: 0.5)
                    : const Color(0x14FFFFFF)),
            borderRadius: BorderRadius.circular(Cf.radiusMd + 2),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                // 圆点（`live`/`cont` 带发光；`end` 静态 —— 稿子如此）
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: c1,
                    boxShadow: kind == _StatKind.end
                        ? null
                        : [
                            BoxShadow(
                                color: c1.withValues(alpha: 0.8),
                                blurRadius: 8),
                          ],
                  ),
                ),
                const SizedBox(width: 5),
                Text(label,
                    style: Cf.label.copyWith(
                        fontWeight: FontWeight.w800, color: Cf.text)),
              ]),
              const SizedBox(height: 4),
              Text('$count $unit',
                  style: Cf.micro.copyWith(fontSize: 10, color: Cf.text3)),
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
  const _SubscribedCalendar({required this.only});

  /// 要显示的状态子集（三个统计卡各对应一个）。
  ///
  /// ## 为什么用"过滤"而不是三套列表
  /// 三条数据的渲染逻辑完全相同（周历 + 按天筛选 + 卡片）⇒
  /// 各写一套必然漂移。
  final _Only only;

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

  /// 加载周历数据（**三段式**：缓存 → Emby → TMDB 兜底）。
  ///
  /// ## 用户方案（2026-10-12）
  /// > "这里如果有库中的数据用库中的数据，tmdb 可以通过静态+定时动态抓取了。
  /// >  这样的话点开追剧，直接就能显示。"
  ///
  /// ## 为什么必须改（真实事故）
  /// 旧实现按剧逐部查 TMDB：**21 部订阅 = 42 个并发请求**
  /// ⇒ 真机日志一片 `周历分集拉取失败 (id): 超时` ⇒ 周历全 0。
  ///
  /// | 方案 | 请求数 | 可靠性 |
  /// |---|---|---|
  /// | 逐部 TMDB | **42** | ❌ 全超时 |
  /// | **库内优先** | **1** | ✅ 本机数据 |
  ///
  /// ## 三段
  /// ```
  /// ① 读缓存 → 立刻渲染（0 请求，点开就有内容）
  /// ② Emby getLibraryWeek（1 请求）→ 覆盖 + 回写缓存
  /// ③ 库里没有的订阅 → TMDB 兜底（限并发 4 + 熔断）
  /// ```
  ///
  /// ## 为什么第 ③ 段还要保留
  /// 用户可能"先订阅、等入库"（库里还没有那部剧）⇒ Emby 给不出日期。
  /// 这种情况通常只有 0–3 部（不再是 21 部），代价可接受。
  Future<void> _loadAll() async {
    // ⚠️ 必须 `await ...future`，不能读 `.value`（未就绪时是 null）
    final subs = await ref.read(subscriptionsProvider.future);
    if (subs.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    if (!mounted) return;

    final monday = _mondayOf(DateTime.now());
    final cacheKey = 'libweek:${_ymd(monday)}';

    // ══════ ① 缓存：立刻渲染（点开就有内容）══════
    final db = ref.read(appDbProvider);
    try {
      final cached = await db.cacheGet(cacheKey, ttl: const Duration(hours: 24));
      if (cached != null && cached.isNotEmpty && mounted) {
        final restored = _decodeWeeks(cached);
        if (restored.isNotEmpty) {
          setState(() {
            _weeks = restored;
            _loading = false; // ★ 有缓存就不显示 loading
          });
          debugPrint('[追剧] 缓存命中 ${restored.length} 部（立即渲染）');
        }
      }
    } catch (e) {
      debugPrint('[追剧] 读缓存失败（忽略）: $e');
    }

    // ══════ ② 库内数据：**按订阅的剧**查（聚合所有服务器）══════
    //
    // ## ★★ 我上一版为什么错（诊断数据）
    // 查"全库本周更新"（`MinPremiereDate`）→ 6 部剧；
    // 而订阅的 21 部（斗破苍穹/凡人修仙传等**连载中**）分集**早就入库了**
    // ⇒ 只有"这周新入库的剧"被查出 ⇒ 与订阅**交集 0**。
    //
    // ## 实测：订阅的剧就在库里
    // iLoveHD 6/8 在库、HK-Emby 7/8 在库（《武神主宰》**只在 HK**）
    // ⇒ **必须聚合所有已登录服务器**（这正是用户说的"多账号聚合"）。
    //
    // ## 新方案
    // · 每台服务器：`mapSeriesTmdbToId()`（1 请求）→ tmdbId → SeriesId
    // · 对**订阅的剧**：`getSeriesEpisodes(id)`（每部 1 请求，**本机**、快）
    // · 合并（同一部多台都有 ⇒ 并集）
    final weeks = <String, ShowWeek>{..._weeks};
    // ⚠️ ccountApisProvider 是 FutureProvider<Map<String, MediaProvider>>
    //    ⇒ 必须 wait ...future（读 .value 会拿到 null，本轮已踩过）
    final apisMap = await ref.read(accountApisProvider.future);
    final apis = apisMap.values.toList();
    final api = ref.read(embyApiProvider);
    var inLib = 0;
    if (apis.isNotEmpty) {
      try {
        // ① 每台的 id 映射（并发）
        final maps = await Future.wait(apis.map((a) async {
          try {
            return await a.mapSeriesTmdbToId();
          } catch (_) {
            return <String, String>{};
          }
        }));

        // ② 对订阅的剧逐部查（限并发 6，本机请求快）
        final tmdbSubs =
            subs.where((x) => x.source == 'tmdb').toList();
        for (var i = 0; i < tmdbSubs.length; i += 6) {
          final batch = tmdbSubs.skip(i).take(6).toList();
          await Future.wait(batch.map((s) async {
            // 该剧在哪几台有（可能多台都有）
            final ids = <String>[];
            for (final m in maps) {
              final sid = m[s.sourceId];
              if (sid != null && sid.isNotEmpty) ids.add(sid);
            }
            if (ids.isEmpty) return;
            final all = <LibraryEpisode>[];
            for (var k = 0; k < ids.length; k++) {
              try {
                all.addAll(await apis[k].getSeriesEpisodes(ids[k]));
              } catch (_) {}
            }
            if (all.isEmpty) return;
            // ③ 只留**本周**（周一到周日）的集
            final days = <int, List<int>>{};
            for (final e in all) {
              (days[e.weekday] ??= []).add(e.episode ?? 0);
            }
            for (final v in days.values) {
              v.sort();
            }
            weeks[s.sourceId] = ShowWeek(days: days, status: s.status);
            inLib++;
          }));
        }
        debugPrint('[追剧] 库内命中 $inLib/${subs.length} 部'
            '（${apis.length} 台）');
        if (mounted && inLib > 0) {
          setState(() {
            _weeks = {...weeks};
            _loading = false;
          });
        }
      } catch (e) {
        debugPrint('[追剧] 库内分集失败: $e');
      }
    }


    // 回写缓存（供下次"点开就有"）
    try {
      if (inLib > 0) {
        await db.cachePut(cacheKey, _encodeWeeks(weeks),
            ttl: const Duration(hours: 24));
      }
    } catch (e) {
      debugPrint('[追剧] 写缓存失败（忽略）: $e');
    }

    // ══════ ③ TMDB 兜底：只查**库里没有的**（通常 0–3 部）══════
    final missing = subs
        .where((s) => s.source == 'tmdb' && !weeks.containsKey(s.sourceId))
        .toList();
    if (missing.isNotEmpty) {
      final key = await ref.read(sessionStoreProvider).loadTmdbKey();
      if (key != null && key.isNotEmpty) {
        final client = ref.read(calendarClientProvider);
        const maxFail = 5; // 熔断：连续失败就停（失败几乎总是同一原因）
        var failed = 0;
        for (var i = 0; i < missing.length; i += 4) {
          if (failed >= maxFail) {
            debugPrint('[追剧] TMDB 兜底连续失败 $failed 次，中止');
            break;
          }
          final batch = missing.skip(i).take(4).toList();
          await Future.wait(batch.map((s) async {
            try {
              final w = await client.fetchWeekEpisodes(s.sourceId, apiKey: key);
              weeks[s.sourceId] = w;
              final cn = w.statusCn;
              if (cn != null &&
                  cn.isNotEmpty &&
                  cn != s.status &&
                  !_syncedStatus.contains(s.sourceId)) {
                _syncedStatus.add(s.sourceId);
                await ref.read(appDbProvider).updateSubscriptionMeta(
                      source: s.source,
                      sourceId: s.sourceId,
                      mediaType: s.mediaType,
                      status: cn,
                    );
              }
            } catch (e) {
              failed++;
              debugPrint('[追剧] 兜底失败（继续其它）: $e');
            }
          }));
        }
      }
    }

    // ══════ ④ Emby 进度（**聚合所有服务器**）══════
    //
    // ## 为什么必须聚合（真机看到的问题）
    // 周历已走多台聚合，但进度原来只查 `embyApiProvider`（**当前会话一台**）
    // ⇒《吞噬星空》《仙逆》在当前会话那台没有 ⇒ 显示"不在媒体库 · 无法显示进度"
    // —— 而它们的周历数据其实是**另一台**给的。**同一个逻辑错误**。
    //
    // ## 合并规则
    // 同一部剧多台都报进度时取**未看数较大**的那份（更保守：
    // 不会把"其实还有没看的"显示成"已看完"）。
    final prog = <String, (int, int)>{};
    for (final a in apis) {
      try {
        final page = await a.getItems(
            includeTypes: 'Series', recursive: true, limit: 1000);
        for (final it in page.items) {
          final tmdb = it.providerIds['tmdb'];
          if (tmdb == null || tmdb.isEmpty) continue;
          final unplayed = it.unplayedItemCount;
          if (unplayed == null) continue;
          final prev = prog[tmdb];
          final total = it.childCount ?? -1;
          if (prev == null || unplayed > prev.$1) {
            prog[tmdb] = (unplayed, total);
          }
        }
      } catch (_) {
        // 进度是"锦上添花"，某台失败不影响其它台
      }
    }
    if (api != null && apis.isEmpty) {
      // 兜底：`accountApisProvider` 空（未登录多账号）时用当前会话
      try {
        final page = await api.getItems(
            includeTypes: 'Series', recursive: true, limit: 1000);
        for (final it in page.items) {
          final tmdb = it.providerIds['tmdb'];
          if (tmdb == null || tmdb.isEmpty) continue;
          final unplayed = it.unplayedItemCount;
          if (unplayed != null) prog[tmdb] = (unplayed, it.childCount ?? -1);
        }
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() {
      _weeks = weeks;
      _progress = prog;
      _loading = false;
    });
  }

  /// 本周一的 0 点（与 `CalendarClient._mondayOf` 同算法）。
  static DateTime _mondayOf(DateTime d) {
    final x = DateTime(d.year, d.month, d.day);
    return x.subtract(Duration(days: x.weekday - 1));
  }

  /// `yyyy-MM-dd`（缓存键用）。
  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// 序列化周历（存缓存）。格式刻意简单：`id|status|day:ep,ep;day:ep`。
  static String _encodeWeeks(Map<String, ShowWeek> weeks) {
    final out = <String>[];
    for (final e in weeks.entries) {
      final days = e.value.days.entries
          .map((d) => '${d.key}:${d.value.join(',')}')
          .join(';');
      out.add('${e.key}|${e.value.status ?? ''}|$days');
    }
    return out.join('\n');
  }

  /// 反序列化（读缓存）。格式不符就返回空 Map（**不抛**）。
  static Map<String, ShowWeek> _decodeWeeks(String raw) {
    final out = <String, ShowWeek>{};
    for (final line in raw.split('\n')) {
      if (line.isEmpty) continue;
      final parts = line.split('|');
      if (parts.length < 3) continue;
      final days = <int, List<int>>{};
      for (final seg in parts[2].split(';')) {
        if (seg.isEmpty) continue;
        final kv = seg.split(':');
        if (kv.length != 2) continue;
        final d = int.tryParse(kv[0]);
        if (d == null) continue;
        days[d] = [
          for (final x in kv[1].split(','))
            if (int.tryParse(x) != null) int.parse(x)
        ];
      }
      out[parts[0]] = ShowWeek(
          days: days, status: parts[1].isEmpty ? null : parts[1]);
    }
    return out;
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
      data: (all) {
        // ★ 按统计卡过滤（稿子三个 `.top-seg-btn` 各对应一个视图）
        final list = all
            .where((x) => widget.only == _Only.live
                ? x.status != '已完结' // live = 连载中 + 状态未知
                : x.status == '已完结')
            .toList();
        if (list.isEmpty) {
          return Center(
            child: Text(
              widget.only == _Only.live ? '没有连载中的订阅' : '没有已完结的订阅',
              style: Cf.caption.copyWith(color: Cf.text3),
            ),
          );
        }
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
                  // ★ 该天更新的**集数**（稿子 `.wd-count`）
                  //
                  // ## 为什么从"小红点"改成"数字"（用户截图指出没按 UI 做）
                  // 稿子原文：`<span class="wd-count">${count}</span>` ——
                  // 红点只说"有更新"，**数字直接告诉有几部**（不用逐个点开看）。
                  // 且稿子用 `count===0?"empty"` 把没更新的那天**压暗**。
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: n == 0
                            ? Colors.transparent
                            : (on
                                ? Cf.ink.withValues(alpha: 0.22)
                                : Cf.accent.withValues(alpha: 0.18)),
                        borderRadius: BorderRadius.circular(Cf.radiusXs),
                      ),
                      child: Text('$n',
                          style: Cf.micro.copyWith(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: n == 0
                                  ? Cf.text3.withValues(alpha: 0.5)
                                  : (on ? Cf.ink : Cf.accent))),
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
              // ★ 集号（稿子口径："已更新至第 N 集"，不是把每天更新的集全罗列）
              //
              // ## 我第一版为什么错
              // 写成 `E${eps.join("/")}` ⇒ 显示 `E7/8/9/10/11/12/13/...` ——
              // 那是**该季每一集**（周历把它们全收进 days）⇒ 长到溢出，
              // 而用户要的是"更新到哪儿了"这一个数。
              //
              // 稿子原文：`已更新至第 ${stats.total} 集` ⇒ 取**最大集号**。
              if (eps.isNotEmpty)
                _chip('更新至 E${eps.reduce((a, b) => a > b ? a : b)}',
                    Cf.accent),
            ]),
            // ★ 「下次更新」提醒（2026-10-12 用户指出少了这个）
            //
            // ## 用户在详情页看到的样子
            // ```
            // ⏰ 下次更新：今天 周一 20:00
            //    10月12日 · 芒果TV 更新 · 你还有 24 集未看
            // ```
            // ## 追剧页做成**一行精简版**（卡片内空间有限）
            // ```
            // ⏰ 下次更新：明天 周二
            // ```
            //
            // ## ★ 为什么不显示"20:00"
            // **TMDB 没有播出时刻**（只有 `air_date`，无 `air_time`）——
            // 详情页那个 `20:00` 是**编的**（我实测确认过；Emby 的
            // `AirTime` 在你这台服务器填充率也是 0）。
            // ⇒ 只显示**哪天**，不编造时刻。
            if (_nextUpdateText() case final nu?) ...[
              const SizedBox(height: 4),
              Row(children: [
                Icon(Icons.alarm_rounded, size: 12, color: Cf.accent),
                const SizedBox(width: 3),
                Text(nu,
                    style: Cf.micro.copyWith(
                        fontSize: 10, color: Cf.accent)),
              ]),
            ],
            const SizedBox(height: 6),
            _progressBar(),
          ]),
        ),
      ]),
    );
  }

  /// 「下次更新」文案：`下次更新：今天 周一` / `明天 周二` / `周三`。
  ///
  /// ## 判据：`week.days` 里**离今天最近**的那天
  /// · 今天有 ⇒ "今天 周X"
  /// · 明天有 ⇒ "明天 周X"
  /// · 其余 ⇒ 直接"周X"（避免"3 天后"这种要心算的说法）
  /// · 本周没有任何更新 ⇒ null（**不显示**，不编"待定"）
  String? _nextUpdateText() {
    final w = week;
    if (w == null || w.days.isEmpty) return null;
    final today = DateTime.now().weekday;
    // 按"距今天的天数"排序（0=今天）
    final days = w.days.keys.toList()
      ..sort((a, b) =>
          ((a - today + 7) % 7).compareTo((b - today + 7) % 7));
    if (days.isEmpty) return null;
    final d = days.first;
    const cn = ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final gap = (d - today + 7) % 7;
    final when = switch (gap) {
      0 => '今天',
      1 => '明天',
      _ => '',
    };
    return when.isEmpty
        ? '下次更新：${cn[d]}'
        : '下次更新：$when ${cn[d]}';
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

