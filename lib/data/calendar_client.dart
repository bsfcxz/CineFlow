/// **追剧日历**（周视图：周一~周日，多源聚合）。
///
/// ## 用户需求（原话）
/// > "追剧日历构建，按照日期周一-周日的时间，从 Bangumi 获取 api、
/// >  TVmaze、TMDB（apikey）、B站时间线接口、trakt 中获取当日更新的
/// >  剧集更新。爱奇艺、b站、腾讯、优酷等主流平台"
///
/// ## ★ 各源**实测结论**（2026-10-11，本机真实请求，不是读文档）
/// | 源 | 可达 | 需 key | "按日期查"能力 | 结论 |
/// |---|---|---|---|---|
/// | **Bangumi** `/calendar` | ✅ | ❌ | **天生周一~周日**（7 组，各带 `weekday.id=1..7`） | ★ 主力 |
/// | **TVmaze** `/schedule/web?date=` | ✅ | ❌ | ✅ 按日（含国漫，实测有 `battle-through-the-heavens`） | ★ 主力 |
/// | **TMDB** `/discover/tv` + `/tv/on_the_air` | ✅ | ✅ | ⚠️ **只能"在播"**，无按日端点 | 辅助 |
/// | **trakt** `/calendars/all/shows/{date}/{days}` | ❌ | ✅ | 接口存在但**本机 403/412**（Cloudflare） | **不做** |
/// | **B站** `/pgc/web/timeline` | ✅ | ❌ | ✅ 番剧更新时间线 | ★ 主力 |
/// | 爱奇艺/腾讯/优酷 | 网页 200 | — | **无公开 API**（首页是 HTML；优酷直接返回风控页） | **不做** |
///
/// ### 为什么不做爱奇艺/腾讯/优酷
/// 实测三家首页：爱奇艺/腾讯返回 **HTML**（无 JSON 接口），
/// 优酷直接返回 **风控页**（`_____tmd_____/punish?x5secdata=...`）。
/// 而各开源项目（MoviePilot / nas-tools）**也没有**接这三家 ——
/// 它们要么依赖用户自建的订阅源，要么只做"下载管理"。
/// ⇒ **不爬网页**（脆弱、易触发风控、且违反 ToS）。
/// 这三家的内容**已通过 Bangumi/B站时间线覆盖大部分国产剧与国漫**。
///
/// ### 为什么不做 trakt
/// 官方 calendar 端点需要 `client_id` + 可能需 OAuth，且本机实测
/// **403（Cloudflare 挑战）**。让用户为此注册应用不值得 ——
/// Bangumi + TVmaze + B站 已覆盖日番/欧美/国漫。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;

/// 日历条目的**完整详情**（供"点击查看简介"弹层用）。
///
/// ## 字段来源与实测（TMDB `/tv/{id}?append_to_response=credits`）
/// **一次请求**同时拿到基本信息与演员/导演（`append_to_response` 的价值）。
/// 实测《仙逆》返回：
/// ```
/// name=仙逆  overview=改编自耳根同名小说…  vote_average=8.3 (45 人)
/// genres=[动画, 剧情, 动作冒险]  networks=[Tencent Video]
/// origin_country=[CN]  1 季 / 200 集  status=Returning Series
/// cast=7 人（含角色名）  crew[Director]=[石头熊, 冯毅]  created_by=[耳根]
/// homepage=https://v.qq.com/x/cover/mzc00200aaogpgh.html
/// ```
///
/// ## 为什么单独建模型（不复用 `CalendarEntry`）
/// 列表只画"标题+海报+评分+热度+平台"，详情要多 8 个字段。
/// 混在一起会让**列表页也去请求详情**（7 天 × 20 条 = 140 次请求）——
/// 那正是"平台补查"踩过的坑。
class CalendarDetail {
  const CalendarDetail({
    required this.title,
    this.originalTitle,
    this.overview,
    this.tagline,
    this.posterUrl,
    this.backdropUrl,
    this.rating,
    this.voteCount,
    this.firstAirDate,
    this.lastAirDate,
    this.genres = const [],
    this.countries = const [],
    this.platforms = const [],
    this.directors = const [],
    this.actors = const [],
    this.seasonCount,
    this.episodeCount,
    this.status,
    this.homepage,
    this.tmdbId,
  });

  final String title;
  final String? originalTitle;

  /// 简介（豆瓣弹层的"简介"块）。
  final String? overview;

  /// 一句话标语（豆瓣副标题的等价物，可能为空）。
  final String? tagline;

  final String? posterUrl;
  final String? backdropUrl;

  /// ★评分（0–10）。
  final double? rating;

  /// 评分人数 —— 豆瓣弹层会显示"17401 人评过"。
  final int? voteCount;

  final String? firstAirDate;
  final String? lastAirDate;

  /// 类型（如 `动画` / `剧情` / `真人秀`）。
  final List<String> genres;

  /// 制片国家/地区（**已从 ISO 码转成中文**，见 [countryName]）。
  final List<String> countries;

  /// 播放平台（**已转中文**）。
  final List<String> platforms;

  /// 导演 / 创作者（剧集的 `created_by` + `crew[job=Director]`）。
  final List<String> directors;

  /// 主演（形如 `史泽鲲 饰 王林`，**带角色名** —— 比豆瓣更细）。
  final List<String> actors;

  final int? seasonCount;
  final int? episodeCount;

  /// 连载状态（TMDB 原文，如 `Returning Series` ⇒ [statusCn] 转中文）。
  final String? status;

  /// 官方播放页（实测《仙逆》给了 `v.qq.com/x/cover/...`）⇒ **点进去就能看**。
  final String? homepage;

  final String? tmdbId;

  /// 状态的中文（`Returning Series` → `连载中`）。
  String? get statusCn => switch (status) {
        'Returning Series' => '连载中',
        'Ended' => '已完结',
        'Canceled' => '已砍',
        'In Production' => '制作中',
        'Planned' => '已预定',
        'Pilot' => '试播集',
        _ => status,
      };

  /// 副标题行（对齐豆瓣的 `"2026 / 美国 / 剧情 动作"`）。
  ///
  /// 形如：`2023 / 中国大陆 / 动画 剧情 动作冒险`。
  /// 空的部分自动跳过（不产生 `//` 这种难看的残留）。
  String get subtitleLine {
    final parts = <String>[];
    final y = firstAirDate;
    if (y != null && y.length >= 4) parts.add(y.substring(0, 4));
    if (countries.isNotEmpty) parts.add(countries.join(' '));
    if (genres.isNotEmpty) parts.add(genres.join(' '));
    return parts.join(' / ');
  }

  /// 集数文案（`1 季 / 200 集`）。
  String? get episodeText {
    final parts = <String>[];
    if (seasonCount != null && seasonCount! > 0) parts.add('$seasonCount 季');
    if (episodeCount != null && episodeCount! > 0) {
      parts.add('$episodeCount 集');
    }
    return parts.isEmpty ? null : parts.join(' / ');
  }
}

/// TMDB 的 `origin_country` 是 **ISO 3166-1 两字母码** ⇒ 转中文。
///
/// ## 为什么要转（实测）
/// TMDB 返回 `["CN"]`，直接显示给用户是 "CN"，而豆瓣显示"中国大陆"。
/// 只收录常见值 + 兜底返回原码（不做完整 ISO 表 —— 那会让文件膨胀且
/// 与本项目无关）。
String countryName(String code) => switch (code.toUpperCase()) {
      'CN' => '中国大陆',
      'HK' => '中国香港',
      'TW' => '中国台湾',
      'MO' => '中国澳门',
      'JP' => '日本',
      'KR' => '韩国',
      'US' => '美国',
      'GB' => '英国',
      'FR' => '法国',
      'DE' => '德国',
      'TH' => '泰国',
      'IN' => '印度',
      'SG' => '新加坡',
      'MY' => '马来西亚',
      'CA' => '加拿大',
      'AU' => '澳大利亚',
      'RU' => '俄罗斯',
      'ES' => '西班牙',
      'IT' => '意大利',
      _ => code,
    };

/// 日历条目的**类别**（用户要求"日期下面按类别区分、综艺、动漫、剧集等"）。
enum CalendarCategory {
  /// 动漫（TMDB genre 16 = Animation）。
  anime('动漫'),

  /// 综艺（TMDB 10764 真人秀 / 10767 脱口秀 / 10763 新闻 / 10768）。
  variety('综艺'),

  /// 剧集（TMDB 没有"剧集"这个 genre ⇒ 用**排除法**得到）。
  series('剧集');

  const CalendarCategory(this.label);

  final String label;

  /// 从 TMDB 的 `genre_ids` 判断类别。
  ///
  /// ## ★★ 实测语义（TMDB 官方文档没写清，我实测确认）
  /// | 筛选参数 | 实测结果 |
  /// |---|---|
  /// | `with_genres=10764` | 8 条 |
  /// | `with_genres=10764,10767`（逗号） | **1 条**（要有**全部**类别） |
  /// | `with_genres=10764\|10767`（竖线） | 8 条（任一即可） |
  /// ⇒ **逗号 = AND、竖线 = OR**。多类别筛选必须用竖线，
  ///   用逗号会**静默漏数据**（不报错，只是结果变少）。
  ///
  /// 这段逻辑是本文件里唯一的"类别判定"，UI 只读 [CalendarCategory]。
  static CalendarCategory fromTmdbGenres(List<int> genreIds) {
    // 优先判动漫：一部片同时是"动画+冒险"时，用户期望归到"动漫"
    if (genreIds.contains(16)) return CalendarCategory.anime;
    // 综艺：真人秀 / 脱口秀 / 新闻 / 其它纪实
    if (genreIds.any(const {10764, 10767, 10763, 10768}.contains)) {
      return CalendarCategory.variety;
    }
    return CalendarCategory.series;
  }

