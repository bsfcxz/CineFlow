/// 多账号聚合搜索（用户要求："搜索聚合 + 首页保持单服务器切换"）。
///
/// ## 为什么只聚合搜索（而不聚合首页）
/// 用户明确选了 C 方案。理由（也是本文件的设计约束）：
/// · **首页聚合**要处理"同一部剧在两台都有 ⇒ 保留哪个"、
///   "两台各有进度 ⇒ 以谁为准" —— 都是产品决策，猜错会让用户困惑
///   （"我看完的怎么又变未看了"）
/// · **搜索聚合**没有这些问题：用户搜一个词，把两台的结果都给出来，
///   点哪条就在哪台上播。语义干净、零歧义。
///
/// ## 服务器标识怎么带
/// `MediaItem.id` 是**各服务器自己的 GUID**，跨服务器无意义。
/// 故聚合结果**必须**与"它来自哪个会话"绑定 —— 用
/// [AggregatedHit] 包一层，而不是往 `MediaItem` 里塞 `serverId`
/// （那会污染中立模型，且现有代码全部不认识该字段）。
///
/// ## 失败隔离（关键）
/// 一台服务器离线/密码失效**不能**让整个搜索失败 —— 其余台的
/// 结果照常显示，失败的那台给一行提示。用 `Future.wait` 的
/// 每个 future 自己 catch（而不是 `wait` 整体抛）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'media_provider.dart';
import 'models.dart';
import 'session_store.dart';

/// 一条聚合命中：条目 + 它来自哪台服务器。
class AggregatedHit {
  const AggregatedHit({
    required this.item,
    required this.session,
    required this.api,
  });

  final MediaItem item;
  final MediaSession session;

  /// 该条目所属服务器的 API 实例（点它时要用这台去解析/播放）。
  final MediaProvider api;

  /// 服务器展示名（用于角标，如 `客厅 Emby`）。
  String get serverLabel => Uri.tryParse(session.serverUrl)?.host ?? '';

  /// 全局唯一键（**跨服务器去重/比较用**）。
  ///
  /// ⚠️ 不能只用 `item.id` —— 两台服务器上"复仇者联盟"是两个不同 GUID，
  /// 而两台服务器上"恰好同 GUID"的两部片也未必是同一部。
  /// 故用 `serverKey|itemId` 作为**本机唯一标识**。
  String get key => '${SessionStore.accountKey(session)}|${item.id}';
}

