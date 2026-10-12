/// 应用状态（riverpod）：会话、API 实例、首页数据
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../data/aggregated_search.dart';
import '../data/calendar_client.dart';
import '../data/db/app_database.dart' show CalendarSubscription;
import '../data/db/db_provider.dart' show appDbProvider;
import '../data/emby_provider.dart';
import '../data/home_repository.dart';
import '../data/media_provider.dart';
import '../data/models.dart';
import '../data/session_store.dart';

final sessionStoreProvider =
    Provider<SessionStore>((ref) => SessionStore());

/// 登录会话：null = 未登录；启动时自动恢复持久化会话
class SessionNotifier extends AsyncNotifier<MediaSession?> {
  @override
  Future<MediaSession?> build() async {
    final store = ref.watch(sessionStoreProvider);
    final s = await store.loadSession();
    // ★ 一次性迁移：老用户只有 `cf_session`，没有 `cf_accounts`
    //
    // ## 为什么必须迁移（而不是只靠 `accountsProvider` 兜底）
    // 兜底只解决"读取"；不迁移的话：
    //   · 用户在「账号与资源整合」页看到的是兜底造出来的条目，
    //     但**一旦他添加第二个账号**，`upsertAccount` 会把新账号
    //     写进（原本为空的）列表 —— 第一个账号**仍不在列表里** ⇒
    //     聚合只搜到新账号，老账号被静默漏掉。
    //   · 而且"移除"当前账号后，列表里没有它，状态会不一致。
    //
    // ⇒ 启动时**补写一次**，让列表与当前会话一致。
    //    写失败不影响启动（下次启动再试）。
    if (s != null) {
      try {
        final accounts = await store.loadAccounts();
        final key = SessionStore.accountKey(s);
        if (!accounts.any((a) => SessionStore.accountKey(a) == key)) {
          await store.upsertAccount(s);
          debugPrint('[Session] 已把当前会话迁移进账号列表');
        }
      } catch (e) {
        debugPrint('[Session] 账号迁移失败（非致命，下次启动重试）: $e');
      }
    }
    return s;
  }

  Future<void> login(String serverUrl, String username, String password,
      {bool remember = true}) async {
    final store = ref.read(sessionStoreProvider);
    final s = await EmbyProvider.authenticate(
      serverUrl: serverUrl,
      username: username,
      password: password,
      deviceId: await store.deviceId(),
    );
    await store.saveSession(s);
    // ★ 多账号：登录即登记进 accounts（用户要求"多 emby 账号登录"）
    //
    // ## 为什么登录也要 upsert（而不是只在"添加账号"时写）
    // 用户第一次登录时并不知道自己在"加账号" —— 若只在专门的
    // "添加账号"入口写，第一个账号就永远不会进列表 ⇒
    // 搜索聚合会漏掉它（最常用的那台反而不被搜）。
    // ⇒ **登录即登记**，入口无关。
    await store.upsertAccount(s);
    await store.upsertServer(SavedServer(
      name: Uri.tryParse(serverUrl)?.host ?? serverUrl,
      url: serverUrl,
      username: username,
      password: remember ? password : null,
    ));
    ref.invalidate(embyApiProvider);
    state = AsyncData(s);
  }

  /// 切换到另一个已登录账号（搜索聚合结果点击时用）。
  ///
  /// ## 为什么"切换"而不是"把 serverId 穿透到播放层"
  /// 搜索结果来自哪台服务器，就得在那台上播 —— 因为
  /// `MediaItem.id` 是**各服务器自己的 GUID**，跨服务器没有意义；
  /// 详情页/合集解析/播放器/进度上报全部依赖"当前会话"。
  ///
  /// 把 `(serverId, itemId)` 复合标识穿透每一层 = 改动整条链路
  ///（详情页 provider、播放路由、进度上报、收藏 toggle…），
  /// 风险远大于收益。**切换会话**则复用全部既有逻辑，且语义正确：
  /// 用户点了一台服务器的资源，就应该在那台上操作。
  Future<void> switchTo(MediaSession s) async {
    final store = ref.read(sessionStoreProvider);
    await store.saveSession(s);
    ref.invalidate(embyApiProvider);
    state = AsyncData(s);
  }

  Future<void> logout() async {
    final store = ref.read(sessionStoreProvider);
    final cur = state.value;
    await store.clearSession();
    // ⚠️ **不删 accounts**：退出当前会话不等于"删除这个账号"，
    //    否则用户下次要用它就得重新输密码（而它就在列表里）。
    //    彻底移除走 [removeAccount]。
    if (cur != null) {
      debugPrint('[Session] 已退出当前会话（账号保留在列表，可再切回）');
    }
    ref.invalidate(embyApiProvider);
    state = const AsyncData(null);
  }

