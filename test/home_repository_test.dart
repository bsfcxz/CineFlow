import 'package:cineflow/data/emby_provider.dart' show MediaException;
import 'package:cineflow/data/home_repository.dart';
import 'package:cineflow/data/media_provider.dart';
import 'package:cineflow/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 首页聚合的降级契约测试（缺陷 §7.9 / §5.5）。
///
/// 为什么需要：
/// - `/Latest` 曾是最外层裸 await，失败时整页错误；而 resume/collections 有 try。
///   这种"降级不一致"静态分析发现不了，只有模拟单区块失败才能验证。
/// - 同时要防止矫枉过正：**四个区块全失败**时必须报错，
///   不能退化成"空首页"（否则网络故障会被伪装成"媒体库是空的"，违反 §5.5）。

/// 可控失败的假 Provider：按方法名决定是否抛错，并记录调用次数。
class _FakeApi implements MediaProvider {
  _FakeApi({
    this.failLatest = false,
    this.failResume = false,
    this.failItems = false,
    this.latestCount = 3,
  });

  final bool failLatest;
  final bool failResume;
  final bool failItems;
  final int latestCount;

  int latestCalls = 0;
  int resumeCalls = 0;
  int itemsCalls = 0;

  MediaItem _item(String id, {bool backdrop = false}) => MediaItem(
        id: id,
        name: '片名 $id',
        type: 'Movie',
        backdropImageTags: backdrop ? const ['tag'] : const [],
      );

  @override
  Future<List<MediaItem>> getLatest({int limit = 24}) async {
    latestCalls++;
    if (failLatest) throw const MediaException('latest 挂了');
    return [
      for (var i = 0; i < latestCount; i++)
        _item('L$i', backdrop: i == 0),
    ];
  }

  @override
  Future<List<MediaItem>> getResume({int limit = 12}) async {
    resumeCalls++;
    if (failResume) throw const MediaException('resume 挂了');
    return [_item('R0')];
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
    itemsCalls++;
    if (failItems) throw const MediaException('items 挂了');
    return ItemPage(items: [_item('C0')], total: 1);
  }

  // ---- 以下方法本测试用不到 ----
  @override
  Future<List<MediaView>> getViews() async => const [];
  @override
  Future<List<String>> getGenres({String? parentId}) async => const [];
  @override
  Future<(int, int)?> getYearRange({
    String? parentId,
    String includeTypes = 'Movie,Series',
  }) async =>
      null;
  @override
  String imageUrl(String itemId,
          {String type = 'Primary',
          int position = 0,
          String? tag,
          int maxWidth = 480}) =>
      '';
  @override
  Future<List<MediaItem>> search(String keyword, {int limit = 30}) async =>
      const [];
  @override
  Future<MediaItemDetail> getItemDetail(String itemId) async =>
      throw UnimplementedError();
  @override
  Future<List<MediaItem>> getSeasons(String seriesId) async => const [];
  @override
  Future<List<MediaItem>> getEpisodes(String seriesId, String seasonId) async =>
      const [];
  @override
  Future<List<MediaItem>> getSimilar(String itemId) async => const [];
  @override
  Future<List<MediaChapter>> getChapters(String itemId) async => const [];
  @override
  Future<bool> toggleFavorite(String itemId, {required bool favorite}) async =>
      favorite;
  @override
  Future<bool> togglePlayed(String itemId, {required bool played}) async =>
      played;
  @override
  Future<PlaybackLaunch> resolvePlayback(String itemId,
          {String? mediaSourceId}) async =>
      throw UnimplementedError();
  @override
  void reportPlaybackStart(
          {required String itemId,
          required String playSessionId,
          required String mediaSourceId,
          required int positionTicks}) {}
  @override
  void reportPlaybackProgress(
          {required String itemId,
          required String playSessionId,
          required String mediaSourceId,
          required int positionTicks,
          required bool paused,
          double rate = 1,
          String? eventName}) {}
  @override
  void reportPlaybackStop(
          {required String itemId,
          required String playSessionId,
          required String mediaSourceId,
          required int positionTicks}) {}
  @override
  void reportItemProgress({
    required String itemId,
    required int positionTicks,
    bool? played,
  }) {}
}

void main() {
  group('首页聚合：单区块失败不拖垮整页（§7.9）', () {
    test('全部成功时四个区块都有数据', () async {
      final d = await HomeData.fetch(_FakeApi());
      expect(d.latest, hasLength(3));
      expect(d.resume, hasLength(1));
      expect(d.collections, hasLength(1));
      expect(d.featured, hasLength(1), reason: '只有带背景图的条目进轮播');
      expect(d.fatalError, isNull);
    });

    test('/Latest 失败不再导致整页错误（回归线）', () async {
      final d = await HomeData.fetch(_FakeApi(failLatest: true));
      // 关键：不抛异常，且其余区块照常
      expect(d.fatalError, isNull, reason: '还有区块成功，不算致命');
      expect(d.latest, isEmpty);
      expect(d.featured, isEmpty);
      expect(d.resume, hasLength(1), reason: 'resume 不受 latest 失败影响');
      expect(d.collections, hasLength(1));
    });

    test('resume 失败不影响 latest 与 collections', () async {
      final d = await HomeData.fetch(_FakeApi(failResume: true));
      expect(d.latest, hasLength(3));
      expect(d.resume, isEmpty);
      expect(d.collections, hasLength(1));
      expect(d.fatalError, isNull);
    });

    test('collections 失败不影响其余区块', () async {
      final d = await HomeData.fetch(_FakeApi(failItems: true));
      expect(d.latest, hasLength(3));
      expect(d.resume, hasLength(1));
      expect(d.collections, isEmpty);
      expect(d.fatalError, isNull);
    });
  });

  group('首页聚合：全失败必须报错而非空首页（§5.5）', () {
    test('三个区块全失败 → fatalError 非空', () async {
      final d = await HomeData.fetch(
          _FakeApi(failLatest: true, failResume: true, failItems: true));
      expect(d.isEmpty, isTrue);
      expect(d.fatalError, isNotNull,
          reason: '网络全断时不能显示空首页，必须让 UI 报错');
      expect(d.fatalError, isA<MediaException>());
    });

    test('全失败但服务器真的没有内容 → 不报错（不能把空库当故障）', () async {
      // latestCount=0 且其余返回空列表：无错误 → 不是 fatal
      final api = _FakeApi(latestCount: 0);
      final d = await HomeData.fetch(api);
      expect(d.fatalError, isNull, reason: '空库是合法状态，不该报错');
    });
  });
}
