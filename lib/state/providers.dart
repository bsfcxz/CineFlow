/// 应用状态（riverpod）：会话、API 实例、首页数据
library;

// `&` 是 drift 给 `Expression<bool>` 重载的 SQL AND（`where` 里用）。
// ⚠️ 不加这个 import 会报 "The operator '&' isn't defined"。
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import 'package:flutter/foundation.dart' show debugPrint;

// `statusCnOf` —— 状态规范化（Emby 的 `Continuing` → 「连载中」）。
// ⚠️ 同步写订阅表时**必须**用它：直接存英文原值会让卡片显示
//    `Continuing`（真机踩到）。
import '../pages/tracking_page.dart' show statusCnOf;
// `danmakuClientProvider` —— 复用用户已配好的弹幕源
// （弹弹play 兼容 API 已统一 20+ 平台，见 platform_episodes.dart）
import '../danmaku/danmaku_providers.dart';
import '../data/platform_episodes.dart';
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
    // ⚠️ 三处失效**都要**（用户上报："切换账户却访问不到数据"）：
    //  · `embyApiProvider`      = 当前会话的 API 实例（首页/详情/播放用）
    //  · `accountsProvider`     = 账号列表（聚合搜索用；它 watch 了
    //                             `sessionProvider.future`，但显式失效更稳，
    //                             免得依赖"恰好会重算"这种巧合）
    //  · `accountApisProvider`  = 每账号一套 API（依赖 accountsProvider）
    // 漏掉后两者 ⇒ 切换后搜索仍打旧服务器（或结果为空）。
    ref.invalidate(embyApiProvider);
    ref.invalidate(accountsProvider);
    ref.invalidate(accountApisProvider);
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
    // 与 switchTo 同理：退出也要让聚合列表跟着变（否则搜索还打已退出的台）
    ref.invalidate(embyApiProvider);
    ref.invalidate(accountsProvider);
    ref.invalidate(accountApisProvider);
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

/// **背景样式**状态（用户 2026-10-14 要求：白色 / 毛玻璃 / 透明 0-100）。
///
/// ## 为什么与 `themeIndexProvider` 分开
/// 两者**正交**：用户可以"粉色主题 + 毛玻璃背景"。
/// 合成一个状态会让"只想换背景"的人**连带换掉强调色**（不是他要的）。
///
/// ## 为什么用 Notifier 而不是直接改 `Cf.bgStyle`
/// `Cf.bgStyle` 是**静态可变字段**（与 `Cf.bg` 同款），改了它
/// **不会触发重建** ⇒ 界面不刷新。`Notifier` 的作用是让根 widget
/// 监听它并重建（`main.dart` 已用 `themeIndexProvider` 做同样的事）。
class BgStyleNotifier extends Notifier<CfBgKind> {
  @override
  CfBgKind build() => CfBgKind.dark;

  void set(CfBgKind v) => state = v;
}

final bgStyleProvider =
    NotifierProvider<BgStyleNotifier, CfBgKind>(BgStyleNotifier.new);

/// 首页顶栏齿轮 → 切到「我的」Tab
class HomeTabNotifier extends Notifier<int> {
  @override
  int build() => 0;
  void set(int i) => state = i;
}

final homeTabProvider =
    NotifierProvider<HomeTabNotifier, int>(HomeTabNotifier.new);

/// 当前可用的 MediaProvider（未登录为 null）。
///
/// ## ⚠️ 关于 `.value` 的**更正**（我一度判断错）
/// 我曾以为"`.value` 在 `AsyncLoading` 期间是 null ⇒ 假未登录"，
/// 并为此加了"最后一次会话"兜底。**那个判断是错的** ——
/// riverpod 2.6.1 源码（`common.dart:205-217`）写着：
/// ```
/// /// It will return the previous value during loading/error state.
/// /// If there is no previous value, reading [value] during loading
/// /// state will return null.
/// T? get value;
/// ```
/// ⇒ `.value` **在 loading 期间返回上一次的值**，不会假 null。
/// 只有"**从未有过值**"时才 null —— 那种情况确实就是未登录。
/// ⇒ 兜底代码已删除（它基于错误前提，且会**掩盖真问题**）。
///
/// ## 那"切换账户后访问不到数据"的真因是什么
/// 见 `profile_page._testLatency` 与 `EmbyProvider` 的 401 处理：
/// 测延迟打的是**免鉴权**的 `/System/Info/Public` ⇒ token 失效也"成功"
/// ⇒ 用户切过去才 401。**与本 provider 无关。**
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

