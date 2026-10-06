/// 地址智能识别的单元测试。
///
/// ## 为什么必须有这个文件
///
/// 用户最常见、也最容易出错的动作是**从浏览器地址栏整段复制粘贴**：
///
///     http://emby.example.com:8096/web/index.html#!/item?id=123&serverId=abc
///
/// 直接拿这串去登录必然失败（要的是 `scheme://host:port`）。
/// 这段解析在真机上"手工试一次"成本很高（要开浏览器、复制、粘贴、看结果），
/// 而它本质是**纯字符串变换** —— 用真值表钉住最划算。
///
/// 与 `PlayerPage.showEpisodeButton` 等同一约定：把逻辑提为 `public static`，
/// 不依赖 UI 私有状态即可断言。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/pages/login_page.dart';

void main() {
  group('地址识别 normalizeServerUrl', () {
    test('★ 粘贴完整 Emby web URL → 截取 scheme://host:port', () {
      expect(
        LoginPage.normalizeServerUrl(
            'http://emby.example.com:8096/web/index.html#!/item?id=123&serverId=abc'),
        'http://emby.example.com:8096',
        reason: '这是最主要的使用场景：从浏览器地址栏整段粘贴',
      );
    });

    test('粘贴带查询串的 URL → 丢掉 ? 之后', () {
      expect(
        LoginPage.normalizeServerUrl('https://emby.example.com:8920/web/?x=1'),
        'https://emby.example.com:8920',
      );
    });

    test('无协议 + 端口 → 自动补 http://', () {
      expect(
        LoginPage.normalizeServerUrl('emby.example.com:8096'),
        'http://emby.example.com:8096',
      );
    });

    test('无协议 + 无端口 → 自动补 http://', () {
      expect(
        LoginPage.normalizeServerUrl('emby.example.com'),
        'http://emby.example.com',
      );
    });

    test('https 的默认端口 443 → 去掉端口', () {
      expect(
        LoginPage.normalizeServerUrl('https://emby.example.com:443'),
        'https://emby.example.com',
      );
    });

    test('http 的默认端口 80 → 去掉端口', () {
      expect(
        LoginPage.normalizeServerUrl('http://emby.example.com:80'),
        'http://emby.example.com',
      );
    });

    test('含 :443 但无协议 → 判为 https', () {
      expect(
        LoginPage.normalizeServerUrl('emby.example.com:443'),
        'https://emby.example.com',
      );
    });

    test('wss:// → 按 https 处理并去掉 wss 前缀', () {
      expect(
        LoginPage.normalizeServerUrl('wss://emby.example.com:8920'),
        'https://emby.example.com:8920',
      );
    });

    test('首尾引号 → 去掉（复制时常带）', () {
      expect(
        LoginPage.normalizeServerUrl('"http://emby.example.com:8096"'),
        'http://emby.example.com:8096',
      );
    });

    test('首尾空白 → 去掉', () {
      expect(
        LoginPage.normalizeServerUrl('   http://emby.example.com:8096  '),
        'http://emby.example.com:8096',
      );
    });

    test('已是干净地址 → 原样返回（幂等）', () {
      const clean = 'http://emby.example.com:8096';
      expect(LoginPage.normalizeServerUrl(clean), clean);
      // 幂等性：再跑一次不变（避免"每次失焦都改一点"）
      expect(
        LoginPage.normalizeServerUrl(LoginPage.normalizeServerUrl(clean)),
        clean,
      );
    });

    test('IP 地址形态正常处理（不误判为域名）', () {
      expect(
        LoginPage.normalizeServerUrl('203.0.113.7:8096'),
        'http://203.0.113.7:8096',
      );
    });

    test('空串 → 原样返回空（不抛异常）', () {
      expect(LoginPage.normalizeServerUrl(''), '');
    });

    test('只有 http:// 前缀（用户刚清空）→ 不抛异常', () {
      // 登录页输入框初始值就是 'http://'
      expect(() => LoginPage.normalizeServerUrl('http://'), returnsNormally);
    });

    test('带路径但无端口 → 只留 host', () {
      expect(
        LoginPage.normalizeServerUrl('http://emby.example.com/web/index.html'),
        'http://emby.example.com',
      );
    });
  });
}
