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
  /// **某剧的库内摘要**（已入库集数 + 最大集号 + 下次更新日）。
  ///
  /// ## 为什么需要（用户要求）
  /// > "库里所有能够获取到的多集剧集、综艺应该都需要这样"
  /// > "下次更新时间你也没整"
  ///
  /// Emby 自己的详情页（首页/搜索/继续观看进去的那个）也应显示：
  /// · **已入库 N 集**（库里实际有几集）
  /// · **已更新至第 N 集**（最大集号）
  /// · **下次更新**（下一个有分集的日期）
  ///
  /// ## 与 [getSeriesEpisodes] 的关系
  /// 本方法是它的**语义封装**（一次请求、算好三个数），
  /// 避免每个调用点各写一遍统计逻辑（本轮已因"两处各写一套"被用户抓到）。
  Future<LibrarySummary?> getLibrarySummary(String seriesId);

  /// **某剧在库内的分集首播日**（追剧周历的**正解**）。
  ///
  /// ## 为什么不能用"全库本周更新"（我上一版的错误）
  /// `MinPremiereDate/MaxPremiereDate` 筛的是"**本周首播入库的集**"。
  /// 实测：你的库本周只有 **6 部**新剧入库，而订阅的 21 部是**连载中**
  ///（分集早就入库了）⇒ 两者交集 0。
  /// ⇒ 必须**按订阅的剧**去查它自己的分集。
  ///
  /// ## 返回
  /// `(季, 集, 本地时区周几)` 列表（该剧全部有 `PremiereDate` 的集）。
  /// 失败返回空列表（**不抛**：周历允许部分剧缺失）。
  Future<List<LibraryEpisode>> getSeriesEpisodes(String seriesId);

  /// **`tmdbId → Emby SeriesId`** 映射（1 个请求）。
  ///
  /// ## 为什么需要
  /// `getLibraryWeek` 返回的 key 是 Emby 的 **`SeriesId`**（内部 id），
  /// 而订阅表存的是 **tmdbId** ⇒ 必须有一次映射。
  ///
  /// ⚠️ **不能**用 `getItems()` 来映射 —— 它的 `Fields` **不含 `ProviderIds`**
  ///    ⇒ `providerIds['tmdb']` 恒空 ⇒ 映射结果为空（真机实测 `库内命中 0/21`）。
  ///    必须显式请求 `Fields=ProviderIds`（与 `collectProviderIds` 同款参数）。
  ///
  /// ## 第二返回值（库内信息）
  /// 现在同时返回 `tmdbId → (SeriesId, 平台名)` ——
  /// 平台取自 Emby 的 `Studios`（**实测内容是播出平台**：
  /// `Tencent Video` / `iQiyi` / `Youku` / `Mango TV` / `Netflix` / `CCTV`）。
  /// 用户订阅时若订阅源没给平台 ⇒ 用库内的补上（时刻标签要用）。
  Future<Map<String, SeriesRef>> mapSeriesTmdbToId();

  /// **全库本周分集**（1 个请求）—— 追剧周历的主数据源。
  ///
  /// ## 为什么需要它（用户思路 + 实测驱动）
  /// > "如果有库中的数据用库中的数据…这样的话点开追剧，直接就能显示。"
  ///
  /// 旧实现按剧逐个查 TMDB：**21 部订阅 = 42 个请求** ⇒ 全部超时 ⇒ 周历全 0。
  /// 本方法**一次请求**返回"全库本周有哪几集要播"，与订阅数**无关**。
  ///
  /// ## 实测（两台服务器，本周）
  /// iLoveHD → 9 条 · HK-Emby → 11 条，每条含
  /// `SeriesName` + `ParentIndexNumber`(季) + `IndexNumber`(集) + `PremiereDate`。
  ///
  /// ## 返回
  /// `(seriesId → 该剧本周的分集列表)`，每项 `(season, episode, weekday)`。
  /// `weekday` 已按**本地时区**折算（见实现里的时区说明）。
  Future<Map<String, List<LibraryEpisode>>> getLibraryWeek({DateTime? weekStart});

  /// **取库内条目的外部 id 集合**（`tmdbId` 集合，按类型分）。
  ///
  /// ## 为什么需要它（首页热播交集）
  /// 用户要求"热播剧集按我库里有的放上去" ⇒ 必须知道"库里有哪些 tmdb id"。
  ///
  /// ## 为什么不复用 `getItems`
  /// `getItems` 的 `Fields` 是写死的（**不含** `ProviderIds`）
  /// ⇒ 拿不到 tmdb id。而首页要的是 5000 条的精简列表
  ///（只 id，不带海报/简介）⇒ 单开一个方法**更快也更省**。
  ///
  /// ⚠️ 实现方需自己处理"服务器不返回 ProviderIds"的情况（返回空集合，不抛）。
  Future<Set<String>> collectProviderIds({
    required String providerKey,
    String includeTypes = 'Series,Movie',
    int limit = 5000,
  });

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

  /// **该剧"接下来该看哪几集"** —— 直接问服务端，不要自己算。
  ///
  /// ## 为什么必须有这个方法（用户指出的"致命问题"）
  ///
  /// 本项目曾自己实现 `SeriesProgress.resolve`：拉全部集、遍历各自的
  /// `UserData`、推断"用户停在第几集"。那是**重新发明轮子且更差**：
  /// Emby 服务端有完整的观看历史与续播语义，`/Shows/NextUp` 直接给出结果。
  ///
  /// 实测（本服务器，剧集《法医秦明之龙番往事》）：
  /// `GET /Shows/NextUp?UserId=…&SeriesId=…&Limit=3` →
  /// S1E9 / S1E10 / S1E11（带 `UserData`），而自算版本还需额外 2 次请求。
  ///
  /// ⚠️ **必须带 `SeriesId`**：不带时本服务器返回 **0 条**
  /// （实测），因为它语义是"整个媒体库的下一集"，需要配合其他参数/配置。
  /// 单剧场景一律用 `SeriesId`。
  ///
  /// 返回按"该看的先后"排序；**空列表表示该剧已全部看完**。
  Future<List<MediaItem>> getNextUp(String seriesId, {int limit = 1});

  /// 相似推荐
  Future<List<MediaItem>> getSimilar(String itemId);

  /// **合集成员**（Emby BoxSet 内的条目），如"漫威电影宇宙"下的全部电影。
  ///
  /// ## 为什么需要它（用户报障）
  /// 用户："当我观看复仇者联盟时，列表并没有显示它的下一部，
  /// 也没有列出它的部数。"
  ///
  /// 电影不是剧集（没有 `seriesId`）⇒ 播放列表拿不到"兄弟片"⇒
  /// 底栏列表只有当前这一部。合集体是唯一来源。
  ///
  /// ## 端点依据（Emby 官方 Go SDK，非猜测）
  /// `Clients/Go/api_collection_service.go`：
  /// ```
  /// localVarPath = a.client.cfg.BasePath + "/Collections/{Id}/Items"
  /// ```
  /// 即 `GET /Collections/{Id}/Items`。
  ///
  /// [collectionId] 来自条目的 `Collections[].Id`
  ///（见 `MediaItem.collectionIds` —— 注意**不是** Jellyfin 的 `BoxSetIds`）。
  ///
  /// ⚠️ 返回的成员**不含**当前正在播的那一部吗？—— 含。调用方按 id 过滤自己。
  Future<List<MediaItem>> getCollectionItems(String collectionId);

  /// **某演职员参与过的作品**（点演员头像 → 作品列表）。
  ///
  /// ## 为什么需要它（用户要求第一批第 1 项）
  /// 详情页的演职员行是"死"的：有头像、有名字，但**点了没反应**。
  /// 用户看到喜欢的演员，想看他还演过什么 —— 这是最自然的下一步。
  ///
  /// ## 端点依据（Emby 官方 Go SDK，非猜测）
  /// `Clients/Go/api_persons_service.go`：
  /// ```
  /// localVarPath = BasePath + "/Persons/{Id}/Credits"
  /// ```
  /// ⇒ `GET /Persons/{Id}/Credits`（该人的全部参演/执导条目）。
  ///
  /// [personId] 来自 `MediaPerson.id`（Emby 的 People[].Id）。
  Future<List<MediaItem>> getPersonCredits(String personId);

  /// **本地预告片**（某个条目自带的 trailer）。
  ///
  /// ## 端点依据（官方 Go SDK）
  /// `Clients/Go/api_user_library_service.go`：
  /// ```
  /// "/Users/{UserId}/Items/{Id}/LocalTrailers"
  /// ```
  ///
  /// ## 与"在线预告"的区别
  /// `LocalTrailers` 是**服务端媒体库里已有的**预告文件（同一个 Emby 库），
  /// 因此能直接起播；`/Items/{Id}/RemoteTrailers`（若有）给的是外部链接，
  /// 需要跳浏览器/YouTube。本项目只做本地预告 —— 它能在播放器里播。
  Future<List<MediaItem>> getLocalTrailers(String itemId);

  /// **上报一次搜索给服务端**（用户要求第一批第 4 项）。
  ///
  /// ## ⚠️ 改过的需求：Emby 没有"读取"搜索历史的端点
  /// 原计划是"服务端搜索历史（RecentlySearched）"，但**全 SDK 核实后否定**：
  /// 扫描 `Clients/Go` 全部 410 个文件，所有含 `Searched` 的端点只有：
  /// ```
  /// POST   /Users/{UserId}/SearchedItems/          ← 上报（本方法用它）
  /// DELETE /Users/{Id}/RecentlySearched            ← 清空
  /// POST   /Users/{Id}/RecentlySearched/Delete     ← 清空
  /// ```
  /// **没有 GET** ⇒ 服务端不回吐历史，客户端**无法**从服务端读回列表。
  ///
  /// ⇒ 因此本项只能实现"**写入侧**"：上报 + 清空同步（多端一致）。
  ///    **读取侧仍用本地** `SessionStore.loadSearchHistory`
  ///    （否则搜索页的历史会永远是空的 —— 那是更糟的"假实现"）。
  ///
  /// ## 为什么还是值得做
  /// · 服务端**有**这份数据（Emby 客户端/Web 端能看到）⇒ 上报后
  ///   用户在官方客户端也能看到同样的历史，是真实的跨端一致；
  /// · 清空时同步服务端 ⇒ 在其他客户端清掉历史后，本 App 也不会"复活"它
  ///   （只清本地会让服务端记录继续存在，用户在别处仍看到 —— 隐私错觉）。
  ///
  /// ⚠️ fire-and-forget：失败**不该**影响搜索（搜索本身已成功）。
  ///    不同 Emby 版本可能无此端点 ⇒ 实现里静默容忍。
  void reportSearched(String query);

  /// **清空服务端搜索历史**（与本地清空成对）。
  ///
  /// ## 为什么必须成对
  /// 用户点"清空历史"的意图是"**让这些记录消失**"。只清本地 =
  /// 记录仍在服务端（且会在官方客户端显示）—— 用户的隐私预期被违背。
  ///
  /// ⚠️ 同样 fire-and-forget：服务端清空失败**不该**阻止本地清空
  ///（用户看到的历史必须先消失）。反过来也要日志可见，便于排查。
  void clearRemoteSearchHistory();

  // ═══════════════════════════════════════════════════════════════
  // 第二批（需新页面）
  // ═══════════════════════════════════════════════════════════════

  /// **制片公司列表**（用户要求第二批第 5 项）。
  ///
  /// ## 端点依据（Emby 官方 Go SDK `api_studios_service.go`）
  /// ```
  /// localVarPath = BasePath + "/Studios"
  /// ```
  /// 参数（同文件 `GetStudiosOpts`）含 `ParentId` / `UserId` /
  /// `StartIndex` / `Limit` / `Recursive`（与 Items 同族）。
  ///
  /// ## 为什么有用
  /// 用户按"漫威/皮克斯/东宝"浏览是**片库的自然维度** ——
  /// 比按类型（"动作/科幻"太宽）更精确。
  ///
  /// ⚠️ 返回的是**公司实体**（`Type == 'Studio'`），不是可播条目。
  ///    生产实现里**不能**用 `isPlayable` 过滤掉它们。
  Future<List<MediaItem>> getStudios({String? parentId, int limit = 100});

  /// **某制片公司的作品**（用户要求第二批第 5 项）。
  ///
  /// ## 端点依据（官方 Go SDK `api_items_service.go`）
  /// `GET /Users/{UserId}/Items` 的 **`Studios`** 参数
  ///（`GetItemsOpts.Studios`，官方参数表里确认存在）。
  ///
  /// [studioName] 来自 `getStudios()` 返回条目的 `name`。
  Future<List<MediaItem>> getStudioItems(String studioName);

  /// **服务端播放列表**（用户要求第二批第 6 项）。
  ///
  /// ## 端点依据（Emby 官方 Go SDK `api_playlist_service.go`）
  /// ```
  /// localVarPath = BasePath + "/Playlists"
  /// ```
  /// 支持 `GET`（列表自身）、`/Playlists/{Id}/Items`（成员）。
  ///
  /// ## 与"本地播放队列"的区别
  /// 本项目的播放列表（`PlaylistController`）是**会话内**的（换集/连播）。
  /// 服务端播放列表是**用户手工建、跨设备同步**的 —— 两回事，别混。
  Future<List<MediaItem>> getPlaylists();

  /// 某服务端播放列表的成员。
  Future<List<MediaItem>> getPlaylistItems(String playlistId);

  /// **即将上线 / 待播**（用户要求第二批第 7 项：追剧日历）。
  ///
  /// ## 端点依据（Emby 官方 Go SDK `api_tv_shows_service.go`）
  /// ```
  /// localVarPath = BasePath + "/Shows/Upcoming"
  /// ```
  ///
  /// ## 与 `getNextUp` 的区别
  /// `NextUp` = "我该看下一集"（**已入库**、有进度语义）；
  /// `Upcoming` = "**未来**会播/会上线的集"（日历语义，可能尚未入库）。
  /// 追剧用户要的是后者。
  ///
  /// [days] = 往后看多少天（官方参数 `MaxEndDate` 的简化封装）。
  Future<List<MediaItem>> getUpcoming({int days = 30, int limit = 40});

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