/// **跨服务器身份键**（判断"两台上的这两条是不是同一部片"）。
///
/// ## ★★ 为什么必须用外部 ID（实测取证 + 调研交叉验证）
/// **标题匹配在真实片源上几乎无效**：
/// ```
/// 服务器 A: "Re：从零开始的异世界生活"
/// 服务器 B: "Re:ZERO -Starting Life in Another World-"
/// ```
/// 归一化后仍不相等（一个中文名一个英文名）。
///
/// 而外部 ID 是**全局唯一**的 —— 实测两台真实 Emby 的填充率：
/// ```
/// iLoveHD: Tmdb 87% / Tvdb 76% / Imdb 75.5%
/// HK-Emby: Tmdb 100% / Imdb 95% / Tvdb 67%
/// ```
/// ⇒ 准确率极高。这也是唯一做了真聚合的开源项目（plezy）的做法：
///   它靠 `imdb/tmdb/tvdb/anidb` 判同一部片
///   （见 `data_aggregation_service.dart`，我复核过）。
///
/// ## 多键策略（返回**所有**可用键，任一命中即视为同一条）
/// 一部片常同时有 imdb + tmdb + tvdb ⇒ 返回全部，
/// 去重时"任一键相同"就合并。这比只取第一个键更稳
///（避免"某台只有 tmdb、另一台只有 imdb"时匹配失败）。
///
/// ## ★★★ 实测：TMDB 的 movie 与 tv 是**两个独立 id 空间**
///
/// 扫描真实服务器 16470 个条目，发现 **165 组"跨类型撞 id"**：
/// ```
/// tmdb/74561  movie → 《阿姆斯特丹恶棍》(2011)
/// tmdb/74561  tv    → 《明星大侦探》(2016)      ← 两个都**正确**
/// tmdb/253    movie → 《007：你死我活》
/// tmdb/253    tv    → 《星际迷航：原初》
/// ```
/// ⇒ **不能**只用 `tmdb:<数字>` 作身份键，**必须带 type**
///（否则电影与剧集会被错判为同一部，跨服聚合时错合并）。
///
/// 另外 35 组"同类型撞 id"经核实是**同一部片的多版本**
///（`.strm` 多份：1080p/480p、Remux/普通）⇒ **不是数据错误**，不需处理。
///
/// ## 为什么标题兜底要**限定 type**
/// `Movie` 与 `Series` 可能同名（如《切尔诺贝利》既有电影也有剧集）
/// ⇒ 不带 type 会把它们错合并。
///
/// ⚠️ **不做模糊匹配**（编辑距离/拼音）：会把
///    《进击的巨人》与《进击的巨人 最终季》合成一条。
List<String> crossServerIdentityKeys(MediaItem it) {
  final out = <String>[];
  // ① 外部 ID（最可靠）—— key 已在解析时统一小写
  //
  // ★★★ **必须带 `type`**（实测发现的真 bug）
  //
  // TMDB 的 movie 与 tv 是**两个独立 id 空间**，同数字各自有效：
  // `tmdb/74561` 同时是《阿姆斯特丹恶棍》(movie) 与《明星大侦探》(tv)，
  // **两条元数据都正确**。
  // ⇒ 不带 type 会把电影与剧集判为"同一部" ⇒ 跨服聚合**错合并**。
  //
  // ## 为什么之前没抓到（两个盲区叠加）
  // · 单测样本都是**同类型**（两部剧 / 两条同 id）
  // · 真机只登录了 1 台服务器 ⇒ **跨服聚合压根没有两条可比**
  // ⇒ 靠"全库数据扫描"才发现，单测与真机都覆盖不到。
  //
  // ⚠️ 下面标题兜底键（`t:`）**一直**带着 type —— 外部 ID 这条却漏了，
  //    是两处**不一致**造成的疏漏。
  for (final p in const ['imdb', 'tmdb', 'tvdb', 'anidb', 'anilist']) {
    final v = it.providerIds[p];
    if (v != null && v.isNotEmpty) {
      out.add('$p:${it.type}:${v.toLowerCase()}');
    }
  }
  // ② 标题 + 年份 + 类型（**兜底**：实测约 0–25% 的条目没有外部 ID）
  final t = it.name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  if (t.isNotEmpty) {
    out.add('t:${it.type}:$t:${it.productionYear ?? ''}');
  }
  return out;
}

/// **一台服务器上的一组"同一部片"**（跨服务器聚合后的一个槽位）。
///
/// ## 为什么是"组"而不是"选一个"
/// 调研发现（plezy 的做法）：同一部片在两台都有时，
/// **不能贪心丢弃**——用户可能想选画质更好的那台。
/// ⇒ 保留全部来源，让 UI 决定（显示"2 台可用"并允许切换）。
class AggregatedGroup {
  AggregatedGroup(this.primary) : copies = [primary];

  /// 主副本（默认展示/播放的那条）。
  final AggregatedHit primary;

  /// 全部副本（含 [primary]；**多台都有时 > 1**）。
  final List<AggregatedHit> copies;

  void add(AggregatedHit hit) => copies.add(hit);

  /// 是否有多个服务器提供同一部片（UI 显示"2 台可用"）。
  bool get hasMultiple => copies.length > 1;

  /// 有几个**不同**服务器提供（同一台重复不算）。
  int get serverCount =>
      copies.map((c) => SessionStore.accountKey(c.session)).toSet().length;

  /// 其他可用来源（供"切换源"用；不含 [primary]）。
  List<AggregatedHit> get alternatives =>
      [for (final c in copies) if (!identical(c, primary)) c];
}

