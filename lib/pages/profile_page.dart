/// 我的 —— 用户头卡（真实头像/服务器）+ 观看统计（Emby 真实数据）+ 设置组 + 退出
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../core/version.dart';
import '../danmaku/danmaku_settings_page.dart';
import 'about_page.dart';
import 'appearance_page.dart';
import 'playback_settings_page.dart';
import 'kernel_settings_page.dart';
import '../data/emby_provider.dart';
import '../data/session_store.dart';
import '../data/models.dart';
import '../pan115/pan115_browser_page.dart';
import '../pan115/pan115_store.dart';
// `reindexTimelines` —— 手动强制重跑三源时刻表索引。
// 与追剧页**共用同一套逻辑**，避免「一处改了另一处没改」。
import 'tracking_page.dart' show reindexTimelines;
import '../state/providers.dart';
import 'account_manager_page.dart';

/// 观看统计（TotalRecordCount 查询，Counts 端点部分服务器不可用）
class _Stats {
  final int moviesWatched; // 已看电影
  final int seriesWatching; // 追剧中（未看完的剧集）
  final int episodesWatched; // 已看分集
  final int favorites; // 收藏
  final int moviesTotal; // 库内电影
  final int seriesTotal; // 库内剧集
  const _Stats(this.moviesWatched, this.seriesWatching, this.episodesWatched,
      this.favorites, this.moviesTotal, this.seriesTotal);
}

final statsProvider = FutureProvider.autoDispose<_Stats>((ref) async {
  final api = ref.watch(embyApiProvider);
  if (api == null) throw const MediaException('未登录');

  Future<int> total(String includeTypes, {String? filters}) async {
    final page = await api.getItems(
        includeTypes: includeTypes, recursive: true, limit: 1, filters: filters);
    return page.total;
  }

  final results = await Future.wait([
    total('Movie', filters: 'IsPlayed'),
    total('Series', filters: 'IsUnplayed'),
    total('Episode', filters: 'IsPlayed'),
    total('Movie,Series,Episode', filters: 'IsFavorite'),
    total('Movie'),
    total('Series'),
  ]);
  return _Stats(results[0], results[1], results[2], results[3], results[4],
      results[5]);
});

