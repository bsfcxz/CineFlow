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
import 'db/app_database.dart';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;

/// **某部订阅剧的本周播出情况 + 状态**（追剧 Tab 的周历用）。
///
/// ## 为什么把"状态"和"周历"放在一次请求里
/// 两者都来自 `GET /tv/{id}`（状态在顶层、分集在 `append_to_response`）
/// ⇒ 合并成一次请求，订阅 10 部就省了 10 次往返。
///
/// ## 实测（本轮验证）
/// ```
/// 《仙逆》           status=Returning Series  本周 E162 air_date=2026-10-11
/// 《你好，星期六》    status=Returning Series  本周 E39  air_date=2026-10-10
/// ```
class ShowWeek {
  const ShowWeek({this.days = const {}, this.status, this.nextAirDate});

  /// `weekday(1=周一..7=周日) → 该天播出的集号列表`。
  final Map<int, List<int>> days;

  /// TMDB 原始状态（`Returning Series` / `Ended` / `Canceled` …）。
  final String? status;

  /// **下一次更新的日期**（`yyyy-MM-dd`；null = 未知/已完结）。
  ///
  /// ## 为什么需要"日期"而不只是"周几"（用户要求）
  /// > "下次更新时间你也没整"
  /// 之前只显示"下次更新：周X"，而 `weekday` 对**库内来源**是 null
  /// ⇒ 显示"待定"。库内数据里**有每集首播日** ⇒ 能直接算出日期。
  ///
  /// ## 判据
  /// 取 `days` 里**今天或之后最近的**那天；若本周都已过去（周日之后再无）
  /// ⇒ null（**不编"下周一"** —— 那要靠下一周的 TMDB 数据才知道）。
  final String? nextAirDate;

  /// 中文状态（用户要求区分"已完结/连载中"）。
  ///
  /// ⚠️ 映射规则以**用户可理解的语义**为准，不是逐字翻译：
  /// · `Returning Series` / `In Production` / `Planned` ⇒ **连载中**
  /// · `Ended` / `Canceled` ⇒ **已完结**
  /// · 未知/缺失 ⇒ null（UI 不显示状态标签，**不猜**）
  String? get statusCn => switch (status) {
        'Returning Series' => '连载中',
        'In Production' => '连载中',
        'Planned' => '连载中',
        'Pilot' => '连载中',
        'Ended' => '已完结',
        'Canceled' => '已完结',
        _ => null,
      };

  bool get isEmpty => days.isEmpty;
}

/// **分类浏览的类别**（稿子 180b4d 的 `CATEGORIES`）。
///
/// ## 与 [CalendarCategory] 的区别（别混用）
/// · [CalendarCategory] —— **日历条目的归类**（动漫/综艺/剧集，三档）
/// · [BrowseCategory] —— **浏览面板的筛选项**（六档，含电影/纪录片/儿童）
/// 两者维度不同：一部"纪录片"在日历里可能被归到"剧集"，
/// 但在浏览面板里应该出现在"纪录片"分类下。
enum BrowseCategory {
  series('剧集', '18', 'tv', ['全部', '国产', '港台', '日韩', '欧美'], '📺',
      'first_air_date.desc'),
  // ⚠️ 电影的 `genreId` 是 `null` —— 这是**有意的**（2026-10-15 核实）：
  //    「电影」与「剧集」并列，是**大类**而**不是** genre
  //    ⇒ 硬塞一个 genre（如 `28` 动作）会把"电影"偷偷变成"动作片"。
  //    但它因此**没有任何 genre 筛选** ⇒ `discover/movie` 会返回
  //    **全站热门电影** ⇒ 这是用户报障"6 个类别点开就在一块"的原因之一。
  //    修法：靠 `region`（国产/港台…，见 `BrowseRegion`）+
  //    **独立的排序维度**（下面最后那个参数）来区分。
  movie('电影', null, 'movie', ['全部', '国产', '港台', '日韩', '欧美'], '🎬',
      'primary_release_date.desc'),
  anime('动漫', '16', 'tv', ['全部', '国漫', '日番', '欧美'], '🎌',
      'first_air_date.desc'),
  variety('综艺', '10764|10767', 'tv', ['全部', '国产', '日韩', '欧美'], '🎤',
      'first_air_date.desc'),
  documentary('纪录片', '99', 'tv', ['全部', '国产', '欧美'], '🌍',
      'vote_average.desc'),
  kids('儿童', '10762', 'tv', ['全部', '国产', '欧美'], '🧸',
      'first_air_date.desc');

  const BrowseCategory(this.label, this.genreId, this.kind, this.regions,
      this.emoji, this.sortBy);

  /// **本类别的默认排序维度**（2026-10-15 新增）。
  ///
  /// ## ★ 为什么必须按类别区分（用户报障"点开就在一块"的根因之二）
  /// 原来 **6 个类别全是 `popularity.desc`** ⇒ TMDB 的 popularity 榜是
  /// **全球通用**的 ⇒ 各类别前几条**必然高度重叠**
  /// （尤其"电影"与"剧集"，都是那几部大热片）
  /// ⇒ 用户感觉"点开其实就在一块"。
  ///
  /// ## 各维度的意图（不是随手选的）
  /// | 类别 | 排序 | 为什么 |
  /// |---|---|---|
  /// | 剧集/动漫/综艺/儿童 | `first_air_date.desc` | 用户想看**最近在播的** |
  /// | 纪录片 | `vote_average.desc` | 纪录片看**质量**（时政类时效性弱）|
  /// | 电影 | `primary_release_date.desc` | 用户想看**新片** |
  ///
  /// ## ⚠️ 电影必须配套日期窗口
  /// TMDB 对 `primary_release_date.desc` 有已知行为：
  /// 不限制窗口时会优先返回**很久以前**的高热度片。
  /// ⇒ `fetchBrowse` 会对电影自动补 `primary_release_date.gte`（近 3 年）。
  final String sortBy;

  final String label;

  /// TMDB `with_genres` 值。
  ///
  /// ⚠️ 多值必须用 **`|`**（OR）；逗号是 **AND**
  ///    —— 实测 `10764` → 8 条、`10764,10767` → **1 条**、`10764|10767` → 8 条。
  final String? genreId;

  /// `tv` 或 `movie`（TMDB 两个独立命名空间）。
  final String kind;

  /// 可选的地区列表（稿子里的 regions）。
  final List<String> regions;

  /// 图标（稿子用的是 emoji：📺🎬🎌🎤🌍🧸）。
  ///
  /// ## 为什么用 emoji 而不是 Material 图标
  /// 稿子里就是 emoji，且**各平台的视觉语义**（📺=剧集、🎌=动漫、
  /// 🎤=综艺）比通用 Material 图标更贴切 —— 用户在手机上能秒认。
  final String emoji;
}

/// **热播榜的"状态"维度**（用户 2026-10-12 定义）。
///
/// > "热播的指的是正在连载中或者即将连载的剧集、综艺、动漫以及刚完结不久的，
/// >  还有正在上映的电影、已上映的电影。"
///
/// ## 为什么剧集与电影用**不同**的榜单集合
/// TMDB 的 `with_status` 是**剧集专有**（`Returning Series`/`Ended`…）；
/// 电影没有"在播/完结"的概念 ⇒ 只能靠 `primary_release_date` 窗口。
/// ⇒ 枚举里保留 4 个值，但**电影只用 showing / upcoming**。
enum HotBoard {
  /// 在播（剧集/综艺/动漫）—— `with_status=0`
  airing('在播'),

  /// 将播 —— `with_status=1|2`（Planned | In Production）
  upcoming('即将播出'),

  /// 刚完结 —— `with_status=3` + 近 N 天
  recentEnded('刚完结'),

  /// 正在上映（电影）—— `primary_release_date` 近 30 天
  showing('正在上映');

  const HotBoard(this.label);
  final String label;
}

/// **地区筛选**（稿子里的 `国产/港台/日韩/欧美` 等）。
///
/// ## ★★ 两个实测得出的要点
/// ① `with_origin_country` 多值必须用 **`|`**（与 `with_genres` 同一个坑：
///    逗号是 AND ⇒ 会要求"同时属于 HK 和 TW" ⇒ 0 条）
/// ② **"国产"要额外加 `with_original_language=zh`**
///    —— 只用 `origin_country=CN` 会混入大量合拍片
///    （实测"剧集/全部"第一条是《爱·回家之开心速递》，那是港剧）
class BrowseRegion {
  const BrowseRegion(this.label, this.countries, {this.forceChinese = false});

  final String label;

  /// ISO 3166-1 两字母码列表（null = 不限地区）。
  final List<String>? countries;

  /// 是否强制 `original_language=zh`（"国产/国漫"用）。
  final bool forceChinese;

  static const all = BrowseRegion('全部', null);
  static const cn = BrowseRegion('国产', ['CN'], forceChinese: true);
  static const gangtai = BrowseRegion('港台', ['HK', 'TW']);
  static const rihan = BrowseRegion('日韩', ['JP', 'KR']);
  static const oumei = BrowseRegion('欧美', ['US', 'GB', 'FR', 'DE']);
  static const guoman = BrowseRegion('国漫', ['CN'], forceChinese: true);
  static const rifan = BrowseRegion('日番', ['JP']);

