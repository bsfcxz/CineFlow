/// 账号管理页 —— 多 Emby 账号的增删与切换。
///
/// ## 为什么需要它（用户要求："增加多 emby 账号登录和资源整合"）
/// 聚合搜索的前提是"**有多个账号**"。而登录页每次登录都会覆盖当前会话
///（`cf_session`），用户想加第二台时必须能：
///   · 添加账号（**不切换**正在看的那台）
///   · 看到已登录的账号列表
///   · 手动切换到某一台
///   · 移除某个账号
///
/// ## 与登录页的关系
/// 登录页仍是"首次登录 / 换服务器"的入口；本页是**已登录账号的管理**。
/// 添加新账号复用了同一个登录表单（点"添加账号"跳到登录页）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../data/models.dart';
import '../data/session_store.dart';
import '../state/providers.dart';
import '../widgets/media_cards.dart';

class AccountManagerPage extends ConsumerWidget {
  const AccountManagerPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider);
    final current = ref.watch(sessionProvider).value;

    return Scaffold(
      backgroundColor: Cf.bg,
      appBar: AppBar(
        backgroundColor: Cf.bg,
        foregroundColor: Cf.text,
        title: const Text('账号与资源整合',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      ),
      body: accounts.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => CfErrorView(
          message: '读取账号失败：$e',
          onRetry: () => ref.invalidate(accountsProvider),
        ),
        data: (list) {
          if (list.isEmpty) {
            return const CfEmptyView(
              icon: Icons.person_off_outlined,
              message: '还没有已登录的账号',
              hint: '登录后会自动登记到这里',
            );
          }
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                child: Text(
                  '搜索会同时搜索以下 ${list.length} 台服务器；\n'
                  '首页与播放仍使用「当前」那一台。',
                  style: TextStyle(fontSize: 12, color: Cf.text3),
                ),
              ),
              for (final s in list)
                _AccountTile(
                  session: s,
                  isCurrent: current != null &&
                      SessionStore.accountKey(current) ==
                          SessionStore.accountKey(s),
                  onSwitch: () async {
                    await ref.read(sessionProvider.notifier).switchTo(s);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(
                            '已切换到 ${Uri.tryParse(s.serverUrl)?.host ?? s.serverUrl}'),
                        duration: const Duration(seconds: 2),
                      ));
                    }
                  },
                  onRemove: () => _confirmRemove(context, ref, s, current),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmRemove(
      BuildContext context, WidgetRef ref, MediaSession s,
      MediaSession? current) async {
    final host = Uri.tryParse(s.serverUrl)?.host ?? s.serverUrl;
    final isCurrent = current != null &&
        SessionStore.accountKey(current) == SessionStore.accountKey(s);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Cf.surface,
        title: const Text('移除账号', style: TextStyle(fontSize: 15)),
        content: Text(
          isCurrent
              // ⚠️ 移除"当前账号"等于退出登录 —— 必须说清楚，
              //    否则用户以为只是从列表里划掉
              ? '「$host」正在使用中。移除后会退出登录。'
              : '从整合列表中移除「$host」？',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('移除', style: TextStyle(color: Cf.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final n = ref.read(sessionProvider.notifier);
    await n.removeAccount(s);
    // 移除的是当前账号 ⇒ 同时退出登录（否则会话还指着已删除的账号）
    if (isCurrent) await n.logout();
  }
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.session,
    required this.isCurrent,
    required this.onSwitch,
    required this.onRemove,
  });

  final MediaSession session;
  final bool isCurrent;
  final VoidCallback onSwitch;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final host = Uri.tryParse(session.serverUrl)?.host ?? session.serverUrl;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: isCurrent ? Cf.accent : Cf.surface2,
        child: Icon(Icons.dns_rounded,
            size: 18, color: isCurrent ? Cf.ink : Cf.text3),
      ),
      title: Row(children: [
        Flexible(
          child: Text(host,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: Cf.text)),
        ),
        if (isCurrent) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: Cf.accent.withValues(alpha: .18),
              borderRadius: BorderRadius.circular(Cf.radiusXs),
            ),
            child: Text('当前',
                style: TextStyle(fontSize: 10, color: Cf.accent)),
          ),
        ],
      ]),
      subtitle: Text(
        session.user.name.isEmpty ? session.user.id : session.user.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: Cf.text3),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (!isCurrent)
          TextButton(
            onPressed: onSwitch,
            child: const Text('切换', style: TextStyle(fontSize: 12)),
          ),
        IconButton(
          tooltip: '移除',
          onPressed: onRemove,
          icon: const Icon(Icons.delete_outline_rounded, size: 18),
          color: Cf.text3,
        ),
      ]),
      onTap: isCurrent ? null : onSwitch,
    );
  }
}