/// **自动同步服务端收藏 → 本地订阅表**（追剧 Tab 每次加载时跑，幂等）。
///
/// ## 用户诉求（多次强调）
/// > "追剧按钮不是同步 emby 服务端的收藏按钮嘛"
/// > "追剧中的订阅还没同步嘛。"
///
/// ⇒ 用户的模型：**追剧 = 服务端收藏**。
///   服务端收藏了什么，追剧 Tab 就该显示什么。
///
/// ## 现状为什么"没同步"
/// · **写**：点「追剧」→ 已同时写 Emby 收藏 + 本地表 ✅
/// · **读**：追剧 Tab 只读**本地表** ⇒ 服务端新增的收藏
///   （在 Emby 网页/其他客户端点的）**不会出现** ❌
///
/// ## 本次修法：把服务端当**事实来源**
/// ```
/// ① 每台 getItems(filters:'IsFavorite') → 服务端收藏清单
/// ② 以 providerIds['tmdb'] 为键（唯一稳定标识，标题会变）
/// ③ 不在本地表的 ⇒ 补进去
/// ```
///
/// ## ⚠️ **只增不删**（重要）
/// 本地可能有"**库里没有**"的外部订阅（先订阅、等入库）
/// ⇒ 删掉会让用户丢失它们。**取消收藏不在这里处理**
///（那要走详情页的「已追 → 追剧」按钮，有明确的用户意图）。
///
/// ## 返回新增条数（幂等 ⇒ 重复调用返回 0）
Future<int> syncFavoritesToSubscriptions({required WidgetRef ref}) async {
  final apisMap = await ref.read(accountApisProvider.future);
  if (apisMap.isEmpty) return 0;
  final db = ref.read(appDbProvider);
  final local = await db.allSubscriptions();
  // 主键三元组 → 该行
  final byKey = <(String, String, String), CalendarSubscription>{
    for (final s in local) (s.source, s.sourceId, s.mediaType): s,
  };
  var added = 0;

  // ⚠️ 日志**不打完整服务器地址**（AGENTS 安全红线）—— 只打序号。
  var idx = 0;
  final seen = <(String, String, String)>{};
  // ★★ **fail-safe 计数器**（我漏了它 ⇒ 删光了用户订阅，见下方注释）
  var okServers = 0;
  var failServers = 0;
  for (final api in apisMap.values) {
    idx++;
    var thisServerOk = false;
    for (final type in const ['Series', 'Movie']) {
      final mt = type == 'Movie' ? 'movie' : 'tv';
      try {
        final page = await api.getItems(
          includeTypes: type,
          filters: 'IsFavorite',
          recursive: true,
          limit: 500,
        );
        thisServerOk = true;   // 至少一个类型取到了 ⇒ 这台可信
        for (final it in page.items) {
          final tmdb = it.providerIds['tmdb'];
          // 没 tmdbId 就跳过：本地表以 tmdbId 为键，用 Emby 内部 id
          // 会在换服务器后失配。
          if (tmdb == null || tmdb.isEmpty) continue;
          final key = ('tmdb', tmdb, mt);
          seen.add(key);
          // ⚠️ **必须用 `ensureSubscribed`（幂等），不能用 `toggle`（翻转）**
          //    —— 真实事故：用 toggle 会让每次同步把上次写入的又取消掉，
          //    现象是订阅"忽有忽无"。详见 `ensureSubscribed` 的注释。
          final existed = byKey.containsKey(key);
          await ensureSubscribed(
            ref,
            entry: CalendarEntry(
              title: it.name,
              source: 'tmdb',
              sourceId: tmdb,
              posterUrl: it.posterUrl(api, maxWidth: 320),
              platform: it.studios.isNotEmpty
                  ? CalendarClient.cnPlatformName(it.studios.first)
                  : null,
              airDate: it.dateCreated,
              category: CalendarCategory.series,
            ),
            mediaType: mt,
            // ★ 用 `statusCnOf` 规范化 —— 直接存 `Continuing` 会让
            //   卡片显示英文（真机踩到）。
            status: statusCnOf(it.status),
          );
          if (!existed) added++;
        }
      } catch (e) {
        debugPrint('[Sync] 第 $idx 台的 $type 收藏同步失败: $e');
      }
    }
    if (thisServerOk) {
      okServers++;
    } else {
      failServers++;
    }
  }

  // ══════ 反向：服务端**没有**的订阅怎么处理（三条规则）══════
  //
  // ## 规则（`syncedToServer` 是安全阀门）
  // | 服务端 | 本地 synced | 动作 |
  // |---|---|---|
  // | 有 | 任意 | 上面已 upsert，这里**标记 true** |
  // | 没有 | true | 用户**在服务端取消**了 ⇒ **删本地** |
  // | 没有 | false | 本地外部订阅（库里没有、没写过收藏）⇒ **保留** |
  //
  // ## 为什么第 3 条必须有
  // "先订阅、等入库"的剧在服务端**没有**收藏（订阅时库里没命中）⇒
  // 若"服务端没有就删"，会把这些全删掉（正是上次 uninstall 的痛）。
  final gone = <(String, String, String)>{};
  for (final e in byKey.entries) {
    if (seen.contains(e.key)) continue;
    // `source` 不是 tmdb 的（B站/Bangumi 等外部源）一律保留
    if (e.key.$1 != 'tmdb') continue;
    if (e.value.syncedToServer) gone.add(e.key);
  }
  if (seen.isNotEmpty) await db.markSubsSynced(seen);

  // ══════ ★★★ **删除的 fail-safe**（我漏了它 ⇒ 删光用户订阅）══════
  //
  // ## 事故（2026-10-13，我造成的）
  // 两台服务器都 `SocketException: Permission denied` ⇒ `seen` 为空
  // ⇒ 我的代码把"**取数失败**"当成了"**用户在服务端取消了**"
  // ⇒ `deleteSubscriptions(gone)` **删掉 11 部订阅**。
  //
  // ## 根因：`seen` 为空有两种**完全不同**的含义
  // | 含义 | 正确动作 |
  // |---|---|
  // | 所有服务器都**查询失败** | **什么都不做**（数据不可信）|
  // | 服务器**正常响应**但确实没这部 | 可以删（用户取消了）|
  // 我把两者混为一谈 ⇒ 一断网就删光。
  //
  // ## fail-safe 判据（保守优先）
  // **只要有任一服务器失败，就完全跳过删除** ——
  // 本仓库有两台，一台失败说明视图不完整，
  // 那台上的收藏可能正是"看起来被删"的那些。
  // 宁可"该删的没删"（下次同步会补上），
  // 绝不"不该删的删了"（**用户数据不可恢复**，见 AGENTS §6.9）。
  if (failServers > 0) {
    debugPrint('[Sync] ⚠️ $failServers 台服务器取数失败 ⇒ '
        '**跳过删除阶段**（宁可漏删，不可误删）');
  } else if (gone.isNotEmpty) {
    await db.deleteSubscriptions(gone);
    debugPrint('[Sync] 服务端已取消收藏 ⇒ 移除本地订阅 ${gone.length} 部'
        '（$okServers 台全部成功）');
  }
  if (added > 0) debugPrint('[Sync] 从服务端收藏同步 $added 部订阅');
  return added;
}

