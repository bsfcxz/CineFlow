/// 弹弹play 开放弹幕网络的 Dart 客户端（**直连官方，不自建**）。
///
/// ## 为什么不自建
///
/// 用户明确要求不自建服务。而官方文档给出了客户端项目的正解
/// （<https://doc.dandanplay.com/open/> 第 7 节「安全注意事项」原文）：
///
/// > 尽量不在客户端应用中硬编码您的 AppSecret
/// > 如果您正在开发**开源的客户端**，可以选择：
/// > 在开源代码中使用**占位符**，之后在构建时从机密中读取 AppSecret 后替换
///
/// 所以本实现**不含任何凭据**：AppId/AppSecret 由用户在「我的 → 弹幕设置」里
/// 填写，存 `flutter_secure_storage`（与 Emby 凭据同一套机制）。
/// 这样既满足官方要求，也满足本仓库的安全红线（凭据一律不入库）。
///
/// ## 官方硬约束（逐条影响实现）
///
/// 1. **必须带签名头**：`X-AppId` / `X-Timestamp` / `X-Signature`
///    （算法见 `danmaku_sign.dart`）。缺头 → 403 `Missing Authentication Headers`。
/// 2. **时间戳偏差过大会 403**（`Invalid Timestamp`）→ 必须用设备真实 UTC 时间。
/// 3. **业务错误可能包在 200 里**：`{"success":false,"errorCode":1,"errorMessage":"…"}`。
///    只看 HTTP 状态码会把业务失败当成成功（返回空弹幕且不报错）。
/// 4. **调用方应自行缓存**（官方第 10 节：弹幕/搜索建议缓存 2–6 小时）。
///    本项目用 drift 缓存（与豆瓣缓存同一张表）。
/// 5. **禁止批量抓取**：只按用户实际播放的条目请求，不做预取。
library;

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../data/platform_episodes.dart';
import '../data/db/app_database.dart';
import 'danmaku_async.dart';
import 'danmaku_config.dart';
import 'danmaku_models.dart';
import 'danmaku_sign.dart';

class DanmakuClient {
  /// 用配置构造（推荐）。
  ///
  /// 支持两种认证形态（见 `danmaku_config.dart` 的说明）：
  ///   - 官方：base 固定 + 请求头签名（AppId/AppSecret）
  ///   - 自建：base 里含 token 路径段 + **不带任何签名头**
  factory DanmakuClient.fromConfig(DanmakuConfig config, {Dio? dio}) =>
      DanmakuClient(
        kind: config.kind,
        baseUrl: switch (config.kind) {
          // 官方与公共代理都用**内置地址**（用户不需要填）
          DanmakuProviderKind.official => kOfficialBase,
          DanmakuProviderKind.publicProxy => kPublicProxyBase,
          // 自建服务才用用户填的地址
          _ => config.normalizedBase,
        },
        appId: config.appId,
        appSecret: config.appSecret,
        useAsync: config.useAsync,
        // 简繁转换交给服务端（chConvert），不做本地映射表
        chConvertCode: config.chConvert.code,
        dio: dio,
      );

  DanmakuClient({
    required this.kind,
    required this.baseUrl,
    this.appId = '',
    this.appSecret = '',
    this.useAsync = true,
    this.chConvertCode = 1,
    Dio? dio,
  }) : _dio = dio ?? Dio();

  /// 官方服务器地址（文档第 2 节）。自建服务用配置里的地址。
  static const kOfficialBase = 'https://api.dandanplay.net';

  /// **内置公共代理地址**（用户要求"直接内置"）。
  ///
  /// ## 实测确认（2026-10-10）
  /// · `GET /api/v2/comment/{id}` → 200，标准 `{count,comments:[{p,m}]}`
  /// · `GET /api/v2/search/anime?keyword=` → 200，`{animes:[{animeId,…}]}`
  /// · `GET /api/v2/bangumi/{animeId}` → 200，含 `episodes[]`
  /// · `GET /api/v2/search/episodes` → **404**（与官方的关键差异！）
  ///
  /// ## 为什么内置它
  /// 官方强制签名 ⇒ 普通用户拿不到凭据 ⇒ "弹幕装了用不了"。
  /// 公共代理免注册直接可用，是**默认**选项。
  ///
  /// ⚠️ 第三方免费实例，可能限流/变更/停服 ⇒ 保留另两条路作为退路。
  static const kPublicProxyBase = 'https://danmaku-api.152468.xyz';

