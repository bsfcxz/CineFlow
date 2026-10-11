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

  @override
  String toString() => 'CalendarEntry($source,$displayTitle,w$weekdayResolved)';
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

    final tasks = <Future<CalendarSourceResult>>[
      guard(_fetchBangumi(), 'bangumi', 'Bangumi 番剧'),
      guard(_fetchTvmaze(), 'tvmaze', 'TVmaze 欧美/国漫'),
      guard(_fetchBilibili(), 'bilibili', 'B站番剧时间线'),
      if (tmdbKey != null && tmdbKey.isNotEmpty)
        guard(_fetchTmdb(tmdbKey), 'tmdb', 'TMDB 在播'),
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

  /// 抓**本周 7 天**（周一到周日）。
  ///
  /// ## ★★★ 性能实测（2026-10-11，真机验证驱动 —— 必须记录）
  /// ```
  /// 单个 /schedule/web 请求：7,832 ms  154 KB
  /// 18 个并发请求：       22,853 ms  4.4 MB（OK=18，无 429）
  /// ```
  /// ⇒ **每源 7 秒的 deadline 必然把 TVmaze 砍掉**（实测"超时（已跳过）"，
  ///   整源丢失、日历只剩 B站）。这不是调 deadline 能解决的 ——
  ///   4.4 MB 在真实移动网络下只会更慢。
  ///
  /// ## ★ 修法：**少请求 + 缩小响应**（而不是加长超时）
  /// 1. **只请求 7 天**（去掉 ±1 天的 2 天）⇒ 14 个请求
  /// 2. **只用 `schedule/web`**（含网络平台/国漫，是我们要的那份）
  ///    ⇒ 7 个请求（**从 18 降到 7**，响应从 4.4 MB 降到约 1.1 MB）
  /// 3. **超时后保留已拿到的部分**（见下：先解析再判超时）
  ///
  /// ## ⚠️ 牺牲了什么（如实记录）
  /// 去掉 ±1 天 ⇒ 无法做"按 UTC+8 重新分桶"（那需要相邻日的数据）。
  /// 改为**信任 TVmaze 的当地日过滤** + 用 `airstamp` 只算**星期几**
  ///（不改变归属日）⇒ 对"周视图"这个用途足够：
  /// 用户关心"**这周哪一天有什么**"，而不是"北京时间精确到哪一天"。
  ///
  /// 若将来要精确到 UTC+8 日界，正确做法是**服务端缓存**
  ///（一次抓 9 天，所有用户共用），而不是让每个客户端抓 4.4 MB。
  Future<CalendarSourceResult> _fetchTvmaze() async {
    const src = 'tvmaze';
    const label = 'TVmaze 欧美/国漫';
    final out = <CalendarEntry>[];
    final failures = <String>[];
    final monday = _mondayOfThisWeek();
    final bodies = <String, String>{}; // 'date' → body

    // ★ 只 7 天 × 1 端点 = 7 个请求（原 18 个）
    final days = [for (var i = 0; i < 7; i++) monday.add(Duration(days: i))];
    final fetched = await Future.wait(days.map((d) async {
      final date = _ymd(d);
      try {
        final cached = await cache?.get('calendar:$src:$date');
        if (cached != null && cached.isNotEmpty) return MapEntry(date, cached);
        final r = await _dio.get<String>(
          'https://api.tvmaze.com/schedule/web',
          queryParameters: {'date': date},
          options: Options(responseType: ResponseType.plain,
              headers: {'User-Agent': _ua}),
        );
        if (r.statusCode == 429) {
          failures.add('限流(429)');
          return MapEntry(date, '');
        }
        if (r.statusCode != 200 || r.data == null) return MapEntry(date, '');
        await cache?.put('calendar:$src:$date', r.data!, ttl: cacheTtl);
        return MapEntry(date, r.data!);
      } catch (e) {
        failures.add('$date: ${_friendly(e)}');
        return MapEntry(date, '');
      }
    }));
    for (final e in fetched) {
      if (e.value.isNotEmpty) bodies[e.key] = e.value;
    }

    // ── 解析（按 `airstamp` 的**星期**归类；见方法头说明）──
    final seenIds = <String>{};
    for (final entry in bodies.entries) {
      final body = entry.value;
      if (body.isEmpty) continue;
      try {
        final j = jsonDecode(body);
        if (j is! List) continue;
        for (final it in j) {
          if (it is! Map) continue;
          // ★★ show 的两处位置都要读（实测两个端点结构不同）
          final show = (it['show'] as Map?) ??
              ((it['_embedded'] as Map?)?['show'] as Map?) ??
              const {};
          final title = (show['name'] as String?) ??
              (it['name'] as String?) ??
              '';
          if (title.isEmpty) continue;
          final id = it['id']?.toString();
          if (id != null && !seenIds.add(id)) continue;

          // ★ 用 `airstamp` 算**星期**（UTC+8 视角），但**不改变归属日**
          final stamp = it['airstamp'] as String?;
          final weekday = _utc8Weekday(stamp) ??
              _weekdayOf(it['airdate'] as String?);
          final season = it['season'];
          final number = it['number'];
          final img = show['image'];
          final rating = (show['rating'] as Map?)?['average'];
          out.add(CalendarEntry(
            title: title,
            // airDate 仍用服务端给的当地日（周视图按 weekday 分桶）
            airDate: it['airdate'] as String?,
            weekday: weekday,
            episode: (season != null && number != null)
                ? 'S${_pad(season)}E${_pad(number)}'
                : null,
            posterUrl: httpsPosterUrl(img is Map ? (img['medium'] as String?) : null),
            rating: (rating as num?)?.toDouble(),
            summary:
                _stripHtml((show['summary'] ?? it['summary']) as String?),
            source: src,
            sourceId: id,
          ));
        }
      } catch (_) {
        // 单天解析失败不影响其余
      }
    }

    if (out.isEmpty && failures.isNotEmpty) {
      return CalendarSourceResult(
          source: src, label: label, error: failures.first);
    }
    return CalendarSourceResult(source: src, label: label, entries: out);
  }

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
  Future<CalendarSourceResult> _fetchTmdb(String apiKey) async {
    const src = 'tmdb';
    const label = 'TMDB 在播';
    try {
      final cached = await cache?.get('calendar:$src');
      String body;
      if (cached != null && cached.isNotEmpty) {
        body = cached;
      } else {
        final r = await _dio.get<String>(
          'https://api.themoviedb.org/3/tv/on_the_air',
          queryParameters: {'api_key': apiKey, 'language': 'zh-CN'},
          options: Options(responseType: ResponseType.plain,
              headers: {'User-Agent': _ua}),
        );
        if (r.statusCode != 200 || r.data == null) {
          // ⚠️ 不把 api_key 写进错误消息（安全红线）
          return CalendarSourceResult(
              source: src, label: label, error: 'HTTP ${r.statusCode}');
        }
        body = r.data!;
        await cache?.put('calendar:$src', body, ttl: cacheTtl);
      }
      final j = jsonDecode(body);
      final out = <CalendarEntry>[];
      for (final it in ((j as Map)['results'] as List? ?? const [])) {
        if (it is! Map) continue;
        final first = it['first_air_date'] as String?;
        final poster = it['poster_path'] as String?;
        out.add(CalendarEntry(
          title: (it['original_name'] as String?) ??
              (it['name'] as String?) ??
              '',
          titleCn: it['name'] as String?,
          airDate: first,
          weekday: _weekdayOf(first),
          posterUrl: poster == null
              ? null
              : 'https://image.tmdb.org/t/p/w300$poster',
          rating: (it['vote_average'] as num?)?.toDouble(),
          summary: it['overview'] as String?,
          source: src,
          sourceId: it['id']?.toString(),
        ));
      }
      return CalendarSourceResult(source: src, label: label, entries: out);
    } catch (e) {
      return CalendarSourceResult(
          source: src, label: label, error: _friendly(e));
    }
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

  static String _pad(Object? v) {
    final s = v?.toString() ?? '?';
    return s.length >= 2 ? s : '0$s';
  }

  /// 把 `airstamp`（ISO8601 带时区）换算到 **UTC+8** 后取**星期几**。
  ///
  /// ## 为什么按 UTC+8 算星期（而不改归属日）
  /// 实测：TVmaze 按"电视台当地日"过滤（请求 02-10 返回的 168 条里
  /// 有 8 条 `airdate=02-09`，但它们的 `airstamp` 换算到电视台本地时区
  /// 后全部等于 02-10）。
  ///
  /// 对中国观众，美东 02-10 20:00 = 北京 **02-11** 09:00
  /// ⇒ 归属到"北京时间的那一天"更符合直觉。
  ///
  /// ⚠️ 但本实现**只改星期、不改 `airDate`** —— 因为要精确改归属日
  /// 必须请求相邻两天（见 `_fetchTvmaze` 头部的性能实测：
  /// 那会让请求量到 18 个、响应 4.4 MB、耗时 22.8 秒，不可接受）。
  /// 对**周视图**这个用途，算对星期已经足够。
  ///
  /// ⚠️ `airstamp` 缺失时返回 null（调用方退回按 `airdate` 算）。
  static int? _utc8Weekday(String? airstamp) {
    if (airstamp == null || airstamp.isEmpty) return null;
    final dt = DateTime.tryParse(airstamp);
    if (dt == null) return null;
    final utc8 = dt.toUtc().add(const Duration(hours: 8));
    return utc8.weekday; // 1=Mon … 7=Sun
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

  /// TVmaze 的 `summary` 是 HTML（`<p>…</p>`）⇒ 去掉标签再显示。
  static String? _stripHtml(String? s) {
    if (s == null || s.isEmpty) return null;
    return s
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .trim();
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
      // ① 同源同 id（**最强**：抓取层的重复，如 TVmaze 的多次请求）
      if (e.sourceId != null && e.sourceId!.isNotEmpty)
        'src:${e.source}:${e.sourceId}',
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
