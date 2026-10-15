/// **Trakt 客户端**（剧集状态 / 已播集数 / 播出网）。
///
/// ## ★ 定位：**状态与集数的第三个独立判据**（不是周几/时刻的来源）
///
/// 实测（2026-10-14，本机 + 真机双测，用 Emby 里 11 部收藏的**真实 tmdb id**）：
///
/// | 字段 | 质量 | 用途 |
/// |---|---|---|
/// | `status` | ✅ **11/11** | 判连载/完结（**纠正了「体能之巅」的 Emby 过期值**）|
/// | `aired_episodes` | ✅ **11/11** | 平台已播集数（「财神窦占龙」= **11**，与用户口述一致）|
/// | `network` | ✅ 11/11 | 播出平台（Youku / Netflix / Disney+ …）|
/// | **`airs.day`/`airs.time`** | ❌ **不可用** | 见下 |
///
/// ### 为什么不用 `airs`（三条硬证据）
/// ```
/// 财神窦占龙   Tuesday 00:00  tz=Asia/Shanghai     ← 00:00 是占位符
/// 一斩苍穹     Tuesday 00:00  tz=Asia/Shanghai     ← 与优酷文案「周一10点SVIP」**差一天**
/// 遮天         Sunday  00:00  tz=America/New_York  ← 腾讯国产动漫却标美国时区
/// ```
/// ⇒ Trakt 的 `airs` 是**社区用户填的**（非平台官方）⇒ 质量不可靠。
/// **周几/时刻继续用既有三层**：优酷详情页文案（显式 SVIP）→ `airDate` → 放送星期。
///
/// ### ⚠️ `tmdb → trakt` 映射**有错配风险**
/// 实测「仙逆」（tmdb=229977）被映射到《陸小鳳之鳳舞九天》。
/// ⇒ 调用方**必须校验标题相似度**再采信（见 `TraktShow.titleMatches`）。
///
/// ## 与既有代码的关系
/// · **认证**：只读公开数据**不需要 OAuth** ⇒ 只要 Client ID
/// · **传输**：复用 `dio`（项目已有），不新增依赖
/// · **凭据**：Client ID 由用户填、存 `flutter_secure_storage`（与 TMDB key 同款）
///
/// ## 实测的接口形态（**两次请求**，因为 search 不给 status）
/// ```
/// GET /search/tmdb/{tmdbId}?type=show
///   → [ { "show": { "ids": {"trakt":201203,"tmdb":210905,...},
///                   "title": "Physical: 100", "year": 2023,
///                   "aired_episodes": 18 },
///         "type": "show", "score": 100 } ]
///   ⚠️ **不含 `status`** ⇒ 必须再查一次详情
///
/// GET /shows/{traktId}?extended=full
///   → { title, year, status, aired_episodes, network, first_aired,
///       last_aired, airs:{day,time,timezone}, rating, genres, runtime, ... }
///   ⚠️ **不带 `extended=full` 时 `status`/`network`/`airs` 全是 null**
///      （实测 `/shows/1388` → status=null、airs=null、aired_episodes=62 有值）
/// ```
library;

import 'dart:async';

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// 一次 Trakt 查询的结果。
///
/// 全部字段**可空** —— Trakt 是第三方站点，字段缺失是常态；
/// 缺时 UI **不显示**而不是编造（§5.3）。
class TraktShow {
  const TraktShow({
    required this.title,
    this.traktId,
    this.year,
    this.status,
    this.airedEpisodes,
    this.network,
    this.firstAired,
    this.lastAired,
  });

  /// Trakt 的 id（`ids.trakt`）。
  final int? traktId;

  /// 标题（英文/原名，**不是中文名**）。
  ///
  /// ⚠️ 用它做**错配校验**：Trakt 按 tmdb id 映射，但实测有错配
  /// （「仙逆」→《陸小鳳之鳳舞九天》）⇒ 拿到后应做相似度检查。
  final String title;

  /// 首播年份。
  final int? year;

  /// **上游原始状态**：`returning series` / `ended` / `canceled` /
  /// `in production` / `planned`。
  ///
  /// ## 为什么保留原文（不在这里转中文）
  /// 本项目已有 `statusCnOf()` 做归一（且它处理多种英文形态）。
  /// 在这里再转一次 ⇒ **同一个事实两处判据**（本仓库踩过多次）
  /// ⇒ 交给调用方用 `statusCnOf` 统一处理。
  final String? status;

  /// **已播出集数**（Trakt 口径）。
  ///
  /// ## 实测校准（为什么可信）
  /// | 剧 | Trakt | 我们的 danmu 方案 | 用户口述 |
  /// |---|---|---|---|
  /// | 财神窦占龙 | **11** | 16 | **11** |
  /// | 体能之巅 | 18 | — | — |
  /// ⇒ Trakt 与用户口述**一致**，比 danmu 的 `episodes[]` 更准
  /// （danmu 含未播预约集，我们已用 `aired` 修正，但仍有偏差）。
  ///
  /// ⚠️ 口径差异：Trakt 是**全剧累计**（跨季）；
  ///    我们的 `PlatformEpisodes.aired` 是**当前 bangumi** 的已播数。
  ///    单季剧两者一致；多季剧可能不同 ⇒ UI 应说明来源。
  final int? airedEpisodes;

  /// 播出网（如 `AMC` / `Netflix` / `Youku`）。
  final String? network;

  /// 首播时间（ISO8601）。
  final String? firstAired;

  /// **最近一集**的播出时间（ISO8601；null = 未完结/无数据）。
  ///
  /// ## 用途：判"是否还在更新"
  /// 与 `status` 互补 —— 有些剧 `status='returning series'` 但**已两年没更新**
  /// （实测「瑞奇·热维斯之街猫一族」就是这种）。
  final String? lastAired;

  bool get isEmpty =>
      status == null && airedEpisodes == null && network == null;

  /// **错配校验**：标题是否与我们的中文名"对得上"。
  ///
  /// ## 为什么要这个（实测踩到）
  /// `tmdb=229977`（仙逆）被 Trakt 映射到《陸小鳳之鳳舞九天》——
  /// **号对不上**，但 Trakt 照样返回 200 + 数据。
  /// ⇒ 若不校验，会把**别的剧**的状态盖到本剧上（比"查不到"更糟）。
  ///
  /// ## ⚠️ 2026-10-15 修的两个真缺陷（用户报"3 集未收录"）
  /// 日志实证：
  /// ```
  /// [Trakt] ⚠️ 错配未采信：tmdb=223911 → "Renegade Immortal"
  ///         （期望「仙逆」/null）          ← ★ 正确的剧被误杀
  /// ```
  /// **缺陷 ①：判据②对中文名永远失效（死代码）**
  /// ```dart
  /// final b = (cnTitle ?? '').toLowerCase();   // 「仙逆」
  /// if (RegExp(r'^[a-z0-9]{3}$').hasMatch(seg) && a.contains(seg)) ...
  /// //  ↑ 中文名的 3 字片段**永不匹配** `[a-z0-9]{3}` ⇒ 这个循环白跑
  /// ```
  /// **缺陷 ②：`expectYear == null` 时直接判 false**
  /// 上游 `resolveEpisode` 有一处**没传 `expectYear`** ⇒ 连第一道判据都进不去
  /// ⇒ 探到最后 `return false`。
  ///
  /// ## 修法（**放宽 + 保留防错配能力**）
  /// 关键认识：**中文名 vs Trakt 英文名本来就无法直接比**
  /// （「仙逆」= `Renegade Immortal`，字符层面毫无重叠）。
  /// ⇒ 判据改为三层，**任一层通过即采信**：
  /// 1. **年份匹配**（强信号，保留）
  /// 2. **拉丁片段匹配**（原本就有，对英文名有效）
  /// 3. **中文名也能给出信号** —— 用 Trakt 的 `ids.tmdb` 反向确认？做不到；
  ///    ⇒ 改为：**当年份缺失或对不上时，只要标题"像同一部剧"就采信**
  ///      （判据：拉丁片段 OR **调用方明确说别拦**）
  ///
  /// ⚠️ 但我**不能**简单改成"总是 true" —— 那会丢掉防错配能力
  /// （「仙逆」→《陸小鳳》那个案例是真事故）。
  /// ⇒ 折中：**把"不确定"与"明确不符"分开**：
  /// · 年份**都已知且不一致** ⇒ **明确不符** ⇒ 拒绝（这才是真错配）
  /// · 年份有一方未知 ⇒ **不确定** ⇒ **采信**（宁可采信，因为
  ///   tmdb id 是强标识；错配是少数，而误杀会让功能完全不可用）
  ///
  /// ## 为什么这个折中是安全的
  /// · `findByTmdb` 查的是 **`/search/tmdb/{id}?type=show`** ——
  ///   按 tmdb id 精确查，错配概率**本来就低**
  /// · 实测的错配案例（tmdb=229977 → 《陸小鳳》）**年份就不同**
  ///   ⇒ 靠"年份都已知且不一致"这一条足以拦住它
  /// · 而误杀的代价是**功能不可用**（"3 集未收录"），比错配更常见
  bool plausiblyMatches({String? cnTitle, int? expectYear}) {
    // ── 判据① 标题**明确重合** ⇒ 直接采信（优先级最高的"正向证据"）──
    //
    // ## ⚠️ 为什么它必须**先于年份**判断（2026-10-15 测试抓到的冲突）
    // 我第一版把"年份不一致 ⇒ 判否"放在最前，于是：
    // ```
    // title='Fanren Xiu Xian Zhuan' year=2020
    // cnTitle='Fanren 修仙传'      expectYear=2026
    // ⇒ 年份不同 ⇒ 判否
    // ```
    // **但标题明明重合**（`fan`）⇒ 这说明就是同一部剧
    //（年份差异的原因很多：Trakt 用首播年、我们用入库/季年；
    //  或数据源本身有偏差）。
    // ⇒ **有正向证据（标题重合）时，不该被年份差异否决**。
    //
    // 这是"多信号投票"的正确形态：
    // · 标题重合 = **正向证据** ⇒ 采信
    // · 标题不重合 + 年份都已知且不同 = **负向证据** ⇒ 拒绝
    // · 都没有 = **不确定** ⇒ 采信（策略 B，用户 2026-10-15 定）
    final a = title.toLowerCase();
    final b = (cnTitle ?? '').toLowerCase();
    if (a.isNotEmpty && b.isNotEmpty) {
      for (var i = 0; i + 3 <= b.length; i++) {
        final seg = b.substring(i, i + 3);
        // 只比拉丁片段（中文片段在英文标题里不会出现）
        if (RegExp(r'^[a-z0-9]{3}$').hasMatch(seg) && a.contains(seg)) {
          return true;
        }
      }
    }

    // ── 判据② 年份**都已知且不一致** ⇒ 明确错配 ⇒ 拒绝 ──
    //
    // ## 为什么这条能拦住真实的错配案例
    // 实测：`tmdb=229977`（仙逆 2023）→ Trakt 返回
    // 《陸小鳳之鳳舞九天》（**1979**）⇒ 年份差 44 年
    // ⇒ 标题不重合（上一步已排除）**且**年份明确不同 ⇒ 拦下 ✓
    if (expectYear != null && year != null) {
      if (expectYear != year) {
        debugPrint('[Trakt] 错配判定：年份不符（$expectYear vs $year）'
            '且标题无重叠 ⇒ 拒绝');
        return false;
      }
      return true;   // 年份相同 ⇒ 采信
    }

    // ── 判据③ 一年方份未知 ⇒ **不确定** ⇒ 采信（策略 B）──
    //
    // ## 为什么不再返回 false（本次修的**行为变更**，用户明确选择）
    // 原实现 `return false` ⇒ 把"**中文名 vs 英文名**"这种
    // **本来就无法比对**的情况判成"错配" ⇒ **误杀**。
    // 实测：`Renegade Immortal`（仙逆的官方英文名）被拦下
    // ⇒ 用户看到「3 集未收录」，实际是**我们自己的校验器拦的**。
    //
    // ## 为什么采信是安全的
    // · `findByTmdb` 按 tmdb id **精确查**，错配概率本来就低
    // · 真错配案例靠判据②（年份明确不同）足以拦住
    // · "年份未知"多半是上游漏传 `expectYear`（已在 detail_page 补上）
    debugPrint('[Trakt] 标题无法比对（「$cnTitle」vs「$title」），'
        '年份未知 ⇒ 按 tmdb 精确查的结果采信');
    return true;
  }