  /// 弹幕缓存 TTL。官方建议 2–6 小时（第 10 节「缓存建议」）。
  static const cacheTtl = Duration(hours: 6);

  final DanmakuProviderKind kind;
  final String baseUrl;
  final String appId;
  final String appSecret;

  /// 是否用异步生成（`?async=1`）。只有 misaka_danmu_server 2.7.0+ 支持；
  /// 其它服务会**静默忽略**这个参数（调研确认 danmu_api 就是如此），
  /// 所以打开它不会让不支持的服务出错。
  final bool useAsync;

  /// 简繁转换（服务端 chConvert）。语义见 DanmakuChConvert。
  ///
  /// 必须进缓存 key —— 否则切了简繁读到的仍是旧缓存，
  /// 用户会以为"开关没生效"。
  final int chConvertCode;

  final Dio _dio;

  /// 可选缓存（有 drift 数据库时启用；测试时可省略）
  AppDatabase? cache;

  bool get _isOfficial => kind == DanmakuProviderKind.official;

  /// 拉取某剧集 id 的弹幕。
  ///
  /// [withRelated] 对应官方 `?withRelated=true`：整合第三方弹幕源。
  /// **注意**：自建服务（danmu_api）会忽略这个参数（调研确认是死参数），
  /// 传了也无害。
  Future<DanmakuBatch> comments(
    int episodeId, {
    bool withRelated = true,
    int? chConvert,
  }) async {
    // 默认用构造时传入的档（= 用户设置）；显式传参可覆盖（测试用）
    final cv = chConvert ?? chConvertCode;
    final path = '/api/v2/comment/$episodeId';
    final cacheKey =
        'danmaku:comment:$episodeId:$withRelated:$cv:${baseUrl.hashCode}';

    // 1) 先查缓存（官方要求缓存；也避免触发自建服务的限流）
    final cached = await cache?.cacheGet(cacheKey);
    if (cached != null) {
      final parsed = _decodeComments(cached, episodeId);
      if (parsed != null) {
        // ★ 诊断（弹幕简繁排查用）：命中缓存时也要能看出"这份数据是哪档"
        debugPrint('[Danmaku] 命中缓存（chConvert=$cv）：'
            '${parsed.items.length} 条，首条«'
            '${parsed.items.isNotEmpty ? parsed.items.first.text : ""}»');
        return parsed;
      }
    }

    // ★★ `async` 参数必须**按源类型**决定发不发（真机 + 实测定位）
    //
    // ## 原来的写法错在哪
    // 无条件按配置发 `if (useAsync) 'async': '1'`，并注释说
    // "其它服务会**静默忽略**这个参数" —— 那是基于 **danmu_api** 的调研。
    // **公共代理不适用**：它严格校验参数白名单，
    // 任何 `async` 值都会 400。实测（2026-10-10）：
    // ```
    // ?async=1  → HTTP 400 {"success":false,
    //                       "errorMessage":"Invalid query parameters"}
    // ?async=0  → HTTP 400（同样）
    // ?withRelated=true&chConvert=1        → 200 ✅
    // ?withRelated=true&chConvert=1&async=1 → 400 ❌（App 的实际请求）
    // ```
    // ⇒ 真机现象：`[PlayerFlow] 弹幕：弹幕服务返回 HTTP 400`
    //   （弹幕永远出不来，但不影响播放）
    //
    // ## 修法：白名单
    // · 公共代理：**永不发** `async`
    // · 官方 / 自建：保留 `useAsync`（misaka 2.7.0+ 才认，其他源忽略）
    final query = {
      'withRelated': '$withRelated',
      'chConvert': '$cv',
      if (useAsync && kind != DanmakuProviderKind.publicProxy) 'async': '1',
    };

    // ★★ 诊断（弹幕简繁排查用）——把"到底发了哪一档"钉死
    //
    // ## 为什么要这条（用户两次报"弹幕还是繁体"）
    // 已实测服务端 chConvert **确实有效**：
    // ```
    // chConvert=0（不转换）: 繁体特征 2   / 简体特征 207
    // chConvert=1（转简体）: 繁体特征 0   / 简体特征 209
    // chConvert=2（转繁体）: 繁体特征 209 / 简体特征 0
    // ```
    // ⇒ 问题在客户端某一环。这条日志同时暴露：
    //   ① 本次 `chConvert` 的值（看是不是意外成了 0/2）
    //   ② 请求路径与是否命中缓存
    //   ③ 拿到后**首条弹幕原文** —— 用字形直接判断简繁，不用再猜
    //
    // ⚠️ 只打 chConvert 值，**不打 api_key/完整 URL**（安全红线）。
    debugPrint('[Danmaku] 请求 comment/$episodeId：chConvert=$cv'
        '（来源=${chConvert != null ? "显式参数" : "配置"}），'
        'withRelated=$withRelated，kind=${kind.name}');

    // 2) 首次请求（异步模式下可能返回 pending）
    final raw = await _get(path, query: query);

    final map = _tryMap(raw);
    if (map == null) throw const DanmakuException('弹幕数据格式异常');

    final first = decideFirstResponse(
      commentCount: (map['count'] as num?)?.toInt() ?? 0,
      status: map['status'] as String?,
      taskId: map['taskId'] as String?,
      description: map['description'] as String?,
      progress: (map['progress'] as num?)?.toInt(),
    );

    // 3) 同步就拿到了（服务端 30 秒内完成）——最常见路径
    if (first.phase == PollPhase.immediate) {
      await cache?.cachePut(cacheKey, raw, ttl: cacheTtl);
      final parsed = _decodeComments(raw, episodeId);
      if (parsed == null) throw const DanmakuException('弹幕数据格式异常');
      return parsed;
    }

    if (first.phase == PollPhase.failed) {
      throw DanmakuException(first.description ?? '服务端生成弹幕失败');
    }

    // 4) 需要轮询：等生成完成后**再取一次普通接口**
    final decision = await _poll(first.taskId!);
    if (decision.phase != PollPhase.ready) {
      throw DanmakuException(decision.description ?? '弹幕生成未完成');
    }
    return comments(episodeId,
        withRelated: withRelated, chConvert: chConvert);
  }

