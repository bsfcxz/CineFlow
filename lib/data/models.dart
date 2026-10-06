/// Emby 数据模型 —— 防御式解析：字段缺失/为空是常态（多服务器实测归纳）
library;

import 'media_provider.dart' show MediaProvider;

class MediaUser {
  final String id;
  final String name;
  final String? primaryImageTag;

  const MediaUser({required this.id, required this.name, this.primaryImageTag});

  factory MediaUser.fromJson(Map<String, dynamic> j) => MediaUser(
        id: j['Id'] as String? ?? '',
        name: j['Name'] as String? ?? '',
        primaryImageTag: j['PrimaryImageTag'] as String?,
      );

  Map<String, dynamic> toJson() =>
      {'Id': id, 'Name': name, 'PrimaryImageTag': primaryImageTag};
}

/// 已登录会话（持久化到 flutter_secure_storage）
class MediaSession {
  final String serverUrl; // 无尾部斜杠
  final String accessToken;
  final MediaUser user;
  final String deviceId;

  const MediaSession({
    required this.serverUrl,
    required this.accessToken,
    required this.user,
    required this.deviceId,
  });

  factory MediaSession.fromJson(Map<String, dynamic> j) => MediaSession(
        serverUrl: j['serverUrl'] as String? ?? '',
        accessToken: j['accessToken'] as String? ?? '',
        user: MediaUser.fromJson(
            (j['user'] as Map<String, dynamic>? ?? const {})),
        deviceId: j['deviceId'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'serverUrl': serverUrl,
        'accessToken': accessToken,
        'user': user.toJson(),
        'deviceId': deviceId,
      };
}

class MediaView {
  final String id;
  final String name;
  final String? collectionType; // movies / tvshows / boxsets / livetv ...
  final String? primaryImageTag;

  const MediaView({
    required this.id,
    required this.name,
    this.collectionType,
    this.primaryImageTag,
  });

  factory MediaView.fromJson(Map<String, dynamic> j) => MediaView(
        id: j['Id'] as String? ?? '',
        name: j['Name'] as String? ?? '',
        collectionType: j['CollectionType'] as String?,
        primaryImageTag:
            (j['ImageTags'] as Map<String, dynamic>?)?['Primary'] as String?,
      );
}

class MediaItem {
  final String id;
  final String name;
  final String type; // Movie / Episode / Series / BoxSet ...
  final bool isFolder;
  final String? seriesName;
  final String? seriesId;

  /// 所属季的 Id（服务端在 Episode 上直接给 `SeasonId`）。
  ///
  /// 加它是因为 `/Shows/NextUp` 返回的分集**只带 `SeasonId`**，
  /// 要靠它定位"这一集属于哪一季"，才能拉对应季的分集列表给播放器。
  final String? seasonId;

  final int? parentIndexNumber; // 季号
  final int? indexNumber; // 集号
  final int? productionYear;
  final double? communityRating;
  final String? officialRating;
  final List<String> genres;
  final String? overview;
  final int? runtimeTicks;
  final bool played;
  final bool isFavorite;
  final double? playedPercentage; // 服务端可能为 null，用 positionTicks 兜底
  final int? positionTicks;

  /// 未看过的子项数（剧集的"还剩几集没看"）。
  ///
  /// ★ 这是判断**剧集是否看过**的可靠字段。实测（本服务器）：
  /// `Series.UserData` 恒为 `Played=false, PlaybackPositionTicks=0`
  /// —— 因为进度记在 **Episode** 上，剧集本身没有"播放位置"这个概念。
  /// 但 `Series.UserData.UnplayedItemCount` 会给真实值（实测 16）。
  ///
  /// 因此：**`unplayedItemCount < 总集数` ⇒ 至少看过一集**，
  /// 详情页据此把「立即播放」换成「继续播放」。
  final int? unplayedItemCount;
  final Map<String, String> imageTags;
  final List<String> backdropImageTags;
  final String? parentBackdropItemId;
  final List<String> parentBackdropImageTags;
  final String? parentThumbItemId;
  final String? parentThumbImageTag;
  final String? seriesPrimaryImageTag;

