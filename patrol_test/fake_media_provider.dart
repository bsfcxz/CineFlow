/// 播放页真机 UI 测试用的**假数据源**。
///
/// ## 为什么需要它（这是本项目最大的验证缺口）
///
/// 集成测试 `integration_test/player_kernel_test.dart` 只驱动**内核**
/// （建纹理 → initialize → 起播 → seek → dispose），**从不碰 UI 层**。
/// 也就是说下面这些事**从来没有被自动化验证过**：
///
///   · 控制层点一下能不能显/隐
///   · 控制条上那些钮**点了有没有反应**（本项目真实踩过：按钮被挤出屏幕、
///     点了因为 `eps != null` 守卫而静默无效 —— 静态分析全都发现不了）
///   · 音轨/字幕/倍速弹层能不能打开
///   · 弹幕层有没有正确地叠在视频之上、控制层之下
///
/// ## 为什么可以完全离线
///
/// `PlayerPage` 只依赖 `embyApiProvider`（一个 `Provider<MediaProvider?>`）。
/// Patrol 测试用 `ProviderScope(overrides: [...])` 注入本文件的假实现，
/// 于是**不需要服务器、不需要凭据、不需要网络** —— 结果完全确定。
/// 这比"登录真服务器再点"可靠得多：后者会因网络/账号状态而时好时坏。
///
/// ## 与"真实走查"的关系（不要误解这个测试的价值）
///
/// 它证明的是**接线**：控件存在、可命中、点了会走对应分支。
/// 它**不能**证明画面渲染正确（纹理内容截不到）、也不能证明真实片源能播 ——
/// 那些必须靠真机肉眼走查（见 `docs/AI-MEMORY.md` 第 20 轮）。
library;

import 'package:cineflow/data/media_provider.dart';
import 'package:cineflow/data/models.dart';

/// 一个"什么都有"的假条目：多集 + 多音轨 + 多字幕。
///
/// 刻意做成**多轨多集**，因为「唯一性则隐藏」这条交互规则只有在
/// 有可选项时才验证得到（单轨片源下按钮本就该隐藏）。
class FakeMediaProvider implements MediaProvider {
  FakeMediaProvider();

  /// 记录被调用的次数，便于断言"某条路径真的走过了"。
  final List<String> calls = [];

  static const _itemId = 'fake-item-1';

  MediaItem _movie() => const MediaItem(
        id: _itemId,
        name: '测试影片',
        type: 'Movie',
        productionYear: 2024,
        runtimeTicks: 72000000000, // 2h
      );

  /// 三集，供「选集」按钮出现（>1 集才显示）。
  List<MediaItem> _episodes() => List.generate(
        3,
        (i) => MediaItem(
          id: 'fake-ep-${i + 1}',
          name: '第 ${i + 1} 话·测试',
          type: 'Episode',
          seriesId: 'fake-series',
          seasonId: 'fake-season',
          parentIndexNumber: 1,
          indexNumber: i + 1,
        ),
      );

  // ---- 媒体库 / 列表（播放页用不到，返回空即可）----

  @override
  Future<List<MediaView>> getViews() async => const [];

  @override
  Future<List<MediaItem>> getLatest({int limit = 20}) async => [_movie()];

  @override
  Future<List<MediaItem>> getResume({int limit = 20}) async => [_movie()];