/// **幂等地确保订阅存在**（存在则不动，不存在则插入）。
///
/// ## ★ 为什么不能复用 `toggleCalendarSubscription`
/// `toggle` 的语义是**翻转**（已订阅 ⇒ 取消）。
/// 而同步要的是**状态收敛**（让本地 = 服务端的收藏集合）。
///
/// ## 真实事故（2026-10-13，我造成的）
/// 同步里写成：
/// ```dart
/// await toggleCalendarSubscription(...);   // ← toggle！
/// ```
/// ⇒ 每次同步把**上次刚写进去的**又取消掉：
/// ```
/// 第 1 次 → 11 部不存在 ⇒ 加上 ⇒ 11 部 ✅
/// 第 2 次 → 11 部已存在 ⇒ **取消** ⇒ 0 部 ❌
/// 第 3 次 → 加上 ⇒ 11 部 ✅
/// 第 4 次 → 取消 ⇒ 0 部 ❌
/// ```
/// 现象就是"订阅忽有忽无"（用户报障 + 我看到的 0 部）。
///
/// ## 为什么"已存在就什么都不做"
/// 不覆盖 —— 用户可能手动改过平台/状态；且**覆盖会丢数据**。
/// 真正的字段更新由其它路径负责（详情页追剧按钮）。
///
/// ## 返回
/// `true` = 本次**新增**了；`false` = 已存在（未改动）。
Future<bool> ensureSubscribed(
  WidgetRef ref, {
  required CalendarEntry entry,
  required String mediaType,
  String status = '',
}) async {
  final db = ref.read(appDbProvider);
  final sid = entry.sourceId ?? entry.displayTitle;
  // 先查：已存在 ⇒ **什么都不做**（幂等，且不覆盖用户可能改过的字段）
  final existing = await (db.select(db.calendarSubscriptions)
        ..where((t) =>
            t.source.equals(entry.source) &
            t.sourceId.equals(sid) &
            t.mediaType.equals(mediaType))
        ..limit(1))
      .getSingleOrNull();
  if (existing != null) return false;

  // 不存在 ⇒ 用**已有的** `toggleSubscription` 写入。
  //
  // ⚠️ 既然上面已确认不存在，`toggle` 在这里**必然走"添加"分支**
  //    ⇒ 语义正确，且**不新造写入路径**（少一处要维护的一致性风险）。
  //    这就是修 bug 的关键：**先判断，再决定要不要 toggle**
  //    —— 而不是无条件 toggle（那会"有则删"，把同步变成翻转）。
  await db.toggleSubscription(
    source: entry.source,
    sourceId: sid,
    mediaType: mediaType,
    title: entry.displayTitle,
    titleCn: entry.titleCn ?? '',
    posterUrl: entry.posterUrl ?? '',
    platform: entry.platform ?? '',
    category: entry.category.name,
    lastAirDate: entry.airDate ?? '',
    status: status,
  );
  ref.invalidate(subscribedKeysProvider);
  ref.invalidate(subscriptionsProvider);
  return true;
}