  /// 保存一条会话供聚合使用（**不改当前会话**）。
  ///
  /// 用于"添加账号但不切换"的场景：用户想整合多台资源，
  /// 但当前正在看的那台不该被换掉。
  Future<void> addAccount(MediaSession s) async {
    await ref.read(sessionStoreProvider).upsertAccount(s);
    // 通知聚合刷新（accounts 变了）
    ref.invalidate(accountsProvider);
  }

  /// 彻底移除一个账号（含把它从 accounts 删掉）。
  Future<void> removeAccount(MediaSession s) async {
    await ref.read(sessionStoreProvider).removeAccount(s);
    ref.invalidate(accountsProvider);
  }
}

final sessionProvider =
    AsyncNotifierProvider<SessionNotifier, MediaSession?>(SessionNotifier.new);

/// 所有已登录账号（多账号聚合的数据源）。
///
/// ## 与 `sessionProvider` 的区别
/// · `sessionProvider` = **当前生效**的那一个（播放/详情/上报都用它）
/// · `accountsProvider` = **全部**已登录的（搜索聚合并行搜它们）
///
/// ## ★★ 兼容旧版本：accounts 为空时用当前会话兜底
///
/// `cf_accounts` 是多账号功能**新增**的存储键。老用户升级后：
///   · `cf_session`（当前会话）**有值** —— 他本来就登录着
///   · `cf_accounts`（账号列表）**为空** —— 那个键当时还不存在
///
/// ⇒ 若不兜底，真机实测到两个症状（**都已复现**）：
///   1. 「账号与资源整合」页显示"还没有已登录的账号"
///      —— 明明已登录（同页入口副标题写着"已登录 1 台"）
///   2. **搜索直接失败** —— 聚合列表为空，上层判定"全台失败"
///
/// ⇒ 兜底：列表为空但**有当前会话** ⇒ 返回 `[当前会话]`。
///    单账号用户（绝大多数）行为与升级前**完全一致**；
///    下次登录/添加时 `upsertAccount` 会自然把它写进列表。
final accountsProvider = FutureProvider<List<MediaSession>>((ref) async {
  // 依赖 sessionProvider：登录/切换后自动重算（新账号立刻参与聚合）
  final cur = await ref.watch(sessionProvider.future);
  final list = await ref.watch(sessionStoreProvider).loadAccounts();
  if (list.isNotEmpty) return list;
  // 兜底：老用户只有 cf_session，没有 cf_accounts
  if (cur != null) return [cur];
  return const [];
});

/// 每个账号一套 API 实例（聚合搜索用）。
///
/// ## 为什么要缓存实例
/// `EmbyProvider` 内部持有 `Dio`（含拦截器与连接池）。
/// 每次聚合都新建会反复重建连接池 —— 白白浪费且慢。
/// 用 `Map` 按 [SessionStore.accountKey] 缓存。
final accountApisProvider =
    FutureProvider<Map<String, MediaProvider>>((ref) async {
  final accounts = await ref.watch(accountsProvider.future);
  final out = <String, MediaProvider>{};
  for (final s in accounts) {
    out[SessionStore.accountKey(s)] = EmbyProvider(s);
  }
  return out;
});

/// 主题预设 index（外观页切换 → MaterialApp key 重建）
class ThemeIndexNotifier extends Notifier<int> {
  @override
  int build() => 0;
  void set(int i) => state = i;
}

final themeIndexProvider =
    NotifierProvider<ThemeIndexNotifier, int>(ThemeIndexNotifier.new);

/// 首页顶栏齿轮 → 切到「我的」Tab
class HomeTabNotifier extends Notifier<int> {
  @override
  int build() => 0;
  void set(int i) => state = i;
}

final homeTabProvider =
    NotifierProvider<HomeTabNotifier, int>(HomeTabNotifier.new);

/// 当前可用的 MediaProvider（未登录为 null）
final embyApiProvider = Provider<MediaProvider?>((ref) {
  final s = ref.watch(sessionProvider).value;
  return s == null ? null : EmbyProvider(s);
});

/// 首页聚合数据（单区块失败不拖垮整页）
final homeProvider = FutureProvider.autoDispose<HomeData>((ref) async {
  final api = ref.watch(embyApiProvider);
  if (api == null) throw const MediaException('未登录');
  return HomeData.fetch(api);
});