/// 把多台结果**跨服务器合并**成组（同一部片只出一个槽位）。
///
/// ## 语义（与 plezy 一致）
/// · **并组**：同一部片的多个副本进同一组（不丢弃）
/// · **主副本 = 第一台**（账号列表顺序；当前会话通常在最前）
/// · 无身份键的条目各自成组（宁可重复也不误合并）
///
/// ## 为什么不做"轮转交错"（Moonfin 的做法）
/// Moonfin 用 round-robin 保证每台曝光，但它**不去重** ⇒
/// 同一部片会重复出现。用户明确要"聚合"，去重更符合预期。
/// 且我们保留 `copies` ⇒ 也能看到"另一台也有"。
List<AggregatedGroup> groupAcrossServers(List<ServerSearchResult> results) {
  final groups = <AggregatedGroup>[];
  final index = <String, AggregatedGroup>{};

  for (final r in results) {
    for (final hit in r.hits) {
      final keys = crossServerIdentityKeys(hit.item);
      // 找已存在的组（任一键命中）
      AggregatedGroup? found;
      for (final k in keys) {
        final g = index[k];
        if (g != null) {
          found = g;
          break;
        }
      }
      if (found != null) {
        found.add(hit);
        // 把新条目的**其余键**也登记到该组（后续条目可命中）
        for (final k in keys) {
          index.putIfAbsent(k, () => found!);
        }
      } else {
        final g = AggregatedGroup(hit);
        groups.add(g);
        for (final k in keys) {
          index[k] = g;
        }
      }
    }
  }
  return groups;
}

/// 单个服务器的搜索状态（便于 UI 分台展示 + 失败提示）。
class ServerSearchResult {
  const ServerSearchResult({
    required this.session,
    this.hits = const [],
    this.error,
  });

  final MediaSession session;
  final List<AggregatedHit> hits;

  /// null = 成功；非 null = 该台失败的原因（**不影响其他台**）。
  final String? error;

  String get label => Uri.tryParse(session.serverUrl)?.host ?? serverUrlFallback;

  static const serverUrlFallback = '服务器';
}

/// 聚合搜索：并行搜所有已登录账号。
///
/// 返回顺序 = 账号列表顺序（当前会话通常在最前，因为登录时会 upsert 到头部）。
final aggregatedSearchProvider = FutureProvider.autoDispose
    .family<List<ServerSearchResult>, String>((ref, query) async {
  final q = query.trim();
  if (q.isEmpty) return const <ServerSearchResult>[];

  // ★★ 所有 `ref.watch` 必须在 **await 之前**取好（真机踩到的崩溃）
  //
  // ## 原来的写法错在哪
  // ```dart
  // final apis = await ref.watch(accountApisProvider.future);   // await
  // final accounts = await ref.watch(accountsProvider.future);  // ← 再用 ref
  // ```
  // Riverpod **禁止在 autoDispose provider 里"await 之后再用 ref"**：
  // 等待期间 provider 可能已被销毁，此时 `ref` 非法。真机日志原文：
  // ```
  // You tried to use Ref inside `onDispose` or other life-cycles.
  // This is not supported, as the provider is already being disposed.
  // ```
  // ⇒ 表现是**搜索直接失败**（异常冒泡到页面兜底 catch）。
  //
  // ## 修法：先同步取两个 Future，再 await；之后只用局部变量。
  final apisFuture = ref.watch(accountApisProvider.future);
  final accountsFuture = ref.watch(accountsProvider.future);

  final apis = await apisFuture;
  final accounts = await accountsFuture;
  if (accounts.isEmpty) return const <ServerSearchResult>[];

  // ⚠️ 每台**各自** catch：一台挂了不能拖垮整次搜索。
  final futures = <Future<ServerSearchResult>>[];
  for (final s in accounts) {
    final api = apis[SessionStore.accountKey(s)];
    if (api == null) continue;
    futures.add(() async {
      try {
        final items = await api.search(q, limit: 30);
        return ServerSearchResult(
          session: s,
          hits: [
            for (final it in items)
              AggregatedHit(item: it, session: s, api: api)
          ],
        );
      } catch (e) {
        // 单台失败：如实带出原因（不伪装成"没结果"）
        return ServerSearchResult(session: s, error: '$e');
      }
    }());
  }
  return await Future.wait(futures);
});
