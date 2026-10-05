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
        baseUrl: config.kind == DanmakuProviderKind.official
            ? kOfficialBase
            : config.normalizedBase,
        appId: config.appId,
        appSecret: config.appSecret,
        useAsync: config.useAsync,
        dio: dio,
      );

  DanmakuClient({
    required this.kind,
    required this.baseUrl,
    this.appId = '',
    this.appSecret = '',
    this.useAsync = true,
    Dio? dio,
  }) : _dio = dio ?? Dio();

  /// 官方服务器地址（文档第 2 节）。自建服务用配置里的地址。
  static const kOfficialBase = 'https://api.dandanplay.net';

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
    int chConvert = 1,
  }) async {
    final path = '/api/v2/comment/$episodeId';
    final cacheKey =
        'danmaku:comment:$episodeId:$withRelated:$chConvert:${baseUrl.hashCode}';

    // 1) 先查缓存（官方要求缓存；也避免触发自建服务的限流）
    final cached = await cache?.cacheGet(cacheKey);
    if (cached != null) {
      final parsed = _decodeComments(cached, episodeId);
      if (parsed != null) return parsed;
    }

    // 2) 首次请求（异步模式下可能返回 pending）
    final raw = await _get(path, query: {
      'withRelated': '$withRelated',
      'chConvert': '$chConvert',
      if (useAsync) 'async': '1',
    });

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

    final raw = await _get('/api/v2/search/episodes', query: {
      'anime': anime,
      if (episode != null) 'episode': '$episode',
    });
    final id = _pickEpisodeId(raw, episode);
    // 负缓存：没搜到也缓存一个空串，避免每次播放都重试（官方限制批量调用）
    await cache?.cachePut(key, id?.toString() ?? '', ttl: cacheTtl);
    return id;
  }

  // ------------------------------------------------------------------

  /// 发 GET 并处理两种错误层（HTTP 层 + 200 里的业务层）。
  Future<String> _get(String path, {Map<String, dynamic>? query}) async {
    // 认证方式随源类型不同（这是两种部署形态的核心差异）：
    //  - 官方：必须带 X-AppId/X-Timestamp/X-Signature 三个头
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
