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
import 'history_page.dart';
import 'playback_settings_page.dart';
import 'kernel_settings_page.dart';
import '../data/emby_provider.dart';
import '../data/media_provider.dart';
import '../data/session_store.dart';
import '../data/models.dart';
import '../pan115/pan115_browser_page.dart';
import '../pan115/pan115_store.dart';
import '../state/providers.dart';
import 'server_list_page.dart';
import 'account_manager_page.dart';
import 'calendar_page.dart';

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
            _statGrid(context, stats),
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
              // ★ 「继续观看」放在这里（用户要求"将下面的播放历史移动到收藏后面"）
              //
              // ## 为什么改名（从"播放历史"→"继续观看"）
              // 用户明确："播放历史对应的内容应该是 emby 服务端的继续观看内容"。
              // 旧名字 + 旧数据源（`Filters=IsPlayed` = 已看完）会误导用户。
              _SettingItem(
                icon: Icons.play_circle_outline_rounded,
                color: const Color(0xFFFFB347),
                title: '继续观看',
                sub: '服务端的续播列表 · 从上次位置接着看',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const HistoryPage()),
                ),
              ),
              _SettingItem(
                icon: Icons.apartment_rounded,
                color: const Color(0xFFE17055),
                title: '制片公司',
                sub: '按片厂浏览（漫威 / 皮克斯 / 东宝…）',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ServerListPage(
                      title: '制片公司',
                      emptyIcon: Icons.apartment_outlined,
                      emptyText: '服务器没有制片公司数据',
                      // 公司是**容器**不是可播条目 ⇒ 点它进"该公司作品"
                      onItemTap: (ctx, r, item) => Navigator.push(
                        ctx,
                        MaterialPageRoute(
                          builder: (_) => ServerListPage(
                            title: item.name,
                            emptyIcon: Icons.movie_outlined,
                            emptyText: '该公司暂时没有作品',
                            loader: (api) => api.getStudioItems(item.name),
                          ),
                        ),
                      ),
                      loader: (api) => api.getStudios(),
                    ),
                  ),
                ),
              ),
              _SettingItem(
                icon: Icons.queue_music_rounded,
                color: const Color(0xFF00B894),
                title: '服务端播放列表',
                sub: '在 Emby 里建的列表 · 多端同步',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ServerListPage(
                      title: '播放列表',
                      emptyIcon: Icons.playlist_remove_rounded,
                      emptyText: '服务器上没有播放列表\n（可在 Emby 网页端创建）',
                      onItemTap: (ctx, r, item) => Navigator.push(
                        ctx,
                        MaterialPageRoute(
                          builder: (_) => ServerListPage(
                            title: item.name,
                            emptyIcon: Icons.playlist_remove_rounded,
                            emptyText: '这个列表是空的',
                            loader: (api) => api.getPlaylistItems(item.id),
                          ),
                        ),
                      ),
                      loader: (api) => api.getPlaylists(),
                    ),
                  ),
                ),
              ),
              _SettingItem(
                icon: Icons.event_available_rounded,
                color: const Color(0xFF0984E3),
                title: '追剧日历',
                // ★★ 2026-10-11 改为**真正的周视图日历**（多源聚合）
                //
                // ## 改之前是什么（用户要求重构）
                // 只是把 Emby 的 `/Shows/Upcoming` 套进通用列表页
                //（`ServerListPage` + `loader: api.getUpcoming`）——
                // 数据只来自**当前那一台 Emby**，且没有周一到周日的视图。
                //
                // ## 改之后（按用户"聚焦国内"的要求调整过）
                // `CalendarPage`：周一~周日横向选择条 + 每天更新列表。
                // 数据源：
                // · **TMDB**（主力）—— `discover/tv` 按 `air_date` 逐天查
                //   国产剧；实测每天 20 条 `lang=zh`
                // · **B站**（补充）—— 仅番剧/国创（**动漫**）；
                //   实测 B站**没有国产真人剧**
                // · ~~TVmaze~~ 已按用户要求删除
                // · 腾讯/爱奇艺/优酷**不做**（实测接口返回空壳/风控）
                sub: '周一~周日 · 国产剧集 / 动漫更新（TMDB + B站）',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const CalendarPage()),
                ),
              ),
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
                  Container(
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
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(children: [
                    Icon(
                      (cur != null &&
                              SessionStore.accountKey(cur) ==
                                  SessionStore.accountKey(a))
                          ? Icons.check_circle_rounded
                          : Icons.circle_outlined,
                      size: 13,
                      color: (cur != null &&
                              SessionStore.accountKey(cur) ==
                                  SessionStore.accountKey(a))
                          ? Cf.accent
                          : Cf.text3,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${a.user.name} · '
                        '${Uri.tryParse(a.serverUrl)?.host ?? a.serverUrl}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: Cf.text2),
                      ),
                    ),
                  ]),
                ),
            ],
          ),
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }

  /// 四张统计卡 —— **全部可点**，点进去看具体内容（用户要求）。
  ///
  /// ## ★★ 用户原话
  /// > "已看电影可以、追剧中、已看分级、收藏都应该可以点击且能看到具体内容"
  ///
  /// ## 每张卡对应的**服务端查询**（全部实测验证过）
  /// | 卡 | 查询 | 实测 |
  /// |---|---|---|
  /// | 已看电影 | `IncludeItemTypes=Movie&Filters=IsPlayed` | ✅ s2: 11 条 |
  /// | 追剧中 | `IncludeItemTypes=Series&Filters=IsUnplayed` | ✅ s2: 5322 |
  /// | 已看分集 | `IncludeItemTypes=Episode&Filters=IsPlayed` | ✅ s2: 916 |
  /// | 收藏 | `IncludeItemTypes=Movie,Series,Episode&Filters=IsFavorite` | ✅ s2: 2 条（黑夜告白/战旗如画） |
  ///
  /// ⚠️ 全部走 `/Users/{uid}/Items`（**不带 `/emby/` 前缀**也通，
  /// 实测两种都 HTTP 200；带前缀更稳妥，见 `getItems` 的实现）。
  Widget _statGrid(BuildContext context, AsyncValue<_Stats> stats) {
    return stats.when(
      loading: () => const SizedBox(height: 66),
      error: (_, _) => const SizedBox.shrink(),
      data: (s) => Row(children: [
        _statCard(
          '${s.moviesWatched}',
          '已看电影',
          onTap: () => _openList(
            ctx: context,
            title: '已看电影',
            emptyIcon: Icons.movie_outlined,
            emptyText: '还没有标记为看过的电影',
            loader: (api) => api.getItems(
              includeTypes: 'Movie',
              filters: 'IsPlayed',
              sortBy: 'DatePlayed',
              sortOrder: 'Descending',
              limit: 200,
            ).then((p) => p.items),
          ),
        ),
        _statCard(
          '${s.seriesWatching}',
          '追剧中',
          onTap: () => _openList(
            ctx: context,
            title: '追剧中',
            emptyIcon: Icons.live_tv_outlined,
            emptyText: '没有未看完的剧集',
            loader: (api) => api.getItems(
              includeTypes: 'Series',
              filters: 'IsUnplayed',
              sortBy: 'DatePlayed',
              sortOrder: 'Descending',
              limit: 200,
            ).then((p) => p.items),
          ),
        ),
        _statCard(
          '${s.episodesWatched}',
          '已看分集',
          onTap: () => _openList(
            ctx: context,
            title: '已看分集',
            emptyIcon: Icons.checklist_rounded,
            emptyText: '还没有看过的分集',
            loader: (api) => api.getItems(
              includeTypes: 'Episode',
              filters: 'IsPlayed',
              sortBy: 'DatePlayed',
              sortOrder: 'Descending',
              limit: 200,
            ).then((p) => p.items),
          ),
        ),
        _statCard(
          '${s.favorites}',
          '收藏',
          onTap: () => _openList(
            ctx: context,
            title: '收藏',
            emptyIcon: Icons.favorite_border_rounded,
            emptyText: '还没有收藏任何内容',
            loader: (api) => api.getItems(
              includeTypes: 'Movie,Series,Episode',
              filters: 'IsFavorite',
              sortBy: 'DateCreated',
              sortOrder: 'Descending',
              limit: 200,
            ).then((p) => p.items),
          ),
        ),
      ]),
    );
  }

  /// 打开"某个统计项的具体内容"列表页（复用 `ServerListPage`）。
  ///
  /// ## 为什么复用而不新建页面
  /// `ServerListPage` 已经处理了加载/空态/错误态/点卡片进详情
  ///（制片公司、服务端播放列表、追剧日历都用它）
  /// ⇒ 新建一个只会重复这些逻辑，且空态文案容易写漏。
  void _openList({
    required BuildContext ctx,
    required String title,
    required IconData emptyIcon,
    required String emptyText,
    required Future<List<MediaItem>> Function(MediaProvider api) loader,
  }) {
    Navigator.push(
      ctx,
      MaterialPageRoute(
        builder: (_) => ServerListPage(
          title: title,
          emptyIcon: emptyIcon,
          emptyText: emptyText,
          loader: loader,
        ),
      ),
    );
  }

  Widget _statCard(String value, String label, {VoidCallback? onTap}) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        // ★ 可点卡片必须有按压反馈（§6.4.1：可点区域要能感知）
        child: Container(
          margin: const EdgeInsets.only(right: 10),
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Cf.radiusMd),
            color: Cf.surface,
            border: Border.all(color: Cf.border),
          ),
          child: Column(children: [
            // 200% 字号下数字（如 5289）会拆行——等比缩放保持单行
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(value,
                  maxLines: 1,
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      color: Cf.accent)),
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 9, color: Cf.text3)),
                // 一个小箭头暗示"可点"（否则用户不知道能点）
                if (onTap != null)
                  Icon(Icons.chevron_right_rounded,
                      size: 11, color: Cf.text3),
              ],
            ),
          ]),
        ),
      ),
    );
  }

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
  const _SettingItem({
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
        padding: const EdgeInsets.symmetric(
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
          const Icon(Icons.chevron_right_rounded,
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
