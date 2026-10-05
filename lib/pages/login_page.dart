/// 登录 / 服务器管理页（对应原型 #page-login，手机端布局）
/// 真实 Emby 认证：POST /Users/AuthenticateByName；凭据仅存手机安全存储。
library;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../core/version.dart';
import '../data/emby_provider.dart';
import '../data/session_store.dart';
import '../state/providers.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _addr = TextEditingController(text: 'http://');
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _remember = true;
  bool _obscure = true;
  bool _busy = false;
  int _selectedServer = -1;
  List<SavedServer> _servers = const [];

  @override
  void initState() {
    super.initState();
    Future(() async {
      try {
        final s = await ref.read(sessionStoreProvider).loadServers();
        if (mounted) setState(() => _servers = s);
      } catch (_) {
        // 存储不可用（如测试环境）时忽略
      }
    });
  }

  @override
  void dispose() {
    _addr.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();

    var url = _addr.text.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    final username = _user.text.trim();
    if (url.length <= 7 || username.isEmpty || _pass.text.isEmpty) {
      _toast('请完整填写服务器地址、用户名和密码', danger: true);
      return;
    }

    setState(() => _busy = true);
    try {
      await ref
          .read(sessionProvider.notifier)
          .login(url, username, _pass.text, remember: _remember);
      // 登录成功后由根级 SessionGate 自动切换到主框架
    } on MediaException catch (e) {
      _toast(e.message, danger: true);
    } catch (_) {
      _toast('登录失败，请稍后重试', danger: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String text, {bool danger = false}) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text,
          style: TextStyle(
              color: danger ? Cf.danger : Cf.accent,
              fontSize: 12.5,
              fontWeight: FontWeight.w600)),
      behavior: SnackBarBehavior.floating,
      backgroundColor: Cf.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: danger ? Cf.danger : Cf.border),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(height: 12),
                  Center(child: CfLogo()),
                  SizedBox(height: 14),
                  Text('连接你的服务器',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                  SizedBox(height: 4),
                  Text('支持 Emby Server · 多服务器自由切换',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, color: Cf.text3)),
                  SizedBox(height: 22),

                  // 已存服务器（真实数据：来自安全存储，登录成功后自动收录）
                  if (_servers.isNotEmpty) ...[
                    for (var i = 0; i < _servers.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _ServerCard(
                          icon: '☁️',
                          name: _servers[i].name,
                          addr: '${_servers[i].username}@${_servers[i].url}',
                          selected: _selectedServer == i,
                          onTap: () {
                            setState(() => _selectedServer = i);
                            _addr.text = _servers[i].url;
                            _user.text = _servers[i].username;
                            if (_servers[i].password != null) {
                              _pass.text = _servers[i].password!;
                            }
                          },
                        ),
                      ),
                    const _OrDivider('或添加新服务器'),
                    SizedBox(height: 4),
                  ],

                  const _FieldLabel('服务器地址'),
                  TextField(
                    controller: _addr,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    style: TextStyle(fontSize: 12.5),
                    decoration:
                        const InputDecoration(hintText: 'http://emby.example.com:8096'),
                  ),
                  const _FieldLabel('用户名'),
                  TextField(
                    controller: _user,
                    autocorrect: false,
                    style: TextStyle(fontSize: 12.5),
                    decoration:
                        const InputDecoration(hintText: '用户名 / 邮箱'),
                  ),
                  const _FieldLabel('密码'),
                  TextField(
                    controller: _pass,
                    obscureText: _obscure,
                    style: TextStyle(fontSize: 12.5),
                    decoration: InputDecoration(
                      hintText: '••••••••',
                      suffixIcon: IconButton(
                        onPressed: () => setState(() => _obscure = !_obscure),
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 18,
                          color: Cf.text3,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      InkWell(
                        onTap: () => setState(() => _remember = !_remember),
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(children: [
                            _Checkbox(on: _remember),
                            SizedBox(width: 6),
                            Text('记住密码',
                                style: TextStyle(
                                    fontSize: 11, color: Cf.text2)),
                          ]),
                        ),
                      ),
                      GestureDetector(
                        onTap: () => _toast('快速连接：在服务器端生成 6 位配对码'),
                        child: Text('快速连接码 →',
                            style:
                                TextStyle(fontSize: 11, color: Cf.accent)),
                      ),
                    ],
                  ),
                  SizedBox(height: 16),
                  _PrimaryButton(
                    text: _busy ? '正在连接…' : '登  录',
                    busy: _busy,
                    onPressed: _login,
                  ),
                  SizedBox(height: 18),
                  // 版本号必须走 kAppVersionLabel（唯一来源 VERSION）。
                  // 这里曾硬编码 v0.1.0，而应用已是 0.2.0——登录页是用户看到的第一屏，
                  // 版本对不上最伤可信度（缺陷 7.17 的漏网处）。
                  Text('CineFlow $kAppVersionLabel · 登录即代表同意《用户协议》',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 9.5, color: Cf.text3)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({
    required this.icon,
    required this.name,
    required this.addr,
    required this.selected,
    required this.onTap,
  });

  final String icon;
  final String name;
  final String addr;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? const Color(0x1200D4FF) : Cf.surface2,
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(11),
            border:
                Border.all(color: selected ? Cf.accent : Cf.border),
          ),
          child: Row(children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                gradient:
                    LinearGradient(colors: [Cf.surface, Cf.border]),
                borderRadius: BorderRadius.circular(9),
              ),
              alignment: Alignment.center,
              child: Text(icon, style: TextStyle(fontSize: 17)),
            ),
            SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      style: TextStyle(
                          fontSize: 12.5, fontWeight: FontWeight.w700)),
                  SizedBox(height: 2),
                  Text(addr,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 10, color: Cf.text3)),
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _OrDivider extends StatelessWidget {
  const _OrDivider(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(children: [
        const Expanded(child: Divider(color: Cf.border)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(text,
              style: TextStyle(fontSize: 10, color: Cf.text3)),
        ),
        const Expanded(child: Divider(color: Cf.border)),
      ]),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 5),
      child: Text(text,
          style: TextStyle(
              fontSize: 10.5,
              color: Cf.text3,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5)),
    );
  }
}

class _Checkbox extends StatelessWidget {
  const _Checkbox({required this.on});
  final bool on;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 15,
      height: 15,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        color: on ? const Color(0x2600D4FF) : Cf.surface2,
        border: Border.all(color: on ? Cf.accent : Cf.border, width: 1.5),
      ),
      alignment: Alignment.center,
      child:
          on ? Icon(Icons.check, size: 10, color: Cf.accent) : null,
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton(
      {required this.text, required this.onPressed, this.busy = false});
  final String text;
  final VoidCallback onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: Cf.primaryGradient,
        borderRadius: BorderRadius.circular(9),
        boxShadow: [
          BoxShadow(
              color: Cf.accent.withValues(alpha: .3),
              blurRadius: 16,
              offset: const Offset(0, 4)),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: busy ? null : onPressed,
          borderRadius: BorderRadius.circular(9),
          child: Container(
            height: 46,
            alignment: Alignment.center,
            child: busy
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.2, color: Cf.ink))
                : Text(text,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: Cf.ink,
                        letterSpacing: 4)),
          ),
        ),
      ),
    );
  }
}
