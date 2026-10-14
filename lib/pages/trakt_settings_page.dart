import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/theme.dart';
import '../data/builtin_secret.dart';
import '../data/trakt_client.dart';
import '../state/providers.dart';

/// **Trakt 设置面板**（用户 2026-10-14 要求，对齐其给的 UI 稿）。
///
/// ## 面板结构（截图）
/// ```text
/// ┌────────────────────────────────────────────┐
/// │ [T] Trakt                    [登录]    ⌃   │
/// │     连接 Trakt 账户以同步观看记录和收藏        │
/// ├────────────────────────────────────────────┤
/// │ 实时追踪                              关  ○─│
/// │ 播放时自动向 Trakt 报告观看进度               │
/// ├────────────────────────────────────────────┤
/// │ 同步已看状态                          关  ○─│
/// │ 在详情页显示 Trakt 同步按钮                  │
/// ├────────────────────────────────────────────┤
/// │ 续播检查                              关  ○─│
/// │ 播放时检查 Trakt 进度并提示从上次位置继续       │
/// └────────────────────────────────────────────┘
/// ```
///
/// ## ★ 认证方式：**设备码流程**（不是 PKCE 回调）
/// 实测（2026-10-14）：
/// ```text
/// POST /oauth/device/code {client_id}
///   → { user_code: "KY5QEMVZ", verification_url: "https://auth.trakt.tv/activate",
///       expires_in: 600, interval: 6 }
/// POST /oauth/device/token {code, client_id}   ← 轮询
///   400（**body 为空**） = 等待用户授权   ⇒ 继续轮询
///   404（**body 为空**） = 码无效/过期    ⇒ 重新申请
///   200                 = 成功
/// ```
/// ### 为什么不用 PKCE + 自定义 scheme
/// 1. 用户配置的重定向 URI 曾多写 `https://` 前缀（畸形）⇒ 设备码**没有回调**，绕开
/// 2. Trakt 后台对自定义 scheme 报「不安全重定向 URI」警告 ⇒ 设备码无此问题
/// 3. 不用装 `app_links`（项目未装）⇒ **零新增依赖**
///
/// ⚠️ **未实测**：轮询成功后的 token 结构与 refresh 流程
///    （需用户本人在浏览器输码，我无法代做）⇒ 解析写成容错式。
class TraktSettingsPage extends ConsumerStatefulWidget {
  const TraktSettingsPage({super.key});

  @override
  ConsumerState<TraktSettingsPage> createState() => _TraktSettingsPageState();
}

class _TraktSettingsPageState extends ConsumerState<TraktSettingsPage> {
  bool _expanded = true;
  bool _busy = false;

  /// 本次登录是否用了**内置**的 Client ID（而非用户自填）。
  ///
  /// ## 为什么要区分（诚实原则）
  /// 用户该知道"凭据从哪来"：
  /// · 内置 ⇒ 设置页显示"已内置（无需填写）"
  /// · 自填 ⇒ 显示"已配置（点此修改）"
  /// ⇒ 不把两者混成一句模糊的"已配置"。
  bool _usingBuiltin = false;

