/// 统一媒体源抽象层 —— 对应《CineFlow 可行性计划书》04 节。
/// UI 层只依赖此抽象；当前实现 EmbyProvider，未来 Pan115Provider 在此扩展，UI 无需改动。
library;
import 'models.dart';

abstract interface class MediaProvider {
  /// 媒体库（Views）
  Future<List<MediaView>> getViews();

  /// 最近添加（服务端过滤不可信，实现方必须客户端复筛）
  Future<List<MediaItem>> getLatest({int limit});

  /// 继续观看（Emby Resume）
  Future<List<MediaItem>> getResume({int limit});

  /// 图片直链
  String imageUrl(String itemId,
      {String type = 'Primary', int position = 0, String? tag, int maxWidth});

  /// 搜索（步骤 4 启用）
  Future<List<MediaItem>> search(String keyword, {int limit});

  /// 分页浏览（媒体库 / 合集内部）
  ///
  /// [sortOrder] 为服务端排序方向（Ascending / Descending）。
  /// 实测：该服务器 SortOrder 默认行为对"最近添加"是反的——
  /// `DateCreated + Ascending` 返回最旧、`Descending` 才返回最新，
  /// 故调用方需按排序字段显式给出方向，不要依赖服务端默认。
  ///
  /// [genres] / [years] 为服务端筛选（逗号分隔可多选，各项之间是 OR）。
  /// 实测本服务器支持这两个参数且结果正确（`Genres=动作` 时
  /// TotalRecordCount 2035→823，返回条目确实都含「动作」；`Years=2024` → 67；
  /// 二者组合 → 19，符合交集语义）。
  /// **必须走服务端**：客户端复筛只作用于已加载页，分页下结果会不完整。
  Future<ItemPage> getItems({
    String? parentId,
    String includeTypes = 'Movie,Series',
    String? searchTerm,
    String sortBy = 'SortName',
    String sortOrder = 'Ascending',
    bool recursive = true,
    bool unplayedOnly = false,
    String? filters, // IsPlayed / IsFavorite / IsUnplayed（逗号分隔可多选）
    String? genres, // 服务端类型筛选（Genres）
    String? years, // 服务端年份筛选（Years）
    int startIndex = 0,
    int limit = 40,
  });

  /// 单条目完整详情（含演职员 / 媒体源）
  Future<MediaItemDetail> getItemDetail(String itemId);

  /// 某库可用的类型列表（服务端分面）。
  /// 实测 `/Genres?ParentId=` 返回 `{Items:[{Name}]}`，空名字需滤掉。
  Future<List<String>> getGenres({String? parentId});

  /// 某库的年份区间（最早, 最晚）。两端探针各一次 `Limit=1` 查询。
  /// 实测本服务器能取到 1931–2026；该库无年份数据时返回 null。
  /// （年份没有可用的分面端点，只能探针实测）
  Future<(int, int)?> getYearRange({
    String? parentId,
    String includeTypes,
  });

  /// 剧集的季列表
  Future<List<MediaItem>> getSeasons(String seriesId);

  /// 某季的分集列表
  Future<List<MediaItem>> getEpisodes(String seriesId, String seasonId);

  /// 相似推荐
  Future<List<MediaItem>> getSimilar(String itemId);

  /// 章节标记（进度条刻度 / 跳过片头）
  Future<List<MediaChapter>> getChapters(String itemId);

  /// 收藏 / 看过 toggle（返回目标状态）
  Future<bool> toggleFavorite(String itemId, {required bool favorite});
  Future<bool> togglePlayed(String itemId, {required bool played});

  /// 解析播放直链（直连原文件）
  ///
  /// [mediaSourceId] 指定多版本条目中的哪一路媒体源；null = 取服务端默认（第一路）。
  Future<PlaybackLaunch> resolvePlayback(String itemId, {String? mediaSourceId});