  const MediaItem({
    required this.id,
    required this.name,
    required this.type,
    this.isFolder = false,
    this.seriesName,
    this.seriesId,
    this.seasonId,
    this.parentIndexNumber,
    this.indexNumber,
    this.productionYear,
    this.communityRating,
    this.officialRating,
    this.genres = const [],
    this.overview,
    this.runtimeTicks,
    this.played = false,
    this.isFavorite = false,
    this.playedPercentage,
    this.positionTicks,
    this.unplayedItemCount,
    this.imageTags = const {},
    this.backdropImageTags = const [],
    this.parentBackdropItemId,
    this.parentBackdropImageTags = const [],
    this.parentThumbItemId,
    this.parentThumbImageTag,
    this.seriesPrimaryImageTag,
  });

  factory MediaItem.fromJson(Map<String, dynamic> j) {
    final ud = j['UserData'] as Map<String, dynamic>?;
    String? parentBackdropId = j['ParentBackdropItemId'] as String?;
    List<String> parentBackdropTags =
        ((j['ParentBackdropImageTags'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList();
    return MediaItem(
      id: j['Id'] as String? ?? '',
      name: j['Name'] as String? ?? '',
      type: j['Type'] as String? ?? '',
      isFolder: j['IsFolder'] == true,
      seriesName: j['SeriesName'] as String?,
      seriesId: j['SeriesId'] as String?,
      seasonId: j['SeasonId'] as String?,
      parentIndexNumber: (j['ParentIndexNumber'] as num?)?.toInt(),
      indexNumber: (j['IndexNumber'] as num?)?.toInt(),
      productionYear: (j['ProductionYear'] as num?)?.toInt(),
      communityRating: (j['CommunityRating'] as num?)?.toDouble(),
      officialRating: j['OfficialRating'] as String?,
      genres: ((j['Genres'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      overview: j['Overview'] as String?,
      runtimeTicks: (j['RunTimeTicks'] as num?)?.toInt(),
      played: ud?['Played'] == true,
      isFavorite: ud?['IsFavorite'] == true,
      playedPercentage: (ud?['PlayedPercentage'] as num?)?.toDouble(),
      positionTicks: (ud?['PositionTicks'] as num?)?.toInt(),
      unplayedItemCount: (ud?['UnplayedItemCount'] as num?)?.toInt(),
      imageTags: ((j['ImageTags'] as Map<String, dynamic>?) ?? const {})
          .cast<String, String>(),
      backdropImageTags: ((j['BackdropImageTags'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      parentBackdropItemId: parentBackdropId,
      parentBackdropImageTags: parentBackdropTags,
      parentThumbItemId: j['ParentThumbItemId'] as String?,
      parentThumbImageTag: j['ParentThumbImageTag'] as String?,
      seriesPrimaryImageTag: j['SeriesPrimaryImageTag'] as String?,
    );
  }

  /// 可播放 / 可浏览的媒体条目。
  ///
  /// ## ⚠️ 口径必须与 Go 侧 `media.IsPlayable` 一致
  ///
  /// 改造前这里是 `type == 'Movie' || type == 'Episode'` —— **漏了 `Series`**，
  /// 而 Go 侧（`go/internal/media/filter.go`）是
  /// `Movie/Episode/Video/MusicVideo/Trailer/**Series**`。
  /// 同一个概念两套口径，后果很实在：
  ///
  /// **实测缺陷**（用户真实库）：该库"最近添加"几乎全是剧集（`Series`），
  /// 于是 `/Latest` 的 24 条被这行过滤成 **1 条**，首页出现 940px 空白带（占屏 39%）。
  ///
  /// `Series` 保留是**正确**的：它是合法浏览入口，详情页有专门分支
  /// （`detail_page.dart` 的 `isSeries`，且它被**排除**在"可浏览文件夹"之外），
  /// 真正起播时会下钻到 `Episode`。
  bool get isPlayable =>
      type == 'Movie' ||
      type == 'Episode' ||
      type == 'Series' ||
      type == 'Video' ||
      type == 'MusicVideo' ||
      type == 'Trailer';

  /// 轮播 / 卡片主标题：剧集条目显示剧名（对齐原型）
  String get displayTitle => type == 'Episode' ? (seriesName ?? name) : name;

  String? get seasonEpisode =>
      (parentIndexNumber != null && indexNumber != null)
          ? 'S$parentIndexNumber E$indexNumber'
          : null;

  String get typeLabel => switch (type) {
        'Movie' => '电影',
        'Episode' || 'Series' => '剧集',
        _ => '影片',
      };

  /// 播放进度 0~1（PlayedPercentage 缺失时用 PositionTicks/RunTimeTicks 推算）
  double get progress {
    final p = playedPercentage;
    if (p != null && p > 0) return (p / 100).clamp(0.0, 1.0);
    final pos = positionTicks;
    if (pos != null &&
        pos > 0 &&
        runtimeTicks != null &&
        runtimeTicks! > 0) {
      return (pos / runtimeTicks!).clamp(0.0, 1.0);
    }
    return 0;
  }

  int? get remainingMinutes =>
      (runtimeTicks != null && progress > 0 && progress < 1)
          ? ((runtimeTicks! / 600000000) * (1 - progress)).round()
          : null;

  /// 剧集**自身**完全没有播放位置 —— 进度记在 Episode 上。
  ///
  /// 实测（本服务器）：`Series.UserData` 恒为
  /// `{"Played":false,"PlaybackPositionTicks":0,"UnplayedItemCount":16}`。
  /// 所以判断"这部剧看过没"**必须下钻到分集**。
  bool get needsEpisodeProgress => type == 'Series';
}

/// 「看到第几集了」—— **已移除：改用服务端 `/Shows/NextUp`**。
///
/// 这里曾有 91 行自写逻辑（`SeriesProgress.resolve` + `SeriesResume`）：
/// 拉全部分集、遍历各自 `UserData`、推断"用户停在第几集"。
///
/// ## 为什么删掉（用户指出的"致命问题"）
///
/// > "这些东西本来你应该能够从 emby 服务端全部拿到。"
///
/// Emby 有专门的端点直接回答这个问题：
/// `GET /Shows/NextUp?UserId=…&SeriesId=…`
/// 实测（本服务器）返回 S1E9/E10/E11（带 `UserData`），**1 次请求**。
/// 而自写版本要 **2 次请求**（分季 + 分集），且边界处理更差 ——
/// 服务端有完整观看历史，能正确处理"跳着看""看完最后一集"
/// "看了几分钟就退出"等情况，客户端遍历很难覆盖全。
///
/// 现由 `MediaProvider.getNextUp(seriesId)` 提供，调用点见 `detail_page._playSeries`。
/// **不要再加回来** —— 那等于重新发明一个更差的轮子。
/// 图片地址便捷解析：自身图缺失时逐级回退到父级/剧集图
extension MediaItemImages on MediaItem {  /// 海报（2:3）
  String? posterUrl(MediaProvider api, {int maxWidth = 320}) {
    final t = imageTags['Primary'];
    if (t != null && t.isNotEmpty) {
      return api.imageUrl(id, tag: t, maxWidth: maxWidth);
    }
    if (parentThumbItemId case final ptid? when (parentThumbImageTag ?? '').isNotEmpty) {
      return api.imageUrl(ptid, type: 'Thumb', tag: parentThumbImageTag, maxWidth: maxWidth);
    }
    if (parentBackdropItemId case final pbid? when parentBackdropImageTags.isNotEmpty) {
      return api.imageUrl(pbid, type: 'Backdrop', tag: parentBackdropImageTags.first, maxWidth: maxWidth);
    }
    if (seriesId case final sid? when (seriesPrimaryImageTag ?? '').isNotEmpty) {
      return api.imageUrl(sid, tag: seriesPrimaryImageTag, maxWidth: maxWidth);
    }
    return null;
  }

  /// 横图（16:9，继续观看卡片）：Thumb → Primary → 父级回退
  String? thumbUrl(MediaProvider api, {int maxWidth = 480}) {
    final t = imageTags['Thumb'];
    if (t != null && t.isNotEmpty) {
      return api.imageUrl(id, type: 'Thumb', tag: t, maxWidth: maxWidth);
    }
    return posterUrl(api, maxWidth: maxWidth);
  }

  /// 背景大图（轮播）
  String? backdropUrl(MediaProvider api, {int maxWidth = 720}) {
    if (backdropImageTags.isEmpty) return null;
    return api.imageUrl(id, type: 'Backdrop', tag: backdropImageTags.first, maxWidth: maxWidth);
  }
}

/// 详情页数据 = 基础条目 + 演职员 + 媒体源（多版本/流信息）
class MediaItemDetail {
  final MediaItem item;
  final String? tagline;
  final List<String> studios;
  final List<MediaPerson> people;
  final List<MediaSource> mediaSources;

  const MediaItemDetail({
    required this.item,
    this.tagline,
    this.studios = const [],
    this.people = const [],
    this.mediaSources = const [],
  });

  factory MediaItemDetail.fromJson(Map<String, dynamic> j) => MediaItemDetail(
        item: MediaItem.fromJson(j),
        tagline: j['Taglines'] is List && (j['Taglines'] as List).isNotEmpty
            ? (j['Taglines'] as List).first.toString()
            : null,
        // ⚠️ 原为 `.map((e) => (e as Map<String, dynamic>)['Name'].toString())`
        // —— **非空断言**，违反 AGENTS §5.3（不允许对服务器字段做非空断言）。
        // 若 Studios 里混入非 map 元素（或 Name 缺失）会直接抛异常，
        // 导致**整个详情页加载失败**。旁边 People/MediaSources 都用了
        // `.whereType<...>()`，这里统一过来。
        studios: ((j['Studios'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map((e) => (e['Name'] ?? '').toString())
            .where((s) => s.isNotEmpty)
            .toList(),
        people: ((j['People'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(MediaPerson.fromJson)
            .toList(),
        mediaSources: ((j['MediaSources'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(MediaSource.fromJson)
            .toList(),
      );
}

class MediaPerson {
  final String id;
  final String name;
  final String? role;
  final String type; // Actor / Director ...
  final String? primaryImageTag;

  const MediaPerson({
    required this.id,
    required this.name,
    this.role,
    required this.type,
    this.primaryImageTag,
  });

  factory MediaPerson.fromJson(Map<String, dynamic> j) => MediaPerson(
        id: j['Id'] as String? ?? '',
        name: j['Name'] as String? ?? '',
        role: j['Role'] as String?,
        type: j['Type'] as String? ?? '',
        primaryImageTag: j['PrimaryImageTag'] as String?,
      );
}

/// 演职员的筛选/排序规则（纯函数，便于单元测试）。
///
/// 实测：Emby 的 `People[].Type` 取值包括 `Actor` / `Director` / `Writer` /
/// `Producer` / `GuestStar` 等；详情页曾只渲染 `Actor`，导致导演等职位即使
/// 服务器已返回也被丢弃（AGENTS.md §7.14）。
extension MediaPeople on List<MediaPerson> {
  /// 演员（含客串），按服务器返回顺序取前 [limit] 位
  List<MediaPerson> actors({int limit = 12}) => where((p) => p.type == 'Actor')
      .take(limit)
      .toList();

  /// 导演。去重并保序——同一人可能因多段署名重复出现
  List<MediaPerson> directors({int limit = 6}) {
    final seen = <String>{};
    return where((p) => p.type == 'Director')
        .where((p) => seen.add(p.id.isEmpty ? p.name : p.id))
        .take(limit)
        .toList();
  }

  /// 编剧
  List<MediaPerson> writers({int limit = 4}) {
    final seen = <String>{};
    return where((p) => p.type == 'Writer')
        .where((p) => seen.add(p.id.isEmpty ? p.name : p.id))
        .take(limit)
        .toList();
  }

  /// 职位摘要行：「导演 张三 / 李四」；无导演时回退编剧；都没有则返回 null
  String? crewLine() {
    final ds = directors();
    if (ds.isNotEmpty) return '导演 ${ds.map((p) => p.name).join(' / ')}';
    final ws = writers();
    if (ws.isNotEmpty) return '编剧 ${ws.map((p) => p.name).join(' / ')}';
    return null;
  }
}

class MediaSource {
  final String id;
  final String? name; // 版本名
  final String? container;
  final int? size; // 字节
  final int? bitrate; // 总码率 bps
  final List<MediaStream> streams;

  // ---- 按官方 SDK（MediaSourceInfo）补齐 ----

  /// 服务端指定的**默认音频流索引**（对应 `MediaStream.index`）。
  /// 用它选初始音轨，而不是猜第一条。
  final int? defaultAudioStreamIndex;

  /// 服务端指定的**默认字幕流索引**。为 null 表示默认不开字幕。
  final int? defaultSubtitleStreamIndex;

  /// 服务端报告的直链播放能力（本服务器实测均为 true）
  final bool supportsDirectPlay;
  final bool supportsDirectStream;
  final bool supportsTranscoding;

  /// 时长（ticks）—— 与 `MediaItem.runTimeTicks` 可能有细微差别
  final int? runTimeTicks;

  /// 播放该源所需的 HTTP 头（服务端要求时非空）
  final Map<String, String> requiredHttpHeaders;

  /// 章节（服务端把章节放在 MediaSource 里，而不是独立端点）
  final List<MediaChapter> chapters;

  const MediaSource({
    required this.id,
    this.name,
    this.container,
    this.size,
    this.bitrate,
    this.streams = const [],
    this.defaultAudioStreamIndex,
    this.defaultSubtitleStreamIndex,
    this.supportsDirectPlay = false,
    this.supportsDirectStream = false,
    this.supportsTranscoding = false,
    this.runTimeTicks,
    this.requiredHttpHeaders = const {},
    this.chapters = const [],
  });

  factory MediaSource.fromJson(Map<String, dynamic> j) => MediaSource(
        id: j['Id'] as String? ?? '',
        name: j['Name'] as String?,
        container: j['Container'] as String?,
        size: (j['Size'] as num?)?.toInt(),
        bitrate: (j['Bitrate'] as num?)?.toInt(),
        streams: ((j['MediaStreams'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(MediaStream.fromJson)
            .toList(),
        defaultAudioStreamIndex:
            (j['DefaultAudioStreamIndex'] as num?)?.toInt(),
        defaultSubtitleStreamIndex:
            (j['DefaultSubtitleStreamIndex'] as num?)?.toInt(),
        supportsDirectPlay: j['SupportsDirectPlay'] == true,
        supportsDirectStream: j['SupportsDirectStream'] == true,
        supportsTranscoding: j['SupportsTranscoding'] == true,
        runTimeTicks: (j['RunTimeTicks'] as num?)?.toInt(),
        requiredHttpHeaders:
            ((j['RequiredHttpHeaders'] as Map?) ?? const {})
                .map((k, v) => MapEntry('$k', '$v')),
        // 章节就在 MediaSource 里 —— 实测 `/Items/{id}/Chapters` 返回 404，
        // 服务端只在 PlaybackInfo / 详情（Fields=Chapters）里给。
        chapters: ((j['Chapters'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(MediaChapter.fromJson)
            .toList(),
      );

  /// 音轨列表（按 `index` 升序，与服务端顺序一致）
  List<MediaStream> get audioStreams =>
      streams.where((s) => s.type == 'Audio').toList();

  /// 字幕轨列表
  List<MediaStream> get subtitleStreams =>
      streams.where((s) => s.type == 'Subtitle').toList();

  /// 视频流（通常只有一条）
  List<MediaStream> get videoStreams =>
      streams.where((s) => s.type == 'Video').toList();

  /// 服务端指定的默认音轨（找不到时回退第一条）
  MediaStream? get defaultAudio {
    final a = audioStreams;
    if (a.isEmpty) return null;
    final idx = defaultAudioStreamIndex;
    if (idx == null) return a.first;
    return a.firstWhere((s) => s.index == idx, orElse: () => a.first);
  }

  String get sizeLabel {
    final s = size;
    if (s == null || s <= 0) return '';
    if (s >= 1073741824) return '${(s / 1073741824).toStringAsFixed(1)} GB';
    return '${(s / 1048576).round()} MB';
  }

  String get versionLabel =>
      (name == null || name!.isEmpty) ? (container ?? '默认版本') : name!;
}

class MediaStream {
  final String type; // Video / Audio / Subtitle
  final String? displayTitle;
  final String? codec;
  final String? language;

  /// 服务端给出的**可读语言名**（如 "Chinese"）——
  /// 优先于裸语言码 `Language`（`chi`），直接用即可，无需自己映射。
  final String? displayLanguage;

  final int? height;
  final int? width;
  final int? channels;
  final bool isDefault;
  final String? videoRange; // SDR / HDR10 / DOVI ...

  // ---- 以下为按官方 SDK 定义补齐的字段（用户指出的"致命问题"）----
  //
  // 官方定义见 `MediaBrowser/Emby.ApiClients` →
  // `Clients/Swift5/.../MediaStream.swift`，共 **56 个字段**；
  // 本项目原先只解析 9 个，于是只能去问播放内核 mpv 再自己拼名字，
  // 而 mpv 的字段更少（没有 DisplayLanguage、没有"默认"标记）→ 结果更差。

  /// **流索引** —— 与服务端 `DefaultAudioStreamIndex` /
  /// `DefaultSubtitleStreamIndex` 对应，语义是 **ffmpeg 的全局流索引**
  /// （官方 swagger：`The index of the stream inside its container.
  /// Probe Field: index`）。
  ///
  /// ## ⚠️ 它 **不是** mpv 的 `aid`/`sid`（这是容易搞错的地方）
  ///
  /// mpv 的 `aid`/`sid` 是**每种类型独立从 1 开始编号**的
  /// （mpv 文档：`unique within tracks of the same type`）。
  /// 典型 MKV（video=0, audio=1, sub=2）下两者会**错位**：
  ///   · Emby `Index`：video=0, audio=1, sub=2
  ///   · mpv  `aid`/`sid`：audio=1, sub=1   ← 注意 sub 是 1 而不是 2
  ///
  /// 想跨这两套编号对齐，唯一可靠的键是 mpv 的 **`ff-index`**
  /// （mpv 文档：`The stream index as usually used by the FFmpeg utilities`），
  /// 它才与 Emby 的 `Index` 同源。见 `KernelTrack.ffIndex`。
  ///
  /// > 教训：本条注释的初版写成"也是播放器内核 aid/sid 的对照键"——**那是错的**，
  /// > 会导致多轨片源**切错轨**。经 Emby 官方 swagger + mpv 官方文档比对后修正。
  final int? index;

  /// 轨道原始标题（片源里写的，如"评论音轨"）
  final String? title;

  /// 声道布局（如 `stereo` / `5.1`）—— 比裸 `channels` 更好读
  final String? channelLayout;

  /// 是否强制字幕
  final bool isForced;

  /// 是否外挂
  final bool isExternal;

  /// 是否听障辅助轨
  final bool isHearingImpaired;

  /// 码率（bps）
  final int? bitRate;

  /// 采样率（Hz）
  final int? sampleRate;

  /// 编码档次与级别（如 `High` / `4.1`）
  final String? profile;
  final double? level;

  /// 视频动态范围扩展（如 `DolbyVision` / `Hdr10`）——
  /// 比 `videoRange` 更细，用于详情页标注杜比视界
  final String? extendedVideoType;
  final String? extendedVideoSubTypeDescription;

  /// 是否文本字幕（文本可调样式；PGS/VOBSUB 等图形字幕不可）
  final bool isTextSubtitleStream;

  final int? bitDepth;
  final double? averageFrameRate;

  const MediaStream({
    required this.type,
    this.displayTitle,
    this.codec,
    this.language,
    this.displayLanguage,
    this.height,
    this.width,
    this.channels,
    this.isDefault = false,
    this.videoRange,
    this.index,
    this.title,
    this.channelLayout,
    this.isForced = false,
    this.isExternal = false,
    this.isHearingImpaired = false,
    this.bitRate,
    this.sampleRate,
    this.profile,
    this.level,
    this.extendedVideoType,
    this.extendedVideoSubTypeDescription,
    this.isTextSubtitleStream = false,
    this.bitDepth,
    this.averageFrameRate,
  });

  factory MediaStream.fromJson(Map<String, dynamic> j) => MediaStream(
        type: j['Type'] as String? ?? '',
        displayTitle: j['DisplayTitle'] as String?,
        codec: j['Codec'] as String?,
        language: j['DisplayLanguage'] as String? ?? j['Language'] as String?,
        displayLanguage: j['DisplayLanguage'] as String?,
        height: (j['Height'] as num?)?.toInt(),
        width: (j['Width'] as num?)?.toInt(),
        channels: (j['Channels'] as num?)?.toInt(),
        isDefault: j['IsDefault'] == true,
        videoRange: j['VideoRange'] as String? ?? j['VideoRangeType'] as String?,
        index: (j['Index'] as num?)?.toInt(),
        title: j['Title'] as String?,
        channelLayout: j['ChannelLayout'] as String?,
        isForced: j['IsForced'] == true,
        isExternal: j['IsExternal'] == true,
        isHearingImpaired: j['IsHearingImpaired'] == true,
        bitRate: (j['BitRate'] as num?)?.toInt(),
        sampleRate: (j['SampleRate'] as num?)?.toInt(),
        profile: j['Profile'] as String?,
        level: (j['Level'] as num?)?.toDouble(),
        extendedVideoType: j['ExtendedVideoType'] as String?,
        extendedVideoSubTypeDescription:
            j['ExtendedVideoSubTypeDescription'] as String?,
        isTextSubtitleStream: j['IsTextSubtitleStream'] == true,
        bitDepth: (j['BitDepth'] as num?)?.toInt(),
        averageFrameRate: (j['AverageFrameRate'] as num?)?.toDouble(),
      );

  /// **用户可读的轨道名** —— 优先用服务端拼好的 `DisplayTitle`。
  ///
  /// 服务端的 `DisplayTitle` 已包含语言 + 编码 + 声道 + 「(默认)」标记，
  /// 例如 `Chinese Simplified (PGSSUB)`、`Mandarin EAC3 5.1 (默认)`。
  /// **不要自己拼** —— 本项目踩过这个坑：自己拼只能得到更差的结果
  /// （服务端给 `Chinese Simplified`，自己拼出 `中文 · 2ch · aac`）。
  ///
  /// 仅当服务端缺失 `DisplayTitle` 时才退回自拼。
  String get label {
    final dt = displayTitle?.trim();
    if (dt != null && dt.isNotEmpty) return dt;

    final parts = <String>[];
    final t = title?.trim();
    if (t != null && t.isNotEmpty) parts.add(t);
    final lang = displayLanguage?.trim();
    if (lang != null && lang.isNotEmpty) parts.add(lang);
    final layout = channelLayout?.trim();
    if (layout != null && layout.isNotEmpty) {
      parts.add(layout);
    } else if (channels != null && channels! > 0) {
      parts.add('${channels!}ch');
    }
    final c = codec?.trim();
    if (c != null && c.isNotEmpty) parts.add(c);
    if (isForced) parts.add('强制');
    if (isExternal) parts.add('外挂');
    return parts.isEmpty ? type : parts.join(' · ');
  }
}

/// 分页浏览结果
class ItemPage {
  final List<MediaItem> items;
  final int total;
  const ItemPage({required this.items, required this.total});
}

/// 章节标记（进度条刻度 / 跳过片头识别）
class MediaChapter {
  final String name;
  final int startPositionTicks;

  /// **章节标记类型** —— Emby 的**原生片头/片尾检测**。
  ///
  /// 官方 `MarkerType` 枚举：`Chapter` | `IntroStart` | `IntroEnd` | `CreditsStart`。
  ///
  /// ## 为什么必须有它（实测推翻了旧注释）
  ///
  /// 本项目 `player_page._detectIntro` 的注释曾写
  /// **"Emby 无原生片头检测，用名称匹配"** —— **那是错的**。
  ///
  /// 实测本服务器（Emby 4.10）某剧集章节：
  /// `Chapter, IntroStart, IntroEnd, Chapter, Chapter, …`
  /// —— 服务端**早已标好**片头区间，而客户端却在猜章节名里有没有"片头"/"intro"。
  ///
  /// 字符串匹配的典型失效场景：
  ///   · 叫"主题曲"/"OP"/"序章"就**识别不到**
  ///   · 叫"片头曲欣赏""片头解析"的普通章节会被**误跳**
  final String? markerType;

  const MediaChapter({
    required this.name,
    required this.startPositionTicks,
    this.markerType,
  });

  factory MediaChapter.fromJson(Map<String, dynamic> j) => MediaChapter(
        name: j['Name'] as String? ?? '',
        startPositionTicks: (j['StartPositionTicks'] as num?)?.toInt() ?? 0,
        markerType: j['MarkerType'] as String?,
      );

  double get seconds => startPositionTicks / 10000000;

  /// 是否为片头起点（服务端标记）
  bool get isIntroStart => markerType == 'IntroStart';

  /// 是否为片头终点
  bool get isIntroEnd => markerType == 'IntroEnd';

  /// 是否为片尾起点
  bool get isCreditsStart => markerType == 'CreditsStart';
}