/// 全局路由表（go_router）—— 对应计划书「路由 go_router」选型。
///
/// ## 为什么从 Navigator 迁到 go_router
///
/// 原先全用 `Navigator.push(MaterialPageRoute(...))`：8 个页面 + 全屏播放器，
/// 当时确实够用（ADR 0002 的取舍）。迁移动机有两个，都不是"为了用而用"：
///
/// 1. **可直接跳转的 URL 语义**：详情页要能由 itemId 直接打开
///    （如从搜索结果、豆瓣榜单、未来的通知/深链跳进来）。
///    `Navigator.push` 必须持有 `BuildContext` 且在页面内构造 widget，
///    而 go_router 用 `/detail/:id` 就能从任意位置跳。
/// 2. **播放器是全屏页**：它有自己的 `PopScope`（必须拦返回以先上报 Stop），
///    用声明式路由能把这个约束显式写在路由表里，而不是散在页面内部。
///
/// ## 迁移纪律（重要）
///
/// **弹窗内的 `Navigator.pop` 不要动**：`showDialog` / `showModalBottomSheet`
/// 走的是根 Navigator 的 pop，与路由表无关。把它们改成 go_router 反而会断。
/// 本次只迁**页面级**跳转（push 到新页面）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/services.dart'
    show DeviceOrientation, SystemChrome, SystemUiMode;

import '../data/models.dart';
import '../pages/detail_page.dart';
import '../pages/history_page.dart';
import '../pages/home_shell.dart';
import '../pages/login_page.dart';
import '../pages/search_page.dart';
import '../player/player_routes.dart';
import '../state/providers.dart';
/// 路由路径常量。
///
/// 用具名常量而不是裸字符串：路径拼写错误在 go_router 里会表现为
/// "跳到 404 页"或"跳不进去"，很难一眼看出；常量能让拼错在编译期暴露。
abstract final class Routes {
  static const login = '/login';
  static const home = '/';
  static const search = '/search';
  static const detail = '/detail';
  static const history = '/history';
  static const player = '/play';

  /// `/detail/:id`
  static String detailOf(String itemId) => '$detail/$itemId';

  /// `/play/:id`，可带 `?index=`（剧集上下文里的第几集）
  static String playOf(String itemId, {int? index}) =>
      index == null ? '$player/$itemId' : '$player/$itemId?index=$index';
}

/// 把 riverpod 的状态变化桥接成 go_router 能听的 [Listenable]。
///
/// ## 为什么不能直接让 router `watch(sessionProvider)`
///
/// 那样每次会话变化都会**重建整个 GoRouter**，而 go_router 的导航栈
/// 是挂在 router 实例上的——重建等于把用户当前的页面栈清空。
/// 表现就是"登录成功后回到了首页而不是原目标页"、
/// 或"退出登录时闪一下再进登录页"。
///
/// 正确做法：router 实例只建一次，用 `refreshListenable` 通知它重跑
/// `redirect`。
///
/// 这里接收 `Ref`（provider 的）而非 UI 的 `WidgetRef`：
/// 需要在 State.dispose 之外管理监听生命周期，`Ref` 由 ProviderScope 托管。
class SessionRefresh extends ChangeNotifier {
  SessionRefresh(Ref ref) {
    _sub = ref.listen(sessionProvider, (_, _) => notifyListeners());
  }

  ProviderSubscription<AsyncValue<MediaSession?>>? _sub;

  @override
  void dispose() {
    _sub?.close();
    super.dispose();
  }
}

/// 会话状态的读取接口（供 [buildRouter] 使用）。
///
/// 刻意**不直接依赖 riverpod 的 `Ref`**：那会让路由表无法在纯
/// widget 测试里构造（测试要么启动真 ProviderScope，要么伪造 Ref）。
/// 抽成两个回调后，路由逻辑变成一个可注入、可断言的纯函数式配置——
/// 会话门控的分支就能被 `test/router_test.dart` 完整覆盖。
class SessionGate {
  const SessionGate({
    required this.current,
    this.listenable,
  });

  /// 读取当前会话状态
  final AsyncValue<MediaSession?> Function() current;

  /// 会话变化通知（go_router 的 refreshListenable）
  final Listenable? listenable;
}