  /// 播放进度上报（开始/进行中/停止，fire-and-forget）
  void reportPlaybackStart(
      {required String itemId,
      required String playSessionId,
      required String mediaSourceId,
      required int positionTicks});
  /// 上报播放进度。
  ///
  /// [eventName] 是上报原因，取值见官方文档
  /// <https://dev.emby.media/doc/restapi/Playback-Check-ins.html>：
  /// `TimeUpdate` / `Pause` / `Unpause` / `VolumeChange` / `RepeatModeChange` /
  /// `AudioTrackChange` / `SubtitleTrackChange` / `PlaylistItemMove` /
  /// `PlaylistItemRemove` / `PlaylistItemAdd` / `QualityChange` /
  /// `SubtitleOffsetChange` / `PlaybackRateChange`。
  ///
  /// **官方要求**："Progress should be reported automatically every 10 seconds,
  /// and immediately following any user interaction with the player"。
  /// 故定时上报传 `TimeUpdate`，用户操作（暂停/拖动/变速/切轨）应即刻单独上报
  /// 一次并带上对应事件名——只靠 10s 定时会让服务端的进度校准滞后一个周期。
  void reportPlaybackProgress(
      {required String itemId,
      required String playSessionId,
      required String mediaSourceId,
      required int positionTicks,
      required bool paused,
      double rate = 1,
      String? eventName});
  void reportPlaybackStop(
      {required String itemId,
      required String playSessionId,
      required String mediaSourceId,
      required int positionTicks});

  /// 持久化条目播放进度（fire-and-forget）。
  ///
  /// 与 `reportPlayback*` 的区别（实测本服务器确认）：
  /// - `Sessions/Playing*` 上报的是**会话状态**，服务端可能在会话结束后丢弃；
  /// - `POST /Users/{uid}/Items/{id}/UserData` 直接写**条目级进度**，是持久化的，
  ///   决定"继续观看"和断点续播读到的值。
  ///
  /// 实测（Emby 4.10.0.40）：该路径**只支持 POST**——
  /// `GET …/UserData` 返回 404「找不到文件」，而 `POST` 返回 204 且写回生效
  /// （写入 `PlaybackPositionTicks=1234567890` 后 `GET /Users/{uid}/Items/{id}`
  /// 能读到该值）。读取进度请走 `getItemDetail`（UserData 内嵌在条目里）。
  void reportItemProgress({
    required String itemId,
    required int positionTicks,
    bool? played,
  });
}

/// `Sessions/Playing/Progress` 的 `EventName` 取值。
///
/// 来自官方文档 <https://dev.emby.media/doc/restapi/Playback-Check-ins.html>：
/// "The EventName property tells the server why you're reporting progress."
///
/// 用具名常量而不是裸字符串：这些值大小写敏感（是帕斯卡命名），
/// 拼错不会报错、只会让服务端忽略该次上报的原因，属于静默失效。
abstract final class ProgressEvent {
  /// 定时上报（每 10 秒）。服务端会据此重新校准自动递增的进度。
  static const timeUpdate = 'TimeUpdate';
  static const pause = 'Pause';
  static const unpause = 'Unpause';
  static const volumeChange = 'VolumeChange';
  static const repeatModeChange = 'RepeatModeChange';
  static const audioTrackChange = 'AudioTrackChange';
  static const subtitleTrackChange = 'SubtitleTrackChange';
  static const playlistItemMove = 'PlaylistItemMove';
  static const playlistItemRemove = 'PlaylistItemRemove';
  static const playlistItemAdd = 'PlaylistItemAdd';
  static const qualityChange = 'QualityChange';
  static const subtitleOffsetChange = 'SubtitleOffsetChange';
  static const playbackRateChange = 'PlaybackRateChange';
}

/// 一次可执行的播放会话
class PlaybackLaunch {
  final String url; // 直连流地址（含 api_key）
  final String itemId;
  final String mediaSourceId;
  final String playSessionId;
  final String? videoLabel; // 例：1080p H264
  final String? audioLabel; // 例：EAC3 5.1
  final String? container;
  final String? transcodingUrl; // HLS 转码兜底（直连失败时的最后手段）
  final int? bitrate; // 原始码率 bps（速度监测判断用）

  const PlaybackLaunch({
    required this.url,
    required this.itemId,
    required this.mediaSourceId,
    required this.playSessionId,
    this.videoLabel,
    this.audioLabel,
    this.container,
    this.transcodingUrl,
    this.bitrate,
  });
}
