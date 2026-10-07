/// 我的 —— 用户头卡（真实头像/服务器）+ 观看统计（Emby 真实数据）+ 设置组 + 退出
library;

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
import '../data/models.dart';
import '../pan115/pan115_browser_page.dart';
import '../pan115/pan115_store.dart';
import '../state/providers.dart';

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

final _statsProvider = FutureProvider.autoDispose<_Stats>((ref) async {
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

class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider).value;
    final stats = ref.watch(_statsProvider);

    return Scaffold(
      backgroundColor: Cf.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            SizedBox(height: 12),
            _headCard(context, ref, session, stats),
            SizedBox(height: 12),
            _statGrid(stats),
            SizedBox(height: 14),
            _settingsGroup([
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
              _SettingItem(
                icon: Icons.history_rounded,
                color: const Color(0xFFFFB347),
                title: '播放历史',
                sub: '最近观看的全部记录',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const HistoryPage()),
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
                  Expanded(
                    child: Text(
                      session == null
                          ? '未连接服务器'
                          : (Uri.tryParse(session.serverUrl)?.host ??
                              session.serverUrl),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11, color: Cf.text3),
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

  Widget _statGrid(AsyncValue<_Stats> stats) {
    return stats.when(
      loading: () => SizedBox(height: 66),
      error: (_, _) => const SizedBox.shrink(),
      data: (s) => Row(children: [
        _statCard('${s.moviesWatched}', '已看电影'),
        _statCard('${s.seriesWatching}', '追剧中'),
        _statCard('${s.episodesWatched}', '已看分集'),
        _statCard('${s.favorites}', '收藏'),
      ]),
    );
  }

  Widget _statCard(String value, String label) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.only(right: 10),
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
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
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 9, color: Cf.text3)),
        ]),
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
