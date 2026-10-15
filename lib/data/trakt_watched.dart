// ══════════════════════════════════════════════════════════════════════
//  Trakt「同步已看状态」—— **双向**同步的拉取方向（Trakt → 本地）
// ══════════════════════════════════════════════════════════════════════
//
// ## 用户要的
// > 现在完善 trakt 中的实时追踪、**同步已看状态**、续播检查等
//
// ## 两个方向
// | 方向 | 实现位置 | 触发 |
// |---|---|---|
// | 本地 → Trakt（推送）| `detail_page._syncToTrakt` | 用户点「同步到 Trakt」|
// | **Trakt → 本地（拉取）** | **本文件** | 同一个按钮（先拉后推）|
//
// ## ★ 为什么必须先拉后推（顺序不能反）
// ```
// 先推：Emby 的"已看"写进 Trakt
// 再拉：Trakt 的"已看"写回 Emby   ⇒ 两边并集 ✅
// ```
// 若反过来（先拉后推）也能得到并集，但**先推能让 Trakt 先拿到
// 本地的新进度**，避免"拉下来的旧状态把刚看的覆盖成未看"的观感问题。
//
// ## ⚠️ 本文件**只做加法**（安全约束，源自 §6.9.1 的真实事故）
// · 绝不把 Emby 的"已看"改成"未看"
// · 拿不到 Trakt 数据时**一个写操作都不做**（"取数失败 ≠ 数据为空"）
// · 每一条写操作都要有日志说明"为什么标这一集"
library;

import 'package:flutter/foundation.dart';

import 'trakt_client.dart';

/// 一次「Trakt → 本地」同步的结果（**如实计数**，不粉饰）。
///
/// ## 为什么要有这个类型
/// 用户点完按钮需要知道**发生了什么**：
/// · "已同步 0 集" 与 "Trakt 上没有记录" 是**两件事**
/// · "跳过了 3 集" 说明部分数据没对上（用户可能想知道为什么）
/// ⇒ 只回一个 bool 会逼调用方编造文案。
class TraktPullResult {
  const TraktPullResult({
    required this.fetched,
    required this.markedNew,
    required this.alreadyWatched,
    this.failed = false,
    this.note,
  });

  /// 是否**成功取到** Trakt 数据（false ⇒ 后续什么都没做）。
  final bool fetched;

  /// 本次**新标记**为已看的集数（真正的"同步成果"）。
  final int markedNew;

  /// 本地**本来就已经**是已看的集数（Trakt 也有）。
  final int alreadyWatched;

  /// 是否因失败而放弃（网络/未登录）。
  final bool failed;

  /// 给用户看的补充说明（如"Trakt 上没有这部剧"）。
  final String? note;

  @override
  String toString() => 'TraktPullResult(fetched=$fetched, '
      'new=$markedNew, already=$alreadyWatched, failed=$failed)';
}

/// 「Trakt → 本地」的已看同步器。
///
/// ## 为什么单独一个类（不塞进详情页）
/// ① 详情页 1731 行（§6.10 规则⑤：大文件先划边界）
/// ② 这段逻辑**必须可单测** —— 它涉及"要不要写用户数据"，
///    是本仓库最需要断言的地方（§6.9.1 的教训）
class TraktWatchedSyncer {
  TraktWatchedSyncer({required this.client, required this.sync});

  /// 用于 **tmdb → trakt show** 的解析。
  ///
  /// ⚠️ 用 `TraktClient.findByTmdb`（**已存在**，自带缓存 + 错配校验），
  ///    不要在这里重写一遍 —— 我第一版就是新造了 `sync.findShowByTmdb`
  ///    这个方法，而它**不存在**（§6.10 规则⑤：先读完整接口）。
  final TraktClient client;

  final TraktSync sync;

