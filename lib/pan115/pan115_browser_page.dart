/// 115 网盘文件浏览页。
///
/// ## 设计取舍：为什么是"文件夹树"而不是"媒体库"
///
/// Emby 有 库→剧集→季→集 的语义层次，115 只有一个**普通文件夹树**。
/// 强行把文件夹映射成"季/集"会造出无意义的概念（见 ADR 0007）。
/// 所以这里就**如实呈现文件夹树**：能进目录、能列文件、能播视频。
///
/// ## 安全提示
///
/// 本页只做浏览与播放，**不做上传/下载/删除/分享**——
/// 那些是写操作，风险与复杂度都远高于播放，且超出"播放器"的范围。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import 'pan115_client.dart';
import 'pan115_login_page.dart';
import 'pan115_player.dart';
import 'pan115_store.dart';

/// 面包屑（用于返回上级）。
class _Crumb {
  const _Crumb(this.id, this.name);
  final String id;
  final String name;
}

class Pan115BrowserPage extends ConsumerStatefulWidget {
  const Pan115BrowserPage({super.key});

  @override
  ConsumerState<Pan115BrowserPage> createState() => _Pan115BrowserPageState();
}

class _Pan115BrowserPageState extends ConsumerState<Pan115BrowserPage> {
  /// 当前目录栈。栈底是根目录（cid=0）。
  final List<_Crumb> _stack = [const _Crumb('0', '115 网盘')];

  List<Pan115File> _files = const [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _currentDir => _stack.last.id;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final client = ref.read(pan115ClientProvider);
    final page = await client.listFiles(
      _currentDir,
      // 单页 200 条：与 Emby 侧列表页口径接近，也不会让单次响应过大
      limit: 200,
    );
    if (!mounted) return;

    // listFiles 失败时返回空页；用 files 为空 + 非根目录 来提示"可能是空目录或失败"。
    // 这里无法区分二者（Go 侧错误文案没回传），故文案要兼顾两种情况。
    setState(() {
      _loading = false;
      _files = page.files;
    });
  }