/// **从服务端收藏恢复本地订阅**（uninstall 事故后的补救）。
///
/// ## 背景（真实事故，见 AGENTS.md §6.9）
/// 我用 `adb uninstall` 清空了本地 `calendar_subscriptions`（21 部订阅）。
/// 但**服务端的 Emby 收藏还在**（实测两台共 26 条）——
/// 因为订阅时"库里命中 ⇒ 同时写 Emby 收藏"。
/// ⇒ 可以从收藏**反查 tmdbId 并重建本地订阅**。
///
/// ## 覆盖范围（诚实说明）
/// · 只能恢复"**订阅时库里有**"的那些（当时才写了收藏）
/// · 库里没有的（先订阅、等入库）**当时没写收藏** ⇒ 恢复不了
/// · 实测两台收藏 26 条，与订阅对上的约 7~14 部（取决于名称匹配）
///
/// ## 匹配策略
/// 服务端收藏的 `Name` 与订阅表可能不完全一致（带"第三季/年番"后缀）
/// ⇒ 用 `tmdbId` 为准（那是唯一稳定标识），标题只用于**展示**。
Future<int> restoreSubscriptionsFromFavorites({
  required WidgetRef ref,
  String? tmdbKey,
}) async {
  final apisMap = await ref.read(accountApisProvider.future);
  final db = ref.read(appDbProvider);
  final existing = await db.allSubscriptions();
  final have = existing.map((s) => s.sourceId).toSet();
  var added = 0;

  for (final api in apisMap.values) {
    for (final type in const ['Series', 'Movie']) {
      List<MediaItem> favs;
      try {
        // ⚠️ `getFavorite()` **不存在**（我第一版凭想象写的）——
        //    用已有的 `getItems(filters: 'IsFavorite')`。
        //    实测：`GET /Items?IncludeItemTypes=Series&Filters=IsFavorite
        //    &Fields=ProviderIds` → iLoveHD 15 部 / HK-Emby 10 部。
        final page = await api.getItems(
          includeTypes: type,
          filters: 'IsFavorite',
          recursive: true,
          limit: 500,
          sortBy: 'SortName',
          sortOrder: 'Ascending',
        );
        favs = page.items;
      } catch (e) {
        debugPrint('[Restore] $type 收藏读取失败（跳过）: $e');
        continue;
      }
      for (final it in favs) {
        final tmdb = it.providerIds['tmdb'];
        if (tmdb == null || tmdb.isEmpty) continue;
        if (!have.add(tmdb)) continue; // 已有订阅 / 本条已处理
        await toggleCalendarSubscription(
          ref,
          entry: CalendarEntry(
            title: it.name,
            source: 'tmdb',
            sourceId: tmdb,
            posterUrl: it.posterUrl(api, maxWidth: 320),
            platform: it.studios.isNotEmpty
                ? CalendarClient.cnPlatformName(it.studios.first)
                : null,
            airDate: it.dateCreated,
            category: switch (type) {
              'Movie' => CalendarCategory.series, // 电影在订阅表按 tv/movie 存
              _ => CalendarCategory.series,
            },
          ),
          mediaType: type == 'Movie' ? 'movie' : 'tv',
          status: it.status ?? '',
        );
        added++;
      }
    }
  }
  debugPrint('[Restore] 从收藏恢复 $added 部订阅');
  return added;
}