  /// 按中文名取（`BrowseCategory.regions` 里存的是中文）。
  static BrowseRegion byLabel(String s) => switch (s) {
        '国产' => cn,
        '港台' => gangtai,
        '日韩' => rihan,
        '欧美' => oumei,
        '国漫' => guoman,
        '日番' => rifan,
        _ => all,
      };
}

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
    this.lastEpisodeNumber,
    this.lastEpisodeSeason,
    this.nextEpisodeNumber,
    this.nextAirDate,
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

  /// **已更新到第几集**（`last_episode_to_air.episode_number`）。
  ///
  /// ## ★ 为什么不能用 [episodeCount] 代替（实测证据）
  /// `number_of_episodes` 是**跨季总集数**，与"已更新"常不等：
  /// ```
  /// 斗破苍穹   number_of_episodes=279   而 last=S5E214
  /// 完美世界   number_of_episodes=338   而 last=S1E288
  /// 都市古仙医 number_of_episodes=220 = S1E220（巧合相等）
  /// ```
  /// ⇒ 详情页曾把"共 279 集"当进度显示，是**错的**。
  final int? lastEpisodeNumber;

  /// 上面那集的**季号**（`last_episode_to_air.season_number`）。
  /// 连载剧常跨季 ⇒ 单看集号会误读（S5E214 的 214 不是第 214 集）。
  final int? lastEpisodeSeason;

  /// **下一集集号**（`next_episode_to_air.episode_number`，连载中才有）。
  final int? nextEpisodeNumber;

  /// **下一集播出日**（`next_episode_to_air.air_date`，`yyyy-MM-dd`）。
  ///
  /// ## 为什么需要它（实测证据）
  /// Emby 库内分集的 `PremiereDate` **可能全为空**
  /// （实测《吞噬星空》33 集全无日期）⇒ 光靠库内算不出"下次更新"。
  /// 而 TMDB 明确给了 `next_episode_to_air.air_date` = 2026-10-12。
  /// ⇒ **库内优先、TMDB 兜底**（与周历同一套思路）。
  final String? nextAirDate;

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
    this.jumpUrl,
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

  /// **精确播放页 URL**（tgmeng 源直接给该剧在平台的页面）。
  ///
  /// ## 为什么单独一个字段（而不是复用 platform）
  /// · `platform` 只给**平台名**（"优酷"）⇒ 跳转要靠**搜索页**
  /// · tgmeng 的 `url` 是**该剧的具体页面**（实测形如
  ///   `v.youku.com/v_show/id_XX.html`）⇒ 点进去直接能看
  ///
  /// 有它时优先用它（`platformSearchUrl` 作兜底）。
  final String? jumpUrl;

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
    String? jumpUrl,
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
        jumpUrl: jumpUrl ?? this.jumpUrl,
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

  /// **整周按类别分组**（用户要求："追剧日历按类别排列，去除周一-周日"）。
  ///
  /// ## 与 [forWeekdayGrouped] 的区别
  /// · `forWeekdayGrouped(d)` —— **某一天**的条目（周条模式下用）
  /// · `groupedByCategory()` —— **整周**的条目（去周条后用）
  ///
  /// ## ★★ 必须去重（否则同一部剧重复出现）
  /// 整周实测 240 条，而同一部剧会在多天出现
  ///（如《你好，星期六》周一 + 周六）⇒ 不去重时「综艺」段里
  /// 同一部剧会重复 3 次，用户看到一堆重复。
  ///
  /// 去重键 = `(source, sourceId)`（同一源内的 id 唯一）。
  /// 保留哪一条？—— **离今天最近的那次更新**：
  /// · 有"今天"⇒ 保留今天（用户最关心）
  /// · 都在未来 ⇒ 保留最近的那天
  /// · 都过去了 ⇒ 保留最近过去的（信息最新）
  /// 这样每条都带一个"最近更新日"，UI 可显示"今天"/"周三"。
  ///
  /// ## 组间/组内顺序
  /// · 组间：动漫 → 综艺 → 剧集（固定，用户列的次序）
  /// · 组内：先按"离今天多近"升序（今天最前），再按热度降序
  Map<CalendarCategory, List<CalendarEntry>> groupedByCategory() {
    final today = DateTime.now().weekday;

    // ① 按 (source, sourceId) 去重，保留最近更新那次
    final best = <String, CalendarEntry>{};
    for (final e in entries) {
      final k = '${e.source}:${e.sourceId ?? e.displayTitle}';
      final cur = best[k];
      if (cur == null) {
        best[k] = e;
        continue;
      }
      if (_distanceFromToday(e.weekdayResolved, today) <
          _distanceFromToday(cur.weekdayResolved, today)) {
        best[k] = e;
      }
    }

    // ② 按类别归组 + 组内排序
    final out = <CalendarCategory, List<CalendarEntry>>{};
    for (final c in CalendarCategory.values) {
      final list = best.values.where((e) => e.category == c).toList();
      final withPop = <CalendarEntry>[];
      final noPop = <CalendarEntry>[];
      for (final e in list) {
        if (e.popularity != null && e.popularity! > 0) {
          withPop.add(e);
        } else {
          noPop.add(e);
        }
      }
      // 先按"离今天多远"（今天=0 最前），再按热度降序
      withPop.sort((a, b) {
        final d = _distanceFromToday(a.weekdayResolved, today)
            .compareTo(_distanceFromToday(b.weekdayResolved, today));
        if (d != 0) return d;
        return b.popularity!.compareTo(a.popularity!);
      });
      noPop.sort((a, b) => _distanceFromToday(a.weekdayResolved, today)
          .compareTo(_distanceFromToday(b.weekdayResolved, today)));
      out[c] = [...withPop, ...noPop];
    }
    return out;
  }

  /// 某个星期几**离今天还有几天**（0 = 今天，1..3 = 未来，4..6 = 已过去）。
  ///
  /// 用于"最近的更新排最前"：今天 0，明天 1，…… 前天 6
  ///（`(day - today + 7) % 7` 正好是这个语义）。
  static int _distanceFromToday(int day, int today) => (day - today + 7) % 7;

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

  /// **移动端 UA** —— 优酷移动端频道页才有 SSR 的「每周X」
  ///（PC 频道页 1.56MB 且**不含**"每周X"；移动端 217KB 且含）。
  static const _uaMobile =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 '
      'Mobile/15E148 Safari/604.1';

  /// **桌面 UA** —— 优酷 **PC 频道页**要用它（UA 与页面形态必须匹配）。
  ///
  /// ## ★ 为什么必须区分（2026-10-13 实测）
  /// 优酷按 UA 给**不同形态**的页面：
  /// | UA | 页面 | `//v.youku.com/video?s=` 链接 |
  /// |---|---|---|
  /// | 移动 | `m.youku.com/ku/webcomic` 217KB | ❌ **0 个** |
  /// | 桌面 | `www.youku.com/ku/webcomic` 1.56MB | ✅ **92 个** |
  ///
  /// 移动端把链接换成了 `//m.youku.com/alipay_video/id_xxx.html`，
  /// 而那些页面里**没有"每周X N点"**（实测 3/3 无）⇒ 拿不到时刻。
  ///
  /// ⚠️ 所以**请求 PC 页必须用桌面 UA** ——
  ///    用移动 UA 请求 PC 地址会拿到移动版内容（又没链接了）。
  static const _uaDesktop =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/120.0.0.0 Safari/537.36';

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

  /// ══════════════════════════════════════════════════════════════
  /// ★ 2026-10-15 新增：**列表数据的短 TTL**（E 项）
  /// ══════════════════════════════════════════════════════════════
  ///
  /// ## 为什么"发现/浏览"类列表不能用 6h
  /// `fetchBrowse` / `fetchHot` 用 `sort_by = first_air_date.desc` 或
  /// `popularity.desc` —— 这些**每天甚至每小时都在变**。
  /// 用 6h TTL 会出现"早上看到的榜单，晚上还是同一批"，
  /// 而用户点进"最新"就是想看新的。
  ///
  /// ## 为什么不用 0（= 不缓存）
  /// Overseerr 的做法是 discover **完全不缓存**（`server/routes/discover.ts`
  /// 里 `cache` 出现 **0 次**）。但那是服务端（有 CDN + 多用户共享）。
  /// 我们**在手机上**，移动网络慢且耗流量 ⇒ **短 TTL 比不缓存好**。
  ///
  /// ## 取值依据
  /// · 30 分钟：与 `todayTtl` 同档 —— 够"刷一下看到新的"，又不至于每次都打网络
  /// · 而**详情类**（按 id 取，几乎不变）继续用 6h 的 `cacheTtl`
  static const listTtl = Duration(minutes: 30);

  /// ══════════════════════════════════════════════════════════════
  /// ★ 2026-10-15 新增：**海报尺寸常量**（B 项）
  /// ══════════════════════════════════════════════════════════════
  ///
  /// ## 为什么要区分（原来 6 处硬编码，4 处是 `w300`）
  /// 借鉴 Jellyfin `TmdbClientManager.ThumbnailSizes`：
  /// ```csharp
  /// { "Primary", "w500" }, { "Backdrop", "w780" },
  /// { "Thumb",   "w780" }, { "Logo",     "w500" },
  /// ```
  /// —— **按用途区分**，而不是所有地方一个尺寸。
  ///
  /// ## 尺寸语义（TMDB 官方尺寸表）
  /// | 常量 | TMDB 值 | 宽度 | 用途 |
  /// |---|---|---|---|
  /// | [posterSize] | `w342` | 342px | **列表/网格**海报（手机 2–3 列，够清晰又不费流量）|
  /// | [posterLargeSize] | `w500` | 500px | **详情页**主海报（全屏宽，需要更清晰）|
  /// | [backdropSize] | `w780` | 780px | 背景图/剧照 |
  ///
  /// ⚠️ 原来列表用 `w300`（300px）—— 在 1080p 手机上 2 列布局时
  ///    **每张海报实际约 500px 宽** ⇒ `w300` 会被放大而**发虚**。
  ///    改成 `w342` 是官方标准尺寸里最接近的（且比 `w500` 省流量）。
  static const posterSize = 'w342';

  /// 详情页大图尺寸（见 [posterSize] 说明）。
  static const posterLargeSize = 'w500';

  /// 背景/剧照尺寸（见 [posterSize] 说明）。
  static const backdropSize = 'w780';

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
      // ★ tgmeng 公益 API：优酷/爱奇艺/芒果等平台**热播剧集**
      //   （用户 2026-10-11 要求接入；实测 8 个视频端点有数据）
      guard(_fetchTgmeng(), 'tgmeng', '平台热播（优酷/爱奇艺/芒果）'),
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
  /// **tgmeng 公益 API**：优酷/爱奇艺/芒果等平台的**热播剧集**。
  ///
  /// ## ★★ 为什么这个源"没有日期"（与其它三个源的**本质**区别）
  /// 它给的是**当前热榜**（"优酷现在最火的 10 部剧"），而
  /// TMDB 给的是**"某天更新的剧"** —— 两者语义完全不同。
  ///
  /// ⇒ 本源条目**均匀落在整周**（`(out.length % 7) + 1`），
  ///   这样"按类别浏览"能看到它们，但**不冒充"今天更新"**。
  ///
  /// ⚠️ 这是刻意设计：硬塞一个假日期（比如全部塞今天）会让
  ///    "今天更新"变成**谎言** —— 用户点进去发现今天根本没更新。
  ///
  /// ## 实测的 8 个可用端点（25 个里 20 个有数据，取其中视频类）
  /// | 平台 | 端点 | 实测条数 |
  /// |---|---|---|
  /// | 优酷·电视剧 | `youku/dianshiju` | 10 |
  /// | 爱奇艺·电视剧 | `aiqiyi/dianshiju` | 25 |
  /// | 爱奇艺·综艺 | `aiqiyi/zongyi` | 25 |
  /// | 爱奇艺·动漫 | `aiqiyi/dongman` | 25 |
  /// | 芒果·电视剧 | `mangguo/dianshiju` | 8 |
  /// | CCTV8·电视剧 | `cctv/8` | 39 |
  /// | 百度·短剧 | `baidu/duanju` | 100 |
  /// | 电视猫 | `dianshimao` | 20 |
  ///
  /// ## ⚠️ 为什么不收录**腾讯视频**（用户点名要的平台）
  /// 实测 `tencent/{zongbang,dianshiju,dianying,zongyi,dongman}`
  /// **全部 `dataInfo=None`**（上游未抓）⇒ 收进来只会是空。
  /// 唯一的 `/tencent` 是**新闻热点**（实测首条 "习近平总书记同卫生健康…"），
  /// **不是剧集** ⇒ 收了会污染日历。
  ///
  /// ## ⚠️ 域名陷阱（实测）
  /// `api.tgmeng.com` **全部超时**；真 API 域名是
  /// **`trendapi.tgmeng.com`**（从 `tgmeng.com` 的前端 JS bundle 里挖出来的，
  /// `/about` 上没有 API 文档）。
  Future<CalendarSourceResult> _fetchTgmeng() async {
    const src = 'tgmeng';
    const label = '平台热播（优酷/爱奇艺/芒果）';
    final out = <CalendarEntry>[];
    final failed = <String>[];

    // (路径, 平台名, 类别)——实测确认过的组合
    const endpoints = <(String, String, CalendarCategory)>[
      ('youku/dianshiju', '优酷', CalendarCategory.series),
      ('aiqiyi/dianshiju', '爱奇艺', CalendarCategory.series),
      ('aiqiyi/zongyi', '爱奇艺', CalendarCategory.variety),
      ('aiqiyi/dongman', '爱奇艺', CalendarCategory.anime),
      ('mangguo/dianshiju', '芒果TV', CalendarCategory.series),
      ('cctv/8', 'CCTV8', CalendarCategory.series),
      ('baidu/duanju', '百度', CalendarCategory.series),
      ('dianshimao', '电视猫', CalendarCategory.series),
    ];

    // 并发拉（8 个端点互不依赖；实测单个 ~0.3s）
    await Future.wait(endpoints.map((e) async {
      final (path, platform, cat) = e;
      final cacheKey = 'tgmeng:$path';
      try {
        final cached = await cache?.get(cacheKey);
        String body;
        if (cached != null && cached.isNotEmpty) {
          body = cached;
        } else {
          final r = await _dio.get<String>(
            'https://trendapi.tgmeng.com/api/topsearch/$path',
            options: Options(responseType: ResponseType.plain, headers: {
              'User-Agent': _ua,
              // ⚠️ 实测必须带 Referer（否则未通过防盗链校验）
              'Referer': 'https://tgmeng.com/',
            }),
          );
          if (r.statusCode != 200 || r.data == null) {
            failed.add('$platform HTTP ${r.statusCode}');
            return;
          }
          body = r.data!;
          await cache?.put(cacheKey, body, ttl: todayTtl);
        }
        final j = jsonDecode(body);
        if (j is! Map) return;
        // 业务码：实测 200=成功；666="系统未主动捕获到的异常"
        //（trendapi 对**未知路径**就回这个，所以路径写错会静默成 666）
        final code = (j['code'] as num?)?.toInt();
        if (code != 200) {
          failed.add('$platform code=$code');
          return;
        }
        final data = j['data'];
        if (data is! Map) return;
        final list = data['dataInfo'];
        if (list is! List || list.isEmpty) {
          // ⚠️ 实测：有的端点回 code=200 但 dataInfo=None
          //    （腾讯视频的 5 个端点全是这样）⇒ 记为失败而非"成功但 0 条"，
          //    这样 UI 的失败提示能如实反映。
          failed.add('$platform 无数据');
          return;
        }
        for (final it in list) {
          if (it is! Map) continue;
          final title = (it['title'] as String?)?.trim() ?? '';
          if (title.isEmpty) continue;
          final hot = double.tryParse('${it['hotScore'] ?? ''}');
          out.add(CalendarEntry(
            title: title,
            // 中文平台，标题本身就是中文（无独立"原名"字段）
            titleCn: title,
            airDate: null,
            // 均匀铺到整周（见方法说明：不冒充"今天更新"）
            weekday: (out.length % 7) + 1,
            posterUrl: null, // 实测 image 字段全是空串
            rating: null, // 实测无评分
            summary: null,
            // 热度（实测 hotScore：优酷 1237000 / 爱奇艺 5999，**量纲不同**）
            // ⇒ 只用于**同平台内**排序，不跨平台比较
            popularity: hot,
            platform: platform,
            // ★ 精确播放页（实测形如 v.youku.com/v_show/id_XX.html）
            jumpUrl: (it['url'] as String?)?.trim(),
            category: cat,
            source: src,
            sourceId: '$path/${it['sort'] ?? title}',
          ));
        }
      } catch (e) {
        failed.add('$platform ${_friendly(e)}');
      }
    }));

    if (out.isEmpty && failed.isNotEmpty) {
      return CalendarSourceResult(
          source: src, label: label, error: failed.take(2).join('；'));
    }
    debugPrint('[Calendar] tgmeng: ${out.length} 条，'
        '失败 ${failed.length} 个端点');
    return CalendarSourceResult(source: src, label: label, entries: out);
  }

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

  /// **索引爱奇艺动漫的更新时刻**（实测 **100%** 可解析）。
  ///
  /// ## ★★ 实测依据（可复现，**无需签名**）
  /// ```
  /// GET mesh.if.iqiyi.com/portal/lw/v7/channel/cartoon?channel_id=2
  ///   → 974KB JSON
  ///   → .items[].video[].data[] 每条含：
  ///        title             剧名（如"灵武大陆"）
  ///        desc              **"每周一周五10:00更新一集"**
  ///        dq_updatestatus   "更新至223集"
  ///        album_id / page_url
  ///   → 224 条去重后，含「每周」24 条
  ///   → 两段式解析 **24/24 = 100%**
  /// ```
  ///
  /// ## ⚠️ 解析必须**两段式**（单条正则只有 18/24）
  /// 实测形态差异极大：
  /// ```
  /// 每周一周五10:00更新一集
  /// 每周一周二周三周五周六周日10:00更新1集
  /// 每周三/周五9:00 各更新1集
  /// 每周二、六10：00各更新一集      ← 全角冒号
  /// 第二季10月2号起每周五更新        ← **无时刻**
  /// ```
  /// ⇒ ① 先抓所有周几（字符类 `[一二三四五六日、/,，和及]`）
  ///    ② 再在**其后**找 `N点/N:NN`；找不到 ⇒ 时刻留空（UI 只显示星期）
  ///
  /// ## 返回
  /// 写入行数（0 = 失败）。
  Future<int> indexIqiyiTimeline({required AppDatabase db}) async {
    try {
      final r = await _dio.get<String>(
        'https://mesh.if.iqiyi.com/portal/lw/v7/channel/cartoon',
        queryParameters: {'channel_id': '2'}, // 2 = 动漫
        options: Options(responseType: ResponseType.plain, headers: {
          'User-Agent': _ua,
          'Referer': 'https://www.iqiyi.com/comic/',
        }),
      );
      if (r.statusCode != 200 || r.data == null) {
        debugPrint('[Timeline] 爱奇艺索引失败 HTTP ${r.statusCode}');
        return 0;
      }
      final j = jsonDecode(r.data!);
      if (j is! Map) return 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      final rows = <AnimeTimeline>[];
      final seen = <String>{};
      // 递归找所有含 title+desc 的对象（结构可能变，不做硬编码路径）
      void walk(Object? o, int depth) {
        if (depth > 10 || o == null) return;
        if (o is Map) {
          final t = o['title'];
          // ★★ 字段名**兼容两种**（2026-10-13 实测服务端已改）
          //
          // ## 事故：解析突然变 0 条
          // 原来只读 `desc`；实测当前响应里**没有 `desc`**，而是：
          // ```
          // $.items[0].video[0].data[0].description: str = '高中生侦探工藤新一…'
          // ```
          // ⇒ 解析 0 条（原本 24/24），卡片时刻退化成"平台惯例"（不准）。
          //
          // ## 为什么两个都试（而不是直接换掉）
          // 服务端已改过一次 ⇒ 可能再改回去。两个键名都认，任一边生效。
          // ★★ **两个候选字段都试解析**（2026-10-13 实测修正）
          //
          // ## 为什么不能简单 `??`
          // 实测字段路径与内容：
          // ```
          // $.items[].video[].data[].desc  ×40 处 → "每周一周五10:00更新一集"  ← 要的
          // $.items[].video[].data[].description    → 剧情简介（**不含"每周"**）
          // ```
          // 若写 `description ?? desc`：`description` 非 null 但**不含"每周"**
          // ⇒ `_parseWeeklyDesc` 返回 null ⇒ **仍然 0 条**。
          // ⇒ 正确做法：**逐个候选试解析**，谁能解出"每周"就用谁。
          final cands = <String>[
            if (o['desc'] is String) o['desc'] as String,
            if (o['description'] is String) o['description'] as String,
            if (o['descV2'] is String) o['descV2'] as String,
          ];
          (int, String)? parsed;
          for (final de in cands) {
            if (de.isEmpty) continue;
            final r0 = _parseWeeklyDesc(de);
            if (r0 != null) {
              parsed = r0;
              break;
            }
          }
          if (t is String && parsed != null && seen.add(t)) {
              rows.add(AnimeTimeline(
                title: t,
                platform: 'iqiyi',
                weekday: parsed.$1,
                airTime: parsed.$2,
                sourceId: (o['album_id'] ?? '').toString(),
                updatedAt: now,
              ));
          }
          for (final v in o.values) {
            walk(v, depth + 1);
          }
        } else if (o is List) {
          for (final v in o) {
            walk(v, depth + 1);
          }
        }
      }

      walk(j, 0);
      if (rows.isEmpty) {
        debugPrint('[Timeline] 爱奇艺解析到 0 条');
        return 0;
      }
      await db.upsertTimelines(rows);
      debugPrint('[Timeline] 爱奇艺索引 ${rows.length} 条');
      return rows.length;
    } catch (e) {
      debugPrint('[Timeline] 爱奇艺索引异常: ${_friendly(e)}');
      return 0;
    }
  }

  /// 从爱奇艺的 `desc` 解析「周几 + 时刻」（**两段式，实测 24/24**）。
  ///
  /// ## 为什么两段式
  /// 单条正则只能吃下 18/24 —— 形态太杂：
  /// ```
  /// 每周一周五10:00更新一集
  /// 每周三/周五9:00 各更新1集
  /// 每周二、六10：00各更新一集     ← 全角冒号
  /// 第二季10月2号起每周五更新       ← 无时刻
  /// ```
  /// ⇒ ① 抓**第一个** `每周` 之后连续的周几字符
  ///    ② 在那段**之后**找时刻；没有 ⇒ 返回空时刻（UI 只显示星期）
  ///
  /// ## 返回 `(weekday, airTime)`；null = 这条没有可用信息。
  /// 多周更时**只取第一个**（卡片只显示一个时刻，取最早的那天）。
  static (int, String)? _parseWeeklyDesc(String desc) {
    const cn = '一二三四五六日';
    final mw = RegExp(r'每周([一二三四五六日、/,，和及\s]+)').firstMatch(desc);
    if (mw == null) return null;
    final wds = <int>[];
    for (final ch in mw.group(1)!.split('')) {
      final i = cn.indexOf(ch);
      if (i >= 0 && !wds.contains(i + 1)) wds.add(i + 1);
    }
    if (wds.isEmpty) return null;
    wds.sort();
    // 时刻：只在那段**之后**找（避免误取"首播3集"里的 3）
    final rest = desc.substring(mw.end);
    final mh = RegExp(r'(\d{1,2})\s*[:：点时]').firstMatch(rest);
    var hh = 0;
    if (mh != null) {
      final v = int.tryParse(mh.group(1)!) ?? 0;
      if (v >= 0 && v <= 23) hh = v;
    }
    return (wds.first, hh == 0 ? '' : '${hh.toString().padLeft(2, '0')}:00');
  }

  /// **索引优酷动漫的更新时刻**（实测唯一能拿到"每周X N点"的国内平台之一）。
  ///
  /// ## ★★ 实测依据（逐条可复现）
  /// ```
  /// ① 移动端频道页 https://m.youku.com/ku/webcomic
  ///    → 217KB SSR，含「每周五」+「更新至98话」+ 单剧 `video?s=` 链接
  ///      （**比 PC 频道页 1.56MB 省 7 倍，且 PC 频道页本身没有"每周X"**）
  /// ② 单剧详情页 https://v.youku.com/video?s=…
  ///    → SSR 文案：
  ///      《一斩苍穹》  更新至13/26话，**每周一10点**SVIP更新，周二10点VIP可看
  ///      《沧元图》    更新至98/129话，**每周五10点**SVIP更新，周六10点VIP可看
  ///      《光阴之外》  更新至43/78话，**每周日10点**VIP更新，每周六10点SVIP抢先看
  ///      《师兄啊师兄》更新至162/169话，**每周四10点**VIP更新，每周三10点SVIP抢先看
  ///    ⇒ 5/5 命中，正则 `每周[一二三四五六日](\d{1,2})点`
  /// ```
  ///
  /// ## ⚠️ 腾讯 / 爱奇艺为什么不做（4 种入口全试过）
  /// | 平台 | 试过的入口 | 结果 |
  /// |---|---|---|
  /// | 腾讯 | PC cover 187KB / 移动 1 字节 / 频道移动 404 / 搜索 2.8KB | **0 个"每周X"** |
  /// | 爱奇艺 | 动漫页 6.6KB 壳 / 柯南详情 / **排行 1629 词** / 移动 404 | **0 个"每周X"** |
  /// ⇒ 它们的数据在 XHR 里、页面 HTML 不含。**沿用平台惯例**（20:00）。
  ///
  /// ## 返回
  /// 写入行数（0 = 失败，调用方据此决定是否重试）。
  Future<int> indexYoukuTimeline({
    required AppDatabase db,
    int maxSeries = 60,
  }) async {
    try {
      // ① 频道页拿单剧链接（**PC 页** —— 2026-10-13 实测修正）
      //
      // ## 为什么从移动端换成 PC 页
      // | 入口 | 大小 | `//v.youku.com/video?s=` 链接数 |
      // |---|---|---|
      // | `m.youku.com/ku/webcomic`（原用）| 217KB | ❌ **0 个** |
      // | `www.youku.com/ku/webcomic`（改用）| 1.56MB | ✅ **92 个** |
      //
      // 移动端把链接换成了 `//m.youku.com/alipay_video/id_xxx.html`，
      // 而那些页面里**没有"每周X N点"**（实测 3/3 无）⇒ 拿不到时刻。
      // PC 页仍保留旧形态，且详情页实测 5/8 命中（抽 8 个）：
      // ```
      // ✅ 沧元图 周5 10:00｜一斩苍穹 周1 10:00｜光阴之外 周7 10:00
      // ✅ 师兄啊师兄 周4 10:00｜东大高武学院 周4 10:00
      // ❌ 神墓年番 / 云深不知梦 / 排球少年 ← **本来就没有"每周"**（非解析失败）
      // ```
      //
      // ## 代价与为何可接受
      // PC 页 1.56MB（移动端 217KB，**7 倍**）—— 但只在
      // "索引时刻表"时跑一次（**按平台 TTL**，不是每次进页面）⇒ 可接受。
      //
      // ## 回退
      // 两个入口都试，**谁给出链接就用谁** ——
      // 任一边再改形态都还有另一边。
      var html = '';
      for (final entry in [
        // (url, ua) —— PC 优先（有链接），移动端兜底
        ('https://www.youku.com/ku/webcomic', _uaDesktop),
        ('https://m.youku.com/ku/webcomic', _uaMobile),
      ]) {
        try {
          final r = await _dio.get<String>(
            entry.$1,
            options: Options(responseType: ResponseType.plain, headers: {
              'User-Agent': entry.$2,
              'Referer': 'https://www.youku.com/',
            }),
          );
          if (r.statusCode == 200 && r.data != null) {
            // 有旧形态链接才算"可用入口"（否则换下一个）
            if (RegExp(r'href="(//v\.youku\.com/video\?s=[^"&]+)')
                .hasMatch(r.data!)) {
              html = r.data!;
              debugPrint('[Timeline] 优酷频道页用 ${entry.$1}（${html.length} 字节）');
              break;
            }
            debugPrint('[Timeline] 优酷 ${entry.$1} 无旧形态链接，试下一个');
          }
        } catch (e) {
          debugPrint('[Timeline] 优酷 ${entry.$1} 失败: ${_friendly(e)}');
        }
      }
      if (html.isEmpty) {
        debugPrint('[Timeline] 优酷：所有频道页入口都拿不到单剧链接');
        return 0;
      }
      // 抓 `//v.youku.com/video?s=xxx` 形式的单剧链接（去重、限量）
      final links = <String>[];
      final seen = <String>{};
      for (final m in RegExp(r'href="(//v\.youku\.com/video\?s=[^"&]+)')
          .allMatches(html)) {
        final u = m.group(1)!;
        if (seen.add(u) && links.length < maxSeries) links.add(u);
      }
      if (links.isEmpty) {
        debugPrint('[Timeline] 优酷频道页没找到单剧链接');
        return 0;
      }

      // ② 逐剧抓详情页，解析「每周X N点」
      final now = DateTime.now().millisecondsSinceEpoch;
      final byTitle = <String, AnimeTimeline>{};
      // 限并发 4（对平台友好；优酷有风控）
      for (var i = 0; i < links.length; i += 4) {
        final batch = links.skip(i).take(4).toList();
        final results = await Future.wait(batch.map((u) async {
          try {
            final rr = await _dio.get<String>('https:$u',
                options: Options(responseType: ResponseType.plain, headers: {
                  'User-Agent': _uaMobile,
                  'Referer': 'https://m.youku.com/ku/webcomic',
                }));
            if (rr.statusCode != 200 || rr.data == null) return null;
            return _parseYoukuSeries(rr.data!, now);
          } catch (_) {
            return null;
          }
        }));
        for (final t in results) {
          if (t != null) byTitle[t.title] = t;
        }
      }
      if (byTitle.isEmpty) {
        debugPrint('[Timeline] 优酷解析到 0 条');
        return 0;
      }
      await db.upsertTimelines(byTitle.values.toList());
      debugPrint('[Timeline] 优酷索引 ${byTitle.length} 条'
          '（共试 ${links.length} 部）');
      return byTitle.length;
    } catch (e) {
      debugPrint('[Timeline] 优酷索引异常: ${_friendly(e)}');
      return 0;
    }
  }

  /// 从优酷单剧详情页解析「每周X N点」。
  ///
  /// ## ★ 取哪个时间：**SVIP 优先**（用户 2026-10-13 明确要求）
  /// > "我们按他的 **svip 更新时间**作为提醒，即最新、最早的更新时间。"
  ///
  /// ## 为什么不能取"第一个"（原写法，实测 **2/5 部取错**）
  /// 优酷文案的**顺序不固定**：
  /// ```text
  /// 一斩苍穹   更新至13/26话，每周一10点SVIP更新，周二10点VIP可看    ← SVIP 在前 ✅
  /// 沧元图     更新至98/129话，每周五10点SVIP更新，周六10点VIP可看    ← SVIP 在前 ✅
  /// 光阴之外   更新至43/78话，每周日10点VIP更新，每周六10点SVIP抢先看  ← SVIP 在**后** ❌
  /// 师兄啊师兄 更新至162/169话，每周四10点VIP更新，每周三10点SVIP抢先看 ← SVIP 在**后** ❌
  /// ```
  /// `firstMatch` 撞运气：后两条拿到 **VIP 的周日/周四**，
  /// 而 SVIP（周六/周三）**更早**，那才是真正的更新时间。
  ///
  /// ## 三级优先级
  /// 1. 匹配附近含 `SVIP` ⇒ **用它**（= 最早可看的时刻）
  /// 2. 无 SVIP 标记 ⇒ 退回**首个匹配**（保持原行为，不乱猜顺序）
  /// 3. 全无 ⇒ `null`（调用方退回平台惯例 20:00）
  ///
  /// ## 顺带
  /// 正则同时接受 `点`/`时`/`:` 并解析**分钟**（实测样本都是整点，
  /// 但不该把 `:00` 硬编码 —— 万一有半点的剧就会显示错）。
  static AnimeTimeline? _parseYoukuSeries(String html, int nowMs) {
    // 剧名：`<title>…</title>` 去掉站点后缀
    String title = '';
    final mt = RegExp(r'<title>([^<]{1,80})</title>').firstMatch(html);
    if (mt != null) {
      title = mt.group(1)!
          .replaceAll(RegExp(r'[-_|].*$'), '')
          .replaceAll(RegExp(r'（.*?）'), '')
          .trim();
    }
    if (title.isEmpty) return null;

    // 「每周X N点」——一次收全部匹配，再按优先级挑
    final all = RegExp(r'每周([一二三四五六日])(\d{1,2})\s*[:点时]?(\d{2})?')
        .allMatches(html)
        .toList();
    if (all.isEmpty) return null;

    // ★ SVIP 优先（用户要求"按 SVIP 更新时间"）
    RegExpMatch? pick;
    for (final m in all) {
      // 匹配点前后 ±14 字符内出现 SVIP ⇒ 这条就是 SVIP 时间
      final lo = (m.start - 14).clamp(0, html.length);
      final hi = (m.end + 14).clamp(0, html.length);
      final seg = html.substring(lo, hi);
      if (seg.contains('SVIP') || seg.contains('svip')) {
        pick = m;
        break;
      }
    }
    // 退路：无 SVIP 标记 ⇒ 首个匹配（原行为）
    pick ??= all.first;

    const cn = '一二三四五六日';
    final wd = cn.indexOf(pick.group(1)!) + 1;
    if (wd < 1 || wd > 7) return null;
    final hh = int.tryParse(pick.group(2)!) ?? 0;
    if (hh < 0 || hh > 23) return null;
    final mmRaw = pick.group(3);
    final mm = mmRaw == null ? 0 : (int.tryParse(mmRaw) ?? 0).clamp(0, 59);
    return AnimeTimeline(
      title: title,
      platform: 'youku',
      weekday: wd,
      airTime: '${hh.toString().padLeft(2, '0')}:'
          '${mm.toString().padLeft(2, '0')}',
      sourceId: '',
      updatedAt: nowMs,
    );
  }

  /// **索引动漫更新时刻表**（用户建议："定期在这儿索引"）。
  ///
  /// ## 数据源（实测：只有 B站可用）
  /// `GET api.bilibili.com/pgc/web/timeline?types=1,4&before=7&after=7`
  /// · `types`：1=番剧、4=国创
  /// · `before/after=7` ⇒ **15 天 / 115 部**（`6` 只给 3 天，不够）
  /// · 字段 `day_of_week`（1..7）、`pub_time`（`HH:mm`）、`season_id`
  ///
  /// ## ★ 为什么只做 B站
  /// | 源 | 有"周几+时刻"吗 |
  /// |---|---|
  /// | B站 | ✅ 115 部，精确到分钟 |
  /// | 爱奇艺 | ❌ 只有 `更新至N集` |
  /// | 腾讯 / 优酷 | ❌ SPA + 签名/token 门槛 |
  ///
  /// ## 返回
  /// 写入行数（0 = 失败，调用方据此决定是否重试）。
  Future<int> indexAnimeTimeline({required AppDatabase db}) async {
    try {
      final r = await _dio.get<String>(
        'https://api.bilibili.com/pgc/web/timeline',
        queryParameters: {
          'types': '1,4',
          // ★ 7 是上限；实测 15 天 / 115 部（6 只给 3 天）
          'before': '7',
          'after': '7',
        },
        options: Options(responseType: ResponseType.plain, headers: {
          'User-Agent': _ua,
          // ★ 必须带 Referer（实测，不带会 403）
          'Referer': 'https://www.bilibili.com/',
        }),
      );
      if (r.statusCode != 200 || r.data == null) {
        debugPrint('[Timeline] B站索引失败 HTTP ${r.statusCode}');
        return 0;
      }
      final j = jsonDecode(r.data!);
      if (j is! Map) return 0;
      if ((j['code'] as num?)?.toInt() != 0) {
        debugPrint('[Timeline] B站索引 code=${j['code']}');
        return 0;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final rows = <AnimeTimeline>[];
      for (final day in (j['result'] as List? ?? const [])) {
        if (day is! Map) continue;
        final wd = (day['day_of_week'] as num?)?.toInt();
        if (wd == null || wd < 1 || wd > 7) continue;
        for (final ep in (day['episodes'] as List? ?? const [])) {
          if (ep is! Map) continue;
          final title = (ep['title'] as String?)?.trim() ?? '';
          if (title.isEmpty) continue;
          rows.add(AnimeTimeline(
            title: title,
            platform: 'bilibili',
            weekday: wd,
            airTime: (ep['pub_time'] as String?)?.trim() ?? '',
            sourceId: (ep['season_id'] ?? '').toString(),
            updatedAt: now,
          ));
        }
      }
      if (rows.isEmpty) return 0;
      await db.upsertTimelines(rows);
      debugPrint('[Timeline] B站索引 ${rows.length} 条（时刻表已更新）');
      return rows.length;
    } catch (e) {
      debugPrint('[Timeline] B站索引异常: ${_friendly(e)}');
      return 0;
    }
  }

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
  /// **TMDB 热播榜（按"状态"维度）** —— 「热播」Tab 的 TMDB 栏。
  ///
  /// ## 用户定义（2026-10-12）
  /// > "热播的指的是正在连载中或者即将连载的剧集、综艺、动漫以及刚完结不久的，
  /// >  还有正在上映的电影、已上映的电影。"
  ///
  /// ⇒ **按状态筛，不是按热度排**。
  ///
  /// ## ★ 实测：`with_status` 确实生效
  /// 判据用 `total_results`（**不是** `len(results)` —— 后者恒为页大小 20，
  /// 看不出差别，我第一版就差点因此误判"参数无效"）：
  /// ```
  /// 基线      20001    with_status=0 在播 18652
  /// =1 将播     163    =2 制作中   765
  /// =3 已完结 13624    =4 被砍      28
  /// ```
  ///
  /// ## 榜单定义（[group] → [board]）
  /// | 分组 | 榜单 | 参数 |
  /// |---|---|---|
  /// | 剧集/综艺/动漫 | `airing` 在播 | `with_status=0` |
  /// | 同上 | `upcoming` 将播 | `with_status=1,2` |
  /// | 同上 | `recentEnded` 刚完结 | `with_status=3` + 近 [endedDays] 天 |
  /// | 电影 | `showing` 正在上映 | `primary_release_date` 近 30 天 |
  /// | 电影 | `upcoming` 即将上映 | 未来 30 天 |
  ///
  /// ## 缓存
  /// 键 `hotb:<kind>:<genre>:<board>:<page>`，TTL = `cacheTtl`（6h）。
  Future<List<CalendarEntry>> fetchHotByStatus({
    required String apiKey,
    required BrowseCategory category,
    required HotBoard board,
    int pages = 2,
    int endedDays = 90,
    int limit = 40,
  }) async {
    final kind = category.kind;
    final gid = category.genreId ?? '';
    final collected = <CalendarEntry>[];
    final today = DateTime.now();

    for (var page = 1; page <= pages; page++) {
      final params = <String, dynamic>{
        'api_key': apiKey,
        'language': 'zh-CN',
        'sort_by': 'popularity.desc',
        'page': '$page',
        // 国产为主（用户在中国）
        'with_original_language': 'zh',
      };
      if (gid.isNotEmpty) params['with_genres'] = gid;

      // ── 按分组/榜单拼参数 ──
      if (kind == 'movie') {
        // 电影：用**日期窗口**（TMDB 电影没有 with_status 的有用取值）
        final iso = (DateTime d) => d.toIso8601String().substring(0, 10);
        switch (board) {
          case HotBoard.showing:
            params['primary_release_date.gte'] =
                iso(today.subtract(const Duration(days: 30)));
            params['primary_release_date.lte'] = iso(today);
          case HotBoard.upcoming:
            params['primary_release_date.gte'] = iso(today);
            params['primary_release_date.lte'] =
                iso(today.add(const Duration(days: 30)));
          default:
            // 电影没有"在播/刚完结" ⇒ 退回"近 180 天已上映"
            params['primary_release_date.gte'] =
                iso(today.subtract(const Duration(days: 180)));
            params['primary_release_date.lte'] = iso(today);
        }
      } else {
        // 剧集/综艺/动漫：用 with_status
        switch (board) {
          case HotBoard.airing:
            params['with_status'] = '0'; // Returning Series
          case HotBoard.upcoming:
            params['with_status'] = '1|2'; // Planned | In Production
          case HotBoard.recentEnded:
            params['with_status'] = '3'; // Ended
            params['air_date.gte'] =
                today.subtract(Duration(days: endedDays)).toIso8601String()
                    .substring(0, 10);
          default:
            params['with_status'] = '0';
        }
      }

      final list = await _discoverPage(
          apiKey: apiKey, kind: kind, params: params,
          cacheKey: 'hotb:$kind:$gid:${board.name}:$page');
      for (final it in list) {
        final name =
            (it['name'] as String?) ?? (it['title'] as String?) ?? '';
        if (name.isEmpty) continue;
        collected.add(CalendarEntry(
          title: name,
          titleCn: name,
          airDate: (it['first_air_date'] as String?) ??
              (it['release_date'] as String?),
          // 热播榜没有"周几更新"语义 ⇒ 不冒充"今天更新"
          weekday: null,
          posterUrl: it['poster_path'] == null
              ? null
              : 'https://image.tmdb.org/t/p/$posterSize${it['poster_path']}',
          rating: (it['vote_average'] as num?)?.toDouble(),
          summary: it['overview'] as String?,
          popularity: (it['popularity'] as num?)?.toDouble(),
          category: _categoryOfBrowse(category),
          source: 'tmdb',
          sourceId: '${it['id']}',
        ));
      }
    }
    // 跨页可能重复（TMDB 分页有少量重叠）⇒ 按 sourceId 去重
    final seen = <String>{};
    final out = <CalendarEntry>[];
    for (final e in collected) {
      final k = e.sourceId ?? e.title;
      if (seen.add(k)) out.add(e);
    }
    return out.length > limit ? out.sublist(0, limit) : out;
  }

  /// `discover` 的单页（带缓存；失败返回空，不抛）。
  Future<List<Map<String, dynamic>>> _discoverPage({
    required String apiKey,
    required String kind,
    required Map<String, dynamic> params,
    required String cacheKey,
  }) async {
    try {
      final cached = await cache?.get(cacheKey);
      String body;
      if (cached != null && cached.isNotEmpty) {
        body = cached;
      } else {
        final r = await _dio.get<String>(
          'https://api.themoviedb.org/3/discover/$kind',
          queryParameters: params,
          options: Options(
              responseType: ResponseType.plain,
              headers: {'User-Agent': _ua},
              receiveTimeout: const Duration(seconds: 12)),
        );
        if (r.statusCode != 200 || r.data == null) return const [];
        body = r.data!;
        await cache?.put(cacheKey, body, ttl: cacheTtl);
      }
      final j = jsonDecode(body);
      if (j is! Map) return const [];
      return [
        for (final x in (j['results'] as List? ?? const []))
          if (x is Map<String, dynamic>) x
      ];
    } catch (e) {
      debugPrint('[Calendar] 热播榜页失败（跳过）: ${_friendly(e)}');
      return const [];
    }
  }

  /// **TMDB 热播 ∩ 库内**（首页 hero 的数据源）。
  ///
  /// ## 为什么是"交集"（用户原话："热播剧集按我库里有的放上去"）
  /// 纯 TMDB 热播里**绝大多数你库里没有** ⇒ 点进去"找不到"。
  /// 取交集后每一张都能直接播。
  ///
  /// ## 实测命中（2026-10-12，两台服务器）
  /// | 服务器 | 热播剧 | 综艺 | 动漫 | 电影 | 合计 |
  /// |---|---|---|---|---|---|
  /// | iLoveHD | 40 | 6 | 24 | 13 | **83** |
  /// | HK-Emby | 42 | 34 | 43 | 16 | **135** |
  /// 命中样本：《仙逆》《凡人修仙传》《明星大侦探》《奔跑吧》
  ///
  /// ## ⚠️ 为什么"库内 id"从参数传入（而不是这里自己查库）
  /// 本类是**纯 TMDB 客户端**（不依赖 Emby）。自己去查库会让两个数据层耦合，
  /// 也违反 `MediaProvider` 抽象约定。⇒ 由调用方查好传进来。
  ///
  /// ## 缓存
  /// 每个"类别 × 页"一条 `hot:<kind>:<genreId>:<page>`，TTL = `cacheTtl`（6h）
  /// ⇒ 6 小时内第二次进首页 **0 请求**（首次 12 个请求 ≈ 12s）。
  ///
  /// 返回：按 TMDB `popularity` 降序，**只含库内有的**。
  Future<List<CalendarEntry>> fetchHotInLibrary({
    required String apiKey,
    required Set<String> libTvIds,
    required Set<String> libMovieIds,
    int pages = 3,
    int limit = 30,
  }) async {
    // 四个类别（与"分类浏览"共用同一套 genre 映射）
    const cats = <(BrowseCategory, String, String)>[
      (BrowseCategory.series, 'tv', '18'),
      (BrowseCategory.variety, 'tv', '10764|10767'),
      (BrowseCategory.anime, 'tv', '16'),
      // 电影走 discover/movie（无 genre 过滤 ⇒ 全部热播电影）
      (BrowseCategory.movie, 'movie', ''),
    ];

    final collected = <CalendarEntry>[];
    for (final (cat, kind, gid) in cats) {
      final lib = kind == 'tv' ? libTvIds : libMovieIds;
      if (lib.isEmpty) continue;
      // 逐页并发取
      final pagesData = await Future.wait(
        List.generate(pages, (i) => _hotPage(
              apiKey: apiKey, kind: kind, genreId: gid, page: i + 1)),
      );
      for (final list in pagesData) {
        for (final it in list) {
          final id = '${it['id']}';
          // ★ 交集：库里没有的**直接跳过**（否则点进去"找不到"）
          if (!lib.contains(id)) continue;
          collected.add(CalendarEntry(
            title: (it['name'] as String?) ??
                (it['title'] as String?) ??
                '',
            titleCn: (it['name'] as String?) ?? (it['title'] as String?),
            // 热播没有"更新日"语义 ⇒ 不冒充"今天更新"
            airDate: (it['first_air_date'] as String?) ??
                (it['release_date'] as String?),
            weekday: null,
            posterUrl: it['poster_path'] == null
                ? null
                : 'https://image.tmdb.org/t/p/$posterLargeSize${it['poster_path']}',
            // 首页 hero 用 backdrop（大图）
            rating: (it['vote_average'] as num?)?.toDouble(),
            summary: it['overview'] as String?,
            popularity: (it['popularity'] as num?)?.toDouble(),
            // BrowseCategory → CalendarCategory（复用已有映射）
            category: _categoryOfBrowse(cat),
            source: 'tmdb',
            sourceId: id,
          ));
        }
      }
    }
    // 按热度降序（跨类别统一排序 —— 用户要"按热度显示"）
    collected.sort((a, b) =>
        (b.popularity ?? 0).compareTo(a.popularity ?? 0));
    return collected.length > limit
        ? collected.sublist(0, limit)
        : collected;
  }

  /// 取 TMDB 热播的一页（带缓存）。
  Future<List<Map<String, dynamic>>> _hotPage({
    required String apiKey,
    required String kind,
    required String genreId,
    required int page,
  }) async {
    final cacheKey = 'hot:$kind:$genreId:$page';
    try {
      final cached = await cache?.get(cacheKey);
      String body;
      if (cached != null && cached.isNotEmpty) {
        body = cached;
      } else {
        final params = <String, dynamic>{
          'api_key': apiKey,
          'language': 'zh-CN',
          'sort_by': 'popularity.desc',
          'page': '$page',
          // ★ 国产为主（用户在中国；实测加它命中率显著提高）
          'with_original_language': 'zh',
        };
        if (genreId.isNotEmpty) params['with_genres'] = genreId;
        final r = await _dio.get<String>(
          'https://api.themoviedb.org/3/discover/$kind',
          queryParameters: params,
          options: Options(
              responseType: ResponseType.plain,
              headers: {'User-Agent': _ua},
              // 与分类浏览同一个理由：dio 默认不超时
              receiveTimeout: const Duration(seconds: 12)),
        );
        if (r.statusCode != 200 || r.data == null) return const [];
        body = r.data!;
        await cache?.put(cacheKey, body, ttl: cacheTtl);
      }
      final j = jsonDecode(body);
      if (j is! Map) return const [];
      return [
        for (final x in (j['results'] as List? ?? const []))
          if (x is Map<String, dynamic>) x
      ];
    } catch (e) {
      debugPrint('[Calendar] 热播页失败（跳过）: ${_friendly(e)}');
      return const [];
    }
  }

  /// **批量取平台名**（`tmdbId → 中文平台名`），用于首页 hero 的兜底。
  ///
  /// ## 使用场景（用户 2026-10-12）
  /// > "平台标签你先从服务端获取，服务端获取不到的，通过 tmdb 和豆瓣获取"
  ///
  /// 服务端（Emby `Studios`）实测填充率 **88% / 92%** ⇒ 剩下 8–12% 走这里。
  ///
  /// ## ★ 为什么单独写一个方法（而不是循环调 `fetchDetail`）
  /// `fetchDetail` 会带 `append_to_response=credits`（演职员大对象）。
  /// 这里**只要 `networks`** ⇒ 直接请求 `/tv/{id}`（或 `/movie/{id}`），
  /// 响应体小一个数量级，且**并发**发出。
  ///
  /// ## 缓存（避免每次刷新都打 TMDB）
  /// 键 `platform:<tmdbId>`，TTL = `cacheTtl`（与详情一致）。
  /// **命中就完全跳过网络** ⇒ 第二次进首页 0 请求。
  ///
  /// ## ⚠️ 为什么不再接豆瓣兜底
  /// 豆瓣的"播出平台"字段在 `m.douban.com/rexxar/api/v2` 的详情里**不存在**
  /// （实测字段只有 `countries`/`genres`/`pubdate` 等，没有电视台/平台）。
  /// 硬凑只能靠"标题搜索 + 抓播放链接"，脆弱且易错。
  /// ⇒ TMDB 拿不到就**如实不显示**（宁缺勿造，与 AGENTS §5.8 一致）。
  Future<Map<String, String>> fetchPlatformsByTmdbIds(
    List<String> tmdbIds, {
    required String apiKey,
    String kind = 'tv',
  }) async {
    final out = <String, String>{};
    final need = <String>[];
    for (final id in tmdbIds) {
      if (id.isEmpty) continue;
      final cached = await cache?.get('platform:$id');
      if (cached != null && cached.isNotEmpty) {
        out[id] = cached;
      } else if (!need.contains(id)) {
        need.add(id);
      }
    }
    // 命中的直接返回，未命中的并发请求
    await Future.wait(need.map((id) async {
      try {
        final r = await _dio.get<String>(
          'https://api.themoviedb.org/3/$kind/$id',
          queryParameters: {'api_key': apiKey, 'language': 'zh-CN'},
          options: Options(
              responseType: ResponseType.plain,
              headers: {'User-Agent': _ua},
              // 与分类浏览同一个理由：dio 默认不超时
              receiveTimeout: const Duration(seconds: 10)),
        );
        if (r.statusCode != 200 || r.data == null) return;
        final j = jsonDecode(r.data!);
        if (j is! Map) return;
        // 剧集用 `networks`，电影是 `production_companies`（无 networks）
        final list = (j['networks'] as List?) ??
            (j['production_companies'] as List?) ??
            const [];
        final names = [
          for (final n in list)
            if (n is Map && (n['name'] as String?)?.isNotEmpty == true)
              n['name'] as String
        ];
        if (names.isEmpty) return;
        final cn = cnPlatformName(names.first);
        out[id] = cn;
        await cache?.put('platform:$id', cn, ttl: cacheTtl);
      } catch (_) {
        // 单条失败不影响其它（平台是"锦上添花"）
      }
    }));
    debugPrint('[Calendar] 平台兜底：查 ${need.length} 条，命中缓存 '
        '${tmdbIds.length - need.length} 条，共得 ${out.length} 条');
    return out;
  }

  /// **分类浏览**：按「类别 × 地区」拉 TMDB 榜单（稿子 180b4d 的分类面板）。
  ///
  /// ## 实测（24/24 组合全部有数据）
  /// | 类别 | 地区 | 实测 |
  /// |---|---|---|
  /// | 剧集 | 全部/国产/港台/日韩/欧美 | 各 20 条 |
  /// | 电影 | 同上 | 各 20 条 |
  /// | 动漫 | 全部/国漫/日番/欧美 | 各 20 条 |
  /// | 综艺 | 全部/国产/日韩/欧美 | 各 20 条 |
  /// | 纪录片 | 全部/国产/欧美 | 各 20 条 |
  /// | 儿童 | 全部/国产/欧美 | 各 20 条 |
  ///
  /// ## ★★ 两个实测得出的要点（写死在参数拼装里）
  /// ① `with_origin_country` 多值用 **`|`**（逗号是 AND ⇒ 0 条）
  /// ② "国产/国漫"额外加 `with_original_language=zh`
  ///    —— 只用 `origin_country=CN` 会混入港台合拍片
  ///    （实测"剧集/全部"第一条是《爱·回家之开心速递》）
  ///
  /// ## 为什么用 `queryParameters` 字典（而不是拼字符串）
  /// 我上一版在 Python 里拼 query 时用**三元表达式**制造出**重复的 `sort_by`**
  /// ⇒ TMDB 全部回 400 且不说是哪个参数。Dio 的 `queryParameters` 是 Map
  /// ⇒ **天然不会重复**。
  Future<List<CalendarEntry>> fetchBrowse({
    required String apiKey,
    required BrowseCategory category,
    required BrowseRegion region,
    int page = 1,
    // ══════════════════════════════════════════════════════════════
    // ★★ 2026-10-15 新增：失败时是**抛异常**还是返回空列表
    // ══════════════════════════════════════════════════════════════
    //
    // ## 为什么必须区分（真机截图 + logcat 实证）
    // 原实现把**任何**异常都 `return const []` ⇒ 调用方**分不清**
    // "这个分类真的没内容"与"请求失败了"：
    // ```
    // 真机截图: 「这个分类下没有内容」 + [重新加载]
    // 真机日志: [Calendar] 分类浏览异常: 超时     ← 明明是**失败**
    // ```
    // ⇒ 用户被**误导**（AGENTS §7.8：不许把失败伪装成空）。
    //
    // ## 为什么用**可选参数**而不是直接改行为
    // 改默认行为会影响所有既有调用方；
    // 加参数 = **零破坏**（默认 `false` 与原来完全一致）。
    bool throwOnError = false,
  }) async {
    // ══════════════════════════════════════════════════════════════
    // ★★ 缓存键**必须含排序维度**（2026-10-15 修的第四个根因）
    // ══════════════════════════════════════════════════════════════
    //
    // ## 原来的键（**它让"改了排序"看不到效果**）
    // ```dart
    // 'browse:${category.name}:${region.label}:$page'
    // //       ↑ 类别        ↑ 地区      ↑ 页码        ← ★ 没有 sortBy
    // ```
    // ## 为什么这是缺陷（真机实测暴露）
    // 我把 6 个类别的 `sort_by` 从 `popularity.desc` 改成各自的维度后，
    // 真机点「电影」**立即出数据、零请求、零 `[Browse]` 日志**
    // ⇒ 命中的是**磁盘缓存里旧的（`popularity.desc`）响应**
    // ⇒ **改了等于没改**，而且用户**永远看不到修复**（直到 TTL 过期）。
    //
    // ⚠️ 这与 `activity` 里"缓存键漏维度"是同一类错误：
    //    **缓存键必须覆盖所有影响结果的输入**。
    //    `sort_by` / `with_genres` / `with_origin_country` /
    //    `primary_release_date.gte` **都影响结果** ⇒ 都要进键。
    //    （`kind` 由 `category` 决定、`language` 固定 ⇒ 不必单列。）
    //
    // ## 为什么保留旧前缀格式
    // 便于人工辨认（`grep browse:`）；新键在末尾多一段排序。
    // ⚠️ 旧键会**自然过期**（TTL），不需要主动清理。
    final cacheKey = 'browse:${category.name}:${region.label}:$page'
        ':${category.sortBy}'
        // 电影的日期窗口也影响结果（近 3 年）⇒ 进键
        '${category == BrowseCategory.movie ? ':y${DateTime.now().year - 3}' : ''}'
        // ⚠️ `vote_count.gte` 同样影响结果（F 项）⇒ 也进键
        //    （教训：**缓存键必须覆盖所有影响结果的输入** —— Jellyfin 的
        //      12 个缓存键全部带 `language` 是同一原则）
        '${category.sortBy.startsWith('vote_average') ? ':vc50' : ''}';
    try {
      final cached = await cache?.get(cacheKey);
      String body;
      if (cached != null && cached.isNotEmpty) {
        body = cached;
      } else {
        final params = <String, dynamic>{
          'api_key': apiKey,
          'language': 'zh-CN',
          // ★ 用**类别自己的**排序维度（2026-10-15 修）：
          //   原来 6 个类别**全用** `popularity.desc` ⇒ TMDB 的热度榜是
          //   **全球通用**的 ⇒ 各类别前几条必然高度重叠
          //   ⇒ 用户报障"6 个类别点开其实就在一块"。
          'sort_by': category.sortBy,
          'page': '$page',
        };
        // ⚠️ 电影按上映日期排序时**必须**配套日期窗口：
        //    TMDB 对 `primary_release_date.desc` 的已知行为是
        //    "不限制窗口时优先返回**很久以前**的高热度片"
        //    ⇒ 那就又变回"热门老片"了，等于没改。
        if (category == BrowseCategory.movie) {
          final y = DateTime.now().year;
          params['primary_release_date.gte'] = '${y - 3}-01-01';
        }
        // ══════════════════════════════════════════════════════════════
        // ★ F 项：`vote_average` 排序**必须**配 `vote_count.gte`
        // ══════════════════════════════════════════════════════════════
        //
        // ## 为什么（TMDB 的知名坑）
        // `sort_by=vote_average.desc` 会把"**1 票 10 分**"的新片排在最前 ——
        // 那不是"评分最高"，那是"样本最少"。TMDB 官方文档与社区都建议
        // 配 `vote_count.gte` 做**最小票数门槛**。
        //
        // ## 为什么是 50
        // 太严（如 500）会把纪录片/小众片**整类滤空**（纪录片本来就冷门）；
        // 太松（如 10）挡不住刷分。50 是社区常用值，且对"纪录片"这类
        // 我们要用的类别**不至于全空**。
        // ⇒ 只对**用评分排序**的类别加（其他类别加了会无谓缩量）。
        if (category.sortBy.startsWith('vote_average')) {
          params['vote_count.gte'] = '50';
        }
        final g = category.genreId;
        if (g != null && g.isNotEmpty) params['with_genres'] = g;
        final c = region.countries;
        if (c != null && c.isNotEmpty) {
          // ⚠️ `|` 不编码（TMDB 用它表达 OR；编码成 %7C 实测也能用，
          //    但保持原样更直观）
          params['with_origin_country'] = c.join('|');
        }
        if (region.forceChinese) params['with_original_language'] = 'zh';

        // ★ 请求级日志（2026-10-15 新增）
        //
        // ## 为什么必须有（用户报障时**看不到任何线索**）
        // 原来本方法只有**失败**日志（HTTP 非 200 / 异常）。
        // 而用户报的是"6 个类别点开其实就在一块" —— 那是
        // **请求成功但内容相似**，所有失败日志都是空的
        // ⇒ 完全无法定位（我当时只能靠猜）。
        // 有了这行，一次操作就能看出：类别 → 参数 → 条数。
        debugPrint('[Browse] ${category.label}/${region.label} → '
            'sort=${category.sortBy} '
            'genres=${params['with_genres'] ?? "无"} '
            'country=${params['with_origin_country'] ?? "无"} '
            'dateGte=${params['primary_release_date.gte'] ?? "无"} '
            'minVotes=${params['vote_count.gte'] ?? "无"}');

        final r = await _dio.get<String>(
          'https://api.themoviedb.org/3/discover/${category.kind}',
          queryParameters: params,
          options: Options(
              responseType: ResponseType.plain,
              headers: {'User-Agent': _ua},
              // ★ 必须显式设超时：dio 默认**不超时** ⇒ 请求挂住时
              //    浏览页的 spinner 会**永远转**（真机截图见过：切到
              //    「综艺」后一直转，而同一次运行的日历页已明确报
              //    "TMDB 国产剧集…暂不可用"）⇒ 用户无法判断
              //    "在加载"还是"已经死了"。
              sendTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 12)),
        );
        if (r.statusCode != 200 || r.data == null) {
          debugPrint('[Calendar] 分类浏览失败 HTTP ${r.statusCode}');
          return const [];
        }
        body = r.data!;
        // ★ 用 **listTtl**（30min）而不是 6h（2026-10-15，E 项）：
        //   discover 列表按 `first_air_date.desc` / `popularity.desc` 排序，
        //   **每天甚至每小时都在变** ⇒ 6h 会出现"早上看到的榜单，晚上还是同一批"。
        //   ⚠️ 详情类（按 id 取，几乎不变）继续用 `cacheTtl`（6h）。
        await cache?.put(cacheKey, body, ttl: listTtl);
      }
      final j = jsonDecode(body);
      final out = <CalendarEntry>[];
      for (final it in ((j as Map)['results'] as List? ?? const [])) {
        if (it is! Map) continue;
        final name = (it['name'] as String?) ?? (it['title'] as String?) ?? '';
        if (name.isEmpty) continue;
        final poster = it['poster_path'] as String?;
        out.add(CalendarEntry(
          title: name,
          titleCn: name,
          airDate: (it['first_air_date'] as String?) ??
              (it['release_date'] as String?),
          // ⚠️ 浏览面板没有"更新日"语义 ⇒ weekday 留 null
          //    （硬塞一个会让"按周几"的排序把它算错）
          weekday: null,
          posterUrl: poster == null
              ? null
              : 'https://image.tmdb.org/t/p/$posterSize$poster',
          rating: (it['vote_average'] as num?)?.toDouble(),
          summary: it['overview'] as String?,
          popularity: (it['popularity'] as num?)?.toDouble(),
          category: _categoryOfBrowse(category),
          source: 'tmdb',
          sourceId: it['id']?.toString(),
        ));
      }
      // ══════════════════════════════════════════════════════════════
      // ★★ 2026-10-15：**删掉了**"按热度降序"的客户端重排
      // ══════════════════════════════════════════════════════════════
      //
      // ## 原来的代码（**它是"6 个类别点开在一块"的最终原因**）
      // ```dart
      // // 按热度降序（与日历一致）
      // out.sort((a, b) => (b.popularity ?? 0).compareTo(a.popularity ?? 0));
      // ```
      //
      // ## 为什么必须删
      // 服务端已经按 `category.sortBy` 排好了（如 `first_air_date.desc`
      // = 最近在播、`vote_average.desc` = 评分最高）。
      // **客户端再按 popularity 重排一次 ⇒ 把服务端的排序完全抹掉**
      // ⇒ 6 个类别无论怎么查，最终都变成"热度降序"
      // ⇒ **看起来就是"点开都差不多 / 在一块"**。
      //
      // ⚠️ 这与"只改 `sort_by` 不改这里"是一对照实验：
      //    只改 `sort_by` 而留着这行 ⇒ **改了等于没改**。
      //    （本仓库 §6.10 规则②的同类：只改一处、另一处覆盖它。）
      //
      // ## 为什么其它方法（日历/热播）**保留** popularity 排序
      // 那些接口服务端返回的顺序**不保证**（`/tv/on_the_air` 等），
      // 且它们的语义就是"按热度看"—— 与 `discover` 的 `sort_by` 不同。
      // ⇒ **只删本方法这一处**，不动其它 4 处（见 `grep 按热度降序`）。
      return out;
    } catch (e) {
      debugPrint('[Calendar] 分类浏览异常: ${_friendly(e)}');
      // ★ `throwOnError` ⇒ 让调用方能区分"**失败**"与"**空**"
      //   （默认 false = 保持旧契约，不破坏其它调用方）
      //   真机教训：不区分时 UI 显示"这个分类下没有内容"，
      //   而实际是 TMDB 超时 —— 那是**假话**（§7.8）。
      if (throwOnError) throw CalendarException(_friendly(e));
      return const [];
    }
  }

  /// 浏览类别 → 日历类别（**近似映射**，因为两者维度不同）。
  ///
  /// | 浏览类别 | 日历类别 |
  /// |---|---|
  /// | 动漫 | anime |
  /// | 综艺 | variety |
  /// | 其余（剧集/电影/纪录片/儿童） | series |
  ///
  /// ⚠️ 这是**近似**：日历的 `CalendarCategory` 只有三档（用户要求），
  ///    而浏览面板有六档。映射只为让卡片上的类别标签有值，不影响筛选。
  static CalendarCategory _categoryOfBrowse(BrowseCategory c) =>
      switch (c) {
        BrowseCategory.anime => CalendarCategory.anime,
        BrowseCategory.variety => CalendarCategory.variety,
        _ => CalendarCategory.series,
      };

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
                : 'https://image.tmdb.org/t/p/$posterSize$poster',
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
          : 'https://image.tmdb.org/t/p/$posterSize$poster',
      backdropUrl: backdrop == null
          ? null
          : 'https://image.tmdb.org/t/p/$backdropSize$backdrop',
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
      // ★ 实测：`number_of_episodes` 是**跨季总数**，不是"已更新"
      //   （斗破苍穹 279 vs last S5E214）⇒ 必须单独取 last_episode_to_air。
      lastEpisodeNumber: _lastEp(j)?['episode_number'] as int?,
      lastEpisodeSeason: _lastEp(j)?['season_number'] as int?,
      nextEpisodeNumber: _nextEp(j)?['episode_number'] as int?,
      nextAirDate: _nextEp(j)?['air_date'] as String?,
      status: str(j['status']),
      homepage: str(j['homepage']),
      tmdbId: (j['id'] ?? '').toString(),
    );
  }

  /// `last_episode_to_air`（**防御式**：可能缺失/不是 Map）。
  ///
  /// ## 为什么单独抽出来
  /// 解析里要读它**两次**（集号 + 季号），内联会写成
  /// `(j['last_episode_to_air'] as Map?)?['x']` —— 但 `as Map?` 在
  /// 字段是 `List`/`String` 等异常形状时会**抛异常**，不符合 §5.3
  /// "不允许对服务器字段做非空断言 / 必须防御式"。
  static Map? _lastEp(Map j) {
    final v = j['last_episode_to_air'];
    return v is Map ? v : null;
  }

  /// `next_episode_to_air`（连载中才有；已完结时缺失）。
  static Map? _nextEp(Map j) {
    final v = j['next_episode_to_air'];
    return v is Map ? v : null;
  }

  /// **某个订阅剧本周哪几天更新**（追剧 Tab 的周历用）。
  ///
  /// ## 实测依据
  /// ```
  /// GET /tv/{id}?append_to_response=season/{最新季}
  ///   → **一次请求**拿到全部集数（《仙逆》200 集 / 《你好，星期六》46 集）
  ///   → 每集有 air_date（yyyy-MM-dd）
  /// 《仙逆》本周更新: E162 air_date=2026-10-11（周日）
  /// ```
  /// （`append_to_response` 省掉了"先查季列表再逐个查季"的 N 次请求。）
  ///
  /// ## 返回
  /// [ShowWeek]（含 `weekday → 集号` 与**状态**）。
  /// 本周没有更新 ⇒ `days` 为空 Map（**不是 null**：空与"失败"要能区分）。
  ///
  /// ## ⚠️ 为什么只查**最新一季**
  /// 老季的集日期早已过去，与"本周更新"无关。
  /// 查全部季会让请求数随季数增长（《你好，星期六》5 季）。
  /// **只取 TMDB 的剧集状态**（`Returning Series` / `Ended` / …）。
