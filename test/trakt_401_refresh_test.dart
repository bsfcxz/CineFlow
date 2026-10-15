// ══════════════════════════════════════════════════════════════════════
//  ★★★ 401 自动刷新的**行为测试**（用真 dio + 假 adapter，离线）
// ══════════════════════════════════════════════════════════════════════
//
// ## 为什么必须单独一个文件（而不是塞进 trakt_refresh_test.dart）
// 那个文件用 `_FakeDio`（**替身**）⇒ **绕过 dio 的拦截器机制**。
// 而 401 刷新的失效模式恰恰在**拦截器机制**里：
// ```
// _opts.validateStatus = (s) => s != null && s < 500
// PROBE-401      status=401  err=null  onError=0  onResponse=1
// PROBE-DEFAULT（默认 validateStatus）  onError=1
// ```
// ⇒ 401 < 500 ⇒ 被当成**成功响应** ⇒ **永不进 `onError`**
// ⇒ 只挂 `onError` 时自动刷新**一行都不执行**，而 15 个替身测试**全绿**。
//
// ## 本文件怎么"真的验证"
// 用 **真 `Dio`** + 假 `HttpClientAdapter`（不联网）：
// · adapter 第 1 次返回 401 → 第 2 次（带新 token）返回 200
// · 断言：① 确实发起了刷新请求 ② 原请求被**重放**且带上了新 token
// ⇒ 这才覆盖了"拦截器是否真的会触发"这条链路。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/data/trakt_client.dart';