  /// 该类别的 **TMDB `with_genres` 参数值**（**竖线分隔**，见上表）。
  ///
  /// ⚠️ **不能用逗号** —— 逗号是 AND。
  /// ⚠️ 剧集没有正向筛选值 ⇒ 用空串表示"靠排除"（见 [withoutGenres]）。
  String get withGenres => switch (this) {
        CalendarCategory.anime => '16',
        CalendarCategory.variety => '10764|10767|10763|10768',
        CalendarCategory.series => '',
      };

  /// 剧集用**排除法**：`without_genres`（同样**竖线**分隔）。
  String get withoutGenres => switch (this) {
        CalendarCategory.anime => '',
        CalendarCategory.variety => '',
        CalendarCategory.series => '16|10764|10767|10763',
      };
}

/// 一条日历条目（**中立模型**：不绑任何源的特有字段）。
class CalendarEntry {
  const CalendarEntry({
    required this.title,
    required this.source,
    this.titleCn,
    this.airDate,
    this.weekday,
    this.episode,
    this.posterUrl,
    this.rating,
    this.summary,
    this.popularity,
    this.platform,
    this.category = CalendarCategory.series,
    this.sourceId,
    this.bangumiId,
  });

  /// 原名（日文/英文）。
  final String title;

  /// 中文名（优先显示；Bangumi 有 `name_cn`，其余源为空）。
  final String? titleCn;

  /// 播出日期（`yyyy-MM-dd`）。TVmaze 精确到日，Bangumi 周番给的是
  /// **固定星期**（无具体日期），此时为 null 而 [weekday] 有值。
  final String? airDate;

  /// 星期几（1=周一 … 7=周日）。Bangumi 用它；其余源按 [airDate] 算。
  final int? weekday;

  /// 集数（`"第 12 集"` / `"S03E01"`）；未知为 null。
  final String? episode;

  final String? posterUrl;

  /// 评分（各源口径不同，仅作展示；Bangumi 是 0–10，TMDB 是 0–10）。
  final double? rating;

  final String? summary;

  /// **热度**（TMDB `popularity`；B站/Bangumi 无此字段时为 null）。
  ///
  /// ## 用途：用户在日历里最关心"**今天有什么值得看的**"
  /// 实测 TMDB 的 `discover` **默认就按热度排**
  ///（与显式 `sort_by=popularity.desc` 结果完全一致），
  /// 但仍显式传参（语义明确），并在合并后**再按热度排一次**
  /// —— 因为多源合并会打乱顺序。
  final double? popularity;

  /// **播放平台**（如 `腾讯视频` / `爱奇艺` / `芒果TV` / `bilibili`）。
  ///
  /// ## ⚠️ 为什么常常为 null（实测）
  /// TMDB 的 `discover` 结果**不含** `networks`，
  /// 且 `append_to_response` 对它无效 ⇒ 必须**逐条查 `/tv/{id}` 详情**。
  /// 成本：一天 20 条 × 7 天 = **140 次请求**
  /// ⇒ 只在"需要显示平台"时按需补查，并控并发。
  final String? platform;

  /// 类别（用于"日期下面按类别区分"）。
  ///
  /// 取值来自 TMDB `genre_ids` 的归并（见 [CalendarCategory]）：
  /// · **动漫** = 16（Animation）
  /// · **综艺** = 10764（真人秀）/ 10767（脱口秀）/ 10763（新闻）/ 10768
  /// · **剧集** = 其余（TMDB 没有"剧集"这个 genre，只能靠排除）
  final CalendarCategory category;

  /// 来源标识（`bangumi` / `tvmaze` / `tmdb` / `bilibili`）。
  final String source;

  /// 源内 id（用于跳转/去重）。
  final String? sourceId;

  /// Bangumi subject id（**跨源去重的关键**：TVmaze/B站 若能对上就当同一条）。
  final int? bangumiId;

  /// 展示用标题（中文优先）。
  String get displayTitle =>
      (titleCn != null && titleCn!.trim().isNotEmpty) ? titleCn! : title;

  /// 这一条属于周几（算好再给 UI，避免 UI 层重复实现日历数学）。
  int get weekdayResolved {
    if (weekday != null && weekday! >= 1 && weekday! <= 7) return weekday!;
    final d = airDate;
    if (d == null) return 1;
    final dt = DateTime.tryParse(d);
    if (dt == null) return 1;
    // DateTime.weekday: 1=Mon … 7=Sun —— 与我们的约定**完全一致**
    return dt.weekday;
  }

  /// 复制并覆盖若干字段（`CalendarEntry` 是 immutable）。
  ///
  /// ## 为什么需要（实测场景）
  /// TMDB 的**平台**要逐条查详情才能拿到 ⇒ 先构造条目、再补 `platform`
  /// ⇒ 必须有 `copyWith`（`out[idx] = e.copyWith(platform: ...)`）。
  CalendarEntry copyWith({
    String? platform,
    double? popularity,
    CalendarCategory? category,
  }) =>
      CalendarEntry(
        title: title,
        titleCn: titleCn,
        airDate: airDate,
        weekday: weekday,
        episode: episode,
        posterUrl: posterUrl,
        rating: rating,
        summary: summary,
        popularity: popularity ?? this.popularity,
        platform: platform ?? this.platform,
        category: category ?? this.category,
        source: source,
        sourceId: sourceId,
        bangumiId: bangumiId,
      );

  @override
  String toString() => 'CalendarEntry($source,$displayTitle,w$weekdayResolved)';
}

/// **平台搜索页 URL**（用户要求"点击能跳转到播放平台"）。
///
/// ## 为什么用"搜索页"而不是"详情页"
/// TMDB 给的是平台**名**（如 `Tencent Video`），不是该平台的剧集 id
/// ⇒ 无法直接拼详情页。而搜索页只要剧名就能定位（用户点一下就到）。
///
/// ## 各平台 URL 规律（全部实测 HTTP 200）
/// | 平台 | URL 模板 |
/// |---|---|
/// | 腾讯视频 | `v.qq.com/x/search/?q={q}` |
/// | 爱奇艺 | `so.iqiyi.com/so/q_{q}` |
/// | 优酷 | `so.youku.com/search_video/q_{q}` |
/// | 芒果TV | `mgtv.com/search/?q={q}` |
/// | B站 | `search.bilibili.com/all?keyword={q}` |
/// | 豆瓣（兜底） | `search.douban.com/movie/subject_search?search_text={q}` |
///
/// ## 返回 null 的语义
/// 平台为空或未识别 ⇒ 返回 null ⇒ UI **不显示可点样式**
///（比点进去 404 好）。
String? platformSearchUrl(String? platform, String title) {
  if (platform == null || platform.isEmpty || title.isEmpty) return null;
  final q = Uri.encodeComponent(title);
  if (platform.contains('腾讯')) return 'https://v.qq.com/x/search/?q=$q';
  if (platform.contains('爱奇艺')) return 'https://so.iqiyi.com/so/q_$q';
  if (platform.contains('优酷')) {
    return 'https://so.youku.com/search_video/q_$q';
  }
  if (platform.contains('芒果')) return 'https://www.mgtv.com/search/?q=$q';
  if (platform.contains('B站') || platform.toLowerCase().contains('bilibili')) {
    return 'https://search.bilibili.com/all?keyword=$q';
  }
  if (platform.contains('CCTV')) {
    return 'https://search.cctv.com/search.php?qtext=$q';
  }
  // 卫视/未识别 ⇒ 用豆瓣搜索（一定能定位到该剧）
  return 'https://search.douban.com/movie/subject_search?search_text=$q';
}

/// 一个源的抓取结果（**失败隔离**：一个源挂了不影响其余）。
class CalendarSourceResult {
  const CalendarSourceResult({
    required this.source,
    required this.label,
    this.entries = const [],
    this.error,
  });

  final String source;
  final String label;
  final List<CalendarEntry> entries;

  /// 非空表示该源失败（UI 显示一行提示，而不是整体报错）。
  final String? error;

  bool get ok => error == null;
}

/// 周视图数据（周一到周日）。
class WeekCalendar {
  const WeekCalendar({required this.sources, required this.entries});

  /// 各源的状态（含失败原因）。
  final List<CalendarSourceResult> sources;

  /// 合并去重后的全部条目。
  final List<CalendarEntry> entries;

  /// 取周几的条目（1=周一 … 7=周日）。
  List<CalendarEntry> forWeekday(int weekday) =>
      entries.where((e) => e.weekdayResolved == weekday).toList();

