import 'package:cineflow/danmaku/danmaku_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// 弹幕源配置的单元测试。
///
/// ## 为什么地址归一化值得单独测
///
/// 用户手填服务地址几乎一定会出错：漏协议头、多尾斜杠、
/// 把 `/api/v2/comment/...` 整段粘进来。这些错误的表现全部是
/// **"弹幕不出来"**——不报错、不提示，用户只会以为"这功能坏了"。
///
/// 归一化把可自动纠正的纠正掉，纠正不了的给中文原因，
/// 这样"配错了"和"服务没数据"就能区分开。
void main() {
  group('地址归一化', () {
    test('已规范的地址不变', () {
      final (base, note) = DanmakuUrl.normalizeBase('http://192.0.2.10:9321');
      expect(base, 'http://192.0.2.10:9321');
      expect(note, isNull);
    });

    test('https 保持不变', () {
      expect(
        DanmakuUrl.normalizeBase('https://danmu.example.com').$1,
        'https://danmu.example.com',
      );
    });

    test('缺协议头时补 http 并给出提示', () {
      final (base, note) = DanmakuUrl.normalizeBase('192.0.2.10:9321');
      expect(base, 'http://192.0.2.10:9321');
      expect(note, contains('http://'), reason: '要告知用户做了改动，避免困惑');
    });

    test('去掉尾部斜杠（避免拼出 //api/v2）', () {
      expect(DanmakuUrl.normalizeBase('http://a.com:9321/').$1,
          'http://a.com:9321');
      expect(DanmakuUrl.normalizeBase('http://a.com:9321///').$1,
          'http://a.com:9321');
    });

    test('★ 剥掉误粘贴的 /api/v2 路径并提示', () {
      final (base, note) = DanmakuUrl.normalizeBase(
          'http://192.0.2.10:9321/api/v2/comment/123');
      expect(base, 'http://192.0.2.10:9321',
          reason: '客户端会自己拼 /api/v2，重复会导致 404');
      expect(note, contains('接口路径'));
    });

    test('保留 token 段（自建服务的 token 就在路径里）', () {
      final (base, _) =
          DanmakuUrl.normalizeBase('http://192.0.2.10:9321/mytoken');
      expect(base, 'http://192.0.2.10:9321/mytoken',
          reason: 'token 是 base 的一部分，不能剥掉');
    });

    test('token 段 + 误粘贴的接口路径 → 只剥路径', () {
      expect(
        DanmakuUrl.normalizeBase('http://a:9321/tok/api/v2/comment/1').$1,
        'http://a:9321/tok',
      );
    });

    test('/api/v1 前缀（御坂的服务形态）也被剥掉', () {
      expect(
        DanmakuUrl.normalizeBase('http://a:9321/tok/api/v1/api/v2/x').$1,
        'http://a:9321/tok',
      );
    });

    test('空输入返回空', () {
      expect(DanmakuUrl.normalizeBase('').$1, '');
      expect(DanmakuUrl.normalizeBase('   ').$1, '');
    });

    test('大小写不敏感地识别路径标记', () {
      expect(DanmakuUrl.normalizeBase('http://a:9321/API/V2/x').$1,
          'http://a:9321');
    });
  });

  group('地址校验', () {
    test('合法 http 通过', () {
      expect(DanmakuUrl.validate('http://192.0.2.10:9321'), isNull);
    });

    test('合法 https 通过', () {
      expect(DanmakuUrl.validate('https://d.example.com/87654321'), isNull);
    });

    test('空地址提示填写', () {
      expect(DanmakuUrl.validate(''), contains('填写'));
    });

    test('缺主机名被拒', () {
      expect(DanmakuUrl.validate('http://'), isNotNull);
    });

    test('非 http(s) 协议被拒', () {
      expect(DanmakuUrl.validate('ftp://a.com'), contains('http'));
    });

    test('乱字符串被拒', () {
      expect(DanmakuUrl.validate('这不是地址'), isNotNull);
    });
  });

  group('可用性判定（区分"没配"与"配了但关了"）', () {
    test('默认（off）不可用', () {
      expect(const DanmakuConfig().isUsable, isFalse);
    });

    test('官方源需 AppId + AppSecret 都填', () {
      const base = DanmakuConfig(kind: DanmakuProviderKind.official);
      expect(base.isUsable, isFalse);
      expect(base.copyWith(appId: 'a').isUsable, isFalse,
          reason: '只有 AppId 不够');
      expect(base.copyWith(appId: 'a', appSecret: 's').isUsable, isTrue);
    });

    test('自建源只需 baseUrl', () {
      const base = DanmakuConfig(kind: DanmakuProviderKind.selfHosted);
      expect(base.isUsable, isFalse);
      expect(base.copyWith(baseUrl: 'http://a:9321').isUsable, isTrue,
          reason: '自建服务用 URL token，不需要 AppSecret');
    });

    test('enabled=false 时配置再全也不可用', () {
      const c = DanmakuConfig(
        kind: DanmakuProviderKind.selfHosted,
        baseUrl: 'http://a:9321',
        enabled: false,
      );
      expect(c.isUsable, isFalse,
          reason: '这是"用户临时关掉"，与"没配置源"是两回事');
    });

    test('kind=off 即使用户填了地址也不可用', () {
      const c = DanmakuConfig(
        kind: DanmakuProviderKind.off,
        baseUrl: 'http://a:9321',
      );
      expect(c.isUsable, isFalse);
    });
  });

  group('base 规范化', () {
    test('去掉尾部斜杠', () {
      expect(
        const DanmakuConfig(baseUrl: 'http://a:9321/').normalizedBase,
        'http://a:9321',
      );
    });

    test('多个尾斜杠全部去掉', () {
      expect(
        const DanmakuConfig(baseUrl: 'http://a:9321///').normalizedBase,
        'http://a:9321',
      );
    });

    test('去空格', () {
      expect(
        const DanmakuConfig(baseUrl: '  http://a:9321  ').normalizedBase,
        'http://a:9321',
      );
    });
  });

  group('copyWith 保留未指定字段', () {
    test('只改 opacity 时其它字段不变', () {
      const c = DanmakuConfig(
        kind: DanmakuProviderKind.selfHosted,
        baseUrl: 'http://a:9321',
        appId: 'id',
        blockedWords: ['广告'],
      );
      final d = c.copyWith(opacity: 0.5);
      expect(d.kind, c.kind);
      expect(d.baseUrl, c.baseUrl);
      expect(d.appId, c.appId);
      expect(d.blockedWords, c.blockedWords);
      expect(d.opacity, 0.5);
    });
  });
}
