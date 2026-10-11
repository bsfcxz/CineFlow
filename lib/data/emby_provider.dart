/// Emby 协议实现（当前阶段的 MediaProvider）
/// 踩坑对策源自多服务器实测，见各方法注释。
library;
import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint;

import 'package:dio/dio.dart';

import '../core/uuid.dart';
import '../core/version.dart';
import 'media_provider.dart';
import 'models.dart';

class MediaException implements Exception {
  final String message;
  const MediaException(this.message);
  @override
  String toString() => message;
}

class EmbyProvider implements MediaProvider {
  EmbyProvider._(this.session, this._dio);

  final MediaSession session;
  final Dio _dio;

  /// 暴露 Dio 供测试注入拦截器、断言**实际发出的查询参数**。
  /// 服务端筛选这类缺陷（§7.15）表现为"UI 看着对、结果不完整"，
  /// 只有断言请求参数才能防回归——见 test/server_filter_test.dart。
  /// 生产代码请勿通过此 getter 发请求，一律走 MediaProvider 方法。
  Dio get dio => _dio;

  static const clientName = 'CineFlow';

  /// 协议头版本：与仓库根 `VERSION` 同源，见 `lib/core/version.dart`。
  /// 曾硬编码为 '0.1.0' 而与实际版本脱节（缺陷 7.17）。
  static const clientVersion = kClientVersion;

  /// 标准 Emby 客户端声明头（Version 缺失时部分 Emby 服务端 AuthenticateByName 会 500）
  static String authHeader(String deviceId, [String? token]) {
    final base = 'MediaBrowser Client="$clientName", Device="Android", '
        'DeviceId="$deviceId", Version="$clientVersion"';
    return token == null ? base : '$base, Token="$token"';
  }

