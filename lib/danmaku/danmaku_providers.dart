/// 弹幕状态的 riverpod providers（配置、客户端、按条目取弹幕）。
///
/// ## 设计要点
///
/// 1. **弹幕失败绝不影响播放**：所有 provider 都把异常转成"空弹幕 + 错误文案"，
///    由 UI 决定是否提示。播放器不该因为弹幕源挂了而播不了。
/// 2. **按 itemId 缓存**：同一集切来切去不该重复请求（官方第 9 节禁止高频调用）。
/// 3. **自动匹配 + 手动覆盖**：先按条目名自动搜 episodeId；
///    搜不到时用户可手动填（存偏好，下次直接命中）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/db_provider.dart';
import '../data/models.dart';
import '../state/providers.dart' show sessionStoreProvider;
import 'danmaku_client.dart';
import 'danmaku_config.dart';
import 'danmaku_match.dart';
import 'danmaku_models.dart';

/// 弹幕配置（从 SessionStore 读取，可在设置页修改）。
///
/// 用 AsyncNotifier 而不是同步 Provider：配置存在 secure_storage 里，
/// 读取是异步的。
class DanmakuConfigNotifier extends AsyncNotifier<DanmakuConfig> {
  @override
  Future<DanmakuConfig> build() =>
      ref.watch(sessionStoreProvider).loadDanmakuConfig();

  Future<void> save(DanmakuConfig config) async {
    await ref.read(sessionStoreProvider).saveDanmakuConfig(config);
    state = AsyncData(config);
    // 配置变了要重建客户端
    ref.invalidate(danmakuClientProvider);
  }

  /// 只改部分字段（设置页的开关/滑块用）
  Future<void> patch({
    DanmakuProviderKind? kind,
    String? baseUrl,
    String? appId,
    String? appSecret,
    bool? enabled,
    double? opacity,
    double? fontScale,
    double? showArea,
    List<String>? blockedWords,
    bool? useAsync,
    DanmakuDisplayModes? modes,
    double? speed,
    bool? bold,
    bool? avoidSubtitle,
  }) async {
    final cur = state.value ?? const DanmakuConfig();
    await save(cur.copyWith(
      kind: kind,
      baseUrl: baseUrl,
      appId: appId,
      appSecret: appSecret,
      enabled: enabled,
      opacity: opacity,
      fontScale: fontScale,
      showArea: showArea,
      blockedWords: blockedWords,
      useAsync: useAsync,
      modes: modes,
      speed: speed,
      bold: bold,
      avoidSubtitle: avoidSubtitle,
    ));
  }
}

final danmakuConfigProvider =
    AsyncNotifierProvider<DanmakuConfigNotifier, DanmakuConfig>(
        DanmakuConfigNotifier.new);

/// 弹幕客户端（配置不可用时为 null）。
final danmakuClientProvider = Provider<DanmakuClient?>((ref) {
  final cfg = ref.watch(danmakuConfigProvider).value;
  if (cfg == null || !cfg.isUsable) return null;
  final client = DanmakuClient.fromConfig(cfg);
  client.cache = ref.watch(appDbProvider);
  return client;
});

/// 一次弹幕加载的结果。
class DanmakuLoadResult {
  const DanmakuLoadResult({
    this.items = const [],
    this.error,
    this.matchedTitle,
    this.episodeId,
    this.fromCache = false,
  });

  final List<Danmaku> items;

  /// 失败原因（中文，可直接展示）。**没有弹幕不算错误**（error 为 null）。
  final String? error;

  /// 服务端确认的番剧名（用于让用户确认匹配对不对）
  final String? matchedTitle;
  final int? episodeId;
  final bool fromCache;

  bool get hasItems => items.isNotEmpty;
}

/// 按 Emby 条目取弹幕。
///
/// 流程：条目名 → 解析出番剧名+集号 → 搜 episodeId → 取弹幕。
/// 任一步失败都返回带 error 的结果，**不抛异常**（弹幕不该阻断播放）。
final danmakuForItemProvider = FutureProvider.autoDispose
    .family<DanmakuLoadResult, MediaItem>((ref, item) async {
  final client = ref.watch(danmakuClientProvider);
  if (client == null) {
    return const DanmakuLoadResult();
  }

  try {
    final q = parseDanmakuQuery(
      name: item.name,
      seriesName: item.seriesName,
      indexNumber: item.indexNumber,
      parentIndexNumber: item.parentIndexNumber,
      itemType: item.type,
    );
    if (!q.usable) {
      return const DanmakuLoadResult(error: '无法从标题识别番剧名');
    }

    final episodeId = await client.findEpisodeId(
      anime: q.anime,
      episode: q.episode,
    );
    if (episodeId == null) {
      // 搜不到不是错误——很多片确实没有弹幕库
      return DanmakuLoadResult(matchedTitle: q.anime);
    }

    final batch = await client.comments(episodeId);
    return DanmakuLoadResult(
      items: batch.items,
      matchedTitle: batch.animeTitle ?? q.anime,
      episodeId: episodeId,
    );
  } on DanmakuException catch (e) {
    return DanmakuLoadResult(error: e.message);
  } catch (e) {
    // 兜底：任何意外都不该让播放器崩
    return DanmakuLoadResult(error: '弹幕加载失败：$e');
  }
});