/// **继续观看（聚合所有已登录服务器）**。
///
/// ## 用户要求
/// > "继续观看你也要聚合一下哦"
///
/// ## 为什么原来的不够（真机实测）
/// `_historyProvider` 用 `embyApiProvider` = **当前会话那一台**。
/// 用户有两台（iLoveHD / HK-Emby），在另一台看了一半的内容
/// **不会出现在继续观看里** —— 与"周历只查一台"是同一类错误。
///
/// ## 合并规则（去重 + 排序）
/// · 去重键：`(serverId, itemId)` —— 两台可能各有一份同一部片，
///   那是**两条不同的续播记录**（进度可能不同），不能按名字去重
/// · 排序：按 `userData.lastPlayedDate` 倒序（最近看的在前）
///   ⚠️ 缺日期的排最后（不能当"最旧"的正序插入 —— 那会让它们挤到中间）
final aggregatedResumeProvider =
    FutureProvider.autoDispose<List<MediaItem>>((ref) async {
  // ⚠️ `accountApisProvider` 是 FutureProvider<Map> ⇒ 必须 await
  final apisMap = await ref.watch(accountApisProvider.future);
  if (apisMap.isEmpty) return const [];
  final lists = await Future.wait(apisMap.values.map((a) async {
    try {
      return await a.getResume(limit: 60);
    } catch (e) {
      debugPrint('[Resume] 某台失败（忽略）: $e');
      return const <MediaItem>[];
    }
  }));
  // ⚠️ `MediaItem` **没有** `serverId` / `userData` / `lastPlayedDate`
  //    （那些是 Emby 线格式，未映射成对象）—— 我第一版又凭记忆写了不存在的字段。
  //    实际可用：`id` / `seriesId` / `indexNumber` / `playedPercentage`。
  //
  // ## 去重键：同一部剧在两台各有一条续播 ⇒ 保留**进度更靠前**的那条
  // 键 = `(seriesId ?? id, indexNumber ?? 0)`
  // · 剧集 ⇒ 同一部剧同集，两台各一份（进度不同）
  // · 电影 ⇒ `seriesId` 为 null，退化成 `(id, 0)`
  final byKey = <String, MediaItem>{};
  for (final list in lists) {
    for (final it in list) {
      final k = '${it.seriesId ?? it.id}/${it.indexNumber ?? 0}';
      final prev = byKey[k];
      if (prev == null) {
        byKey[k] = it;
        continue;
      }
      // 进度更靠前的胜出（null 当 0）
      final a = prev.playedPercentage ?? 0;
      final b = it.playedPercentage ?? 0;
      if (b > a) byKey[k] = it;
    }
  }
  final out = byKey.values.toList();
  // ## 排序：`playedPercentage` 降序
  //
  // ⚠️ **次优选择**（已记录）：理想是按"最近播放时间"，但 `MediaItem`
  //    没有映射 `UserData.LastPlayedDate`。退而求其次用"看了多少"——
  //    看了一半的比刚开头的更可能想接着看。
  //    要改对需给 `MediaItem` 加 `lastPlayedDate` 字段（另开一轮）。
  out.sort((a, b) =>
      (b.playedPercentage ?? 0).compareTo(a.playedPercentage ?? 0));
  return out;
});

/// **某剧的库内摘要**（按 `tmdbId` 查；详情页用）。
///
/// ## 为什么按 tmdbId（而不是 Emby 的 SeriesId）
/// 详情页手上只有 `tmdbId`（来自外部源）⇒ 需要先映射一次
/// （`mapSeriesTmdbToId`，1 个请求），再取摘要。
///
/// ## 缓存
/// `FutureProvider.family` 自带缓存（同一部剧反复打开详情页不会再请求）。
/// 要刷新用 `ref.invalidate`。
/// **平台侧集数缓存**（`标题 → PlatformEpisodes`，内存 + TTL）。
///
/// ## 为什么需要缓存
/// 一次追剧页加载会对**每部订阅**查一次（2 次请求/部）。
/// 上游是**第三方免费实例** —— 反复拉会被限流
/// （本仓库踩过"42 并发请求全部超时"，见 `AI-MEMORY.md`）。
/// 而平台集数**一天最多变几次** ⇒ 30 分钟 TTL 足够且省得多。
class PlatformEpisodesCache {
  final Map<String, PlatformEpisodes?> _mem = {};
  final Map<String, int> _at = {};
  static const _ttlMs = 30 * 60 * 1000;

  PlatformEpisodes? get(String key, int nowMs) {
    final t = _at[key];
    if (t == null || nowMs - t > _ttlMs) return null;
    return _mem[key];
  }

  bool has(String key, int nowMs) {
    final t = _at[key];
    return t != null && nowMs - t <= _ttlMs;
  }

  void put(String key, PlatformEpisodes? v, int nowMs) {
    _mem[key] = v;
    _at[key] = nowMs;
  }
}

/// 进程内单例（页面重建不丢缓存）
final _platformCache = PlatformEpisodesCache();

