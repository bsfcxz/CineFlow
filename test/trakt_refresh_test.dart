// ══════════════════════════════════════════════════════════════════════
//  Trakt **Token 自动刷新**的契约守卫测试
// ══════════════════════════════════════════════════════════════════════
//
// ## 为什么这组测试必须有
// 刷新的失败形态是**静默的**：
// · 不刷新 ⇒ access token **7 天后**（官方文档）失效
//   ⇒ 用户所有 Trakt 功能停摆，现象是"同步不动了"（极难查）
// · refresh token 是**一次性**的 ⇒ 若并发刷新各刷一次，
//   第二次用**已作废**的 token ⇒ 用户被踢到"重新授权"
//
// ## 实测依据（写在 `TraktSync.refresh()` 的注释里）
// ```
// A. 只 refresh_token + client_id
//    → 400 {"error":"invalid_request","error_description":"grant_type is required"}
// B. + grant_type                     ← 本实现
//    → 400 {"error":"invalid_grant","error_description":"session not found"}
// E. 缺 client_id → 400 invalid_grant  ← 服务端**不强制**它
// F. 缺 refresh_token → 400 invalid_request "Missing a required refresh_token"
// ```
//
// ## ⚠️ 两个 dio 参数的区别（我为此修了两轮，务必看清）
// | 参数 | 用途 | 谁注入 |
// |---|---|---|
// | `dio` | **业务请求**（scrobble/history/…）| 生产：默认；测试：`_FakeDio` |
// | `bareDio` | **仅 `/oauth/token` 刷新**（裸实例，**防递归**）| 生产：默认 `Dio()`；测试：**必须也注入替身** |
//
// ⚠️ **只注入 `dio` 是不够的** —— 刷新走的是 `bareDio`
// ⇒ 不注入它，测试会**真的联网打 Trakt 服务端**
//   （实测踩过：日志出现真实响应 `400 {"error":"invalid_grant"}`）。
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/data/trakt_client.dart';

/// 假 Dio：记录请求 + 可指定响应。
class _FakeDio implements Dio {
  _FakeDio({this.statusCode = 200, this.body});

  int statusCode;
  dynamic body;
  final calls = <Map<String, dynamic>>[];

  /// ⚠️ `TraktSync` 构造器会往这里装 401 拦截器 ⇒ 必须实现
  ///（否则报 `NoSuchMethodError: no instance getter 'interceptors'`）
  @override
  final Interceptors interceptors = Interceptors();

