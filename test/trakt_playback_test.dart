// ══════════════════════════════════════════════════════════════════════
//  `TraktPlaybackReporter`（「实时追踪」的节流与状态机）
// ══════════════════════════════════════════════════════════════════════
//
// ## 为什么必须测（这里的错**用户会直接感受到**）
// | 错误 | 用户看到 |
// |---|---|
// | `start` 不节流 | 反复 play/pause ⇒ 每次都 `start` ⇒ 契约说 start **会清空进度** ⇒ **播放位置被抹掉** |
// | 只用 tmdb id | 服务端拒（契约：episode ids 无 tmdb）⇒ 追踪静默失效 |
// | 把 409/422 当错误 | 重播同一集时日志全是假错误 |
library;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/data/trakt_client.dart';
import 'package:cineflow/data/trakt_playback.dart';

/// 假 Dio：只记录请求，不真发。
///
/// ## 怎么造响应
/// `TraktSync.scrobble` 用 `_dio.post`，`validateStatus` 允许 4xx
/// ⇒ 这里返回指定状态码即可模拟 409/422/201。
class _FakeDio implements Dio {
  _FakeDio(this.statusCode, [this.body]);

  final int statusCode;
  final dynamic body;
  final calls = <Map<String, dynamic>>[];

  /// ⚠️ **必须实现 `interceptors`**（2026-10-14 加 401 自动刷新后暴露的缺口）
  ///
  /// ## 为什么
  /// `TraktSync` 的构造器现在会 `_dio.interceptors.add(...)` 装
  /// "401 自动刷新"拦截器 ⇒ 替身没有这个 getter 就抛
  /// `NoSuchMethodError: Class '_FakeDio' has no instance getter 'interceptors'`
  /// （**12 个测试同时红**，全是这一个原因）。
  ///
  /// ## 为什么用真 `Interceptors` 而不是空实现
  /// 用真的 ⇒ 拦截器**确实被装上了**（能验证"装上没抛异常"）。
  /// 但它**不会被执行** —— 因为本替身直接返回响应、不经过 dio 的
  /// 错误处理链（401 拦截器挂在 `onError` 上）。
  /// ⇒ 本文件测的是"请求体/节流/409-422 语义"，不测刷新（刷新另有测试）。
  @override
  final Interceptors interceptors = Interceptors();

  @override
  Future<Response<T>> post<T>(String path,
      {data, Map<String, dynamic>? queryParameters,
      Options? options, CancelToken? cancelToken,
      ProgressCallback? onSendProgress, ProgressCallback? onReceiveProgress}) async {
    calls.add({'path': path, 'data': data, 'headers': options?.headers});
    return Response<T>(
      requestOptions: RequestOptions(path: path),
      statusCode: statusCode,
      data: body as T?,
    );
  }

  // ---- 以下都是 Dio 接口要求但本项目用不到的成员 ----
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  group('TraktPlaybackReporter · 能否上报的判据', () {
    test('★★★ 只给 tmdb 的剧集 ⇒ **不能上报**（契约限制）', () {
      final rep = TraktPlaybackReporter(
        sync: TraktSync(clientId: 'x', accessToken: 'y', dio: _FakeDio(201)),
        episodeIds: const TraktIds(tmdb: 12345),
      );
      expect(rep.canReport, isFalse,
          reason: '★★★ 契约：episodeIdsRequestSchema 只有 trakt/tvdb。'
              '很多人会以为"有 tmdb 就够了" —— 那不是，必须显式失败而不是静默发出去');
    });

    test('★★ 有 trakt 或 tvdb 的剧集 ⇒ 可以上报', () {
      final sync = TraktSync(clientId: 'x', accessToken: 'y', dio: _FakeDio(201));
      expect(TraktPlaybackReporter(sync: sync,
          episodeIds: const TraktIds(trakt: 1)).canReport, isTrue);
      expect(TraktPlaybackReporter(sync: sync,
          episodeIds: const TraktIds(tvdb: 2)).canReport, isTrue);
    });

    test('★ 电影的 tmdb 可用（契约支持 movie 的 tmdb）', () {
      final rep = TraktPlaybackReporter(
        sync: TraktSync(clientId: 'x', accessToken: 'y', dio: _FakeDio(201)),
        movieIds: const TraktIds(tmdb: 999),
      );
      expect(rep.canReport, isTrue);
    });

    test('★★ 什么都不给 ⇒ 不能上报（且不发请求）', () async {
      final fake = _FakeDio(201);
      final rep = TraktPlaybackReporter(
          sync: TraktSync(clientId: 'x', accessToken: 'y', dio: fake));
      expect(rep.canReport, isFalse);
      final r = await rep.onStarted();
      expect(r.error, isNotNull);
      expect(fake.calls, isEmpty, reason: '不能上报时**不应**发请求');
    });
  });

