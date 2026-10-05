/// 首页聚合：精选轮播 / 继续观看 / 最近添加
library;

import 'media_provider.dart';
import 'models.dart';

class HomeData {
  final List<MediaItem> featured; // 轮播（有背景图的最新条目）
  final List<MediaItem> resume; // 继续观看
  final List<MediaItem> latest; // 最近添加
  final List<MediaItem> collections; // 合集（BoxSet）

  /// 全部区块都失败时记下首个错误，供 UI 显示错误页而非空首页。
  /// 只用于区分"部分失败（照常渲染其余区块）"与"全失败（网络/服务器不可用）"。
  final Object? fatalError;

  const HomeData({
    required this.featured,
    required this.resume,
    required this.latest,
    this.collections = const [],
    this.fatalError,
  });

  /// 是否所有区块都为空（无轮播/继续观看/最近添加/合集）
  bool get isEmpty =>
      featured.isEmpty &&
      resume.isEmpty &&
      latest.isEmpty &&
      collections.isEmpty;

  /// 单区块失败不拖垮整块面板（一个分面挂掉不能拖垮整块面板）
  ///
  /// 四个区块**各自独立降级**：任一区块失败只让该区块为空，其余照常渲染。
  /// 特别注意 `/Latest` —— 它曾是最外层裸 await，一旦失败整页变成错误页，
  /// 而 resume/collections 却有 try 保护，属于典型的降级不一致。
  ///
  /// 但降级不等于掩盖：若**四个区块全失败**，把首个错误放进 [fatalError]，
  /// 由 UI 显示错误页。否则网络断开时用户会看到"空首页"而误以为媒体库是空的。
  static Future<HomeData> fetch(MediaProvider api) async {
    Object? firstError;

    // 轮播与"最近添加"同源（/Latest），失败时两者一起为空
    List<MediaItem> latest = const [];
    try {
      latest = await api.getLatest(limit: 24);
    } catch (e) {
      firstError ??= e;
    }

    List<MediaItem> resume = const [];
    try {
      resume = await api.getResume(limit: 12);
    } catch (e) {
      firstError ??= e;
    }

    final featured =
        latest.where((i) => i.backdropImageTags.isNotEmpty).take(5).toList();

    List<MediaItem> collections = const [];
    try {
      final page = await api.getItems(
          includeTypes: 'BoxSet',
          sortBy: 'DateCreated',
          // 合集按最新优先（实测本服务器 Ascending 会给最旧，见 MediaProvider.getItems 注释）
          sortOrder: 'Descending',
          recursive: true,
          limit: 12);
      collections = page.items;
    } catch (e) {
      firstError ??= e;
    }

    final data = HomeData(
      featured: featured,
      resume: resume.take(8).toList(),
      latest: latest.take(18).toList(),
      collections: collections,
    );

    // 全空 + 至少一个错误 → 视为致命（网络不可用/服务器拒绝），交给 UI 报错
    if (data.isEmpty && firstError != null) {
      return HomeData(
        featured: const [],
        resume: const [],
        latest: const [],
        fatalError: firstError,
      );
    }
    return data;
  }
}