/// **批量取平台集数**（给追剧页用）。
///
/// ## 参数
/// · `titles` —— 订阅的剧名列表（通常 ≤ 30 部）
///
/// ## 行为
/// · 并发限制 **4**（对上游友好；`danmakuClient` 内部串行不住的话会打爆）
/// · 命中缓存的不再请求
/// · 单个失败只影响那一部（`null` 值也会写缓存 ⇒ 缺字段的剧不会反复重试）
/// · 未配置弹幕源 ⇒ 直接返回空 Map（不是错误）
///
/// ## 返回
/// `标题 → PlatformEpisodes?`（值为 null = 查过但拿不到）
Future<Map<String, PlatformEpisodes?>> fetchPlatformEpisodesBatch({
  required WidgetRef ref,
  required List<String> titles,
}) async {
  final out = <String, PlatformEpisodes?>{};
  if (titles.isEmpty) return out;

  // ★★ **必须等配置就绪**（本仓库第 8 次踩同一个坑）
  //
  // ## 坑的形状
  // `danmakuClientProvider` 内部：
  // ```dart
  // final cfg = ref.watch(danmakuConfigProvider).value;  // AsyncNotifierProvider
  // if (cfg == null || !cfg.isUsable) return null;       // 未就绪 ⇒ null
  // ```
  // `AsyncNotifierProvider` 首次读是 `loading` ⇒ `.value == null`
  // ⇒ client 为 null ⇒ 我原来 `if (client == null) return out;` **静默跳过**。
  //
  // 现象：chips 不出现、**日志也没有**（连"[Platform]"都不打）——真机实测踩到。
  //
  // ⇒ 规约（`AGENTS.md` §6 与 `AI-MEMORY.md` 反复记）：**读 provider 要
  //   `await ...future`，不要读 `.value`**。
  final cfg = await ref.read(danmakuConfigProvider.future);
  if (!cfg.isUsable) {
    debugPrint('[Platform] 弹幕源不可用（${cfg.kind.name}）⇒ 跳过平台集数');
    return out;
  }
  final client = ref.read(danmakuClientProvider);
  if (client == null) {
    debugPrint('[Platform] 客户端未就绪 ⇒ 跳过');
    return out;
  }
  final now = DateTime.now().millisecondsSinceEpoch;

  // ① 先吃缓存
  final todo = <String>[];
  for (final t in titles) {
    final k = t.trim();
    if (k.isEmpty) continue;
    if (_platformCache.has(k, now)) {
      out[k] = _platformCache.get(k, now);
    } else {
      todo.add(k);
    }
  }
  if (todo.isEmpty) return out;

  // ② 限并发 4（与 danmaku 匹配同一策略）
  const batchSize = 4;
  for (var i = 0; i < todo.length; i += batchSize) {
    final batch = todo.skip(i).take(batchSize).toList();
    await Future.wait(batch.map((t) async {
      PlatformEpisodes? r;
      try {
        r = await client.fetchPlatformEpisodes(t);
      } catch (e) {
        debugPrint('[Platform] 「$t」查询失败（忽略）: $e');
        r = null;
      }
      out[t] = r;
      // ⚠️ **null 也写缓存** —— 否则缺数据的剧每次进页面都重试
      _platformCache.put(t, r, now);
    }));
  }
  debugPrint('[Platform] 平台集数：请求 ${todo.length} 部，'
      '缓存命中 ${titles.length - todo.length} 部');
  return out;
}

