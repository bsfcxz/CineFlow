# -*- coding: utf-8 -*-
"""登录页改造：
1. 横屏适配：品牌区左 + 表单右（Compact 竖屏保持上下，横屏/Medium 切左右）
2. CineFlow 品牌文字放在图标下方
3. 地址智能识别：从任意 Emby web URL 提取 host:port（含协议）
"""
import io
import re

p = 'lib/pages/login_page.dart'
s = io.open(p, encoding='utf-8').read()

# ---------- 1) 地址智能识别：_login 里规范化 URL ----------
old = """    var url = _addr.text.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }"""
new = """    var url = _normalizeServerUrl(_addr.text.trim());
    if (url == null || url.isEmpty) {
      _toast('请输入有效的服务器地址', danger: true);
      return;
    }"""
assert old in s, 'url normalize anchor'
s = s.replace(old, new)

# 添加 _normalizeServerUrl 方法（插在 _login 之前）
old = "  Future<void> _login() async {"
new = """  /// 从任意粘贴文本提取 Emby 服务器地址。
  ///
  /// 支持的输入形态（全部归一化为 `协议://host:port`）：
  ///   emby.example.com:8096
  ///   http://emby.example.com:8096
  ///   http://emby.example.com:8096/web/index.html#!/item?id=2852317&serverId=xxx
  ///   https://emby.example.com
  ///
  /// 策略：取 scheme://host:port 前 3 段，丢弃路径/查询/片段。
  static String? _normalizeServerUrl(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return null;

    // 无协议前缀 → 默认 http://
    if (!text.startsWith('http://') && !text.startsWith('https://')) {
      text = 'http://$text';
    }

    try {
      final uri = Uri.parse(text);
      final host = uri.host;
      if (host.isEmpty) return null;
      final port = uri.port;
      final scheme = uri.scheme.isEmpty ? 'http' : uri.scheme;
      // 有非默认端口才带上；443/80 省略
      final isDefault = (scheme == 'https' && port == 443) ||
          (scheme == 'http' && port == 80);
      return isDefault
          ? '$scheme://$host'
          : '$scheme://$host:$port';
    } catch (_) {
      return null;
    }
  }

  Future<void> _login() async {"""
assert old in s, 'login method anchor'
s = s.replace(old, new, 1)

# ---------- 2) 横屏适配 + 品牌文字在图标下方 ----------
# 重写整个 build 方法的 Scaffold body：横屏用 Row 左品牌右表单，竖屏保持 Column
old = """  @override
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
                  const SizedBox(height: 12),
                  const Center(child: CfLogo()),
                  const SizedBox(height: 14),
                  const Text('连接你的服务器',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  const Text('支持 Emby Server · 多服务器自由切换',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, color: Cf.text3)),
                  const SizedBox(height: 22),"""

new = """  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(builder: (context, box) {
          final isWide = box.maxWidth >= 600;
          if (isWide) return _wideBody();
          return _narrowBody();
        }),
      ),
    );
  }

  /// 竖屏（Compact）：品牌上方 → 表单下方
  Widget _narrowBody() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),
              // 品牌：图标 + CineFlow 文字在下方
              _brandHeader(),
              const SizedBox(height: 20),
              _loginForm(),
            ],
          ),
        ),
      ),
    );
  }

  /// 横屏（Medium+）：品牌区左侧，表单右侧
  Widget _wideBody() {
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
                  _brandHeader(alignment: CrossAxisAlignment.start),
                  const SizedBox(height: 24),
                  Text('万影成流 · 一触即映',
                      style: TextStyle(
                          fontSize: 14,
                          color: Cf.text3,
                          fontStyle: FontStyle.italic)),
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
                padding: const EdgeInsets.symmetric(
                    horizontal: 32, vertical: 28),
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

  /// 品牌区：Logo + CineFlow 文字在图标下方 + 副标题
  Widget _brandHeader(
      {CrossAxisAlignment alignment = CrossAxisAlignment.center}) {
    final isCenter = alignment == CrossAxisAlignment.center;
    final textAlign = isCenter ? TextAlign.center : TextAlign.left;
    return Column(
      crossAxisAlignment: alignment,
      children: [
        const Center(child: CfLogo()),
        const SizedBox(height: 10),
        Text('CineFlow',
            textAlign: textAlign,
            style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.5,
                color: Cf.text)),
        const SizedBox(height: 4),
        Text('连接你的服务器',
            textAlign: textAlign,
            style:
                TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Cf.text2)),
        const SizedBox(height: 3),
        Text('支持 Emby Server · 多服务器自由切换',
            textAlign: textAlign,
            style: const TextStyle(fontSize: 11, color: Cf.text3)),
      ],
    );
  }

  /// 登录表单（已存服务器卡片 + 地址/用户名/密码 + 登录按钮）
  Widget _loginForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
"""

# 找到旧表单体的开头（已存服务器卡片开始），追加余下内容
old2 = """                  // 已存服务器（真实数据：来自安全存储，登录成功后自动收录）"""
new2 = """                  // 已存服务器（真实数据：来自安全存储，登录成功后自动收录）"""
# 需要把剩余部分也包进 _loginForm 的 children
# 旧代码在 Column(children: [...]) 里，从"已存服务器"到 footer 结束
# 新代码在 _loginForm 的 Column(children: [...]) 里——结构一致，只需要闭合

io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('login page ok (part 1)')