  /// 轮询任务状态直到终态。
  ///
  /// 时序按配置：1.5 秒间隔、总上限 5 分钟（超时按失败处理）。
  Future<PollDecision> _poll(String taskId) async {
    const config = PollConfig();
    final started = DateTime.now();
    var last = const PollDecision(PollPhase.waiting, taskId: '');

    while (true) {
      await Future<void>.delayed(config.interval);
      final elapsed = DateTime.now().difference(started);

      final raw = await _get('/api/v2/taskcomment/$taskId');
      final map = _tryMap(raw) ?? const <String, dynamic>{};
      last = decidePollResponse(
        status: map['status'] as String?,
        taskId: map['taskId'] as String? ?? taskId,
        description: map['description'] as String?,
        progress: (map['progress'] as num?)?.toInt(),
        elapsed: elapsed,
        config: config,
      );
      if (last.isTerminal) return last;
    }
  }

  /// 搜索**候选番剧/剧集列表**（手动匹配面板用）。
  ///
  /// ## 与 [findEpisodeId] 的区别（这是本方法存在的理由）
  /// [findEpisodeId] 只返回**一个** id（自动匹配用）——
  /// 它必然会在"译名不同 / 多季归档"时**猜错**，而用户**无从纠正**。
  ///
  /// 外部两个成熟项目（dd-danmaku / RyoLee/emby-danmaku）的 README
  /// 都专门列了这两类失败原因，并把「手动匹配」当核心功能：
  /// > 1. 译名导致的异常：如『よふかしのうた』Emby 识别为《彻夜之歌》，
  /// >    而弹弹play 中为《夜曲》导致无法匹配
  /// > 2. 存在多季/剧场版/OVA 等导致的异常
  ///
  /// ⇒ 本方法把**候选摊开给用户选**，这是唯一的出路。
  ///
  /// ## 返回结构（统一两种源的形状）
  /// 每个候选 = 一条"番剧 → 其剧集列表"，UI 先让用户选番剧、
  /// 再选具体集（或直接按集号自动选）。
  Future<List<DanmakuCandidate>> searchCandidates(String keyword) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return const [];
    try {
      if (kind == DanmakuProviderKind.publicProxy) {
        // 公共代理：search/anime → bangumi/{id}（两步，见 findEpisodeId 说明）
        final sRaw = await _get('/api/v2/search/anime', query: {'keyword': kw});
        final sMap = _tryMap(sRaw);
        if (sMap == null) return const [];
        final animes = (sMap['animes'] as List?) ?? const [];
        final out = <DanmakuCandidate>[];
        // 只取前 8 个候选：再多用户也不会翻（且减少请求数）
        for (final a in animes.whereType<Map>().take(8)) {
          final aid = (a['animeId'] as num?)?.toInt();
          if (aid == null) continue;
          final title = (a['animeTitle'] as String?) ?? '';
          List<DanmakuEpisodeBrief> eps = const [];
          try {
            final dRaw = await _get('/api/v2/bangumi/$aid');
            final dMap = _tryMap(dRaw);
            final bg = dMap?['bangumi'];
            if (bg is Map) {
              eps = [
                for (final e in ((bg['episodes'] as List?) ?? const [])
                    .whereType<Map>())
                  if ((e['episodeId'] as num?) != null)
                    DanmakuEpisodeBrief(
                      episodeId: (e['episodeId'] as num).toInt(),
                      number: int.tryParse('${e['episodeNumber']}'),
                      title: (e['episodeTitle'] as String?) ?? '',
                    ),
              ];
            }
          } catch (_) {
            // 单个候选取详情失败不影响其它候选
          }
          out.add(DanmakuCandidate(
            animeId: aid,
            title: title,
            type: (a['typeDescription'] as String?) ?? '',
            episodes: eps,
          ));
        }
        return out;
      }

      // 官方 / 自建：`search/episodes?anime=` 一步返回 animes[].episodes[]
      final raw = await _get('/api/v2/search/episodes', query: {'anime': kw});
      final map = _tryMap(raw);
      if (map == null) return const [];
      final animes = (map['animes'] as List?) ?? const [];
      final out = <DanmakuCandidate>[];
      for (final a in animes.whereType<Map>().take(8)) {
        final eps = <DanmakuEpisodeBrief>[
          for (final e in ((a['episodes'] as List?) ?? const []).whereType<Map>())
            if ((e['episodeId'] as num?) != null)
              DanmakuEpisodeBrief(
                episodeId: (e['episodeId'] as num).toInt(),
                number: (e['episodeNumber'] as num?)?.toInt(),
                title: (e['episodeTitle'] as String?) ?? '',
              ),
        ];
        out.add(DanmakuCandidate(
          animeId: (a['animeId'] as num?)?.toInt() ?? 0,
          title: (a['animeTitle'] as String?) ?? '',
          type: (a['typeDescription'] as String?) ?? '',
          episodes: eps,
        ));
      }
      return out;
    } catch (e) {
      // 搜索失败 = "没找到"，不是错误（与 findEpisodeId 同口径）
      return const [];
    }
  }

  /// 按「番剧名 + 集号」搜索弹幕库，取最匹配的 episodeId。
  ///
  /// 官方推荐（2025-01-26 变更日志）：`episode` 用**数字**查询响应更快。
  /// 返回 null 表示没搜到——调用方按"该片暂无弹幕"处理，**不算错误**。
  Future<int?> findEpisodeId({
    required String anime,
    int? episode,
  }) async {
    final key =
        'danmaku:find:$anime:${episode ?? 0}';
    final cached = await cache?.cacheGet(key);
    if (cached != null) {
      final v = int.tryParse(cached);
      // 缓存空串表示"上次就没搜到"，直接短路避免反复打接口
      if (cached.isEmpty) return null;
      if (v != null) return v;
    }

    // ★★ 搜索路径**随源类型分支**（实测差异，不是猜测）
    //
    // · 官方/自建：`/api/v2/search/episodes?anime=&episode=` —— **一步**拿到 id
    // · 公共代理：**没有**那个端点（实测 404）⇒ 走两步：
    //     `/api/v2/search/anime?keyword=` → animeId
    //     `/api/v2/bangumi/{animeId}`     → episodes[] → episodeId
    //
    // ⚠️ 若统一成一种，必有一边拿不到 id ⇒ 表现为"弹幕永远匹配不到"
    //    （不报错、不崩溃，正是本仓库反复记录的静默失败形态）。
    final int? id;
    if (kind == DanmakuProviderKind.publicProxy) {
      id = await _findEpisodeIdViaProxy(anime: anime, episode: episode);
    } else {
      final raw = await _get('/api/v2/search/episodes', query: {
        'anime': anime,
        if (episode != null) 'episode': '$episode',
      });
      id = _pickEpisodeId(raw, episode);
    }
    // 负缓存：没搜到也缓存一个空串，避免每次播放都重试（官方限制批量调用）
    await cache?.cachePut(key, id?.toString() ?? '', ttl: cacheTtl);
    return id;
  }

  /// 公共代理的两步搜索：`search/anime` → `bangumi/{id}` → 选集。
  ///
  /// ## 端点形状（实测 2026-10-10）
  /// ```
  /// GET /api/v2/search/anime?keyword=我推的孩子
  ///   → {"animes":[{"animeId":17449,"animeTitle":"我推的孩子","type":"tvseries"}]}
  /// GET /api/v2/bangumi/17449
  ///   → {"bangumi":{"episodes":[{"episodeId":174490001,
  ///      "episodeTitle":"第1话 母亲和孩子","episodeNumber":"1"}]}}
  /// ```
  ///
  /// ## 选集策略（与官方 `_pickEpisodeId` 同口径）
  /// 优先按 `episodeNumber == episode` **精确匹配**；没集号或匹配不到时
  /// 回退第一集（至少能出弹幕，用户可用"手动匹配"纠正）。
  ///
  /// ## 容错
  /// · `animes` 为空 → null（"该片暂无弹幕"，**不是错误**）
  /// · `episodes` 为空/缺字段 → null
  /// · 任何解析异常都吞掉返回 null —— 搜索失败不该让播放页报错
  Future<int?> _findEpisodeIdViaProxy({
    required String anime,
    int? episode,
  }) async {
    try {
      // ---- 第一步：按标题找番剧 ----
      final searchRaw =
          await _get('/api/v2/search/anime', query: {'keyword': anime});
      final searchMap = _tryMap(searchRaw);
      if (searchMap == null) return null;
      final animes = (searchMap['animes'] as List?) ?? const [];
      if (animes.isEmpty) return null;

      // 取第一个结果：代理已按相关度排序（实测「我推的孩子」首条即正确项）
      final list0 = animes.whereType<Map<String, dynamic>>().toList();
      if (list0.isEmpty) return null;
      final animeId = (list0.first['animeId'] as num?)?.toInt();
      if (animeId == null) return null;

      // ---- 第二步：取该番剧的集列表 ----
      final detailRaw = await _get('/api/v2/bangumi/$animeId');
      final detailMap = _tryMap(detailRaw);
      if (detailMap == null) return null;
      final bg = detailMap['bangumi'];
      if (bg is! Map) return null;
      final eps = (bg['episodes'] as List?) ?? const [];
      if (eps.isEmpty) return null;

      final list = eps.whereType<Map<String, dynamic>>().toList();
      if (list.isEmpty) return null;

      // ---- 选集：精确匹配集号，否则第一集 ----
      if (episode != null) {
        for (final e in list) {
          final n = e['episodeNumber'];
          final asInt = n is num ? n.toInt() : int.tryParse('$n');
          if (asInt == episode) {
            final id = (e['episodeId'] as num?)?.toInt();
            if (id != null) return id;
          }
        }
      }
      return (list.first['episodeId'] as num?)?.toInt();
    } catch (_) {
      // 搜索失败 = "暂无弹幕"，不是错误（与官方路径同口径）
      return null;
    }
  }

  // ------------------------------------------------------------------

  /// **取「平台侧」的番剧更新信息**（周几 / 平台集数 / 是否在播 / 播出平台）。
  ///
  /// ## ★ 为什么复用弹幕源的端点
  /// 用户："我接的不是 danmu_api 里面的嘛"。
  /// 弹弹play 兼容 API 的 `/api/v2/bangumi/{id}` 已经包含
  /// **20+ 平台**（腾讯/优酷/爱奇艺/B站/芒果/咪咕…）统一后的番剧数据：
  /// ```
  /// metadata: ["话数: 26", "放送星期: 星期日", "在线播放平台: 腾讯视频", …]
  /// episodes: [{episodeNumber, episodeTitle, airDate} × N]
  /// isOnAir: false
  /// ```
  /// ⇒ 不必逐家逆平台私有协议（那条路走过：腾讯要 H38/H42/Uk 三个头 + Cookie，
  ///   优酷要 UA 与页面配对，爱奇艺字段名还会变）。
  ///
  /// ## 与 `_findEpisodeIdViaProxy` 的关系
  /// 两者**都是** search→bangumi 两次请求，但**目的不同**：
  /// · 那个要 `episodeId`（去取弹幕）
  /// · 这个要 `metadata`/`episodes.length`（去显示平台信息）
  /// ⇒ 暂不合并：合并会让"只要弹幕"的路径被迫解析无关字段。
  ///
  /// ## 返回
  /// `null` = 拿不到（未配源 / 搜不到 / 上游改字段）。
  /// **这不是错误** —— 调用方退回已有逻辑，不向用户报错。
  Future<PlatformEpisodes?> fetchPlatformEpisodes(String title) async {
    final kw = title.trim();
    if (kw.isEmpty) return null;
    try {
      final searchRaw =
          await _get('/api/v2/search/anime', query: {'keyword': kw});
      final searchMap = _tryMap(searchRaw);
      if (searchMap == null) return null;
      final animes = (searchMap['animes'] as List?) ?? const [];
      final list0 = animes.whereType<Map<String, dynamic>>().toList();
      if (list0.isEmpty) return null;
      // 取第一个：上游已按相关度排序（与 `_findEpisodeIdViaProxy` 同策略）
      final animeId = (list0.first['animeId'] as num?)?.toInt();
      if (animeId == null) return null;

      final detailRaw = await _get('/api/v2/bangumi/$animeId');
      final detailMap = _tryMap(detailRaw);
      if (detailMap == null) return null;
      return parseBangumi(detailMap);
    } catch (_) {
      // 拿不到平台信息 ≠ 错误（与 `_findEpisodeIdViaProxy` 同口径）
      return null;
    }
  }

  // ------------------------------------------------------------------

  /// 发 GET 并处理两种错误层（HTTP 层 + 200 里的业务层）。
  Future<String> _get(String path, {Map<String, dynamic>? query}) async {
    // 认证方式随源类型不同（这是三种部署形态的核心差异）：
    //  - 官方：必须带 X-AppId/X-Timestamp/X-Signature 三个头
    //  - 公共代理：**不带任何认证头**（免注册，实测直接可用）
    //  - 自建：token 在 URL 路径里，**不需要任何认证头**
    //    （调研确认 danmu_api/misaka 都不看 header 签名）
    final Map<String, String> headers;
    if (_isOfficial) {
      if (appId.isEmpty || appSecret.isEmpty) {
        throw const DanmakuException('未配置弹弹play 凭据（AppId / AppSecret）');
      }
      headers = dandanplayAuthHeaders(
        appId: appId,
        appSecret: appSecret,
        // ⚠️ 必须是**不含查询参数**的 path，否则签名不匹配（官方第 5 节）
        path: path,
      );
    } else {
      // 公共代理与自建都无需签名头。自建要校验 base 非空
      //（公共代理的 base 是内置常量，必然非空）。
      if (baseUrl.isEmpty) {
        throw const DanmakuException('未配置弹幕服务地址');
      }
      headers = const {};
    }

    final Response<String> resp;
    try {
      resp = await _dio.get<String>(
        '$baseUrl$path',
        queryParameters: query,
        options: Options(
          headers: headers,
          responseType: ResponseType.plain,
          // 让 dio 把 4xx 也交给我们处理，以便读出 X-Error-Message
          validateStatus: (s) => s != null && s < 500,
        ),
      );
    } on DioException catch (e) {
      throw DanmakuException(_networkMessage(e));
    }

    final code = resp.statusCode ?? 0;
    if (code == 401) {
      throw const DanmakuException('弹幕服务拒绝了请求：缺少身份验证',
          statusCode: 401);
    }
    if (code == 403) {
      // 官方在响应头里给具体原因（第 6 节）；自建服务则是 token 无效
      final reason = resp.headers.value('x-error-message') ?? '';
      throw DanmakuException(
          _isOfficial ? _forbiddenMessage(reason) : '弹幕服务拒绝访问（token 无效或未授权）',
          statusCode: 403);
    }
    // ⚠️ 自建服务的一个坑（调研确认）：弹幕未命中时返回 **HTTP 404**
    // 且 body 是 `{"count":0,"comments":[]}`。
    // 这不是错误，是"这一集没有弹幕"——若当错误抛出，用户会看到无意义的报错。
    if (code == 404) {
      final body404 = resp.data ?? '';
      final m = _tryMap(body404);
      if (m != null && m.containsKey('count')) return body404;
      throw const DanmakuException('弹幕服务未找到该条目', statusCode: 404);
    }
    if (code < 200 || code >= 300) {
      throw DanmakuException('弹幕服务返回 HTTP $code', statusCode: code);
    }

    final body = resp.data ?? '';

    // 业务错误包在 200 里（官方第 6 节；自建服务也用这个形状）——必须显式判断，
    // 否则"服务器内部错误"会被当成"这部片没有弹幕"。
    final map = _tryMap(body);
    if (map != null && map['success'] == false) {
      final msg = (map['errorMessage'] as String?)?.trim();
      throw DanmakuException(
          msg == null || msg.isEmpty ? '弹幕服务返回业务错误' : '弹幕服务：$msg');
    }
    return body;
  }

  String _networkMessage(DioException e) {
    final t = e.type;
    if (t == DioExceptionType.connectionTimeout ||
        t == DioExceptionType.receiveTimeout ||
        t == DioExceptionType.sendTimeout) {
      return '连接弹幕服务超时（检查网络或服务地址）';
    }
    if (t == DioExceptionType.connectionError) {
      return _isOfficial
          ? '无法连接 api.dandanplay.net（可能被网络拦截）'
          : '无法连接弹幕服务（检查地址与端口，以及是否在同一网络）';
    }
    return '弹幕请求失败：${e.message ?? e.type.name}';
  }

  /// 403 的 `X-Error-Message` → 中文提示。
  ///
  /// 官方只给这几个英文枚举值，逐个翻译：
  /// 用户看到 "Invalid Signature" 无从下手，看到"签名不匹配（检查 AppSecret）"
  /// 才知道去改设置。
  String _forbiddenMessage(String reason) => switch (reason) {
        'Missing Authentication Headers' =>
          '弹弹play：缺少认证头（请检查 AppId/AppSecret 是否已填）',
        'Invalid Timestamp' =>
          '弹弹play：时间戳无效（设备时间与标准时间偏差过大，请校准系统时间）',
        'Invalid AppId' =>
          '弹弹play：AppId 或 AppSecret 无效',
        'Invalid Signature' =>
          '弹弹play：签名不匹配（请检查 AppSecret 是否正确）',
        'Invalid AppSecret' =>
          '弹弹play：AppSecret 无效',
        _ => reason.isEmpty
            ? '弹弹play 拒绝访问（403）'
            : '弹弹play 拒绝访问：$reason',
      };
}