class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key});

  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage> {
  /// 服务器延迟测试结果（**就地显示**，见 `_testLatency`）。
  ///
  /// ## 为什么是 State 而不是 SnackBar（实测驱动）
  /// 原来是 `ScaffoldMessenger.showSnackBar` —— 3 秒后消失。
  /// 两个问题：
  /// · **UX**：延迟是"状态"不是"一次性通知"，用户点完想再看就没了
  /// · **可验证性**：`uiautomator dump` 要 2–4 秒，SnackBar 只活 3 秒
  ///   ⇒ 我连续 4 轮真机验证都抓不到它（测试与实现赛跑）。
  ///   这正是 §8.4 说的"验证手段本身没被验证"。
  int? _latencyMs;

  /// 延迟测试中的标记（显示"测试中…"）。
  bool _testing = false;

  /// 测试失败的文案（`null` = 没有失败）。
  String? _latencyError;

  /// 已测过的服务器（避免切换页面后重复测）。
  String? _latencyServerUrl;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider).value;
    final stats = ref.watch(statsProvider);

    return Scaffold(
      backgroundColor: Cf.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            SizedBox(height: 12),
            _headCard(context, ref, session, stats),
            // ★ 多账号列表（只有 >1 台时才显示）
            _accountList(context, ref),
            SizedBox(height: 12),
            // ★ 统计四格（已看电影/追剧中/已看分集/收藏）已移除
            //   （用户 2026-10-11："删除我的底栏内容中的已看电影、追剧中、
            //     已看分集、收藏"）
            //
            // ## 为什么移除
            // · 这些数字是"全库统计"，与「我的」页的**管理**定位不符
            // · 用户要看的"我在追什么"已经在「追剧」Tab 里
            // · `statsProvider` 每次进页要发 6 个查询（其中 4 个只为这四格）
            //
            // ⚠️ `statsProvider` 仍保留（`_headCard` 用它的库规模数字：
            //    电影/剧集总数），只是不再画那四张卡。
            SizedBox(height: 14),
            _settingsGroup([
              // ★ 多账号与资源整合（放在最前 —— 它是"资源来源"级别的设置）
              _SettingItem(
                icon: Icons.dns_rounded,
                color: const Color(0xFF8E44AD),
                title: '账号与资源整合',
                sub: ref.watch(accountsProvider).maybeWhen(
                      data: (l) => l.length <= 1
                          ? '已登录 1 台 · 可添加更多服务器'
                          : '已登录 ${l.length} 台 · 搜索会同时搜它们',
                      orElse: () => '管理已登录的 Emby 服务器',
                    ),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const AccountManagerPage()),
                ),
              ),
              _SettingItem(
                icon: Icons.cloud_outlined,
                color: const Color(0xFF00A8FF),
                title: '115 网盘',
                // 副标题动态反映登录状态，避免用户点进去才发现未登录
                sub: ref.watch(pan115SessionProvider).maybeWhen(
                      data: (info) => info == null
                          ? '未登录 · 扫码即可访问网盘视频'
                          : [
                              if (info.userName.isNotEmpty) info.userName,
                              if (info.vipName.isNotEmpty) info.vipName,
                              if (info.spaceLabel.isNotEmpty) info.spaceLabel,
                            ].join(' · '),
                      orElse: () => '未登录 · 扫码即可访问网盘视频',
                    ),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const Pan115BrowserPage()),
                ),
              ),
              // ★ 「继续观看」已移除（用户 2026-10-11）
              //
              // ## 为什么移除
              // 它已在**「追剧」Tab 的第二个分页**里（与"追剧日历"并列）。
              // 用户明确要求"删除继续观看" —— 同一内容两处入口会让用户困惑
              // "哪个才是我要看的"。
              //
              // ⚠️ `HistoryPage` 仍在（被「追剧」Tab 复用），只是不再从这里进。
              // ★ 「制片公司」已移除（用户要求）
              //
              // ## 为什么移除
              // 用户明确："去除我的中的制片公司"。
              // 该入口按片厂浏览（漫威/皮克斯/东宝…），属于"探索型"功能，
              // 与「我的」页"管理自己资源"的定位不符。
              //
              // ## 底层能力保留（别顺手删 `getStudios`）
              // `MediaProvider.getStudios` / `getStudioItems` 仍在
              //（搜索页等处可能复用）⇒ 移除的只是这个入口。
              // ★ 「服务端播放列表」已移除（用户 2026-10-11）
              //
              // ## 为什么移除
              // 用户明确要求删除。它是"在 Emby 里建的列表"，
              // 使用频率低（该库实测只有少量列表），且入口占了一行。
              //
              // ⚠️ `getPlaylists` / `getPlaylistItems` 仍在 provider 上
              //    （将来若要放回，位置在「服务端」类目下）。
              // ★ 「追剧日历」入口**已移除**（用户 2026-10-12）
              //
              // ## 为什么移除
              // 它的 TMDB 全量周历**已并入「热播」Tab 的 TMDB 栏**
              //（作为一个"更新日历"榜单）—— 同一内容两处入口会让用户困惑。
              //
              // ⚠️ 页面本身（`CalendarPage`）**保留**：
              //    · 用户订阅的"周几更新"走 `fetchWeekEpisodes(tmdbId)`
              //      （按 tmdbId 查该剧自己的播出日）⇒ **不依赖**这个全量周历
              //    · 热播 Tab 会以"更新日历"榜的形式复用它
              _SettingItem(
                icon: Icons.tune_rounded,
                color: const Color(0xFF6C5CE7),
                title: '播放设置',
                sub: '默认倍速 · 跳片头 · 自动连播',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const PlaybackSettingsPage()),
                ),
              ),
              _SettingItem(
                icon: Icons.memory_rounded,
                color: const Color(0xFF00B4D8),
                title: '播放内核',
                sub: '自动适配 · 或手动指定 mpv / Media3',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const KernelSettingsPage()),
                ),
              ),
              _SettingItem(
                icon: Icons.subtitles_rounded,
                // 原为硬编码 0xFF00D4FF：外观页切到绿/紫/橙时此处**不变色**（实测 bug）。
                color: Cf.accent,
                title: '弹幕设置',
                sub: '弹幕源 · 外观 · 屏蔽词',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const DanmakuSettingsPage()),
                ),
              ),
              _SettingItem(
                icon: Icons.palette_outlined,
                color: const Color(0xFF00E5A0),
                title: '外观',
                sub: '主题色 · 深色模式',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AppearancePage()),
                ),
              ),
              // ★ 从服务端收藏恢复订阅（uninstall 事故的补救，见 AGENTS.md §6.9）
              //
              // ## 为什么会有这个入口
              // 本地 `calendar_subscriptions` 曾被误清空（21 部订阅）；
              // 但**服务端 Emby 收藏还在**（订阅时"库里命中 ⇒ 同时写收藏"）
              // ⇒ 可以从收藏反查 tmdbId 重建订阅。
              //
              // ## 诚实说明（覆盖范围有限）
              // 只能恢复"**订阅时库里有**"的那些 —— 当时才写了收藏。
              // 库里没有的（先订阅、等入库）当时没写收藏 ⇒ 恢复不了。
              _SettingItem(
                icon: Icons.restore_rounded,
                color: const Color(0xFF00E5A0),
                title: '恢复追剧订阅',
                sub: '从 Emby 服务端收藏重建本地订阅（误清空后使用）',
                onTap: () => _restoreSubs(context, ref),
              ),
              // ★ 「更新时刻表」—— 手动强制重跑三大源索引
              //
              // ## 为什么需要
              // 索引**按平台 TTL**（24h）⇒ 订阅的剧改档后，用户要等一天才生效。
              // 给一个手动入口 ⇒ 立刻刷新（也便于确认索引是否真的在工作）。
              _SettingItem(
                icon: Icons.schedule_rounded,
                color: const Color(0xFF5B8DEF),
                title: '更新时刻表',
                sub: '重新抓取 B站/爱奇艺/优酷 的连载更新时间',
                onTap: () => _reindexTimelines(context, ref),
              ),
              _SettingItem(
                icon: Icons.info_outline_rounded,
                color: const Color(0xFF8BA3CC),
                title: '关于',
                sub: '版本 · 技术栈 · 开源致谢 · 免责声明',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AboutPage()),
                ),
              ),
            ]),
            SizedBox(height: 14),
            _logoutButton(context, ref),
            SizedBox(height: 20),
            // 底部版本号也可点进关于页——用户排查问题时习惯从这儿找版本
            Center(
              child: GestureDetector(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AboutPage()),
                ),
                child: Text('CineFlow $kAppVersionLabel',
                    style: TextStyle(fontSize: 10, color: Cf.text3)),
              ),
            ),
            SizedBox(height: 14),
          ],
        ),
      ),
    );
  }

  Widget _headCard(BuildContext context, WidgetRef ref,
      MediaSession? session, AsyncValue<_Stats> stats) {
    final api = ref.watch(embyApiProvider);
    final avatarUrl = (session != null && api != null)
        ? '${session.serverUrl}/Users/${session.user.id}/Images/Primary?maxWidth=160&api_key=${session.accessToken}'
        : null;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Cf.surface, Cf.surface2],
        ),
        border: Border.all(color: Cf.border),
      ),
      child: Row(children: [
        Container(
          width: 58,
          height: 58,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: Cf.logoGradient,
          ),
          child: ClipOval(
            child: avatarUrl != null
                ? Image.network(avatarUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => _initial(session))
                : _initial(session),
          ),
        ),
        SizedBox(width: 13),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(session?.user.name ?? '未登录',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w800)),
                SizedBox(height: 3),
                Row(children: [
                  // ★ 状态圆点**可点**（用户 2026-10-11："小圆点不能点击"）
                  //
                  // ## 它原来是什么
                  // 一个 7×7 的纯装饰 `Container` —— 但视觉上是"绿点 = 在线"，
                  // 用户会自然地去点它（这是**可点暗示与实际行为不符**）。
                  //
                  // ## 现在
                  // 点它 = **测延迟**（与点地址同一个动作）——
                  // 因为它表达的就是"这台服务器活着吗"，点它测延迟最符合直觉。
                  //
                  // `CfTapTarget` 把命中区撑到 48dp：
                  // 7px 的圆点裸放**点不中**（本仓库审计过同类问题，
                  // 最小可点元素曾只有 16×16）。
                  CfTapTarget(
                    size: 44,
                    semanticLabel: '服务器状态，点击测延迟',
                    onTap: session == null
                        ? null
                        : () => _testLatency(context, ref, session),
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Cf.success,
                        boxShadow: [
                          BoxShadow(
                              color: Cf.success.withValues(alpha: .6),
                              blurRadius: 6),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(width: 6),
                  // ★ 服务器地址**可点** ⇒ 测延迟（用户要求）
                  //
                  // ## 为什么用 `/System/Info/Public` 测（实测驱动）
                  // · `/System/Info/Public` → HTTP 200（s1: 536ms / s2: 53ms）
                  // · `/Users/Me`          → HTTP **500** ← 不能用
                  // 且该端点**不需要 token** ⇒ 即使凭据失效也能测"网络通不通"
                  // （能区分"服务器挂了"与"登录态过期"）。
                  Expanded(
                    child: _AddressChip(
                      serverUrl: session?.serverUrl,
                      // ⚠️ 只有"测的就是当前这台"时才显示结果 ——
                      //    否则切换账号后会显示上一台的数据（错配）
                      latencyMs: _latencyServerUrl == session?.serverUrl
                          ? _latencyMs
                          : null,
                      testing: _testing,
                      error: _latencyServerUrl == session?.serverUrl
                          ? _latencyError
                          : null,
                      onTap: session == null
                          ? null
                          : () => _testLatency(context, ref, session),
                    ),
                  ),
                ]),
              ]),
        ),
        // 统计：库规模
        stats.maybeWhen(
          data: (s) => Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('${s.moviesTotal}',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      color: Cf.accent)),
              Text('电影',
                  style: TextStyle(fontSize: 9, color: Cf.text3)),
              SizedBox(height: 4),
              Text('${s.seriesTotal}',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      color: Cf.accent)),
              Text('剧集',
                  style: TextStyle(fontSize: 9, color: Cf.text3)),
            ],
          ),
          orElse: () => SizedBox(width: 32),
        ),
      ]),
    );
  }

  Widget _initial(MediaSession? s) => Center(
        child: Text(
          (s?.user.name.isNotEmpty ?? false) ? s!.user.name[0] : 'C',
          style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w900,
              color: Cf.ink),
        ),
      );

  /// **测服务器延迟**（点击地址触发，用户要求）。
  ///
  /// ## 为什么用 `/System/Info/Public`（实测驱动）
  /// | 端点 | 实测 |
  /// |---|---|
  /// | `/System/Info/Public` | ✅ HTTP 200（s1: 536ms / s2: 53ms） |
  /// | `/Users/Me` | ❌ HTTP **500** ← 不能用 |
  ///
  /// 且该端点**不需要 token** ⇒ 能区分两种情况：
  /// · 连不上 ⇒ "服务器不可达"（网络/DNS/端口问题）
  /// · 连上但 200 ⇒ 服务器活着（若此时 App 内其他请求失败 ⇒ 是登录态问题）
  ///
  /// ## 为什么测 3 次取**最小值**
  /// 单次测的是"第一个请求"（含 TLS 握手/DNS 缓存冷启动），会偏高。
  /// 取 3 次最小值更接近真实带宽延迟（这也是 ping 类工具的常见做法）。
  Future<void> _testLatency(
      BuildContext context, WidgetRef ref, MediaSession session) async {
    if (_testing) return;
    setState(() {
      _testing = true;
      _latencyError = null;
      _latencyMs = null;
      _latencyServerUrl = session.serverUrl;
    });
    final base = session.serverUrl.replaceAll(RegExp(r'/+$'), '');
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
      // 不校验状态码 —— 拿到响应就算"通"（我们要的是耗时）
      validateStatus: (_) => true,
    ));
    final times = <int>[];
    String? err;
    for (var i = 0; i < 3; i++) {
      final sw = Stopwatch()..start();
      try {
        await dio.get<String>('$base/System/Info/Public',
            options: Options(responseType: ResponseType.plain));
        sw.stop();
        times.add(sw.elapsedMilliseconds);
      } catch (e) {
        sw.stop();
        err = e.toString();
        break;
      }
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      if (times.isEmpty) {
        // 失败也要显示 —— "服务器不可达"同样是用户需要的信息
        _latencyError = err?.contains('timeout') ?? false ? '超时' : '不可达';
      } else {
        _latencyMs = times.reduce((a, b) => a < b ? a : b);
      }
    });
  }

  /// 多账号列表（用户要求"多账号聚合地址和内容没增加进去"）。
  ///
  /// ## 为什么要单独列出来
  /// 头部卡片只显示 `sessionProvider`（**当前**会话）⇒ 登录了多台时
  /// 用户看不到另外几台。这里把 `accountsProvider` 的**全部**账号列出来，
  /// 每台一行（平台色点 + 名称 + 地址），当前那台高亮。
  ///
  /// ## 实测背景
  /// 设备上目前只登录了 **1 台**（`已登录 1 台`）。**只有 1 台时不显示
  /// 本区块**（避免视觉冗余）—— 用户加第二台后自动出现。
  Widget _accountList(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider);
    return accounts.maybeWhen(
      data: (list) {
        if (list.length <= 1) return const SizedBox.shrink();
        final cur = ref.watch(sessionProvider).value;
        return Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('已登录 ${list.length} 台服务器',
                    style: TextStyle(fontSize: 11, color: Cf.text3)),
              ),
              for (final a in list)
                Builder(builder: (ctx) {
                  final isCur = cur != null &&
                      SessionStore.accountKey(cur) ==
                          SessionStore.accountKey(a);
                  return InkWell(
                    // ★ 整行可点（不只是圆点）——
                    //   圆点只有 13px，就算扩到 48dp，用户也习惯点"那一行"。
                    //   `InkWell` 自带水波纹 ⇒ 有按压反馈。
                    onTap: () async {
                      if (isCur) {
                        // 已选中的那台点了要有反馈 —— 静默无反应会让用户
                        // 以为"又点不动"（这正是本次报障的观感）。
                        ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
                          const SnackBar(
                              content: Text('已是当前服务器'),
                              duration: Duration(seconds: 1)),
                        );
                        return;
                      }
                      try {
                        await ref.read(sessionProvider.notifier).switchTo(a);
                        if (ctx.mounted) {
                          ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
                            SnackBar(
                                content: Text('已切换到 ${a.user.name}'),
                                duration: const Duration(seconds: 1)),
                          );
                        }
                      } catch (e) {
                        if (ctx.mounted) {
                          ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
                            SnackBar(content: Text('切换失败：$e')),
                          );
                        }
                      }
                    },
                    borderRadius: BorderRadius.circular(Cf.radiusSm),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 6),
                      child: Row(children: [
                        // 命中区 ≥48dp：视觉仍是 13px 图标，
                        // 用 `CfTapTarget` 扩命中区（AGENTS §6.4.1）。
                        //  ⚠️ 不用裸 `GestureDetector` —— 本仓库审计过
                        //     5 处裸手势最小仅 16×16（既点不中又无反馈）。
                        // size 36 + 上下 padding 6×2 = **48dp** 行高
                        //（AGENTS §6.4.1：可点区域 ≥48dp；视觉圆点仍 13px）
                        CfTapTarget(
                          size: 36,
                          semanticLabel: isCur
                              ? '${a.user.name}，当前服务器'
                              : '切换到 ${a.user.name}',
                          onTap: null, // 交给外层 InkWell，避免双重触发
                          child: Icon(
                            isCur
                                ? Icons.check_circle_rounded
                                : Icons.circle_outlined,
                            size: 13,
                            color: isCur ? Cf.accent : Cf.text3,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${a.user.name} · '
                            '${Uri.tryParse(a.serverUrl)?.host ?? a.serverUrl}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 11,
                                color: isCur ? Cf.text : Cf.text2),
                          ),
                        ),
                        if (!isCur)
                          Icon(Icons.chevron_right_rounded,
                              size: 15, color: Cf.text3),
                      ]),
                    ),
                  );
                }),
            ],
          ),
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }

  // ★ 统计四格（已看电影/追剧中/已看分集/收藏）已整体移除
  //   （`_statGrid` / `_statCard` / `_openList` 三个方法一起删掉 ——
  //    它们只服务那四格，留着就是死代码）
  //   （用户 2026-10-11：删除我的底栏内容中的已看电影、追剧中、已看分集、收藏）
  //
  // ## 为什么连方法一起删（而不只是不调用它）
  // 留着未引用的方法会让下一个改动者以为这功能还在，只是没接线，
  // 进而花时间找为什么没显示。**死代码比没有更贵**。
  //
  // ⚠️ statsProvider 保留 —— _headCard 用它的库规模数字（电影/剧集总数）。

  Widget _settingsGroup(List<_SettingItem> items) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Cf.surface,
        border: Border.all(color: Cf.border),
      ),
      child: Column(children: [
        for (var i = 0; i < items.length; i++) ...[
          items[i],
          if (i < items.length - 1)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 14),
              child: Divider(color: Cf.border, height: 1),
            ),
        ],
      ]),
    );
  }

  Widget _logoutButton(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: () async {
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: Cf.surface,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
            title: Text('退出登录',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            content: Text('确定要退出当前服务器吗？',
                style: TextStyle(fontSize: 13, color: Cf.text2)),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text('取消', style: TextStyle(color: Cf.text3))),
              TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child:
                      Text('退出', style: TextStyle(color: Cf.danger))),
            ],
          ),
        );
        if (ok == true) {
          await ref.read(sessionProvider.notifier).logout();
        }
      },
      child: Container(
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: const Color(0x14FF6B6B),
          border: Border.all(color: const Color(0x59FF6B6B)),
        ),
        child: Text('退出登录',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Cf.danger)),
      ),
    );
  }
}

