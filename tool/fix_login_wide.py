# -*- coding: utf-8 -*-
"""登录页横屏适配：LayoutBuilder 切换窄/宽布局。
窄屏：现有竖向布局。宽屏(≥600)：品牌区左侧 + 表单右侧（对齐 BoxPlayer/MovieClaw 登录设计）。
"""
import io

p = 'lib/pages/login_page.dart'
s = io.open(p, encoding='utf-8').read()

old = """  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: keys.login.page,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: ["""

new = """  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: keys.login.page,
      body: SafeArea(
        child: LayoutBuilder(builder: (context, box) {
          final isWide = box.maxWidth >= 600;
          if (isWide) return _wideLayout();
          return _narrowLayout();
        }),
      ),
    );
  }

  /// 窄屏（Compact 竖屏）：品牌上方 → 表单下方
  Widget _narrowLayout() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: _loginForm(),
        ),
      ),
    );
  }

  /// 宽屏（Medium+ 横屏/分屏）：品牌区左侧，表单右侧
  Widget _wideLayout() {
    return Center(
      child: Row(
        children: [
          // 左侧品牌区
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Center(child: CfLogo()),
                  const SizedBox(height: 10),
                  const Center(
                    child: Text('CineFlow',
                        style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 2,
                            color: Cf.text)),
                  ),
                  const SizedBox(height: 4),
                  const Center(
                    child: Text('万影成流 · 一触即映',
                        style: TextStyle(
                            fontSize: 11,
                            letterSpacing: 3,
                            color: Cf.text3)),
                  ),
                  const SizedBox(height: 20),
                  Text('连接你的服务器',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text('支持 Emby Server · 多服务器自由切换',
                      style: TextStyle(fontSize: 11, color: Cf.text3)),
                ],
              ),
            ),
          ),
          // 分割线
          Container(width: 1, color: Cf.border),
          // 右侧表单
          Expanded(
            flex: 3,
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 380),
                  child: _loginForm(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 登录表单（品牌区 + 已存服务器 + 地址/用户名/密码 + 按钮 + footer）
  Widget _loginForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: 12),
        Center(child: CfLogo()),
        SizedBox(height: 10),
        // 品牌名：Logo 下方
        const Center(
          child: Text('CineFlow',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2,
                  color: Cf.text)),
        ),
        const SizedBox(height: 4),
        const Center(
          child: Text('万影成流 · 一触即映',
              style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 3,
                  color: Cf.text3)),
        ),
        SizedBox(height: 18),
        Text('连接你的服务器',
            textAlign: TextAlign.center,
            style:
                TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
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
          key: keys.login.serverField,
          controller: _addr,
          keyboardType: TextInputType.url,
          autocorrect: false,
          style: TextStyle(fontSize: 13),
          decoration:
              const InputDecoration(hintText: 'http://emby.example.com:8096'),
        ),
        const _FieldLabel('用户名'),
        TextField(
          key: keys.login.usernameField,
          controller: _user,
          autocorrect: false,
          style: TextStyle(fontSize: 13),
          decoration:
              const InputDecoration(hintText: '用户名 / 邮箱'),
        ),
        const _FieldLabel('密码'),
        TextField(
          key: keys.login.passwordField,
          controller: _pass,
          obscureText: _obscure,
          style: TextStyle(fontSize: 13),
          decoration: InputDecoration(
            hintText: '••••••••',
            suffixIcon: IconButton(
              key: keys.login.passwordToggle,
              onPressed: () => setState(() => _obscure = !_obscure),
              icon: Icon(
                _obscure
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                size: 20,
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
              key: keys.login.rememberRow,
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
              key: keys.login.quickConnectLink,
              onTap: () => _toast('快速连接：在服务器端生成 6 位配对码'),
              child: Text('快速连接码 →',
                  style:
                      TextStyle(fontSize: 11, color: Cf.accent)),
            ),
          ],
        ),
        SizedBox(height: 16),
        _PrimaryButton(
          key: keys.login.submitButton,
          text: _busy ? '正在连接…' : '登  录',
          busy: _busy,
          onPressed: _login,
        ),
        SizedBox(height: 18),
        Text('CineFlow $kAppVersionLabel · 登录即代表同意《用户协议》',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 10, color: Cf.text3)),
      ],
    );
  }
}

// ---- 以下是与旧 build 方法分离的私有组件（原样保留） ----

class _LoginPageBody extends StatelessWidget {
  const _LoginPageBody();
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

abstract class _LoginPageDeprecated {
"""
assert old in s, 'build anchor'
s = s.replace(old, new, 1)

# 删除旧 build 方法的 body 内容尾部（原 Column 尾部到类结束前）
# 由于新代码已完整包含 _loginForm，旧尾部变成孤儿代码——找到旧的 "  }\n}" 结尾
# 简单方法：找到新代码结尾 "abstract class _LoginPageDeprecated {" 后面删除到下一个有意义的 class
idx = s.find('abstract class _LoginPageDeprecated {')
if idx >= 0:
    # 找到 _LoginPageDeprecated 类体结尾（到下一个 class 或文件尾）
    # 直接删除从 _LoginPageDeprecated 到 _ServerCard class 前
    server_idx = s.find('class _ServerCard')
    if server_idx > idx:
        s = s[:idx] + s[server_idx:]
    else:
        # 或者到文件末尾
        s = s[:idx]

io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('login wide layout ok')