  /// 取周几的条目，**按类别分组**、组内**按热度降序**（用户要求）。
  ///
  /// ## 排序规则（用户原话："按热度显示"）
  /// · **组间**：动漫 → 综艺 → 剧集（固定顺序，用户列的次序）
  /// · **组内**：`popularity` 降序
  ///   —— 热度缺失（B站/Bangumi 没有该字段）时排到最后，
  ///      但**同源内保持原顺序**（B站本身按时间排，不该打乱）
  ///
  /// ## 为什么缺失热度排最后
  /// 把"未知热度"当 0 会与"热度真的很低"混在一起；
  /// 排最后 + 保持原序，既不打乱 B站的时间序，也不抢占 TMDB 的热度序。
  Map<CalendarCategory, List<CalendarEntry>> forWeekdayGrouped(int weekday) {
    final day = forWeekday(weekday);
    final out = <CalendarCategory, List<CalendarEntry>>{};
    for (final c in CalendarCategory.values) {
      final list = day.where((e) => e.category == c).toList();
      // 稳定排序：先按"有无热度"分两段，段内按热度降序
      // （Dart 的 sort 不保证稳定 ⇒ 自己保证：先算序号再排）
      final withPop = <CalendarEntry>[];
      final noPop = <CalendarEntry>[];
      for (final e in list) {
        if (e.popularity != null && e.popularity! > 0) {
          withPop.add(e);
        } else {
          noPop.add(e);
        }
      }
      withPop.sort((a, b) => b.popularity!.compareTo(a.popularity!));
      out[c] = [...withPop, ...noPop];
    }
    return out;
  }

  /// 有内容的源数量（用于 UI 显示"来自 N 个源"）。
  int get okSourceCount => sources.where((s) => s.ok).length;

  int get failedSourceCount => sources.where((s) => !s.ok).length;

  bool get isEmpty => entries.isEmpty;
}

/// 追剧日历客户端：并行抓多个源，**失败隔离**，合并去重。
///
/// ## 为什么不用 `Future.wait`（会被一个失败拖垮）
/// `Future.wait` 默认"任一 future 抛异常就整体抛" ⇒ 一个源挂掉会让
/// 整个日历空白。改为每个 future **自己 catch**（与
/// `aggregated_search.dart` 的多服务器搜索同一策略）。
class CalendarClient {
  CalendarClient({Dio? dio, this.cache})
      : _dio = dio ??
            Dio(BaseOptions(
              // ★ 超时必须够大（真网测试抓到：Bangumi 单响应 **77 KB**）
              //
              // ## 实测（2026-10-11）
              // Bangumi `/calendar` 返回 77,594 字节；TVmaze 7 天**并行**
              // 会同时占带宽 ⇒ 原 12s 超时**偶发超时**（真网测试直接抓到
              // "Bangumi 超时"，而同一时刻 Python 裸请求秒回）。
              // ⇒ 连/收超时都提到 25s。
              connectTimeout: const Duration(seconds: 25),
              receiveTimeout: const Duration(seconds: 25),
              // ⚠️ 不让 dio 因 4xx/5xx 抛异常 —— 由我们按状态码分支处理
              validateStatus: (_) => true,
            ));

  final Dio _dio;

  /// 缓存（可后置注入 —— 见 `calendarClientProvider`）。
  CalendarCache? cache;

  /// UA 必须带（Bangumi 对空 UA 会 403；B站要求 Referer）。
  ///
  /// ## ⚠️ Bangumi 官方对 UA 有**明确要求**（调研取证，2026-10-11）
  /// 其文档原文：
  /// > "非浏览器的 API 使用者请指定一个带有**开发者个人 ID 和应用名称**
  /// >  的 User Agent"
  /// 并**明确禁止** `Bangumi/1.0` 这类泛化 UA。
  /// ⇒ 用 `bsfcxz/CineFlow/1.0 (Android) (<repo>)` 形式（带开发者 ID）。
  ///
  /// 实测：**不带 UA 请求 `/calendar` 直接失败**（HTTP 0，连接被拒），
  /// 带上则 200 + 77,594 字节。
  static const _ua = 'bsfcxz/CineFlow/1.0 (Android) '
      '(+https://github.com/bsfcxz/CineFlow)';

  /// 缓存 TTL —— **按"是否本周"分档**（调研取证：MoviePilot 用 6h）。
  ///
  /// ## 为什么要分档
  /// · **本周（含今天）**：B站时间线当天会滚动更新（新番可能改期，
  ///   且响应里有 `delay` / `delay_reason` 字段）⇒ **30 分钟**足够新鲜
  /// · **未来/整周**：节目表基本固定 ⇒ **6 小时**（省流量）
  ///
  /// ⚠️ 失败响应**不缓存**（见各 `_fetchXxx`：出错时直接 return，
  ///    不调 `cache.put`）—— 否则一次网络抖动会"锁定"半小时。
  static const cacheTtl = Duration(hours: 6);

  /// 本周数据的短 TTL（见 [cacheTtl] 说明）。
  static const todayTtl = Duration(minutes: 30);

  /// **每个源的独立 deadline**（`fetchWeek` 用它包住每个源）。
  ///
  /// ## 为什么必须"每源独立"（真机验证抓到：整页转圈 12 秒）
  /// `Future.wait` 会等**所有** future 完成 ⇒ **最慢的源决定整页时间**。
  /// 真机实测：Bangumi 的退避 + 慢响应让日历页 **转圈 12 秒**，
  /// 用户体感是"页面坏了"（截图确认卡在 loading）。
  ///
  /// ⇒ 每个源单独 `timeout(perSourceDeadline)`：
  ///   超时的源按"失败"处理（UI 显示"暂不可用"），**其余源照常展示**。
  ///
  /// ## 为什么是 7 秒（实测取舍）
  /// · Bangumi：退避 3s + 两次请求 ≈ 4–6s ⇒ 能容纳
  /// · TVmaze：7 个请求并发（实测单请求 7.8s，**这个值会撞线**）
  ///   ⇒ 见 `_fetchTvmaze` 的说明：已砍到 7 请求 + 只算星期
  /// · B站：1 个请求 ⇒ 秒级
  ///
  /// 超过 7 秒的源已属"明显异常"，此时**先给用户看结果**比等它更重要。
  static const perSourceDeadline = Duration(seconds: 7);

  // ══════════════════════════════════════════════════════════
  // 公开入口
  // ══════════════════════════════════════════════════════════