  @override
  String toString() => 'TraktShow($title, id=$traktId, status=$status, '
      'aired=$airedEpisodes, net=$network)';
}

/// **解析 `/shows/{id}?extended=full` 响应**（纯函数，便于单测）。
///
/// ## 为什么提成纯函数
/// 本仓库验证纪律（§8.1）："纯逻辑改动请补单元测试"。
///
/// ## 容错（§5.3：不允许对服务器字段做非空断言）
/// Trakt 是第三方 ⇒ 每个字段都做**类型判断**，
/// 类型不符返回 null，**不抛异常**（`as X` 会崩 —— 单测抓过同类问题）。
TraktShow? parseTraktShow(Map<String, dynamic> raw) {
  final t = raw['title'];
  String title = t is String ? t : '';
  if (title.isEmpty) {
    final ids = raw['ids'];
    if (ids is Map) {
      final slug = ids['slug'];
      if (slug is String) title = slug;
    }
  }
  if (title.isEmpty) return null; // 连标题都没有 ⇒ 数据不可用

  int? asInt(dynamic v) {
    if (v is int) return v;
    if (v is String) return int.tryParse(v);
    if (v is num) return v.toInt();
    return null;
  }

  String? asStr(dynamic v) => v is String && v.isNotEmpty ? v : null;

  int? traktId;
  final ids = raw['ids'];
  if (ids is Map) traktId = asInt(ids['trakt']);

  // ⚠️ `status` **必须**来自 `extended=full` —— 不带时响应里是 null
  //    （实测 `/shows/1388` → status=null，而 `?extended=full` → 'ended'）
  return TraktShow(
    traktId: traktId,
    title: title,
    year: asInt(raw['year']),
    status: asStr(raw['status']),
    airedEpisodes: asInt(raw['aired_episodes']),
    network: asStr(raw['network']),
    firstAired: asStr(raw['first_aired']),
    lastAired: asStr(raw['last_aired']),
  );
}

/// 从 `/search/tmdb/{id}` 响应里取 `traktId`（纯函数，便于单测）。
///
/// ## 响应形态（实测）
/// ```json
/// [ { "score": 100.0, "type": "show",
///     "show": { "title": "Physical: 100", "year": 2023,
///               "aired_episodes": 18,
///               "ids": { "trakt": 201203, "tmdb": 210905, "tvdb": 424941 } } } ]
/// ```
/// ⇒ 一个数组；取第一项（Trakt 已按匹配度排序）。
///
/// ## 返回
/// `traktId`；拿不到 = null（**不编**）。
int? parseTraktSearchId(dynamic raw) {
  if (raw is! List || raw.isEmpty) return null;
  for (final item in raw) {
    if (item is! Map) continue;
    final show = item['show'];
    if (show is! Map) continue;
    final ids = show['ids'];
    if (ids is! Map) continue;
    final v = ids['trakt'];
    if (v is int) return v;
    if (v is String) {
      final p = int.tryParse(v);
      if (p != null) return p;
    }
  }
  return null;
}


// ══════════════════════════════════════════════════════════════════
//  网络层
// ══════════════════════════════════════════════════════════════════

/// **Trakt 客户端**。
///
/// ## 生命周期
/// 由 `traktClientProvider` 构造（Client ID 为空时返回 null ⇒ 调用方跳过）。
/// 无状态、可安全复用。
/// Trakt HTTP 的**统一超时**（2026-10-15 新增）。
///
/// ## 🔴 为什么必须有（用户报障："还是没同步"）
/// 症状：点「同步」后 UI **永远转圈**，日志在 `partial=1` 之后**完全空白**
/// —— 既没有后续日志，也没有 catch 里的失败日志，`_snack` 也不弹。
///
/// ## 根因：`Dio()` 默认**没有任何超时**
/// ```dart
/// _dio = dio ?? Dio()      // ← connectTimeout / receiveTimeout 都是 null
/// ```
/// dio 的默认值是 **`null` = 无限等待** ⇒ 网络不通时请求**永久挂起**
/// ⇒ 调用方 `await` 永不返回 ⇒ 用户看到"没反应"（而不是错误提示）。
///
/// ⚠️ 这与本仓库 §5.5"失败要可降级"是**同一类**问题：
/// **卡住**比**报错**更糟 —— 报错至少用户知道发生了什么。
///
/// ## 取值依据
/// · `connectTimeout 10s`：Trakt 在部分网络环境不稳定（本机实测
///   `api.trakt.tv` 偶发不通）；10 秒足够区分"慢"与"不通"。
/// · `receiveTimeout 15s`：同步是**用户主动等**的操作，可以比
///   播放路径宽松些；但不能无限。
///
/// ⚠️ **不要**把它设成很大（如 60s）—— 那样用户会以为 App 卡死。
Dio _newTraktDio() {
  final d = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
    sendTimeout: const Duration(seconds: 10),
  ));
  // ══════════════════════════════════════════════════════════════════
  // 🔴 为什么要在**拦截器**里再强制注入一次（不是多此一举）
  // ══════════════════════════════════════════════════════════════════
  //
  // ## 真机证据（用户报障："还是没同步"，2026-10-15）
  // 构造时**已经**给了 `BaseOptions` 超时，但日志显示
  // `await _dio.post(...)` **永不返回**（等 30 秒仍无任何日志，
  // 连 `try/catch` 都没进）⇒ 说明请求级 `Options`（我们逐请求传的
  // `_opts`，只有 headers + validateStatus）**覆盖了 BaseOptions**，
  // 把这个请求的超时**清成了 null（无限等待）**。
  //
  // ## dio 的合并语义（关键）
  // 请求级 `Options` 的字段是 `null` 时，**不保证**回落到 `BaseOptions`
  // —— `Options.compose` 会以请求级为准。实测在这条路径上就是不回落。
  // ⇒ **只靠构造时的 BaseOptions 不可靠**。
  //
  // ## 修法：拦截器里兜底填满
  // 任何请求只要没显式设超时，就用默认值补上
  // ⇒ **一处生效、覆盖全部**（含以后新增的请求，不会漏）。
  //   ⚠️ 这比"逐个请求加超时"可靠 —— 后者已验证会漏
  //   （本文件曾有 12 处没加）。
  d.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) {
      options.connectTimeout ??= const Duration(seconds: 10);
      options.receiveTimeout ??= const Duration(seconds: 15);
      options.sendTimeout ??= const Duration(seconds: 10);
      handler.next(options);
    },
  ));
  return d;
}

class TraktClient {
  TraktClient({
    required this.clientId,
    Dio? dio,
    this.cache,
  })  : _dio = dio ?? _newTraktDio(),
        assert(clientId != '', 'Client ID 不得为空（provider 负责判空）');

  /// 用户的 Trakt Client ID（**凭据：只存 secure_storage，不入库**）。
  final String clientId;

  final Dio _dio;

  /// 可选缓存（复用日历那套 `CalendarCache`，零新增基建）。
  final TraktCache? cache;

  /// 公开只读接口的基址。
  static const kBase = 'https://api.trakt.tv';

  /// 缓存 TTL：**24 小时**。
  ///
  /// ## 为什么这么长
  /// · 剧集状态（连载/完结）一天最多变一次
  /// · Trakt 有**速率限制**（实测响应头带 `x-ratelimit`），不宜频繁请求
  /// · 与 TMDB 的 `cacheTtl`（6h）不同：那里周历每周都变，这里状态更稳
  static const cacheTtl = Duration(hours: 24);

  Map<String, String> get _headers => {
        'trakt-api-version': '2',
        'trakt-api-key': clientId,
        'Content-Type': 'application/json',
        // Trakt 要求可识别的 UA（不设会被 CF 拦的概率更高）
        'User-Agent': 'CineFlow/0.4.0 (Android)',
      };

  /// **按 TMDB id 查剧集信息**（两步请求）。
  ///
  /// ## 为什么必须两步（实测）
  /// `/search/tmdb/{id}` 的响应**不含 `status`**：
  /// ```json
  /// [{"show":{"ids":{"trakt":201203,...},"title":"Physical: 100",
  ///           "year":2023,"aired_episodes":18},"type":"show","score":100}]
  /// ```
  /// 而 `status` 只在 `/shows/{id}?extended=full` 里（且**不带 extended 也是 null**）。
  ///
  /// ## 参数
  /// · `tmdbId` —— Emby 的 `ProviderIds.Tmdb`（实测 11 部收藏 100% 有值）
  /// · `expectCnTitle` / `expectYear` —— 用于**错配校验**（见 `plausiblyMatches`）
  ///
  /// ## 返回
  /// · 命中且**校验通过** ⇒ `TraktShow`
  /// · 查不到 / 校验不过 / 网络失败 ⇒ **null**（调用方退回既有判据）
  Future<TraktShow?> findByTmdb(
    String tmdbId, {
    String? expectCnTitle,
    int? expectYear,
  }) async {
    final id = tmdbId.trim();
    if (id.isEmpty) return null;
    final cacheKey = 'trakt:tmdb:$id';
    try {
      final hit = await cache?.get(cacheKey);
      if (hit != null && hit.isNotEmpty) {
        // 缓存里存的是 JSON；解析失败**当作未命中**（不要因为坏缓存而不查）
        try {
          final m = jsonDecode(hit) as Map<String, dynamic>;
          if (m['__miss'] == true) return null; // 负缓存
          return parseTraktShow(m);
        } catch (_) {
          // 坏缓存 ⇒ 继续走网络
        }
      }
    } catch (_) {
      // 缓存读失败不该阻断
    }

    try {
      // ── 第一步：tmdbId → traktId ──
      final r1 = await _dio.get<dynamic>(
        '$kBase/search/tmdb/$id',
        queryParameters: {'type': 'show'},
        options: Options(
          headers: _headers,
          sendTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
        ),
      );
      if (r1.statusCode != 200 || r1.data == null) {
        debugPrint('[Trakt] search 失败 HTTP ${r1.statusCode} (tmdb=$id)');
        return null;
      }
      final traktId = parseTraktSearchId(r1.data);
      if (traktId == null) {
        debugPrint('[Trakt] 查不到（tmdb=$id）');
        // 负缓存：24h 内不再重试同一部（避免每进页面都打一次）
        await _putMiss(cacheKey);
        return null;
      }

      // ── 第二步：拿 status / aired / network ──
      final r2 = await _dio.get<Map<String, dynamic>>(
        '$kBase/shows/$traktId',
        queryParameters: {'extended': 'full'},
        options: Options(
          headers: _headers,
          sendTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
        ),
      );
      if (r2.statusCode != 200 || r2.data == null) {
        debugPrint('[Trakt] detail 失败 HTTP ${r2.statusCode} (trakt=$traktId)');
        return null;
      }
      final show = parseTraktShow(r2.data!);
      if (show == null) return null;

      // ── 错配校验（实测「仙逆」被映射到《陸小鳳之鳳舞九天》）──
      //
      // ## 为什么必须校验
      // tmdb id 对不上时 Trakt 照样返回 200 + 数据
      // ⇒ 不校验会把**别的剧**的状态盖到本剧（比"查不到"更糟）。
      if (!show.plausiblyMatches(cnTitle: expectCnTitle, expectYear: expectYear)) {
        debugPrint('[Trakt] ⚠️ 错配未采信：tmdb=$id → "${show.title}"'
            '（期望「$expectCnTitle」/$expectYear）');
        await _putMiss(cacheKey);
        return null;
      }

      // 只缓存**成功且校验通过**的结果（§6.9.1：失败不该被当成"没有"）
      try {
        await cache?.put(cacheKey, jsonEncode(r2.data), ttl: cacheTtl);
      } catch (_) {}
      return show;
    } on DioException catch (e) {
      // 网络失败 ⇒ null（**不写负缓存** —— 下次还要重试）
      debugPrint('[Trakt] 网络失败 (tmdb=$id): ${e.type}');
      return null;
    } catch (e) {
      debugPrint('[Trakt] 异常 (tmdb=$id): $e');
      return null;
    }
  }