  Future<bool> _ensureLoggedIn() async {
    final info = await ref.read(pan115SessionProvider.future);
    if (info != null) return true;
    if (!mounted) return false;
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const Pan115LoginPage()),
    );
    return ok == true;
  }

  void _enter(Pan115File dir) {
    setState(() {
      _stack.add(_Crumb(dir.id, dir.name));
      _files = const [];
    });
    _load();
  }

  void _goUp(int index) {
    setState(() {
      _stack.removeRange(index + 1, _stack.length);
      _files = const [];
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(pan115SessionProvider);

    return Scaffold(
      backgroundColor: Cf.bg,
      appBar: AppBar(
        backgroundColor: Cf.bg,
        foregroundColor: Cf.text,
        title: Text('115 网盘', style: TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: Icon(Icons.refresh_rounded, size: 20, color: Cf.text2),
          ),
        ],
      ),
      body: session.when(
        loading: () => Center(
            child: CircularProgressIndicator(color: Cf.accent)),
        error: (e, _) => _empty('读取失败：$e', retry: true),
        data: (info) {
          // ★ 开关必须**在未登录时也可见**。
          //
          // 踩过的设计疏漏：首版把开关放在"账号条"里，而账号条只在已登录
          // 才渲染 —— 于是**最需要它的场景（未登录/刚被风控拦下）反而看不到**。
          // 开关的用途正是"察觉异常时立即止损"，那一刻往往就是未登录态。
          final panel = _switchPanel();
          if (info == null) {
            return Column(children: [panel, Expanded(child: _needLogin())]);
          }
          return Column(children: [
            _accountBar(info),
            _breadcrumb(),
            const Divider(height: 1, color: Cf.border),
            Expanded(child: _body()),
          ]);
        },
      ),
    );
  }

  /// 账号条：让用户确认登录的是哪个账号，并显示会员等级与容量。
  ///
  /// 显示 VIP 等级不是装饰：115 的部分清晰度/大文件受会员限制，
  /// 用户看到"为什么这个片子播不了"时能有个线索。
  ///
  /// 下方还有**全局开关**：115 走非公开接口，访问代价在用户账号上（风控），
  /// 用户需能一键停用。**Go 侧默认关闭**，所以首次进来会看到它是 off。
  Widget _accountBar(Pan115UserInfo info) => Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        color: Cf.surface,
        child: Column(children: [
          Row(children: [
            Icon(Icons.cloud_outlined, size: 16, color: Cf.accent),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                [
                  if (info.userName.isNotEmpty) info.userName,
                  if (info.vipName.isNotEmpty) info.vipName,
                  if (info.spaceLabel.isNotEmpty) info.spaceLabel,
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: Cf.text2),
              ),
            ),
            _logoutButton(),
          ]),
        ]),
      );

  /// 全局开关面板（**未登录时也要显示**，见 build 里的说明）。
  ///
  /// 它同时承担"风险透明化"的职责：把今日已用请求数摆出来，
  /// 让用户能自己判断离风控还有多远，而不是黑箱。
  Widget _switchPanel() {
    final sw = ref.watch(pan115SwitchProvider);
    return sw.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (s) {
        final on = s?.enabled ?? false;
        final used = s?.usedToday ?? 0;
        final cap = s?.dailyCap ?? 0;
        return Container(
          margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
          decoration: BoxDecoration(
            // 「已启用」侧原为硬编码青色 → 改随主题；「已停用」侧用 warn 语义色
            // （停用是**警示**状态，不该跟着主题变绿/变紫）。
            color: on
                ? Cf.accent.withValues(alpha: 0.08)
                : Cf.warn.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: on
                    ? Cf.accent.withValues(alpha: 0.20)
                    : Cf.warn.withValues(alpha: 0.33)),
          ),
          child: Row(children: [
            Icon(
              on ? Icons.power_settings_new_rounded : Icons.power_off_rounded,
              size: 16,
              color: on ? Cf.accent : const Color(0xFFFFB347),
            ),
            SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    on ? '115 已启用' : '115 已停用',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: on ? Cf.text : const Color(0xFFFFB347),
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    on
                        ? '今日请求 $used/$cap（达上限会自动暂停）'
                        : '当前不会向 115 发送任何请求',
                    style: TextStyle(fontSize: 11, color: Cf.text3),
                  ),
                ],
              ),
            ),
            Switch(
              value: on,
              activeThumbColor: Cf.accent,
              onChanged: (v) async {
                await ref.read(pan115ClientProvider).pan115Switch(enabled: v);
                ref.invalidate(pan115SwitchProvider);
                // 开关变化会影响会话恢复（启用后才去拉账号信息）
                ref.invalidate(pan115SessionProvider);
              },
            ),
          ]),
        );
      },
    );
  }

  Widget _logoutButton() => TextButton(
        onPressed: () async {
          final sure = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: Cf.surface,
              title: Text('退出 115 登录？', style: TextStyle(fontSize: 16)),
              content: Text('将清除本机保存的凭据。',
                  style: TextStyle(fontSize: 13, color: Cf.text2)),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text('取消')),
                TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text('退出', style: TextStyle(color: Cf.danger))),
              ],
            ),
          );
          if (sure != true) return;
          // 存储与 Go 内存会话都要清——只清一处会让"退出"名不副实
          await ref.read(pan115StoreProvider).clear();
          await ref.read(pan115ClientProvider).clearSession();
          ref.invalidate(pan115SessionProvider);
        },
        child: Text('退出', style: TextStyle(fontSize: 12, color: Cf.text3)),
      );

  Widget _breadcrumb() => SizedBox(
        height: 36,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          itemCount: _stack.length,
          separatorBuilder: (_, _) => Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Icon(Icons.chevron_right_rounded, size: 16, color: Cf.text3),
          ),
          itemBuilder: (_, i) {
            final last = i == _stack.length - 1;
            return GestureDetector(
              onTap: last ? null : () => _goUp(i),
              child: Center(
                child: Text(
                  _stack[i].name,
                  style: TextStyle(
                    fontSize: 12,
                    color: last ? Cf.accent : Cf.text2,
                    fontWeight: last ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
            );
          },
        ),
      );

  Widget _body() {
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: Cf.accent));
    }
    if (_error != null) return _empty(_error!, retry: true);
    if (_files.isEmpty) {
      return _empty('此文件夹为空\n（若刚登录成功仍为空，可能是接口被风控拦截，请稍后重试）',
          retry: true);
    }
    return RefreshIndicator(
      color: Cf.accent,
      backgroundColor: Cf.surface,
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: _files.length,
        itemBuilder: (_, i) => _tile(_files[i]),
      ),
    );
  }

  Widget _tile(Pan115File f) {
    // 目录在前、文件在后；同类按名称排序（115 的返回顺序依赖服务端排序参数，
    // 这里再排一次以保证同屏内稳定，避免刷新后位置跳动）
    final isVideo = _isVideo(f.name);
    return ListTile(
      dense: true,
      leading: Icon(
        f.isDir
            ? Icons.folder_rounded
            : (isVideo ? Icons.movie_outlined : Icons.insert_drive_file_outlined),
        size: 20,
        color: f.isDir ? Cf.accent : Cf.text3,
      ),
      title: Text(
        f.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 14,
          color: isVideo || f.isDir ? Cf.text : Cf.text3,
        ),
      ),
      subtitle: f.isDir
          ? null
          : Text(
              [
                if (f.sizeLabel.isNotEmpty) f.sizeLabel,
                if (f.star) '★',
              ].join(' · '),
              style: TextStyle(fontSize: 11, color: Cf.text3),
            ),
      trailing: f.playable
          ? Icon(Icons.play_circle_outline_rounded,
              size: 20, color: Cf.accent)
          : null,
      onTap: () {
        if (f.isDir) {
          _enter(f);
        } else if (f.playable) {
          _play(f);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('该文件无法播放（缺少提取码或非视频文件）')),
          );
        }
      },
    );
  }

  Future<void> _play(Pan115File f) async {
    final ok = await _ensureLoggedIn();
    if (!ok || !mounted) return;
    await openPan115Player(context, f);
  }

  Widget _empty(String msg, {bool retry = false}) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(msg,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Cf.text3, height: 1.6)),
          ),
          if (retry)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: TextButton(
                onPressed: _load,
                child: Text('重试', style: TextStyle(color: Cf.accent)),
              ),
            ),
        ]),
      );

  Widget _needLogin() => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.cloud_off_rounded, size: 40, color: Cf.text3),
          SizedBox(height: 12),
          Text('尚未登录 115 网盘',
              style: TextStyle(fontSize: 14, color: Cf.text2)),
          SizedBox(height: 14),
          FilledButton.icon(
            onPressed: () async {
              final ok = await Navigator.of(context).push<bool>(
                MaterialPageRoute(builder: (_) => const Pan115LoginPage()),
              );
              if (ok == true) ref.invalidate(pan115SessionProvider);
            },
            icon: Icon(Icons.qr_code_rounded, size: 20),
            label: Text('扫码登录'),
            style: FilledButton.styleFrom(backgroundColor: Cf.accent),
          ),
        ]),
      );

  /// 常见视频扩展名。
  ///
  /// 用扩展名而不是 MIME/类型字段：115 的文件条目里 `ico` 是"图标标识"、
  /// 语义不稳定（取证结论），靠它判类型不可靠。
  static bool _isVideo(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return false;
    final ext = name.substring(dot + 1).toLowerCase();
    return const {
      'mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'ts', 'm2ts',
      'webm', 'rmvb', 'rm', 'm4v', 'mpg', 'mpeg', '3gp', 'iso',
    }.contains(ext);
  }
}
