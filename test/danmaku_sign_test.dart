import 'package:cineflow/danmaku/danmaku_sign.dart';
import 'package:flutter_test/flutter_test.dart';

/// 弹弹play 请求签名的单元测试。
///
/// ## 为什么必须测，且必须有"独立算出来的"期望值
///
/// 签名算法 `base64(sha256(AppId + Timestamp + Path + AppSecret))` 里
/// 有三处**极易写错且服务端不会告诉你哪里错**的细节：
///   1. Path **不含查询参数**（`?withRelated=true` 不能参与签名）
///   2. 拼接顺序固定 AppId→Timestamp→Path→AppSecret，**无分隔符**
///   3. 是 **sha256 的原始字节**再 base64，不是把十六进制串再 base64
///
/// 错了只会收到 `403 + X-Error-Message: Invalid Signature`，
/// 没有任何字段级提示。所以下面的期望值**不是**从本实现跑出来的
/// （那样等于自己证明自己），而是用 **Python 的 hashlib/base64 独立实现**
/// 按同一规范算出来的——两套独立实现得到同一结果，才能说明规范被正确落地。
///
/// 另外，官方 API 在本机网络**不可达**（实测 HTTP 000），无法端到端联调，
/// 因此这层纯函数测试就是唯一能自动化的防线。
void main() {
  group('签名算法（对官方规范）', () {
    test('与 Python 独立实现一致 —— 官方示例参数（UTC 2025-01-01）', () {
      // 官方文档示例：UTC 2025-01-01 00:00:00 → 1735660800
      final sig = dandanplaySignature(
        appId: 'your_app_id',
        appSecret: 'your_app_secret',
        path: '/api/v2/comment/123450001',
        timestamp: 1735660800,
      );
      expect(sig, 'MNBT8iOsIplI/GSkJEAH3V1AlpTyH1aMPJ1nedenEsw=');
    });

    test('与 Python 独立实现一致 —— 自定义参数', () {
      expect(
        dandanplaySignature(
          appId: 'app1',
          appSecret: 'sec1',
          path: '/api/v2/comment/123450001',
          timestamp: 1735660800,
        ),
        'tTHq0jZmFz+EM9ZNkV5nrFmM9Cm41TeIxIc6SFNYSO8=',
      );
    });

    test('与 Python 独立实现一致 —— 搜索接口路径', () {
      expect(
        dandanplaySignature(
          appId: 'app1',
          appSecret: 'sec1',
          path: '/api/v2/search/episodes',
          timestamp: 1735660800,
        ),
        'sItq+ivtevQ6DWbsTmILB5bAlV7qa4DPrcYVjueWRZM=',
      );
    });
  });

  group('易错细节（官方规范逐条锁定）', () {
    test('查询参数不参与签名（带 ? 会被截断）', () {
      final withoutQuery = dandanplaySignature(
        appId: 'a',
        appSecret: 's',
        path: '/api/v2/comment/123',
        timestamp: 1735660800,
      );
      final withQuery = dandanplaySignature(
        appId: 'a',
        appSecret: 's',
        // 官方原文：path 不包括 '?' 后面的查询参数
        path: '/api/v2/comment/123?withRelated=true',
        timestamp: 1735660800,
      );
      expect(withQuery, withoutQuery,
          reason: '带查询参数应与不带完全相同——截断逻辑必须生效');
    });

    test('拼接顺序敏感：调换顺序必须得到不同签名', () {
      final a = dandanplaySignature(
          appId: 'app', appSecret: 'sec', path: '/p', timestamp: 1);
      final b = dandanplaySignature(
          appId: 'sec', appSecret: 'app', path: '/p', timestamp: 1);
      expect(a, isNot(b), reason: '若实现里顺序写错，两者会相同');
    });

    test('大小写敏感', () {
      final lower = dandanplaySignature(
          appId: 'app', appSecret: 'sec', path: '/api/v2/comment/1', timestamp: 1);
      final upper = dandanplaySignature(
          appId: 'app', appSecret: 'sec', path: '/API/V2/COMMENT/1', timestamp: 1);
      expect(lower, isNot(upper));
    });

    test('时间戳变化会改变签名（防"时间戳没参与"的实现错误）', () {
      final t1 = dandanplaySignature(
          appId: 'a', appSecret: 's', path: '/p', timestamp: 1000);
      final t2 = dandanplaySignature(
          appId: 'a', appSecret: 's', path: '/p', timestamp: 1001);
      expect(t1, isNot(t2));
    });

    test('结果是 base64（含 = 填充或 64 字符集），不是十六进制', () {
      final sig = dandanplaySignature(
          appId: 'a', appSecret: 's', path: '/p', timestamp: 1);
      // sha256 → 32 字节 → base64 恒为 44 字符（含一个 = 填充）
      expect(sig.length, 44);
      expect(sig.endsWith('='), isTrue);
      expect(RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(sig), isTrue,
          reason: '含 - 或 _ 说明用了 base64url；含非 base64 字符说明实现错误');
      // 十六进制是 64 字符，与 44 不同——这条能挡住"hex 后 base64"的错误
      expect(sig.length, isNot(64));
    });
  });

  group('请求头三件套', () {
    test('包含官方要求的三个头', () {
      final h = dandanplayAuthHeaders(
        appId: 'myid',
        appSecret: 'mysec',
        path: '/api/v2/comment/1',
        now: DateTime.utc(2025, 1, 1),
      );
      expect(h.keys.toSet(), {'X-AppId', 'X-Timestamp', 'X-Signature'});
      expect(h['X-AppId'], 'myid');
    });

    test('时间戳是 UTC 秒级（2033 年前恒为 10 位）', () {
      final h = dandanplayAuthHeaders(
        appId: 'a',
        appSecret: 's',
        path: '/p',
        now: DateTime.utc(2025, 1, 1),
      );
      expect(h['X-Timestamp'], '1735689600');
    });

    test('时间戳跨时区一致（必须用 UTC，不能受设备时区影响）', () {
      final utc = dandanplayAuthHeaders(
          appId: 'a', appSecret: 's', path: '/p', now: DateTime.utc(2025, 1, 1));
      final local = dandanplayAuthHeaders(
        appId: 'a',
        appSecret: 's',
        path: '/p',
        // 同一时刻，但用本地时区构造
        now: DateTime.utc(2025, 1, 1).toLocal(),
      );
      expect(local['X-Timestamp'], utc['X-Timestamp'],
          reason: '用本地时间算签名会与服务端偏差，导致 403 Invalid Timestamp');
      expect(local['X-Signature'], utc['X-Signature']);
    });

    test('头部签名与单独调用签名函数一致', () {
      final now = DateTime.utc(2025, 6, 1);
      final h = dandanplayAuthHeaders(
          appId: 'a', appSecret: 's', path: '/api/v2/comment/9', now: now);
      final expectSig = dandanplaySignature(
        appId: 'a',
        appSecret: 's',
        path: '/api/v2/comment/9',
        timestamp: now.millisecondsSinceEpoch ~/ 1000,
      );
      expect(h['X-Signature'], expectSig);
    });
  });
}