class _SettingItem extends StatelessWidget {
  _SettingItem({
    required this.icon,
    required this.color,
    required this.title,
    required this.sub,
    required this.onTap,
  });
  final IconData icon;
  final Color color;
  final String title;
  final String sub;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(
            horizontal: Cf.gap4, vertical: Cf.gap3),
        child: Row(children: [
          // 用统一徽章组件（30×30 + 描边），替掉原先手写的 29×29 无描边容器：
          // 内边距从 6.5px 提到 7px，描边让徽章在深色底上更"站得住"，
          // 且与其它页面的同类型徽章**外观一致**。
          CfIconBadge(icon: icon, color: color),
          const SizedBox(width: Cf.gap3),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text(title,
                  style: Cf.body.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(sub, style: Cf.micro),
            ]),
          ),
          Icon(Icons.chevron_right_rounded,
              size: Cf.iconMd, color: Cf.text3),
        ]),
      ),
    );
  }
}

/// **服务器地址**（可点 ⇒ 测延迟）。
///
/// 抽成独立组件的原因：`_headCard` 已经很长（头像+名字+地址+统计），
/// 把"可点 + 提示点击"的逻辑塞进去会更难读。
class _AddressChip extends StatelessWidget {
  const _AddressChip({
    required this.serverUrl,
    this.onTap,
    this.latencyMs,
    this.testing = false,
    this.error,
  });