  @override
  Future<Response<T>> post<T>(String path,
      {data,
      Map<String, dynamic>? queryParameters,
      Options? options,
      CancelToken? cancelToken,
      ProgressCallback? onSendProgress,
      ProgressCallback? onReceiveProgress}) async {
    calls.add({'path': path, 'data': data});
    return Response<T>(
      requestOptions: RequestOptions(path: path),
      statusCode: statusCode,
      data: body as T?,
    );
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// 抛异常的假 Dio（测"网络失败不抛"）。
class _ThrowingDio implements Dio {
  @override
  final Interceptors interceptors = Interceptors();

  @override
  Future<Response<T>> post<T>(String path,
          {data,
          Map<String, dynamic>? queryParameters,
          Options? options,
          CancelToken? cancelToken,
          ProgressCallback? onSendProgress,
          ProgressCallback? onReceiveProgress}) async =>
      throw DioException(requestOptions: RequestOptions(path: path));

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// 构造一个"两个 dio 都用同一个替身"的 TraktSync。
///
/// ## 为什么要包一层（而不是每处写两遍）
/// 本文件有 8 处构造 ⇒ 逐个写 `dio:` + `bareDio:` 必然漏
///（我第一版就漏了 6 处，导致测试**真的联网**）。
TraktSync _sync({
  required Dio fake,
  String access = 'o',
  String? refresh = 'r',
  void Function(String, String?)? onRefreshed,
  void Function(int)? onExpires,
}) =>
    TraktSync(
      clientId: 'cid',
      accessToken: access,
      refreshToken: refresh,
      onTokenRefreshed: onRefreshed,
      onExpiresAt: onExpires,
      // 业务请求 + 刷新请求都用同一个替身：
      // 前者验证"请求体形状"，后者验证"刷新拿到什么响应"
      dio: fake,
      bareDio: fake,
    );

void main() {
  group('★★★ refresh 的请求体（实测确定的必需字段）', () {
    test('★★★ 必须带 refresh_token + grant_type（实测 A 组缺 grant_type 会报错）',
        () async {
      final dio = _FakeDio(statusCode: 200, body: {
        'access_token': 'new-access',
        'refresh_token': 'new-refresh',
      });
      final ok = await _sync(fake: dio, access: 'old', refresh: 'old-refresh')
          .refresh();
      expect(ok, isTrue);
      expect(dio.calls.length, 1);
      final body = dio.calls.first['data'] as Map;
      expect(body['refresh_token'], 'old-refresh');
      expect(body['grant_type'], 'refresh_token',
          reason: '★★★ 实测：缺它服务端返回\n'
              '    `400 invalid_request "grant_type is required"`');
      expect(dio.calls.first['path'], contains('/oauth/token'));
    });

    test('★ 不发 redirect_uri / client_secret（实测服务端不强制）', () async {
      final dio = _FakeDio(statusCode: 200, body: {
        'access_token': 'a', 'refresh_token': 'r',
      });
      await _sync(fake: dio).refresh();
      final body = dio.calls.first['data'] as Map;
      expect(body.containsKey('redirect_uri'), isFalse,
          reason: '★ 实测 C 组（带 redirect_uri）与 B 组响应**逐字相同**\n'
              '    ⇒ 不需要发它');
      expect(body.containsKey('client_secret'), isFalse);
    });
  });

  group('★★★ 一次性语义：必须替换新旧 token', () {
    test('★★★ 刷新成功后 accessToken2 必须变成新的', () async {
      final sync = _sync(
        fake: _FakeDio(statusCode: 200, body: {
          'access_token': 'new-a', 'refresh_token': 'new-r',
        }),
        access: 'old', refresh: 'old-r',
      );
      await sync.refresh();
      expect(sync.accessToken2, 'new-a',
          reason: '★ 请求时读的是 accessToken2 ⇒ 不更新的话刷新等于没做');
    });

    test('★★★ refresh token 必须被替换（官方：旧的立即作废）', () async {
      final sync = _sync(
        fake: _FakeDio(statusCode: 200, body: {
          'access_token': 'new-a', 'refresh_token': 'new-r',
        }),
        access: 'old', refresh: 'old-r',
      );
      await sync.refresh();
      expect(sync.refreshToken, 'new-r',
          reason: '★★★ 官方原文：\n'
              '    "The refresh token used in the request is **immediately\n'
              '     invalidated**, so always replace your stored tokens."\n'
              '    ⇒ 不替换 ⇒ 下次刷新必失败 ⇒ 用户被踢到重新授权');
    });

    test('★★ 回调必须把**两个** token 都传出去（只传 access 会丢 refresh）',
        () async {
      String? gotA;
      String? gotR;
      final sync = _sync(
        fake: _FakeDio(statusCode: 200, body: {
          'access_token': 'new-a', 'refresh_token': 'new-r',
        }),
        access: 'old', refresh: 'old-r',
        onRefreshed: (a, r) {
          gotA = a;
          gotR = r;
        },
      );
      await sync.refresh();
      expect(gotA, 'new-a');
      expect(gotR, 'new-r',
          reason: '★★ 只写 access 会让存储里的 refresh 变成**已作废**的那个');
    });
  });

  group('★★ 失败形态（不能把"没登录"当"刷新失败"）', () {
    test('★★★ 没有 refresh token ⇒ 返回 false 且**不发请求**', () async {
      final dio = _FakeDio();
      final sync = _sync(fake: dio, refresh: null);
      expect(await sync.refresh(), isFalse);
      expect(dio.calls, isEmpty,
          reason: '★ 没凭据就不该发请求（省一次无意义的 400）');
    });

    test('★★ 400 invalid_grant ⇒ 返回 false，**不抛异常**', () async {
      final sync = _sync(
        fake: _FakeDio(statusCode: 400, body: {
          'error': 'invalid_grant', 'error_description': 'session not found',
        }),
        refresh: 'bad',
      );
      expect(await sync.refresh(), isFalse,
          reason: '★ 官方：legacy refresh token 换不了 ⇒ 要让用户重新授权，\n'
              '    但**不能抛异常**（会把调用方的播放流程打断）');
    });

    test('★★ 200 但响应缺 access_token ⇒ 返回 false（防御式）', () async {
      final sync = _sync(
        fake: _FakeDio(statusCode: 200, body: {'refresh_token': 'r2'}),
      );
      expect(await sync.refresh(), isFalse,
          reason: '★ 形状变了要当失败，不能把 null 塞进 accessToken2');
    });

    test('★ 网络异常 ⇒ 返回 false，不抛', () async {
      final sync = _sync(fake: _ThrowingDio());
      expect(await sync.refresh(), isFalse);
    });
  });

  group('★★★ 刷新**不能**走带拦截器的 dio（防递归）', () {
    test('★★★ 刷新必须用 `bareDio`，不能用 `dio`', () async {
      // ⚠️ 这是**硬要求**：`_dio` 上装了"401 ⇒ 刷新 ⇒ 重放"的拦截器。
      //    若刷新请求也走 `_dio`，而 `/oauth/token` 返回 401
      //    （refresh token 作废时正是）⇒ 拦截器再调刷新 ⇒ **无限递归**。
      final bizDio = _FakeDio(statusCode: 200,
          body: {'access_token': 'x', 'refresh_token': 'y'});
      final bareDio = _FakeDio(statusCode: 200,
          body: {'access_token': 'na', 'refresh_token': 'nr'});
      final sync = TraktSync(
        clientId: 'cid', accessToken: 'o', refreshToken: 'r',
        dio: bizDio, bareDio: bareDio,
      );
      await sync.refresh();
      expect(bareDio.calls.length, 1,
          reason: '★★★ 刷新请求必须打在**裸 dio** 上（防递归）');
      expect(bizDio.calls, isEmpty,
          reason: '★★★ 若这里非空 ⇒ 刷新走了带拦截器的 dio ⇒ 401 时会无限递归');
    });
  });

  group('★★ 单飞（single-flight）的结构守卫', () {
    test('★★★ 源码必须实现单飞（`_refreshing ??=` 存在）', () async {
      // `_refreshOnce()` 是私有的，测试无法直接调 ⇒ 只能做**结构断言**。
      // ⚠️ 单飞是硬要求：refresh token **一次性**
      //    ⇒ 并发 401 各刷一次 ⇒ 后两次必失败 ⇒ 用户被登出。
      final src = await File('lib/data/trakt_client.dart').readAsString();
      expect(src.contains('_refreshing ??='), isTrue,
          reason: '★★★ 单飞是硬要求（官方：refresh token single-use）');
      expect(src.contains('__traktRetried'), isTrue,
          reason: '★★ 必须有"只重试一次"的标记，否则刷新后再 401 会无限循环');
    });

    test('★★★ 401 必须**两个回调都判**（onResponse + onError）', () async {
      // ⚠️ 实测证据（真 dio + 假 adapter）：
      //   `validateStatus: (s) => s < 500` 让 401 变成"成功响应"
      //   ⇒ **永不进 onError** ⇒ 只挂 onError 的话刷新**一行都不执行**。
      //   （我第一版就是这样，且 14 个测试全绿 —— 因为替身绕过了真实行为。）
      final src = await File('lib/data/trakt_client.dart').readAsString();
      expect(src.contains('onResponse: (r, handler)'), isTrue,
          reason: '★★★ 401 被 validateStatus 接受时走 onResponse ⇒\n'
              '    必须在这里也判 401，否则自动刷新是**死代码**');
      expect(src.contains('onError: (e, handler)'), isTrue,
          reason: '★ 兜底：某些调用点若用了自己的 validateStatus，401 走异常路径');
    });
  });

  group('★★ fromStore 工厂（三处调用点统一入口）', () {
    test('★★★ 没登录（access 为空）⇒ 返回 null，不构造', () async {
      final s = await TraktSync.fromStore(
        clientId: 'cid',
        readAccess: () async => null,
        readRefresh: () async => 'r',
        writeTokens: (a, r) async {},
        writeExpiresAt: (_) async {},
        expiresInMs: () async => null,
      );
      expect(s, isNull, reason: '★ 没登录时调用方应跳过 Trakt 功能');
    });

    test('★★★ 已登录 ⇒ 带上 refreshToken（否则刷新是死的）', () async {
      final s = await TraktSync.fromStore(
        clientId: 'cid',
        readAccess: () async => 'acc',
        readRefresh: () async => 'ref',
        writeTokens: (a, r) async {},
        writeExpiresAt: (_) async {},
        expiresInMs: () async => null,
      );
      expect(s, isNotNull);
      expect(s!.refreshToken, 'ref',
          reason: '★★★ 不带它 ⇒ `refresh()` 第一行就 return false\n'
              '    ⇒ 401 拦截器装了也永远刷不动（我本轮差点就这么交了）');
    });

    test('★★ 刷新回调会写回存储（两个 token 都写）', () async {
      String? wroteA;
      String? wroteR;
      final s = await TraktSync.fromStore(
        clientId: 'cid',
        readAccess: () async => 'acc',
        readRefresh: () async => 'ref',
        writeTokens: (a, r) async {
          wroteA = a;
          wroteR = r;
        },
        writeExpiresAt: (_) async {},
        expiresInMs: () async => null,
        dio: _FakeDio(statusCode: 200, body: {
          'access_token': 'na', 'refresh_token': 'nr',
        }),
        bareDio: _FakeDio(statusCode: 200, body: {
          'access_token': 'na', 'refresh_token': 'nr',
        }),
      );
      await s!.refresh();
      // 回调是 unawaited 的 ⇒ 让事件循环跑一轮
      await Future<void>.delayed(Duration.zero);
      expect(wroteA, 'na');
      expect(wroteR, 'nr');
    });
  });
}