// ═══════════════════════════════════════════════════════════════
// 追剧日历（多源聚合，见 `lib/data/calendar_client.dart`）
// ═══════════════════════════════════════════════════════════════

/// 日历客户端（进程内单例 —— **必须**单例，因为它持有"失败冷却"状态）。
///
/// ## 为什么必须单例（真网测试抓到的 UX 问题）
/// `CalendarClient` 内部记着 `_failedAt`（失败源冷却名单）。
/// 若每次 build 都 new 一个，冷却状态丢失 ⇒ 一个必然失败的源
/// （如本机连不上的 Bangumi）会让**每次打开日历都白等 8 秒退避**
/// （实测：缓存全命中时仍耗时 **8,408 ms**）。
/// **订阅结果**（供 UI 区分"成功/未入库/失败"三种提示）。
enum SubscribeOutcome {
  /// 已在库里 + 已写订阅（本地表 + Emby 收藏）。
  subscribed,

  /// 已在库里，已**取消**订阅。
  unsubscribed,

  /// **库里没有这部** ⇒ 未写任何东西（用户要求"提示，订阅暂未入库"）。
  notInLibrary,

  /// 网络/接口失败。
  failed,
}

/// 订阅动作的返回值。
class SubscribeResult {
  const SubscribeResult(this.outcome, {this.title = '', this.error});

  final SubscribeOutcome outcome;

  /// 媒体标题（用于提示文案）。
  final String title;

  /// `failed` 时的原因。
  final String? error;
}

/// **订阅一部「外部源」作品**（豆瓣 / TMDB）—— 先搜本地库，再决定怎么做。
///
/// ## 用户要求（2026-10-12）
/// > "tmdb 和豆瓣的订阅增加后 —— 先搜索本地库是否有，存在的话直接从
/// >  emby 服务端收藏 = 订阅，没有的话提示，订阅暂未入库。"
///
/// ## 三步
/// ① **搜本地库**（`aggregatedSearchProvider`，并行搜所有已登录服务器）
/// ② **命中** ⇒ 写 Emby 收藏（`toggleFavorite`）+ 写本地订阅表
/// ③ **未命中** ⇒ **什么都不写**，返回 [SubscribeOutcome.notInLibrary]
///
/// ## ⚠️ 为什么未命中时不能写本地订阅表
/// 写了的话，首页「我的追剧」会出现一部**库里没有、也播不了**的剧 ——
/// 用户点进去只会"找不到"。用户明确要求这种情况下**提示**而不是静默记录。
///
/// ## 为什么用标题搜（而不是用 tmdbId 精确查）
/// · 豆瓣条目**没有 tmdbId**（两个体系不通），只能靠标题
/// · 即便有 tmdbId，Emby 也没有"按 tmdbId 查询"的公开端点
///   （只能 `AnyProviderIdEquals`，实测不覆盖全部条目）
/// ⇒ 标题搜索 + **首条即认**（用户点的是具体某部剧，搜出来第一条通常就是）。
///    若需要更精确，可后续加"二次确认"弹窗。
///
/// ## 传 [entry] 的情况（日历/TMDB 详情页）
/// 那两处的条目**自带海报/评分/简介**（比搜出来的 Emby 条目更全），
/// 且 `sourceId` 就是 tmdbId ⇒ **订阅表用它**，身份更稳。
/// 但"是否在库里"仍然要搜（那是本函数的核心价值）。
Future<SubscribeResult> subscribeExternal({
  required WidgetRef ref,
  required String title,
  required String mediaType, // 'tv' | 'movie'
  String? platform,
  String? category,
  String? status,
  double? rating,
  String? posterUrl,
  String? summary,
  /// 外部源自带的条目（有则用它写订阅表，保留海报/评分/简介）。
  CalendarEntry? entry,
  /// 是否**取消**订阅（true = 取消）。
  ///
  /// ## 为什么需要这个开关
  /// 用户点"已追"时要**取消**。而取消**不需要**"先搜库"
  ///（库里有没有都该能取消 —— 否则用户会卡在"已追"出不来）。
  bool unsubscribe = false,
}) async {
  final t = title.trim();
  if (t.isEmpty) {
    return const SubscribeResult(SubscribeOutcome.failed, error: '标题为空');
  }

  // ★ 取消路径：不搜库、直接删（已追的必须能取消）
  if (unsubscribe && entry != null) {
    try {
      final now = await toggleCalendarSubscription(
        ref,
        entry: entry,
        mediaType: mediaType,
        status: status ?? '',
      );
      return SubscribeResult(
          now ? SubscribeOutcome.subscribed : SubscribeOutcome.unsubscribed,
          title: entry.displayTitle);
    } catch (e) {
      return SubscribeResult(SubscribeOutcome.failed, title: t, error: '$e');
    }
  }

  // ① 先搜本地库
  List<ServerSearchResult> results;
  try {
    results = await ref.read(aggregatedSearchProvider(t).future);
  } catch (e) {
    return SubscribeResult(SubscribeOutcome.failed,
        title: t, error: '搜索本地库失败：$e');
  }

  // 找第一条命中的（跨台聚合后的主条目）
  MediaItem? hit;
  MediaSession? hitSession;
  for (final r in results) {
    if (r.hits.isEmpty) continue;
    hit = r.hits.first.item;
    hitSession = r.session;
    break;
  }

  // ③ 未命中 ⇒ 什么都不写
  if (hit == null) {
    return SubscribeResult(SubscribeOutcome.notInLibrary, title: t);
  }

  // ② 命中 ⇒ 写 Emby 收藏 + 本地订阅表
  try {
    final tmdbId = hit.providerIds['tmdb'];
    // ★ 有外部源的 entry 就用它（海报/评分/简介更全，且 sourceId = tmdbId）
    final subEntry = entry ?? CalendarEntry(
      title: hit.name,
      titleCn: hit.name,
      source: (tmdbId != null && tmdbId.isNotEmpty) ? 'tmdb' : 'emby',
      sourceId: (tmdbId != null && tmdbId.isNotEmpty) ? tmdbId : hit.id,
      posterUrl: posterUrl,
      rating: hit.communityRating ?? rating,
      summary: summary,
      platform: platform,
      category: _categoryFor(category),
      airDate: null,
    );
    final now = await toggleCalendarSubscription(
      ref,
      entry: subEntry,
      mediaType: hit.type == 'Movie' ? 'movie' : (mediaType.isEmpty ? 'tv' : mediaType),
      status: status ?? _statusCn(hit.status) ?? '',
    );

    // Emby 收藏（= 服务端订阅，跨设备同步）
    if (hitSession != null) {
      try {
        final apis = await ref.read(accountApisProvider.future);
        final api = apis[SessionStore.accountKey(hitSession)];
        await api?.toggleFavorite(hit.id, favorite: now);
      } catch (e) {
        // 本地订阅已写成功 ⇒ 服务端失败只降级提示，不回滚
        debugPrint('[Subscribe] 同步 Emby 收藏失败: $e');
      }
    }

    return SubscribeResult(
        now ? SubscribeOutcome.subscribed : SubscribeOutcome.unsubscribed,
        title: hit.name);
  } catch (e) {
    return SubscribeResult(SubscribeOutcome.failed, title: t, error: '$e');
  }
}

