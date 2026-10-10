// 多账号与聚合搜索的守卫测试。
//
// ## 用户要求
// "增加多 emby 账号登录和资源整合"，方案确认为
// **"搜索聚合 + 首页保持单服务器切换"**（用户明确选择）。
//
// ## 为什么这些断言必要
// 多账号最容易出的两类**静默**故障：
// ① **账号唯一键只用 serverUrl** ⇒ 同一台服务器上的第二个 Emby 用户
//    被去重挤掉（家庭共享场景），且**不报错**
// ② **聚合时没有"每台各自 catch"** ⇒ 一台离线导致整个搜索失败
//    （用户看到"搜索失败"，其实另一台有结果）
//
// 还有一类语义错误：**跨服务器点击不切换会话** ⇒ 拿 A 的 itemId
// 去 B 查（404，或更糟：查到另一部同 id 的片）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/data/models.dart';
import 'package:cineflow/data/session_store.dart';

/// 剥注释读源码（§8.4：断言不得被注释满足）。
String code(String path) => File(path)
    .readAsStringSync()
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('///') && !t.startsWith('*');
    })
    .join('\n');

MediaSession _s(String url, String uid) => MediaSession(
      serverUrl: url,
      accessToken: 'tok-$uid',
      user: MediaUser(id: uid, name: 'user$uid'),
      deviceId: 'dev',
    );