  /// 抓取整周日历（并行 + 失败隔离 + 合并去重）。
  ///
  /// [tmdbKey] 为空时**跳过 TMDB**（它不是必需源）。
  Future<WeekCalendar> fetchWeek({String? tmdbKey}) async {
    // ★★ **每源独立超时**（真机验证抓到：整页卡 12 秒）
    //
    // ## 为什么必须加（`Future.wait` 等最慢的那个）
    // `Future.wait` 等**所有** future 完成 ⇒ **最慢的源决定整页加载时间**。
    // 真机实测：Bangumi 的 8 秒退避 ⇒ 打开日历**转圈 12 秒**
    //（截图确认卡在 loading）。用户体感是"页面坏了"。
    //
    // ## 修法：给每个源一个**独立 deadline**
    // 超时的源按"失败"处理（UI 显示"暂不可用"，其余源照常展示）。
    // 这与调研结论一致：fan-out 必须"每台独立 deadline"，
    // 否则一台慢就拖垮整体。
    //
    // ⚠️ deadline 取 7 秒的取舍：
    // · Bangumi 退避 3s + 两次请求 ≈ 4–6s ⇒ 能容纳
    // · TVmaze 18 个请求分批（见 `_fetchTvmaze`）≈ 3–5s ⇒ 能容纳
    // · 超过 7s 的源已"明显异常"，此时**先给用户看结果**更重要
    // ⚠️ 必须是**每源**独立 deadline（`Future.wait` 的语义是"等最慢的"）

    Future<CalendarSourceResult> guard(
      Future<CalendarSourceResult> f,
      String source,
      String label,
    ) async {
      try {
        return await f.timeout(perSourceDeadline);
      } on TimeoutException {
        debugPrint('[Calendar] $label 超时'
            '（>${perSourceDeadline.inSeconds}s）⇒ 跳过');
        return CalendarSourceResult(
            source: source, label: label, error: '超时（已跳过）');
      } catch (e) {
        return CalendarSourceResult(source: source, label: label, error: '$e');
      }
    }

    // ★★ 源清单（2026-10-11 按用户要求重构：删 TVmaze，聚焦国内）
    //
    // ## 用户要求
    // > "删除 TVmaze …… 我在中国，主要聚焦国内的 腾讯、爱奇艺、b站、优酷等
    // >  国产剧集" / "国内的可以调用 tmdb 获取"
    //
    // ## 实测依据（本轮，全部真实请求）
    // | 源 | 结论 |
    // |---|---|
    // | **TMDB** `discover/tv` + `air_date.gte/lte` | ✅ 换 5 个日期结果**全不同** ⇒ 过滤真生效；<br>每天 20 条**全是国产剧**（`lang=zh`） ⇒ **主力** |
    // | **B站时间线** | ✅ 可用，但 `types=1`（番剧）/`types=4`（国创）**只有动漫**；<br>实测 2/3/5/6 全空 ⇒ **B站没有国产真人剧** |
    // | Bangumi | ❌ WAF 拦 TLS 指纹（本机/真机都不可达，已留证据） |
    // | ~~TVmaze~~ | 用户明确不要 ⇒ **已删** |
    // | 腾讯 pbaccess | ❌ `ret=0` 但 **`data` 为 None**（空壳） |
    // | 爱奇艺 videolib | ❌ `risk_level:2` + **`data` 为 None**（风控） |
    // | 优酷 | ❌ mtop 200 但无可用剧集列表 |
    //
    // ⚠️ 腾讯/爱奇艺/优酷**不是"懒得做"** —— 是实测拿不到数据
    //    （三家都返回 HTTP 200 但内容为空/风控标记）。
    //    这是**它们的反爬策略**，客户端无法绕过。
    final tasks = <Future<CalendarSourceResult>>[
      // ★ TMDB 是国产剧集的主力源（用户要求 + 实测有效）
      if (tmdbKey != null && tmdbKey.isNotEmpty)
        guard(_fetchTmdb(tmdbKey), 'tmdb', 'TMDB 国产剧集'),
      // ★ B站补动漫（番剧 + 国创）—— 它**没有国产真人剧**，故只是补充
      guard(_fetchBilibili(), 'bilibili', 'B站番剧/国创'),
      guard(_fetchBangumi(), 'bangumi', 'Bangumi 番剧'),
    ];
    final results = await Future.wait(tasks);
    // ★★ 记住"哪个源这次彻底失败" ⇒ 短时间内**不再重试它**
    //
    // ## 为什么必须记（真网测试抓到的 UX 问题）
    // Bangumi 的退避重试要等 8 秒；而它在本机/真机**必定失败**
    // （WAF 按 TLS 指纹拦截，见 `docs/CALENDAR-SOURCES.md`）
    // ⇒ 每次打开日历都要白等 8 秒（实测缓存全命中时仍耗时 **8.4 秒**）。
    //
    // ⇒ 失败的源进入**冷却名单**，冷却期内直接跳过（不发请求、不等退避）。
    //    冷却结束（用户下次真正刷新日历）才重新尝试 —— 那时网络/环境
    //    可能已变（比如用户切了网络）。
    for (final r in results) {
      if (!r.ok) {
        _failedAt[r.source] = DateTime.now();
      } else {
        _failedAt.remove(r.source);
      }
    }
    final merged = mergeCalendarEntries(
      [for (final r in results) ...r.entries],
    );
    debugPrint('[Calendar] ${results.length} 个源：'
        '成功 ${results.where((r) => r.ok).length} / '
        '失败 ${results.where((r) => !r.ok).length}，'
        '合并后 ${merged.length} 条');
    for (final r in results.where((r) => !r.ok)) {
      debugPrint('[Calendar]   ✗ ${r.label}：${r.error}');
    }
    // ★★ 按源 × 按星期 的分布（真机排查"某天的列表里全是某个源"用）
    //
    // ## 为什么必须打这个（真机现象驱动）
    // 真机实测：合并后 173 条（TMDB 贡献了 74 条），但**周日那一栏
    // 列出的全是 B站**。光看总数「TMDB 成功了」无法判断
    // "它到底落在哪几天" ⇒ 逐源逐天打出来，一眼看出是
    // ① TMDB 没返回某天 ② 还是归星期算错了 ③ 还是 UI 排序问题
    for (final r in results.where((r) => r.ok)) {
      final byDay = <int, int>{};
      for (final e in r.entries) {
        byDay[e.weekdayResolved] = (byDay[e.weekdayResolved] ?? 0) + 1;
      }
      final dist = [for (var d = 1; d <= 7; d++) '${byDay[d] ?? 0}'];
      debugPrint('[Calendar]   ${r.label} 按天(一~日)=${dist.join("/")}');
    }
    final mergedByDay = <int, int>{};
    for (final e in merged) {
      mergedByDay[e.weekdayResolved] = (mergedByDay[e.weekdayResolved] ?? 0) + 1;
    }
    debugPrint('[Calendar]   合并后按天(一~日)='
        '${[for (var d = 1; d <= 7; d++) mergedByDay[d] ?? 0].join("/")}');
    return WeekCalendar(sources: results, entries: merged);
  }

  /// 失败源的冷却记录（source → 失败时刻）。
  final _failedAt = <String, DateTime>{};

  /// 失败冷却期（见 [fetchWeek] 说明）。
  ///
  /// 取 10 分钟：足够避免"反复打开日历都等 8 秒"，
  /// 又不会让用户长时间看不到一个已恢复的源。
  static const failCooldown = Duration(minutes: 10);

  /// 该源是否在冷却期内（冷却中 ⇒ 直接跳过，不请求不等退避）。
  bool _inCooldown(String source) {
    final t = _failedAt[source];
    if (t == null) return false;
    return DateTime.now().difference(t) < failCooldown;
  }

  // ══════════════════════════════════════════════════════════
  // ① Bangumi ——**天生周一~周日**（主力源）
  // ══════════════════════════════════════════════════════════

  /// `GET https://api.bgm.tv/calendar`
  ///
  /// ## 实测返回形状（2026-10-11）
  /// ```json
  /// [ { "weekday": {"en":"Mon","cn":"星期一","ja":"月耀日","id":1},
  ///     "items": [ {"id":390200,"name":"…","name_cn":"…",
  ///                 "air_date":"2026-10-05","air_weekday":1,
  ///                 "rating":{"score":3.5},"images":{"large":"…"}} ] } ]
  /// ```
  /// 实测 7 组，条目数 11/10/12/11/14/21/25 ⇒ **正好是周一到周日**。
  ///
  /// ⚠️ 这是"**当季在播番剧的固定星期表**"，不是"某一天的更新列表"。
  ///    对周番（每周固定时间播出）这正是我们要的语义。
  Future<CalendarSourceResult> _fetchBangumi() async {
    const src = 'bangumi';
    const label = 'Bangumi 番剧';
    const url = 'https://api.bgm.tv/calendar';
    // ★ 冷却期内直接跳过（避免每次都白等 8 秒退避 —— 见 [fetchWeek] 说明）
    if (_inCooldown(src)) {
      return const CalendarSourceResult(
          source: src, label: label, error: '暂不可用（稍后自动重试）');
    }
    try {
      final cached = await cache?.get('calendar:$src');
      String body;
      if (cached != null && cached.isNotEmpty) {
        body = cached;
      } else {
        // ★ 带**退避重试**（见 [bangumiBackoff]：实测的 IP 级限流）
        final r = await _getWithBackoff(url, headers: {'User-Agent': _ua});
        if (r == null || r.statusCode != 200 || r.data == null ||
            r.data!.isEmpty) {
          return const CalendarSourceResult(
              source: src, label: label, error: '接口暂不可用（可能限流）');
        }
        body = r.data!;
        // ⚠️ 只在**成功**时缓存（失败缓存会让日历空半小时）
        await cache?.put('calendar:$src', body, ttl: cacheTtl);
      }
      final j = jsonDecode(body);
      if (j is! List) {
        return const CalendarSourceResult(
            source: src, label: label, error: '返回格式异常');
      }
      final out = <CalendarEntry>[];
      for (final day in j) {
        if (day is! Map) continue;
        final wd = (day['weekday'] as Map?)?['id'];
        final weekday = (wd as num?)?.toInt();
        for (final it in (day['items'] as List? ?? const [])) {
          if (it is! Map) continue;
          final rating = (it['rating'] as Map?)?['score'];
          final imgs = it['images'];
          String? poster;
          if (imgs is Map) {
            poster = (imgs['large'] ?? imgs['common'] ?? imgs['medium'])
                as String?;
          }
          out.add(CalendarEntry(
            title: (it['name'] as String?) ?? '',
            titleCn: it['name_cn'] as String?,
            airDate: it['air_date'] as String?,
            weekday: weekday,
            // ★★ 必须把 `http://` 升成 `https://`（调研取证 + 本项目实测）
            //
            // ## 为什么（不处理会让**海报全部裂掉**）
            // Bangumi 的 `images.large` 实测**全是 `http://lain.bgm.tv/...`**：
            // ```json
            // "images": {"large": "http://lain.bgm.tv/pic/cover/l/1c/...jpg"}
            // ```
            // 而 Android 9+ 默认**禁止明文 HTTP**（cleartext）。
            // 本项目 manifest 虽开了 `usesCleartextTraffic`（为兼容 http Emby），
            // 但图片走 `Image.network` 仍可能被其它策略拦；
            // 且 https 显然更好（防篡改、防运营商劫持）。
            //
            // ⇒ 统一 `http://` → `https://`（lain.bgm.tv 支持 https，
            //   本项目既有 `DoubanImage` 也走同一思路）。
            posterUrl: httpsPosterUrl(poster),
            rating: (rating as num?)?.toDouble(),
            summary: it['summary'] as String?,
            source: src,
            sourceId: it['id']?.toString(),
            bangumiId: (it['id'] as num?)?.toInt(),
          ));
        }
      }
      return CalendarSourceResult(source: src, label: label, entries: out);
    } catch (e) {
      return CalendarSourceResult(
          source: src, label: label, error: _friendly(e));
    }
  }

  // ══════════════════════════════════════════════════════════
  // ② TVmaze —— 按日期（含国漫；实测有国漫条目）
  // ══════════════════════════════════════════════════════════

