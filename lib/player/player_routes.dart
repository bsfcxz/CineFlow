/// 播放器的路由定义与深链回退。
///
/// ## 为什么播放器单独一个文件
///
/// 其它页面都只需要一个 id（详情页 `/detail/:id`），而播放器需要：
///   - 完整的 `MediaItem`（含 runtimeTicks / progress —— 决定断点续播）
///   - 可选的**整季分集列表**（决定"选集抽屉"与"自动连播下一集"是否可用）
///   - 多版本选择（详情页「版本」chips 传下来的 mediaSourceId）
///
/// 这些无法全塞进 URL。go_router 的标准解法是 `state.extra` 传对象，
/// **但 extra 在深链/进程重启后会丢失**（它是内存对象，不进 URL）。
///
/// 因此这里必须有一条**按 id 拉取的回退路径**：
/// 有 extra → 直接用（UI 内跳转的常规路径，零延迟）
/// 无 extra → 按 `/play/:id` 拉详情再播（深链、通知、外部唤起）
///
/// 这条回退不是"为了完整性"，而是让播放器真正可被 URL 打开的前提——
/// 否则 `/play/xxx` 这种链接进来只会白屏。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/theme.dart';
import '../data/emby_provider.dart';
import '../data/models.dart';
import '../pages/detail_page.dart'
    show detailProvider, episodesProvider, seasonsProvider;
import '../widgets/media_cards.dart';
import 'player_flow_page.dart' show PlayerFlowPage, useNewPlayerUi;
import 'player_page.dart';

/// 播放器路由的 `extra` 载荷。
///
/// 用专门的类型而不是裸 Map：`extra` 是 `Object?`，
/// 类型化能让"传错东西"在编译期暴露，而不是运行时白屏。
class PlayerRouteArgs {
  const PlayerRouteArgs({
    required this.item,
    this.episodes,
    this.index = 0,
    this.mediaSourceId,
  });

  final MediaItem item;

  /// 整季分集；为 null 时选集抽屉与自动连播不可用（如从首页继续观看进入）
  final List<MediaItem>? episodes;
  final int index;
  final String? mediaSourceId;
}

/// 跳转播放器（UI 内的常规入口）。
///
/// 保留这个函数而不是让调用方直接 `context.go`：
/// 调用点众多，集中在一处便于将来调整 extra 的形状。
void openPlayer(BuildContext context, MediaItem item,
    {List<MediaItem>? episodes, int index = 0, String? mediaSourceId}) {
  context.push(
    '/play/${item.id}',
    extra: PlayerRouteArgs(
      item: item,
      episodes: episodes,
      index: index,
      mediaSourceId: mediaSourceId,
    ),
  );
}

/// 播放器路由（供 router.dart 挂载）。
///
/// ## 双播放页渐进迁移
/// `--dart-define=CF_NEW_PLAYER=true` 时走**新播放 UI**（PlayerFlowPage，
/// 按 HTML 原型重构的那套，Emby 流程见 player_flow_page.dart）；
/// 默认仍走旧页 —— 新页未经真实登录 E2E 验证前不接管主路径。
GoRoute playerRoute() => GoRoute(
      path: '/play/:id',
      builder: (context, state) {
        final extra = state.extra;
        if (useNewPlayerUi) {
          return _flowArgs(state, extra);
        }
        if (extra is PlayerRouteArgs) {
          return PlayerPage(
            item: extra.item,
            episodes: extra.episodes,
            index: extra.index,
            mediaSourceId: extra.mediaSourceId,
          );
        }
        // 深链/进程重启后 extra 丢失：按 id 拉详情再播
        return _PlayerDeepLink(
          itemId: state.pathParameters['id'] ?? '',
          index: int.tryParse(state.uri.queryParameters['index'] ?? '') ?? 0,
        );
      },
    );

/// 新播放 UI 的参数装配（extra 丢失时按 id 兜底拉详情）。
Widget _flowArgs(GoRouterState state, Object? extra) {
  if (extra is PlayerRouteArgs) {
    return PlayerFlowPage(
      item: extra.item,
      episodes: extra.episodes,
      index: extra.index,
      mediaSourceId: extra.mediaSourceId,
    );
  }
  return _PlayerDeepLink(
    itemId: state.pathParameters['id'] ?? '',
    index: int.tryParse(state.uri.queryParameters['index'] ?? '') ?? 0,
    useNewUi: true,
  );
}

/// 深链回退：按 id 拉详情，成功后替换为真正的播放器。
///
/// [useNewUi] = 跟随 CF_NEW_PLAYER 开关走新播放 UI（保持与主入口同一选择）。
class _PlayerDeepLink extends ConsumerWidget {
  const _PlayerDeepLink({required this.itemId, this.index = 0, this.useNewUi = false});

  final String itemId;
  final int index;
  final bool useNewUi;

  Widget _player(MediaItem item, {List<MediaItem>? episodes}) {
    if (useNewUi) {
      return PlayerFlowPage(item: item, episodes: episodes, index: index);
    }
    return PlayerPage(item: item, episodes: episodes, index: index);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (itemId.isEmpty) {
      return const _PlayerDeepLinkError(message: '缺少条目 ID');
    }
    final detail = ref.watch(detailProvider(itemId));
    return detail.when(
      loading: () => Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Cf.accent)),
      ),
      error: (e, _) => _PlayerDeepLinkError(
        message: e is MediaException ? e.message : '无法加载该条目',
      ),
      data: (d) {
        // 剧集深链：需要"季 id"才能拉分集，而条目里只有季号——
        // 故先取季列表再按季号匹配（`episodesProvider` 的键是 (seriesId, seasonId)）。
        final seriesId = d.item.seriesId;
        if (seriesId == null) {
          return _player(d.item);
        }
        final seasons = ref.watch(seasonsProvider(seriesId));
        return seasons.when(
          loading: () => Scaffold(
            backgroundColor: Colors.black,
            body: Center(child: CircularProgressIndicator(color: Cf.accent)),
          ),
          // 季列表失败不影响播放：退化为"无选集上下文"仍可起播
          error: (_, _) => _player(d.item),
          data: (list) {
            final want = d.item.parentIndexNumber ?? 1;
            String? seasonId;
            for (final s in list) {
              if (s.parentIndexNumber == want) seasonId = s.id;
            }
            if (seasonId == null) {
              return _player(d.item);
            }
            final eps = ref.watch(episodesProvider((seriesId, seasonId)));
            return _player(d.item, episodes: eps.value);
          },
        );
      },
    );
  }
}

class _PlayerDeepLinkError extends StatelessWidget {
  const _PlayerDeepLinkError({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: CfErrorView(
        message: message,
        // 深链失败没有"上一页"可回（可能是冷启动进来的），故回首页
        onRetry: () => context.go('/'),
      ),
    );
  }
}