/// 会话门控的决策函数（纯函数，便于单测）。
///
/// 抽出来是**为了可测**：redirect 里嵌在闭包里时，
/// 只能靠启动整个 widget 树 + 渲染真实页面来验证，
/// 而真实页面会发网络请求、需要 ProviderScope——
/// 测试退化成"集成测试"，容易因无关原因失败。纯函数则可直接断言。
///
/// ## 分支顺序很重要
///
/// 1. **会话恢复中 → 不放行首页，也不跳登录页**：见下方「为什么删掉了 /splash」。
/// 2. 未登录 → 登录页（已在登录页则不重复跳，避免死循环）
/// 3. 已登录但停在登录页 → 首页
/// 4. 其余放行
///
/// ## 为什么删掉了 `/splash` 路由（2026-10）
///
/// 冷启动到登录页之间原本依次显示**三张互不相同的 logo**：
///
/// | 阶段 | 显示 | 尺寸/形态 |
/// |---|---|---|
/// | ① Android 系统启动图（API 31+ 强制） | `launch_logo` | 288×288 圆角方块，被系统**裁成圆形** |
/// | ② Dart `/splash` 路由 | `CfLogo(size: 56, radius: 16)` | 56dp |
/// | ③ 登录页 | `CfLogo()` | 默认 **52dp / radius 14** |
///
/// 三者尺寸与形态都不同 → 肉眼看到"图标跳一下、再变一次"。
/// 用户要求直接去掉中间那层（②），只保留登录页。
///
/// ## ⚠️ 删掉 splash 后，`isLoading` 这一支为什么不能直接判"未登录"
///
/// 冷启动时会话尚未从 `flutter_secure_storage` 恢复完
/// （`SessionNotifier.build()` 是异步的）。此时若判"未登录 → 登录页"，
/// 已登录用户会**先闪一下登录页**再跳回首页 —— 这正是当初引入 splash 的原因。
///
/// 但**也不能放行首页**：`HomePage` 里是 `ref.read(embyApiProvider)!`
/// （非空断言），而 `embyApiProvider` 依赖 `sessionProvider.value`，
/// 恢复期间为 `null` → 直接抛 `Null check operator used on a null value`（红屏）。
///
/// 所以恢复期间返回 `null`（**放行当前 location**）：
///   · 冷启动初始位置是 `/`，但 go_router 会先按 `redirect` 的结果决定最终落点，
///     而 `Routes.login` 会被显式拦到登录页 —— 见下一分支。
///   · 实际效果：恢复期间停在**登录页**（而不是空白 splash 页），
///     恢复完成若是已登录，则立刻被送去首页。
///
/// 这样既没有第三张 logo，也不会闪登录页、不会红屏。
String? resolveRedirect({
  required AsyncValue<MediaSession?> session,
  required String location,
}) {
  if (session.isLoading) {
    // 恢复中：已在登录页就停住（避免重复跳），否则一律先去登录页。
    //
    // 用登录页而非首页做落点，是因为它**不依赖** `embyApiProvider`
    // （登录页只用 `sessionProvider.notifier` 提交表单），
    // 因此恢复期间渲染它是安全的。
    return location == Routes.login ? null : Routes.login;
  }

  final loggedIn = session.value != null;
  if (!loggedIn) {
    return location == Routes.login ? null : Routes.login;
  }
  if (location == Routes.login) {
    return Routes.home;
  }
  return null; // 已登录且在正常页面 → 放行
}

/// 应用路由表实例（全局唯一）。
///
/// 用 Provider 承载而不是在 widget 里 `late final`：
/// 路由表需要读会话，而 UI 层只有 `WidgetRef`；放 Provider 里能拿到
/// 真正的 `Ref`，监听生命周期也由 ProviderScope 托管。
///
/// **此 Provider 永不 invalidate**：GoRouter 的导航栈挂在实例上，
/// 换实例等于清空用户当前页面栈。会话变化靠 `refreshListenable` 通知
/// （见 [SessionRefresh]），不靠重建 router。
final routerProvider = Provider<GoRouter>((ref) {
  final refresh = SessionRefresh(ref);
  ref.onDispose(refresh.dispose);
  return buildRouter(
    gate: SessionGate(
      current: () => ref.read(sessionProvider),
      listenable: refresh,
    ),
  );
});

/// 构造应用路由表（会话感知）。
///
/// [gate] 提供会话状态与变化通知；测试可注入假实现。
/// [initialLocation] 供测试注入（避免测试依赖真实会话状态）。
// ---- 自动竖屏观察者（真机 bug 的根治方案）----
//
// ## 问题（三轮排查的完整结论）
// 播放页会锁横屏。退出它的**落点不止一个**：
// ```
// 播放器 → 详情页（实测最常见）
// 播放器 → 首页
// 播放器 → 桌面（播放页是任务根路由时）
// ```
// 前两轮把复位挂在播放页 `dispose` / `HomeShell.initState`：
//   · `dispose`：调用发生了，但窗口没转（平台层不应用）
//   · `HomeShell.initState`：只在**冷启动**跑一次（它一直在栈底，不 unmount）
//   · `RouteAware.didPopNext`：只覆盖"直接下层是首页"，**漏掉详情页**
//
// ## 根治：在**导航层**统一处理，而不是逐页挂回调
// 逐页挂是打地鼠 —— 每加一个页面都要记得挂，漏一个就复现。
// 这里改成监听**全局路由变化**：任何一次导航完成后，
// 若当前路由**不是播放器**，就把方向复位成竖屏。
//
// 新增页面**自动覆盖**（不需要记得挂任何东西），
// 只有播放页需要横屏 —— 判断条件是"当前路由不在 /play 下"。
class AutoPortraitObserver extends NavigatorObserver {
  AutoPortraitObserver();

