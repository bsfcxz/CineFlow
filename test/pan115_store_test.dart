import 'package:cineflow/data/session_store.dart';
import 'package:cineflow/pan115/pan115_client.dart';
import 'package:cineflow/pan115/pan115_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// 115 凭据**存取闭环**测试。
///
/// ## 为什么必须有（这是第三个同类缺陷的回归线）
///
/// 用户实测的完整链路故障最终定位到**三处独立的"静默取不到值"**：
///
/// 1. `invokeAsync` 双重 JSON 编码 → Go 侧解析失败（已修）
/// 2. Go 发 `UID` 大写、Dart 读 `uid` 小写 → 凭据全空（已修）
/// 3. 本文件的主题：**存取闭环**——写进去的要能原样读出来
///
/// 前两处的表现都是"没有任何报错，只是状态永远不对"。
/// 这类缺陷静态分析发现不了，只有"写出→读回"的闭环断言能守住。
///
/// 与 `danmaku_persist_test.dart` 同一思路：它当年也抓出过一个真实缺陷。
void main() {
  group('115 凭据存取闭环', () {
    late _MemoryKv kv;
    late Pan115Store store;

    setUp(() {
      kv = _MemoryKv();
      store = Pan115Store(SessionStore(storage: kv));
    });

    test('★ 写入后能原样读回全部四个字段', () async {
      const cred = Pan115Credential(
        uid: 'u1',
        cid: 'c1',
        seid: 's1',
        kid: 'k1',
        userName: '测试账号',
      );
      await store.saveCredential(cred);
      final got = await store.loadCredential();

      expect(got, isNotNull, reason: '存进去的凭据必须能读出来（否则登录等于白扫）');
      expect(got!.uid, 'u1');
      expect(got.cid, 'c1');
      expect(got.seid, 's1');
      expect(got.kid, 'k1');
      expect(got.userName, '测试账号');
    });

    test('★ 未存过时返回 null（不是抛异常、也不是半初始化对象）', () async {
      expect(await store.loadCredential(), isNull);
    });

    test('clear() 之后必须读不到', () async {
      await store.saveCredential(
          const Pan115Credential(uid: 'u', cid: 'c', seid: 's'));
      expect(await store.loadCredential(), isNotNull);

      await store.clear();
      expect(await store.loadCredential(), isNull,
          reason: '退出登录后必须真的读不到（否则"退出"名不副实）');
    });

    test('覆盖写入：第二次的凭据必须完全替换第一次', () async {
      await store.saveCredential(
          const Pan115Credential(uid: 'old', cid: 'c', seid: 's', kid: 'k'));
      await store.saveCredential(const Pan115Credential(
          uid: 'new', cid: 'c2', seid: 's2')); // 不带 kid

      final got = await store.loadCredential();
      expect(got!.uid, 'new', reason: '不能残留旧 uid');
      expect(got.cid, 'c2');
      expect(got.kid, '', reason: '第二次没提供 kid 时应为空，不能残留旧值');
    });

    test('★ 缺 CID 的凭据写入后读回应为 null（无效凭据不入库）', () async {
      // 注意 uid/cid/seid 是 required——所以必须用 fromJson 构造"缺字段"的情况
      // （那正是真实缺陷的发生路径：从 JSON 读不到 → 空串）。
      final broken = Pan115Credential.fromJson(
          const {'uid': 'u', 'seid': 's'}); // 故意不含 cid
      expect(broken, isNull,
          reason: '缺 CID 的凭据在 115 侧会静默返回空文件列表，必须当无效处理');
    });

    test('损坏的存储值返回 null 而不是抛异常', () async {
      kv.seedRaw('cf_pref_pan115_cred', '{不是 JSON');
      expect(await store.loadCredential(), isNull);
    });

    test('存储里是数组而非对象时返回 null', () async {
      kv.seedRaw('cf_pref_pan115_cred', '[1,2,3]');
      expect(await store.loadCredential(), isNull);
    });

    test('★ 存储键名必须是 getPref/setPref 的约定形式', () async {
      // getPref 内部会加 `cf_pref_` 前缀。若哪天有人给 _key 也加上前缀，
      // 写入与读取就会落到两个不同的键上——表现为"存了但读不到"，
      // 而两边代码看起来都"没错"。这条断言把实际键名钉死。
      await store.saveCredential(
          const Pan115Credential(uid: 'u', cid: 'c', seid: 's'));
      expect(kv.raw.containsKey('cf_pref_pan115_cred'), isTrue,
          reason: '实际存储键应为 cf_pref_pan115_cred');
      expect(kv.raw.containsKey('cf_pref_cf_pref_pan115_cred'), isFalse,
          reason: '不能出现双重前缀');
    });

    test('特殊字符的凭据值往返无损', () async {
      const weird = r'a+b/c=d==efgh&ij?kl; m%n';
      await store.saveCredential(
          Pan115Credential(uid: weird, cid: weird, seid: weird, kid: weird));
      final got = await store.loadCredential();
      expect(got!.uid, weird);
      expect(got.seid, weird);
    });
  });

  group('Pan115Credential 有效性口径（与 Go 侧必须一致）', () {
    test('UID/CID/SEID 备齐即有效；KID 可空', () {
      expect(
          const Pan115Credential(uid: 'u', cid: 'c', seid: 's').isValid, isTrue,
          reason: 'KID 允许缺失（兼容老 cookie）');
      expect(
          const Pan115Credential(uid: 'u', cid: 'c', seid: 's', kid: 'k')
              .isValid,
          isTrue);
    });

    test('★ fromJson 的语义是"缺失即无效"——这是防御第一道关卡', () {
      // uid/cid/seid 是 required，故"字段缺失"只能从 JSON 路径发生
      // （而那正是真实缺陷的发生路径：读不到键 → 空串 → 无效）。
      // 本测试固化：任一必需字段缺失就返回 null，
      // 而不是返回一个"看起来有效但实际用不了"的对象。
      expect(Pan115Credential.fromJson(const {}), isNull);
      expect(Pan115Credential.fromJson(const {'uid': 'u'}), isNull);
      expect(Pan115Credential.fromJson(const {'uid': 'u', 'cid': 'c'}), isNull,
          reason: '缺 SEID 会 401');
      expect(Pan115Credential.fromJson(const {'uid': 'u', 'seid': 's'}), isNull,
          reason: '缺 CID 会静默返回空列表（比 401 更危险）');
      expect(
          Pan115Credential.fromJson(
              const {'uid': 'u', 'cid': 'c', 'seid': 's'}),
          isNotNull);
    });

    test('★ fromJson 兼容大小写两种键名（真实缺陷的回归线）', () {
      // Go 侧用大写（与 115 cookie 名一致），Dart 侧习惯小写。
      // 曾经的 bug：Go 发 UID、Dart 读 uid → 全取不到 →
      // 登录"成功"却存不进有效凭据，界面回到"尚未登录"。
      final upper = Pan115Credential.fromJson(
          const {'UID': 'u', 'CID': 'c', 'SEID': 's', 'KID': 'k'});
      expect(upper, isNotNull, reason: '大写键名必须能读到（Go 侧就用大写）');
      expect(upper!.uid, 'u');
      expect(upper.cid, 'c');
      expect(upper.seid, 's');
      expect(upper.kid, 'k');

      final lower = Pan115Credential.fromJson(
          const {'uid': 'u', 'cid': 'c', 'seid': 's'});
      expect(lower, isNotNull, reason: '小写也要兼容，防止将来任一侧改名');
      expect(lower!.uid, 'u');
    });

    test('toString 不得泄露任何凭据值', () {
      const cred = Pan115Credential(
          uid: 'SECRET_UID', cid: 'SECRET_CID', seid: 'SECRET_SEID');
      final s = cred.toString();
      expect(s.contains('SECRET'), isFalse,
          reason: 'toString 可能被顺手打进日志——绝不能含凭据值（安全红线）');
    });
  });
}

/// 内存 KV（仅实现 SecureKv 的三个方法——这正是把存储抽成最小接口的收益）。
class _MemoryKv implements SecureKv {
  final raw = <String, String>{};

  @override
  Future<String?> read({required String key}) async => raw[key];

  @override
  Future<void> write({required String key, required String value}) async =>
      raw[key] = value;

  @override
  Future<void> delete({required String key}) async => raw.remove(key);

  void seedRaw(String key, String value) => raw[key] = value;
}