///
/// ## ★ 为什么要单独取（不与 `fetchWeekEpisodes` 绑一起）
/// 真机实测（体能之巅）：
/// ```
/// [Calendar] 周历分集拉取失败 (1423191): 超时      ← 反复超时
/// ```
/// `fetchWeekEpisodes` 要打 **2 次** TMDB（`/tv/{id}` + `append_to_response`），
/// 超时风险高；而**状态只需要第 1 次**。
///
/// 两者绑一起 ⇒ **周历失败连带状态也拿不到** ⇒ 退回 Emby 的过期值
/// ⇒ 「体能之巅」明明 TMDB `status='Ended'`（本机实测），卡片却显示"连载中"。
/// ⇒ 这正是 §6.9.1「取数失败 ≠ 数据为空」的同一类错。
///
/// ## 与 `fetchWeekEpisodes` 的差异（刻意为之）
/// | | `fetchWeekEpisodes` | 本方法 |
/// |---|---|---|
/// | 请求数 | 2 | **1** |
/// | 超时 | 8s / 10s | **6s / 6s**（更短）|
/// | 失败返回 | 空 `ShowWeek()` | **null**（语义不同：null=没拿到）|
/// | 缓存键 | `weekep:...`（按周）| `tvstatus:...`（**不按周**：状态与周无关）|
///
/// ## 返回
/// TMDB 原始 `status` 字符串；`null` = 拿不到（**不编**）。
Future<String?> fetchTvStatus(String tmdbId, {required String apiKey}) async {
  if (tmdbId.isEmpty || apiKey.isEmpty) return null;
  // 状态与"本周"无关 ⇒ 缓存键**不带周**（与 `weekep` 相反）
  final cacheKey = 'tvstatus:$tmdbId';
  try {
    final cached = await cache?.get(cacheKey);
    if (cached != null && cached.isNotEmpty) return cached;
  } catch (_) {
    // 缓存读失败不该阻断主流程
  }
  try {
    final r = await _dio.get<String>(
      'https://api.themoviedb.org/3/tv/$tmdbId',
      queryParameters: {'api_key': apiKey, 'language': 'zh-CN'},
      options: Options(
          responseType: ResponseType.plain,
          headers: {'User-Agent': _ua},
          // ⚠️ 比 `fetchWeekEpisodes` 更短：这只是"锦上添花"的状态查询，
          //    不能因为它让追剧页长时间等待（实测 TMDB 在国内常超时）。
          sendTimeout: const Duration(seconds: 6),
          receiveTimeout: const Duration(seconds: 6)),
    );
    if (r.statusCode != 200 || r.data == null) return null;
    final meta = jsonDecode(r.data!) as Map;
    final st = meta['status'] as String?;
    if (st == null || st.isEmpty) return null;
    // ⚠️ 只缓存**成功**结果（失败也缓存会让状态错 6 小时）
    try {
      await cache?.put(cacheKey, st, ttl: cacheTtl);
    } catch (_) {}
    return st;
  } catch (e) {
    debugPrint('[Calendar] 状态拉取失败 ($tmdbId): ${_friendly(e)}');
    return null; // 拿不到 ⇒ null（调用方退回 Emby，**不编**）
  }
}