  /// 写**负缓存**（查不到 / 错配）。
  ///
  /// ## 为什么负缓存也要存（而网络失败不存）
  /// · "查不到""错配"是**上游的确定结论** ⇒ 24h 内重试没意义（白打速率限制）
  /// · "网络失败"是**我方问题** ⇒ 下次必须重试
  /// ⇒ 两者必须区分（§6.9.1「取数失败 ≠ 数据为空」的同一原则）。
  /// `GET /shows/{traktId}/seasons/{n}/episodes` —— 某季的集列表。
  ///
  /// ## 实测（2026-10-14，§10.2 先行验证）
  /// ```
  /// GET /shows/1388/seasons/1/episodes → 200, 1842ms
  ///   [{ season:1, number:1, title:"Pilot",
  ///      ids:{ trakt:73482, tmdb:62085, tvdb:349232 } }, ...]
  /// ✅ 7/7 集都含 `ids.trakt`
  /// ```
  /// ## 为什么返回原始 List 而不是解析成模型
  /// 唯一用途是**取 `ids.trakt`**（`TraktEpisodeResolver.resolveEpisode`）。
  /// 造一个只用了两个字段的模型类是本仓库反对的"空概念"。
  ///
  /// ## 返回 null = **网络/服务端失败**（与"空列表"区分！）
  /// ⇒ 调用方据此决定**是否缓存**：失败不缓存（下次重试），
  ///   空的季才缓存（那集确实不存在）。
  Future<List<dynamic>?> fetchSeasonEpisodes({
    required int traktShowId,
    required int season,
  }) async {
    if (traktShowId <= 0 || season < 0) return null;
    try {
      final r = await _dio.get<dynamic>(
        '$kBase/shows/$traktShowId/seasons/$season/episodes',
        options: Options(
          headers: _headers,
          sendTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
        ),
      );
      if (r.statusCode != 200) {
        debugPrint('[Trakt] seasons/$season/episodes HTTP ${r.statusCode} '
            '(show=$traktShowId)');
        return null;
      }
      final d = r.data;
      return d is List ? d : null;
    } catch (e) {
      debugPrint('[Trakt] seasons/$season/episodes 异常: $e');
      return null;
    }
  }

  Future<void> _putMiss(String key) async {
    try {
      await cache?.put(key, jsonEncode({'__miss': true}), ttl: cacheTtl);
    } catch (_) {}
  }