  group('TraktPlaybackReporter · 节流（防止 start 抹掉进度）', () {
    test('★★★ 同类动作在 minInterval 内**不重复发**', () async {
      final fake = _FakeDio(201, {'action': 'start'});
      final rep = TraktPlaybackReporter(
        sync: TraktSync(clientId: 'x', accessToken: 'y', dio: fake),
        episodeIds: const TraktIds(trakt: 1),
        minInterval: const Duration(seconds: 10),
      );
      await rep.onStarted();
      await rep.onStarted();   // 立刻再来一次 ⇒ 应被节流
      await rep.onStarted();
      expect(fake.calls.length, 1,
          reason: '★★★ 契约：start **会清空播放进度**。'
              '用户反复点 play/pause 若不节流，每次 start 都会把位置抹掉');
    });

    test('★★ 不同动作**不互相**节流（play→pause 应都发出）', () async {
      final fake = _FakeDio(201, {'action': 'pause'});
      final rep = TraktPlaybackReporter(
        sync: TraktSync(clientId: 'x', accessToken: 'y', dio: fake),
        episodeIds: const TraktIds(trakt: 1),
      );
      await rep.onStarted();
      await rep.onPaused(30);
      await rep.onStopped(30);
      expect(fake.calls.length, 3,
          reason: '★ 节流只针对**同类**动作；play→pause→stop 是不同状态，都要报');
      // ⚠️ 路径是**完整 URL**（`$_apiBase/scrobble/x`）—— 我第一版断言写成
      //    `/scrobble/x`（相对路径）⇒ 假失败。断言要看**结尾**而不是全等。
      final paths = fake.calls.map((c) => c['path'] as String).toList();
      expect(paths.where((p) => p.endsWith('/scrobble/start')).length, 1);
      expect(paths.where((p) => p.endsWith('/scrobble/pause')).length, 1);
      expect(paths.where((p) => p.endsWith('/scrobble/stop')).length, 1);
      expect(paths.every((p) => p.startsWith('https://api.trakt.tv/')), isTrue,
          reason: '契约的 base 是 https://api.trakt.tv');
    });
  });

  group('TraktPlaybackReporter · 请求体符合契约', () {
    test('★★★ progress 传 0–100（不是 0–1）', () async {
      final fake = _FakeDio(201, {'action': 'stop'});
      final rep = TraktPlaybackReporter(
        sync: TraktSync(clientId: 'x', accessToken: 'y', dio: fake),
        episodeIds: const TraktIds(trakt: 1),
      );
      await rep.onStopped(85.5);
      final data = fake.calls.first['data'] as Map;
      expect(data['progress'], 85.5,
          reason: '★★★ 契约：progress 是 float(0-100)。'
              '传 0.855 会被服务端视为 0.855% ⇒ 判为 <1% ⇒ 422 忽略');
    });

    test('★★★ 剧集 id 里**不含 tmdb**（即使传了完整的 TraktIds）', () async {
      final fake = _FakeDio(201, {'action': 'start'});
      final rep = TraktPlaybackReporter(
        sync: TraktSync(clientId: 'x', accessToken: 'y', dio: fake),
        episodeIds: const TraktIds(trakt: 1, tmdb: 2, tvdb: 3),
      );
      await rep.onStarted();
      final data = fake.calls.first['data'] as Map;
      final ids = (data['episode'] as Map)['ids'] as Map;
      expect(ids.containsKey('tmdb'), isFalse,
          reason: '★★★ 契约：episode ids 只接受 trakt/tvdb。'
              '混 tmdb 会被服务端拒且不指出字段');
      expect(ids['trakt'], 1);
      expect(ids['tvdb'], 3);
    });

    test('★★ 请求头带 Bearer token（契约要求 OAuth）', () async {
      final fake = _FakeDio(201, {'action': 'start'});
      final rep = TraktPlaybackReporter(
        sync: TraktSync(clientId: 'cid', accessToken: 'tok', dio: fake),
        episodeIds: const TraktIds(trakt: 1),
      );
      await rep.onStarted();
      final h = fake.calls.first['headers'] as Map;
      expect(h['Authorization'], 'Bearer tok');
      expect(h['trakt-api-key'], 'cid');
      expect(h['trakt-api-version'], '2');
    });

    test('★ 电影请求体带 title/year/ids（契约形状）', () async {
      final fake = _FakeDio(201, {'action': 'start'});
      final rep = TraktPlaybackReporter(
        sync: TraktSync(clientId: 'x', accessToken: 'y', dio: fake),
        movieIds: const TraktIds(tmdb: 7),
        movieTitle: '某电影',
        movieYear: 2026,
      );
      await rep.onStarted();
      final mv = (fake.calls.first['data'] as Map)['movie'] as Map;
      expect(mv['title'], '某电影');
      expect(mv['year'], 2026);
      expect((mv['ids'] as Map)['tmdb'], 7);
    });
  });

  group('TraktPlaybackReporter · 409/422 不当错误', () {
    test('★★ 409 ⇒ duplicate 标志，ok=false 但**无 error**', () async {
      final fake = _FakeDio(409, {});
      final rep = TraktPlaybackReporter(
        sync: TraktSync(clientId: 'x', accessToken: 'y', dio: fake),
        episodeIds: const TraktIds(trakt: 1),
      );
      final r = await rep.onStarted();
      expect(r.duplicate, isTrue);
      expect(r.error, isNull, reason: '★ 409 是防重复，不是故障');
    });

    test('★★ 422 ⇒ tooShort 标志（进度<1%）', () async {
      final fake = _FakeDio(422, {});
      final rep = TraktPlaybackReporter(
        sync: TraktSync(clientId: 'x', accessToken: 'y', dio: fake),
        episodeIds: const TraktIds(trakt: 1),
      );
      final r = await rep.onStopped(0.5);
      expect(r.tooShort, isTrue);
      expect(r.error, isNull);
    });
  });
}
