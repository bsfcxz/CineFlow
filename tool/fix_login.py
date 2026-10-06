# -*- coding: utf-8 -*-
"""登录页重构：CineFlow 品牌区 + 地址智能识别 + UI 微调"""
import io

p = 'lib/pages/login_page.dart'
s = io.open(p, encoding='utf-8').read()

# ---------- 1) 地址智能识别：_normalizeServerUrl ----------
old = """  Future<void> _login() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();

    var url = _addr.text.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    final username = _user.text.trim();"""
new = """  /// 地址智能识别：从任意粘贴内容中提取 `scheme://host:port`。
  ///
  /// 支持：
  ///   http://emby.example.com:8096/web/index.html#!/item?id=2852317&serverId=...
  ///   https://emby.example.com
  ///   emby.example.com:8096        （自动补 http://）
  ///   emby.example.com           （自动补 http://）
  ///   https://emby.example.com:443（去默认端口）
  String _normalizeServerUrl(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return url;

    // 去掉首尾引号/空白
    url = url.replaceAll(RegExp(r'^["\']+|["\']+$'), '');

    // 无协议 → 自动补 http://（端口 443 或显式 wss 提示则 https）
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      // 检查是否有 443 或 .onion 等 https 信号
      final https_likely = url.contains(':443') || url.startsWith('wss://');
      url = '${https_likely ? 'https' : 'http'}://${url.replaceFirst('wss://', '')}';
    }

    // 解析并提取 scheme://host:port（去掉路径/查询/锚点）
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;

    final scheme = uri.scheme.isEmpty ? 'http' : uri.scheme;
    final host = uri.host;
    final hasPort = uri.hasPort && uri.port != 0;

    // 省略默认端口
    if ((scheme == 'http' && uri.port == 80) ||
        (scheme == 'https' && uri.port == 443)) {
      return '$scheme://$host';
    }
    return hasPort ? '$scheme://$host:$port' : '$scheme://$host';
  }

  Future<void> _login() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();

    final url = _normalizeServerUrl(_addr.text);
    final username = _user.text.trim();"""
assert old in s, 'login url anchor'
s = s.replace(old, new)

# 旧 while loop 已不需要（normalize 处理了）
old2 = """    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    final username = _user.text.trim();"""
# 不存在了（上面替换掉了）——检查
if old2 in s:
    s = s.replace(old2, '')

# 尾部斜杠检查（_login 里可能残留）
s = s.replace("""    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
""", "")

# ---------- 2) UI：CineFlow 品牌区（Logo 下方加名字） ----------
old = """                  SizedBox(height: 12),
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
                  SizedBox(height: 22),"""
new = """                  SizedBox(height: 12),
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
                  SizedBox(height: 22),"""
assert old in s, 'brand anchor'
s = s.replace(old, new)

# ---------- 3) footer 版本行用 Cf 版本号 ----------
s = s.replace("CineFlow v0.3.1 · 登录即代表同意《用户协议》",
              "CineFlow v\${kAppVersion} · 登录即代表同意《用户协议》")
# 不能在 const Text 里用变量，改
s = s.replace("""                  Text('CineFlow v\${kAppVersion} · 登录即代表同意《用户协议》',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 9.5, color: Cf.text3)),""",
"""                  Text('CineFlow v\$kAppVersion · 登录即代表同意《用户协议》',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 9.5, color: Cf.text3)),""")
# 如果不是 const 就不改
if "'CineFlow v\$kAppVersion" not in s and "'CineFlow v" in s:
    # 查找原始行并替换
    import re
    s = re.sub(
        r"Text\('CineFlow v[^']* · 登录即代表同意《用户协议》',\s*textAlign: TextAlign\.center,\s*style: const TextStyle\(fontSize: 9\.5, color: Cf\.text3\)\)",
        "Text('CineFlow v\$kAppVersion · 登录即代表同意《用户协议》',\n                      textAlign: TextAlign.center,\n                      style: TextStyle(fontSize: 9.5, color: Cf.text3))",
        s)

io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('login ok')