/// 库内一集（追剧周历用）。
///
/// 库内一部剧的引用（`tmdbId → SeriesRef`）。
class SeriesRef {
  const SeriesRef({required this.seriesId, this.platform});

  /// Emby 的 `SeriesId`。
  final String seriesId;

  /// **播出平台**（取自 `Studios`；null = 库里没这个元数据）。
  final String? platform;
}

/// 某剧的**库内摘要**（详情页「已入库 / 已更新 / 下次更新」三个数）。
class LibrarySummary {
  const LibrarySummary({
    required this.episodeCount,
    this.title = '',
    this.lastEpisode,
    this.lastSeason,
    this.unplayedCount,
    this.nextAirDate,
    this.days = const {},
  });

  /// **剧名**（Emby 的 `Name`）。
  ///
  /// ## 为什么摘要要带剧名
  /// `librarySummaryProvider` 的第三级来源是**本地时刻表**
  /// （`anime_timelines`，按剧名查）⇒ 需要剧名。
  /// 摘要本来就在查这部剧，顺手带名字**零额外请求**。
  final String title;

  /// **已入库集数**（库里实际有几集）。
  final int episodeCount;

  /// **最后一集的集号**（null = 拿不到）。
  ///
  /// ## ⚠️ 这是**季内集号**，不是"全剧第几集"（真机踩到）
  /// ```
  /// 《赛尔号》已入库 349 集，但 IndexNumber 的 max = 52
  /// ```
  /// Emby 的 `IndexNumber` 是**季内集号**（`ParentIndexNumber` 才是季号）
  /// ⇒ 多季剧取 max 会得到一个远小于总集数的数，
  /// 用户看到"349 集 · 更新至第 52 集"会觉得数据错。
  /// ⇒ 显示时必须配合 [lastSeason]（多季带季号，见 `_progressText`）。
  final int? lastEpisode;

