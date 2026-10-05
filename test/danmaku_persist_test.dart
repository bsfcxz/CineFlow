import 'package:cineflow/danmaku/danmaku_config.dart';
import 'package:cineflow/data/session_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// 内存版 KV 存储（测试用）。
///
/// 只实现 `SecureKv` 的三个方法——这正是"抽出最小接口"的收益：
/// 若直接伪造 `FlutterSecureStorage`（方法很多），这个假实现会长十倍，
/// 且每次上游加方法都要跟着改。
class _MemoryKv implements SecureKv {
  final _map = <String, String>{};

  @override
  Future<String?> read({required String key}) async => _map[key];

  @override
  Future<void> write({required String key, required String value}) async =>
      _map[key] = value;

  @override
  Future<void> delete({required String key}) async => _map.remove(key);

  /// 绕过往写逻辑直接塞原始字符串（模拟"存储里是坏数据"）
  void seedRaw(String key, String raw) => _map[key] = raw;
}

/// 弹幕配置的**存取闭环**测试。
///
/// ## 这个测试针对的是真实 bug 规律（来自 Cmby 的版本历史调研）
///
/// Cmby（同类 Emby 客户端）的弹幕 bug **高度集中在
/// 「默认值 / 存储层 / 过滤状态 三者不同步」**——它跨 v0.1.0、v0.1.1
/// 连续多个版本都在修：
///   - 默认值被存储层旧值覆盖
///   - 默认值与存储层不一致（显示一个值、实际用另一个）
///   - 关闭屏蔽后状态不恢复
///
/// 这类 bug 的特征是**只在"改过设置又重启"时才显形**，
/// 单看代码或只测一次行为都发现不了。故这里逐个字段做
/// **写出→读回**的闭环断言：任何字段漏存/漏读/类型不符都会立即变红。
///
/// 用内存 `SecureKv` 而不是假的 `SessionStore`：读写的序列化逻辑
/// （JSON ↔ 对象）本身就是要测的东西，用假 SessionStore 会把这段绕过去。
void main() {
  group('弹幕配置存取闭环（每个字段独立往返）', () {
    late _MemoryKv kv;
    late SessionStore store;

    setUp(() {
      kv = _MemoryKv();
      store = SessionStore(storage: kv);
    });

    /// 写一个"每个字段都非默认"的配置，用于暴露漏存字段
    DanmakuConfig nonDefault() => const DanmakuConfig(
          kind: DanmakuProviderKind.selfHosted,
          baseUrl: 'http://192.0.2.10:9321/mytoken',
          appId: 'test-app-id',
          appSecret: 'test-secret',
          enabled: false,
          opacity: 0.75,
          fontScale: 1.4,
          showArea: 0.6,
          blockedWords: ['广告', '剧透', '刷屏'],
          useAsync: false,
        );

    test('★ 全部字段写出后能原样读回（防漏存）', () async {
      final want = nonDefault();
      await store.saveDanmakuConfig(want);
      final got = await store.loadDanmakuConfig();

      expect(got.kind, want.kind);
      expect(got.baseUrl, want.baseUrl);
      expect(got.appId, want.appId);
      expect(got.appSecret, want.appSecret);
      expect(got.enabled, want.enabled);
      expect(got.opacity, closeTo(want.opacity, 0.001));
      expect(got.fontScale, closeTo(want.fontScale, 0.001));
      expect(got.showArea, closeTo(want.showArea, 0.001));
      expect(got.blockedWords, want.blockedWords);
      expect(got.useAsync, want.useAsync);
    });

    test('★ 未设置过时返回默认值（不能是 null 或半初始化状态）', () async {
      final got = await store.loadDanmakuConfig();
      expect(got.kind, DanmakuProviderKind.off);
      expect(got.baseUrl, '');
      expect(got.enabled, isTrue);
      expect(got.opacity, 1.0);
      expect(got.fontScale, 1.0);
      expect(got.showArea, 1.0);
      expect(got.blockedWords, isEmpty);
      expect(got.useAsync, isTrue);
    });

    test('★ 二次写入完整覆盖（防"旧值残留"——Cmby 修过这个）', () async {
      await store.saveDanmakuConfig(nonDefault());
      await store.saveDanmakuConfig(const DanmakuConfig());
      final got = await store.loadDanmakuConfig();

      expect(got.kind, DanmakuProviderKind.off,
          reason: 'kind 必须回到 off，不能残留上次的 selfHosted');
      expect(got.baseUrl, '');
      expect(got.opacity, 1.0);
      expect(got.blockedWords, isEmpty,
          reason: '屏蔽词清空后不能残留（Cmby 的"关闭屏蔽后不恢复"就是这类）');
    });

    test('★ 屏蔽词清空能被持久化（防"关不掉的屏蔽"）', () async {
      await store.saveDanmakuConfig(
          const DanmakuConfig(blockedWords: ['广告']));
      expect((await store.loadDanmakuConfig()).blockedWords, ['广告']);

      await store.saveDanmakuConfig(const DanmakuConfig(blockedWords: []));
      expect((await store.loadDanmakuConfig()).blockedWords, isEmpty,
          reason: '若实现用 `if (list.isNotEmpty)` 判断，清空会失效');
    });

    test('★ enabled=false 必须被持久化（防"关了又自动开"）', () async {
      await store.saveDanmakuConfig(const DanmakuConfig(enabled: false));
      expect((await store.loadDanmakuConfig()).enabled, isFalse);
    });

    test('★ base 里的 token 路径段必须原样保留', () async {
      const url = 'http://192.0.2.5:9321/mySecretToken';
      await store.saveDanmakuConfig(const DanmakuConfig(baseUrl: url));
      expect((await store.loadDanmakuConfig()).baseUrl, url,
          reason: 'token 丢了会导致 401/403，且现象是"没有弹幕"');
    });

    test('中文与特殊字符的屏蔽词往返无损', () async {
      const words = ['广告', '剧透🤐', 'spam', '刷屏!!'];
      await store.saveDanmakuConfig(const DanmakuConfig(blockedWords: words));
      expect((await store.loadDanmakuConfig()).blockedWords, words);
    });

    test('AppSecret 含特殊字符时往返无损（签名会用到）', () async {
      const secret = r'a+b/c=d==efgh&ij?kl';
      await store.saveDanmakuConfig(const DanmakuConfig(appSecret: secret));
      expect((await store.loadDanmakuConfig()).appSecret, secret,
          reason: '密钥被 JSON 转义破坏会导致签名不符 → 403');
    });

    test('三种源类型都能往返（枚举序列化不能丢）', () async {
      for (final k in DanmakuProviderKind.values) {
        await store.saveDanmakuConfig(DanmakuConfig(kind: k));
        expect((await store.loadDanmakuConfig()).kind, k,
            reason: '${k.name} 序列化/反序列化不对称');
      }
    });
  });

  group('损坏数据的容错（不能让应用起不来）', () {
    late _MemoryKv kv;
    late SessionStore store;

    setUp(() {
      kv = _MemoryKv();
      store = SessionStore(storage: kv);
    });

    test('存储里是非法 JSON 时回退默认值', () async {
      kv.seedRaw('cf_danmaku_config', '{not json');
      final got = await store.loadDanmakuConfig();
      expect(got.kind, DanmakuProviderKind.off,
          reason: '配置损坏应回退默认，而不是抛异常让启动失败');
    });

    test('JSON 是数组而非对象时回退默认值', () async {
      kv.seedRaw('cf_danmaku_config', '[1,2,3]');
      expect((await store.loadDanmakuConfig()).kind, DanmakuProviderKind.off);
    });

    test('未知的 kind 字面量回退为 off（防升级/降级崩溃）', () async {
      kv.seedRaw('cf_danmaku_config',
          '{"kind":"someFutureProvider","opacity":0.5}');
      final got = await store.loadDanmakuConfig();
      expect(got.kind, DanmakuProviderKind.off);
      expect(got.opacity, 0.5, reason: '其它合法字段仍应被读出');
    });

    test('字段类型不符时用默认值（如 opacity 是字符串）', () async {
      kv.seedRaw('cf_danmaku_config', '{"opacity":"high","fontScale":1.5}');
      final got = await store.loadDanmakuConfig();
      expect(got.opacity, 1.0, reason: '类型不符不该抛异常');
      expect(got.fontScale, 1.5, reason: '正常字段仍读出');
    });

    test('blockedWords 里混入非字符串时被过滤（不留脏数据）', () async {
      kv.seedRaw('cf_danmaku_config',
          '{"blockedWords":["广告",123,null,"剧透"]}');
      expect((await store.loadDanmakuConfig()).blockedWords, ['广告', '剧透']);
    });
  });
}