  /// 授权页的 WebView 控制器。
  ///
  /// ⚠️ **必须在这里持有**（不能建在 dialog 的 builder 里）——
  /// `WebViewController` 每次 build 都新建会**重复加载**并丢状态。
  late final WebViewController _web = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    // 该页用 htmx 局部更新 ⇒ **必须开 JS**，否则按钮点了没反应
    ..setUserAgent('Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36');
  String? _clientId;
  String? _accessToken;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = ref.read(sessionStoreProvider);
    final id = await store.loadTraktClientId();
    final tk = await store.loadTraktAccessToken();
    if (!mounted) return;
    // 探测内置凭据是否可用（只影响 UI 文案，**不改存储**）
    final builtin = (id == null || id.isEmpty)
        ? await unsealBuiltinTraktClientId()
        : null;
    if (!mounted) return;
    setState(() {
      _clientId = id;
      _accessToken = tk;
      _usingBuiltin = builtin != null && builtin.isNotEmpty;
    });
  }

  bool get _loggedIn => (_accessToken ?? '').isNotEmpty;

  Future<void> _toast(String m) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(seconds: 2)),
    );
  }

  // ══════════════════════════════════════════════════════════════
  //  Client ID（凭据：只进 secure_storage，仓库里不放任何值）
  // ══════════════════════════════════════════════════════════════

  /// 弹 **Trakt Client ID** 输入框。
  ///
  /// ## 为什么必须由用户填（不能内置）
  /// §红线：**凭据一律不入库**，仓库里连占位符都不放。
  /// 用户需自己在 <https://trakt.tv/oauth/applications> 建应用拿 Client ID。
  Future<void> _editClientId() async {
    final store = ref.read(sessionStoreProvider);
    final cur = await store.loadTraktClientId() ?? '';
    if (!mounted) return;
    final ctl = TextEditingController(text: cur);
    // ⚠️ `saved` 声明在 try 外（内部用 final 的话出了 try 不可见 —— 已在
    //    calendar_page 踩过同一个错，见那里的注释）
    bool? saved;
    try {
      saved = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: Cf.surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Cf.radiusMd)),
          title: const Text('Trakt Client ID'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '连接 Trakt 需要你自己的 Client ID。\n\n'
                '申请步骤：\n'
                '1. 打开 trakt.tv/oauth/applications\n'
                '2. New Application（名字随填）\n'
                '3. Redirect URI 填：\n'
                '   com.cineflow.app://auth/oauth2callback\n'
                '4. 保存后复制 **Client ID**\n\n'
                '（只存在本机安全存储，不会上传）',
                style: Cf.caption.copyWith(color: Cf.text3),
              ),
              const SizedBox(height: Cf.gap2),
              TextField(
                controller: ctl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Client ID',
                  hintText: '64 位十六进制',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            if (cur.isNotEmpty)
              TextButton(
                onPressed: () async {
                  await store.saveTraktClientId('');
                  // 清 Client ID 时**同时清 token**（否则留着一份无主的登录态）
                  await store.clearTraktTokens();
                  if (ctx.mounted) Navigator.pop(ctx, true);
                },
                child: const Text('清除'),
              ),
            FilledButton(
              onPressed: () async {
                await store.saveTraktClientId(ctl.text);
                if (ctx.mounted) Navigator.pop(ctx, true);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      );
    } finally {
      ctl.dispose();
    }
    if (saved == true) {
      await _load();
      await _toast('已保存 Client ID');
    }
  }

  // ══════════════════════════════════════════════════════════════
  //  登录（设备码流程）
  // ══════════════════════════════════════════════════════════════

  Future<void> _login() async {
    if (_busy) return;
    final store = ref.read(sessionStoreProvider);
    // ① 用户自填优先（尊重用户：他特意填了自己的就用他的）
    var id = await store.loadTraktClientId() ?? '';

    // ② 没填 ⇒ 尝试**解封内置**的（签名绑定混淆，见 builtin_secret.dart）
    //
    // ## 为什么内置（用户 2026-10-14 要求）
    // > Client ID 以后内置在我的应用中，不对外公开
    // ⇒ 开箱即用：用户不必先去 trakt.tv/oauth/applications 建应用。
    //
    // ⚠️ 解封失败是**正常情形之一**（换签名重打包 / 平台无原生通道）
    //    ⇒ 静默回退到"让用户填"，**不报错**（见 unsealBuiltinTraktClientId）。
    if (id.isEmpty) {
      final builtin = await unsealBuiltinTraktClientId();
      if (builtin != null && builtin.isNotEmpty) {
        id = builtin;
        _usingBuiltin = true;
        debugPrint('[Trakt] 使用内置 Client ID（签名绑定解封成功）');
      }
    }

    if (id.isEmpty) {
      // 都没有 ⇒ 让他填（一步到位，不用先报错再跳）
      await _editClientId();
      id = await store.loadTraktClientId() ?? '';
      if (id.isEmpty) return;
    }
    if (!mounted) return;

    setState(() => _busy = true);
    final client = TraktClient(clientId: id);
    try {
      final session = await client.startDeviceAuth();
      if (session == null) {
        await _toast('申请授权码失败 —— 请检查 Client ID 是否正确');
        return;
      }
      if (!mounted) return;
      // 弹出授权指引（显示码 + 打开浏览器 + 轮询）
      final ok = await _showAuthorizeDialog(client, session);
      if (ok == true) {
        await _load();
        await _toast('已连接 Trakt');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 授权对话框：显示 6 位码 + 一键打开浏览器 + **按 interval 轮询**。
  ///
  /// ## 轮询策略（基于实测）
  /// · 间隔 = 服务端给的 `interval`（实测 6s）
  /// · `400` ⇒ 继续等（**body 为空，只能靠状态码判**）
  /// · `404` ⇒ 码失效 ⇒ 停止并提示重来
  /// · `429` ⇒ 退避（多等一个 interval）
  /// · 到 `expires_in` 超时 ⇒ 停止
  /// · 用户关掉对话框 ⇒ **停止轮询**（不要后台偷跑）
  Future<bool?> _showAuthorizeDialog(
      TraktClient client, TraktDeviceSession session) async {
    var cancelled = false;
    final completer = Completer<bool>();

    // 后台轮询：把结果写进 ValueNotifier，UI 只读它（不在 build 里跑网络）
    final status = ValueNotifier<String>('等待授权…');
    final done = ValueNotifier<bool>(false);

    // ⚠️ `disposed` 与 `cancelled` **必须分开**（审计发现的真隐患）：
    //
    // ## 两个标志的区别
    // · `cancelled` = **用户不再关心**（关弹窗）⇒ 停止轮询
    // · `disposed`  = `status`/`done` 两个 ValueNotifier **已被 dispose**
    //                 ⇒ **绝不能再写它们**（写了 Flutter 会抛
    //                 `A ValueNotifier was used after being disposed`）
    //
    // ## 为什么不能只用一个
    // 后台 Future 可能正卡在 `await pollDeviceToken()`（网络请求中），
    // 此时用户关掉弹窗 ⇒ 我们把 notifier dispose 了 ⇒
    // 请求返回后那一行 `status.value = ...` **就会抛异常**。
    // ⇒ 所以写之前必须检查 `disposed`（而不是只看 `cancelled`）。
    var disposed = false;

    unawaited(() async {
      var interval = session.intervalSec;
      while (!cancelled && !session.isExpired && !done.value) {
        await Future<void>.delayed(Duration(seconds: interval));
        if (cancelled || disposed || !mounted) break;
        final r = await client.pollDeviceToken(session);
        // ⚠️ **请求返回后必须再查一次** —— 上面那次 await 期间用户可能已关窗
        if (cancelled || disposed || !mounted) break;
        switch (r.state) {
          case TraktAuthState.success:
            await ref.read(sessionStoreProvider).saveTraktTokens(
                  access: r.accessToken!,
                  refresh: r.refreshToken,
                );
            // 保存 token 也可能耗时 ⇒ 再查一次再写 UI
            if (disposed) {
              if (!completer.isCompleted) completer.complete(true);
              return;
            }
            status.value = '授权成功';
            done.value = true;
            if (!completer.isCompleted) completer.complete(true);
            return;
          case TraktAuthState.expired:
            status.value = r.message ?? '授权码已失效';
            done.value = true;
            if (!completer.isCompleted) completer.complete(false);
            return;
          case TraktAuthState.slowDown:
            interval = (interval + 3).clamp(3, 30);
            status.value = '请求过于频繁，放慢轮询…';
          case TraktAuthState.waiting:
            status.value = '等待授权…（剩余 ${session.remainingSec}s）';
          case TraktAuthState.error:
            // ⚠️ 网络失败**不算授权失败**（§6.9.1）⇒ 继续轮询，只提示
            status.value = '网络抖动，重试中…（剩余 ${session.remainingSec}s）';
        }
      }
      if (!completer.isCompleted && !done.value && !disposed) {
        status.value = '已超时，请重新登录';
        if (!completer.isCompleted) completer.complete(false);
      }
    }());

    if (!mounted) return null;
    // 先让 WebView 加载授权页（弹窗一出现就有内容，避免白屏）
    unawaited(_web.loadRequest(Uri.parse(session.verificationUrl)));
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Cf.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Cf.radiusMd)),
        title: const Text('连接 Trakt'),
        content: SizedBox(
          width: double.maxFinite,
          height: 460,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ══════ 内置 WebView（用户 2026-10-14 要求）══════
              //
              // ## 加载哪个 URL
              // `https://auth.trakt.tv/activate` —— 设备侧实测会 **302**
              // 到 `/signin?callbackURL=%2Factivate`，即 Trakt 的登录页
              // （用户截图里那个：语言 / 邮箱 / 「给我发送登录链接」）。
              //
              // ## 为什么不需要 NavigationDelegate 拦截
              // 设备码流程**没有回调** —— 用户在页面里输 6 位码，Trakt 自己确认。
              // 我们只**轮询** `/oauth/device/token`（见下面的轮询逻辑）
              // ⇒ 这是它与 PKCE 方案的关键区别（那才需要抓 redirect）。
              //
              // ## 必须开 JS
              // 该页用 **htmx**（服务端渲染 + 局部更新）⇒
              // 不开 JS 则按钮点了没反应。
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(Cf.radiusSm),
                  child: WebViewWidget(controller: _web),
                ),
              ),
              const SizedBox(height: Cf.gap2),
              // ══════ 授权码（用户要照着输）══════
              Row(children: [
                Text('授权码：', style: Cf.caption.copyWith(color: Cf.text3)),
                SelectableText(
                  session.userCode,
                  style: Cf.title.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                    color: Cf.accent,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '复制授权码',
                  onPressed: () async {
                    await Clipboard.setData(
                        ClipboardData(text: session.userCode));
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(content: Text('授权码已复制')),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy_rounded, size: 18),
                ),
              ]),
              // ══════ 「在浏览器中打开」兜底 ══════
              //
              // ## 为什么必须有（实测依据）
              // Trakt 登录页提供 **Google / Apple** 登录；而 Google
              // **明确禁止**在嵌入式 WebView 里做 OAuth
              // （错误 `disallowed_useragent`，判据是 UA 含 `; wv)`）。
              // ⇒ 这不是我们能绕过的（绕过违反其政策，也会被风控）
              // ⇒ 用邮箱登录可在 WebView 内完成；用 Google 则必须跳浏览器。
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () async {
                    final uri = Uri.tryParse(session.verificationUrl);
                    if (uri == null) return;
                    if (!await launchUrl(uri,
                        mode: LaunchMode.externalApplication)) {
                      if (ctx.mounted) {
                        ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                            content:
                                Text('请手动打开 ${session.verificationUrl}')));
                      }
                    }
                  },
                  icon: const Icon(Icons.open_in_new_rounded, size: 16),
                  label: const Text('用 Google 登录？在浏览器中打开'),
                ),
              ),
              // ══════ 轮询状态 ══════
              ValueListenableBuilder<String>(
                valueListenable: status,
                builder: (_, v, __) => Row(children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: Cf.gap2),
                  Expanded(
                    child: Text(v,
                        style: Cf.caption.copyWith(color: Cf.text2)),
                  ),
                ]),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              if (!completer.isCompleted) completer.complete(false);
              Navigator.pop(ctx, false);
            },
            child: const Text('取消'),
          ),
        ],
      ),
    );
    cancelled = true;
    // ⚠️ **顺序很重要**：先置 `disposed`（让后台 Future 停止写 UI），
    //    再 dispose 两个 notifier。
    //    反过来的话，后台 Future 可能在 dispose 之后、置标志之前写一次 ⇒ 抛异常。
    disposed = true;
    status.dispose();
    done.dispose();
    return result ?? await completer.future;
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Cf.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Cf.radiusMd)),
        title: const Text('断开 Trakt'),
        content: const Text('将清除本机的 Trakt 登录状态（保留 Client ID）。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('断开'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(sessionStoreProvider).clearTraktTokens();
    await _load();
    await _toast('已断开 Trakt');
  }

  // ══════════════════════════════════════════════════════════════
  //  UI
  // ══════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Cf.bg,
      appBar: AppBar(
        backgroundColor: Cf.bg,
        title: const Text('Trakt'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(Cf.gap4),
        children: [
          _headerCard(),
          const SizedBox(height: Cf.gap3),
          // 三个开关：**尚未接后端**（如实标注，不假装已实现）
          _switchGroup(),
          const SizedBox(height: Cf.gap3),
          _clientIdCard(),
        ],
      ),
    );
  }

  Widget _headerCard() {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Cf.radiusMd),
        color: Cf.surface,
        border: Border.all(color: Cf.border),
      ),
      child: Column(children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: Cf.gap4, vertical: Cf.gap3),
            child: Row(children: [
              // Trakt 品牌色（官方紫）
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: const Color(0xFF9F42C6),
                  borderRadius: BorderRadius.circular(Cf.radiusSm),
                ),
                child: const Icon(Icons.sync_alt_rounded,
                    color: Colors.white, size: 20),
              ),
              const SizedBox(width: Cf.gap3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Trakt',
                        style: Cf.body.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                      _loggedIn
                          ? '已连接 —— 可同步观看记录和收藏'
                          : '连接 Trakt 账户以同步观看记录和收藏',
                      style: Cf.micro,
                    ),
                  ],
                ),
              ),
              // 登录 / 断开
              if (_busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                FilledButton(
                  onPressed: _loggedIn ? _logout : _login,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(64, 36), // ≥48dp 命中区（§6.4.1）
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  child: Text(_loggedIn ? '断开' : '登录'),
                ),
              const SizedBox(width: Cf.gap2),
              Icon(
                _expanded
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                color: Cf.text3,
              ),
            ]),
          ),
        ),
        // 展开区（对齐截图：展开时显示三个开关）
        if (_expanded) ...[
          Divider(color: Cf.border, height: 1),
          _switchRow('实时追踪', '播放时自动向 Trakt 报告观看进度'),
          Divider(color: Cf.border, height: 1),
          _switchRow('同步已看状态', '在详情页显示 Trakt 同步按钮'),
          Divider(color: Cf.border, height: 1),
          _switchRow('续播检查', '播放时检查 Trakt 进度并提示从上次位置继续'),
        ],
      ]),
    );
  }

  /// 三个开关（**未接后端**）。
  ///
  /// ## ⚠️ 为什么显示为「关」且不可点
  /// 它们的后端行为（上报进度 / 同步已看 / 续播检查）需要
  /// `POST /scrobble/*`、`POST /sync/history` 等**写入类**接口，
  /// 而本项目**从未验证过**那些接口（也不该在没验证前让用户以为能用）。
  ///
  /// ⇒ §5.8 的规矩：**未接入的功能不许假装已实现**。
  ///   所以这里显示灰态 + 点击提示"开发中"，而不是给一个点了没反应的开关。
  Widget _switchRow(String title, String sub) {
    return InkWell(
      onTap: () => _toast('$title：功能开发中（需要先完成 Trakt 写入接口的实测）'),
      child: Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: Cf.gap4, vertical: Cf.gap3),
        child: Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Cf.body.copyWith(color: Cf.text3)),
                const SizedBox(height: 2),
                Text(sub, style: Cf.micro),
              ],
            ),
          ),
          Text('关', style: Cf.micro.copyWith(color: Cf.text3)),
          const SizedBox(width: Cf.gap2),
          // 视觉上是关掉的 Switch（`onChanged: null` = disabled）
          Switch(value: false, onChanged: null),
        ]),
      ),
    );
  }

  Widget _switchGroup() => const SizedBox.shrink();

  Widget _clientIdCard() {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Cf.radiusMd),
        color: Cf.surface,
        border: Border.all(color: Cf.border),
      ),
      child: InkWell(
        onTap: _editClientId,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: Cf.gap4, vertical: Cf.gap3),
          child: Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Client ID',
                      style: Cf.body.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    (_clientId ?? '').isNotEmpty
                        ? '已配置（点此修改）'
                        : (_usingBuiltin
                            // ⚠️ 如实标注来源：内置的是**混淆存储**，
                            //    不是"看不见的钥匙"（见 builtin_secret.dart）
                            ? '已内置（无需填写 · 点此覆盖）'
                            : '必填 —— 点此填写'),
                    style: Cf.micro,
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                size: Cf.iconMd, color: Cf.text3),
          ]),
        ),
      ),
    );
  }
}