  /// 最后一集的**季号**（`ParentIndexNumber`；null = 未知/单季）。
  final int? lastSeason;

  /// **未看集数**（null = 拿不到）。
  ///
  /// ## 为什么放进 `LibrarySummary`
  /// 追剧卡片的进度行要显示"已看 X/Y · 剩 Z"。
  /// 原来进度**另走一条链**（`getItems(limit:1000)`）——
  /// 那条链有**截断 bug**（HK 5711 部 ⇒ 只取前 1000 ⇒ 一斩苍穹查不到）。
  /// 而 `getLibrarySummary` **本来就在查这部剧的 Episodes**
  /// （实测 `/Shows/{id}/Episodes` 响应带 `UserData.Played`）
  /// ⇒ 顺手数出来，**零额外请求**、且**逐部精确**（不受任何 limit 影响）。
  final int? unplayedCount;

  /// **下次更新日**（`yyyy-MM-dd`；null = 本周已无更新 / 拿不到）。
  final String? nextAirDate;

  /// `weekday(1=周一..7=周日) → 该天播出的集号`（**只有带日期的集才进**）。
  ///
  /// ## 为什么放进摘要（而不是另调 `getSeriesEpisodes`）
  /// 两者打的是**同一个端点**（`/Shows/{id}/Episodes`）——
  /// 分两次调用是白花一次请求。
  /// 更重要的是：`getSeriesEpisodes` 会**过滤掉没有 `PremiereDate` 的集**，
  /// 而 `getLibrarySummary` 不会 ⇒ 两个口径会打架
  ///（真机实测：卡片 `更新至 E239` vs 详情页 `已更新 第 203 集`）。
  /// ⇒ **统一到本方法**，一个请求给全部数据。
  final Map<int, List<int>> days;