  /// 把 Trakt 上"已看"的集标记到本地（**只加不减**）。
  ///
  /// [tmdbShowId] 是**剧的** tmdb（不是集级的 —— 见 `TraktEpisodeResolver`）。
  /// [episodes] 是本剧的**全部集**（含 Emby 的 `played` 状态），
  ///   由调用方提供（详情页已加载，不重复请求）。
  /// [markPlayed] 是"把某一集标为已看"的回调（注入以便单测）。
  ///
  /// ## 返回
  /// 见 [TraktPullResult]。**任何失败都不抛**（同步是附加功能）。
  Future<TraktPullResult> pull({
    required String tmdbShowId,
    required List<TraktEpisodeRef> episodes,
    required Future<bool> Function(String embyItemId) markPlayed,
    String? expectCnTitle,
    int? expectYear,
  }) async {
    if (tmdbShowId.trim().isEmpty) {
      return const TraktPullResult(
          fetched: false, markedNew: 0, alreadyWatched: 0,
          note: '这部剧没有 TMDB id');
    }
    if (episodes.isEmpty) {
      return const TraktPullResult(
          fetched: false, markedNew: 0, alreadyWatched: 0,
          note: '本剧没有分集数据');
    }

    // ════════════════════════════════════════════════════════════
    // ① 取 Trakt 记录（**history 优先，watched 回退**）
    // ════════════════════════════════════════════════════════════
    //
    // ## ★ 为什么必须先查 history（2026-10-15 用户报障的根因）
    // Trakt 有**两套独立数据**（契约 `contracts/sync/index.ts`）：
    // | 概念 | 端点 | 写入条件 |
    // |---|---|---|
    // | **history** | `/sync/history/shows/:id` | **任何播放**（含看一半）|
    // | watched | `/sync/watched/shows` | 仅 `progress > 80%` |
    //
    // 用户原话："我**观看了一部分**点击同步后没有实现"
    // ⇒ 看一半只进 history ⇒ 查 watched **必然空**
    //   （日志实证 `没有已看记录`，而网页历史里明明有）。
    // ## ② 那为什么还要回退 watched
    // 有些用户用**别的**客户端，那里可能只写 watched（scrobble > 80%）
    // ⇒ 两段查覆盖更多情况。**代价**：多一次请求（可接受）。
    var watched = <int, Set<String>>{};
    var sawAny = false;      // 是否**成功**取到过数据（区分"空"与"失败"）

    // 先解析 trakt show id（history 需要它）
    final showForHistory = await client.findByTmdb(
      tmdbShowId,
      expectCnTitle: expectCnTitle,
      expectYear: expectYear,
    );
    if (showForHistory == null || showForHistory.traktId == null) {
      debugPrint('[TraktPull] 取不到 trakt show id ⇒ 跳过');
      return const TraktPullResult(
          fetched: true, markedNew: 0, alreadyWatched: 0,
          note: 'Trakt 上没有这部剧');
    }
    final traktShowId = showForHistory.traktId!;

    // ① history（含"看一半"）
    //
    // ⚠️ **必须 try/catch**（2026-10-15 测试抓到的真缺陷）
    // `TraktSync.getShowHistory` 内部**有** catch，但：
    // · 测试替身／将来换实现时可能直接抛
    // · `_dio` 的某些异常不经过我的 catch（如 DioException 在拦截器里抛）
    // ⇒ 一旦冒泡，**回退 watched 的逻辑就永远不执行**（整个同步崩）。
    //   测试实证：
    //   ```
    //   Exception: 模拟网络失败
    //     test/trakt_watched_test.dart 52:21   _FakeSync.getShowHistory
    //     lib/data/trakt_watched.dart 148:29   TraktWatchedSyncer.pull   ← 冒泡到这
    //   ```
    try {
      final hist = await sync.getShowHistory(traktShowId);
      if (hist != null) {
        sawAny = true;
        if (hist.isNotEmpty) watched[traktShowId] = hist;
        debugPrint('[TraktPull] history 命中 ${hist.length} 集');
      } else {
        debugPrint('[TraktPull] history 取数失败（回退 watched）');
      }
    } catch (e) {
      // ★ 不冒泡 —— 让下面的 watched 回退有机会执行
      debugPrint('[TraktPull] history 异常（回退 watched）: $e');
    }

    // ② watched（回退；history 为空时才需要）
    if (watched.isEmpty) {
      try {
        final w = await sync.getWatchedShows();
        sawAny = true;
        final set = w[traktShowId];
        if (set != null && set.isNotEmpty) watched[traktShowId] = set;
        debugPrint('[TraktPull] watched 命中 ${set?.length ?? 0} 集');
      } catch (e) {
        // ★ 取数失败 ⇒ 若 history 也失败，则**一个写操作都不做**（§6.9.1）
        debugPrint('[TraktPull] 取 watched 失败: $e');
      }
    }

    // ③ 两段都失败 ⇒ failed（调用方**不做任何写**）
    if (!sawAny) {
      debugPrint('[TraktPull] history 与 watched 都取数失败 '
          '⇒ 放弃本次同步（不写任何数据）');
      return const TraktPullResult(
          fetched: false, markedNew: 0, alreadyWatched: 0, failed: true);
    }

    // ② 找到本剧对应的 Trakt 记录
    // ⚠️ `getWatchedShows` 的 key 是 **trakt show id**，而我们手里是 tmdb
    //    ⇒ 需要一次 tmdb→trakt 的解析（复用 `TraktClient.findByTmdb`）
    //    这一步**必须**有，否则会拿 traktId 去比 tmdbId（永远匹配不上，
    //    且**静默返回 0**，最难查）。
    // ⚠️ 传 expectCnTitle/expectYear 做**错配校验** —— 实测 Trakt 的
    //    tmdb 映射会错（tmdb 229977 我们叫《遮天》，
    //    Trakt 返回《陸小鳳之鳳舞九天》2000）⇒ 不校验会同步到**别的剧**。
    // （tmdb → trakt id 已在上面解析，这里直接复用）
    final traktId = traktShowId;
    final set = watched[traktId];
    if (set == null || set.isEmpty) {
      debugPrint('[TraktPull] Trakt 上 tmdb=$tmdbShowId '
          '(trakt=$traktId) 没有已看记录');
      return const TraktPullResult(
          fetched: true, markedNew: 0, alreadyWatched: 0,
          note: 'Trakt 上这部剧还没有已看记录');
    }

    // ③ 逐集比对（**只加不减**）
    var newCount = 0;
    var already = 0;
    for (final ep in episodes) {
      final key = 'S${ep.season}E${ep.number}';
      if (!set.contains(key)) continue;      // Trakt 没看 ⇒ 不动本地
      if (ep.played) {
        already++;                            // 两边都有 ⇒ 什么都不做
        continue;
      }
      // ★ 只在"Trakt 已看 且 本地未看"时**加**标记
      try {
        final ok = await markPlayed(ep.itemId);
        if (ok) {
          newCount++;
          debugPrint('[TraktPull] 标记已看 $key（Trakt 上有，本地没有）');
        } else {
          debugPrint('[TraktPull] 标记 $key 失败（服务端拒绝）');
        }
      } catch (e) {
        // 单集失败**不中断整批**（新集可能服务端不接受）
        debugPrint('[TraktPull] 标记 $key 异常: $e');
      }
    }
    debugPrint('[TraktPull] 完成：新增 $newCount 集，'
        '本地已有 $already 集（Trakt 共 ${set.length} 集）');
    return TraktPullResult(
        fetched: true, markedNew: newCount, alreadyWatched: already);
  }
}