  factory EmbyProvider(MediaSession session) {
    final dio = Dio(BaseOptions(
      baseUrl: session.serverUrl,
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 20),
      sendTimeout: const Duration(seconds: 12),
      validateStatus: (c) => c != null && c < 500,
    ));
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      options.headers['X-Emby-Authorization'] =
          authHeader(session.deviceId, session.accessToken);
      options.headers['X-Emby-Token'] = session.accessToken;
      handler.next(options);
    }));
    return EmbyProvider._(session, dio);
  }

  /// 用户名密码认证（POST /Users/AuthenticateByName）
  static Future<MediaSession> authenticate({
    required String serverUrl,
    required String username,
    required String password,
    required String deviceId,
  }) async {
    final dio = Dio(BaseOptions(
      baseUrl: serverUrl,
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 15),
      validateStatus: (c) => c != null && c < 500,
    ));
    try {
      final r = await dio.post('/Users/AuthenticateByName',
          data: {'Username': username, 'Pw': password},
          options: Options(headers: {'X-Emby-Authorization': authHeader(deviceId)}));
      if (r.statusCode == 401) {
        throw const MediaException('用户名或密码错误');
      }
      final data = (r.data as Map<String, dynamic>?);
      final token = data?['AccessToken'] as String?;
      final user = data?['User'] as Map<String, dynamic>?;
      if (token == null || token.isEmpty || user == null) {
        throw const MediaException('服务器返回异常，请确认是 Emby 服务');
      }
      return MediaSession(
        serverUrl: serverUrl,
        accessToken: token,
        user: MediaUser.fromJson(user),
        deviceId: deviceId,
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        throw const MediaException('用户名或密码错误');
      }
      throw MediaException(_friendly(e));
    }
  }

  static String _friendly(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '连接超时，请检查服务器地址与网络';
      case DioExceptionType.connectionError:
        return '无法连接服务器，请检查地址与网络';
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode ?? 0;
        if (code == 401) return '用户名或密码错误';
        if (code == 404) return '接口不存在，请确认这是 Emby 服务器';
        return '服务器错误 ($code)';
      default:
        return '登录失败，请稍后重试';
    }
  }

  dynamic _ok(Response r) {
    if ((r.statusCode ?? 500) >= 400) {
      throw MediaException('服务器错误 (${r.statusCode})');
    }
    return r.data;
  }

  List<Map<String, dynamic>> _itemsList(dynamic data) =>
      ((data is Map<String, dynamic> ? data['Items'] : data) as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();

  @override
  Future<List<MediaView>> getViews() async {
    final d = _ok(await _dio.get('/Users/${session.user.id}/Views'));
    return [
      for (final j in _itemsList(d)) MediaView.fromJson(j),
    ];
  }

  @override
  Future<List<MediaItem>> getLatest({int limit = 24}) async {
    // ⚠️ 实测：/Latest 返回裸数组；IncludeItemTypes 服务端可能无视 → 客户端复筛。
    //
    // ★ 2026-10 修一个真实缺陷（首页只剩 1 条内容）：
    //   原参数是 `'IncludeItemTypes': 'Movie,Episode'`（只请求电影与单集），
    //   但下游复筛用的是 `isPlayable`（**Series 也算可播**，见 models.dart）。
    //   两者口径不一致 → **剧集被服务端滤掉、复筛也无从救回**。
    //
    //   实测证据（用户真实库）：`/Latest` 不带到类型时返回 **24 条且全部有背景图**，
    //   带上 `Movie,Episode` 后该库只剩 **1 条**（因为最近添加的几乎全是 Series）。
    //   首页因此出现 940px 空白带（占屏 39%）。
    //
    //   修法：**不在服务端做类型过滤**，把"哪些能上首页"完全交给客户端的
    //   `isPlayable` 一处决定。这样也符合 AGENTS §6.1 的既有结论
    //   （服务端筛选不可信），而不是反过来依赖它。
    final d = _ok(await _dio.get('/Users/${session.user.id}/Items/Latest',
        queryParameters: {
          'Limit': limit,
          'Fields':
              // `Collections`：与 getResume 同理 —— 首页轮播/最近添加里的
              // 电影也要能解析出合集体，否则从这些入口进播放器时
              // "列表没有下一部"仍会复现。
              'PrimaryImageAspectRatio,ProductionYear,OfficialRating,'
                  'CommunityRating,Genres,Overview,DateCreated,Collections',
        }));
    final items = [for (final j in _itemsList(d)) MediaItem.fromJson(j)];
    // 单一事实源：可播性只在这里判定（Series 保留 —— 它是合法浏览入口，
    // 真正起播时会下钻到 Episode）
    return items.where((i) => i.isPlayable).toList();
  }

  @override
  Future<List<MediaItem>> getResume({int limit = 12}) async {
    final d = _ok(await _dio.get('/Users/${session.user.id}/Items/Resume',
        queryParameters: {
          'Limit': limit,
          'MediaTypes': 'Video',
          // ★ `Collections` 必加（2026-10-09）：
          //   "继续观看"是**用户点进电影的主要入口**（真机截图确认），
          //   不带这个字段 ⇒ 电影条目拿不到合集体 ⇒
          //   `openPlayerResolved` 的合集分支只能降级成单条播放 ⇒
          //   "列表里没有下一部"（用户报障）在这条路径上**依然复现**。
          //   ⚠️ 只补 `getItems`/`getItemDetail` 而漏这里 = 修了但没修全。
          'Fields': 'PrimaryImageAspectRatio,BasicSyncInfo,Collections',
        }));
    return [for (final j in _itemsList(d)) MediaItem.fromJson(j)];
  }

  @override
  String imageUrl(String itemId,
      {String type = 'Primary',
      int position = 0,
      String? tag,
      int maxWidth = 480}) {
    final path = type == 'Backdrop' ? '$type/$position' : type;
    final t = (tag == null || tag.isEmpty) ? '' : '&tag=$tag';
    return '${session.serverUrl}/Items/$itemId/Images/$path'
        '?maxWidth=$maxWidth&quality=88$t&api_key=${session.accessToken}';
  }

  @override
  Future<List<MediaItem>> search(String keyword, {int limit = 30}) async {
    // ★★ 2026-10-09 修："搜索剧集时出现一堆散乱单集"（用户报障）
    //
    // ## 根因
    // 原实现 `IncludeItemTypes: 'Movie,Episode'` —— **直接请求单集**。
    // 搜"斗罗大陆"时服务端把每一集都当独立结果返回 ⇒ 列表被
    // `第 1 集 / 第 2 集 / 第 3 集…` 刷屏，而用户想找的是**那部剧**。
    //
    // ## 按 Emby 的口径修（不是自创规则）
    // Emby 的"可浏览实体"是 **Series / Movie / BoxSet / Video**；
    // `Episode` 属于 Series 的子项，不该作为搜索结果的平级条目。
    // 官方 `ItemsService.GetItems` 的 `IncludeItemTypes` 就是为此设计的
    //（见官方 Go SDK `api_items_service.go` 的参数表）。
    //
    // ## 为什么仍然请求 Episode，但**折叠**掉
    // 有些单集的名字与剧名无关（搜"第 6 集"或某集专属标题时），
    // 完全不请求会漏结果。故：
    //   · 服务端返回 Series + Movie + BoxSet + Video + Episode
    //   · **客户端把 Episode 折叠到它的剧集下**（`SeriesId` 已出现 ⇒ 丢弃该集）
    //   · 剧集本身没出现时**保留该集**（否则用户搜不到）
    // ⇒ 既不漏，也不刷屏；且折叠规则只依赖服务端给的 `SeriesId`。
    //
    // ## `MediaTypes: 'Video'` 已去掉
    // 它会滤掉 `BoxSet`（合集不是视频类型）—— 而合集是"系列电影"的
    // 载体（见 `collectionIds`）。去掉后由下面的 `isPlayable`/类型白名单收敛。
    final d = _ok(await _dio.get('/Users/${session.user.id}/Items',
        queryParameters: {
          'SearchTerm': keyword,
          'Limit': limit,
          'Recursive': true,
          'IncludeItemTypes': 'Movie,Series,BoxSet,Video,Episode',
          // 按用户要求的排序：Emby 默认 `SortName`，与本服务器实测一致
          'SortBy': 'SortName',
          'SortOrder': 'Ascending',
          'Fields': 'PrimaryImageAspectRatio,ProductionYear,OfficialRating,'
              'CommunityRating,Collections,SeriesId,'
              // ★★ **必须带 ProviderIds** —— 跨服务器去重的唯一可靠依据
              //
              // ## 为什么（实测取证，2026-10-11，两台真实 Emby）
              // Emby **默认不返回** `ProviderIds`，必须显式请求。
              // 带上后的填充率：
              // ```
              // iLoveHD: Tmdb 87% / Tvdb 76% / Imdb 75.5%
              // HK-Emby: Tmdb 100% / Imdb 95% / Tvdb 67%
              // ```
              // ⇒ 聚合搜索靠它判"同一部片在两台都有"。
              //   不请求 ⇒ `providerIds` 恒空 ⇒ 去重退回标题匹配
              //   ⇒ 中英文混排的片名**匹配不上**，用户看到重复条目。
              'ProviderIds',
        }));

    final raw = [for (final j in _itemsList(d)) MediaItem.fromJson(j)];

    // ---- 折叠单集（见上方说明）----
    final seriesIds = <String>{
      for (final i in raw)
        if (i.type == 'Series' || i.type == 'BoxSet') i.id,
    };
    final out = <MediaItem>[];
    for (final i in raw) {
      if (i.type == 'Episode') {
        // 该集所属剧集已在结果里 ⇒ 丢弃（用户点剧集进去看分集）
        final sid = i.seriesId;
        if (sid != null && sid.isNotEmpty && seriesIds.contains(sid)) continue;
      }
      // 类型白名单（`isPlayable` 已含 Series/Movie/Episode/Video/…）
      if (!i.isPlayable) continue;
      out.add(i);
    }
    return out;
  }

  @override
  Future<ItemPage> getItems({
    String? parentId,
    String includeTypes = 'Movie,Series',
    String? searchTerm,
    String sortBy = 'SortName',
    String sortOrder = 'Ascending',
    bool recursive = true,
    bool unplayedOnly = false,
    String? filters,
    String? genres,
    String? years,
    int startIndex = 0,
    int limit = 40,
  }) async {
    final d = _ok(await _dio.get('/Users/${session.user.id}/Items',
        queryParameters: {
          'ParentId': ?parentId,
          'Recursive': recursive,
          'IncludeItemTypes': includeTypes,
          if (searchTerm case final st? when st.isNotEmpty) 'SearchTerm': st,
          'SortBy': sortBy,
          // 实测：本服务器 DateCreated+Ascending 返回最旧，Descending 才最新，
          // 故方向由调用方显式传入，勿依赖服务端默认（见 MediaProvider.getItems 注释）
          'SortOrder': sortOrder,
          'StartIndex': startIndex,
          'Limit': limit,
          // ⚠️ 两个 Filters 分支只能二选一：同时写入会被后者静默覆盖（原缺陷 §7.6）
          if (unplayedOnly)
            'Filters': 'IsUnplayed'
          else if (filters case final f? when f.isNotEmpty)
            'Filters': f,
          // 服务端类型/年份筛选（实测有效；客户端复筛在分页下不完整，见 §7.15）
          if (genres case final g? when g.isNotEmpty) 'Genres': g,
          if (years case final y? when y.isNotEmpty) 'Years': y,
          'Fields':
              // ★ `Collections` 必加：它是"电影所属合集"的唯一来源
              //   （见 `MediaItem.collectionIds`）。缺它就永远拿不到
              //   兄弟片 ⇒ 列表里没有"下一部"（用户报障场景）。
              'PrimaryImageAspectRatio,ProductionYear,OfficialRating,'
                  'CommunityRating,UserData,Collections',
        })) as Map<String, dynamic>;
    final items = [for (final j in _itemsList(d)) MediaItem.fromJson(j)];
    return ItemPage(
      items: items,
      total: (d['TotalRecordCount'] as num?)?.toInt() ?? items.length,
    );
  }

  @override
  Future<MediaItemDetail> getItemDetail(String itemId) async {
    final d = _ok(await _dio.get('/Users/${session.user.id}/Items/$itemId',
        queryParameters: {
          'Fields':
              // ★ `Collections` 同 `getItems`：详情页也要用它才能知道
              //   "这部属于哪个合集"（电影详情页的"同系列"入口依赖它）。
              'MediaSources,People,Studios,Genres,Overview,Taglines,'
                  'ProductionYear,OfficialRating,CommunityRating,Collections',
        })) as Map<String, dynamic>;
    return MediaItemDetail.fromJson(d);
  }

  /// 库内可用类型。实测 `/Genres?ParentId=` → 200 + `{Items:[{Name}]}`；
  /// 空 Name 要滤掉（实测记录过该形态）。
  @override
  Future<List<String>> getGenres({String? parentId}) async {
    final d = _ok(await _dio.get('/Genres', queryParameters: {
      'ParentId': ?parentId,
      'UserId': session.user.id,
    }));
    final names = ((d is Map<String, dynamic> ? d['Items'] : d) as List? ??
            const [])
        .whereType<Map<String, dynamic>>()
        .map((j) => (j['Name'] as String? ?? '').trim())
        .where((n) => n.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return names;
  }

  /// 年份区间：两次 Limit=1 探针（年份无分面端点，见 MediaProvider 注释）。
  /// 只取首条的 ProductionYear；缺失即视为该端无数据。
  @override
  Future<(int, int)?> getYearRange({
    String? parentId,
    String includeTypes = 'Movie,Series',
  }) async {
    Future<int?> probe(String sortOrder) async {
      final d = _ok(await _dio.get('/Users/${session.user.id}/Items',
          queryParameters: {
            'ParentId': ?parentId,
            'Recursive': true,
            'IncludeItemTypes': includeTypes,
            'SortBy': 'ProductionYear',
            'SortOrder': sortOrder,
            'Limit': 1,
            'Fields': 'ProductionYear',
          })) as Map<String, dynamic>;
      final items = _itemsList(d);
      if (items.isEmpty) return null;
      return (items.first['ProductionYear'] as num?)?.toInt();
    }

    // 并发两端探针；任一端缺失或不对（早>晚）都视为无区间
    final results = await Future.wait([probe('Descending'), probe('Ascending')]);
    final newest = results[0];
    final oldest = results[1];
    if (newest == null || oldest == null || oldest > newest) return null;
    return (oldest, newest);
  }

  @override
  Future<List<MediaItem>> getSeasons(String seriesId) async {
    final d = _ok(await _dio.get('/Shows/$seriesId/Seasons',
        queryParameters: {
          'userId': session.user.id,
          'Fields': 'BasicSyncInfo,PrimaryImageAspectRatio',
        }));
    return [for (final j in _itemsList(d)) MediaItem.fromJson(j)];
  }

  @override
  Future<List<MediaItem>> getEpisodes(String seriesId, String seasonId) async {
    final d = _ok(await _dio.get('/Shows/$seriesId/Episodes',
        queryParameters: {
          'userId': session.user.id,
          'seasonId': seasonId,
          // UserData 必须带：分集列表要显示"已看/看到多少"
          'Fields': 'PrimaryImageAspectRatio,Overview,UserData',
        }));
    return [for (final j in _itemsList(d)) MediaItem.fromJson(j)];
  }

  /// 「该看哪几集」—— 直接问服务端（用户指出的"致命问题"的正解）。
  ///
  /// 实测（本服务器 Emby 4.10）：
  ///   · `GET /Shows/NextUp?UserId=&SeriesId=&Limit=3` → S1E9/E10/E11（带 UserData）
  ///   · **不带 `SeriesId` 时返回 0 条** —— 该端点默认语义是"整个库的下一集"，
  ///     需要其它参数配合；单剧场景必须带 `SeriesId`。
  ///   · 该剧全部看完时返回**空列表**（不是错误）→ 调用方据此回退到第一集。
  ///
  /// 这替代了此前自己实现的 `SeriesProgress.resolve`（拉全部集 + 逐个推断），
  /// 省掉 2 次请求，且语义更准（服务端有完整观看历史）。
  @override
  Future<List<MediaItem>> getNextUp(String seriesId, {int limit = 1}) async {
    final d = _ok(await _dio.get('/Shows/NextUp',
        queryParameters: {
          'UserId': session.user.id,
          'SeriesId': seriesId,
          'Limit': limit,
          // 与 getEpisodes 保持一致的字段集，保证卡片渲染不差数据
          'Fields': 'PrimaryImageAspectRatio,Overview,UserData',
        }));
    return [for (final j in _itemsList(d)) MediaItem.fromJson(j)];
  }

  @override
  Future<List<MediaItem>> getSimilar(String itemId) async {
    // ★ 2026-10-09 改用**服务端分类推荐**（用户要求第一批第 3 项）
    //
    // ## 为什么换（`/Items/{id}/Similar` 不够好）
    // `/Similar` 只给一个**平铺列表**，服务端已经算好了分类
    //（"同类型"/"同导演"/"同演员"…）却**全混在一起**，
    // 客户端拿不到"为什么推荐它"。
    //
    // ## 新端点（依据 Emby 官方 Go SDK）
    // `Clients/Go/api_movies_service.go`：
    // ```
    // localVarPath = BasePath + "/Movies/Recommendations"
    // ```
    // 参数（同文件）：`CategoryLimit` / `ItemLimit` / `UserId` /
    // `ParentId` / `ImageTypeLimit`。
    //
    // ## 返回形状差异（关键）
    // `/Similar` 返回 `{Items:[…]}`；`/Movies/Recommendations`
    // 返回 **`[{BaselineItemName, RecommendationType, Items:[…]}, …]`**
    // —— 即"分组数组"，每组一个推荐理由。
    // ⚠️ 这里做**形状兼容**：两种都吃（若服务端/版本给平铺也照常工作）。
    //   客户端不该假设某一种形状一定成立（AGENTS §5.3 防御式解析）。
    final d = _ok(await _dio.get('/Movies/Recommendations', queryParameters: {
      'UserId': session.user.id,
      'ItemLimit': 8,
      'CategoryLimit': 4,
      'Fields': 'PrimaryImageAspectRatio,ProductionYear,CommunityRating,'
          'OfficialRating,UserDefaults,Collections',
    }));

    final out = <MediaItem>[];
    final seen = <String>{};
    // 形状 A：分组数组（官方形状）
    if (d is List) {
      for (final g in d.whereType<Map<String, dynamic>>()) {
        for (final j in _itemsList(g)) {
          final it = MediaItem.fromJson(j);
          if (seen.add(it.id)) out.add(it);
        }
      }
    } else if (d is Map<String, dynamic>) {
      // 形状 B：平铺（容错）
      for (final j in _itemsList(d)) {
        final it = MediaItem.fromJson(j);
        if (seen.add(it.id)) out.add(it);
      }
    }
    // 只保留可播条目（推荐里可能混入 Person/Genre 之类的实体）
    return out.where((i) => i.isPlayable).toList();
  }

  /// 某演职员参与过的作品（用户要求第一批第 1 项：点演员有反应）。
  ///
  /// ## 端点依据（Emby 官方 Go SDK，非猜测）
  /// `Clients/Go/api_persons_service.go`：
  /// ```
  /// localVarPath = a.client.cfg.BasePath + "/Persons/{Id}/Credits"
  /// ```
  ///
  /// ## 参数取舍
  /// · `UserId`：让每个作品带 `UserData`（"已看/看到 N%"）——
  ///   作品列表要能显示进度，否则用户分不清哪部看过。
  /// · `Fields` 带 `Collections`：列表里点进某部电影时，那部也要知道
  ///   自己的合集（否则连播链断掉，与 `collectionIds` 同因）。
  /// · `Recursive: true`：该人可能只在剧里演某一集，不递归会漏。
  /// · **不按类型过滤**：演员既有电影也有剧集，全要。
  ///
  /// ⚠️ 路径**不带** `/Users/{uid}` 前缀（与 `/Persons` 服务同族）。
  @override
  Future<List<MediaItem>> getPersonCredits(String personId) async {
    final d = _ok(await _dio.get('/Persons/$personId/Credits',
        queryParameters: {
          'UserId': session.user.id,
          'Recursive': true,
          'Fields': 'PrimaryImageAspectRatio,ProductionYear,CommunityRating,'
              'OfficialRating,UserData,RunTimeTicks,Collections',
          // 按社区评分排序：比按名字排更贴近"值得看的作品"
          'SortBy': 'CommunityRating,ProductionYear',
          'SortOrder': 'Descending,Descending',
        }));
    return [for (final j in _itemsList(d)) MediaItem.fromJson(j)]
        .where((i) => i.isPlayable)
        .toList();
  }

  /// 上报搜索给服务端（用户要求第一批第 4 项，**只做写入侧**）。
  ///
  /// ## 端点依据（官方 Go SDK `api_user_library_service.go`）
  /// ```
  /// localVarPath = BasePath + "/Users/{UserId}/SearchedItems/"
  /// ```
  /// 动词 `Post`。
  ///
  /// ## ⚠️ 为什么没有"读取"实现
  /// 全 SDK 核实：Emby **没有** GET 搜索历史的端点
  ///（只有 POST 上报 + 两处 DELETE 清空，见 `MediaProvider` 的说明）。
  /// 故读取侧仍用本地 `SessionStore.loadSearchHistory`。
  /// 编一个不存在的 GET 端点会导致"历史永远为空"的假实现。
  ///
  /// ## 为什么是 fire-and-forget
  /// 搜索已成功返回结果，上报只是**附带**。让上报失败阻断搜索体验
  /// 是本末倒置；且不同 Emby 版本可能无此端点（要静默容忍）。
  @override
  void reportSearched(String query) {
    final q = query.trim();
    if (q.isEmpty) return;
    unawaited(() async {
      try {
        await _dio.post('/Users/${session.user.id}/SearchedItems/',
            queryParameters: {'SearchTerm': q});
      } catch (e) {
        // 静默：非关键路径。留日志便于排查（如端点不存在）
        debugPrint('[Search] 上报服务端历史失败（非致命）: $e');
      }
    }());
  }

  /// 清空服务端搜索历史（官方 Go SDK `api_user_service.go`）。
  ///
  /// ## 为什么用 POST .../Delete 而不是 DELETE 那个
  /// 两个端点语义相同（都是清空）：
  /// ```
  /// DELETE /Users/{Id}/RecentlySearched          （RESTful 风格）
  /// POST   /Users/{Id}/RecentlySearched/Delete   （Emby 的"POST + 后缀"风格）
  /// ```
  /// 本仓库既有的 toggle 用的都是 **`POST .../Delete`** 风格
  ///（见 `toggleFavorite`/`togglePlayed`，且实测该服务器有 `/emby/` 前缀
  /// 的同类路径）⇒ 保持一致，减少一个变量。
  @override
  void clearRemoteSearchHistory() {
    unawaited(() async {
      try {
        await _dio.post(
            '/Users/${session.user.id}/RecentlySearched/Delete');
      } catch (e) {
        debugPrint('[Search] 清空服务端历史失败（非致命）: $e');
      }
    }());
  }

  /// 制片公司列表（用户要求第二批第 5 项）。
  ///
  /// ## 端点依据（官方 Go SDK `api_studios_service.go`）
  /// ```
  /// localVarPath = BasePath + "/Studios"
  /// ```
  /// 参数含 `ParentId`/`UserId`/`StartIndex`/`Limit`/`Recursive`。
  ///
  /// ## ⚠️ 不过滤 `isPlayable`
  /// 公司是**浏览实体**（`Type == 'Studio'`），不是可播条目。
  /// `isPlayable` 白名单里没有它 —— 照搬那套过滤会把结果清空。
  @override
  Future<List<MediaItem>> getStudios({String? parentId, int limit = 100}) async {
    final d = _ok(await _dio.get('/Studios', queryParameters: {
      'UserId': session.user.id,
      'ParentId': ?parentId,
      'Recursive': true,
      'Limit': limit,
      'SortBy': 'SortName',
      'SortOrder': 'Ascending',
      'Fields': 'PrimaryImageAspectRatio',
    }));
    return [for (final j in _itemsList(d)) MediaItem.fromJson(j)];
  }

  /// 某制片公司的作品（用户要求第二批第 5 项）。
  ///
  /// ## 端点依据（官方 Go SDK `api_items_service.go`）
  /// `GetItemsOpts.Studios` —— 官方参数表里确认存在该参数
  ///（按制片公司名过滤）。
  @override
  Future<List<MediaItem>> getStudioItems(String studioName) async {
    final d = _ok(await _dio.get('/Users/${session.user.id}/Items',
        queryParameters: {
          'Studios': studioName,
          'Recursive': true,
          'IncludeItemTypes': 'Movie,Series',
          'SortBy': 'ProductionYear,SortName',
          'SortOrder': 'Descending,Ascending',
          'Limit': 200,
          'Fields': 'PrimaryImageAspectRatio,ProductionYear,CommunityRating,'
              'OfficialRating,UserData,Collections',
        }));
    return [for (final j in _itemsList(d)) MediaItem.fromJson(j)]
        .where((i) => i.isPlayable)
        .toList();
  }

  /// 服务端播放列表（用户要求第二批第 6 项）。
  ///
  /// ## 端点依据（官方 Go SDK `api_playlist_service.go`）
  /// ```
  /// localVarPath = BasePath + "/Playlists"
  /// ```
  /// ⚠️ 该路径**不带** `/Users/{uid}` —— 播放列表是服务端级资源，
  /// 不是用户级。带用户前缀会 404（与 `/Collections/{Id}/Items` 同类）。
  @override
  Future<List<MediaItem>> getPlaylists() async {
    final d = _ok(await _dio.get('/Playlists', queryParameters: {
      'UserId': session.user.id,
      'SortBy': 'SortName',
      'SortOrder': 'Ascending',
    }));
    return [for (final j in _itemsList(d)) MediaItem.fromJson(j)];
  }

  /// 播放列表成员（官方 SDK 的 `/Playlists/{Id}/Items`）。
  @override
  Future<List<MediaItem>> getPlaylistItems(String playlistId) async {
    final d = _ok(await _dio.get('/Playlists/$playlistId/Items',
        queryParameters: {
          'UserId': session.user.id,
          'Fields': 'PrimaryImageAspectRatio,ProductionYear,RunTimeTicks,'
              'UserData,Collections',
        }));
    return [for (final j in _itemsList(d)) MediaItem.fromJson(j)]
        .where((i) => i.isPlayable)
        .toList();
  }

  /// 即将上线（用户要求第二批第 7 项：追剧日历）。
  ///
  /// ## 端点依据（官方 Go SDK `api_tv_shows_service.go`）
  /// ```
  /// localVarPath = BasePath + "/Shows/Upcoming"
  /// ```
  ///
  /// ## 时间窗写法
  /// 官方参数是 `MinEndDate`/`MaxEndDate`（ISO8601）。这里用
  /// `MaxEndDate = now + days`，**不传** `MinEndDate`（让服务端把
  /// "已入库但还没播的"也一并给出，对追剧用户更有用）。
  ///
  /// ⚠️ 日期**必须带时区**（`toUtc().toIso8601String()`）：裸本地时间
  ///    在服务端按 UTC 解读会偏一整天。
  @override
  Future<List<MediaItem>> getUpcoming({int days = 30, int limit = 40}) async {
    final until = DateTime.now().toUtc().add(Duration(days: days));
    final d = _ok(await _dio.get('/Shows/Upcoming', queryParameters: {
      'UserId': session.user.id,
      'Limit': limit,
      'MaxEndDate': until.toIso8601String(),
      'Fields': 'PrimaryImageAspectRatio,ProductionYear,CommunityRating,'
          'UserData,SeriesId,SeasonId,IndexNumber,ParentIndexNumber',
    }));
    return [for (final j in _itemsList(d)) MediaItem.fromJson(j)];
  }

  /// 本地预告片（用户要求第一批第 2 项）。
  ///
  /// ## 端点依据（官方 Go SDK `api_user_library_service.go`）
  /// ```
  /// "/Users/{UserId}/Items/{Id}/LocalTrailers"
  /// ```
  ///
  /// ## 为什么只做 Local 不做 Remote
  /// Local 预告是**同一个 Emby 库里已有的媒体文件** ⇒ 能直接进播放器起播。
  /// Remote 是外部链接（YouTube 等）⇒ 要跳浏览器，本项目播放器不为它服务。
  @override
  Future<List<MediaItem>> getLocalTrailers(String itemId) async {
    final d = _ok(await _dio.get(
        '/Users/${session.user.id}/Items/$itemId/LocalTrailers',
        queryParameters: {
          'Fields': 'PrimaryImageAspectRatio,RunTimeTicks,ProductionYear',
        }));
    return [for (final j in _itemsList(d)) MediaItem.fromJson(j)];
  }

  /// 合集成员（用户报障："看复仇者联盟时列表没有下一部"）。
  ///
  /// ## ★★ 真机实测推翻了"官方端点一定可用"（本轮踩到）
  /// 官方 Go SDK（`api_collection_service.go`）写的是：
  /// ```
  /// localVarPath = BasePath + "/Collections/{Id}/Items"
  /// ```
  /// 但**这台服务器返回 404**。真机日志取证：
  /// ```
  /// [Detail] 取合集失败（降级为单条播放）: 服务器错误 (404)
  /// ```
  /// 而同一批改动的 `/Studios`（同样不带 `/Users` 前缀）**能正常返回**
  /// ⇒ 不是"缺前缀"这么简单，而是**该服务器/版本没有这个路由**。
  ///
  /// ## 因此改为**多策略回退**（按可用性排序，不赌单一路径）
  /// 1. `GET /Collections/{Id}/Items`（官方形状，能用的服务器走这条）
  /// 2. `GET /Users/{uid}/Items?ParentId={Id}`（**通用列表端点** +
  ///    合集 id 当父级）—— 合集体在 Emby 里本身就是个"容器"，
  ///    Emby Web 端也是这么列成员的，故这条最可能在旧服务器上可用
  /// 3. `GET /Users/{uid}/Items?ParentId={Id}&Recursive=false`（同 2，
  ///    但不递归：万一合集里嵌了子文件夹）
  ///
  /// ## 为什么要"回退"而不是"直接换掉策略 1"
  /// 不同 Emby 版本路由不同：新版本认 `/Collections`，
  /// 旧版本只认 `ParentId`。**两种都试**才能对两代服务器都对。
  /// 失败时逐个降级并打日志，便于定位是哪条成功的。
  ///
  /// ## 参数取舍（各策略共用）
  /// · `UserId`：让成员带 `UserData`（"看到 37%"）
  /// · `Fields=Collections`：为**后续跳转**保留合集体信息 ——
  ///   用户在列表里点另一部时，那一部也要知道自己的合集，
  ///   否则连播到第二部后列表就断了。
  /// · 不传 `SortBy`：合集内顺序由服务端给（通常按年份），
  ///   自己按名字重排会打乱"按剧情顺序建合集"的库。
  @override
  Future<List<MediaItem>> getCollectionItems(String collectionId) async {
    const fields = 'Collections,PrimaryImageAspectRatio,ProductionYear,'
        'CommunityRating,RunTimeTicks,Overview';

    // 策略 1：官方路径
    try {
      final d = _ok(await _dio.get('/Collections/$collectionId/Items',
          queryParameters: {'UserId': session.user.id, 'Fields': fields}));
      final items = [for (final j in _itemsList(d)) MediaItem.fromJson(j)];
      if (items.isNotEmpty) return items;
    } catch (e) {
      debugPrint('[Collection] 策略1 /Collections/{id}/Items 失败: $e');
    }

    // 策略 2：通用列表端点的 ParentId（旧服务器）
    for (final recursive in [true, false]) {
      try {
        final d = _ok(await _dio.get('/Users/${session.user.id}/Items',
            queryParameters: {
              'ParentId': collectionId,
              'Recursive': recursive,
              'Fields': fields,
            }));
        final items = [for (final j in _itemsList(d)) MediaItem.fromJson(j)];
        if (items.isNotEmpty) {
          debugPrint('[Collection] 策略2 成功（ParentId, recursive=$recursive）'
              '：${items.length} 项');
          return items;
        }
      } catch (e) {
        debugPrint('[Collection] 策略2(recursive=$recursive) 失败: $e');
      }
    }

    // 全部失败 → 空列表（调用方会降级为单条播放，不阻塞看电影）
    debugPrint('[Collection] 全部策略失败，返回空（降级为单条播放）');
    return const [];
  }

  /// 收藏 toggle（POST 收藏 / POST .../Delete 取消）
  @override
  Future<bool> toggleFavorite(String itemId, {required bool favorite}) async {
    final path = favorite
        ? '/emby/Users/${session.user.id}/FavoriteItems/$itemId'
        : '/emby/Users/${session.user.id}/FavoriteItems/$itemId/Delete';
    await _dio.post(path);
    return favorite;
  }

  /// 看过 toggle
  @override
  Future<bool> togglePlayed(String itemId, {required bool played}) async {
    final path = played
        ? '/emby/Users/${session.user.id}/PlayedItems/$itemId'
        : '/emby/Users/${session.user.id}/PlayedItems/$itemId/Delete';
    await _dio.post(path);
    return played;
  }

  @override
  Future<List<MediaChapter>> getChapters(String itemId) async {
    final d = _ok(await _dio.get('/Users/${session.user.id}/Items/$itemId',
        queryParameters: {'Fields': 'Chapters'})) as Map<String, dynamic>;
    return ((d['Chapters'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(MediaChapter.fromJson)
        .toList();
  }

  /// 解析播放直链。
  ///
  /// 实测（Emby 4.10.0.40，2026-10）：`GET /Items/{id}/PlaybackInfo?userId=` 只返回
  /// `{MediaSources, PlaySessionId}` 两个顶层字段，**不含 `TranscodingUrl`**；
  /// 即使附带 `MediaSourceId` 查询参数，服务端也只是把它作为"期望路"参考，
  /// 响应里仍会给出全部 MediaSources —— 所以下面必须自己按 id 复选。
  ///
  /// 关于转码（§7.12 遗留项）：实测该服务器 `SupportsTranscoding` 虽报 true，
  /// 但带 DeviceProfile 的 POST（EnableDirectPlay=false 强制转码）返回
  /// `SupportsTranscoding=false` 且无 `TranscodingUrl`；直连
  /// `/Videos/{id}/master.m3u8` 能拿到 200 播放列表，但 `CODECS` 仍是源编码
  /// （hvc1）——即**服务端并未真正转码**（免费版无 Premiere，转码被禁用）。
  /// 因此本客户端当前只做直连；转码分支待服务器具备转码能力后再接入。
  @override
  Future<PlaybackLaunch> resolvePlayback(String itemId,
      {String? mediaSourceId}) async {
    final d = _ok(await _dio.get('/Items/$itemId/PlaybackInfo',
        queryParameters: {
          'userId': session.user.id,
          // 指定版本时顺带带上 mediaSourceId，让服务端直接返回该路媒体源
          'mediaSourceId': ?mediaSourceId,
        })) as Map<String, dynamic>;
    final sources = ((d['MediaSources'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    if (sources.isEmpty) {
      throw const MediaException('没有可播放的媒体源');
    }
    // 多版本：优先选中调用方指定的那一路，找不到则回退第一路（服务端默认）
    var picked = sources.first;
    if (mediaSourceId case final id? when id.isNotEmpty) {
      for (final s in sources) {
        if (s['Id'] == id) {
          picked = s;
          break;
        }
      }
    }
    final ms = MediaSource.fromJson(picked);
    final video = ms.streams
        .where((s) => s.type == 'Video')
        .toList();
    final audio = ms.streams
        .where((s) => s.type == 'Audio')
        .toList();
    // 直连原文件（static=true），Range 由服务端处理
    final url = '${session.serverUrl}/Videos/$itemId/stream'
        '?static=true&mediaSourceId=${ms.id}&api_key=${session.accessToken}';
    //
    // ⚠️ 曾在此处试过"连接预热"（发一个小 Range GET 提前握手），
    //    **已删除** —— 实测证明它无效，原因是**连接池不共享**：
    //      · 预热走 Dart 的 HttpClient（dio）
    //      · 播放器走 Android HttpURLConnection / Media3 DataSource
    //    两者是完全不同的连接池，**TCP 连接不共享**，而慢启动是
    //    **按连接**的 ⇒ 预热对播放器零帮助。
    //    实测对照（n=3）：无预热 DEMUX 中位 7757ms；有预热 9757ms
    //    （无改善，且白耗 256KB 带宽）。
    //
    //    若将来要做，唯一有意义的形式是**用播放器同一条栈**预热
    //    （即通过 MethodChannel 在原生侧用 HttpURLConnection 发请求，
    //     依赖它的 keep-alive 池复用）—— 但那依赖"URL 完全一致 +
    //    池未驱逐"，脆弱，收益不确定，暂不做。

    // 转码兜底（硬解直连优先，转码是最后手段）：
    // Emby 标准 HLS master 播放列表，libmpv 原生可播；限制到 h264/aac 1080p。
    final transcode = '${session.serverUrl}/Videos/$itemId/master.m3u8'
        '?MediaSourceId=${ms.id}&api_key=${session.accessToken}'
        '&VideoCodec=h264&AudioCodec=aac,mp3'
        '&TranscodingMaxAudioChannels=2&SegmentContainer=mp4'
        '&MinSegments=1&BreakOnNonKeyFrames=True'
        '&h264-profile=high,main,baseline&h264-level=52'
        '&VideoBitrate=8000000&AudioBitrate=192000';
    return PlaybackLaunch(
      url: url,
      itemId: itemId,
      mediaSourceId: ms.id,
      playSessionId: uuidV4(),
      videoLabel: video.isNotEmpty ? video.first.label : null,
      audioLabel: audio.isNotEmpty ? audio.first.label : null,
      container: ms.container,
      transcodingUrl: transcode,
      bitrate: ms.bitrate,
      // ★ 把服务端的完整流列表交给播放器（用户指出的"致命问题"的正解）：
      //   播放器此前只问 mpv 要轨道，字段更少、名字更差。
      //   服务端 `DisplayTitle` 已拼好（`Chinese Simplified (PGSSUB)` 等），
      //   且带 `Index` 可与内核轨道对应、带 `IsDefault` 表明默认轨。
      streams: ms.streams,
      defaultAudioIndex: ms.defaultAudioStreamIndex,
      defaultSubtitleIndex: ms.defaultSubtitleStreamIndex,
      // 章节随 launch 带来：播放器不必再单独发一次 getChapters 请求
      chapters: ms.chapters,
      // 服务端要求的额外头（多数情况为空）必须透传给内核，否则可能 403
      headers: ms.requiredHttpHeaders,
    );
  }

  Map<String, dynamic> _reportBody({
    required String itemId,
    required String playSessionId,
    required String mediaSourceId,
    required int positionTicks,
    bool? paused,
    double? rate,
    String? eventName,
  }) =>
      {
        'ItemId': itemId,
        'PlaySessionId': playSessionId,
        'MediaSourceId': mediaSourceId,
        'PositionTicks': positionTicks,
        'IsPaused': ?paused,
        'PlaybackRate': ?rate,
        // 上报原因。官方文档要求"用户交互后立即上报"时带此字段，
        // 服务端据此校准自动进度递增（如拖动后必须立刻纠正）。
        // 定时上报用 `TimeUpdate`；Start/Stopped 不需要它。
        'EventName': ?eventName,
        'PlayMethod': 'DirectStream',
        'CanSeek': true,
        'VolumeLevel': 100,
      };

  void _fire(Future<void> fut) {
    unawaited(fut.catchError((_) {}));
  }

  /// 持久化条目进度。实测：`POST …/UserData` → **204**（无响应体）；
  /// `GET …/UserData` → 404，故读进度只能从条目详情里的 `UserData` 取。
  /// 只传需要改的字段，避免把未在意的状态（如 Played）顺带覆盖。
  @override
  void reportItemProgress({
    required String itemId,
    required int positionTicks,
    bool? played,
  }) {
    _fire(_dio.post('/Users/${session.user.id}/Items/$itemId/UserData',
        data: {
          'PlaybackPositionTicks': positionTicks < 0 ? 0 : positionTicks,
          'Played': ?played,
        }));
  }

  @override
  void reportPlaybackStart(
          {required String itemId,
          required String playSessionId,
          required String mediaSourceId,
          required int positionTicks}) =>
      _fire(_dio.post('/Sessions/Playing', data: _reportBody(
          itemId: itemId,
          playSessionId: playSessionId,
          mediaSourceId: mediaSourceId,
          positionTicks: positionTicks)));

  @override
  void reportPlaybackProgress(
          {required String itemId,
          required String playSessionId,
          required String mediaSourceId,
          required int positionTicks,
          required bool paused,
          double rate = 1,
          String? eventName}) =>
      _fire(_dio.post('/Sessions/Playing/Progress', data: _reportBody(
          itemId: itemId,
          playSessionId: playSessionId,
          mediaSourceId: mediaSourceId,
          positionTicks: positionTicks,
          paused: paused,
          rate: rate,
          eventName: eventName)));

  @override
  void reportPlaybackStop(
          {required String itemId,
          required String playSessionId,
          required String mediaSourceId,
          required int positionTicks}) =>
      _fire(_dio.post('/Sessions/Playing/Stopped', data: _reportBody(
          itemId: itemId,
          playSessionId: playSessionId,
          mediaSourceId: mediaSourceId,
          positionTicks: positionTicks)));
}
