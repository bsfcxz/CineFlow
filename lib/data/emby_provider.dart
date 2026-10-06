/// Emby 协议实现（当前阶段的 MediaProvider）
/// 踩坑对策源自多服务器实测，见各方法注释。
library;
import 'dart:async';

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
              'PrimaryImageAspectRatio,ProductionYear,OfficialRating,CommunityRating,Genres,Overview,DateCreated',
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
          'Fields': 'PrimaryImageAspectRatio,BasicSyncInfo',
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
    final d = _ok(await _dio.get('/Users/${session.user.id}/Items',
        queryParameters: {
          'SearchTerm': keyword,
          'Limit': limit,
          'Recursive': true,
          'IncludeItemTypes': 'Movie,Episode',
          'Fields':
              'PrimaryImageAspectRatio,ProductionYear,OfficialRating,CommunityRating',
          'MediaTypes': 'Video',
        }));
    // ⚠️ 实测：服务端无视类型筛选 → 客户端复筛
    final items = [for (final j in _itemsList(d)) MediaItem.fromJson(j)];
    return items.where((i) => i.isPlayable).toList();
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
              'PrimaryImageAspectRatio,ProductionYear,OfficialRating,CommunityRating,UserData',
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
              'MediaSources,People,Studios,Genres,Overview,Taglines,ProductionYear,OfficialRating,CommunityRating',
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
    // 注意：Emby 的 Similar 路径不带 /Users/{uid}（实测 404 对比确认）
    final d = _ok(await _dio.get('/Items/$itemId/Similar', queryParameters: {
      'userId': session.user.id,
      'Limit': 12,
      'Fields': 'PrimaryImageAspectRatio,ProductionYear,CommunityRating',
    }));
    return [for (final j in _itemsList(d)) MediaItem.fromJson(j)];
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