  // ══════════════════════════════════════════════════════════
  // ③ B站番剧时间线
  // ══════════════════════════════════════════════════════════

  /// `GET https://api.bilibili.com/pgc/web/timeline?types=1,4&before=6&after=6`
  ///
  /// ## ★★ 三个实测坑（调研取证，每个都会导致错误）
  ///
  /// ### 坑 1：`types` 要带上 `4`（国创），否则漏国漫
  /// `types=1` 只给**番剧**；`types=1,4` 才含**国创**。
  /// 对中文用户国漫很重要（实测 `types=1` 也返回 0 条的情况多见于
  /// 该时间窗内无排期，而非参数错）。
  ///
  /// ### 坑 2：`before`/`after` **硬上限 7**
  /// 实测：`before=7&after=7` → `code=0`（15 天）；
  /// `before=8&after=8` → **`code=-400` 请求错误**。
  /// ⇒ 传 6（覆盖整周 13 天，足够）。
  ///
  /// ### 坑 3：`date` 字段**没有年份**（`"10-5"`）
  /// 实测响应里 `date` 是 `"10-5"` 形态 ⇒ `DateTime.tryParse` **必然失败**。
  /// 但同一对象里有 **`date_ts`**（Unix 秒，北京时间当天 0 点）
  /// ⇒ 必须用 `date_ts` 推日期。
  /// 我第一版直接用 `date` 字符串 ⇒ 全部解析失败 ⇒ 全归周一（真网测试抓到）。
  ///
  /// ## 返回形状（实测）
  /// ```json
  /// {"code":0,"message":"success",
  ///  "result":[{"date":"10-5","date_ts":1791129600,"day_of_week":1,
  ///    "episodes":[{"title":"…","pub_index":"第14话",
  ///                 "pub_ts":…,"cover":"…","season_id":298872}]}]}
  /// ```
  /// 实测 `date_ts=1791129600` → UTC+8 = `2026-10-05 00:00` ⇒ **全链路按 UTC+8**。
  Future<CalendarSourceResult> _fetchBilibili() async {
    const src = 'bilibili';
    const label = 'B站番剧时间线';
    const url = 'https://api.bilibili.com/pgc/web/timeline';
    try {
      final cached = await cache?.get('calendar:$src');
      String body;
      if (cached != null && cached.isNotEmpty) {
        body = cached;
      } else {
        final r = await _dio.get<String>(
          url,
          queryParameters: {
            'types': '1,4', // ★ 1=番剧 4=国创（见"坑 1"）
            'before': '6', // ★ 上限 7（见"坑 2"）
            'after': '6',
          },
          options: Options(responseType: ResponseType.plain, headers: {
            'User-Agent': _ua,
            // ★ 必须带 Referer（实测）
            'Referer': 'https://www.bilibili.com/',
          }),
        );
        if (r.statusCode != 200 || r.data == null) {
          return const CalendarSourceResult(
              source: src, label: label, error: '接口返回异常');
        }
        body = r.data!;
        await cache?.put('calendar:$src', body, ttl: todayTtl);
      }
      final j = jsonDecode(body);
      if (j is! Map) {
        return const CalendarSourceResult(
            source: src, label: label, error: '返回格式异常');
      }
      final code = (j['code'] as num?)?.toInt();
      if (code != 0) {
        // ⚠️ 不投递 api_key/完整 URL（只报 code，安全红线）
        return CalendarSourceResult(
            source: src, label: label, error: '接口 code=$code');
      }
      final out = <CalendarEntry>[];
      for (final day in (j['result'] as List? ?? const [])) {
        if (day is! Map) continue;
        // ★★ 用 `date_ts` 推日期（`date` 没有年份，见"坑 3"）
        final date = _dateFromTs(day['date_ts']) ??
            _fixBiliDate(day['date'] as String?);
        final weekday = _weekdayOf(date);
        for (final ep in (day['episodes'] as List? ?? const [])) {
          if (ep is! Map) continue;
          final title = (ep['title'] as String?) ?? '';
          if (title.isEmpty) continue;
          out.add(CalendarEntry(
            title: title,
            airDate: date,
            weekday: weekday,
            // B站的 `pub_index` 是中文最自然的集数表述（"第14话"）
            episode: (ep['pub_index'] as String?)?.isNotEmpty == true
                ? ep['pub_index'] as String?
                : (ep['pub_time'] as String?),
            posterUrl: httpsPosterUrl(ep['cover'] as String?),
            source: src,
            sourceId: ep['episode_id']?.toString(),
            bangumiId: (ep['season_id'] as num?)?.toInt(),
          ));
        }
      }
      return CalendarSourceResult(source: src, label: label, entries: out);
    } catch (e) {
      return CalendarSourceResult(
          source: src, label: label, error: _friendly(e));
    }
  }

  // ══════════════════════════════════════════════════════════
  // ④ TMDB（辅助：只有"在播"，没有按日端点）
  // ══════════════════════════════════════════════════════════

  /// `GET /3/tv/on_the_air?api_key=…`
  ///
  /// ## ⚠️ 为什么 TMDB 只能当辅助
  /// 实测 TMDB **没有"某天播出什么"的端点**：
  /// · `/tv/on_the_air` = "本周有集更新的剧"（**不告诉你哪天**）
  /// · `/discover/tv` 支持 `first_air_date` 但那是**首播日**，不是更新日
  /// ⇒ 只能把"在播剧"列出来，**无法归入具体星期**
  ///   ⇒ 我们用 `first_air_date` 的星期兜底（≥ 有胜于无）。
  ///
  /// 好处：TMDB 的**中文译名与海报质量**最好，可补 Bangumi 缺的欧美剧。
  /// **按日期**抓国产剧集（本日历的**主力源**，用户明确要求用 TMDB）。
  ///
  /// ## ★★ 为什么从"榜单"改成"按日"（实测驱动的改造）
  /// 上一版用的是 `/tv/on_the_air` —— 它只给"本周有更新的剧"，
  /// **不告诉你哪天**（20 条全是英文剧，与"国产剧日历"需求完全不搭）。
  ///
  /// 本轮实测发现 TMDB **真的支持按播出日筛**：
  /// ```
  /// /discover/tv?air_date.gte=D&air_date.lte=D&with_original_language=zh
  /// 10-11 → 你好星期六、仙逆、现在就出发、武神主宰、披荆斩棘
  /// 10-12 → 吞噬星空、无上神帝、死刑将至、魅影神捕、逆天至尊
  /// 10-13 → 毛雪汪、武神主宰、遮天、一念永恒、炼气十万年
  /// ```
  /// **换 5 个日期结果全部不同** ⇒ 过滤确实生效（不是固定榜单）。
  /// 且全是 `lang=zh` 的国产剧 ⇒ 正好命中用户需求。
  ///
  /// ## 为什么逐天查 7 次（而不是查一次）
  /// `air_date.gte/lte` 只能给**一个区间**；周视图要"每天各有什么"。
  /// 查 `gte=周一&lte=周日` 会得到 7 天混在一起的一大堆，
  /// 且无法知道每条属于哪一天（`discover` 返回里**没有**该剧在本周的
  /// 具体播出日 —— `first_air_date` 是首播日，不是本周更新日）。
  /// ⇒ **必须逐天查**（7 个请求，实测每个 ~0.3s）。
  ///
  /// ## 为什么带 `with_original_language=zh`
  /// 用户明确"聚焦国内"。不带则混入大量欧美剧（实测 20 条里一半是英文）。
  Future<CalendarSourceResult> _fetchTmdb(String apiKey) async {
    const src = 'tmdb';
    const label = 'TMDB 国产剧集';
    final out = <CalendarEntry>[];
    final failures = <String>[];
    final monday = _mondayOfThisWeek();

    // 逐天并行（7 个请求，互不依赖）
    final days = [for (var i = 0; i < 7; i++) monday.add(Duration(days: i))];
    final results = await Future.wait(days.map((d) async {
      final date = _ymd(d);
      final weekday = d.weekday; // 1=Mon … 7=Sun
      final key = 'calendar:$src:$date';
      try {
        final cached = await cache?.get(key);
        String body;
        if (cached != null && cached.isNotEmpty) {
          body = cached;
        } else {
          final r = await _dio.get<String>(
            'https://api.themoviedb.org/3/discover/tv',
            queryParameters: {
              'api_key': apiKey,
              'language': 'zh-CN',
              // ★★ 按**播出日区间**筛（`gte == lte` 即"当天"）
              'air_date.gte': date,
              'air_date.lte': date,
              // ★ 只国产（用户要求"聚焦国内"）
              'with_original_language': 'zh',
              'sort_by': 'popularity.desc',
              'page': '1',
            },
            options: Options(responseType: ResponseType.plain,
                headers: {'User-Agent': _ua}),
          );
          if (r.statusCode == 401) {
            // ⚠️ 不把 api_key 写进错误消息（安全红线）
            failures.add('key 无效');
            return <CalendarEntry>[];
          }
          if (r.statusCode != 200 || r.data == null) {
            failures.add('HTTP ${r.statusCode}');
            return <CalendarEntry>[];
          }
          body = r.data!;
          // ⚠️ 只缓存**成功**的响应（失败缓存会让日历空 6 小时）
          await cache?.put(key, body, ttl: todayTtl);
        }
        final j = jsonDecode(body);
        final list = <CalendarEntry>[];
        for (final it in ((j as Map)['results'] as List? ?? const [])) {
          if (it is! Map) continue;
          final name = (it['name'] as String?) ??
              (it['original_name'] as String?) ??
              '';
          if (name.isEmpty) continue;
          final poster = it['poster_path'] as String?;
          // ★ 类别：TMDB 的 `genre_ids`（见 `CalendarCategory` 的实测表）
          final gids = ((it['genre_ids'] as List?) ?? const [])
              .map((x) => (x as num).toInt())
              .toList();
          list.add(CalendarEntry(
            title: name,
            // TMDB 的 zh-CN 已给中文名；`original_name` 作兜底
            titleCn: it['name'] as String?,
            // ★ `air_date` = 我们查的那一天（这是"当日更新"的语义）
            airDate: date,
            weekday: weekday,
            posterUrl: poster == null
                ? null
                : 'https://image.tmdb.org/t/p/w300$poster',
            rating: (it['vote_average'] as num?)?.toDouble(),
            summary: it['overview'] as String?,
            // ★ 热度（用户要求"按热度显示"）
            popularity: (it['popularity'] as num?)?.toDouble(),
            // ★ 类别（用户要求"按类别区分"）
            category: CalendarCategory.fromTmdbGenres(gids),
            source: src,
            sourceId: it['id']?.toString(),
          ));
        }
        // 已按 popularity.desc 请求 ⇒ 服务端已排好；这里**再排一次**
        // 保证"按热度"是确定性行为（不依赖服务端默认）
        list.sort((a, b) => (b.popularity ?? 0).compareTo(a.popularity ?? 0));
        return list;
      } catch (e) {
        failures.add('$date: ${_friendly(e)}');
        return <CalendarEntry>[];
      }
    }));
    for (final list in results) {
      out.addAll(list);
    }

    if (out.isEmpty && failures.isNotEmpty) {
      // 去重后只报一个原因（7 天同一原因会重复 7 次）
      final uniq = failures.toSet().take(2).join('；');
      return CalendarSourceResult(source: src, label: label, error: uniq);
    }

    return CalendarSourceResult(source: src, label: label, entries: out);
  }

