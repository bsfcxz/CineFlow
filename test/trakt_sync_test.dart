// ══════════════════════════════════════════════════════════════════════
//  Trakt **播放同步** 的单元测试（契约守卫）
// ══════════════════════════════════════════════════════════════════════
//
// ## 为什么必须测（这里的错**不会报错**，只会静默失效）
// | 错误 | 现象 |
// |---|---|
// | 剧集 ids 里混进 `tmdb` | 服务端 **400/422**，但契约说 episode 只支持 trakt/tvdb |
// | `progress` 传 0–1 而不是 0–100 | 服务端视为 0.x% ⇒ **被当成 <1% 忽略**（422） |
// | 把 409/422 当异常 | 重播同一集时日志充满假错误 |
//
// ## 契约来源（权威）
// `trakt/trakt-api` 的 `projects/api/src/contracts/`：
// ```ts
// episodeIdsRequestSchema = union([{ trakt }, { tvdb }])          // 无 tmdb
// movieIdsRequestSchema   = union([{trakt},{slug},{imdb},{tmdb}])
// scrobble body: { progress: float(0-100), episode?: {ids}, movie?: {...} }
// /sync/playback resp: [{ progress: float(0-100), paused_at, type, ... }]
// ```
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/data/trakt_client.dart';

void main() {
  group('TraktIds · 契约要求的 id 筛选', () {
    test('★★★ 剧集模式必须**丢掉 tmdb**（契约里 episode ids 没有 tmdb）', () {
      const ids = TraktIds(trakt: 123, tmdb: 456, tvdb: 789);
      final ep = ids.toJson(episodeMode: true);
      expect(ep.containsKey('tmdb'), isFalse,
          reason: '★★★ 契约：episodeIdsRequestSchema 只接受 trakt/tvdb。'
              '混进 tmdb 会被服务端拒绝，且**错误信息不指出是哪个字段**');
      expect(ep['trakt'], 123);
      expect(ep['tvdb'], 789);
      expect(ep.containsKey('imdb'), isFalse);
      expect(ep.containsKey('slug'), isFalse);
    });

    test('★★ 电影模式保留 tmdb（契约支持）', () {
      const ids = TraktIds(trakt: 1, tmdb: 2);
      final mv = ids.toJson();
      expect(mv['trakt'], 1);
      expect(mv['tmdb'], 2);
    });

    test('★★★ usableForEpisode：只有 tmdb 时**不可用于剧集**', () {
      const onlyTmdb = TraktIds(tmdb: 456);
      expect(onlyTmdb.usableForEpisode, isFalse,
          reason: '★★★ 这是最危险的组合：我们详情页手里常常只有 tmdb，'
              '直接拿去 scrobble 必被拒 ⇒ 必须先解析出 trakt/tvdb id');
      expect(const TraktIds(trakt: 1).usableForEpisode, isTrue);
      expect(const TraktIds(tvdb: 1).usableForEpisode, isTrue);
      expect(const TraktIds().usableForEpisode, isFalse);
    });

    test('空 ids 序列化为空 map（不产生 `"tmdb": null` 这类脏字段）', () {
      expect(const TraktIds().toJson(), isEmpty);
      expect(const TraktIds().toJson(episodeMode: true), isEmpty);
    });
  });

  group('TraktScrobbleResult · 409/422 是**业务语义**不是错误', () {
    test('★★★ 409（重复）不算失败', () {
      const r = TraktScrobbleResult(statusCode: 409, duplicate: true);
      expect(r.ok, isFalse, reason: 'ok 只对 201 为真');
      expect(r.duplicate, isTrue,
          reason: '★★★ 409 是"刚 scrobble 过"的防重复 —— 重播同一集时**必然**出现，'
              '调用方必须当正常分支处理（否则日志全是假错误）');
      expect(r.error, isNull);
    });

    test('★★★ 422（progress<1%）不算失败', () {
      const r = TraktScrobbleResult(statusCode: 422, tooShort: true);
      expect(r.tooShort, isTrue,
          reason: '★★★ 契约：<1% 会被服务端忽略并返回 422。'
              '刚点开就退出**必然**触发');
      expect(r.error, isNull);
    });

    test('★★ 服务端可能把 stop 降级为 pause（progress 1%–79%）', () {
      // 契约原文：If the progress is between 1% and 79%, it will be treated
      // as a *pause* and the `action` will be set to **pause**
      const r = TraktScrobbleResult(
          statusCode: 201, ok: true, serverAction: 'pause');
      expect(r.serverAction, 'pause',
          reason: '★★ 所以 UI/日志要用 serverAction 而不是"我请求了什么"');
    });
  });

  group('TraktPlaybackItem · /sync/playback 响应解析', () {
    test('★★★ progress 是 **0-100 百分比**（不是 0-1）', () {
      final it = TraktPlaybackItem.fromJson({
        'progress': 42.5,
        'paused_at': '2026-10-14T12:00:00.000Z',
        'id': 1,
        'type': 'episode',
        'episode': {'season': 2, 'number': 7, 'title': 'E7',
                    'ids': {'trakt': 999}},
        'show': {'ids': {'trakt': 111, 'tmdb': 222}},
      });
      expect(it, isNotNull);
      expect(it!.progress, 42.5,
          reason: '★★★ 契约是 float(0-100)。当成 0-1 会让"续播"跳到 0.4% 处');
      expect(it.season, 2);
      expect(it.number, 7);
      expect(it.traktShowId, 111);
      expect(it.traktEpisodeId, 999);
      expect(it.tmdbShowId, 222);
      expect(it.type, 'episode');
    });

    test('★ 缺 progress 时返回 null（防御式，不抛）', () {
      expect(TraktPlaybackItem.fromJson({'type': 'episode'}), isNull);
      expect(TraktPlaybackItem.fromJson(const {}), isNull);
    });

    test('★ 字段缺失/类型不符时不崩（服务端字段可能增删）', () {
      final it = TraktPlaybackItem.fromJson({
        'progress': 10,          // int 而非 double
        'paused_at': 12345,      // 非字符串
        'type': 42,              // 非字符串
      });
      expect(it, isNotNull);
      expect(it!.progress, 10.0, reason: 'int 也要能收（num 统一转 double）');
      expect(it.pausedAt, '', reason: '类型不符时回退空串，不抛');
      expect(it.type, 'episode', reason: '未知类型回退 episode（占多数）');
    });

    test('★ 契约示例：episode 的 ids **没有 tmdb**（解析不依赖它）', () {
      final it = TraktPlaybackItem.fromJson({
        'progress': 50,
        'paused_at': '2026-10-14T12:00:00Z',
        'type': 'episode',
        'episode': {'season': 1, 'number': 1, 'ids': {'trakt': 5}},
        'show': {'ids': {'trakt': 9}},
      });
      expect(it!.traktEpisodeId, 5);
      expect(it.tmdbShowId, isNull, reason: 'show 只给 trakt 时 tmdb 应为 null');
    });
  });

  group('TraktScrobbleAction · 路径与契约一致', () {
    test('★ 三个动作的路径段就是字面量名', () {
      expect(TraktScrobbleAction.start.path, 'start');
      expect(TraktScrobbleAction.pause.path, 'pause');
      expect(TraktScrobbleAction.stop.path, 'stop');
    });
  });

  group('TraktHistoryResult', () {
    test('★ added 从响应解析（契约：{added:{movies,episodes}}）', () {
      const r = TraktHistoryResult(ok: true, added: 3, statusCode: 201);
      expect(r.ok, isTrue);
      expect(r.added, 3);
    });
  });
}