/// 外部源的类别字符串 → 日历类别（**近似**：只有三档）。
CalendarCategory _categoryFor(String? c) => switch (c) {
      '动漫' || '动画' => CalendarCategory.anime,
      '综艺' || '真人秀' => CalendarCategory.variety,
      _ => CalendarCategory.series,
    };

/// Emby 的 `Status` → 中文（订阅表存中文，与详情页一致）。
String? _statusCn(String? s) => switch (s) {
      'Continuing' => '连载中',
      'Ended' => '已完结',
      _ => null,
    };

/// **平台名兜底**：把一批 tmdbId 换成交中文平台名（`tmdbId → 平台名`）。
///
/// ## 为什么做成 `family`（按 id 集合缓存）
/// 首页轮播是 5 个 `_Slide` 各自 build。若每个 slide 自己查平台，
/// 同一部剧会**重复发请求**。`family` 以"需要补查的 id 集合"为键
/// ⇒ 整页只查一次，且结果被 riverpod 缓存。
///
/// ## 返回空 Map 的两种情况（都不是错误）
/// · 没填 TMDB key（用户没配）⇒ 跳过，不如实不显示
/// · 全都命中服务端了 ⇒ 不需要补查
final platformFallbackProvider =
    FutureProvider.family<Map<String, String>, String>((ref, idsKey) async {
  if (idsKey.isEmpty) return const {};
  final ids = idsKey.split(',').where((s) => s.isNotEmpty).toList();
  final key = await ref.watch(sessionStoreProvider).loadTmdbKey();
  if (key == null || key.isEmpty) return const {};
  return ref.watch(calendarClientProvider).fetchPlatformsByTmdbIds(
        ids,
        apiKey: key,
      );
});

