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

  /// `sourceId → (未看集数, 总集数)`。
  ///
  /// ⚠️ 总集数是 **-1 表示未知**（`MediaItem` 目前没映射 `ChildCount`）
  /// ⇒ UI 只显示"剩 N 集"，**不编造分母**（"已看 8/12" 里的 12 拿不到）。
  /// 要给 `MediaItem` 加 `ChildCount` 解析才能显示完整进度。
  Map<String, (int, int)> _progress = {};

  /// sourceId → **下次更新日**（yyyy-MM-dd；第 ② 段顺手算）。
  Map<String, String> _libNext = {};

  /// `sourceId → **库内平台名**`（订阅表没平台时用它补 —— 时刻标签要用）。
  Map<String, String> _libPlat = {};

  /// `sourceId → **库内最大集号**`（卡片"更新至 EN"用 —— **以库为准**）。
  Map<String, int> _libMaxEp = {};

  /// `sourceId → 时刻表条目`（B站官方索引；决定卡片的精确时刻）。
  Map<String, AnimeTimeline> _timeline = {};

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
      _progress = prog;
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
      final w = weeks[s.sourceId];
      if (w != null && w.days.containsKey(today)) n++;
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
                            // ★ 库内集数（详情页「已入库」用）
                            // 库内集数（provider 里的；子级也能 watch）
                            libCount: ref
                                .watch(libraryEpisodeCountProvider)[
                                    onDay[i].sourceId],
                            libNext: _libNext[onDay[i].sourceId],
                            libPlatform: _libPlat[onDay[i].sourceId],
                            libMaxEp: _libMaxEp[onDay[i].sourceId],
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
    this.progress,
    this.libCount,
    this.libNext,
    this.libPlatform,
    this.libMaxEp,
    this.timeline,
    this.isToday = false,
  });

  final CalendarSubscription sub;
  final ShowWeek? week;

  /// **库内已入库的集数**（null = 库里没有 / 未查到）⇒ 传给详情页显示「已入库」。
  final int? libCount;

  /// `(已看集数, 总集数)`；null = Emby 里没匹配到（**不编数字**）。
  final (int, int)? progress;

  /// 今天是否更新（左侧 3px 竖条用）。
  final bool isToday;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // ⚠️ fallback **必须过 `statusCnOf`** —— 真机踩到：
    //    `week` 为 null（库内命中、未走日历）时，fallback 直接把
    //    Emby 的英文原值 `Continuing` 交给 UI ⇒ 卡片显示 "Continuing"。
    final cn = week?.statusCn ??
        (sub.status.isEmpty ? null : statusCnOf(sub.status));
    final eps = week?.days.values.expand((x) => x).toList() ?? const <int>[];
    return GestureDetector(
      onTap: () => _open(context, ref),
      behavior: HitTestBehavior.opaque,
      child: _content(cn, eps),
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
  Widget _content(String? cn, List<int> eps) {
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
              if ((libMaxEp ?? 0) > 0)
                _chip('更新至 E$libMaxEp', Cf.accent)
              else if (eps.isNotEmpty)
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

  /// **时刻表条目**（B站官方索引；`null` = 没索引到）。
  final AnimeTimeline? timeline;

  /// 生效的平台名（**库内优先** —— 那是最准的）。
  String get _platform =>
      (libPlatform != null && libPlatform!.isNotEmpty)
          ? libPlatform!
          : sub.platform;

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
      // ⚠️ 文案**不断言用户行为**（真机观察：库里集被批量标 `Played`
      //    ⇒ 显示"已看完"会让用户以为 App 乱说）。
      //    ⇒ 只陈述**数据事实**："无未看集"。
      return Text(unplayed == 0 ? '无未看集' : '剩 $unplayed 集',
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
      // ⚠️ `已追完` 改为 `无未看集` —— 见上面同处的说明：
      //    `unplayed == 0` 只证明"库里没有未看的集"，
      //    **不能**推出"用户看完了"（库里可能被批量标记）。
      Text(unplayed == 0 ? '已看 $played/$total · 无未看集' : '已看 $played/$total · 剩 $unplayed 集',
          style: Cf.micro.copyWith(fontSize: 10, color: Cf.text3)),
    ]);
  }

  Widget _fb() => Container(
        color: Cf.surface2,
        alignment: Alignment.center,
        child: Icon(Icons.movie_outlined, size: Cf.iconSm, color: Cf.text3),
      );
}