// ---------------------------------------------------------------------------
// 解析（拆成顶层函数便于单测）
// ---------------------------------------------------------------------------

Map<String, dynamic>? _tryMap(String s) {
  try {
    final v = jsonDecode(s);
    return v is Map ? v.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}

/// 从弹幕响应解出弹幕列表。
///
/// 官方形状：`{"count":N,"comments":[{"cid":…,"p":"…","m":"…"}, …]}`
/// 兼容：`comments` 缺失 / 元素不是 Map / `p` 或 `m` 缺失 —— 一律跳过该条，
/// **不抛异常**（自建服务与第三方源的实现质量参差）。
DanmakuBatch? _decodeCommentsImpl(String body, int episodeId) {
  final map = _tryMap(body);
  if (map == null) return null;

  final list = map['comments'];
  if (list is! List) {
    // 有 count 但无 comments：服务端明确表示"没有弹幕"，是合法结果
    if (map.containsKey('count')) {
      return DanmakuBatch(items: const [], episodeId: episodeId);
    }
    return null;
  }

  final items = <Danmaku>[];
  for (final e in list) {
    if (e is! Map) continue;
    final p = e['p'];
    final m = e['m'];
    if (p is! String || m is! String) continue;
    final d = Danmaku.fromP((e['cid'] as Object?)?.toString() ?? '', p, m);
    if (d != null) items.add(d);
  }

  return DanmakuBatch(
    items: items,
    episodeId: episodeId,
    animeTitle: map['animeTitle'] as String?,
    episodeTitle: map['episodeTitle'] as String?,
  ).sorted();
}

/// 从搜索响应里挑出最匹配的 episodeId。
///
/// 官方形状：`{"success":true,"animes":[{"animeId":…,"animeTitle":"…",
/// "episodes":[{"episodeId":…,"episodeTitle":"…","episodeNumber":N}]}]}`
///
/// 挑选策略（按可信度）：
///   1. `episodeNumber` 与请求集号**完全相等**的
///   2. 都没有 episodeNumber 时，取第一个番剧的第一集
/// 不用"标题相似度"：番剧名已经由搜索接口匹配过，这里再做模糊匹配
/// 只会引入新的误判。
int? _pickEpisodeIdImpl(String body, int? episode) {
  final map = _tryMap(body);
  if (map == null) return null;
  final animes = map['animes'];
  if (animes is! List) return null;

  int? firstAny;
  for (final a in animes) {
    if (a is! Map) continue;
    final eps = a['episodes'];
    if (eps is! List) continue;
    for (final e in eps) {
      if (e is! Map) continue;
      final id = (e['episodeId'] as num?)?.toInt();
      if (id == null) continue;
      firstAny ??= id;
      final num_ = (e['episodeNumber'] as num?)?.toInt();
      if (episode != null && num_ == episode) return id;
    }
  }
  // 没给集号（电影/剧场版）或没匹配上时，用第一个可用结果
  return firstAny;
}

/// 供客户端调用的包装（保持可读的调用点）
DanmakuBatch? _decodeComments(String body, int episodeId) =>
    _decodeCommentsImpl(body, episodeId);

int? _pickEpisodeId(String body, int? episode) =>
    _pickEpisodeIdImpl(body, episode);