final calendarClientProvider = Provider<CalendarClient>((ref) {
  final c = CalendarClient();
  final db = ref.watch(appDbProvider);
  // 复用既有的 drift 缓存表（与豆瓣同一套 cacheGet/cachePut）
  c.cache = DriftCalendarCache(db);
  return c;
});

/// 本周日历数据。
///
/// ## TMDB key 从哪来（**绝不入库**）
/// 用户可在「我的 → 追剧日历设置」里填自己的 TMDB API key，
/// 存 `flutter_secure_storage`（与 Emby 凭据同一套机制）。
/// 未填 ⇒ 跳过 TMDB 源（它只是辅助：TMDB 没有"按日"端点）。
final calendarWeekProvider = FutureProvider.autoDispose<WeekCalendar>((
  ref,
) async {
  final client = ref.watch(calendarClientProvider);
  final key = await ref.watch(sessionStoreProvider).loadTmdbKey();
  return client.fetchWeek(tmdbKey: key);
});


// ══════════════════════════════════════════════════════════
// 追剧订阅（用户：「我的追剧」= 追剧日历里**订阅**的内容）
// ══════════════════════════════════════════════════════════
//
// ## 为什么是独立的一组 provider（不复用 calendarWeekProvider）
// · `calendarWeekProvider` 是**外部源**的数据（TMDB/B站），6h 缓存、可能失败
// · 订阅是**本地数据**（drift），永远可读、不会失败
// 两者生命周期与失败语义完全不同 ⇒ 混在一起会让"源挂了"连带订阅也空。

/// 订阅键集合（形如 `tmdb:12345:tv`）。
///
/// ## 为什么单独一个 provider（而不是从列表推导）
/// 日历一天 30 条、整周 240 条 ⇒ 每条都查一次库是 240 次查询。
/// 一次查出 Set 后本地判断是 O(1)。
final subscribedKeysProvider = FutureProvider<Set<String>>((ref) async {
  final db = ref.watch(appDbProvider);
  return db.subscribedKeys();
});

/// 全部订阅（按"最近更新日"倒序）。
///
/// ⚠️ **不 autoDispose**：首页「我的追剧」与日历页都要用；
///    autoDispose 会让每次切页都重查库。
final subscriptionsProvider = FutureProvider<List<CalendarSubscription>>((
  ref,
) async {
  final db = ref.watch(appDbProvider);
  return db.allSubscriptions();
});

/// **订阅/取消订阅**（唯一写入口）。
///
/// ## 为什么写成一个顶层函数而不是 Notifier 方法
/// 调用点有 2 处（日历卡片、详情弹层），都只需要"toggle + 刷新"。
/// 用函数可以保证**两处刷新逻辑一致**（不会有一处漏 invalidate）。
///
/// ## 返回
/// `true` = 现在已订阅；`false` = 现在未订阅。
/// ## 为什么收 \WidgetRef\ 而不是 \Ref\（riverpod 3 的类型约束）
///
/// riverpod 3 把两者分开了：
/// · \Ref\ —— provider 内部用
/// · \WidgetRef\ —— widget 里用
/// 它们**没有公共父类**，但 \invalidate\ 语义一样。
/// ⇒ 收 \Ref\ 会让 widget 调用处编译不过（实测报
///   "The argument type 'WidgetRef' can't be assigned to 'Ref'"）。
///
/// 唯一调用方是 UI（日历星标按钮）⇒ 收 \WidgetRef\。
/// 若将来 provider 内部也要 toggle，再抽只收 db 的底层函数。
Future<bool> toggleCalendarSubscription(
  WidgetRef ref, {
  required CalendarEntry entry,
  required String mediaType,
  String status = '',
}) async {
  final db = ref.read(appDbProvider);
  final now = await db.toggleSubscription(
    source: entry.source,
    sourceId: entry.sourceId ?? entry.displayTitle,
    mediaType: mediaType,
    title: entry.displayTitle,
    titleCn: entry.titleCn ?? '',
    posterUrl: entry.posterUrl ?? '',
    platform: entry.platform ?? '',
    category: entry.category.name,
    lastAirDate: entry.airDate ?? '',
    // 状态（"连载中"/"已完结"）—— 用户要求区分。
    // 由调用方传入（日历下拉取才知道），拿不到就空串（UI 不显示标签）。
    status: status,
  );
  // 两个 provider 都要刷（一个给"是否已订阅"的按钮状态，
  // 一个给首页/日历的订阅列表）
  ref.invalidate(subscribedKeysProvider);
  ref.invalidate(subscriptionsProvider);
  return now;
}