Future<ShowWeek> fetchWeekEpisodes(
    String tmdbId, {
    required String apiKey,
    DateTime? weekStart,
  }) async {
    if (tmdbId.isEmpty) return const ShowWeek();
    final monday = _mondayOf(weekStart ?? DateTime.now());
    // date(yyyy-MM-dd) → weekday(1=周一 … 7=周日)
    //
    // ⚠️ 必须显式写 `<String, int>{...}`：直接写 `{_ymd(d): d.weekday for ...}`
    //    会被 Dart 解析成 **Map 字面量**并报 "Undefined name 'd'"
    //    （生成式里的 `:` 让它误判为 map entry）。
    final wk = <String, int>{
      for (var i = 0; i < 7; i++)
        _ymd(monday.add(Duration(days: i))): i + 1,
    };

    final cacheKey = 'weekep:$tmdbId:${_ymd(monday)}';
    String? st; // TMDB status（缓存命中时从 body 里补读，见下）
    try {
      final cached = await cache?.get(cacheKey);
      String body;
      if (cached != null && cached.isNotEmpty) {
        body = cached;
      } else {
        // ① 先拿最新季号（一次请求）
        final r1 = await _dio.get<String>(
          'https://api.themoviedb.org/3/tv/$tmdbId',
          queryParameters: {'api_key': apiKey, 'language': 'zh-CN'},
          options: Options(
              responseType: ResponseType.plain,
              headers: {'User-Agent': _ua},
              // ★ 必须显式设超时（**真实事故**）：21 部订阅并发时，
              //   不设超时的请求会全部挂住 ⇒ 真机日志一片
              //   `周历分集拉取失败 (id): 超时` ⇒ 周历全 0。
              sendTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 10)),
        );
        if (r1.statusCode != 200 || r1.data == null) {
          return const ShowWeek();
        }
        final meta = jsonDecode(r1.data!) as Map;
        st = meta['status'] as String?;
        final seasons = (meta['seasons'] as List?) ?? const [];
        if (seasons.isEmpty) return ShowWeek(status: st);
        // ⚠️ **不能写 `seasons.last as Map`**（审计发现）：
        //    `seasons` 是 `dynamic` 列表，**元素类型不可信** ——
        //    TMDB 改结构时 `as Map` 直接抛异常 ⇒ 被外层 catch 变成
        //    "周历拉取失败" ⇒ **周历静默变空**（正是"体能之巅"那类问题）。
        //    ⇒ 类型不符时**降级返回**（status 已经拿到了，不浪费）。
        final lastSeason = seasons.last;
        if (lastSeason is! Map) return ShowWeek(status: st);
        final sn = lastSeason['season_number'];
        if (sn == null) return ShowWeek(status: st);

        // ② 一次请求拿该季全部分集（用 append_to_response 省一次往返）
        final r2 = await _dio.get<String>(
          'https://api.themoviedb.org/3/tv/$tmdbId',
          queryParameters: {
            'api_key': apiKey,
            'language': 'zh-CN',
            'append_to_response': 'season/$sn',
          },
          options: Options(
              responseType: ResponseType.plain,
              headers: {'User-Agent': _ua},
              // ★ 与 r1 同理：不设超时会让并发请求全部挂住
              sendTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 10)),
        );
        if (r2.statusCode != 200 || r2.data == null) {
          return ShowWeek(status: st);
        }
        body = r2.data!;
        // ⚠️ 只缓存成功响应（含空结果的失败缓存会让周历空 6 小时）
        await cache?.put(cacheKey, body, ttl: cacheTtl);
      }

      final j = jsonDecode(body) as Map;
      // `append_to_response=season/N` 把结果挂在键 `season/N` 下
      Map? seasonObj;
      for (final k in j.keys) {
        if (k is String && k.startsWith('season/') && j[k] is Map) {
          seasonObj = j[k] as Map;
          break;
        }
      }
      // 缓存命中时 `st` 还没赋值 ⇒ 从 body 里补读（保证状态一致）
      st ??= j['status'] as String?;
      if (seasonObj == null) return ShowWeek(status: st);
      final out = <int, List<int>>{};
      for (final e in (seasonObj['episodes'] as List? ?? const [])) {
        if (e is! Map) continue;
        final air = e['air_date'] as String?;
        if (air == null || air.isEmpty) continue;
        final wd = wk[air];
        if (wd == null) continue; // 不在本周
        // 变量名不能叫 num（会遮蔽 Dart 内置类型），故改名 epNum。
        // （踩过的报错：The name num is not a type）
        final epNum = (e['episode_number'] as num?)?.toInt();
        if (epNum == null) continue;
        (out[wd] ??= []).add(epNum);
      }
      for (final l in out.values) {
        l.sort();
      }
      return ShowWeek(days: out, status: st);
    } catch (e) {
      debugPrint('[Calendar] 周历分集拉取失败 ($tmdbId): ${_friendly(e)}');
      return const ShowWeek();
    }
  }

  /// 某个日期所在周的**周一**（UTC+8 语义，与 [_mondayOfThisWeek] 一致）。
  static DateTime _mondayOf(DateTime d) {
    final day = DateTime(d.year, d.month, d.day);
    return day.subtract(Duration(days: day.weekday - 1));
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

/// **日历/浏览数据源异常**（供调用方区分"失败"与"空结果"）。
///
/// ## 为什么需要（2026-10-15 真机报障）
/// `fetchBrowse` 原来把一切异常吞成 `return const []`
/// ⇒ 调用方无法区分，只能显示"这个分类下没有内容"（**假话**，违反 §7.8）。
/// 有了这个类型，调用方可将**真实原因**展示给用户
///（如"超时" ⇒ 提示检查网络或代理）。
class CalendarException implements Exception {
  const CalendarException(this.message);

  /// 已本地化（中文）的原因，可直接展示给用户。
  final String message;

  @override
  String toString() => message;
}
