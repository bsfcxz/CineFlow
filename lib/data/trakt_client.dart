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
  /// ## 判据（宽松但有效）
  /// · 中文名与 Trakt 英文名通常**无法直接比**
  /// · 所以退化为：**年份匹配** + **任一侧包含对方的拉丁片段**
  /// · 都不满足 ⇒ false（调用方**不采信**）
  ///
  /// ⚠️ 这是**尽力而为**的校验：它会把部分真命中判为 false（保守方向正确 ——
  ///    宁可不用 Trakt 的数据，也不要盖错）。
  bool plausiblyMatches({String? cnTitle, int? expectYear}) {
    // 年份能对上：强信号
    if (expectYear != null && year != null && expectYear == year) return true;
    // 标题有共同的拉丁片段（≥3 字符）
    final a = title.toLowerCase();
    final b = (cnTitle ?? '').toLowerCase();
    if (a.isEmpty || b.isEmpty) return false;
    for (var i = 0; i + 3 <= b.length; i++) {
      final seg = b.substring(i, i + 3);
      // 只比拉丁片段（中文片段在英文标题里不会出现）
      if (RegExp(r'^[a-z0-9]{3}$').hasMatch(seg) && a.contains(seg)) return true;
    }
    return false;
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
class TraktClient {
  TraktClient({
    required this.clientId,
    Dio? dio,
    this.cache,
  })  : _dio = dio ?? Dio(),
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