  final String? serverUrl;
  final VoidCallback? onTap;

  /// 延迟毫秒（null = 还没测）。
  final int? latencyMs;

  /// 正在测（显示"测试中…"）。
  final bool testing;

  /// 测试失败文案（`null` = 没失败）。
  final String? error;

  /// 延迟的颜色分级（给用户"快/慢"的直观感受）。
  ///
  /// 阈值取常见经验值：<100ms 很好 / <300ms 可用 / 更高偏慢。
  Color _latencyColor(int ms) {
    if (ms < 100) return Cf.success;
    if (ms < 300) return Cf.warn;
    return const Color(0xFFFF6B6B);
  }

  @override
  Widget build(BuildContext context) {
    final url = serverUrl;
    if (url == null) {
      return Text('未连接服务器',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: Cf.text3));
    }
    final host = Uri.tryParse(url)?.host ?? url;

    // 右侧状态：测试中 / 结果 / 失败 / 只显示"可点"提示
    final Widget tail;
    if (testing) {
      tail = Text('测试中…',
          style: TextStyle(fontSize: 10, color: Cf.text3));
    } else if (latencyMs case final ms?) {
      tail = Text('${ms}ms',
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: _latencyColor(ms)));
    } else if (error case final e?) {
      tail = Text(e, style: TextStyle(fontSize: 10, color: Cf.warn));
    } else {
      tail = Icon(Icons.speed_rounded, size: 12, color: Cf.text3);
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Cf.radiusXs),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: Cf.text3)),
            ),
            const SizedBox(width: 4),
            tail,
          ],
        ),
      ),
    );
  }
}

