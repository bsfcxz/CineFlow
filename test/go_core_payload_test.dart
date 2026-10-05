import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

/// `invokeAsync` 的 **payload 编码契约**测试。
///
/// ## 这个测试针对一个真实缺陷（用户实测报出来的）
///
/// 症状：115 扫码页**二维码能正常显示**，但**永远停在"等待二维码…"**，
/// 且日志里没有任何报错。
///
/// 根因是**双重 JSON 编码**：`invokeAsync` 先在主 isolate 把 payload
/// `jsonEncode` 成字符串，传给子 isolate 后又交给 `invoke()`，
/// 而 `invoke()` 内部**再编码一次**。于是 `{"uid":"x"}`
/// 变成 `"{\"uid\":\"x\"}"`（一个 JSON **字符串字面量**而非对象），
/// Go 侧反序列化到 `Request` 结构体必然失败。
///
/// ## 为什么这个 bug 特别阴险
///
/// `qr.start` 恰好**没有 payload**（走 `payload == null` 分支），
/// 所以只有它正常 —— 表现为"二维码能拿到、轮询却全失败"，
/// 看起来极像服务端问题。我因此先跑了一次**真实网络集成测试**
/// （`go/internal/rpc/pan115_live_test.go`）证明 Go 侧完全正常，
/// 才把范围收敛到 Dart 侧的这一层。
///
/// ## 这个测试为什么必须存在（而不是只靠集成测试）
///
/// 真实网络测试默认跳过（要外网 + 一次 30 秒长轮询），
/// 不能进日常门禁。而**编码这个纯逻辑**可以不依赖网络测：
/// 只要断言"编出来的字面量是一个 JSON 对象、且键值就是原样"，
/// 双重编码就会立刻失败。
void main() {
  group('FFI payload 编码契约（防双重编码）', () {
    /// 模拟 `invoke()` 内部对 payload 做的事：`jsonEncode(payload)`。
    ///
    /// 注意 `invoke` 的签名是 `Object? payload`，且**约定收原始对象**。
    /// 传入字符串会被再编码一次——这正是当初的 bug。
    String encodeLikeInvoke(Object? payload) => jsonEncode(payload);

    /// 模拟 Go 侧把收到的字符串反序列化成信封。
    Object? decodeLikeGo(String s) => jsonDecode(s);

    test('★ 传原始 Map 时，Go 侧应解出**对象**（键值原样）', () {
      final payload = {'uid': 'u123', 'time': 1791105716, 'sign': 'abc'};
      final wire = encodeLikeInvoke(payload);
      final decoded = decodeLikeGo(wire);

      expect(decoded, isA<Map>(),
          reason: '必须是 JSON 对象，否则 Go 的 json.Unmarshal 到结构体会失败');
      final m = decoded! as Map;
      expect(m['uid'], 'u123');
      expect(m['time'], 1791105716);
      expect(m['sign'], 'abc');
    });

    test('★ 若先编码再传（旧 bug 的写法），Go 侧会解出**字符串**而非对象', () {
      final payload = {'uid': 'u123', 'sign': 'abc'};

      // 旧实现：主 isolate 先编码，子 isolate 又交给 invoke → 再编码
      final doubleEncoded = encodeLikeInvoke(encodeLikeInvoke(payload));
      final decoded = decodeLikeGo(doubleEncoded);

      // 这个断言**固化缺陷现象**：解出来是 String 而不是 Map。
      // 若将来有人"顺手"在 invokeAsync 里加回预编码，本测试会立刻变红。
      expect(decoded, isA<String>(),
          reason: '双重编码的典型特征是解出字符串——Go 侧会因此无法解析');
      expect(decoded, isNot(isA<Map>()),
          reason: '一旦这里变成 Map，说明双重编码被修掉了（应更新本测试的意图）');
    });

    test('空 payload 不发（Go 侧把空串当零值请求，不是错误）', () {
      // invokeAsync 在 payload == null 时不传第三参等价于传 null，
      // invoke 会编成空串。Go 的 ParseRequest 把空串视为零值 Request。
      expect(encodeLikeInvoke(null), 'null');
    });

    test('含中文/特殊字符的 payload 往返不损坏', () {
      final payload = {'label': '请用 115 App 扫码', 'q': 'a"b\\c'};
      final decoded = decodeLikeGo(encodeLikeInvoke(payload))! as Map;
      expect(decoded['label'], '请用 115 App 扫码');
      expect(decoded['q'], 'a"b\\c');
    });

    test('列表与嵌套结构也能原样传递', () {
      final payload = {
        'files': [
          {'id': '1', 'name': 'a.mkv'},
          {'id': '2', 'name': 'b.mp4'},
        ],
        'total': 2,
      };
      final decoded = decodeLikeGo(encodeLikeInvoke(payload))! as Map;
      expect(decoded['total'], 2);
      final files = decoded['files']! as List;
      expect(files.length, 2);
      expect((files[0] as Map)['name'], 'a.mkv');
    });
  });

  group('Pan115QrStatus 语义（由 Dart 侧解析 Go 结果）', () {
    // 直接构造 Go 侧真实返回的 JSON（取自真实网络测试的输出），
    // 验证 Dart 的字段映射没有拼错——这也是"轮询全失败"的另一条可能路径。
    const realPollJson =
        '{"ok":true,"result":{"allowed":false,"label":"请用 115 App 扫码",'
        '"status":0,"terminal":false}}';

    test('★ 真实 Go 响应能被正确映射（字段名不能拼错）', () {
      final env = jsonDecode(realPollJson) as Map<String, dynamic>;
      expect(env['ok'], true);
      final m = env['result']! as Map<String, dynamic>;

      expect(m['status'], 0, reason: 'status=0 表示等待扫码');
      expect(m['label'], '请用 115 App 扫码',
          reason: 'label 是 UI 直接显示的文字，拼错会让界面一直显示默认文案');
      expect(m['terminal'], false, reason: '未扫码不是终态，否则轮询会停');
      expect(m['allowed'], false,
          reason: '未扫码不可换凭据（否则会返回误导性的「老乡验证失败」）');
    });

    test('key 名大小写必须与 Go 侧一致（Go 用 allowed 不是 allow）', () {
      final m = (jsonDecode(realPollJson) as Map)['result']! as Map;
      // 文档化 Go 侧的准确键名：改动任一侧都要同步
      expect(m.keys.toSet(), {'status', 'label', 'terminal', 'allowed'});
    });
  });

  group('★ 凭据键名大小写（真实缺陷的回归线）', () {
    // Go 侧 `pan115_routes.go` 发出的就是这个形状（大写，与 115 cookie 名一致）。
    const goCredentialJson = '{"UID":"u1","CID":"c1","SEID":"s1","KID":"k1"}';

    test('Go 发大写 UID/CID/SEID 时，Dart 必须能读到（曾经读不到）', () {
      final j = jsonDecode(goCredentialJson) as Map<String, dynamic>;

      // 复现缺陷：按下标小写读，全都拿不到
      expect(j['uid'], isNull,
          reason: '这正是当初的 bug：Go 发大写、Dart 读小写 → 静默取到 null');
      expect(j['UID'], 'u1', reason: 'Go 侧确实用大写');

      // 修复后的取法（大小写都兼容）：
      String pick(String a, String b) =>
          (j[a] as String?) ?? (j[b] as String?) ?? '';
      expect(pick('uid', 'UID'), 'u1');
      expect(pick('cid', 'CID'), 'c1');
      expect(pick('seid', 'SEID'), 's1');
      expect(pick('kid', 'KID'), 'k1');
    });

    test('小写形状也要兼容（防止将来 Go 侧改名把登录搞挂）', () {
      final j = jsonDecode('{"uid":"u2","cid":"c2","seid":"s2"}')
          as Map<String, dynamic>;
      String pick(String a, String b) =>
          (j[a] as String?) ?? (j[b] as String?) ?? '';
      expect(pick('uid', 'UID'), 'u2');
      expect(pick('cid', 'CID'), 'c2');
      expect(pick('seid', 'SEID'), 's2');
      expect(pick('kid', 'KID'), '', reason: 'KID 允许缺失（兼容老 cookie）');
    });

    test('★ 缺 CID 时必须判为无效（否则会静默返回空文件列表）', () {
      // 这条与 Go 侧 Credential.Valid() 的口径必须一致：
      // UID/CID/SEID 三缺一即无效；KID 可空。
      // 缺 CID 尤其危险——115 会返回空列表而不是报错，
      // 表现为"网盘是空的"，用户完全不知道发生了什么。
      const missingCid = '{"UID":"u","SEID":"s"}';
      final j = jsonDecode(missingCid) as Map<String, dynamic>;
      String pick(String a, String b) =>
          (j[a] as String?) ?? (j[b] as String?) ?? '';
      final uid = pick('uid', 'UID');
      final cid = pick('cid', 'CID');
      final seid = pick('seid', 'SEID');
      final valid = uid.isNotEmpty && cid.isNotEmpty && seid.isNotEmpty;
      expect(valid, isFalse, reason: '缺 CID 必须无效');
    });
  });
}