  /// **懒加载播放平台**（用户要求"显示播放平台，点击能跳转"）。
  ///
  /// ## 为什么是懒加载而不是在 `_fetchTmdb` 里一起拉（真机 bug 驱动）
  /// 原实现在 `_fetchTmdb` 末尾补平台，两个问题：
  /// ① `out.take(24)` 里 `out` 是**整周**条目（140 条）
  ///    ⇒ 只覆盖**周一**，用户选周日时**永远拿不到平台**
  /// ② 就算改成"每天各取几条"，7 天 × N 次 + discover 7 次
  ///    **必然超过每源 7s 的 deadline** ⇒ 整个 TMDB 源被砍
  ///
  /// ⇒ 改为：**只给"当前看到的那一天"补**（20 条约 2–3s），
  ///    并按 TMDB id 缓存（同一部剧不重复查）。
  ///
  /// ## 缓存策略
  /// · key = `platform:<tmdbId>`，TTL 用 [cacheTtl]（6h）
  ///   —— 平台归属极少变，长 TTL 合理
  /// · **只缓存成功结果**（失败不缓存，否则"网络抖动"会锁 6 小时）
  ///
  /// ## 返回
  /// `tmdbId → 中文平台名`（拿不到的条目**不在 map 里**，UI 显示"未知"）。
  Future<Map<String, String>> fetchPlatforms(
    List<CalendarEntry> entries, {
    required String apiKey,
    int limit = 20,
  }) async {
    final out = <String, String>{};
    // 只处理 TMDB 条目（B站/Bangumi 没有平台概念）
    final targets = entries
        .where((e) => e.source == 'tmdb' && (e.sourceId?.isNotEmpty ?? false))
        .take(limit)
        .toList();
    if (targets.isEmpty) return out;

    // 先查缓存
    final need = <CalendarEntry>[];
    for (final e in targets) {
      final c = await cache?.get('platform:${e.sourceId}');
      if (c != null && c.isNotEmpty) {
        out[e.sourceId!] = c;
      } else {
        need.add(e);
      }
    }
    if (need.isEmpty) return out;

    // 限并发 6（TMDB 约 40 请求/10s）
    const concurrency = 6;
    for (var i = 0; i < need.length; i += concurrency) {
      final batch = need.skip(i).take(concurrency).toList();
      await Future.wait(batch.map((e) async {
        try {
          final r = await _dio.get<String>(
            'https://api.themoviedb.org/3/tv/${e.sourceId}',
            queryParameters: {'api_key': apiKey, 'language': 'zh-CN'},
            options: Options(responseType: ResponseType.plain,
                headers: {'User-Agent': _ua}),
          );
          if (r.statusCode != 200 || r.data == null) return;
          final jd = jsonDecode(r.data!);
          final nets = ((jd as Map)['networks'] as List?) ?? const [];
          final names = [
            for (final n in nets)
              if (n is Map && (n['name'] as String?)?.isNotEmpty == true)
                n['name'] as String
          ];
          if (names.isEmpty) return;
          final cn = cnPlatformName(names.first);
          out[e.sourceId!] = cn;
          await cache?.put('platform:${e.sourceId}', cn, ttl: cacheTtl);
        } catch (_) {
          // 单条失败不影响其余（平台是"锦上添花"）
        }
      }));
    }
    debugPrint('[Calendar] 平台补查：${out.length}/${targets.length} 条'
        '（缓存命中 ${targets.length - need.length}）');
    return out;
  }

  /// **拉完整详情**（供"点击查看简介"弹层）。
  ///
  /// ## 一次请求拿全部（`append_to_response` 的价值）
  /// `GET /tv/{id}?append_to_response=credits&language=zh-CN`
  /// 实测同时返回：简介 / 评分 / 人数 / 类型 / 平台 / 国家 /
  /// 季数集数 / 状态 / 官网 / **演员（含角色名）/ 导演 / 创作者**
  /// ⇒ 不必"先拉基本信息再拉 credits"两次请求。
  ///
  /// ## 缓存
  /// key = `detail:<tmdbId>`，TTL 用 [cacheTtl]（6h）。
  /// 详情变化很慢（评分/演员），长 TTL 合理。
  ///
  /// ## 返回 null 的语义
  /// 拉取失败或 id 无效 ⇒ **返回 null**（UI 显示"暂无详情"），
  /// **不抛异常**（详情是"锦上添花"，不该让弹层崩）。
  Future<CalendarDetail?> fetchDetail(
    String tmdbId, {
    required String apiKey,
  }) async {
    if (tmdbId.isEmpty) return null;
    final cacheKey = 'detail:$tmdbId';
    try {
      final cached = await cache?.get(cacheKey);
      if (cached != null && cached.isNotEmpty) {
        return _parseDetail(cached);
      }
      final r = await _dio.get<String>(
        'https://api.themoviedb.org/3/tv/$tmdbId',
        queryParameters: {
          'api_key': apiKey,
          'language': 'zh-CN',
          // ★ 一次请求同时拿 credits（演员+导演）——
          //   分开拉会多一次请求，且实测没必要
          'append_to_response': 'credits',
        },
        options: Options(responseType: ResponseType.plain,
            headers: {'User-Agent': _ua}),
      );
      if (r.statusCode != 200 || r.data == null) {
        debugPrint('[Calendar] 详情拉取失败 HTTP ${r.statusCode}');
        return null;
      }
      await cache?.put(cacheKey, r.data!, ttl: cacheTtl);
      return _parseDetail(r.data!);
    } catch (e) {
      debugPrint('[Calendar] 详情拉取异常: ${_friendly(e)}');
      return null;
    }
  }