/// **库内摘要**（已入库集数 / 已更新集号 / 下次更新日）。
///
/// ## 参数
/// · `arg` —— `"<tmdbId>|<titleHint>"` 组合键。
///   ## ★ 为什么要把剧名编进 family 参数（而不是另加一个 family）
///   第三级来源（本地 `anime_timelines`）**按剧名查**。而服务器离线时
///   拿不到剧名 —— 必须由调用方传进来。`FutureProvider.family` 只接受
///   一个参数 ⇒ 用 `|` 拼（tmdbId 是纯数字，剧名可能带 `|`，
///   故用 `indexOf` 从**第一个** `|` 切，剩下全是剧名）。
final librarySummaryProvider =
    FutureProvider.family<LibrarySummary?, String>((ref, arg) async {
  final bar = arg.indexOf('|');
  final tmdbId = bar < 0 ? arg : arg.substring(0, bar);
  final titleHint = bar < 0 ? '' : arg.substring(bar + 1);
  if (tmdbId.isEmpty) return null;
  final apisMap = await ref.watch(accountApisProvider.future);
  // 遍历所有已登录服务器：任一台上找到就用（**多账号聚合**）
  LibrarySummary? best;
  for (final api in apisMap.values) {
    try {
      final map = await api.mapSeriesTmdbToId();
      final ref0 = map[tmdbId];
      if (ref0 == null || ref0.seriesId.isEmpty) continue;
      final sum = await api.getLibrarySummary(ref0.seriesId);
      if (sum != null && sum.episodeCount > 0) {
        // 取**集数最多**的那台（用户可能在多台都有，集数多的更全）
        if (best == null || sum.episodeCount > best.episodeCount) {
          best = sum;
        }
        // 已有"下次更新日"就不用再找别台了
        if (sum.nextAirDate != null) break;
      }
    } catch (e) {
      debugPrint('[Library] 摘要查询失败（换下一台）: $e');
    }
  }
  // ★★★ 修：`best == null` **不再直接 return**（2026-10-13，真机报障"下次更新标签呢"）
  //
  // ## 原来的错
  // ```dart
  // if (best == null) return null;          // 服务器连不上 ⇒ 早退
  // ...
  // final row = await db.timelineFor(...);  // 本地时刻表 ⇒ 永远跑不到
  // ```
  // 而 `anime_timelines` 是**纯本地表**（0 网络、不需要 TMDB key），
  // 它的价值**恰恰在于**"服务器拿不到时也能给下次更新" ——
  // 却被挡在"必须先有服务器数据"之后 ⇒ 服务器一离线就彻底失效。
  //
  // ## 修法
  // 没有 `best` 时**仍然**查本地时刻表；查到就给
  //（`episodeCount: 0` 表示"集数未知" ⇒ 详情页只显示「下次更新」，
  //  不显示「已入库/已更新」）。

  // ★ **TMDB 兜底**：库内没有"下次更新日"时用 TMDB 的 `next_episode_to_air.air_date`
  //
  // ## 为什么需要（实测证据）
  // Emby 库内分集的 `PremiereDate` **可能全为空**
  // （实测某剧 33 集全无日期）⇒ 库内算不出"下次更新"。
  // 而 TMDB 明确给了日期。
  // ## 成本
  // 只在 `nextAirDate == null` 时发 1 个请求（CalendarClient 有 6h 缓存）。
  // `best` 可能为 null ⇒ `best?.` 让"没有服务器数据"时也尝试 TMDB
  if ((best?.nextAirDate) == null) {
    try {
      final key = await ref.read(sessionStoreProvider).loadTmdbKey();
      if (key != null && key.isNotEmpty) {
        final d = await ref.read(calendarClientProvider).fetchDetail(
              tmdbId,
              apiKey: key,
            );
        if (d?.nextAirDate != null && d!.nextAirDate!.isNotEmpty) {
          return LibrarySummary(
            // `best` 可能为 null（服务器离线）—— 那集数未知用 0
            episodeCount: best?.episodeCount ?? 0,
            title: best?.title ?? titleHint,
            lastEpisode: best?.lastEpisode,
            lastSeason: best?.lastSeason,
            nextAirDate: d.nextAirDate,
            days: best?.days ?? const {},
          );
        }
      }
    } catch (e) {
      debugPrint('[Library] TMDB 兜底失败（忽略）: $e');
    }
  }

  // ★ **第三级：本地时刻表**（`anime_timelines`，**0 网络、不需要 TMDB key**）
  //
  // ## 为什么必须有这一级（真机报障）
  // > "下次更新时间在详情页中还没有"
  // 前两级都会失败：
  // · 库内：分集**都已播出** ⇒ "今天或之后最近的日期"必然找不到
  // · TMDB：**需要 key**（key 被 uninstall 清空后就没填）
  // ⇒ `nextAirDate` 恒 null ⇒ 横幅**永远不显示**。
  //
  // ## 数据来源
  // `anime_timelines`（B站/优酷/爱奇艺 周更表索引，含 `weekday` + `airTime`）
  // ⇒ 按**剧名**查，从今天起找回最近的那个 weekday。
  try {
    final db = ref.read(appDbProvider);
    final row = await db.timelineFor(
        best != null && best.title.isNotEmpty
            ? best.title
            : titleHint);
    if (row != null && row.weekday >= 1 && row.weekday <= 7) {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final gap = (row.weekday - now.weekday + 7) % 7;
      final d0 = today.add(Duration(days: gap));
      final ymd = '${d0.year.toString().padLeft(4, '0')}-'
          '${d0.month.toString().padLeft(2, '0')}-'
          '${d0.day.toString().padLeft(2, '0')}';
      debugPrint('[Library] 下次更新来自本地时刻表：${best?.title ?? titleHint} → $ymd'
          '（周${row.weekday} ${row.airTime}）');
      return LibrarySummary(
        // 服务器离线时集数未知 ⇒ 0（详情页据此只显示「下次更新」）
        episodeCount: best?.episodeCount ?? 0,
        title: best?.title ?? titleHint,
        lastEpisode: best?.lastEpisode,
        lastSeason: best?.lastSeason,
        nextAirDate: ymd,
        days: best?.days ?? const {},
      );
    }
  } catch (e) {
    debugPrint('[Library] 本地时刻表查询失败（忽略）: $e');
  }
  return best;
});

/// **每部订阅剧在库内已入库的集数**（`sourceId → 集数`）。
///
/// ## 谁写谁读
/// · **写**：追剧页 `_loadAll` 第 ② 段（对每部调 `getSeriesEpisodes`，
///   条目数就是库内集数）—— **零额外请求**
/// · **读**：追剧页头部的 `FinishedGrid`（"全 N 集"）与详情页（「已入库」行）
///
/// ## 为什么放 provider 而不是 State
/// 头部（三统计卡 + 视图切换）在 `TrackingPage.build`，
/// 而 `_loadAll` 在**子级** `_SubscribedCalendarState` ——
/// 子 State 的字段头部读不到。用 provider 跨层级共享
/// （与 `todayUpdateCountProvider` 同一手法，不引入新机制）。
final libraryEpisodeCountProvider =
    NotifierProvider<LibraryEpisodeCountNotifier, Map<String, int>>(
  LibraryEpisodeCountNotifier.new,
);

class LibraryEpisodeCountNotifier extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() => const {};

  /// 由追剧页写入（**唯一写入口**）。
  void set(Map<String, int> v) {
    if (!_same(v, state)) state = v;
  }

  static bool _same(Map<String, int> a, Map<String, int> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }
}