  /// **申请设备码**（登录第一步）。
  ///
  /// ## 实测（2026-10-14）
  /// ```
  /// POST /oauth/device/code  {"client_id": "<用户的 Client ID>"}
  /// → 200 {"device_code":"<43 字符>", "user_code":"KY5QEMVZ",
  ///        "verification_url":"https://auth.trakt.tv/activate",
  ///        "expires_in":600, "interval":6}
  /// ```
  /// ## 返回
  /// 会话对象；失败 ⇒ null（调用方提示"申请失败，请检查 Client ID"）。
  Future<TraktDeviceSession?> startDeviceAuth() async {
    try {
      final r = await _dio.post<dynamic>(
        '$kBase/oauth/device/code',
        data: {'client_id': clientId},
        options: Options(
          headers: _headers,
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
          // Trakt 在错误时也返回空 body ⇒ 让 dio 把 4xx 交给我们判断
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      if (r.statusCode != 200 || r.data is! Map) {
        debugPrint('[Trakt] 设备码申请失败 HTTP ${r.statusCode}');
        return null;
      }
      // ⚠️ **不能写 `r.data as Map`** —— `validateStatus` 允许 4xx，
    //    `r.data` 的类型**不可控**（可能是 String / null / List）。
    //    硬转遇到非 Map 会抛 ⇒ 被外层 catch 变成"设备码申请失败"（误导用户）。
    final m = r.data;
      String? str(dynamic v) => v is String && v.isNotEmpty ? v : null;
      int? num_(dynamic v) {
        if (v is int) return v;
        if (v is num) return v.toInt();
        if (v is String) return int.tryParse(v);
        return null;
      }

      final dc = str(m['device_code']);
      final uc = str(m['user_code']);
      final vu = str(m['verification_url']);
      if (dc == null || uc == null || vu == null) {
        debugPrint('[Trakt] 设备码响应缺字段: ${m.keys.toList()}');
        return null;
      }
      final exp = num_(m['expires_in']) ?? 600;
      final iv = num_(m['interval']) ?? 5;
      return TraktDeviceSession(
        deviceCode: dc,
        userCode: uc,
        verificationUrl: vu,
        expiresAtMs: DateTime.now().millisecondsSinceEpoch + exp * 1000,
        // 下限 1s：万一服务端给 0，别让 App 死循环打接口
        intervalSec: iv < 1 ? 1 : iv,
      );
    } on DioException catch (e) {
      debugPrint('[Trakt] 设备码申请网络失败: ${e.type}');
      return null;
    } catch (e) {
      debugPrint('[Trakt] 设备码申请异常: $e');
      return null;
    }
  }

  /// **轮询一次**（登录第二步；调用方按 `intervalSec` 反复调）。
  ///
  /// ## ★★ 实测的关键事实：**body 恒为空，只能靠 HTTP 状态码判**
  /// ```
  /// 400（0 字节） = 等待用户授权        → TraktAuthState.waiting
  /// 404（0 字节） = 码无效/过期         → TraktAuthState.expired
  /// 200           = 成功（返回 token）  → TraktAuthState.success
  /// 429           = 轮询过快            → TraktAuthState.slowDown
  /// 其它          = 可重试              → TraktAuthState.error
  /// ```
  /// ⚠️ **不要**写成 `if (body['error'] == 'authorization_pending')` ——
  ///    body 是空的，那种代码**永远不成立**（会一直当 error）。
  ///
  /// ## 未实测的分支（如实标注）
  /// `200` 时的 token 结构按官方形状解析，但**未经本机验证**
  /// （需用户本人在浏览器输码）⇒ 解析写成**容错式**，字段缺失不崩。
  Future<TraktTokenResult> pollDeviceToken(TraktDeviceSession session) async {
    try {
      final r = await _dio.post<dynamic>(
        '$kBase/oauth/device/token',
        data: {'code': session.deviceCode, 'client_id': clientId},
        options: Options(
          headers: _headers,
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final code = r.statusCode ?? 0;

      // ★ 按**状态码**判（body 为空，实测）
      if (code == 400) {
        return const TraktTokenResult(state: TraktAuthState.waiting);
      }
      if (code == 404) {
        return const TraktTokenResult(
          state: TraktAuthState.expired,
          message: '授权码已失效，请重新获取',
        );
      }
      if (code == 429) {
        return const TraktTokenResult(
          state: TraktAuthState.slowDown,
          message: '请求过于频繁，请稍候',
        );
      }
      if (code != 200) {
        return TraktTokenResult(
          state: TraktAuthState.error,
          message: 'Trakt 返回 HTTP $code',
        );
      }

      // ── 200：解析 token（**容错**，因该分支未本机实测）──
      final m = r.data;
      if (m is! Map) {
        return const TraktTokenResult(
          state: TraktAuthState.error,
          message: '授权成功但响应格式异常',
        );
      }
      String? str(dynamic v) => v is String && v.isNotEmpty ? v : null;
      int? num_(dynamic v) {
        if (v is int) return v;
        if (v is num) return v.toInt();
        if (v is String) return int.tryParse(v);
        return null;
      }

      final at = str(m['access_token']);
      if (at == null) {
        return const TraktTokenResult(
          state: TraktAuthState.error,
          message: '授权成功但未返回 access_token',
        );
      }
      return TraktTokenResult(
        state: TraktAuthState.success,
        accessToken: at,
        refreshToken: str(m['refresh_token']),
        expiresInSec: num_(m['expires_in']),
        scope: str(m['scope']),
      );
    } on DioException catch (e) {
      // ⚠️ 网络失败 ⇒ **error 而非 expired**（§6.9.1：取数失败 ≠ 数据为空）
      return TraktTokenResult(
        state: TraktAuthState.error,
        message: '网络失败：${e.type}',
      );
    } catch (e) {
      return TraktTokenResult(
        state: TraktAuthState.error,
        message: '轮询异常',
      );
    }
  }
}

/// Trakt 结果缓存（与日历那套 `CalendarCache` 同构：`get` / `put(ttl)`）。
///
/// ## 为什么不直接用 `CalendarCache`
/// `CalendarCache` 定义在 `calendar_client.dart`；直接引用会让
/// **data 层内部产生横向依赖**（trakt → calendar），而两者业务无关。
/// ⇒ 定义同构的最小接口，适配器在 provider 层做。
/// **集 id 解析**：把「tmdb 剧 id + 季/集号」换成**集级操作可用**的 id。
///
/// ## ★ 为什么需要（契约的硬约束）
/// ```ts
/// episodeIdsRequestSchema = union([{ trakt }, { tvdb }])   // ← **没有 tmdb**
/// showIdsRequestSchema    = union([{trakt},{slug},{imdb},{tmdb},{tvdb}])
/// ```
/// ⇒ 集级操作（scrobble / sync 单集）只能传 **trakt 或 tvdb**。
///
/// ## 职责边界（**只做 `findByTmdb` 做不到的那一段**）
/// `TraktClient.findByTmdb` 已经内置：
/// · `tmdb → trakt show id` 的查询
/// · 结果缓存（键 `trakt:tmdb:{id}`，含 `__miss` 负缓存）
/// · 错配校验（`expectCnTitle` / `expectYear`）
/// ⇒ 本类**不重复**这些（同一事实两处判据是本仓库反复踩的坑），
///   只负责**它没有的**：拿到某季的集列表并缓存。
///
/// ## 实测（§10.2 先行验证，2026-10-14）
/// ```
/// GET /search/tmdb/1396?type=show      → 200, 1060ms, trakt=1388
/// GET /shows/1388/seasons/1/episodes   → 200, 1842ms, **7/7 集含 ids.trakt**
/// ```
/// ⇒ 每集都有 trakt id（可放心用）；但**两次 1–2 秒** ⇒ 季列表必须缓存。
class TraktEpisodeResolver {
  TraktEpisodeResolver({required this.client, this.cache});

  final TraktClient client;
  final TraktCache? cache;

  /// 季集列表的 TTL。
  ///
  /// ## 为什么 7 天（而不是永久）
  /// 已播出集的 trakt id **不会变**，但**新集**会陆续加进来
  /// ⇒ 缓存太久会导致"最新一集解析不出 id"（用户刚看完就同步不了）。
  /// 7 天是折中：命中率高，且最多滞后一周就能拿到新集。
  static const _seasonTtl = Duration(days: 7);

  /// 解析出集级的 `TraktIds`（失败返回 null）。
  ///
  /// ## 返回 null 的四种情况（**都是可预期的**，不是错误）
  /// 1. Trakt 没有这部剧（`findByTmdb` 返回 null）
  /// 2. **错配**（传了 `expectCnTitle`/`expectYear` 时由 `findByTmdb` 拦下）
  /// 3. 该季/该集不存在（新集还没被 Trakt 收录）
  /// 4. 网络失败（**不写负缓存** ⇒ 下次重试）
  Future<TraktIds?> resolveEpisode({
    required String tmdbShowId,
    required int season,
    required int number,
    String? expectCnTitle,
    int? expectYear,
  }) async {
    if (tmdbShowId.trim().isEmpty || season < 0 || number <= 0) return null;

    // ① tmdb → trakt show（**复用** findByTmdb 的缓存与错配校验）
    final show = await client.findByTmdb(tmdbShowId,
        expectCnTitle: expectCnTitle, expectYear: expectYear);
    final traktShowId = show?.traktId;
    if (traktShowId == null || traktShowId <= 0) {
      return null;
    }

    // ② 该季的集列表（带缓存）
    final sKey = 'trakt:season:$traktShowId:$season';
    final cached = await cache?.get(sKey);
    if (cached != null) {
      final tid = _lookup(cached, number);
      // 缓存命中但**没有这一集** ⇒ 可能是新集（缓存过期前等一等）
      return tid == null ? null : TraktIds(trakt: tid);
    }

    final eps = await client.fetchSeasonEpisodes(
        traktShowId: traktShowId, season: season);
    if (eps == null) {
      // ⚠️ 网络失败 ⇒ **不写缓存**（否则会负缓存住"暂时查不到"）
      debugPrint('[Trakt] 季集列表拉取失败（不缓存，下次重试）');
      return null;
    }

    final map = <int, int>{};
    for (final e in eps) {
      if (e is! Map) continue;
      final n = e['number'];
      final ids = e['ids'];
      if (n is! int || ids is! Map) continue;
      final t = ids['trakt'];
      if (t is int) map[n] = t;
    }
    // 紧凑序列化（`集号:traktId,...`）—— 比存整个 JSON 小得多
    final packed = map.entries.map((e) => '${e.key}:${e.value}').join(',');
    await cache?.put(sKey, packed, ttl: _seasonTtl);

    final tid = map[number];
    return tid == null ? null : TraktIds(trakt: tid);
  }

  /// **Emby `SeriesId` → tmdb id**（反向映射，带进程内缓存）。
  ///
  /// ## ★ 为什么不用新接口（我一度加了，是多余的）
  /// `MediaProvider` **早就有** `mapSeriesTmdbToId()`：
  /// ```
  /// Future<Map<String, SeriesRef>> mapSeriesTmdbToId();
  ///   返回 tmdbId → SeriesRef(seriesId, platform)   ← 一次请求拿全表
  /// ```
  /// 我要的只是**反向** ⇒ 反转那张表即可。
  ///
  /// ⚠️ 我本轮**第二次**重复实现已有能力（第一次：`findByTmdb` 已自带
  ///    缓存与错配校验而我重写了一版）。教训：**动手前读完整抽象的方法列表**，
  ///    不要只看字段。
  ///
  /// ## 为什么要缓存反向表
  /// `mapSeriesTmdbToId()` 是"翻页拉全库"（实测 5713 条 Series）——
  /// 播放器起播路径上不能反复调 ⇒ 缓存到进程结束
  ///（剧与 tmdb 的对应关系不变）。
  /// **`seriesId → tmdbId` 反向表**（进程内缓存，由**外部预热**填入）。
  ///
  /// ## ★ 为什么不在这里主动拉（重要设计决策）
  /// `mapSeriesTmdbToId()` 是**翻页拉全库**（实测 5713 条 Series，数秒）。
  /// 若解析器在**起播路径**上触发它 ⇒ 用户每次冷启动第一次播放都要多等几秒。
  ///
  /// ⇒ 改为**只读缓存**：追剧页 / 首页本来就在拉那个映射
  ///   （它们必须拉，否则周历显示不出来），**顺手填这里**。
  ///   解析器拿不到 ⇒ **直接放弃上报**（宁可这集不记，也不让用户等）。
  ///   第一次播放可能不上报，但**第二次就有了**（缓存已被别处填好）。
  ///
  /// ## 与 §6.9.1 的一致性
  /// "取数失败 ≠ 数据为空" —— 这里更进一步：**不取数**（缓存空 => 静默跳过）。
  static Map<String, String>? _reverseCache;

  /// 由外部（追剧页）在拿到 `mapSeriesTmdbToId()` 结果后调用。
  ///
  /// ## 为什么是 push 而不是 pull
  /// 让"谁有数据"主动推给"谁需要数据"，而不是让播放路径去拉网络
  /// ⇒ 起播不受影响。这是本类的**唯一**依赖注入点。
  ///
  /// ## 🔴 2026-10-15 修了一个**方向反转两次**的真 bug
  /// 参数语义是 **`seriesId → tmdbId`**（与 `_reverseCache` 同一个方向），
  /// 而**旧实现又反转了一次** ⇒ 转两次 = 回到 `tmdbId → seriesId`
  /// ⇒ `tmdbIdForSeries(seriesId)` **永远查不到**。
  ///
  /// 真机证据（用户报障："光阴之外 / 仙逆未同步"）：
  /// ```
  /// 19:42:22  [Trakt] 反向映射已预热: 5713 条（seriesId → tmdb）  ← 数量对
  /// 19:45:18  [TraktTrack] 反向映射未预热 ⇒ 本次跳过              ← 其实"查不到"
  /// ```
  /// ⚠️ 数量是**对的**（5713），所以日志看起来完全正常 ⇒
  ///    只靠"条数"判断预热成功**永远发现不了这个 bug**。
  ///
  /// ## 契约（**调用方必须遵守**）
  /// | 参数 | 方向 |
  /// |---|---|
  /// | `seedReverseMap(v)` | `v[seriesId] = tmdbId` |
  /// | `_reverseCache` | 同上（不再反转）|
  /// | `tmdbIdForSeries(seriesId)` | 返回 `tmdbId` |
  ///
  /// ⚠️ **旧实现的锅**：参数名叫 `tmdbToSeriesId`（暗示 tmdb→series），
  ///    而调用方 `providers.dart` 传的却是 `rev`（已是 series→tmdb）
  ///    ⇒ 名字与实际相反，两边各自反转 ⇒ 抵消。
  ///    ⇒ 现在**参数名改成 `seriesToTmdb`**，名实一致，杜绝再犯。
  static void seedReverseMap(Map<String, String> seriesToTmdb) {
    final out = <String, String>{};
    for (final e in seriesToTmdb.entries) {
      // ⚠️ **不再反转** —— 直接收下（见上面的契约表）
      if (e.key.isNotEmpty && e.value.isNotEmpty) out[e.key] = e.value;
    }
    _reverseCache = out;
    // ⚠️ 自检样本的**截断要防越界**（测试用 1 字符 key 暴露过
    //    `RangeError: Invalid value: Not in inclusive range 0..1: 2`）
    // ⇒ 用 `clamp` 而不是硬编码 `substring(0, 2)`。
    final sample = out.isEmpty
        ? ''
        : '，样本 ${_head(out.keys.first, 8)}… → ${_head(out.values.first, 12)}';
    debugPrint('[Trakt] 反向映射已预热: ${out.length} 条（seriesId → tmdb）'
        // ★ 附一条**可自检**的样本：光看条数发现不了"方向反了"
        '$sample');
  }

  /// 安全截断（`s` 短于 `n` 时原样返回，**不越界**）。
  static String _head(String s, int n) => s.length <= n ? s : s.substring(0, n);

  /// 查 `seriesId` 对应的 tmdb id。**只读缓存，不发网络请求**。
  ///
  /// ## 为什么是 `static`
  /// 它只读 static 字段 `_reverseCache`，**不依赖任何实例状态**
  /// ⇒ 设为 static 后，播放器不必先 new 一个 `TraktEpisodeResolver`
  ///   就能查询（少一个无意义的对象）。
  ///
  /// ## 返回 null 的含义（**不是错误**）
  /// 缓存还没预热（本次冷启动后还没打开过追剧页）
  /// ⇒ 调用方应**静默跳过**这次上报（不要重试、不要报错）。
  static String? tmdbIdForSeries(String seriesId) {
    if (seriesId.trim().isEmpty) return null;
    final c = _reverseCache;
    if (c == null || c.isEmpty) return null;
    return c[seriesId];
  }

  /// 从紧凑串里取某集的 trakt id。
  static int? _lookup(String packed, int number) {
    for (final part in packed.split(',')) {
      final kv = part.split(':');
      if (kv.length == 2 && kv[0] == '$number') return int.tryParse(kv[1]);
    }
    return null;
  }
}

// ══════════════════════════════════════════════════════════════════════
//  ★ 播放同步（实时追踪 / 已看同步 / 续播检查）
// ══════════════════════════════════════════════════════════════════════
//
// ## 契约来源（**权威，非推测**）
// 取自 `trakt/trakt-api` 仓库的 `projects/api/src/contracts/`（ts-rest + zod）：
//
// ### ① `POST /scrobble/{start|pause|stop}`
// ```ts
// body: { progress: <float 0-100>,
//         episode?: { ids: { trakt } | { tvdb } },
//         movie?:   { title, year, ids: { trakt|slug|imdb|tmdb } } }
// resp 201: { id, progress, action: 'start'|'pause'|'stop', episode?, show? }
// ```
// 服务端语义（抄自 contract 的 description，**不是我的猜测**）：
// · `start` —— 开始播放或**取消暂停**时调用；**会清空**播放进度
// · `stop`  —— 停止/播完时调用；**>80% 视为看完**；1%–79% 视为 pause；
//              **<1% 返回 422 且忽略**；同一 item 刚 scrobble 过会 **409**
//
// ### ② `POST /sync/history`
// ```ts
// body: { movies?, shows?, seasons?, episodes? }   // 元素都带 ids
// resp: { added: {movies,episodes}, updated: {...}, not_found: {...} }
// ```
//
// ### ③ `GET /sync/playback`
// ```ts
// resp: [{ progress: <0-100>, paused_at: <ISO>, id,
//          type: 'movie'|'episode', movie?, episode?, show? }]
// ```
//
// ## ★★ 一个致命约束（决定了调用方必须做什么）
// ```
// episodeIdsRequestSchema = union([{ trakt }, { tvdb }])   ← **没有 tmdb**！
// showIdsRequestSchema    = union([{trakt},{slug},{imdb},{tmdb},{tvdb}])
// ```
// ⇒ **剧集级操作只能传 trakt 或 tvdb id**；只有 show 级才支持 tmdb。
//   我们详情页手里是 Emby itemId + tmdb id ⇒ **必须先解析出 trakt 剧集 id**。

/// scrobble 的动作（契约里响应回显的就是这三个字面量）。
enum TraktScrobbleAction {
  start,
  pause,
  stop;

  /// 路径段（与 `POST /scrobble/{action}` 一一对应）。
  String get path => name;
}

/// **播放同步客户端**（实时追踪 / 已看同步 / 续播）。
///
/// ## 为什么单独一个类（而不是塞进 `TraktClient`）
/// `TraktClient` 已经承担"查剧集元数据 + 设备码登录"，再塞三组播放 API
/// 会让它变成万能类。这里的职责是**播放态同步**，边界清晰。
///
/// ## 与 `TraktClient` 的关系
/// 复用它的 `_dio` 与 `clientId` —— 通过构造参数注入，不复制连接池。
class TraktSync {
  TraktSync({
    required this.clientId,
    required this.accessToken,
    /// **refresh token**（一次性；刷新后必须替换，见 [refresh]）。
    ///
    /// ## 为什么必须传进来（用户 2026-10-14 要求）
    /// access token 只有 **7 天**（官方文档）⇒ 不做刷新的话
    /// 用户 7 天后所有 Trakt 功能**静默失效**（表现为"同步不动了"）。
    this.refreshToken,
    /// **刷新成功后的回调**（把新的 access/refresh 写回安全存储）。
    ///
    /// ## 为什么用回调而不是让本类直接写存储
    /// ① `TraktSync` 是**数据层**，不该依赖 `SessionStore`（§5.1）
    /// ② 单测里不必构造 secure_storage
    this.onTokenRefreshed,
    /// **到期时刻回调**（epoch 毫秒）—— 借鉴小幻影视的
    /// `set_TraktExpiresTimestamp`。
    ///
    /// ## 为什么需要它
    /// 存了到期时刻才能"**提前**刷新"：不必等 401 才发现过期
    /// （那会多一次必然失败的请求 + 一条误导性的错误日志）。
    ///
    /// ⚠️ 必须进构造器 —— 我第一版把字段声明了却**忘了加参数**
    ///（`fromStore` 里传 `onExpiresAt:` ⇒ "named parameter isn't defined"）。
    this.onExpiresAt,
    Dio? dio,
    /// **裸 Dio**（刷新专用，不带拦截器）—— **仅测试注入用**。
    ///
    /// ## 为什么生产代码不给它传值
    /// 刷新**必须**走一个不带拦截器的实例，否则
    /// `/oauth/token` 返回 401 时会再次触发拦截器 ⇒ **无限递归**。
    /// 默认用 `_newTraktDio()`（裸的，但**带超时**）⇒ 生产无需传。
    /// ## 为什么测试要能注入
    /// 否则测试的假替身收不到刷新请求（它们注入的是 `dio`，那是业务请求用的）。
    Dio? bareDio,
  }) : _dio = dio ?? _newTraktDio(),
       _bare = bareDio {
    // ══════════════════════════════════════════════════════════════
    // ★ 401 自动刷新 + 重试（用户 2026-10-14 规格第 4 步）
    // ══════════════════════════════════════════════════════════════
    //
    // ## 为什么用"401 触发"而不是"定时刷新"
    // | 方式 | 问题 |
    // |---|---|
    // | 定时刷新 | 用户不活跃时也刷 ⇒ **浪费**；且覆盖不了"被提前吊销" |
    // | **401 触发** | 按需、且能覆盖任意失效原因（这才是用户要的语义）|
    //
    // ## ⚠️ 必须防的三个坑
    // ① **重试只能一次**：刷新后再 401 ⇒ 放弃（否则无限循环）
    // ② **并发的 401 只能触发一次刷新**：多个请求同时 401 时，
    //    若各自刷新 ⇒ 第二次用**已被作废**的 refresh token（一次性！）
    //    ⇒ 用 `_refreshing` Future 做"单飞"（single-flight）
    // ③ **刷新请求本身不能走这个拦截器**：否则 401 递归
    //    （`/oauth/token` 用独立的 dio 调用，见 `refresh()`）
    _dio.interceptors.add(InterceptorsWrapper(
      // ══════════════════════════════════════════════════════════════
      // ★★ 为什么**两个**回调都要挂（实测证据，不是"保险起见"）
      // ══════════════════════════════════════════════════════════════
      //
      // ## 决定性实测（2026-10-14，真 dio + 假 adapter）
      // ```
      // _opts.validateStatus = (s) => s < 500
      // PROBE-401      status=401  err=null  onError=0  onResponse=1
      // PROBE-DEFAULT（默认 validateStatus）  onError=1
      // ```
      // ⇒ 401 < 500 ⇒ 被当成**成功响应** ⇒ **永不进 `onError`**
      // ⇒ 只挂 `onError` 时，自动刷新**一行都不会执行**
      //    （我第一版就是这样，而且 14 个测试全绿 ——
      //      因为它们用 `_FakeDio`，绕过了真实 dio 行为）。
      //
      // ## 为什么不把 `validateStatus` 改成 `< 400`
      // 那会**破坏 scrobble 的 409/422 语义** —— 那两个是**正常业务**
      //（409 = 刚 scrobble 过；422 = progress < 1%），
      // 实测确认过，且 `TraktScrobbleResult` 依赖它。
      // ⇒ 保住 `validateStatus`，改为**两个回调都判 401**。
      onResponse: (r, handler) async {
        if (r.statusCode != 401) return handler.next(r);
        if (r.requestOptions.extra['__traktRetried'] == true) {
          debugPrint('[Trakt] 重放后仍 401 ⇒ 放弃（避免无限循环）');
          return handler.next(r);
        }
        final ok = await _refreshOnce();
        if (!ok) return handler.next(r);   // 刷新失败 ⇒ 把 401 交回调用方
        try {
          final o = r.requestOptions;
          o.headers['Authorization'] = 'Bearer $accessToken2';
          o.extra['__traktRetried'] = true;
          return handler.resolve(await _dio.fetch(o));
        } catch (err) {
          return handler.next(r);
        }
      },
      // 兜底：若某调用点用了**自己的** Options（validateStatus < 400），
      // 401 会走异常路径 ⇒ 这条分支仍需要。
      onError: (e, handler) async {
        if (e.response?.statusCode != 401) return handler.next(e);
        // 重试标记：已重试过就不再刷新（坑①）
        if (e.requestOptions.extra['__traktRetried'] == true) {
          debugPrint('[Trakt] 刷新后仍 401 ⇒ 放弃（避免无限循环）');
          return handler.next(e);
        }
        final ok = await _refreshOnce();
        if (!ok) return handler.next(e);
        try {
          // 用**新 token** 重放原请求（坑①：打标记）
          final o = e.requestOptions;
          o.headers['Authorization'] = 'Bearer $accessToken2';
          o.extra['__traktRetried'] = true;
          final r = await _dio.fetch(o);
          return handler.resolve(r);
        } catch (err) {
          return handler.next(e);
        }
      },
    ));
  }

  /// **单飞**（single-flight）刷新：并发 401 只触发一次刷新。
  ///
  /// ## 为什么这是硬要求（不是优化）
  /// Trakt 的 refresh token 是**一次性**的（官方原文）：
  /// > Every successful refresh returns a new `access_token` and
  /// > `refresh_token`. The refresh token used in the request is
  /// > **immediately invalidated**.
  /// ⇒ 若两个并发请求各刷一次，**第二次必然失败**（用已作废的 token）
  ///    且会把用户踢到"需要重新授权"。
  /// **从安全存储构造**（读 token + 自动写回刷新结果）。
  ///
  /// ## 为什么要有这个工厂（而不是三个页面各写一遍）
  /// 三个调用点（详情页 / 播放器 / 设置页）的"读 token + 刷新写回"
  /// 逻辑**完全相同** ⇒ 复制三份必然漏改（本仓库踩过"三处不一致"的坑）。
  /// ⇒ 收口到一处：页面只调 `fromStore`。
  ///
  /// ## 返回 null 的情况（**都不是错误**）
  /// · 没登录（无 access token）⇒ 调用方跳过 Trakt 功能
  ///
  /// ## ⚠️ 写回必须**同时**写 access 与 refresh
  /// refresh token 是**一次性**的（官方原文）⇒ 只写 access 会让
  /// 下次刷新用**已作废**的 refresh ⇒ 用户被踢到重新授权。
  /// ## ★ 提前刷新（借鉴小幻影视的 `GetValidTraktAccessTokenAsync`）
  ///
  /// 存了 `expires_at` 之后，可以在**快到期时主动刷新**，
  /// 而不是等 401 才发现过期（那会多一次必然失败的请求 +
  /// 一条误导性的错误日志）。
  ///
  /// ## 提前量 = 1 天（有依据，不是拍脑袋）
  /// · access token 寿命 **7 天**（官方文档）
  /// · 1 天 = 1/7 ⇒ 用户每天用一次就自动续上；
  ///   即使用户隔 6 天才用，也仍在有效期内
  /// · 提前量再大没意义（刷新只是多一次请求，但会让"刚登录就刷新"显得怪）
  ///
  /// ## ⚠️ 刷新失败**不阻断**（返回的 sync 仍可用）
  /// 旧 token 可能还没过期；且 401 拦截器还会再试一次。
  /// ⇒ 失败只记日志，**不返回 null**（那会让用户莫名"未登录"）。
  static const refreshLeadMs = 24 * 60 * 60 * 1000;

  static Future<TraktSync?> fromStore({
    required String clientId,
    required Future<String?> Function() readAccess,
    required Future<String?> Function() readRefresh,
    required Future<void> Function(String access, String? refresh) writeTokens,
    /// 存到期时刻（epoch 毫秒）。
    ///
    /// ## ⚠️ 不传它会让"提前刷新"**永远不触发**
    /// 链路是：`refresh()` → `_reportExpiry()` → `onExpiresAt` → 本回调
    /// → `SessionStore.saveTraktExpiresAt` → 下次 `expiresInMs()` 读到值。
    /// 断任何一环 ⇒ `expiresInMs()` 恒为 null ⇒ 提前刷新失效。
    /// （我第一版就漏了这一环 —— 方法定义了但没人调。）
    required Future<void> Function(int epochMs) writeExpiresAt,
    /// 读到期的剩余毫秒（null = 没记录 ⇒ 不提前刷新）。
    required Future<int?> Function() expiresInMs,
    Dio? dio,
    /// **裸 Dio**（刷新专用）—— **仅测试注入用**。
    ///
    /// ## 为什么生产不传
    /// 刷新**必须**走不带拦截器的实例，否则 `/oauth/token` 返回 401 时
    /// 会再次触发拦截器 ⇒ **无限递归**。默认 `Dio()` 就是裸的。
    /// ## 为什么测试要能传
    /// 否则替身收不到刷新请求（注入的 `dio` 是给**业务请求**用的）
    /// ⇒ 测试会**真的联网**（实测踩过：日志出现真实 400 响应）。
    Dio? bareDio,
  }) async {
    final at = await readAccess();
    if (at == null || at.isEmpty) return null;
    final rt = await readRefresh();
    final sync = TraktSync(
      clientId: clientId,
      accessToken: at,
      refreshToken: rt,
      onTokenRefreshed: (access, refresh) {
        // 不 await：回调签名是同步的；写失败不影响本次请求
        //（下次请求还会带新 access，存储落后一次可接受）
        unawaited(writeTokens(access, refresh));
      },
      // ★ 到期时刻也要存（否则下次无法判断"还剩多久"）
      onExpiresAt: (epochMs) => unawaited(writeExpiresAt(epochMs)),
      dio: dio,
      bareDio: bareDio,
    );

    // ---- ★ 提前刷新（快到期就现在刷）----
    try {
      final left = await expiresInMs();
      if (left != null && left < refreshLeadMs && left > 0) {
        debugPrint('[Trakt] token 还剩 ${left ~/ 3600000} 小时到期 '
            '⇒ 提前刷新（阈值 ${refreshLeadMs ~/ 3600000} 小时）');
        final ok = await sync.refresh();
        if (!ok) {
          // ⚠️ 失败**不阻断**：旧 token 可能还没过期，且 401 拦截器还会试
          debugPrint('[Trakt] 提前刷新失败（继续用旧 token）');
        }
      }
    } catch (e) {
      debugPrint('[Trakt] 提前刷新检查异常（忽略）: $e');
    }
    return sync;
  }

  /// 从 token 响应里算**到期时刻**并回调。
  ///
  /// ## 契约字段
  /// `created_at`（epoch 秒）+ `expires_in`（秒）
  /// ⇒ `expiresAt = (created_at + expires_in) * 1000`
  ///
  /// ## ⚠️ 防御式（我没实测过这两个字段的真实值）
  /// · 缺 `created_at` ⇒ 用 `now`
  /// · 缺 `expires_in` ⇒ 用官方文档的 **7 天**兜底
  ///   （官方："The `access_token` is valid for 7 days"）
  /// ⇒ **绝不**因为字段缺失就崩或算出负数。
  void _reportExpiry(Map m) {
    final cb = onExpiresAt;
    if (cb == null) return;
    final created = m['created_at'];
    final expiresIn = m['expires_in'];
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final base = created is num ? created.toInt() : nowSec;
    // 7 天 = 604800 秒（官方文档）
    final life = expiresIn is num ? expiresIn.toInt() : 604800;
    final at = (base + life) * 1000;
    cb(at);
    debugPrint('[Trakt] access token 到期：'
        '${DateTime.fromMillisecondsSinceEpoch(at)}（${life}s 后）');
  }

  /// `POST /oauth/revoke` —— **登出时吊销** access token。
  ///
  /// ## 为什么要有它（借鉴小幻影视的 `Create_TraktRevokeTokenRequest`）
  /// 只清本地存储的话，Trakt 服务端**仍认为该 token 有效**
  /// ⇒ 安全上不干净（token 若被截获仍可用）。
  /// 官方契约原文：
  /// > An `access_token` can be revoked when a user signs out of their
  /// > Trakt account in your app.
  ///
  /// ## ★ 实测（2026-10-14，用**假** token 探测）
  /// ```
  /// POST /oauth/revoke { token, client_id }   → 200  ✅ 契约形状
  /// POST /oauth/revoke { access_token, ... }  → 200  （服务端宽松）
  /// POST /oauth/revoke {}                     → 401 unauthorized_client
  ///                                              ← 证明服务端**确实在校验**
  /// ```
  /// 契约（`contracts/oauth/index.ts:180`）：
  /// ```
  /// summary: 'Revoke an access_token'
  /// path: '/revoke'  method: 'POST'
  /// body: { token*: string, client_id*: string }
  /// 200: z.undefined()
  /// ```
  ///
  /// ## 返回
  /// `true` = 服务端确认已吊销。**失败不影响本地登出**
  /// （本地必须清干净，不能因为网络问题把用户"锁"在登录态）。
  Future<bool> revoke() async {
    try {
      final r = await _dio.post<dynamic>(
        '$_apiBase/oauth/revoke',
        data: {'token': accessToken2, 'client_id': clientId},
        options: _opts,
      );
      final ok = r.statusCode == 200 || r.statusCode == 204;
      debugPrint('[Trakt] revoke HTTP ${r.statusCode} ⇒ ${ok ? "已吊销" : "未确认"}');
      return ok;
    } catch (e) {
      debugPrint('[Trakt] revoke 异常（本地仍会登出）: $e');
      return false;
    }
  }

  /// **裸 Dio**（不带拦截器）—— 只用于 `/oauth/token` 刷新，**防递归**。
  ///
  /// ## 为什么不能复用 `_dio`
  /// `_dio` 上装了"401 ⇒ 刷新 ⇒ 重放"的拦截器。
  /// 若刷新请求也走 `_dio`，而它又返回 401（refresh token 作废时就是）
  /// ⇒ 拦截器再调刷新 ⇒ **无限递归**。
  ///
  /// ## 为什么可能是 null
  /// 构造时没传 `bareDio` ⇒ 首次刷新时惰性创建（见 `_bareClient`）。
  Dio? _bare;

  /// 取裸 Dio（首次用时创建）。
  ///
  /// ⚠️ 必须用 `_newTraktDio()`（**带超时**）而不是裸 `Dio()` ——
  /// 否则 refresh 请求在网络不通时**永久挂起**，而它持有 `_refreshing` 锁
  /// ⇒ **后续所有请求都被它挡住**（整个客户端死锁）。
  Dio get _bareClient => _bare ??= _newTraktDio();

  Future<bool>? _refreshing;

  Future<bool> _refreshOnce() {
    // 已有刷新在跑 ⇒ 复用它（不新开）
    return _refreshing ??= refresh().whenComplete(() {
      _refreshing = null;
    });
  }

  final String clientId;

  /// **登录态等价物**（凭据）—— 只在内存与会话存储里流转，不入库。
  final String accessToken;

  /// refresh token（**一次性**：刷新成功后旧值立即失效）。
  String? refreshToken;

  /// 刷新成功回调（把新 token 写回安全存储）。
  void Function(String access, String? refresh)? onTokenRefreshed;

  /// **到期时刻回调**（epoch 毫秒）—— 借鉴小幻影视的
  /// `set_TraktExpiresTimestamp`。
  ///
  /// ## 为什么需要它
  /// 存了到期时刻才能"**提前**刷新"：不必等 401 才发现过期
  /// （那会多一次必然失败的请求 + 一条误导性的错误日志）。
  void Function(int epochMs)? onExpiresAt;

  /// `POST /oauth/token` —— 用 refresh token 换新的 access token。
  ///
  /// ## ★ 实测（2026-10-14，用**假** refresh_token 探测，不消耗真实凭据）
  /// ```
  /// A. 只 refresh_token + client_id
  ///    → 400 {"error":"invalid_request",
  ///           "error_description":"grant_type is required"}
  /// B. + grant_type                    ← ★ 本实现
  ///    → 400 {"error":"invalid_grant","error_description":"session not found"}
  /// C. + redirect_uri + grant_type（契约 schema 的全字段）
  ///    → 400 invalid_grant   ← 与 B 完全相同
  /// D. 同上 + client_secret 空串
  ///    → 400 invalid_grant   ← 与 B 完全相同
  /// E. **缺 client_id** → 400 invalid_grant   ← ⚠️ 服务端**不强制**它
  /// F. **缺 refresh_token** → 400 invalid_request
  ///    "Missing a required refresh_token for refresh_token grant"
  /// ```
  /// ⇒ 结论（**比契约更精确**）：
  /// · **必需**：`refresh_token` + `grant_type`
  ///   （F 与 A 两条对照证明服务端**确实在校验**，不是一律放过）
  /// · **非必需**：`redirect_uri` / `client_secret` / `client_id`
  ///   （C/D/E 的响应与 B **逐字相同**）
  ///
  /// ⚠️ 契约的 `tokenRefreshSchema` = `tokenBaseSchema.extend({...})` 声明了
  ///    `client_id + client_secret + redirect_uri + refresh_token + grant_type`
  ///    —— 但那是**客户端校验**用的 schema，服务端实际**更宽松**
  ///    ⇒ 以**实测**为准（§6.10 规则②"契约 ≠ 现实"）。
  ///
  /// ## 返回
  /// `true` = 刷新成功（且已回调写回存储）
  /// `false` = 失败（**不代表要登出** —— 只有 `invalid_grant` 才要）
  ///
  /// ## ⚠️ 单次使用语义（官方原文）
  /// > Refresh tokens are **single-use**. Every successful refresh returns a
  /// > new `access_token` and `refresh_token`. The refresh token used in the
  /// > request is **immediately invalidated**.
  /// ⇒ 成功后**必须**用响应里的新 refresh 替换旧的，否则下次刷新必失败。
  Future<bool> refresh() async {
    final rt = refreshToken;
    if (rt == null || rt.isEmpty) {
      debugPrint('[Trakt] 无 refresh token ⇒ 无法刷新');
      return false;
    }
    try {
      // ══════════════════════════════════════════════════════════════
      // ★ 用**裸 Dio**（不带拦截器）发刷新请求 —— 防递归
      // ══════════════════════════════════════════════════════════════
      //
      // ## 为什么（我第一版写的是 `_dio.post(...)`，**与自己上面的注释矛盾**）
      // 拦截器在 401 时会调 `_refreshOnce()` → `refresh()`
      // ⇒ 若 `refresh()` 又走 `_dio`，而 `/oauth/token` 也返回 401
      //   （refresh token 已作废时**正是**这个响应）
      // ⇒ **无限递归**。
      //
      // ## 为什么用惰性 `_bare ??= Dio()`
      // ① 独立实例 ⇒ 拦截器链不共享（递归路径不存在）
      // ② 惰性创建 ⇒ 不刷新时不额外占资源
      final r = await _bareClient.post<dynamic>(
        '$_apiBase/oauth/token',
        data: {
          'refresh_token': rt,
          'client_id': clientId,
          'grant_type': 'refresh_token',
        },
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'trakt-api-version': '2',
            'trakt-api-key': clientId,
          },
          validateStatus: (v) => v != null && v < 500,
        ),
      );
      if (r.statusCode != 200 || r.data is! Map) {
        // ⚠️ **保留响应体**（官方要求）—— 它是判断"要不要重新授权"的唯一依据
        debugPrint('[Trakt] 刷新失败 HTTP ${r.statusCode} body=${r.data}');
        return false;
      }
      final m = r.data as Map;
      final at = m['access_token'];
      if (at is! String || at.isEmpty) {
        debugPrint('[Trakt] 刷新响应缺 access_token: $m');
        return false;
      }
      // ★ 一次性：**必须**替换（官方明确要求）
      accessToken2 = at;
      final newRt = m['refresh_token'];
      if (newRt is String && newRt.isNotEmpty) refreshToken = newRt;
      onTokenRefreshed?.call(at, newRt is String ? newRt : null);
      // 算到期时刻（借鉴小幻影视的 set_TraktExpiresTimestamp）
      _reportExpiry(m);
      debugPrint('[Trakt] token 已刷新（refresh 是否更新：'
          '${newRt is String && newRt.isNotEmpty}）');
      return true;
    } catch (e) {
      debugPrint('[Trakt] 刷新异常（保留响应体以便判断）: $e');
      return false;
    }
  }

  /// 当前有效的 access token（刷新后会被替换）。
  ///
  /// ⚠️ `accessToken` 是 `final`（构造时注入），刷新后需要可变副本
  /// ⇒ 用本字段承载"最新值"，请求时读它。
  late String accessToken2 = accessToken;

  final Dio _dio;

  /// 统一请求头（契约 `_internal/builder.ts` 的 `authMetadata('required')`：
  /// 这三组端点都要求 OAuth，必须带 `Authorization: Bearer <token>`）。
  Options get _opts => Options(
        headers: {
          'Content-Type': 'application/json',
          'trakt-api-version': '2',
          'trakt-api-key': clientId,
          'Authorization': 'Bearer $accessToken2',
        },
        // ⚠️ 不抛 4xx —— scrobble 的 **409/422 是正常业务语义**
        //（409 = 刚 scrobble 过；422 = progress < 1% 被忽略）
        // ⇒ 让调用方按状态码分支，而不是当异常。
        validateStatus: (s) => s != null && s < 500,
        // ══════════════════════════════════════════════════════════════
        // 🔴 2026-10-15 修：**请求级也必须显式给超时**
        // ══════════════════════════════════════════════════════════════
        //
        // ## 真机证据（用户报障："还是没同步"）
        // 日志在 `⑥ map[1]=12688410 ⇒ 命中`（`resolveEpisode` 成功返回）
        // 之后**彻底静默** —— 等 30 秒也没有：
        // · 没有 scrobble 成功日志
        // · **没有** `catch (e)` 里那条 `[Trakt] 同步已看失败【...】`
        // · 也没有 `_snack`
        // ⇒ `await _dio.post(...)` **永不返回** —— `try/catch` 救不了它
        //   （超时抛的是 `DioException`，但**根本没抛**）。
        //
        // ## 为什么构造时的 `BaseOptions` 不够
        // `TraktSync` 的构造已改成 `_newTraktDio()`（带 `BaseOptions` 超时），
        // **但请求级 `Options` 没有显式给** ⇒ 实测在这条路径上
        // `sendTimeout`/`receiveTimeout` **未生效**（HTTP 请求无限等待）。
        // ⇒ **不依赖继承，逐请求写明**（与本文件 `startDeviceAuth` 的既有做法一致）。
        //
        // ⚠️ 这与本仓库 §5.5 是同一类问题：**"卡住"比"报错"更糟** ——
        //    报错至少用户知道发生了什么，"永远转圈"会让用户以为 App 死了。
        sendTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
      );

  /// `POST /scrobble/{action}`
  ///
  /// ## 返回
  /// `TraktScrobbleResult` —— **包含 HTTP 状态码**，因为 409/422 是业务语义：
  /// · `201` 成功（`action` 由服务端回显，可能与请求的**不同**：
  ///   `stop` 在 1%–79% 时会被服务端改成 `pause`）
  /// · `409` 同一 item 刚 scrobble 过（**不是错误**，忽略即可）
  /// · `422` progress < 1%（**不是错误**，忽略即可）
  Future<TraktScrobbleResult> scrobble({
    required TraktScrobbleAction action,
    required double progress,
    TraktIds? movieIds,
    TraktIds? episodeIds,
    String? movieTitle,
    int? movieYear,
  }) async {
    // 契约：`progress` 是 0–100 的 float（**不是** 0–1，也不是 0–1e9 tick）
    final body = <String, dynamic>{
      'progress': progress.clamp(0, 100),
    };
    if (episodeIds != null) {
      // ⚠️ 剧集只能 trakt/tvdb —— 调用方必须已解析出其中一个
      body['episode'] = {'ids': episodeIds.toJson(episodeMode: true)};
    } else if (movieIds != null) {
      body['movie'] = {
        if (movieTitle != null) 'title': movieTitle,
        if (movieYear != null) 'year': movieYear,
        'ids': movieIds.toJson(),
      };
    } else {
      return const TraktScrobbleResult(
        statusCode: 0,
        error: 'scrobble 需要 movieIds 或 episodeIds',
      );
    }

    try {
      final r = await _dio.post<dynamic>(
        '$_apiBase/scrobble/${action.path}',
        data: body,
        options: _opts,
      );
      final code = r.statusCode ?? 0;
      // 201 = 成功；服务端会回显**实际** action（stop 可能被降级为 pause）
      String? actual;
      if (r.data is Map) {
        final a = (r.data as Map)['action'];
        if (a is String) actual = a;
      }
      return TraktScrobbleResult(
        statusCode: code,
        // 409（重复）/ 422（progress<1%）是**预期内的业务分支**，不算失败
        ok: code == 201,
        serverAction: actual,
        duplicate: code == 409,
        tooShort: code == 422,
      );
    } catch (e) {
      // 网络异常**不算"同步失败"**（§6.9.1：取数失败 ≠ 数据为空）
      return TraktScrobbleResult(statusCode: 0, error: e.toString());
    }
  }

  /// **某剧的播放历史**（`GET /sync/history/shows/:id`）—— 返回已看集集合。
  ///
  /// ## ★ 为什么必须用它（2026-10-15 用户报障的根因）
  /// 我原来用 `GET /sync/watched/shows`（**已看完**），而 Trakt 有**两套数据**：
  /// | 概念 | 端点 | 写入条件 |
  /// |---|---|---|
  /// | **history** | `GET /sync/history/:type/:id` | **任何播放**（含看一半）|
  /// | watched | `GET /sync/watched/:type` | 仅 `progress > 80%` |
  ///
  /// 用户原话："我**观看了一部分**点击同步后没有实现"
  /// ⇒ 看一半 ⇒ **只进 history** ⇒ 查 watched **必然查不到**
  ///   （日志实证：`[TraktPull] ... 没有已看记录`，而网页历史里明明有）。
  ///
  /// ## 契约（`contracts/sync/index.ts:217-231`）
  /// ```
  /// history: { path: '/:type/:id', pathPrefix: '/history' }
  /// ⇒ GET /sync/history/shows/{traktShowId}
  /// response: syncHistoryItemResponseSchema[] = {id, watched_at, action, type}
  ///           .passthrough()   ← ★ 所以还能取到 episode/show 子对象
  /// ```
  /// ⚠️ **必须带剧的 trakt id**（与 `/watched/shows` 不同 —— 那个是全量）。
  ///
  /// ## 返回
  /// `Set<'S{season}E{number}'>`；**null = 取数失败**（调用方据此区分"空"与"失败"）。
  Future<Set<String>?> getShowHistory(int traktShowId) async {
    try {
      final r = await _dio.get<dynamic>(
        '$_apiBase/sync/history/shows/$traktShowId',
        // 契约里 history 支持分页；显式 limit 保证拿到足够多
        queryParameters: {'limit': 500},
        options: _opts,
      );
      if (r.statusCode != 200 || r.data is! List) {
        debugPrint('[Trakt] /sync/history/shows HTTP ${r.statusCode}');
        return null;   // ★ 失败返回 null
      }
      final out = <String>{};
      for (final e in (r.data as List)) {
        if (e is! Map) continue;
        // ⚠️ 防御式解析：契约只保证 {id, watched_at, action, type}，
        //    季/集在 `episode` 子对象里（`.passthrough()` 才带出来）
        final ep = e['episode'];
        if (ep is! Map) continue;
        final sn = ep['season'];
        final no = ep['number'];
        if (sn is num && no is num) out.add('S${sn.toInt()}E${no.toInt()}');
      }
      debugPrint('[Trakt] /sync/history/shows/$traktShowId → '
          '${out.length} 集（共 ${(r.data as List).length} 条记录）');
      return out;
    } catch (e) {
      debugPrint('[Trakt] /sync/history/shows 异常: $e');
      return null;
    }
  }

  /// **已看的电影**（`GET /sync/watched/movies`）。
  ///
  /// ## 为什么需要（2026-10-15 用户报障的根因）
  /// 我原来只实现了 `getWatchedShows()`（剧集）——
  /// 而**电影的端点不同**（`/watched/movies` vs `/watched/shows`）。
  /// 用户点《生化危机爆发夜》（**电影**）的同步 ⇒ 代码却去调
  /// `getSeasons(电影id)` ⇒ `/Shows/{电影id}/Seasons` ⇒ **404**。
  ///
  /// ## 契约（`contracts/sync/index.ts:677`）
  /// ```
  /// watched: { summary: 'Get watched', path: '/watched/:type' }
  ///   type ∈ {movies, shows, seasons, episodes}
  /// ⇒ /sync/watched/movies
  /// 返回 syncWatchedItemResponseSchema[]: { plays?, last_watched_at?, type? } & ...
  /// ```
  /// ⚠️ 返回项里含 `movie.ids.tmdb` ⇒ 可用来判断"某部电影是否已看"。
  ///
  /// ## 返回
  /// `tmdbId 集合`（**空集合 ≠ 失败**：可能真的一部都没看）。
  /// **失败时返回 null**（调用方据此区分"取数失败"与"数据为空" —— §6.9.1）。
  Future<Set<int>?> getWatchedMovies() async {
    try {
      final r = await _dio.get<dynamic>(
        '$_apiBase/sync/watched/movies',
        options: _opts,
      );
      if (r.statusCode != 200 || r.data is! List) {
        debugPrint('[Trakt] /sync/watched/movies HTTP ${r.statusCode}');
        return null;   // ★ 失败返回 null（不是空集合）
      }
      final out = <int>{};
      for (final e in (r.data as List)) {
        if (e is! Map) continue;
        final mv = e['movie'];
        if (mv is! Map) continue;
        final ids = mv['ids'];
        if (ids is! Map) continue;
        final t = ids['tmdb'];
        if (t is num) out.add(t.toInt());
      }
      debugPrint('[Trakt] /sync/watched/movies → ${out.length} 部');
      return out;
    } catch (e) {
      debugPrint('[Trakt] /sync/watched/movies 异常: $e');
      return null;
    }
  }

  /// **把电影加进已看**（`POST /sync/history` body `{movies:[{ids}]}`）。
  ///
  /// ## 契约（`contracts/sync/index.ts:233`）
  /// ```
  /// summary: 'Add items to watched history'
  /// body: { movies?, shows?, seasons?, episodes? }
  /// 200: { added:{movies,episodes}, updated:{...}, not_found:{...} }
  /// ```
  /// ⚠️ `movieIdsRequestSchema` **支持 tmdb**（与 episode 不同！）
  /// ⇒ 电影可以直接用 tmdb，不需要 trakt id。
  ///
  /// ## 返回
  /// `TraktHistoryResult`（含 `added` 计数，供 UI 如实报告）。
  Future<TraktHistoryResult> addMoviesToHistory(List<TraktIds> movies) async {
    try {
      final r = await _dio.post<dynamic>(
        '$_apiBase/sync/history',
        data: {'movies': [for (final m in movies) {'ids': m.toJson()}]},
        options: _opts,
      );
      final ok = r.statusCode == 200 || r.statusCode == 201;
      var added = 0;
      if (ok && r.data is Map) {
        final a = (r.data as Map)['added'];
        if (a is Map && a['movies'] is num) added = (a['movies'] as num).toInt();
      }
      debugPrint('[Trakt] /sync/history(movies) HTTP ${r.statusCode} '
          'added=$added');
      return TraktHistoryResult(
          statusCode: r.statusCode ?? 0, ok: ok, added: added);
    } catch (e) {
      debugPrint('[Trakt] /sync/history(movies) 异常: $e');
      return const TraktHistoryResult(statusCode: 0, ok: false, added: 0);
    }
  }

  /// `GET /users/me` —— **当前登录用户**（授权成功后显示用户名/头像）。
  ///
  /// ## 契约（`contracts/users/index.ts`）
  /// ```
  /// summary: 'Get user profile'   path: '/me'   method: 'GET'
  /// 返回: { username, name?, private, vip, ids:{slug,...}, images:{avatar:{full}} }
  /// ```
  /// ⚠️ 实测**需 OAuth**（无 token → 401）⇒ 只在已登录时调用。
  ///
  /// ## 为什么授权后必须调它（用户要求）
  /// > 这个授权成功后，显示我的 trakt 名字哇
  /// 只显示"已连接"是不够的 —— 用户要能确认**连的是哪个账号**
  ///（多账号场景下尤其重要：连错了要能立刻看出来）。
  Future<TraktUser?> getMe() async {
    try {
      final r = await _dio.get<dynamic>('$_apiBase/users/me', options: _opts);
      if (r.statusCode != 200 || r.data is! Map) {
        debugPrint('[Trakt] /users/me HTTP ${r.statusCode}');
        return null;
      }
      return TraktUser.fromJson(r.data as Map);
    } catch (e) {
      // 取用户信息失败**不影响登录状态**（token 已存了）
      debugPrint('[Trakt] /users/me 异常: $e');
      return null;
    }
  }

  /// `GET /sync/playback` —— 取**暂停中的播放进度**（「续播检查」用）。
  ///
  /// ## 返回
  /// 列表（可能为空）；每项的 `type` 判别是 movie 还是 episode。
  /// ## 为什么不用 `/sync/playback/{id}`
  /// 那个要 trakt id；我们手里是 tmdb ⇒ 拉全量再本地匹配更稳。
  /// 注意：Trakt 对 playback 列表有**默认条数限制**（官方文档提到分页），
  /// 这里显式要 `limit=100`（足够覆盖个人使用）。
  Future<List<TraktPlaybackItem>> getPlayback({int limit = 100}) async {
    try {
      final r = await _dio.get<dynamic>(
        '$_apiBase/sync/playback?limit=$limit',
        options: _opts,
      );
      if (r.statusCode != 200 || r.data is! List) {
        debugPrint('[Trakt] /sync/playback HTTP ${r.statusCode}');
        return const [];
      }
      final out = <TraktPlaybackItem>[];
      for (final e in (r.data as List)) {
        if (e is! Map) continue;
        final it = TraktPlaybackItem.fromJson(e);
        if (it != null) out.add(it);
      }
      return out;
    } catch (e) {
      debugPrint('[Trakt] /sync/playback 异常: $e');
      return const [];
    }
  }

  /// `GET /sync/watched/shows` —— 已看过的剧（「同步已看状态」用）。
  ///
  /// ## 返回形状（契约）
  /// `[{ show: {...}, seasons: [{ number, episodes: [{number, ...}] }] }]`
  /// ⇒ 解析成 `traktShowId → 已看集集合`，便于与本地比对。
  Future<Map<int, Set<String>>> getWatchedShows() async {
    try {
      final r = await _dio.get<dynamic>(
        '$_apiBase/sync/watched/shows',
        options: _opts,
      );
      if (r.statusCode != 200 || r.data is! List) {
        debugPrint('[Trakt] /sync/watched/shows HTTP ${r.statusCode}');
        return const {};
      }
      final out = <int, Set<String>>{};
      for (final e in (r.data as List)) {
        if (e is! Map) continue;
        final show = e['show'];
        if (show is! Map) continue;
        final ids = show['ids'];
        if (ids is! Map) continue;
        final tid = ids['trakt'];
        if (tid is! int) continue;
        final set = <String>{};
        final seasons = e['seasons'];
        if (seasons is List) {
          for (final sn in seasons) {
            if (sn is! Map) continue;
            final num_ = sn['number'];
            final eps = sn['episodes'];
            if (num_ is! int || eps is! List) continue;
            for (final ep in eps) {
              if (ep is! Map) continue;
              final en = ep['number'];
              if (en is int) set.add('$num_-$en');   // 「季-集」复合键
            }
          }
        }
        out[tid] = set;
      }
      return out;
    } catch (e) {
      debugPrint('[Trakt] /sync/watched/shows 异常: $e');
      return const {};
    }
  }

  /// `POST /sync/history` —— 把"已看"写进 Trakt。
  ///
  /// ## 为什么用 episodes（而不是 shows+seasons）
  /// 粒度最细、语义最准（我们本来就知道看完了哪一集）。
  /// ## ⚠️ 只能传 trakt/tvdb id（见文件顶部的约束说明）
  Future<TraktHistoryResult> addEpisodesToHistory(
      List<TraktIds> episodeIds) async {
    if (episodeIds.isEmpty) {
      return const TraktHistoryResult(ok: true, added: 0);
    }
    try {
      final r = await _dio.post<dynamic>(
        '$_apiBase/sync/history',
        data: {
          'episodes': [
            for (final id in episodeIds)
              {'ids': id.toJson(episodeMode: true)},
          ],
        },
        options: _opts,
      );
      final code = r.statusCode ?? 0;
      var added = 0;
      if (r.data is Map) {
        final a = (r.data as Map)['added'];
        if (a is Map && a['episodes'] is int) added = a['episodes'] as int;
      }
      return TraktHistoryResult(ok: code == 200 || code == 201, added: added,
          statusCode: code);
    } catch (e) {
      return TraktHistoryResult(ok: false, statusCode: 0, error: e.toString());
    }
  }

  static const _apiBase = 'https://api.trakt.tv';
}

/// Trakt 的 id 集合（契约 `_internal/request/idsRequestSchema.ts`）。
///
/// ## ★ 为什么要区分 `episodeMode`
/// ```ts
/// episodeIdsRequestSchema = union([{ trakt }, { tvdb }])   ← **无 tmdb**
/// showIdsRequestSchema    = union([{trakt},{slug},{imdb},{tmdb},{tvdb}])
/// ```
/// ⇒ 同一个类在"剧集模式"下必须**丢掉 tmdb**，否则服务端 400/422。
///   用参数而不是两个类：字段完全一样，只是发出去时筛一遍。
class TraktIds {
  const TraktIds({this.trakt, this.tmdb, this.tvdb, this.imdb, this.slug});

  final int? trakt;
  final int? tmdb;
  final int? tvdb;
  final String? imdb;
  final String? slug;

  /// 是否能用于**剧集级**操作（只需 trakt 或 tvdb 之一）。
  bool get usableForEpisode => trakt != null || tvdb != null;

  /// 序列化。`episodeMode = true` 时**只留 trakt/tvdb**（契约要求）。
  Map<String, dynamic> toJson({bool episodeMode = false}) => {
        if (trakt != null) 'trakt': trakt,
        if (!episodeMode && tmdb != null) 'tmdb': tmdb,
        if (tvdb != null) 'tvdb': tvdb,
        if (!episodeMode && imdb != null) 'imdb': imdb,
        if (!episodeMode && slug != null) 'slug': slug,
      };

  @override
  String toString() =>
      'TraktIds(trakt=$trakt, tmdb=$tmdb, tvdb=$tvdb, usableEp=$usableForEpisode)';
}

/// `POST /scrobble/*` 的结果。
///
/// ## 为什么要把 409/422 做成**字段**而不是异常
/// 契约里写明它们是**业务语义**：
/// · `409` 同一 item 刚 scrobble 过（防重复）—— 重播同一集时**必然出现**
/// · `422` progress < 1% 被忽略 —— 刚点开就退出时**必然出现**
/// ⇒ 当异常处理会让日志充满假错误，也会让用户看到无意义的报错。
class TraktScrobbleResult {
  const TraktScrobbleResult({
    required this.statusCode,
    this.ok = false,
    this.serverAction,
    this.duplicate = false,
    this.tooShort = false,
    this.error,
  });

  final int statusCode;
  final bool ok;

  /// 服务端**实际**执行的动作。⚠️ 与请求的可能不同：
  /// 请求 `stop` 但进度 1%–79% 时，服务端会降级为 `pause`。
  final String? serverAction;

  /// `409` —— 刚 scrobble 过（不是错误）。
  final bool duplicate;

  /// `422` —— progress < 1%，被服务端忽略（不是错误）。
  final bool tooShort;

  final String? error;

  @override
  String toString() => 'TraktScrobbleResult(code=$statusCode, ok=$ok, '
      'server=$serverAction, dup=$duplicate, short=$tooShort, err=$error)';
}

/// Trakt 用户资料（`GET /users/me`）。
///
/// ## 为什么字段都可空
/// 契约里只有 `username` / `private` / `vip` / `ids` 是必填，
/// `name` / `images` 可选（用户没设真名/头像时就不返回）。
/// ⇒ **不要**对可选字段做非空断言（§5.3）。
class TraktUser {
  const TraktUser({
    required this.username,
    this.name,
    this.avatarUrl,
    this.isVip = false,
  });

  /// 登录名（**唯一必然存在**的标识）—— UI 显示 `@username`。
  final String username;

  /// 真名（用户可能没填）。
  final String? name;

  /// 头像地址（用户可能没设）。
  final String? avatarUrl;

  final bool isVip;

  /// UI 显示用的一行文字：有真名就"真名（@login）"，否则只有 @login。
  String get display => (name != null && name!.isNotEmpty)
      ? '$name（@$username）'
      : '@$username';

  static TraktUser? fromJson(Map m) {
    final u = m['username'];
    if (u is! String || u.isEmpty) return null;   // 没用户名 ⇒ 无法显示
    final img = m['images'] is Map ? m['images'] as Map : const {};
    final av = img['avatar'] is Map ? img['avatar'] as Map : const {};
    final full = av['full'];
    return TraktUser(
      username: u,
      name: m['name'] is String ? m['name'] as String : null,
      avatarUrl: full is String && full.isNotEmpty ? full : null,
      isVip: m['vip'] == true,
    );
  }

  @override
  String toString() => 'TraktUser($username)';
}

/// `GET /sync/playback` 的一项（续播进度）。
class TraktPlaybackItem {
  const TraktPlaybackItem({
    required this.progress,
    required this.pausedAt,
    required this.type,
    this.traktShowId,
    this.traktEpisodeId,
    this.season,
    this.number,
    this.title,
    this.tmdbShowId,
  });

  /// **0–100 的百分比**（契约 `float(z.number().min(0).max(100))`）。
  final double progress;

  /// ISO8601（暂停时刻）。
  final String pausedAt;

  /// `'movie'` 或 `'episode'`。
  final String type;

  final int? traktShowId;
  final int? traktEpisodeId;
  final int? season;
  final int? number;
  final String? title;

  /// 剧集模式可空（契约里 episode ids **没有 tmdb**）。
  final int? tmdbShowId;

  /// 从契约形状解析（**防御式**：字段可能缺）。
  static TraktPlaybackItem? fromJson(Map m) {
    final p = m['progress'];
    if (p is! num) return null;
    final t = m['type'];
    final show = m['show'] is Map ? m['show'] as Map : const {};
    final ep = m['episode'] is Map ? m['episode'] as Map : const {};
    final showIds = show['ids'] is Map ? show['ids'] as Map : const {};
    int? gi(dynamic v) => v is int ? v : (v is num ? v.toInt() : null);
    return TraktPlaybackItem(
      progress: p.toDouble(),
      pausedAt: m['paused_at'] is String ? m['paused_at'] as String : '',
      type: t is String ? t : 'episode',
      traktShowId: gi(showIds['trakt']),
      traktEpisodeId: gi(ep['ids'] is Map ? (ep['ids'] as Map)['trakt'] : null),
      season: gi(ep['season']),
      number: gi(ep['number']),
      title: ep['title'] is String ? ep['title'] as String : null,
      tmdbShowId: gi(showIds['tmdb']),
    );
  }

  @override
  String toString() => 'TraktPlayback($type S$season E$number '
      '${progress.toStringAsFixed(1)}% paused=$pausedAt)';
}

/// `POST /sync/history` 的结果。
class TraktHistoryResult {
  const TraktHistoryResult({
    required this.ok,
    this.added = 0,
    this.statusCode = 0,
    this.error,
  });

  final bool ok;
  final int added;
  final int statusCode;
  final String? error;

  @override
  String toString() =>
      'TraktHistoryResult(ok=$ok, added=$added, code=$statusCode, err=$error)';
}

abstract interface class TraktCache {
  Future<String?> get(String key);
  Future<void> put(String key, String value, {required Duration ttl});
}

// ══════════════════════════════════════════════════════════════════
//  设备码登录（OAuth 2.0 Device Authorization Grant）
// ══════════════════════════════════════════════════════════════════

/// 一次「设备码授权」会话（用户要输的那个码 + 轮询所需的一切）。
class TraktDeviceSession {
  const TraktDeviceSession({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUrl,
    required this.expiresAtMs,
    required this.intervalSec,
  });

  /// 轮询用的**临时凭据**（**敏感**：不入库、不打日志、用完即弃）。
  final String deviceCode;

  /// 展示给用户的短码（如 `KY5QEMVZ`）—— 用户在浏览器里输它。
  final String userCode;

  /// 用户要打开的网址（实测：`https://auth.trakt.tv/activate`）。
  final String verificationUrl;

  /// 过期时刻（毫秒时间戳）。实测 `expires_in = 600`（10 分钟）。
  final int expiresAtMs;

  /// 轮询间隔（秒）。实测 `interval = 6`。
  final int intervalSec;

  bool get isExpired => DateTime.now().millisecondsSinceEpoch >= expiresAtMs;

  /// 剩余秒数（给 UI 显示倒计时）。
  int get remainingSec {
    final left = (expiresAtMs - DateTime.now().millisecondsSinceEpoch) ~/ 1000;
    return left < 0 ? 0 : left;
  }

  @override
  String toString() =>
      'TraktDeviceSession(code=$userCode, url=$verificationUrl, '
      'interval=${intervalSec}s, expired=$isExpired)';
}

/// **一次轮询的结果**（App 据此决定"继续等 / 重来 / 成功 / 报错"）。
enum TraktAuthState {
  /// HTTP 400 —— **还在等用户在浏览器里确认**（实测：body 为空，只能靠状态码）。
  waiting,

  /// HTTP 404 —— 设备码**无效或已过期**（实测与"等待"的码不同）。
  expired,

  /// HTTP 200 —— 授权成功，token 已拿到。
  success,

  /// HTTP 429 —— 轮询太快（应退避）。
  slowDown,

  /// 其它（网络失败 / 服务端异常）—— **可重试**，不代表授权失败。
  error,
}

/// 一次轮询的完整结果。
class TraktTokenResult {
  const TraktTokenResult({
    required this.state,
    this.accessToken,
    this.refreshToken,
    this.expiresInSec,
    this.scope,
    this.message,
  });

  final TraktAuthState state;

  /// 访问令牌（**凭据** —— 只进 secure_storage）。
  final String? accessToken;

  /// 刷新令牌（**凭据**）。
  ///
  /// ⚠️ **单次使用**（官方文档）—— 每次刷新都会换发新的，旧的**立即失效**
  /// ⇒ 刷新成功后必须用响应里的新值覆盖存储。
  ///
  /// ✅ **本仓库已实现自动刷新**（2026-10-15 更正本条 ——
  /// 原文写"尚未实现"，实现后**没回头改**，属过时信息，会误导后人）：
  /// · `TraktSync.refresh()` → `POST /oauth/token`
  ///   body `{refresh_token, client_id, grant_type}` —— **实测**这三个足够
  ///   （`redirect_uri`/`client_secret` 服务端不强制，见 `refresh()` 的实测表）
  /// · 触发有**两条**路径：
  ///   ① **提前刷新**：`fromStore` 里剩余寿命 < 1 天 ⇒ 主动刷
  ///      （依据 `SessionStore.saveTraktExpiresAt` 存的 `expires_at`）
  ///   ② **401 自愈**：拦截器 —— ⚠️ `onResponse` **和** `onError` **都要挂**：
  ///      `validateStatus < 500` 让 401 走"成功"路径，
  ///      只挂 `onError` 时刷新**一行都不执行**（实测踩过，见构造器注释）
  /// · 失败形态 `400` + `{"error":"invalid_grant"}` ⇒ 需用户重新授权
  final String? refreshToken;

  /// 有效期（秒）。官方形状是 90 天（`7776000`），但**未本机实测**。
  final int? expiresInSec;

  /// 授权范围（官方形状是 `public`）。
  final String? scope;

  /// 失败原因（中文，可直接展示）。
  final String? message;

  bool get hasToken =>
      accessToken != null && accessToken!.isNotEmpty;
}