  /// 解析 `/tv/{id}?append_to_response=credits` 的响应。
  ///
  /// ⚠️ 全部字段防御式取值（§5.3）—— TMDB 的字段**常缺**
  ///（实测《你好，星期六》的 `episode_run_time` 有值而
  /// 《仙逆》的是空数组；`created_by` 也可能为空）。
  CalendarDetail _parseDetail(String body) {
    final j = jsonDecode(body) as Map;
    String? str(Object? v) {
      final s = v?.toString();
      return (s == null || s.isEmpty) ? null : s;
    }

    List<String> names(Object? list, {bool cn = false}) => [
          for (final x in (list as List? ?? const []))
            if (x is Map && (x['name'] as String?)?.isNotEmpty == true)
              cn ? cnPlatformName(x['name'] as String) : x['name'] as String
        ];

    // 导演 = `created_by`（剧集的"创作者"，实测《仙逆》= 耳根）
    //      + `crew[job == 'Director']`（实测 = 石头熊/冯毅）
    // 两者都可能有值，合并去重。
    final directors = <String>[];
    for (final c in (j['created_by'] as List? ?? const [])) {
      if (c is Map && (c['name'] as String?)?.isNotEmpty == true) {
        directors.add(c['name'] as String);
      }
    }
    final credits = j['credits'];
    if (credits is Map) {
      for (final c in (credits['crew'] as List? ?? const [])) {
        if (c is Map && c['job'] == 'Director') {
          final n = c['name'] as String?;
          if (n != null && n.isNotEmpty && !directors.contains(n)) {
            directors.add(n);
          }
        }
      }
    }

    // 主演：**带角色名**（实测 `('史泽鲲', '王林 (voice)')`）——
    // 比豆瓣的纯名字更有信息量。角色名去掉 `(voice)` 这类括注。
    final actors = <String>[];
    if (credits is Map) {
      for (final c in (credits['cast'] as List? ?? const [])) {
        if (c is! Map) continue;
        final n = c['name'] as String?;
        if (n == null || n.isEmpty) continue;
        final role = (c['character'] as String? ?? '')
            .replaceAll(RegExp(r'\s*\(.*?\)'), '')
            .trim();
        actors.add(role.isEmpty ? n : '$n 饰 $role');
        if (actors.length >= 12) break;
      }
    }

    final poster = str(j['poster_path']);
    final backdrop = str(j['backdrop_path']);
    return CalendarDetail(
      title: (str(j['name']) ?? str(j['original_name'])) ?? '',
      originalTitle: str(j['original_name']),
      overview: str(j['overview']),
      tagline: str(j['tagline']),
      posterUrl: poster == null
          ? null
          : 'https://image.tmdb.org/t/p/w300$poster',
      backdropUrl: backdrop == null
          ? null
          : 'https://image.tmdb.org/t/p/w780$backdrop',
      rating: (j['vote_average'] as num?)?.toDouble(),
      voteCount: (j['vote_count'] as num?)?.toInt(),
      firstAirDate: str(j['first_air_date']),
      lastAirDate: str(j['last_air_date']),
      genres: names(j['genres']),
      countries: [
        for (final c in (j['origin_country'] as List? ?? const []))
          if (c is String && c.isNotEmpty) countryName(c)
      ],
      platforms: names(j['networks'], cn: true),
      directors: directors,
      actors: actors,
      seasonCount: (j['number_of_seasons'] as num?)?.toInt(),
      episodeCount: (j['number_of_episodes'] as num?)?.toInt(),
      status: str(j['status']),
      homepage: str(j['homepage']),
      tmdbId: (j['id'] ?? '').toString(),
    );
  }

  /// 平台补查的**条数上限**（保留给将来"全量预取"用）。
  ///
  /// 取 24：覆盖"一天 20 条"这个实测规模，且并发 6 ⇒ 最多 4 批
  ///（每批约 1s）⇒ 总耗时约 4s，仍在每源 7s deadline 内。
  static const platformFetchLimit = 24;

  /// TMDB 的 network 名 → **中文平台名**（"点击跳转"要用中文关键词）。
  ///
  /// ## 为什么需要映射
  /// TMDB 返回英文/混合名：`Tencent Video` / `iQIYI` / `Mango TV` /
  /// `bilibili` / `Youku` —— 而用户看到中文名才有意义，
  /// 且跳转时要按平台选**对应的搜索页**（见 `platformSearchUrl`）。
  ///
  /// ## network id 依据（实测 `search/company`）
  /// ```
  /// Tencent Video → 74457      iQIYI → 172414
  /// Youku → 48460              MangoTV → 139947
  /// bilibili → 123270
  /// ```
  /// ⚠️ 有些剧挂在**电视台**（`Hunan Television`）而非流媒体
  /// ⇒ 那种映射到"湖南卫视"，跳转时用它自己的搜索词。
  static String cnPlatformName(String tmdbName) {
    final n = tmdbName.toLowerCase();
    if (n.contains('tencent') || n.contains('qq')) return '腾讯视频';
    if (n.contains('iqiyi') || n.contains('爱奇艺')) return '爱奇艺';
    if (n.contains('youku') || n.contains('优酷')) return '优酷';
    if (n.contains('mango') || n.contains('mgtv')) return '芒果TV';
    if (n.contains('bilibili')) return 'B站';
    if (n.contains('hunan')) return '湖南卫视';
    if (n.contains('zhejiang')) return '浙江卫视';
    if (n.contains('jiangsu')) return '江苏卫视';
    if (n.contains('dragon') || n.contains('shanghai')) return '东方卫视';
    if (n.contains('cctv')) return 'CCTV';
    // 未识别的保留原名（比显示"未知"更有信息量）
    return tmdbName;
  }

  // ══════════════════════════════════════════════════════════
  // 工具
  // ══════════════════════════════════════════════════════════

  /// ★★ **Bangumi 有 IP 级限流**（实测确认，2026-10-11）
  ///
  /// ## 证据链（不是猜测）
  /// 1. 开发期密集探测后，`api.bgm.tv/calendar` 从正常变为
  ///    **`ConnectionResetError` / `HandshakeException`**
  /// 2. 等待 60 秒后**连续 5 次全部恢复**（HTTP 200 / 77,594 字节 / 0.7s）
  /// 3. **同期 TVmaze / B站 一切正常** ⇒ 不是本机网络问题
  ///
  /// ## 为什么表现为"TLS 握手失败"（而不是 429）
  /// 服务端在**握手阶段就断开连接**（TCP RST），而不是返回 HTTP 状态码。
  /// ⇒ Dart 侧看到的是 `HandshakeException`，**极易误判为 TLS 不兼容**
  ///   （我第一版就是这么误判的）。
  ///
  /// ## 修法（三条，都必须有）
  /// 1. **退避重试**：命中后等 [bangumiBackoff] 再试一次（只重试 1 次，
  ///    避免加重限流）
  /// 2. **失败不缓存**：否则一次限流会让日历空半小时
  /// 3. **TTL 别太短**：频繁刷新等于自助限流（6h 已足够）
  ///
  /// ⚠️ 退避值从 8s **降到 3s**（真机验证后调整）：
  /// 8s 会让这个源**必然**撞上 `fetchWeek` 的 7s 独立 deadline
  /// ⇒ 永远以"超时"收场，连"限流"这个真实原因都报不出来。
  /// 3s 能容纳两次请求（限流通常几百毫秒就断），
  /// 且总耗时留在 deadline 之内。
  static const bangumiBackoff = Duration(seconds: 3);

  /// 带**退避重试**的 GET（专治 Bangumi 的 IP 级限流）。
  ///
  /// ## 为什么只重试 1 次
  /// 限流是"请求量触发"的 ⇒ 连续重试只会**加重**限流。
  /// 等 [bangumiBackoff] 后试一次；仍失败就如实报错（UI 显示该源不可用，
  /// 其余源不受影响）。
  ///
  /// ## 为什么捕获所有异常（而不只 DioException）
  /// 实测限流表现为 `HandshakeException`（TLS 层），
  /// 它包在 `DioException(type: unknown)` 里 —— 但为保险起见
  /// 用 `catch (_)` 兜住一切（包括将来可能出现的其它形态）。
  Future<Response<String>?> _getWithBackoff(
    String url, {
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final r = await _dio.get<String>(
          url,
          queryParameters: query,
          options: Options(
            responseType: ResponseType.plain,
            headers: headers,
          ),
        );
        if (r.statusCode == 200 && r.data != null && r.data!.isNotEmpty) {
          return r;
        }
        if (r.statusCode == 429) {
          // 显式限流：等一下再试
          if (attempt == 0) {
            await Future<void>.delayed(bangumiBackoff);
            continue;
          }
        }
        return r;
      } catch (_) {
        // 限流常表现为"握手被断开"（不是 HTTP 状态码）
        if (attempt == 0) {
          debugPrint('[Calendar] 请求失败，${bangumiBackoff.inSeconds}s 后重试一次'
              '（Bangumi 实测有 IP 级限流）');
          await Future<void>.delayed(bangumiBackoff);
          continue;
        }
        return null;
      }
    }
    return null;
  }

  /// 把异常转成**给用户看的**短句（不带内部栈/URL）。
  static String _friendly(Object e) {
    if (e is DioException) {
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.sendTimeout:
          return '超时';
        case DioExceptionType.connectionError:
          return '网络不可达';
        default:
          return '请求失败';
      }
    }
    return '解析失败';
  }

  /// 本周周一（**本地时区**，零点）。
  ///
  /// ## 为什么以本地时区算"这一周"
  /// 用户看的是自己的周历 —— 用 UTC 会在跨时区时把"周一"算错一天。
  /// `DateTime.weekday` 的 1=周一 与我们的约定一致。
  static DateTime _mondayOfThisWeek() {
    final now = DateTime.now();
    final d = DateTime(now.year, now.month, now.day);
    return d.subtract(Duration(days: d.weekday - 1));
  }

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// 由 `yyyy-MM-dd` 算星期几（1=周一…7=周日）。解析失败返回 1。
  static int _weekdayOf(String? ymd) {
    if (ymd == null || ymd.isEmpty) return 1;
    final d = DateTime.tryParse(ymd);
    return d?.weekday ?? 1;
  }

  /// Unix 秒 → `yyyy-MM-dd`（按 **UTC+8** 解释）。
  ///
  /// ## 为什么按 UTC+8
  /// B站的 `date_ts` 实测是"北京时间当天 0 点"的 Unix 秒
  /// （`1791129600` → UTC+8 = `2026-10-05 00:00`）。
  /// 若按 UTC 解释会**整体偏一天**（变成 10-04 16:00）。
  static String? _dateFromTs(Object? ts) {
    final n = (ts as num?)?.toInt();
    if (n == null || n <= 0) return null;
    final d = DateTime.fromMillisecondsSinceEpoch(n * 1000, isUtc: true)
        .add(const Duration(hours: 8));
    return _ymd(d);
  }

  /// 兜底：把 B站的无年份 `date`（`"10-5"`）补成 `yyyy-MM-dd`。
  ///
  /// ## 为什么要这个兜底
  /// B站响应里 `date` 是 `"10-5"`（**没有年份**）⇒ `DateTime.tryParse`
  /// 必然返回 null ⇒ 所有条目会归到同一天（我第一版就是这样，
  /// 真网测试抓到"56 条 → 8 条"）。主路径用 `date_ts`，这是保险丝。
  ///
  /// ⚠️ 年份取**当前年**：跨年周（12/29–1/4）会偏一年，
  ///    但那时 `date_ts` 一定存在（主路径生效）⇒ 影响可忽略。
  static String? _fixBiliDate(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final m = RegExp(r'^(\d{1,2})-(\d{1,2})$').firstMatch(raw.trim());
    if (m == null) {
      // 已是 `yyyy-MM-dd` 形态
      return DateTime.tryParse(raw) != null ? raw : null;
    }
    final y = DateTime.now().year;
    return '$y-${m.group(1)!.padLeft(2, '0')}-${m.group(2)!.padLeft(2, '0')}';
  }


}