/// **今日有更新的订阅剧数量**（底栏「追剧」角标用）。
///
/// ## 稿子原文（`updateNavBadge()`）
/// ```js
/// const todayCount = Array.from(followedLive).map(id => CONTENT[id])
///     .filter(c => c && seriesInDay(c, todayDow)).length;
/// badge.style.display = todayCount > 0 ? 'block' : 'none';   // 0 时隐藏
/// ```
///
/// ## ★ 为什么必须共享（而不是底栏自己算）
/// 这个数字要和**追剧页周历**里的数字**完全一致**——
/// 底栏显示 3、点进去看到 2 会让用户困惑。
/// 周历数据在 `_SubscribedCalendarState` 里（`_weeks`），底栏拿不到
/// ⇒ 由追剧页 `_loadAll` **写入**，底栏**读取**。
///
/// ⚠️ 不能用 `ref.watch` 在这里再查一遍 TMDB（那会翻倍请求）。
final todayUpdateCountProvider = NotifierProvider<TodayUpdateCountNotifier, int>(
  TodayUpdateCountNotifier.new,
);

class TodayUpdateCountNotifier extends Notifier<int> {
  @override
  int build() => 0;

  /// 由追剧页写入（**唯一写入口**）。
  void set(int n) {
    if (state != n) state = n;
  }
}

/// **TMDB 热播榜**（「热播」Tab 的 TMDB 栏，按 类别 × 状态）。
///
/// ## 用户定义
/// > "热播的指的是正在连载中或者即将连载的剧集、综艺、动漫以及刚完结不久的，
/// >  还有正在上映的电影、已上映的电影。"
///
/// ## 与 `hotHeroProvider` 的分工
/// · `hotHeroProvider` —— 首页 hero：**∩ 库内**（点进去能直接播）
/// · 本 provider —— 热播 Tab：**全量**（库里没有的也能看简介/订阅）
///
/// ## 没填 TMDB key ⇒ 返回空（UI 显示"去填 key"的引导，不是空列表）
final hotBoardProvider = FutureProvider.family<List<CalendarEntry>,
    (BrowseCategory, HotBoard)>((ref, key) async {
  // ⚠️ `ref.watch` 必须在 await 之前（riverpod 既有约定）
  final keyFuture = ref.watch(sessionStoreProvider).loadTmdbKey();
  final apiKey = await keyFuture;
  if (apiKey == null || apiKey.isEmpty) return const [];
  return ref.read(calendarClientProvider).fetchHotByStatus(
        apiKey: apiKey,
        category: key.$1,
        board: key.$2,
      );
});

/// **首页 hero = TMDB 热播 ∩ 库内**（用户："热播剧集按我库里有的放上去"）。
///
/// ## 为什么必须"∩ 库内"
/// 纯 TMDB 热播里绝大多数**库里没有** ⇒ 点进去"找不到"。
/// 取交集后每一张都能直接播（实测命中：iLoveHD 83 部 / HK-Emby 135 部）。
///
/// ## 缓存
/// · 库内 tmdb id：6h（`libIdSetProvider`）
/// · TMDB 热播：6h（`CalendarClient._hotPage` 的 `cacheTtl`）
/// ⇒ 6 小时内第二次进首页 **0 请求**。
///
/// ## 返回空的情况（**都必须回退到 /Latest 轮播**）
/// · 没填 TMDB key
/// · TMDB 不可达
/// · 交集为空（库里没有任何热播内容）
final hotHeroProvider = FutureProvider<List<CalendarEntry>>((ref) async {
  // ⚠️ 所有 `ref.watch` 必须在 await 之前取好（riverpod 的既有约定，
  //    本仓库踩过"await 之后再 ref ⇒ 崩溃"）
  final keyFuture = ref.watch(sessionStoreProvider).loadTmdbKey();
  final apisFuture = ref.watch(accountApisProvider.future);
  final key = await keyFuture;
  if (key == null || key.isEmpty) return const [];

  final apis = await apisFuture;
  if (apis.isEmpty) return const [];

  // ① 查库内 tmdb id（只查**第一台**：hero 是"精选"，跨服做并集意义不大，
  //    且每多一台多 2 个请求）
  final api = apis.values.first;
  final tvIds = <String>{};
  final movieIds = <String>{};
  try {
    tvIds.addAll(await api.collectProviderIds(
        providerKey: 'tmdb', includeTypes: 'Series'));
    movieIds.addAll(await api.collectProviderIds(
        providerKey: 'tmdb', includeTypes: 'Movie'));
  } catch (e) {
    debugPrint('[Hot] 读库内 tmdb id 失败（回退 /Latest）: $e');
    return const [];
  }
  if (tvIds.isEmpty && movieIds.isEmpty) return const [];

  // ② + ③ TMDB 热播 ∩ 库内
  return ref.read(calendarClientProvider).fetchHotInLibrary(
        apiKey: key,
        libTvIds: tvIds,
        libMovieIds: movieIds,
      );
});

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
