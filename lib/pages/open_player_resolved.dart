/// **通用播放入口**：解析条目上下文（剧集→取分集列表；电影→直开）。
///
/// ## 为什么必须有这个（真机 bug，用户两次反馈）
///
/// 用户反馈："播放剧集和综艺时播放列表并没有显示当前集数"。
/// 真机取证：从**首页「继续观看」卡片**进播放器，列表显示
/// "列表为空 / 没有待播放的媒体" —— 因为 `home_page.dart` 调的是
/// `openPlayer(context, item)`，**根本没传 episodes**。
///
/// 而详情页的「立即播放」（`_playSeries`）是**传了的**。
/// 同一个"要看这部剧"的动作，从不同入口进来结果不同 ——
/// 这不是"集数徽章没画"，而是**数据在入口处就丢了**。
///
/// ## 修法：把"解析上下文"收敛到一个函数
/// 所有入口都改调它。它做的事：
///   1. 判断条目是不是剧集（有 `seriesId` 且 type 为 Episode/Series）
///   2. 是剧集 → 向服务端取**完整分集列表**，按 `seriesId+seasonId`
///      定位当前集所在季，连 `index` 一起传给播放器
///   3. 不是 → 直接 `openPlayer`（单条视频）
///
/// 详情页 `_playSeries` 保留自己的版本（它要维护 `_selectedSeasonId`/
/// `_seriesResumeLabel` 等页面状态，且按钮文案需要 nextUp 详情）；
/// 其余入口统一走这里。
///
/// ## ⚠️ 弹幕/进度上报不受影响
/// 播放器内部按 `item.id` 自行处理，与入口无关。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    show WidgetRef;

import '../data/models.dart';
import '../state/providers.dart';
import '../player/player_routes.dart';

/// 打开播放器；**若是剧集条目，自动解析其分集列表**。
///
/// [context] 用于读 provider 与导航。
/// [item] 要播放的条目（可能是剧集的某一集，也可能是电影）。
///
/// ## 与 [openPlayer] 的关系
/// [openPlayer] 是"已知一切"的底层入口（详情页用它，
/// episodes/index 都已备好）；本函数是"只知道条目"的**高层入口**
/// （首页继续观看、搜索结果等，只有一条 MediaItem）。
Future<void> openPlayerResolved(
  BuildContext context,
  MediaItem item,
  WidgetRef ref,
) async {
  final api = ref.read(embyApiProvider);

  // ---- 非剧集（电影 / 无 seriesId）→ 直接播 ----
  final isEpisode = item.type == 'Episode' || item.seriesId != null;
  if (api == null || !isEpisode) {
    openPlayer(context, item);
    return;
  }

  // ---- 剧集：取分集列表 ----
  //
  // ⚠️ 用 `item.seasonId` 定位季（该集属于哪一季就取哪一季），
  //    而不是"无脑取第一季" —— 多季剧取错季会让列表对不上当前集。
  var seasonId = item.seasonId;
  if (seasonId == null || seasonId.isEmpty) {
    // 条目没带 seasonId（少见）：退而求其次取该剧第一季
    try {
      final seasons = await api.getSeasons(item.seriesId ?? item.id);
      if (seasons.isNotEmpty) seasonId = seasons.first.id;
    } catch (_) {
      // 取季失败 → 退化成单条视频播放（总比打不开强）
      openPlayer(context, item);
      return;
    }
  }
  if (seasonId == null || seasonId.isEmpty) {
    openPlayer(context, item);
    return;
  }

  try {
    final seriesId = item.seriesId ?? item.id;
    final episodes = await api.getEpisodes(seriesId, seasonId);
    if (episodes.isEmpty) {
      openPlayer(context, item);
      return;
    }
    // 当前集在列表中的位置（找不到则从头播）
    final idx = episodes.indexWhere((e) => e.id == item.id);
    if (!context.mounted) return;
    openPlayer(
      context,
      idx >= 0 ? episodes[idx] : item,
      episodes: episodes,
      index: idx >= 0 ? idx : 0,
    );
  } catch (_) {
    // 分集取失败 → 退化成单条播放（总比打不开强；错误不打断用户）
    if (!context.mounted) return;
    openPlayer(context, item);
  }
}