/// **合并去重**（多源同一部剧只留一条）。
///
/// ## ★★★ 两次真网测试抓到的 bug（必须记录，否则会重犯）
///
/// ### bug 1：**过度去重**（第一版）
/// key = `(星期, 归一化标题)`，结果：
/// ```
/// 各源合计 56 条 → 合并后 8 条（去重 48 条 = 86%）
/// ```
/// 根因：B站同一部剧**跨天多集**（10-5 第14话 / 10-6 第15话）被压成一条。
/// ⇒ key 必须含**日期**。
///
/// ### bug 2：**误合并不同的剧**（第二版，更危险）
/// 加上日期后仍过度（45%），诊断输出暴露真相：
/// ```
/// «Ну, погоди! Каникулы» vs «Вор в загоне»  ← 完全不同的剧！
/// «Death is Coming» ×5                        ← 5 部**同名**的剧
/// «Embers of the Night» ×2
/// ```
/// 根因：**TVmaze 里同名剧极多**（不同国家/不同年份的"Death is Coming"），
/// 而"标题+日期"无法区分它们。
///
/// ## ★★ 最终判据（**只有强证据才合并**）
/// 调研结论原文："**匹配不上就保留两条，宁可多不可错并**"。
/// 误合并让用户**看不到某部剧**（比看到重复严重得多）。
///
/// 故只保留**两条**强判据：
/// 1. **同源同 id** —— 同一源内一条内容只该出现一次（抓取去重）
/// 2. **外部 ID 相同 + 同日期** —— imdb/tmdb 是全局唯一的，
///    两台服务器都有同一部片时才命中（**这才是"跨服务器聚合"要的**）
///
/// ⚠️ **不再用"标题+日期"做跨源去重** —— 实测它会把
///    `Death is Coming`（5 部不同剧）合成一条，丢掉 4 部。
///
/// ⚠️ 代价（如实）：同一部**中文剧**在 B站与 Bangumi 都出现、
///    且两边都没填外部 ID 时，会显示两条。
///    但这**远好于**丢掉内容 —— 且实测 B站/ Bangumi 的条目本身
///    重复率不高（B站 101 条里只合并掉 2 条）。
List<CalendarEntry> mergeCalendarEntries(List<CalendarEntry> all) {
  final out = <CalendarEntry>[];
  final seenKeys = <String>{};

  for (final e in all) {
    if (e.title.trim().isEmpty) continue;
    final day = e.airDate ?? 'w${e.weekdayResolved}';
    final keys = <String>[
      // ① 同源同 id（**最强**：抓取层的重复，如分页/多次请求带回同一条）
      //
      // ★ 2026-10-11 加日期：TMDB 允许一部剧**同时**属于多个类别
      //   （如既有 16 动漫又有 10764 综艺）⇒ 按类别分别查询时会**重复返回**
      //   同一条 ⇒ 必须带日期才能把它们合并成一条。
      if (e.sourceId != null && e.sourceId!.isNotEmpty)
        'src:${e.source}:${e.sourceId}:${e.airDate ?? e.weekdayResolved}',
      // ② 同源 + 同日期 + 同标题
      //    （同源内同一天的同名条目 = 同一部剧，安全）
      //
      // ⚠️ 必须 `${e.source}` —— `$e.source` 会插值**对象 e**
      //    （Dart 插值陷阱，被单测抓到）
      'same:${e.source}:$day:${normalizeTitle(e.displayTitle)}',
      // ③ **跨源**：外部 ID 相同 + 同日期
      //
      // ★ 这是唯一安全的跨源判据 —— imdb/tmdb 全局唯一。
      //   实测两台真实 Emby 的填充率 75–100%，足够覆盖主要片源。
      if (e.bangumiId != null) 'bgm:${e.bangumiId}:$day',
    ];
    if (keys.any(seenKeys.contains)) continue;
    seenKeys.addAll(keys);
    out.add(e);
  }
  return out;
}

/// `http://` → `https://`（**Bangumi 海报必须处理**，否则海报全裂）。
///
/// ## 为什么必须有（实测 + 调研双重取证）
/// Bangumi 的 `images.large` **全是** `http://lain.bgm.tv/...`：
/// ```json
/// "images": {"large": "http://lain.bgm.tv/pic/cover/l/1c/b4/…jpg"}
/// ```
/// 而 **Android 9+ 默认禁止明文 HTTP**（cleartext）⇒ 不升级就
/// **海报全部裂掉**（图片加载失败，显示占位）。
///
/// ## 为什么是**顶层公开函数**（而不是类内私有 static）
/// 反向注入自查发现：它原本是私有的 ⇒ **无法单测**；
/// 而依赖它的真网测试在 Bangumi 不可达时会**跳过**（本机/真机就是）
/// ⇒ 这个 bug **逃得掉**（实测：禁掉它测试仍全绿）。
/// ⇒ 提到顶层并公开，直接单测（§8.1"纯逻辑提为 public"）。
///
/// ## 语义
/// · `http://…` → `https://…`
/// · 已是 `https://` ⇒ 原样（**幂等**）
/// · null / 空串 / 非 http（ftp、相对路径）⇒ 原样
String? httpsPosterUrl(String? url) {
  if (url == null) return null;
  if (url.isEmpty) return url;
  if (url.startsWith('http://')) return 'https://${url.substring(7)}';
  return url;
}

/// 标题归一化（用于跨源去重）：去标点/空白、统一大小写与全半角。
///
/// 公开导出以便单测（§8.1 要求"纯逻辑提为 public static"）。
String normalizeTitle(String s) {
  final sb = StringBuffer();
  for (final r in s.runes) {
    // 全角 ASCII（FF01–FF5E）→ 半角（21–7E）
    final c = (r >= 0xFF01 && r <= 0xFF5E) ? r - 0xFEE0 : r;
    final ch = String.fromCharCode(c);
    // 只保留字母/数字/汉字（去掉 `：:-—.'"()` 等）
    if (RegExp(r'[A-Za-z0-9\u4e00-\u9fff]').hasMatch(ch)) {
      sb.write(ch.toLowerCase());
    }
  }
  return sb.toString();
}

/// 日历缓存接口（与 `DoubanCache` 同构：复用 drift 的 `cacheGet/cachePut`）。
abstract interface class CalendarCache {
  Future<String?> get(String key);
  Future<void> put(String key, String value, {required Duration ttl});
}

/// 内存实现（单测用）。
final class MemoryCalendarCache implements CalendarCache {
  final _m = <String, (String, DateTime)>{};

  @override
  Future<String?> get(String key) async {
    final v = _m[key];
    if (v == null) return null;
    if (DateTime.now().isAfter(v.$2)) {
      _m.remove(key);
      return null;
    }
    return v.$1;
  }

  @override
  Future<void> put(String key, String value, {required Duration ttl}) async {
    _m[key] = (value, DateTime.now().add(ttl));
  }
}

/// drift 实现（复用 `AppDatabase.cacheGet/cachePut` —— 与豆瓣同一套缓存表）。
///
/// ## 为什么不新建一张表
/// `app_database.dart` 已有通用 KV 缓存（带 TTL），豆瓣就是复用它。
/// 日历数据同样是"带 TTL 的 JSON 文本" ⇒ 同一张表、同一套语义，
/// 新建表只会多一份 migration 负担（且改表要升 schemaVersion）。
final class DriftCalendarCache implements CalendarCache {
  DriftCalendarCache(this._db);

  final dynamic _db; // AppDatabase（避免 data 层反向依赖 db 层类型）

  @override
  Future<String?> get(String key) async =>
      await _db.cacheGet(key) as String?;

  @override
  Future<void> put(String key, String value, {required Duration ttl}) async {
    await _db.cachePut(key, value, ttl: ttl);
  }
}