/// **从服务端收藏恢复本地订阅**（写操作，先二次确认）。
///
/// ## 为什么用对话框确认
/// 这是**写操作**（往订阅表加行）⇒ 不该点一下就执行。
///
/// ## 幂等
/// `restoreSubscriptionsFromFavorites` 内部按 `tmdbId` 去重，
/// 重复点不会重复写（只报"恢复了 0 部"）。
Future<void> _restoreSubs(BuildContext context, WidgetRef ref) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      backgroundColor: Cf.surface,
      title: const Text('恢复追剧订阅'),
      content: const Text(
        '将从两台 Emby 服务端的**收藏**重建本地订阅。\n\n'
        '只有"订阅时库里已有"的剧才恢复得了 —— '
        '库里没有的当时没写收藏。\n\n'
        '已有订阅不会重复添加。',
        style: TextStyle(fontSize: 13, height: 1.6),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('开始恢复')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger?.showSnackBar(const SnackBar(
      content: Text('正在读取服务端收藏…'), duration: Duration(seconds: 1)));
  try {
    final n = await restoreSubscriptionsFromFavorites(ref: ref);
    // 订阅表变了 ⇒ 让「追剧」Tab 与首页「我的追剧」重拉
    ref.invalidate(subscriptionsProvider);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(
        content: Text(n > 0
            ? '已恢复 $n 部订阅'
            : '没有可恢复的（可能都已存在，或收藏里没有库内剧）')));
  } catch (e) {
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(content: Text('恢复失败：$e')));
  }
}

/// **手动强制重跑三大源的更新时刻表索引**。
///
/// ## 与追剧页 `_ensureTimelineIndexed` 的关系
/// 两处**共用** `reindexTimelines`（顶层函数）——
/// 避免"一处改了源、另一处没改"（本仓库踩过"修了但没修全"）。
///
/// ## 为什么值得给用户
/// 索引默认按 **24h TTL** 跳过；订阅的剧改档后用户要等一天。
/// 手动入口能立刻刷新，也便于用户自助确认功能是否正常。
Future<void> _reindexTimelines(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger?.showSnackBar(const SnackBar(
      content: Text('正在更新时刻表（B站/爱奇艺/优酷）…'),
      duration: Duration(seconds: 2)));
  try {
    final n = await reindexTimelines(ref: ref);
    // 追剧页要重新读一次时刻表（否则卡片上的时刻还是旧的）
    ref.invalidate(subscriptionsProvider);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(
        content: Text(n > 0
            ? '时刻表已更新（$n 条）'
            : '时刻表已是最新（本次 0 条新增）')));
  } catch (e) {
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(content: Text('更新失败：$e')));
  }
}
