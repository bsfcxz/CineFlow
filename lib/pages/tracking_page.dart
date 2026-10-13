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

import 'dart:async';

import 'package:flutter/material.dart';
import '../data/emby_provider.dart';
import '../data/media_provider.dart';
import '../widgets/calendar_detail_sheet.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../widgets/media_cards.dart';
import '../widgets/media_tags.dart';
import '../widgets/tracking_views.dart';
import 'detail_page.dart';
// ⚠️ **不能**只 `show ShowWeek` —— 卡片转 `CalendarEntry` 时
//    还需要 `CalendarEntry` 与 `BrowseCategory`。
//    show 选择器会**屏蔽其它名字**，漏写就报 "Undefined class"
//    （编译器看不到，但文件里确实有）。
import '../data/aggregated_search.dart';
import '../data/platform_episodes.dart';
import '../data/calendar_client.dart'
    show CalendarEntry, CalendarCategory, ShowWeek;
// ⚠️ show 选择器会**屏蔽其它名字**——漏写就报 'Undefined class'
//（我已经踩过两次：CalendarEntry、AnimeTimeline）。
import '../data/db/app_database.dart'
    show AnimeTimeline, CalendarSubscription;
import '../data/db/db_provider.dart' show appDbProvider;
import '../state/providers.dart';

// ══════════════════════════════════════════════════════════════════
// 顶层工具函数（**必须在 class 之外** —— 否则 import show 导不出去）
// ══════════════════════════════════════════════════════════════════

/// **把任意来源的状态规范成中文展示值**（`连载中` / `已完结` / `未知`）。
///
/// ## ★ 为什么必须有（真机物证）
/// 状态有**四种来源**，字面量各不相同：
/// | 来源 | 值 |
/// |---|---|
/// | Emby `Status` | `Continuing` / `Ended` |
/// | 订阅表快照（`sub.status`）| 上面两者，或**空串** |
/// | TMDB | `Returning Series` / `Ended` / `Canceled` |
/// | 本地时刻表 | 已经是中文 |
///
/// 而计数/配色原来直接写 `x.status == '连载中'`
/// ⇒ 对英文值**永远不匹配** ⇒ 真机出现
/// ```
/// 共 11 部 · 连载 3 · 已完结 0      ← 「已完结」恒为 0
/// 皎洁迎宵之月 | 已完结 | ...        ← 卡片却能显示中文（走了另一条路径）
/// ```
/// ⇒ 同一个事实两处判据不同 ⇒ **必须收敛到这一个函数**。
String statusCnOf(String? raw) {
  final v = (raw ?? '').trim().toLowerCase();
  if (v.isEmpty) return '未知';
  if (v.contains('continu') || v.contains('returning')) return '连载中';
  if (v.contains('end') || v.contains('cancel')) return '已完结';
  // 已经是中文（本地时刻表/上游已转好）
  if (v.contains('连载')) return '连载中';
  if (v.contains('完结')) return '已完结';
  return '未知';
}

/// 「算连载中」的**宽松**判据（计数/周历用）：
/// `连载中` 或 `未知` 都算 —— 未知时宁可多显示周历信息，也不误判成已完结。
bool isLiveish(String? raw) {
  final cn = statusCnOf(raw);
  return cn == '连载中' || cn == '未知';
}



/// **强制重新索引三大源的更新时刻表**（供「我的 → 更新时刻表」调用）。
///
/// ## 为什么抽成顶层函数
/// 追剧页的 `_ensureTimelineIndexed` 是 **State 的私有方法**，
/// 「我的」页拿不到。而两处**必须共用同一套索引逻辑** ——
/// 否则一处改了源、另一处没改（本仓库踩过"修了但没修全"）。
///
/// ## 返回
/// 各源新增条数之和（0 = 全部失败或无新增）。
/// ## 为什么收 `WidgetRef` 而不是 `Ref`（riverpod 3 的类型约束）
/// riverpod 3 把两者分开了：`Ref`（provider 内部）/ `WidgetRef`（widget 里），
/// **它们没有公共父类**，但 `read`/`invalidate` 语义一样。
/// ⇒ 收 `Ref` 会让 widget 调用处**编译不过**
///（实测 `The argument type 'WidgetRef' can't be assigned to 'Ref'`）。
/// 唯一调用方是 UI（「我的」页按钮）⇒ 收 `WidgetRef`。
Future<int> reindexTimelines({required WidgetRef ref}) async {
  final c = ref.read(calendarClientProvider);
  final db = ref.read(appDbProvider);
  var total = 0;
  // 每个源单独 try —— 一个源挂了不该拖垮其它两个
  Future<void> run(String platform, Future<int> Function() fn) async {
    try {
      final n = await fn();
      total += n;
      debugPrint('[Timeline] $platform 强制索引完成，$n 条');
    } catch (e) {
      debugPrint('[Timeline] $platform 强制索引失败: $e');
    }
  }

  // 顺序：先便宜后贵（B站 1 请求 / 爱奇艺 1 请求 / 优酷 1+N）
  await run('bilibili', () => c.indexAnimeTimeline(db: db));
  await run('iqiyi', () => c.indexIqiyiTimeline(db: db));
  await run('youku', () => c.indexYoukuTimeline(db: db));
  return total;
}

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
    final live = list.where((x) => isLiveish(x.status)).length;
    final ended = list.where((x) => !isLiveish(x.status)).length;
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
    // ★ 库内集数（由子级 `_loadAll` 写入 → 这里读；
    //   见 `libraryEpisodeCountProvider` 的说明）。
    //   已完结网格的"全 N 集"与详情页的「已入库」都用它。
    final libCount = ref.watch(libraryEpisodeCountProvider);
    final list = subs.maybeWhen(
        data: (l) => l, orElse: () => const <CalendarSubscription>[]);
    // 三个统计卡的数字（稿子 `#segLiveCount` / `#segEndCount` / `#segContCount`）
    final liveCount = list.where((x) => isLiveish(x.status)).length;
    final endedCount = list.where((x) => !isLiveish(x.status)).length;
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
                // 0 连载中：**保留周历**（周几更新对连载剧有意义）
                0 => _SubscribedCalendar(only: _Only.live),
                // 1 已完结：**3 列海报网格，不带日历**（用户截图规格）
                //    已完结的剧不会再更新 ⇒ 周历毫无意义
                1 => _FinishedView(
                    subs: list.where((x) => !isLiveish(x.status)).toList(),
                    libCount: libCount,
                  ),
                // 2 继续观看：**横卡列表**（聚合所有服务器）
                _ => const _ContinueView(),
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 「已完结」视图包装（把订阅表转成 `FinishedGrid` 需要的形状）。
class _FinishedView extends ConsumerWidget {
  const _FinishedView({required this.subs, required this.libCount});

  /// **已完结**的订阅（上层已过滤好；这里不再筛一次，
  /// 避免"两处各筛一套"导致口径不一致）。
  final List<CalendarSubscription> subs;

  /// `sourceId → 库内集数`（来自追剧页第 ② 段）。
  final Map<String, int> libCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FinishedGrid(
      items: subs,
      // ★ 集数用**库内实际集数**（`_libCount`，追剧页第 ② 段顺手记下的）
      //    拿不到就不显示（"宁可不显示，也不编数字"）。
      episodeCountOf: (id) => libCount[id],
      onTap: (sub) => showCalendarDetail(context, _subToEntry(sub)),
    );
  }
}

/// 「继续观看」视图包装（**聚合所有已登录服务器**）。
///
/// ## 为什么不用 `HistoryPage`
/// 它是通用的 3 列海报网格；用户要的是稿子里的**横卡**（`.cont-card`：
/// 130×74 缩略图 + 标题 + 进度条 + 百分比）。
/// 且 `HistoryPage` 只查**当前会话一台**，用户明确要求"继续观看也要聚合"。
class _ContinueView extends ConsumerWidget {
  const _ContinueView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(aggregatedResumeProvider);
    final api = ref.watch(embyApiProvider);
    return async.when(
      loading: () => Center(child: CircularProgressIndicator(color: Cf.accent)),
      error: (e, _) => CfErrorView(
        message: e is MediaException ? e.message : '加载失败',
        onRetry: () => ref.invalidate(aggregatedResumeProvider),
      ),
      data: (items) => RefreshIndicator(
        color: Cf.accent,
        backgroundColor: Cf.surface,
        onRefresh: () => ref.refresh(aggregatedResumeProvider.future),
        child: ContinueList(
          items: items,
          api: api,
          onTap: (it) => openMediaItem(context, it),
        ),
      ),
    );
  }
}