  static const empty = LibrarySummary(episodeCount: 0);
}

/// 只要 UI 需要的三样：季、集、**本地时区的周几**。
class LibraryEpisode {
  const LibraryEpisode({
    required this.seriesId,
    required this.seriesName,
    required this.season,
    required this.episode,
    required this.weekday,
  });

  final String seriesId;
  final String seriesName;
  final int? season;
  final int? episode;

  /// **本地时区**的周几（1=周一 … 7=周日）。
  ///
  /// ⚠️ 必须由服务端 UTC 时间**转本地**后计算 —— 否则
  /// `2024-12-22T16:00:00Z`（北京 12-23 周一）会被算成周日。
  /// 时区折算在实现里做，UI 直接用。
  final int weekday;
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

  /// **服务端给出的完整媒体流列表**（音轨/字幕/视频）。
  ///
  /// ## 为什么必须带上它（用户指出的"致命问题"）
  ///
  /// 播放器此前只从**播放内核 mpv** 解析轨道名，而 mpv 的 `track-list`
  /// 字段远少于服务端：没有 `DisplayLanguage`、没有 `IsForced`/`IsExternal`、
  /// 没有「(默认)」标记、没有 `ChannelLayout`。
  ///
  /// 服务端 `MediaStream.DisplayTitle` 已是人类可读名，实测：
  /// `Chinese Simplified (PGSSUB)`、`Mandarin EAC3 5.1 (默认)`、
  /// `Chinese TRUEHD 5.1 (默认)` —— 正是用户要的"中字/繁体/多音轨区分"。
  ///
  /// 故：**轨道选择 UI 一律以本字段为准**，内核轨道仅用于执行切换。
  final List<MediaStream> streams;

  /// 服务端指定的默认音轨/字幕轨索引（对应 `MediaStream.index`）
  final int? defaultAudioIndex;
  final int? defaultSubtitleIndex;

  /// **章节** —— 服务端把章节放在 `MediaSource.Chapters` 里。
  ///
  /// 改造前播放器单独调 `api.getChapters()` 再发一次请求，
  /// 而 `PlaybackInfo` 的响应里**本来就带**（实测 12 章）。
  /// 现随 launch 一起带过来，**省掉一次 HTTP 往返**。
  final List<MediaChapter> chapters;

  /// 播放该源所需的额外 HTTP 头（服务端要求时非空）。
  /// **必须透传给播放内核**，否则某些源会 403（内核的 `open` 已支持 headers）。
  final Map<String, String> headers;

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
    this.streams = const [],
    this.defaultAudioIndex,
    this.defaultSubtitleIndex,
    this.chapters = const [],
    this.headers = const {},
  });

  /// 音轨（服务端口径，按服务端顺序）
  List<MediaStream> get audioStreams =>
      streams.where((s) => s.type == 'Audio').toList();

  /// 字幕轨（服务端口径）
  List<MediaStream> get subtitleStreams =>
      streams.where((s) => s.type == 'Subtitle').toList();
}
