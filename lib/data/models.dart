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

  /// 可播放条目（服务端类型筛选不可信，客户端复筛用）
  bool get isPlayable => type == 'Movie' || type == 'Episode';

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
}

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
        studios: ((j['Studios'] as List?) ?? const [])
            .map((e) => (e as Map<String, dynamic>)['Name'].toString())
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

  const MediaSource({
    required this.id,
    this.name,
    this.container,
    this.size,
    this.bitrate,
    this.streams = const [],
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
      );

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
  final int? height;
  final int? width;
  final int? channels;
  final bool isDefault;
  final String? videoRange; // SDR / HDR10 / DOVI ...

  const MediaStream({
    required this.type,
    this.displayTitle,
    this.codec,
    this.language,
    this.height,
    this.width,
    this.channels,
    this.isDefault = false,
    this.videoRange,
  });

  factory MediaStream.fromJson(Map<String, dynamic> j) => MediaStream(
        type: j['Type'] as String? ?? '',
        displayTitle: j['DisplayTitle'] as String?,
        codec: j['Codec'] as String?,
        language: j['DisplayLanguage'] as String? ?? j['Language'] as String?,
        height: (j['Height'] as num?)?.toInt(),
        width: (j['Width'] as num?)?.toInt(),
        channels: (j['Channels'] as num?)?.toInt(),
        isDefault: j['IsDefault'] == true,
        videoRange: j['VideoRange'] as String? ?? j['VideoRangeType'] as String?,
      );
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

  const MediaChapter({required this.name, required this.startPositionTicks});

  factory MediaChapter.fromJson(Map<String, dynamic> j) => MediaChapter(
        name: j['Name'] as String? ?? '',
        startPositionTicks: (j['StartPositionTicks'] as num?)?.toInt() ?? 0,
      );

  double get seconds => startPositionTicks / 10000000;
}
