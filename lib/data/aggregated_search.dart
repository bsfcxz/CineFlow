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
