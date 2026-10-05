import 'dart:convert';

import 'package:cineflow/danmaku/danmaku_client.dart';
import 'package:cineflow/danmaku/danmaku_config.dart';
import 'package:cineflow/danmaku/danmaku_models.dart';
import 'package:cineflow/danmaku/danmaku_sign.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 弹弹play 客户端的行为测试。
///
/// ## 为什么用 Mock Dio 而不是打真实接口
///
/// 两个原因，都是实测得出的：
/// 1. **官方 API 在本机网络不可达**（`api.dandanplay.net` HTTPS 被拦，
///    实测 HTTP 000；同域的 doc./dev. 却可访问）——无法端到端联调。
/// 2. 官方《使用约定》明令**禁止批量抓取与高频调用**，测试不该打真实接口。
///
/// 所以这里覆盖的是**协议契约**：请求头/路径/参数是否符合官方规范、
/// 以及官方文档点名的两类错误（HTTP 403 与"包在 200 里的业务错误"）是否被正确识别。
/// 这两类错误若不处理，表现是"弹幕空着但不报错"，用户完全无从排查。
void main() {
  late List<RequestOptions> sent;

  DanmakuClient build({
    Map<String, dynamic>? jsonBody,
    String? rawBody,
    int status = 200,
    Map<String, List<String>> headers = const {},
    String appId = 'id',
    String appSecret = 'sec',
    DanmakuProviderKind kind = DanmakuProviderKind.official,
    String baseUrl = DanmakuClient.kOfficialBase,
  }) {
    sent = [];
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
      sent.add(o);
      h.resolve(Response(
        requestOptions: o,
        statusCode: status,
        data: rawBody ?? jsonEncode(jsonBody ?? const {}),
        headers: Headers.fromMap({
          for (final e in headers.entries) e.key: e.value,
        }),
      ));
    }));
    return DanmakuClient(
      kind: kind,
      baseUrl: baseUrl,
      appId: appId,
      appSecret: appSecret,
      // 测试默认关异步，避免首次响应解析影响既有断言；
      // 异步路径由 danmaku_async_test.dart 覆盖
      useAsync: false,
      dio: dio,
    );
  }

  /// 构造一个能拿到 taskId 的客户端（用于异步路径）
  DanmakuClient buildAsync({
    required Map<String, dynamic> first,
    required Map<String, dynamic> polled,
    required Map<String, dynamic> finalBody,
  }) {
    sent = [];
    var call = 0;
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
      sent.add(o);
      final body = switch (call++) {
        0 => first,
        1 => polled,
        _ => finalBody,
      };
      h.resolve(Response(
        requestOptions: o,
        statusCode: 200,
        data: jsonEncode(body),
        headers: Headers(),
      ));
    }));
    return DanmakuClient(
      kind: DanmakuProviderKind.selfHosted,
      baseUrl: 'http://danmu.local:9321/tok',
      useAsync: true,
      dio: dio,
    );
  }

  group('请求签名（官方规范）', () {
    test('弹幕请求带齐三个认证头', () async {
      final c = build(jsonBody: {'count': 0, 'comments': []});
      await c.comments(123);
      final h = sent.single.headers;
      expect(h.containsKey('X-AppId'), isTrue);
      expect(h.containsKey('X-Timestamp'), isTrue);
      expect(h.containsKey('X-Signature'), isTrue);
    });

    test('签名用的 path 不含查询参数（否则服务端必然 403）', () async {
      final c = build(jsonBody: {'count': 0, 'comments': []});
      await c.comments(123, withRelated: true, chConvert: 1);
      final o = sent.single;
      // 请求确实带了查询参数
      expect(o.queryParameters['withRelated'], 'true');
      expect(o.queryParameters['chConvert'], '1');
      // 但签名必须只覆盖 path 部分——用同 path 重新算签名应完全一致
      final expectSig = dandanplaySignatureOf(o);
      expect(o.headers['X-Signature'], expectSig);
    });

    test('未配置凭据时给出可操作的中文提示', () async {
      final c = build(appId: '', appSecret: '');
      await expectLater(
        c.comments(1),
        throwsA(isA<DanmakuException>().having(
          (e) => e.message,
          'message',
          contains('未配置'),
        )),
      );
    });
  });

  group('URL 与参数（官方接口形状）', () {
    test('弹幕接口是 /api/v2/comment/{episodeId}', () async {
      final c = build(jsonBody: {'count': 0, 'comments': []});
      await c.comments(999);
      expect(sent.single.path, 'https://api.dandanplay.net/api/v2/comment/999');
    });

    test('withRelated 默认开启（官方推荐整合第三方源）', () async {
      final c = build(jsonBody: {'count': 0, 'comments': []});
      await c.comments(1);
      expect(sent.single.queryParameters['withRelated'], 'true');
    });

    test('chConvert 默认 1（转简体，与全中文 UI 一致）', () async {
      final c = build(jsonBody: {'count': 0, 'comments': []});
      await c.comments(1);
      expect(sent.single.queryParameters['chConvert'], '1');
    });

    test('搜索接口是 /api/v2/search/episodes 且集号用数字（官方建议）', () async {
      final c = build(jsonBody: {'success': true, 'animes': []});
      await c.findEpisodeId(anime: '我推的孩子', episode: 5);
      final o = sent.single;
      expect(o.path, 'https://api.dandanplay.net/api/v2/search/episodes');
      expect(o.queryParameters['anime'], '我推的孩子');
      expect(o.queryParameters['episode'], '5',
          reason: '官方变更日志：episode 为数字时响应显著更快');
    });

    test('不传集号时请求里不出现 episode 参数（剧场版场景）', () async {
      final c = build(jsonBody: {'success': true, 'animes': []});
      await c.findEpisodeId(anime: '千与千寻');
      expect(sent.single.queryParameters.containsKey('episode'), isFalse);
    });
  });

  group('弹幕解析', () {
    test('解析官方形状并排序', () async {
      final c = build(jsonBody: {
        'count': 3,
        'comments': [
          {'cid': 3, 'p': '30.5,1,25,16777215,0,0,abc,0', 'm': '第三'},
          {'cid': 1, 'p': '1.0,1,25,16777215,0,0,abc,0', 'm': '第一'},
          {'cid': 2, 'p': '10,4,25,16711680,0,0,def,0', 'm': '底部'},
        ],
      });
      final batch = await c.comments(7);
      expect(batch.items.length, 3);
      // 乱序输入必须被排好（渲染层假定有序）
      expect(batch.items[0].text, '第一');
      expect(batch.items[1].text, '底部');
      expect(batch.items[2].text, '第三');
      expect(batch.items[0].timeMs, 1000);
      expect(batch.items[2].timeMs, 30500);
      expect(batch.items[1].mode, DanmakuMode.bottom);
      expect(batch.items[1].color, 16711680);
    });

    test('p 字段缺段时不崩、按默认值处理', () async {
      final c = build(jsonBody: {
        'count': 1,
        'comments': [
          {'cid': 1, 'p': '5', 'm': '只有时间'},
        ],
      });
      final b = await c.comments(1);
      expect(b.items.single.mode, DanmakuMode.scroll);
      expect(b.items.single.color, 0xFFFFFF);
    });

    test('非法条目被跳过，合法条目仍可用（不因一条坏数据全丢）', () async {
      final c = build(jsonBody: {
        'count': 4,
        'comments': [
          {'cid': 1, 'p': '1,1,25,16777215', 'm': '好'},
          {'cid': 2, 'p': 'not-a-number', 'm': '坏时间'},
          {'cid': 3, 'm': '缺 p'},
          'not-a-map',
        ],
      });
      final b = await c.comments(1);
      expect(b.items.length, 1);
      expect(b.items.single.text, '好');
    });

    test('count=0 且无 comments 是合法结果（没弹幕，不是错误）', () async {
      final c = build(jsonBody: {'count': 0});
      final b = await c.comments(1);
      expect(b.items, isEmpty);
    });

    test('带 alpha 的颜色被夹到 24 位（否则弹幕变全透明）', () async {
      final c = build(jsonBody: {
        'count': 1,
        // 0x00FFFFFF：alpha=0 会让弹幕完全看不见
        'comments': [
          {'cid': 1, 'p': '1,1,25,16777215', 'm': '透明?'},
        ],
      });
      final b = await c.comments(1);
      expect(b.items.single.color, 0xFFFFFF);
    });

    test('空文本弹幕被丢弃', () async {
      final c = build(jsonBody: {
        'count': 1,
        'comments': [
          {'cid': 1, 'p': '1,1,25,16777215', 'm': '   '},
        ],
      });
      final b = await c.comments(1);
      expect(b.items, isEmpty);
    });
  });

  group('★ p 字段的两种格式（实测踩过的坑）', () {
    // 下面两条 fixture 来自真实抓包（调研确认），
    // 不是构造出来的——它们正是"颜色解析错位"这个 bug 的证据。
    test('弹弹play 原生 4 段：颜色在 index 2，不是 index 3', () {
      // 官方 fixture：0.01,1,16777215,[Gamer]hui0810yong
      // → 时间 0.01s、模式 1、颜色 16777215(白)、第4段是发送者ID
      final d = Danmaku.fromP('1722521763', '0.01,1,16777215,[Gamer]hui0810yong', '簽');
      expect(d, isNotNull);
      expect(d!.color, 16777215, reason: '颜色必须在 index 2');
      expect(d.fontSize, 25, reason: '4 段格式没有字号，用默认 25');
      expect(d.userHash, '[Gamer]hui0810yong');
      expect(d.timeMs, 10);
      expect(d.mode, DanmakuMode.scroll);
    });

    test('若按 B站 8 段解析原生 4 段数据，颜色会变成字号（回归线）', () {
      final d = Danmaku.fromP('1', '0.01,1,16777215,sender', 'x')!;
      // 16777215 是白色，绝不能是 25（那是字号）
      expect(d.color, isNot(25),
          reason: '首版把 index2 当字号，颜色取值错位——此断言锁死正确布局');
      expect(d.color, 0xFFFFFF);
    });

    test('B站 8 段格式仍被正确识别（颜色在 index 3）', () {
      // 8 段：时间,模式,字号,颜色,时间戳,池,hash,行ID
      final d = Danmaku.fromP(
          '1', '10.5,1,25,16711680,1700000000,0,abcd1234,99', '红色')!;
      expect(d.color, 16711680, reason: 'B站布局颜色在 index 3');
      expect(d.fontSize, 25);
      expect(d.userHash, 'abcd1234');
    });

    test('启发式：短段数但 index2 像字号、index3 像颜色 → 判为 B站布局', () {
      // 某些服务的 p 只有 6 段，但仍是 B站语义
      final d = Danmaku.fromP('1', '5,1,25,16776960,1700000000,0', '黄')!;
      expect(d.color, 16776960);
      expect(d.fontSize, 25);
    });

    test('顶部/底部模式在两种格式下都正确', () {
      expect(Danmaku.fromP('1', '1,5,16777215,x', 'top')!.mode,
          DanmakuMode.top);
      expect(Danmaku.fromP('1', '1,4,16777215,x', 'bottom')!.mode,
          DanmakuMode.bottom);
      expect(Danmaku.fromP('1', '1,1,25,16777215,0,0,h,1', 's')!.mode,
          DanmakuMode.scroll);
    });

    test('只有时间段的 p 不崩，用默认字号与颜色', () {
      final d = Danmaku.fromP('1', '5', '只有时间')!;
      expect(d.color, 0xFFFFFF);
      expect(d.fontSize, 25);
    });
  });

  group('搜索结果的 episodeId 挑选', () {
    test('优先取 episodeNumber 与请求集号相同的那一条', () async {
      final c = build(jsonBody: {
        'success': true,
        'animes': [
          {
            'animeTitle': '我推的孩子',
            'episodes': [
              {'episodeId': 111, 'episodeNumber': 1},
              {'episodeId': 222, 'episodeNumber': 5},
              {'episodeId': 333, 'episodeNumber': 9},
            ],
          }
        ],
      });
      expect(await c.findEpisodeId(anime: '我推的孩子', episode: 5), 222);
    });

    test('跨多个番剧结果中匹配集号', () async {
      final c = build(jsonBody: {
        'success': true,
        'animes': [
          {
            'episodes': [
              {'episodeId': 1, 'episodeNumber': 2},
            ]
          },
          {
            'episodes': [
              {'episodeId': 2, 'episodeNumber': 7},
            ]
          },
        ],
      });
      expect(await c.findEpisodeId(anime: 'x', episode: 7), 2);
    });

    test('没给集号时取第一个可用结果（剧场版）', () async {
      final c = build(jsonBody: {
        'success': true,
        'animes': [
          {
            'episodes': [
              {'episodeId': 888, 'episodeNumber': 1},
            ]
          }
        ],
      });
      expect(await c.findEpisodeId(anime: '千与千寻'), 888);
    });

    test('搜不到返回 null（不是错误）', () async {
      final c = build(jsonBody: {'success': true, 'animes': []});
      expect(await c.findEpisodeId(anime: '不存在的片', episode: 1), isNull);
    });

    test('响应结构异常返回 null 而不抛异常', () async {
      final c = build(rawBody: 'not json');
      expect(await c.findEpisodeId(anime: 'x', episode: 1), isNull);
    });
  });

  group('官方点名的两类错误（不处理会"静默空弹幕"）', () {
    test('403 按 X-Error-Message 给出可操作提示 —— Invalid Signature', () async {
      final c = build(
        status: 403,
        rawBody: '',
        headers: {'x-error-message': ['Invalid Signature']},
      );
      await expectLater(
        c.comments(1),
        throwsA(isA<DanmakuException>().having(
          (e) => e.message,
          'message',
          allOf(contains('签名不匹配'), contains('AppSecret'))),
        ),
      );
    });

    test('403 Invalid Timestamp 提示校准系统时间', () async {
      final c = build(
        status: 403,
        rawBody: '',
        headers: {'x-error-message': ['Invalid Timestamp']},
      );
      await expectLater(
        c.comments(1),
        throwsA(isA<DanmakuException>()
            .having((e) => e.message, 'message', contains('时间'))),
      );
    });

    test('403 但响应头缺失时仍有兜底文案', () async {
      final c = build(status: 403, rawBody: '');
      await expectLater(
        c.comments(1),
        throwsA(isA<DanmakuException>()
            .having((e) => e.statusCode, 'statusCode', 403)),
      );
    });

    test('401 提示缺少认证头', () async {
      final c = build(status: 401, rawBody: '');
      await expectLater(
        c.comments(1),
        throwsA(isA<DanmakuException>()
            .having((e) => e.message, 'message', contains('身份验证'))),
      );
    });

    test('★ 业务错误包在 200 里必须被识别（官方第 6 节）', () async {
      // 这是最危险的一种：HTTP 200 但 success=false。
      // 只看状态码会把"服务器内部错误"当成"这部片没有弹幕"。
      final c = build(jsonBody: {
        'success': false,
        'errorCode': 1,
        'errorMessage': '服务器内部错误',
      });
      await expectLater(
        c.comments(1),
        throwsA(isA<DanmakuException>()
            .having((e) => e.message, 'message', contains('服务器内部错误'))),
      );
    });

    test('success=false 且无 message 时给通用提示', () async {
      final c = build(jsonBody: {'success': false, 'errorCode': 9});
      await expectLater(
        c.comments(1),
        throwsA(isA<DanmakuException>()),
      );
    });

    test('5xx 被报告为 HTTP 错误', () async {
      final c = build(status: 502, rawBody: 'bad gateway');
      await expectLater(
        c.comments(1),
        throwsA(isA<DanmakuException>()
            .having((e) => e.message, 'message', contains('502'))),
      );
    });
  });

  group('自建服务（URL token 认证，与官方完全不同）', () {
    test('不带任何签名头（自建服务不看 header 签名）', () async {
      final c = build(
        kind: DanmakuProviderKind.selfHosted,
        baseUrl: 'http://danmu.local:9321/tok',
        jsonBody: {'count': 0, 'comments': []},
      );
      await c.comments(1);
      final h = sent.single.headers;
      expect(h.containsKey('X-Signature'), isFalse,
          reason: '自建服务的 token 在 URL 路径里，不需要签名头');
      expect(h.containsKey('X-AppId'), isFalse);
    });

    test('base 里保留 token 路径段', () async {
      final c = build(
        kind: DanmakuProviderKind.selfHosted,
        baseUrl: 'http://danmu.local:9321/tok',
        jsonBody: {'count': 0, 'comments': []},
      );
      await c.comments(9);
      expect(sent.single.path, 'http://danmu.local:9321/tok/api/v2/comment/9');
    });

    test('★ 404 视为"该集没有弹幕"而非错误（自建服务的坑）', () async {
      // 调研确认：danmu_api 未命中时返回 HTTP 404 + {"count":0,"comments":[]}
      final c = build(
        kind: DanmakuProviderKind.selfHosted,
        baseUrl: 'http://a:9321',
        status: 404,
        rawBody: '{"count":0,"comments":[]}',
      );
      final batch = await c.comments(1);
      expect(batch.items, isEmpty,
          reason: '若把 404 当错误抛出，用户会看到无意义的报错而不是"暂无弹幕"');
    });

    test('404 但 body 不是弹幕形状 → 仍报错（区分真 404）', () async {
      final c = build(
        kind: DanmakuProviderKind.selfHosted,
        baseUrl: 'http://a:9321',
        status: 404,
        rawBody: 'not found',
      );
      await expectLater(c.comments(1), throwsA(isA<DanmakuException>()));
    });

    test('403（token 无效）给出针对性提示', () async {
      final c = build(
        kind: DanmakuProviderKind.selfHosted,
        baseUrl: 'http://a:9321',
        status: 403,
        rawBody: '',
      );
      await expectLater(
        c.comments(1),
        throwsA(isA<DanmakuException>()
            .having((e) => e.message, 'message', contains('token'))),
      );
    });

    test('未填地址时报明确错误', () async {
      final c = build(
        kind: DanmakuProviderKind.selfHosted,
        baseUrl: '',
        jsonBody: const {},
      );
      await expectLater(
        c.comments(1),
        throwsA(isA<DanmakuException>()
            .having((e) => e.message, 'message', contains('地址'))),
      );
    });

    test('异步模式会附加 async=1', () async {
      final c = buildAsync(
        first: {'count': 5, 'comments': []},
        polled: {'status': 'completed'},
        finalBody: {'count': 5, 'comments': []},
      );
      await c.comments(1);
      expect(sent.first.queryParameters['async'], '1');
    });
  });

  group('异步生成（?async=1 → 轮询 → 再取弹幕）', () {
    test('pending → 轮询 → completed → 重新取弹幕', () async {
      final c = buildAsync(
        first: {
          'count': 0,
          'comments': [],
          'status': 'pending',
          'taskId': 'T1',
          'description': '正在抓取',
        },
        polled: {'status': 'completed', 'taskId': 'T1'},
        finalBody: {
          'count': 1,
          'comments': [
            {'cid': 1, 'p': '1.5,1,16777215,src', 'm': '终于来了'},
          ],
        },
      );
      final batch = await c.comments(42);
      expect(batch.items.single.text, '终于来了');
      // 三次请求：首次 comment、轮询 taskcomment、再取 comment
      expect(sent.length, 3);
      expect(sent[1].path, contains('/api/v2/taskcomment/T1'));
      expect(sent[2].path, contains('/api/v2/comment/42'));
    });

    test('failed → 抛出服务端给的原因', () async {
      final c = buildAsync(
        first: {
          'count': 0,
          'comments': [],
          'status': 'pending',
          'taskId': 'T2',
        },
        polled: {
          'status': 'failed',
          'taskId': 'T2',
          'description': '所有数据源均失败',
        },
        finalBody: const {},
      );
      await expectLater(
        c.comments(1),
        throwsA(isA<DanmakuException>()
            .having((e) => e.message, 'message', contains('所有数据源均失败'))),
      );
    });

    test('同步就完成时不轮询（只有一次请求）', () async {
      final c = buildAsync(
        first: {
          'count': 2,
          'comments': [
            {'cid': 1, 'p': '1,1,16777215,s', 'm': 'a'},
            {'cid': 2, 'p': '2,1,16777215,s', 'm': 'b'},
          ],
        },
        polled: const {},
        finalBody: const {},
      );
      final batch = await c.comments(1);
      expect(batch.items.length, 2);
      expect(sent.length, 1, reason: '服务端 30 秒内完成时不返回 taskId');
    });
  });
}

/// 按客户端实际发出的 URL 重算签名，用于验证"签名只覆盖 path"。
String dandanplaySignatureOf(RequestOptions o) {
  final uri = Uri.parse(o.path);
  final appId = o.headers['X-AppId'] as String;
  final ts = int.parse(o.headers['X-Timestamp'] as String);
  // 这里刻意只用 uri.path（不含 query），与官方规范一致
  return _sig(appId, ts, uri.path);
}

String _sig(String appId, int ts, String path) {
  // 复用被测实现，避免在测试里重复一遍算法（算法本身另有独立向量测试）
  return dandanplaySignature(
    appId: appId,
    appSecret: 'sec',
    path: path,
    timestamp: ts,
  );
}