  /// 当前路由是否是播放器（播放器需横屏，不能复位）。
  bool _isPlayerRoute(Route<dynamic>? route) {
    final name = route?.settings.name ?? '';
    return name.startsWith('/play');
  }

  void _enforce(Route<dynamic>? route) {
    if (_isPlayerRoute(route)) return;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    // push 播放器时**不复位**（它自己会锁横屏）；
    // push 其他页面 → 确保竖屏
    _enforce(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    // ★ 核心场景：从播放器 pop 回来后，对**落点路由**强制竖屏。
    //   这里检查 previousRoute（落点），而不是被 pop 掉的 route。
    _enforce(previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    _enforce(newRoute);
  }
}

/// 全局单例观察者（挂到 GoRouter.observers）。
///
/// ⚠️ 必须是**顶层**：写进函数体会变成局部变量，
///    外部（HomeShell 等）访问不到 —— 我第一版就犯了这个错。
final AutoPortraitObserver appRouteObserver = AutoPortraitObserver();

GoRouter buildRouter({required SessionGate gate, String? initialLocation}) {
  return GoRouter(
    observers: [appRouteObserver],
    initialLocation: initialLocation ?? Routes.home,
    refreshListenable: gate.listenable,
    // 未匹配路径统一进首页：本项目没有值得单独做的 404 页，
    // 而"跳错路径导致白屏"体验更差。
    errorBuilder: (context, state) => const HomeShell(),

    // 会话门控（原先在 main.dart 的 _SessionGate 里，迁到此处）。
    // 决策逻辑见 resolveRedirect（纯函数，被 test/router_test.dart 覆盖）。
    redirect: (context, state) => resolveRedirect(
      session: gate.current(),
      location: state.matchedLocation,
    ),

    routes: [
      // 登录页：独立于主框架（无底部 Tab）
      //
      // ★ 2026-10 去掉了原来的 `/splash` 占位页。
      //   冷启动到登录页之间原本会依次显示**三张互不相同的 logo**
      //   （系统启动图 → Dart splash → 登录页），尺寸与形态都不一样，
      //   肉眼看到"图标跳一下再变一次"。用户要求直接去掉中间那层。
      //   会话恢复期间的落点改由 [resolveRedirect] 决定（停在登录页，
      //   而**不**是停在首页 —— 首页非空依赖 embyApiProvider，会红屏）。
      GoRoute(
        path: Routes.login,
        builder: (context, state) => const LoginPage(),
      ),

      // 主框架：底部 Tab（首页 / 排行榜 / 我的），内部用 IndexedStack 保活
      GoRoute(
        path: Routes.home,
        builder: (context, state) => const HomeShell(),
      ),

      // 搜索
      GoRoute(
        path: Routes.search,
        builder: (context, state) => SearchPage(
          // 支持 ?q= 预填（豆瓣榜单「在媒体库中搜索」用）
          initialQuery: state.uri.queryParameters['q'],
        ),
      ),

      // 播放历史
      //
      // ★ 2026-10 补：`HistoryPage` 早就实现好了，但**既没注册路由、
      //   首页「继续观看 → 全部 ›」还弹的是「即将推出」** ——
      //   属于"功能做好了却没接上"：用户点"全部"看不到本该能看到的历史列表。
      GoRoute(
        path: Routes.history,
        builder: (context, state) => const HistoryPage(),
      ),

      // 详情：/detail/:id
      GoRoute(
        path: '${Routes.detail}/:id',
        builder: (context, state) => DetailPage(
          itemId: state.pathParameters['id'] ?? '',
        ),
      ),

      // 播放器：/play/:id?index=N
      // 全屏横屏页，自带 PopScope 拦截返回（见 PlayerPage）
      playerRoute(),
    ],
  );
}

/// 路由表是否需要会话感知由 [buildRouter] 决定（它已读取 sessionProvider）。
///
/// 注意：`GoRouter` 自身就 `implements RouterConfig<RouteMatchList>`，
/// 可直接赋给 `MaterialApp.router(routerConfig: ...)`，
/// **不需要**再包一层自定义 Config（那是多余且易错的中间层）。