  @override
  Future<List<MediaItem>> search(String keyword, {int limit = 40}) async =>
      const [];

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
  }) async =>
      const ItemPage(items: [], total: 0);

  @override
  Future<List<String>> getGenres({String? parentId}) async => const [];

  @override
  Future<(int, int)?> getYearRange({
    String? parentId,
    String includeTypes = 'Movie,Series',
  }) async =>
      null;

  // ---- 播放页真正会调到的 ----

  @override
  Future<MediaItemDetail> getItemDetail(String itemId) async {
    calls.add('getItemDetail');
    return MediaItemDetail(item: _movie(), people: const []);
  }

  @override
  Future<List<MediaItem>> getSeasons(String seriesId) async => const [];

  @override
  Future<List<MediaItem>> getEpisodes(String seriesId, String seasonId) async {
    calls.add('getEpisodes');
    return _episodes();
  }

  @override
  Future<List<MediaItem>> getNextUp(String seriesId, {int limit = 1}) async {
    calls.add('getNextUp');
    return [];
  }

  @override
  Future<List<MediaItem>> getSimilar(String itemId) async => const [];

  @override
  Future<List<MediaChapter>> getChapters(String itemId) async {
    calls.add('getChapters');
    // 12 章 + 片头标记，供进度条刻度与跳片头使用
    return const [
      MediaChapter(name: '片头', startPositionTicks: 0, markerType: 'IntroStart'),
      MediaChapter(name: '正片', startPositionTicks: 1280000000),
      MediaChapter(name: '片尾', startPositionTicks: 6900000000, markerType: 'CreditsStart'),
    ];
  }

  @override
  Future<bool> toggleFavorite(String itemId, {required bool favorite}) async =>
      favorite;

  @override
  Future<bool> togglePlayed(String itemId, {required bool played}) async =>
      played;

  @override
  Future<PlaybackLaunch> resolvePlayback(String itemId,
      {String? mediaSourceId}) async {
    calls.add('resolvePlayback');
    return const PlaybackLaunch(
      // 指向**黑洞端口**（discard, 端口 9）：能建连但永不返回数据。
      // 这正是 STRM 死源的形态 —— 于是也能顺带验证起播超时那条路径
      // （15s 后应切转码或报错，而不是永久灰屏）。
      url: 'http://127.0.0.1:9/fake-stream.mp4',
      itemId: _itemId,
      mediaSourceId: 'fake-source-1',
      playSessionId: 'fake-session-1',
      videoLabel: '1080p H264',
      audioLabel: 'EAC3 5.1',
      container: 'mp4',
      bitrate: 8000000,
      streams: [
        MediaStream(
          index: 1,
          type: 'Audio',
          codec: 'aac',
          language: 'chi',
          displayTitle: 'Mandarin AAC 2.0',
          isDefault: true,
          channels: 2,
        ),
        MediaStream(
          index: 2,
          type: 'Audio',
          codec: 'eac3',
          language: 'eng',
          displayTitle: 'English EAC3 5.1',
          channels: 6,
        ),
        MediaStream(
          index: 3,
          type: 'Subtitle',
          codec: 'subrip',
          language: 'chi',
          displayTitle: 'Chinese Simplified (SRT)',
          isDefault: true,
        ),
        MediaStream(
          index: 4,
          type: 'Subtitle',
          codec: 'subrip',
          language: 'chi',
          displayTitle: 'Chinese Traditional (SRT)',
          isForced: true,
        ),
      ],
      defaultAudioIndex: 1,
      defaultSubtitleIndex: 3,
      chapters: [
        MediaChapter(name: '片头', startPositionTicks: 0, markerType: 'IntroStart'),
        MediaChapter(name: '正片', startPositionTicks: 1280000000),
      ],
    );
  }

  @override
  String imageUrl(String itemId,
          {String type = 'Primary',
          int position = 0,
          String? tag,
          int maxWidth = 400}) =>
      '';

  // ---- 上报：全部记录，便于断言"起播真的上报了" ----

  @override
  void reportPlaybackStart(
      {required String itemId,
      required String playSessionId,
      required String mediaSourceId,
      required int positionTicks}) {
    calls.add('reportPlaybackStart');
  }

  @override
  void reportPlaybackProgress(
      {required String itemId,
      required String playSessionId,
      required String mediaSourceId,
      required int positionTicks,
      required bool paused,
      double rate = 1,
      String? eventName}) {
    calls.add('reportPlaybackProgress:${eventName ?? ''}');
  }

  @override
  void reportPlaybackStop(
      {required String itemId,
      required String playSessionId,
      required String mediaSourceId,
      required int positionTicks}) {
    calls.add('reportPlaybackStop');
  }

  @override
  void reportItemProgress({
    required String itemId,
    required int positionTicks,
    bool? played,
  }) {
    calls.add('reportItemProgress');
  }
}