/// 订阅 → `CalendarEntry`（`showCalendarDetail` 需要的类型）。
///
/// ## 为什么在调用侧转（而不是改 `showCalendarDetail` 签名）
/// 那个函数被 **3 处**复用（日历页/分类浏览/热播页），它们手上都是
/// `CalendarEntry`。为一个调用点改公共签名会波及它们。
CalendarEntry _subToEntry(CalendarSubscription sub) => CalendarEntry(
      title: sub.title,
      titleCn: sub.titleCn.isEmpty ? null : sub.titleCn,
      source: sub.source,
      sourceId: sub.sourceId,
      posterUrl: sub.posterUrl.isEmpty ? null : sub.posterUrl,
      platform: sub.platform.isEmpty ? null : sub.platform,
      // ⚠️ `CalendarEntry.category` 是 `CalendarCategory`（3 档），
      //    不是 `BrowseCategory`（6 档）—— 两者维度不同。
      category: switch (sub.category) {
        'anime' => CalendarCategory.anime,
        'variety' => CalendarCategory.variety,
        _ => CalendarCategory.series,
      },
      airDate: sub.lastAirDate.isEmpty ? null : sub.lastAirDate,
    );

/// 「追剧日历」要显示的**状态子集**。
///
/// ## ★ 为什么现在只剩一个值（曾经有 `ended`）
/// 用户要求"已完结的显示成 3 列海报网格，**不带日历**"⇒
/// 已完结改走 `FinishedGrid`，不再复用周历视图
/// ⇒ `_Only.ended` 成了**死分支**，删掉。
/// 保留枚举而不是直接去掉参数：周历视图**语义上仍只服务"连载中"**，
/// 留一个值比留一个 bool 更能表达"这是状态过滤"。
enum _Only { live }

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

  /// sourceId → **下次更新日**（yyyy-MM-dd；第 ② 段顺手算）。
  Map<String, String> _libNext = {};

  /// `sourceId → **库内平台名**`（订阅表没平台时用它补 —— 时刻标签要用）。
  Map<String, String> _libPlat = {};

  /// `sourceId → **库内最大集号**`（卡片"更新至 EN"用 —— **以库为准**）。
  Map<String, int> _libMaxEp = {};

  /// `sourceId → 时刻表条目`（B站官方索引；决定卡片的精确时刻）。
  Map<String, AnimeTimeline> _timeline = {};

  /// `sourceId → 平台侧信息`（周几 / 平台集数 / 是否在播 / 播出平台）。
  ///
  /// 数据源是**内置弹幕源**（见 `_loadPlatform`）；
  /// 空 Map = 还没拿到 / 未配置弹幕源 —— 卡片据此退回库内口径。
  Map<String, PlatformEpisodes?> _platform = {};

  /// `sourceId → TMDB 的剧集状态`（`Ended` / `Returning Series` …）。
  ///
  /// ## ★ 为什么与 `_weeks` **分开存**（真机实证）
  /// `_weeks` 来自 `fetchWeekEpisodes`（**2 次** TMDB 请求），
  /// 实测频繁超时：`[Calendar] 周历分集拉取失败 (1423191): 超时`
  /// ⇒ 周历失败会**连带状态也拿不到** ⇒ 退回 Emby 的过期 `Status`
  /// ⇒ 「体能之巅」TMDB 说 `Ended`，卡片却显示"连载中"。
  ///
  /// 现在状态**单独查**（`fetchTvStatus`，1 次请求 / 6s 超时）
  /// ⇒ 周历挂了状态照样准。这是 §6.9.1「取数失败 ≠ 数据为空」。
  Map<String, String> _tmdbStatus = {};

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
    // `sourceId → 库内集数`（本段填充，见 `_libCount` 的说明）
    final libCount = <String, int>{};
    // `sourceId → 下次更新日 yyyy-MM-dd`（本段顺手算，零额外请求）
    final libNext = <String, String>{};
    // `sourceId → 库内平台名`（订阅表没平台时用它补 —— 时刻标签要用）
    final libPlat = <String, String>{};
    // `sourceId → 库内最大集号`（卡片"更新至 EN"用 —— **以库为准**）
    final libMaxEp = <String, int>{};
    // `sourceId → (已看, 总)` 进度（第 ② 段用 `sum.unplayedCount` 填）。
    //
    // ⚠️ 必须**声明在第 ② 段之前**，否则作用域不够。
    // ⚠️ 第 ④ 段的旧 `getItems(limit:1000)` 反查**已废** ——
    //    那条链有截断 bug（HK 5711 部 ⇒ 只取前 1000），
    //    现在改用逐部精确的 `unplayedCount`（见第 ② 段的说明）。
    // ⚠️ **当前无 UI 消费方**（2026-10-13）。
    // 原本给卡片底部"已看 X/Y"用，但用户要求改成
    // 「已入库集数 · 平台更新数」（见 `_libraryBar`）⇒ 那行不再需要它。
    // **保留计算**的理由：它来自 `sum.unplayedCount`（第 ② 段顺手得来，
    // 零额外请求），且"继续观看"将来可能要按未看数排序。
    final prog = <String, (int, int)>{};
    final api = ref.read(embyApiProvider);
    var inLib = 0;
    if (apis.isNotEmpty) {
      try {
        // ① 每台的 id 映射（并发）
        final List<Map<String, SeriesRef>> maps =
        await Future.wait(apis.map((a) async {
          try {
            return await a.mapSeriesTmdbToId();
          } catch (_) {
            return <String, SeriesRef>{};
          }
        }));

        // ★ **平台侧信息**（周几 / 平台集数）—— 与库内集数**并行**拿。
        //
        // ## 为什么要"平台数 + 库内数"都显示（用户明确要求）
        // > "显示平台数和库内数，这样我知道我库内的集数，
        // >  也就可以去获取没在库的数了。"
        // ⇒ 两数相减 = **你缺几集**，用户可据此去补。
        //
        // ## 为什么放在这里（而不是单独一段）
        // 它和第 ② 段用**同一份** `subs`（订阅列表），放一起省一次遍历；
        // 且 `_loadAll` 内顺序执行，`await` 它会拖长首屏 ⇒ 用**不阻塞**的方式：
        // 先**不 await**，让它在后台跑完再 setState（见下面的 `_loadPlatform`）。
        unawaited(_loadPlatform(subs));
        // ★ TMDB 状态也**后台**拉（独立于周历；见 `_tmdbStatus`）
        unawaited(_loadTmdbStatus());

        // ② 对订阅的剧逐部查（限并发 6，本机请求快）
        final tmdbSubs =
            subs.where((x) => x.source == 'tmdb').toList();
        for (var i = 0; i < tmdbSubs.length; i += 6) {
          final batch = tmdbSubs.skip(i).take(6).toList();
          await Future.wait(batch.map((s) async {
            // 该剧在哪几台有（可能多台都有）
            // ★★ **`(api, seriesId)` 必须成对**（2026-10-13 修真实 bug）
            //
            // ## 原来的错：平行数组 + 下标
            // `maps[k]` 对应 `apis[k]`，但**某台没有这部剧时不 push**
            // ⇒ `ids` 比 `maps` 短 ⇒ 后面用 `ids` 的下标去索引 `apis` 会**错位**。
            //
            // ## 真机物证（用户报障"在媒体库中却显示不在媒体库"）
            // `apis[0]`=iLoveHD（**离线**）、`apis[1]`=HK-Emby（在线）
            // ⇒ `maps[0]={}`、`maps[1]`=4997 条
            // ⇒ 「凡人修仙传」只在 HK ⇒ `ids=['2749504']`（下标 0）
            // ⇒ 循环用 `apis[0]`（**离线的 iLoveHD**）去查 ⇒ 失败
            // ⇒ 显示"不在媒体库"。
            //
            // ⇒ 让**数据自己带着来源**，从类型上杜绝错位。
            final ids = <(MediaProvider, String)>[];
            // ★ 并用**库内平台**补订阅表的空平台
            //
            // ## 为什么需要（用户要卡片上的 `20:00` 时刻标签）
            // 时刻由 `platformAirTime(平台)` 推出 ⇒ 平台为空就没有时刻。
            // 订阅源（TMDB/B站/tgmeng）常常没给平台；库内的 `Studios`
            // **实测就是播出平台**（Tencent Video / iQiyi / Mango TV / CCTV…）。
            String? libPlatform;
            for (var mi = 0; mi < maps.length; mi++) {
              final rf = maps[mi][s.sourceId];
              if (rf == null || rf.seriesId.isEmpty) continue;
              // `maps[mi]` 来自 `apis[mi]`（两者同序，见上面的构造）
              ids.add((apis[mi], rf.seriesId));
              libPlatform ??= rf.platform;
            }
            if (libPlatform != null && libPlatform.isNotEmpty) {
              libPlat[s.sourceId] = libPlatform;
            }
            if (ids.isEmpty) return;
            // ★★ 改用 `getLibrarySummary`（**一个请求拿全部**）
            //
            // ## 为什么换（真机实证的矛盾）
            // ```
            // 卡片：更新至 E239            ← TMDB 周历（错）
            // 详情页：已入库 203 集 / 第 203 集  ← 库内（对）
            // ```
            // 根因：`getSeriesEpisodes` **会过滤掉没有 `PremiereDate` 的集**
            //（《吞噬星空》33 集全无日期 ⇒ 返回空），
            // 而 `getLibrarySummary` 不会 ⇒ 同一部剧、两个函数、两个数。
            // ⇒ 统一到 `getLibrarySummary`（它与详情页**同源同口径**）。
            // ══════ 聚合所有服务器（用户要求"单台也能显示 + 多台自动聚合"）══════
            //
            // ## 两条独立的最优
            // · **基准**（集数/集号/周历/下次更新）：取 `episodeCount` **最大**的台
            // · **进度**（未看数）：优先用基准那台的；基准没有就找**有数据**的台
            //
            // ⚠️ **分母必须与分子同源**：`已看 X / Y` 的 X 与 Y 必须来自**同一台**，
            //    否则会出现"已看 12/193"来自两台这种假数据。
            //    ⇒ 换台取进度时，**它的 episodeCount 一起用**。
            final sums = <LibrarySummary>[];
            for (final (entApi, entId) in ids) {
              try {
                final r0 = await entApi.getLibrarySummary(entId);
                if (r0 != null && r0.episodeCount > 0) sums.add(r0);
              } catch (_) {}
            }
            if (sums.isEmpty) return;
            // 基准：集数最大
            var sum = sums.first;
            for (final r0 in sums) {
              if (r0.episodeCount > sum.episodeCount) sum = r0;
            }
            // 进度：基准有就用；否则找"未看最少"的那台（= 用户看得最远的）
            //  —— 单台有进度时自然就是它（用户要的"单台也能显示"）。
            if (sum.unplayedCount == null) {
              LibrarySummary? bestProg;
              for (final r0 in sums) {
                if (r0.unplayedCount == null) continue;
                if (bestProg == null || r0.unplayedCount! < bestProg.unplayedCount!) {
                  bestProg = r0;
                }
              }
              if (bestProg != null) sum = bestProg;
            }
            if (sum.episodeCount == 0) return;

            // ① 已入库集数（**以库为准**）
            libCount[s.sourceId] = sum.episodeCount;
            // ★ **进度**（用户："单台也能显示"）
            //
            // ## 为什么在这里算（而不是第 ④ 段）
            // 第 ④ 段用 `getItems(limit:1000)` 反查 —— 那条链有**截断 bug**
            // （HK 5711 部 ⇒ 只取前 1000 ⇒ 一斩苍穹查不到 ⇒ 卡片显示
            //  "不在媒体库 · 无法显示进度"）。
            // `sum.unplayedCount` 是**逐部精确**的（来自该剧自己的
            // `/Shows/{id}/Episodes`）⇒ **不受任何 limit 影响**。
            if (sum.unplayedCount != null && sum.episodeCount > 0) {
              final unplayed = sum.unplayedCount!.clamp(0, sum.episodeCount);
              prog[s.sourceId] = (sum.episodeCount - unplayed, sum.episodeCount);
            }
            // ② 库内最大集号 ⇒ 卡片"更新至 EN"
            if (sum.lastEpisode != null && sum.lastEpisode! > 0) {
              libMaxEp[s.sourceId] = sum.lastEpisode!;
            }
            // ③ 库内下次更新日
            if (sum.nextAirDate != null && sum.nextAirDate!.isNotEmpty) {
              libNext[s.sourceId] = sum.nextAirDate!;
            }
            // ④ 周历（只含**带日期**的集；没日期时为空 ⇒ 退回 TMDB 周历）
            if (sum.days.isNotEmpty) {
              weeks[s.sourceId] = ShowWeek(
                  days: sum.days, status: s.status);
            }
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
    // ★ 查时刻表（0 网络，只读本地）
    await _loadTimelineHits();

    // ★ 库内集数写进 provider（头部与详情页要读；见该 provider 的说明）
    ref.read(libraryEpisodeCountProvider.notifier).set(libCount);
    setState(() {
      _weeks = weeks;
      _libNext = libNext;
      _libPlat = libPlat;
      _libMaxEp = libMaxEp;
      _loading = false;
    });

    // ══════ ⑤ 动漫更新时刻表（用户建议："定期在这儿索引"）══════
    //
    // ## 触发策略
    // 打开追剧页时：**表为空或超过 24h** ⇒ 后台索引一次。
    // 不做系统级定时任务 —— 移动端系统定时不可靠（会被杀后台），
    // 而时刻极少变（用户："时间一般不会更改的，你固定住就好"）
    // ⇒ "打开时按需刷新"就够，且**不阻塞 UI**（`await` 放在最后）。
    await _ensureTimelineIndexed();

    // ★ 写底栏角标（稿子 `updateNavBadge()`：今日更新的剧集数）
    //
    // ⚠️ 必须**与周历用同一份 `_weeks`** —— 各算各的会让
    //    底栏显示 3、点进去看到 2（用户已因此报障过一次）。
    _syncNavBadge(weeks, subs);
  }

  /// 确保**动漫更新时刻表**已索引（表为空或超 24h 才刷）。
  ///
  /// ## 为什么 24h
  /// 时刻极少变（用户："时间一般不会更改的，你固定住就好"）。
  /// 索引 115 部只需 1 个请求 ⇒ 24h 一次的成本可忽略。
  ///
  /// ## 失败不抛
  /// 索引失败只是"没有精确时刻"⇒ 回落平台惯例，**不影响周历**。
  /// 确保三大源的更新时刻表已索引（**按平台 TTL**）。
  ///
  /// `force: true` ⇒ **跳过 TTL 判定**，强制重跑
  ///（与「我的 → 更新时刻表」的 `reindexTimelines` 语义一致）。
  Future<void> _ensureTimelineIndexed({bool force = false}) async {
    final c = ref.read(calendarClientProvider);
    final db = ref.read(appDbProvider);
    var total = 0;
    // ★ **每个平台各判自己的新鲜度**（不能用一个全局 TTL）
    //
    // ## 真机踩到的 bug
    // 原实现：`at = 全表 max(updated_at)` ⇒ B站索引过一次后，
    // 整个 if (fresh) return **把爱奇艺/优酷一起跳过**
    // ⇒ 新加的平台永远不索引（dump 证实：只有 B站时刻生效）。
    Future<void> run(String platform, Future<int> Function() fn) async {
      try {
        final at = await db.timelineIndexedAt(platform: platform);
        final now = DateTime.now().millisecondsSinceEpoch;
        const day = 24 * 60 * 60 * 1000;
        // ⚠️ `force` 时跳过 TTL —— 手动刷新要求立刻生效
        if (!force && at != null && now - at < day) {
          debugPrint('[追剧] $platform 时刻表还新鲜（跳过）');
          return;
        }
        final n = await fn();
        total += n;
        // ★ **每平台各打一行** —— 原来只有汇总
        //   （`本次新增 N 条`），排查时分不清哪个源没工作。
        //   实测踩到：一直"还新鲜"，看不出表里到底有没有数据。
        debugPrint('[追剧] $platform 索引完成，新增 $n 条');
      } catch (e) {
        debugPrint('[追剧] $platform 索引失败（继续）: $e');
      }
    }

    // ## 顺序：先便宜后贵
    // · **B站** 1 个请求（官方时间表，115 部）
    // · **爱奇艺** 1 个请求（频道 JSON，两段式解析 100%）
    // · **优酷** 1 + N（频道页 + 逐剧详情页，限并发 4）—— 最准但最贵
    //
    // ## 腾讯为什么不在列（穷尽式验证过，见 CalendarClient 的注释）
    await run('bilibili', () => c.indexAnimeTimeline(db: db));
    await run('iqiyi', () => c.indexIqiyiTimeline(db: db));
    await run('youku', () => c.indexYoukuTimeline(db: db));
    debugPrint('[追剧] 时刻表本次新增 $total 条');
    if (total > 0 && mounted) {
      await _loadTimelineHits();
    }
  }

  /// **拉 TMDB 的剧集状态**（独立于周历，见 `_tmdbStatus` 的说明）。
  ///
  /// ## 为什么值得单独一次请求
  /// 用户的报障「体能之巅已完结却显示连载中」根因就是**周历超时连带状态丢失**。
  /// 而状态只需 `/tv/{id}` 一次请求（周历要 2 次）⇒ 成功率高得多。
  ///
  /// ## 限并发
  /// 与平台信息同理：限 **4** —— TMDB 在国内响应慢，并发高了全都会超时。
  Future<void> _loadTmdbStatus() async {
    final subs = await ref.read(subscriptionsProvider.future);
    if (subs.isEmpty) return;
    // ⚠️ TMDB Key 走 `sessionStore`（**不是** provider）——
    //    与本文件 804 行 `_loadAll` 的既有用法一致。
    final key = await ref.read(sessionStoreProvider).loadTmdbKey();
    if (key == null || key.isEmpty) return;
    // ⚠️ `calendarClientProvider` 返回**非空**类型（provider 内部保证），
    //    所以不写 `if (client == null)` —— analyze 会报 dead_code。
    final client = ref.read(calendarClientProvider);

    // ⚠️ `CalendarSubscription` **没有 tmdbId 列**（读 `.g.dart` 确认）：
    //    `source == 'tmdb'` 时 `sourceId` **就是** tmdbId；
    //    `source == 'emby'` 时 `sourceId` 是 Emby SeriesId ⇒ 需要反向映射。
    final byTmdb = <String, String>{};   // tmdbId → sourceId

    // ① tmdb 源的：sourceId 直接用
    for (final s in subs) {
      if (s.source == 'tmdb' && s.sourceId.isNotEmpty) {
        byTmdb[s.sourceId] = s.sourceId;
      }
    }

    // ② emby 源的：用 `mapSeriesTmdbToId()` 反查（它已翻页取全 5710 条）
    final embySubs = subs.where((x) => x.source != 'tmdb').toList();
    if (embySubs.isNotEmpty) {
      try {
        // ⚠️ `embyApiProvider` 是 `Provider<MediaProvider?>`（未登录时为 null）
        //    ⇒ 必须判空，否则 analyze 报 "receiver can be null"。
        final api = ref.read(embyApiProvider);
        if (api == null) {
          debugPrint('[TmdbStatus] 无 Emby 会话，跳过 emby 源反查');
        } else {
        final map = await api.mapSeriesTmdbToId();
        // map 是 `tmdbId → SeriesRef` ⇒ 反查 `seriesId → tmdbId`
        final rev = <String, String>{};
        map.forEach((tmdb, ref0) => rev[ref0.seriesId] = tmdb);
        for (final s in embySubs) {
          final tmdb = rev[s.sourceId];
          if (tmdb != null && tmdb.isNotEmpty) byTmdb[tmdb] = s.sourceId;
        }
        }
      } catch (e) {
        debugPrint('[TmdbStatus] 映射反查失败（跳过 emby 源）: $e');
      }
    }
    if (byTmdb.isEmpty) {
      debugPrint('[TmdbStatus] 无可用 tmdbId，跳过');
      return;
    }

    final out = <String, String>{};
    final ids = byTmdb.keys.toList();
    const batch = 4;
    for (var i = 0; i < ids.length; i += batch) {
      final chunk = ids.skip(i).take(batch).toList();
      await Future.wait(chunk.map((id) async {
        try {
          final st = await client.fetchTvStatus(id, apiKey: key);
          if (st != null && st.isNotEmpty) out[byTmdb[id]!] = st;
        } catch (_) {
          // 拿不到就跳过（不阻断其它剧）
        }
      }));
    }
    if (!mounted || out.isEmpty) return;
    setState(() => _tmdbStatus = {..._tmdbStatus, ...out});
    debugPrint('[TmdbStatus] 拿到 ${out.length}/${ids.length} 部的状态');
  }

  /// **拉「平台侧」信息**（周几 / 平台集数 / 是否在播 / 播出平台）。
  ///
  /// ## 为什么不 await（在 `_loadAll` 里 `unawaited`）
  /// 上游是**第三方免费实例**（`danmaku-api.152468.xyz`），
  /// 且每部要 **2 次请求**（search→bangumi）⇒ 11 部 = 22 次。
  /// 若 await 它，首屏会被拖住（本仓库踩过"42 并发全部超时"）。
  /// ⇒ **后台跑，拿到再 setState**；首屏永远不等它。
  ///
  /// ## 失败语义
  /// 单个失败只影响那一部（`null` 也会写进缓存 ⇒ 不反复重试）；
  /// 整个失败就保持空 Map ⇒ 卡片退回库内口径（**不报错、不伪装**）。
  Future<void> _loadPlatform(List<CalendarSubscription> subs) async {
    if (subs.isEmpty) return;
    // 用**展示名**去搜（`titleCn` 优先，与 `_loadTimelineHits` 同口径）
    final byTitle = <String, CalendarSubscription>{};
    for (final s in subs) {
      final t = (s.titleCn.isEmpty ? s.title : s.titleCn).trim();
      if (t.isNotEmpty) byTitle[t] = s;
    }
    if (byTitle.isEmpty) return;
    try {
      final res = await fetchPlatformEpisodesBatch(
        ref: ref,
        titles: byTitle.keys.toList(),
      );
      if (!mounted) return;
      final out = <String, PlatformEpisodes?>{};
      for (final e in res.entries) {
        final sub = byTitle[e.key];
        if (sub != null) out[sub.sourceId] = e.value;
      }
      setState(() => _platform = out);
    } catch (e) {
      debugPrint('[Platform] 批量拉取失败（退回库内口径）: $e');
    }
  }
  /// 查"订阅剧在时刻表里的更新时刻"（**只读本地表，0 网络**）。
  Future<void> _loadTimelineHits() async {
    final db = ref.read(appDbProvider);
    // ⚠️ **必须 `await ...future`** —— 这是本轮修过 6 次的同一个坑：
    //    读 `.value` 在未就绪时是 null ⇒ `?? const []` ⇒ **静默不执行**。
    //    全仓守卫测试当场抓到（`tracking_page.dart` 命中）。
    final subs = await ref.read(subscriptionsProvider.future);
    final hits = <String, AnimeTimeline>{};
    for (final s in subs) {
      final t = s.titleCn.isEmpty ? s.title : s.titleCn;
      try {
        final row = await db.timelineFor(t);
        if (row != null) hits[s.sourceId] = row;
      } catch (_) {}
    }
    if (mounted) setState(() => _timeline = hits);
  }

  /// **生效周几**（State 级）—— **日历分桶 / 底栏角标 / 卡片** 三处共用。
  ///
  /// ## 用户规则（2026-10-13）
  /// > 凡是 svip 提前更新的，vip 只能第二天更新的这种，
  /// > 我们都以他**最新的更新时间**为准写入日历。
  ///
  /// ## 为什么必须是"取最早"（实测两个反向 case）
  /// | 剧 | `airDate` 推的 | 「放送星期」| 真值（页面文案）|
  /// |---|---|---|---|
  /// | 遮天（腾讯）| **周二** | 周三 | 周二 = SVIP |
  /// | 一斩苍穹（优酷）| 周二 | 空 | **周一** = SVIP（在本地时刻表）|
  /// ⇒ 取"离今天最近的下一次"（gap 最小）才能同时覆盖。
  ///
  /// ## 为什么 State 里也要有一份（不能只留卡片的 getter）
  /// 卡片的 `_weekday` 拿不到 State 的 `_weeks`/`_platform`；
  /// 而分桶与角标在 State 里 ⇒ 两处必须**同一算法**，否则
  /// 会出现"卡片说周二、日历排在周日"（用户已报此 bug）。
  int? _effectiveWeekdayOf(String sourceId) {

    // ★★ **按来源优先级取第一个**（不是比 gap —— 那是我上一版的错）
    //
    // ## 我上一版为什么错（用户让我自查查出来的）
    // 我写的是"取**离今天最近**的下一次"（`gap = (wd-today+7)%7` 小者优先）。
    // 今天周二时，一斩苍穹的候选 = {周一(SVIP), 周二(airDate=VIP)}
    // ⇒ gap(周二)=0 < gap(周一)=6 ⇒ **选中周二** ❌
    // 而用户明确："周二这边你不应该显示了" ⇒ 要**周一**。
    //
    // **根因**：用户说的"最新/最早"是 **SVIP 比 VIP 早一天** 那个"早"，
    //          不是"距离今天多远"。两者是不同的语义。
    //
    // ## 正确规则
    // ① `timeline.weekday`  —— 本地时刻表（**优酷文案里显式写了 SVIP**）
    //                           实测一斩苍穹 = 周一（SVIP）
    // ② `airedWeekday`      —— danmu `airDate`（实测遮天 = 周二 = SVIP）
    // ③ `plat.weekday`      —— 「放送星期」= **VIP**（较晚 ⇒ 降级）
    // ④ 库内周历             —— 兜底
    final tl = _timeline[sourceId]?.weekday;
    if (tl != null && tl >= 1 && tl <= 7) return tl;
    final air = _platform[sourceId]?.airedWeekday;
    if (air != null && air >= 1 && air <= 7) return air;
    final wk = _platform[sourceId]?.weekday;
    if (wk != null && wk >= 1 && wk <= 7) return wk;
    final days = _weeks[sourceId]?.days;
    if (days != null) {
      final ks = days.keys.where((k) => k >= 1 && k <= 7).toList()..sort();
      if (ks.isNotEmpty) return ks.first;
    }
    return null;
  }

  /// 把"今日更新的订阅数"写进 `todayUpdateCountProvider`（底栏角标）。
  ///
  /// ## 判据（与周历 `_countOn` 完全一致）
  /// `_weeks[sourceId].days` 是否含**今天的 weekday**。
  /// 只看 `_Only.live`（已完结的剧不会有"今日更新"）。
  void _syncNavBadge(Map<String, ShowWeek> weeks, List<CalendarSubscription> subs) {
    final today = DateTime.now().weekday;
    var n = 0;
    for (final s in subs) {
      // 已完结的跳过（与"连载中"统计卡同一口径）
      if (s.status == '已完结') continue;
      // ★ 与**分桶**同一判据（`_effectiveWeekdayOf`）——
      //   原来用 `weeks[..].days.containsKey(today)`（只看库内）
      //   ⇒ 会出现"周日显示了某剧，但底栏角标没 +1"的矛盾。
      if (_effectiveWeekdayOf(s.sourceId) == today) n++;
    }
    // ★ 直接由调用方传入 `subs`（`_loadAll` 顶部已 `await ...future` 拿到）
    //
    // ## 为什么不再读一次（守卫测试当场抓到）
    // 我第一版写的是 `ref.read(subscriptionsProvider).value` —— 又是本轮
    // 修过 5 次的那个错（未就绪时是 null ⇒ 静默不执行）。
    // 全仓守卫测试立刻变红，指向这一行。**改成参数传入**。
    ref.read(todayUpdateCountProvider.notifier).set(n);
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
  ///
  /// ## ★ 必须与**分桶**用同一判据（真机踩到）
  /// 原实现只看 `_weeks.values`（**库内**周历）：
  /// ```dart
  /// for (final w in _weeks.values) {
  ///   if (w.days.containsKey(weekday)) n++;     // ❌ 旧判据
  /// }
  /// ```
  /// ⇒ 真机出现：**周三徽标显示 5，列表却是「这一天没有订阅剧更新」**
  ///   （分桶已改用 `_effectiveWeekdayOf`，徽标还是旧的）。
  ///
  /// ⇒ 现在统一走 `_effectiveWeekdayOf`（**单一事实源**）。
  ///   这是本仓库反复强调的"同一事实必须收敛到一个函数"
  ///   —— 本轮我改了分桶与底栏角标，**漏了这个徽标**，靠真机截图才发现。
  /// ## ★ 必须与列表用**同一份订阅集**（真机踩到第二次）
  /// 我第一次只把它从 `_weeks` 换成"全部订阅的并集"，但**仍与列表不一致**：
  /// ```dart
  /// final list = all.where(按 widget.only 过滤)...   // 列表只显示"连载中"侧
  /// for (final s in _allSubsForCount)                 // ❌ 徽标算了两侧
  /// ```
  /// ⇒ 真机截图：**周三徽标 1、列表「这一天没有订阅剧更新」**。
  ///
  /// ⇒ 现在由 `build` 把**过滤后的** `list` 传进来 ⇒ 两处**必然一致**。
  int _countOn(int weekday, List<CalendarSubscription> list) {
    var n = 0;
    for (final s in list) {
      if (_effectiveWeekdayOf(s.sourceId) == weekday) n++;
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
                ? isLiveish(x.status) // live = 连载中 + 状态未知
                : !isLiveish(x.status))
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
        //
        // ★ 分桶改用**生效周几**（平台 SVIP 优先 + 库内兜底）—— 用户报障：
        //   "然后你周日怎么又显示凡人修仙传的更新了"
        //   根因：原来只看 `_weeks`（**库内**周历）⇒
        //         平台说周六、库内排到周日 ⇒ **周日多出一部**。
        //   ⇒ 改用与卡片**同一个** `_effectiveWeekdayOf`（单一事实源），
        //     否则又会出现"卡片说周二、日历排在周日"的矛盾。
        final onDay = <CalendarSubscription>[];
        for (final s in list) {
          if (_effectiveWeekdayOf(s.sourceId) == _sel) onDay.add(s);
        }
        return Column(children: [
          _WeekBar(
            selected: _sel,
            today: today,
            loading: _loading,
            // ★ 传**过滤后的** `list` —— 与下面的 `onDay` 分桶同源，
            //   否则徽标与列表会不一致（真机踩到：徽标 1、列表空）。
            countOn: (wd) => _countOn(wd, list),
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
                            // ★ 库内集数（详情页「已入库」用）
                            // 库内集数（provider 里的；子级也能 watch）
                            libCount: ref
                                .watch(libraryEpisodeCountProvider)[
                                    onDay[i].sourceId],
                            libNext: _libNext[onDay[i].sourceId],
                            libPlatform: _libPlat[onDay[i].sourceId],
                            libMaxEp: _libMaxEp[onDay[i].sourceId],

                            // ★ 平台侧信息（周几 / **平台集数** / 是否在播 / 播出平台）

                            //   —— 用户要求"显示平台数和库内数"（两数相减=你缺几集）

                            plat: _platform[onDay[i].sourceId],
            // ★ TMDB 状态（独立于周历 —— 周历超时时它仍可用）
            tmdbStatus: _tmdbStatus[onDay[i].sourceId],
                            timeline: _timeline[onDay[i].sourceId],
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
/// 订阅剧卡片。
///
/// ## 为什么是 `ConsumerWidget`（而不是 `StatelessWidget`）
/// 点击时要 `ref.read(aggregatedSearchProvider)` **先查库** ——
/// 库里有的直接进库内详情页（用户要求"应该等于库中的详情页"）。
class _SubTile extends ConsumerWidget {
  const _SubTile({
    required this.sub,
    this.week,
    this.libCount,
    this.libNext,
    this.libPlatform,
    this.libMaxEp,
    // ★ 平台侧信息（周几 / **平台集数** / 是否在播 / 播出平台）
    this.plat,
    this.tmdbStatus,
    this.timeline,
    this.isToday = false,
  });

  final CalendarSubscription sub;
  final ShowWeek? week;

  /// **库内已入库的集数**（null = 库里没有 / 未查到）⇒ 传给详情页显示「已入库」。
  final int? libCount;

  /// 今天是否更新（左侧 3px 竖条用）。
  final bool isToday;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // ⚠️ fallback **必须过 `statusCnOf`** —— 真机踩到：
    //    `week` 为 null（库内命中、未走日历）时，fallback 直接把
    //    Emby 的英文原值 `Continuing` 交给 UI ⇒ 卡片显示 "Continuing"。
    // ★ **平台数据优先**（`isOnAir` 能纠正 Emby 的过期 `Status`）

    //   真机实例：「体能之巅」Emby 说 Continuing，平台说已完结（见 `_statusCn`）。

    final cn = _statusCn;
    final eps = week?.days.values.expand((x) => x).toList() ?? const <int>[];
    return GestureDetector(
      onTap: () => _open(context, ref),
      behavior: HitTestBehavior.opaque,
      child: _content(context, cn, eps),
    );
  }

  /// 点开卡片：**先查库**，命中进库内详情页；没命中才用日历详情页。
  ///
  /// ## ★ 用户要求（2026-10-12）
  /// > "追剧中详情页应该等于库中的详情页，不需要跳转"
  ///
  /// ## 为什么必须查库（而不是直接开日历详情页）
  /// 日历详情页是我为**外部源**（TMDB/豆瓣）做的 ——
  /// 库里已有的剧不该有两套详情页。用户明确要求"应该等于"。
  ///
  /// ## 降级
  /// 库里没有（先订阅、等入库的剧）⇒ 仍用日历详情页看简介/取消订阅。
  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final title = sub.titleCn.isEmpty ? sub.title : sub.titleCn;
    final entry = _subToEntry(sub);
    // 轻提示：查库约 1 秒，避免"点了没反应"
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('正在媒体库里查找…'),
          duration: Duration(milliseconds: 1200),
        ),
      );
    }
    try {
      final results =
          await ref.read(aggregatedSearchProvider(title).future);
      if (!context.mounted) return;
      for (final r in results) {
        for (final h in r.hits) {
          final t = h.item.type;
          // 只要整剧/整片（避免命中的是分集）
          if (t != 'Series' && t != 'Movie') continue;
          ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
          openMediaItem(context, h.item);
          return;
        }
      }
    } catch (_) {
      // 查库失败 ⇒ 走降级（不让用户卡住）
    }
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
    // 库里没有 ⇒ 外部源详情页（能看简介、能取消订阅）
    showCalendarDetail(
      context,
      entry,
      libraryEpisodeCount: libCount,
    );
  }

  /// 卡片内容（拆出来是为了让 [build] 只负责"包点击"）。
  /// **「平台数 + 库内数」的 chips**（用户 2026-10-13 要求）。
  ///
  /// ## 用户原话
  /// > "显示平台数和库内数，这样我知道我库内的集数，
  /// >  也就可以去获取没在库的数了。"
  ///
  /// ## 三个数字的分工
  /// · `mine`  = 库内最大集号（**你手上有几集**）
  /// · `platN` = 平台已更新集数（**平台放到第几集**）
  /// · 相减    = **你缺几集**（最可行动的数字）
  ///
  /// ## 三态
  /// | 情形 | chips |
  /// |---|---|
  /// | 库内+平台，平台更多 | `E6` `平台 16 集` `缺 10 集` |
  /// | 库内+平台，平台不多 | `E6` `平台 16 集` |
  /// | 只有库内 | `更新至 E6`（原行为）|
  /// | 只有平台 | `平台 16 集` |
  /// | 都没有 | 空 |
  ///
  /// ## ⚠️ 为什么是方法而不是内联 `if {...}`
  /// `Wrap(children: [...])` 是**表达式列表** —— 里面写多语句的
  /// `if (x) { a(); b(); }` 会被 Dart 当成 **Set 字面量**
  /// （实测报 `The element type 'Set<Widget>' can't be assigned to 'Widget'`）。
  /// **平台侧"已更新到第几集"** —— ★ 用**已播出**数，不是上游总数。
  ///
  /// ## 用户报障
  /// > "遮天周二是今天更新 **185** 集，不是你标注的平台更新 **190** 集"
  ///
  /// ## 实测根因
  /// `episodes[]` **含未播出的预约集**（遮天有 5 集在未来：
  /// 第186集 2026-10-20、第187集 2026-10-27 …
  /// 直到 第190集 2026-11-17）⇒ 直接数长度会**超前 5 集**。
  ///
  /// ## 兜底
  /// `aired` 拿不到（无 airDate 字段）时退回 `updated`（总数）
  /// —— 那至少不是凭空编的。
  int? get _platCount {
    final p = plat;
    if (p == null) return null;
    return p.aired ?? p.updated;
  }

  List<Widget> _epChips(int mine, int? platN) {
    if (mine > 0 && platN != null && platN > 0) {
      return [
        _chip('E$mine', Cf.accent),
        _chip('平台 $platN 集', Cf.text2),
        // **缺几集**单独一个 chip —— 那是最可行动的数字
        if (platN > mine) _chip('缺 ${platN - mine} 集', Cf.warn),
      ];
    }
    if (mine > 0) return [_chip('更新至 E$mine', Cf.accent)];
    if (platN != null && platN > 0) {
      return [_chip('平台 $platN 集', Cf.accent)];
    }
    return const [];
  }

  /// ⚠️ 需要 `context`（`Image.network` 的 `cacheWidth` 要乘
  /// `devicePixelRatioOf(context)` —— 见其中说明）。
  Widget _content(BuildContext context, String? cn, List<int> eps) {
    // ★ 「平台数 + 库内数」的两个数字（用户 2026-10-13 要求）
    //
    // ## 用户原话
    // > "显示平台数和库内数，这样我知道我库内的集数，
    // >  也就可以去获取没在库的数了。"
    //
    // ## 三个数字的分工
    // · `mine`  = 库内最大集号（**你手上有几集**）
    // · `platN` = 平台已更新集数（**平台放到第几集**）
    // · 相减    = **你缺几集**（可行动：去补）
    //
    // ⚠️ 必须在**方法体的语句区**声明 —— `children: [...]` 是表达式列表，
    //    里面不能放 `final` 语句（实测报 `Expected an identifier`）。
    final mine = (libMaxEp ?? 0) > 0
        ? libMaxEp!
        : (eps.isNotEmpty
            ? eps.reduce((a, b) => a > b ? a : b)
            : 0);
    // ★ 用**已播出**数（用户："今天更新 185 集"，不是 190）
    final platN = _platCount;
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
                // ★ `cacheWidth` 减少解码量（流畅度优化）
                //
                // ## 为什么这里收益最大
                // 显示只有 56×80，而海报原图常见 500×750 ⇒
                // 原来按**原始像素**解码（≈8.9 倍多余的像素）⇒ 一屏十几张时
                // 解码耗时与内存都放大。
                //
                // ## 为什么用 `devicePixelRatio` 动态算而不是写死
                // `cacheWidth` 单位是**物理像素**，须 × DPR；且折叠屏/平板的
                // DPR 与屏宽都不同 ⇒ 写死数字会糊。
                // `clamp` 下限 240：极低 DPR 时也给足清晰度。
                : Image.network(sub.posterUrl,
                    fit: BoxFit.cover,
                    cacheWidth:
                        (56 * MediaQuery.devicePixelRatioOf(context))
                            .round()
                            .clamp(240, 720),
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
              if (_platform.isNotEmpty) _chip(_platform, Cf.text2),
              // ★ 播出时刻（稿子 `.uc-meta .time-tag`：绿底浅绿字）
              //
              // ⚠️ 这是**平台常规首播时刻**（腾讯/爱奇艺/芒果 20:00、
              //    B站 23:30…），**不是该剧的精确时刻** ——
              //    实测两台服务器的 `AirTime`/`AirDays` 全为空、
              //    分集时间部分只有 00:00:00 / 16:00:00（都是日期零点）。
              //    详见 `platformAirTime` 的注释。
              if (_airTime case final at?) _timeChip(at),
              // ★ 集号（稿子口径："已更新至第 N 集"，不是把每天更新的集全罗列）
              //
              // ## 我第一版为什么错
              // 写成 `E${eps.join("/")}` ⇒ 显示 `E7/8/9/10/11/12/13/...` ——
              // 那是**该季每一集**（周历把它们全收进 days）⇒ 长到溢出，
              // 而用户要的是"更新到哪儿了"这一个数。
              //
              // 稿子原文：`已更新至第 ${stats.total} 集` ⇒ 取**最大集号**。
              // ★ "更新至 EN" —— **库内集号优先**（用户："以库里的集数为准"）
              //
              // ## 为什么必须换（真机 dump 的矛盾）
              // 原来用**周历**的最大集号：`更新至 E239`，
              // 而详情页显示库里只有 **203 集** ⇒ 两个数字打架。
              // 用户看到会以为数据错。
              // ## 两级
              // 1. 库内最大集号（`libMaxEp`）—— 最准
              // 2. 没有 ⇒ 退回周历
              // ══════ ★ 「平台数 + 库内数」并排（用户 2026-10-13 要求）══════
              //
              // ## 用户原话
              // > "显示平台数和库内数，这样我知道我库内的集数，
              // >  也就可以去获取没在库的数了。"
              //
              // ## 三个数字的分工
              // · `mine` = 库内最大集号（**你手上有几集**）
              // · `plat.updated` = 平台已更新集数（**平台放到第几集**）
              // · 两者相减 = **你缺几集**（可行动：去补）
              //
              // ## 文案三态（对齐现有风格）
              // · 有库内+平台，且平台更多 ⇒ `E6` `平台 16 集` `缺 10 集`
              // · 有库内+平台，平台不多   ⇒ `E6` `共 16 集`
              // · 只有库内（现状）        ⇒ `更新至 E6`
              // · 只有平台                ⇒ `平台 16 集`
              // ⚠️ 用**局部函数返回列表**而不是 `if {...}` 语句块 ——
              //    `children: [...]` 是**表达式列表**，多语句的 `{ }` 会被当成
              //    **Set 字面量**（实测报 `Set<Widget> can't be assigned`）。
              ..._epChips(mine, platN),
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
            _libraryBar(),
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
  /// 「下次更新」文案：`下次更新：今天 周一 20:00`。
  ///
  /// ## 与用户截图的对应（稿子）
  /// ```
  /// ⏰ 下次更新：今天 周一 20:00
  /// ```
  ///
  /// ## 三级降级（都不编造）
  /// · 有库内日期 ⇒ "今天/明天/日期" + 周几
  /// · 只有 `weekday` ⇒ "周X"
  /// · 都没有 ⇒ null（**不显示**，而不是显示"待定"）
  ///
  /// ## 时刻是**平台常规时刻**
  /// 见 `platformAirTime` 的实测注释：两台服务器的 `AirTime` 全空，
  /// 分集时间部分只有零点 ⇒ 精确时刻在现有源里不存在。
  /// 认不出平台 ⇒ **不带时刻**（只显示到周几）。
  String? _nextUpdateText() {
    final w = week;
    final today = DateTime.now().weekday;
    const cn = ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final at = _airTime;

    // ① 库内日期优先（最准）
    final d = _nextDate; // yyyy-MM-dd
    if (d != null && d.length >= 10) {
      final dt = DateTime.tryParse(d);
      if (dt != null) {
        final now = DateTime.now();
        final gap = DateTime(dt.year, dt.month, dt.day)
            .difference(DateTime(now.year, now.month, now.day))
            .inDays;
        final when = switch (gap) {
          0 => '今天',
          1 => '明天',
          _ => d,
        };
        final wd = cn[dt.weekday];
        return at == null
            ? '下次更新：$when $wd'
            : '下次更新：$when $wd $at';
      }
    }

    // ② 退回外部源的 weekday
    if (w != null && w.days.isNotEmpty) {
      final days = w.days.keys.toList()
        ..sort((a, b) =>
            ((a - today + 7) % 7).compareTo((b - today + 7) % 7));
      final dd = days.first;
      final gap = (dd - today + 7) % 7;
      final when = switch (gap) {
        0 => '今天',
        1 => '明天',
        _ => '',
      };
      final head = when.isEmpty ? '下次更新：${cn[dd]}' : '下次更新：$when ${cn[dd]}';
      return at == null ? head : '$head $at';
    }

    // ③ **平台「放送星期」**（本项接线：卡片周几用平台数据）
    //
    // ## 为什么加这一级
    // ①② 都依赖**库内分集日期**。实测「财神窦占龙」库里只有 6 集、
    // 若那几集没有 `PremiereDate` ⇒ ①② 全空 ⇒ 卡片**什么都不显示**。
    // 而平台侧（弹弹play 聚合）有「放送星期: 星期日」（实测「仙逆」= 星期一、
    // 「完美世界」= 星期五）⇒ **比不显示有用**。
    //
    // ## 优先级仍在最后
    // 库内日期是**你自己的库**的事实（最贴实际），平台周几是通用排期表
    // ⇒ 有库内数据时不覆盖（避免"库里明明给了 10-15，却显示周X"的矛盾）。
    // ⚠️ 走 `_weekday`（**平台优先 + 库内兜底**）而不是 `plat?.weekday`：
    //    平台没给「放送星期」时（实测一斩苍穹/财神窦占龙）还能退回库内周历。
    final pw = _weekday;
    if (pw != null) {
      final gap = (pw - today + 7) % 7;
      final when = switch (gap) {
        0 => '今天',
        1 => '明天',
        _ => '',
      };
      final head =
          when.isEmpty ? '下次更新：${cn[pw]}' : '下次更新：$when ${cn[pw]}';
      return at == null ? head : '$head $at';
    }
    return null; // **不显示**"待定"
  }

  /// 库内的"下次更新日"（`yyyy-MM-dd`；null = 拿不到）。
  ///
  /// 由 `_loadAll` 从 `librarySummaryProvider` 之外单独查 —— 见 `libNext`。
  String? get _nextDate => libNext;

  /// 该剧的库内"下次更新日"（由上层通过构造参数传入）。
  final String? libNext;

  /// **库内平台名**（订阅表没平台时用它 —— 决定能否显示 `20:00` 时刻）。
  final String? libPlatform;

  /// **库内最大集号**（"更新至 EN"用 —— **以库为准**，用户明确要求）。
  final int? libMaxEp;

  /// **平台侧信息**（周几 / 平台集数 / 是否在播 / 播出平台）。
  ///
  /// 数据源是**内置弹幕源**（弹弹play 兼容 API）——
  /// 它已统一 20+ 平台，无需逐家对接。
  /// null = 还没拿到 / 未配源 ⇒ 卡片退回**库内口径**。
  final PlatformEpisodes? plat;

  /// **TMDB 剧集状态**（`Ended` / `Returning Series` …；null = 没拿到）。
  ///
  /// ## 为什么与 `week?.statusCn` 并存
  /// `week` 依赖 `fetchWeekEpisodes` **成功**（2 次请求，实测常超时）；
  /// 本字段来自**独立**的 1 次请求 ⇒ 周历挂了它还在。
  /// 判据链见 `_statusCn`。
  final String? tmdbStatus;
  /// **时刻表条目**（B站官方索引；`null` = 没索引到）。
  final AnimeTimeline? timeline;

  /// 生效的平台名（**多平台合并** —— 用户："多平台都显示，现在只显示第一个"）。
  ///
  /// ## 为什么要合并
  /// 两个来源各有一半信息：
  /// · **Emby `Studios`**（经 `libPlatform`/`sub.platform` 传入）—— 可能有**多个**
  ///   （实测「财神窦占龙」= `iQiyi` + `bilibili`）
  /// · **平台源**（`plat?.platform`）—— 通常是**单个**（`在线播放平台: 腾讯视频`）
  /// ⇒ 取并集、去重、保持顺序（库内在前，因为那是你自己库的原始数据）。
  ///
  /// ⚠️ 去重是**必须的**：两个来源常给同一个平台（如都为"腾讯视频"），
  ///    不去重会显示 `腾讯视频 · 腾讯视频`。
  String get _platform {
    // ⚠️ 用 `mergePlatforms`（**别名归一后再去重**）而不是纯字符串比较 ——
    //    真机踩到：Emby 给 `Youku`、平台源给 `优酷` ⇒ 纯字符串比较会显示
    //    `Youku · 优酷`（同一平台两次）。见 `kPlatformAlias`。
    final merged = mergePlatforms([libPlatform, sub.platform, plat?.platform]);
    return merged.join(' · ');
  }

  /// **生效的连载状态**（中文）—— **平台数据优先于 Emby**。
  ///
  /// ## ★ 为什么要用平台数据纠正 Emby（真机实例）
  /// 「体能之巅：百人大挑战」（用户报障"好像已经完结了，怎么还显示连载中"）：
  /// | 来源 | 判定 |
  /// |---|---|
  /// | **Emby `Status`** | `Continuing`（**缓存了 2 年的旧值**，`EndDate` 为空）|
  /// | **TMDB**（本机实测）| `Ended`、末集 **2024-04-02** |
  /// | **平台源 `isOnAir`** | `false` |
  /// ⇒ Emby 的值**确定过期**（服务器只在扫描时抓一次元数据，之后不跟上游更新）。
  ///
  /// ## 判据
  /// · `isOnAir == true`  ⇒ `连载中`
  /// · `isOnAir == false` ⇒ `已完结`
  /// · 拿不到 ⇒ 退回 Emby 的 `statusCnOf(...)`（**不猜**）
  String get _statusCn {
    // ① 平台源 `isOnAir` —— 最快（已在内存里，无额外请求）
    final on = plat?.isOnAir;
    if (on == true) return '连载中';
    if (on == false) return '已完结';

    // ② **TMDB 状态**（独立于周历）—— 真机修「体能之巅」的关键一级
    //
    // ## 为什么必须在 ③ 之前
    // `week?.statusCn` 依赖 `fetchWeekEpisodes` **成功**（2 次请求）；
    // 实测它频繁超时（`周历分集拉取失败: 超时`）⇒ 状态一起丢。
    // 而 TMDB 这里只 1 次请求（6s 超时）⇒ **更可能拿到**。
    final tm = tmdbStatus;
    if (tm != null && tm.isNotEmpty) {
      final cn = statusCnOf(tm);
      // ⚠️ `statusCnOf` 对认不出的英文返回「未知」——
      //    那种情况**继续往下兜底**，不要把"未知"当结论。
      if (cn != '未知') return cn;
    }

    // ③ 周历里捎带的状态（可能因超时为空）
    // ④ Emby 快照（最后一档，可能过期）
    return statusCnOf(
        week?.statusCn ?? (sub.status.isEmpty ? null : sub.status));
  }

  /// **生效的周几**（1..7；null = 都不知道）。
  ///
  /// ## 优先级：平台「放送星期」优先，库内周历兜底
  /// · **平台源**（`metadata` 的 `放送星期: 星期日`）—— 权威播出日
  /// · **库内周历**（分集 `PremiereDate` 推出的 `week`）—— 只覆盖**已入库**的集
  ///   （实测「财神窦占龙」库里 6 集 ⇒ 只能推出已播的那几天）
  /// ⇒ 平台有就用平台，没有才用库内。
  ///
  /// ⚠️ 实测**并非每部都有**「放送星期」（一斩苍穹/财神窦占龙 就没有）
  ///    ⇒ 缺时返回 null，UI 不显示（不编）。
  /// 候选周几（多个来源；最终由 `_weekday` **取最早**）。
  List<int> get _weekdayCandidates {
    final out = <int>[];
    // 去重加入（同一周几可能被多个来源给出）
    void add(int? wd) {
      if (wd != null && wd >= 1 && wd <= 7 && !out.contains(wd)) out.add(wd);
    }

    // ① **本地时刻表** —— 优酷/爱奇艺详情页文案里**显式写了 SVIP**
    //    实测一斩苍穹：文案「每周一10点SVIP更新，周二10点VIP可看」⇒ 周一 ✅
    //    （这条最权威：它是平台自己写的 SVIP 标记，不是我们推断的）
    add(timeline?.weekday);
    // ② `airDate` 推的周几 —— 实测遮天 = 周二 = **SVIP 提前更新日** ✅
    add(plat?.airedWeekday);
    // ③ 平台「放送星期」—— 实测遮天 = 周三 = **VIP 正式日**（较晚 ⇒ 降级）
    add(plat?.weekday);
    // ④ 库内周历兜底
    final days = week?.days;
    if (days != null) {
      final ks = days.keys.where((k) => k >= 1 && k <= 7).toList()..sort();
      for (final k in ks) {
        add(k);
      }
    }
    return out;
  }

  /// **生效的周几** —— 用户规则："以 **SVIP** 的更新时间为准"。
  ///
  /// ## 用户原话（2026-10-13）
  /// > 凡是 svip 提前更新的，vip 只能第二天更新的这种，
  /// > 我们都以他**最新的更新时间**为准写入日历。
  ///
  /// ## ★ 为什么是"按来源优先级"而不是"比 gap"（我踩过的坑）
  /// 我第一版写的是"取**离今天最近**的下一次"（`gap = (wd-today+7)%7` 小者优先）。
  /// 今天周二时，一斩苍穹的候选 = {周一(SVIP), 周二(airDate)}：
  /// ```
  /// gap(周二)=0  <  gap(周一)=6   ⇒ 选中周二  ❌
  /// ```
  /// 而用户明确"周二这边你不应该显示了" ⇒ 要**周一**。
  ///
  /// **根因**：用户说的"最早"是 **SVIP 比 VIP 早一天** 那个"早"，
  /// 不是"距离今天多远"—— 两者是**不同的语义**，不能混用。
  ///
  /// ## 优先级（越前越权威）
  /// ① `timeline`（本地时刻表：优酷文案**显式写 SVIP**）② `airDate`
  /// ③ 放送星期（= VIP，较晚）④ 库内周历
  ///
  /// ## 实测两个反向 case
  /// | 剧 | `airDate` 推的 | 「放送星期」| 真值（页面文案）|
  /// |---|---|---|---|
  /// | 遮天（腾讯）| **周二** | 周三 | 周二（SVIP）|
  /// | 一斩苍穹（优酷）| 周二 | 空 | **周一**（SVIP，在本地时刻表里）|
  /// ⇒ 只看 `airDate` 会漏一斩苍穹；只看「放送星期」会漏遮天。
  ///   **只有"取最早"能同时覆盖两者**。
  ///
  /// ## "最早"怎么比（周几是循环的）
  /// 真实语义 = 「**离今天最近的下一次**」⇒ `(wd - today + 7) % 7`，小者更早。
  int? get _weekday {
    // ★ **按来源优先级取第一个**（与 State 的 `_effectiveWeekdayOf` 同规则）
    //
    // ## 我上一版为什么错（自查）
    // 写成"取离今天最近的下一次"⇒ 周二时一斩苍穹会选中**周二(VIP)**，
    // 而用户要**周一(SVIP)**（"周二这边你不应该显示了"）。
    // "SVIP 早一天"的"早" ≠ "离今天近"。
    //
    // ## 优先级
    // ① 本地时刻表（优酷文案显式写 SVIP）② airDate ③ 放送星期(VIP) ④ 库内
    for (final wd in _weekdayCandidates) {
      if (wd >= 1 && wd <= 7) return wd;
    }
    return null;
  }

  /// **生效的更新时刻**（`HH:mm`；null = 不知道）。
  ///
  /// ## 优先级（越靠前越准）
  /// 1. **时刻表索引**（B站官方，精确到分）—— 实测 `pub_time` = `10:00`
  /// 2. **平台惯例**（`platformAirTime`：腾讯/爱奇艺/优酷 20:00、B站 23:30）
  /// 3. 都没有 ⇒ null（**不显示**，不编）
  String? get _airTime {
    final t = timeline?.airTime;
    if (t != null && t.isNotEmpty) return t;
    return platformAirTime(_platform);
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

  /// 播出时刻胶囊（稿子 `.uc-meta .time-tag`：绿底浅绿字，紧跟平台标签）。
  ///
  /// 与 [_chip] 分开是因为**配色不同**（那个用状态色，这个固定绿）。
  Widget _timeChip(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          // `rgba(34,197,94,0.15)`
          color: const Color(0xFF22C55E).withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(Cf.radiusXs),
        ),
        child: Text(text,
            style: Cf.micro.copyWith(
                fontWeight: FontWeight.w700,
                // `#7dd96f`
                color: const Color(0xFF7DD96F))),
      );

  /// **库内 / 平台的集数对比条**（用户 2026-10-13 要求）。
  ///
  /// ## 用户原话
  /// > "应该显示的不是 7/7 已看，而是**已入库集数和平台更新数**。"
  ///
  /// ## 与旧实现（`_progressBar`）的区别
  /// | | 旧 | 新 |
  /// |---|---|---|
  /// | 分子 | 已看集数 | **已入库集数**（`libCount`）|
  /// | 分母 | 库内总集数 | **平台更新数**（`plat.updated`）|
  /// | 语义 | 我看了多少 | **我收藏了几成** |
  ///
  /// ⇒ 用户要的是后者：一眼看出"库里差几集没收到"（差多少已在 chips 里显示）。
  ///
  /// ## 三态（缺数据不编，§5.3/§5.5）
  /// · 库内+平台 ⇒ 画条 + `已入库 7 集 · 平台 18 集`
  /// · 只有其一 ⇒ 只显示文字（**不画条**，因为没有分母）
  /// · 都没有     ⇒ 不显示
  Widget _libraryBar() {
    final mine = libCount ?? libMaxEp;
    // ★ 用**已播出**数（用户："今天更新 185 集"，不是 190）
    final platN = _platCount;
    if (mine == null && platN == null) return const SizedBox.shrink();

    // 文字部分
    final parts = <String>[
      if (mine != null) '已入库 $mine 集',
      if (platN != null && platN > 0) '平台 $platN 集',
    ];
    final text = Text(parts.join(' · '),
        style: Cf.micro.copyWith(fontSize: 10, color: Cf.text3));

    // 只有一边 ⇒ 不画条（分母未知，画出来是假进度）
    if (mine == null || platN == null || platN <= 0) return text;

    // 两边都有 ⇒ 画「库内 / 平台」占比
    final ratio = (mine / platN).clamp(0.0, 1.0);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(Cf.radiusXs),
        child: LinearProgressIndicator(
          value: ratio,
          minHeight: 3,
          backgroundColor: const Color(0x1AFFFFFF),
          // 收满 ⇒ 绿（与"无未看集"同色系）；没收满 ⇒ 品牌色
          valueColor: AlwaysStoppedAnimation(
              ratio >= 1.0 ? Cf.success : Cf.accent),
        ),
      ),
      const SizedBox(height: 3),
      text,
    ]);
  }

  Widget _fb() => Container(
        color: Cf.surface2,
        alignment: Alignment.center,
        child: Icon(Icons.movie_outlined, size: Cf.iconSm, color: Cf.text3),
      );
}