/// 同步时用到的一集（**中立类型**，不含 Emby 词汇）。
///
/// ## 为什么要这个薄包装
/// `TraktWatchedSyncer` 只关心三件事：季、集、本地是否已看 + 怎么标记。
/// 直接传 `MediaItem` 会让本文件依赖 Emby 的模型
///（违反 §5.1"UI/逻辑只依赖抽象"），也让单测必须构造完整 MediaItem。
class TraktEpisodeRef {
  const TraktEpisodeRef({
    required this.itemId,
    required this.season,
    required this.number,
    required this.played,
    this.progress = 0,
  });

  /// 本地条目 id（`markPlayed` 用它）。
  final String itemId;
  final int season;
  final int number;

  /// 本地**当前**是否已看。
  final bool played;

  /// 本地播放进度 **0–100**（来自 Emby 的 `playedPercentage`／`positionTicks`）。
  ///
  /// ## ★ 为什么需要它（2026-10-15 用户要求）
  /// > 对于我**已经观看了一部分**的应该同步为 trakt 的**继续观看**
  ///
  /// 契约（`scrobble/index.ts:50-55`）明确三个区间：
  /// ```
  /// progress > 80%  ⇒ 标为 watched（已看）
  /// 1% ≤ p ≤ 79%    ⇒ 视为 pause ⇒ **继续观看**（我们推这个）
  /// progress < 1%   ⇒ 返回 422 被忽略（不要发）
  /// ```
  /// ⇒ 没有 `progress` 就无法区分"已看完"与"看了一半"。
  ///
  /// ## 默认 0 的含义
  /// 0 = 没看过 / 服务端没给进度 ⇒ 调用方**不要**推 `scrobble`
  ///（<1% 会被 422 拒绝）。
  final double progress;
}