/// 假适配器：按脚本返回响应，并记录每次收到的 Authorization 头。
///
/// ## 为什么不联网
/// 单测**不该依赖网络**（会 flaky、且可能打到真实服务端 ——
/// 我在 `trakt_refresh_test.dart` 上真踩过：日志出现真实
/// `400 {"error":"invalid_grant"}`）。
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.script);

  /// 每次请求依次返回的 (状态码, body)。
  final List<(int, Map<String, dynamic>)> script;

  /// 记录每次请求的 `Authorization` 头（用于断言"重放带了新 token"）。
  final authHeaders = <String?>[];

  /// 记录请求路径。
  final paths = <String>[];

  int _i = 0;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    authHeaders.add(options.headers['Authorization']?.toString());
    paths.add(options.uri.path);
    final idx = _i < script.length ? _i : script.length - 1;
    _i++;
    final (code, body) = script[idx];
    return ResponseBody.fromString(
      jsonEncode(body),
      code,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('★★★ 401 ⇒ 自动刷新 ⇒ 重放（真 dio + 假 adapter）', () {
    test('★★★ 业务请求 401 ⇒ 触发刷新并把原请求**重放**（带新 token）', () async {
      // 脚本：
      //   ① 业务请求 → 401（token 过期）
      //   ② 刷新请求 → 200（给新 token）
      //   ③ 重放业务请求 → 200
      final adapter = _ScriptedAdapter([
        (401, {'error': 'unauthorized'}),
        (200, {'access_token': 'NEW-A', 'refresh_token': 'NEW-R',
               'created_at': 1700000000, 'expires_in': 604800}),
        // ⚠️ 重放的响应必须是**契约形状**（`TraktScrobbleResult.fromJson`
        //    读 `action` 字段来判断"服务端是否把它降级成 pause"）。
        //    我第一版写了 `{'ok': true}` ⇒ `r.ok` 为 false ⇒ 断言假失败。
        //    契约（scrobble/index.ts）：201 返回 `{action, ...}`。
        (201, {'action': 'start', 'progress': 10.0}),
      ]);

      final biz = Dio()..httpClientAdapter = adapter;
      final sync = TraktSync(
        clientId: 'cid', accessToken: 'OLD', refreshToken: 'OLD-R',
        dio: biz,
        // ⚠️ 刷新也要走**同一个**被观察的 dio ⇒ 否则本测试观察不到刷新请求
        //    （生产默认是独立裸实例，那是**防递归**要求）
        bareDio: biz,
      );

      final r = await sync.scrobble(
        action: TraktScrobbleAction.start,
        progress: 10,
        episodeIds: const TraktIds(trakt: 1),
      );

      expect(adapter.paths.length, 3,
          reason: '★★★ 应为 3 次请求：业务401 → 刷新 → 重放\n'
              '    若只有 1 次 ⇒ **401 拦截器没触发**（自动刷新是死代码）');
      expect(adapter.paths[1], contains('/oauth/token'),
          reason: '★ 第 2 次必须是刷新请求');
      expect(adapter.authHeaders[2], 'Bearer NEW-A',
          reason: '★★★ 重放必须带**新** token —— 否则重放还是 401，等于没刷新');
      expect(r.ok, isTrue, reason: '★ 重放成功后，调用方应拿到成功结果');
    });

    test('★★★ 刷新后再 401 ⇒ **只重试一次**（不无限循环）', () async {
      // 脚本：全部 401（模拟"新 token 也无效"，例如账号被吊销）
      final adapter = _ScriptedAdapter([
        (401, {'error': 'unauthorized'}),
        (200, {'access_token': 'NEW-A', 'refresh_token': 'NEW-R'}),
        (401, {'error': 'still unauthorized'}),
      ]);
      final biz = Dio()..httpClientAdapter = adapter;
      final sync = TraktSync(
        clientId: 'cid', accessToken: 'OLD', refreshToken: 'OLD-R',
        dio: biz, bareDio: biz,
      );

      final r = await sync.scrobble(
        action: TraktScrobbleAction.start,
        progress: 10,
        episodeIds: const TraktIds(trakt: 1),
      );

      expect(adapter.paths.length, 3,
          reason: '★★★ 必须**恰好 3 次**（业务 → 刷新 → 重放一次后放弃）。\n'
              '    若持续增长 ⇒ `__traktRetried` 标记失效 ⇒ **无限循环**\n'
              '    （真机上表现为请求风暴 + 耗电）');
      expect(r.ok, isFalse, reason: '★ 最终仍是 401 ⇒ 如实报失败');
    });

    test('★★ 刷新请求失败（如 refresh token 作废）⇒ 不重放，**原样返回 401**',
        () async {
      final adapter = _ScriptedAdapter([
        (401, {'error': 'unauthorized'}),
        // 刷新失败：官方文档的 `invalid_grant`
        (400, {'error': 'invalid_grant',
               'error_description': 'session not found'}),
      ]);
      final biz = Dio()..httpClientAdapter = adapter;
      final sync = TraktSync(
        clientId: 'cid', accessToken: 'OLD', refreshToken: 'BAD',
        dio: biz, bareDio: biz,
      );

      final r = await sync.scrobble(
        action: TraktScrobbleAction.start,
        progress: 10,
        episodeIds: const TraktIds(trakt: 1),
      );

      expect(adapter.paths.length, 2,
          reason: '★ 刷新失败 ⇒ **不该重放**（重放也会 401，白费一次请求）');
      expect(r.statusCode, 401, reason: '★ 把原始的 401 如实交回调用方');
    });

    test('★★★ 刷新成功后 accessToken2 被替换（后续请求用新 token）', () async {
      final adapter = _ScriptedAdapter([
        (401, {'error': 'unauthorized'}),
        (200, {'access_token': 'NEW-A', 'refresh_token': 'NEW-R'}),
        (200, {'ok': true}),
        (200, {'ok': true}),   // 第 4 次：后续**新**业务请求
      ]);
      final biz = Dio()..httpClientAdapter = adapter;
      final sync = TraktSync(
        clientId: 'cid', accessToken: 'OLD', refreshToken: 'OLD-R',
        dio: biz, bareDio: biz,
      );

      await sync.scrobble(
        action: TraktScrobbleAction.start, progress: 10,
        episodeIds: const TraktIds(trakt: 1));

      expect(sync.accessToken2, 'NEW-A');

      // 再发一次业务请求（这次不该 401、不该刷新）
      await sync.scrobble(
        action: TraktScrobbleAction.pause, progress: 20,
        episodeIds: const TraktIds(trakt: 1));

      expect(adapter.authHeaders.last, 'Bearer NEW-A',
          reason: '★★★ 后续请求必须用**新** token（否则每次都要 401+刷新一轮）');
      expect(adapter.paths.length, 4,
          reason: '★ 第 2 次业务请求**不该**再触发刷新（token 已是新的）');
    });
  });
}