void main() {
  group('★ 账号唯一键（accountKey）', () {
    test('★ 同一服务器 + 不同用户 ⇒ 键不同（家庭共享场景）', () {
      final a = _s('http://nas:8096', 'u1');
      final b = _s('http://nas:8096', 'u2');
      expect(SessionStore.accountKey(a), isNot(SessionStore.accountKey(b)),
          reason: '★★ 只用 serverUrl 做键会把第二个用户挤掉 ——\n'
              '    同一台 Emby 可以有多个用户（家庭共享），\n'
              '    他们的库/权限/进度都不同。');
    });

    test('同服务器同用户 ⇒ 键相同（用于去重）', () {
      expect(SessionStore.accountKey(_s('http://nas:8096', 'u1')),
          SessionStore.accountKey(_s('http://nas:8096', 'u1')));
    });

    test('不同服务器同用户 ⇒ 键不同', () {
      expect(SessionStore.accountKey(_s('http://a:8096', 'u1')),
          isNot(SessionStore.accountKey(_s('http://b:8096', 'u1'))));
    });
  });

  group('★★ 源码结构（防脱钩）', () {
    late String store;
    late String agg;
    late String prov;

    setUpAll(() {
      store = code('lib/data/session_store.dart');
      agg = code('lib/data/aggregated_search.dart');
      prov = code('lib/state/providers.dart');
    });

    test('★ accountKey 必须含 userId', () {
      expect(store.contains(r"'${s.serverUrl}|${s.user.id}'"), isTrue,
          reason: '★ accountKey 必须 = serverUrl|userId（见上方测试）');
    });

    test('★ 多账号列表与"当前会话"分开存（向后兼容）', () {
      expect(store.contains('_accountsKey'), isTrue);
      expect(store.contains('_sessionKey'), isTrue,
          reason: '★ `cf_session` 必须保留 —— 所有既有代码都读它，\n'
              '    改成"列表+索引"会牵动整条链路（风险 >> 收益）');
    });

    test('★★ 聚合搜索必须"每台各自 catch"（一台挂不能拖垮全部）', () {
      final i = agg.indexOf('final futures');
      expect(i, greaterThanOrEqualTo(0), reason: '找不到聚合循环');
      // ⚠️ 窗口要足够宽且**不能越界**：
      //    `try` 在 ~230 处、`catch` 在 ~700 处；文件尾可能不足 1100。
      //    （第一版直接 substring(i, i+1100) → RangeError）
      final seg = agg.substring(i, (i + 1100).clamp(0, agg.length));
      expect(seg.contains('try {'), isTrue,
          reason: '★★ 每台必须各自 try/catch ——\n'
              '    否则一台离线会让整个搜索失败（用户看不到另一台的结果）');
      expect(seg.contains('catch (e)'), isTrue);
      // ★ 断言"catch 里**返回**了带 error 的结果"（不是 rethrow）——
      //   只查 `ServerSearchResult(session: s, error:` 太弱：
      //   `catch (e) { throw e; }` 也满足 try+catch 两条，
      //   但**行为是错的**（异常会冒泡到 Future.wait ⇒ 整次搜索失败）。
      final ci = seg.indexOf('catch (e)');
      expect(ci, greaterThanOrEqualTo(0));
      final catchBody = seg.substring(ci, (ci + 200).clamp(0, seg.length));
      expect(catchBody.contains('return ServerSearchResult(session: s, error:'),
          isTrue,
          reason: '★★ catch 里必须**返回**带 error 的结果（不是 rethrow）——\n'
              '    失败要如实带出原因，且不能冒泡拖垮整次搜索。');
      expect(catchBody.contains('throw '), isFalse,
          reason: '★ catch 里不得 rethrow（会毁掉"失败隔离"）');
    });

    test('★ 聚合用 Future.wait 并行（不是串行 await）', () {
      expect(agg.contains('Future.wait('), isTrue,
          reason: '★ 串行搜 N 台 = N 倍等待');
    });

    test('★ 搜索页必须切会话后再打开（跨服务器 id 不可混用）', () {
      final sp = code('lib/pages/search_page.dart');
      expect(sp.contains('switchTo(hit.session)'), isTrue,
          reason: '★★ `MediaItem.id` 是各服务器自己的 GUID；\n'
              '    不切换就拿 A 的 id 去 B 查（404 或查到别的片）');
      expect(sp.contains('_openHit'), isTrue);
    });

    test('★ 海报必须用该条所属服务器的 api 渲染', () {
      final sp = code('lib/pages/search_page.dart');
      expect(sp.contains('api: hit.api'), isTrue,
          reason: '★ 用当前会话的 api 取图会去错的服务器（白图/404）');
    });

    test('★ 单账号时不显示服务器分组标题（避免无意义分组）', () {
      final sp = code('lib/pages/search_page.dart');
      expect(sp.contains('final multi = groups.length > 1'), isTrue,
          reason: '★ 只有一台时显示分组头是噪声');
    });

    test('★ 登录必须登记进 accounts（否则第一个账号不进聚合）', () {
      // ⚠️ 必须**限定在 login 方法体内**断言 —— 文件里 `upsertAccount(`
      //    也出现在 `addAccount` 里，裸 contains 改掉 login 那处仍为真
      //    （§8.4：同一串出现多处）。第一版就栽在这里（注入没抓到）。
      final i = prov.indexOf('Future<void> login(');
      expect(i, greaterThanOrEqualTo(0), reason: '找不到 login');
      final end = prov.indexOf('Future<void> switchTo(', i);
      expect(end, greaterThan(i), reason: '找不到 login 的结束边界');
      final seg = prov.substring(i, end);
      expect(seg.contains('upsertAccount(s)'), isTrue,
          reason: '★ 登录即登记 —— 否则最常用的那台反而不被搜');
    });

    test('★ 退出登录不得删除账号（只清当前会话）', () {
      // ⚠️ 窗口**必须截到方法体结束**（下一个方法签名）——
      //    第一版用固定 700 字符，结果窗口越界进了 `removeAccount`
      //    的方法体，误判为"logout 里调了 removeAccount"。
      //    ⇒ §8.4："窗口用下一个方法名作边界，别拍长度"。
      final i = prov.indexOf('Future<void> logout()');
      expect(i, greaterThanOrEqualTo(0), reason: '找不到 logout');
      final end = prov.indexOf('Future<void> addAccount(', i);
      expect(end, greaterThan(i), reason: '找不到 logout 的结束边界');
      final seg = prov.substring(i, end);
      expect(seg.contains('removeAccount'), isFalse,
          reason: '★ 退出 ≠ 删除账号；彻底移除走 removeAccount');
      expect(seg.contains('clearSession()'), isTrue,
          reason: '★ 退出必须清当前会话');
    });
  });
}
