import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/go_core.dart';
import 'core/router.dart';
import 'core/theme.dart';
import 'state/providers.dart';
import 'data/db/db_provider.dart';
import 'data/session_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 注：播放内核已从 media_kit 迁移到"安卓原生 mpv"（K0–K4）。
  // 新内核不需要全局 ensureInitialized：mpv 实例由 PlayerChannel
  // 在第一次起播时按需创建（且必须先拿到 Flutter 纹理的 Surface）。

  // 恢复主题色偏好（外观页四选一；默认 0 = 青）
  try {
    final themeIdx = int.tryParse(
            await SessionStore().getPref('theme_index') ?? '') ??
        0;
    Cf.applyTheme(themeIdx);
  } catch (_) {}

  // ★ 恢复**背景底色**（用户 2026-10-14：六档 + 自定义）
  //
  // ## 为什么必须在这里恢复
  // `Cf.bgKind` / `Cf.bgOpacity` 是**静态字段** ⇒ 首帧渲染前就得设好，
  // 否则会"先闪一下深色、再跳到浅白"（观感差）。
  // 与上面 `theme_index` 同一时机、同一理由。
  //
  // ## 容错
  // 存的是 `CfBgKind.name` ⇒ `firstWhere` 找不到回退 `dark`
  // （**不抛异常** —— 旧版本没有这个 pref）。
  try {
    final bgName = await SessionStore().getPref('bg_kind') ?? '';
    final bgOp =
        int.tryParse(await SessionStore().getPref('bg_opacity') ?? '') ?? 60;
    final customHex = await SessionStore().getPref('bg_custom') ?? '';
    if (customHex.isNotEmpty) {
      final v = int.tryParse(customHex, radix: 16);
      if (v != null) Cf.customBgColor = Color(v);
    }
    if (bgName.isNotEmpty) {
      final kind = CfBgKind.values.firstWhere(
        (e) => e.name == bgName,
        orElse: () => CfBgKind.dark,
      );
      Cf.applyBackground(kind, opacity: bgOp);
    }
  } catch (_) {}

  // Go 核心逻辑层：尝试加载，失败不阻塞启动。
  // 当前业务逻辑仍在 Dart（ADR 0002 的纯 Dart 路径），Go 层是新引入的
  // 核心逻辑承载点（ADR 0004），处于"已打通、逐步迁移"阶段——
  // 因此这里只记状态，**不因加载失败而阻止应用启动**。
  final go = GoCore.tryLoad();
  if (go != null) {
    final ping = GoCore.ping();
    debugPrint('[GoCore] 已加载，ping=${ping.ok ? ping.result : ping.error}');
    // 自检媒体规则也可达：能跑通说明 dispatch 的字符串路由正确
    // （Go 编译器会合并字符串常量，静态扫描二进制查不到方法名，
    //   所以只能靠这种运行时调用确认）。
    final sort = go.sortParams('DateCreated');
    final norm = go.normalizeLatest([
      {'id': 'smoke-movie', 'type': 'Movie'},
      {'id': 'smoke-boxset', 'type': 'BoxSet'},
    ]);
    debugPrint('[GoCore] sortParams=$sort  normalizeLatest 保留=${norm?.length}');
  } else {
    debugPrint('[GoCore] 未加载（该平台未提供 .so），继续纯 Dart 路径');
  }

  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Cf.bg,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  // ---- 会话预热：在首帧之前把会话恢复完（2026-10）----
  //
  // ## 为什么必须在这里做（而不是交给 UI 处理 loading 态）
  //
  // 冷启动时 `sessionProvider` 是异步的（读 flutter_secure_storage）。
  // 在它恢复完之前，路由无法判断用户是否已登录，于是**必须**有个过渡：
  //
  //   · 停在首页 → `HomePage` 里是 `ref.read(embyApiProvider)!`（非空断言），
  //     而该 provider 依赖 `sessionProvider.value`，此刻是 null
  //     → 直接抛 `Null check operator used on a null value`（**红屏**）
  //   · 跳登录页 → 已登录用户会**先闪一下登录页**再跳回首页
  //   · 显示一张过渡页 → 就是刚从路由里删掉的 `/splash`，
  //     它和系统启动图、登录页的 logo 尺寸/形态都不同 → "图标跳两下"
  //
  // 三条路都不好，而**根因是"首帧时会话还没准备好"**。
  // 所以在首帧之前把它恢复完，加载态就根本不出现 —— 三个问题一起消失。
  //
  // 这段时间用户看到的是**系统启动图**（品牌深蓝底），不是黑屏也不是空白，
  // 所以这里等待是自然的，不产生额外闪烁。
  //
  // ## 为什么要 timeout
  // flutter_secure_storage 底层是 Android Keystore 解密，正常 < 100ms；
  // 但设备密钥损坏等异常下可能抛错或迟迟不返回。**绝不能因恢复失败而不启动**：
  // 超时/异常一律继续，此时会话按 null 处理 → 走登录页（用户重新登录即可）。
  final container = ProviderContainer();
  try {
    await container
        .read(sessionProvider.future)
        .timeout(const Duration(seconds: 3));
  } catch (e) {
    debugPrint('[Session] 预热失败（按未登录继续）: $e');
  }

  runApp(UncontrolledProviderScope(
    container: container,
    child: const CineFlowApp(),
  ));
}

class CineFlowApp extends ConsumerStatefulWidget {
  const CineFlowApp({super.key});

  @override
  ConsumerState<CineFlowApp> createState() => _CineFlowAppState();
}

class _CineFlowAppState extends ConsumerState<CineFlowApp> {
  @override
  Widget build(BuildContext context) {
    // 从 Provider 取路由实例（见 core/router.dart 的说明：
    // 实例必须稳定，故不能在这里 build 重建）。
    final router = ref.watch(routerProvider);
    // 主题切换：index 变化 → key 变化 → 全树用新 Cf 静态色重建
    final themeIdx = ref.watch(themeIndexProvider);

    // 本地库自检：打开并清理过期缓存（不阻塞首帧）。
    // 失败不致命——缓存/历史都不是应用可用性的前提，
    // 故只记日志，让用户仍能正常浏览与播放。
    if (!_dbChecked) {
      _dbChecked = true;
      Future<void>(() async {
        try {
          final db = ref.read(appDbProvider);
          final purged = await db.cachePurgeExpired();
          final stats = await db.cacheStats();
          debugPrint('[DB] 就绪，清理过期缓存 $purged 条，'
              '现有 ${stats.count} 条 / ${stats.bytes} 字符');
        } catch (e) {
          debugPrint('[DB] 打开失败（缓存与历史将不可用）: $e');
        }
      });
    }

    return MaterialApp.router(
      key: ValueKey('theme-$themeIdx'),
      title: 'CineFlow',
      debugShowCheckedModeBanner: false,
      theme: Cf.theme(),
      routerConfig: router,
    );
  }

  bool _dbChecked = false;
}
