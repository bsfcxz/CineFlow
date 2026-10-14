/// `TraktShow` 解析的单测。
///
/// ## 为什么必须有（本仓库验证纪律 §8.1）
/// > 纯逻辑改动请补单元测试，不要只靠真机点击。
///
/// `parseTraktShow` / `parseTraktSearchId` 是**唯一有分支**的地方
/// （`extended=full` 的字段缺失、类型异常、数组形状），正是最容易回归的部分。
///
/// ## ★ fixture 全部来自**真实响应**（2026-10-14 实测，非编造）
/// 下面三段 JSON 是本机 curl 的实际输出（脱敏后原样保留结构）：
library;

import 'package:cineflow/data/trakt_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('★★★ parseTraktShow：从真实响应解析（fixture 为实测数据）', () {
    /// 实测：`GET /shows/1388?extended=full`（节选解析用到的字段）
    Map<String, dynamic> breakingBad() => {
          'title': 'Breaking Bad',
          'year': 2008,
          'status': 'ended',
          'aired_episodes': 62,
          'network': 'AMC',
          'first_aired': '2008-01-21T02:00:00.000Z',
          'last_aired': '2013-09-30T01:00:00.000Z',
          'airs': {
            'day': 'Sunday',
            'time': '21:00',
            'timezone': 'America/New_York',
          },
          'ids': {'trakt': 1388, 'tmdb': 1396, 'slug': 'breaking-bad'},
        };

    test('① 完整响应：状态 / 集数 / 平台 / 时间 全部解析出来', () {
      final r = parseTraktShow(breakingBad());
      expect(r, isNotNull);
      expect(r!.title, 'Breaking Bad');
      expect(r.traktId, 1388, reason: 'ids.trakt');
      expect(r.year, 2008);
      expect(r.status, 'ended', reason: '**未转中文** —— 交给 statusCnOf 统一处理');
      expect(r.airedEpisodes, 62);
      expect(r.network, 'AMC');
      expect(r.lastAired, '2013-09-30T01:00:00.000Z');
    });

    test('② ★ 不带 `extended=full` 时 status/network 为 null（实测）', () {
      // 实测：`GET /shows/1388`（无 extended）→ status=null、airs=null
      final r = parseTraktShow({
        'title': 'Breaking Bad',
        'aired_episodes': 62, // ← 这个仍有值
        'status': null, // ← 实测就是 null
        'network': null,
        'ids': {'trakt': 1388},
      });
      expect(r, isNotNull);
      expect(r!.status, isNull, reason: '不带 extended 时确实没有 ⇒ 不是 bug');
      expect(r.network, isNull);
      expect(r.airedEpisodes, 62, reason: '**aired_episodes 不带 extended 也有**');
    });

    test('③ 缺 title 时退回 ids.slug（实测响应里两者都有）', () {
      final r = parseTraktShow({
        'ids': {'trakt': 1388, 'slug': 'breaking-bad'},
        'status': 'ended',
      });
      expect(r, isNotNull);
      expect(r!.title, 'breaking-bad');
    });

    test('④ 连标题都没有 ⇒ null（数据不可用）', () {
      expect(parseTraktShow({}), isNull);
      expect(parseTraktShow({'status': 'ended'}), isNull,
          reason: '没标题 ⇒ 无法展示也无法校验 ⇒ 视为不可用');
    });

    test('⑤ 字段类型异常时不崩（第三方站点不可信）', () {
      final r = parseTraktShow({
        'title': 'X',
        'year': '2008', // 字符串形式
        'aired_episodes': '62', // 字符串形式
        'status': 42, // 类型错
        'network': <String>[], // 类型错
        'ids': {'trakt': '1388'}, // 字符串形式
      });
      expect(r, isNotNull);
      expect(r!.year, 2008, reason: '字符串数字应能转换');
      expect(r.airedEpisodes, 62);
      expect(r.traktId, 1388);
      expect(r.status, isNull, reason: '非字符串 ⇒ null（不硬转）');
      expect(r.network, isNull);
    });

    test('⑥ ids 结构不对时不崩', () {
      final r = parseTraktShow({'title': 'X', 'ids': 'not-a-map'});
      expect(r, isNotNull);
      expect(r!.traktId, isNull);
    });
  });

  group('★★★ parseTraktSearchId：从 /search/tmdb 取 traktId', () {
    /// 实测：`GET /search/tmdb/210905?type=show` 的**完整响应**（254 字节）
    List<dynamic> physical100() => [
          {
            'show': {
              'ids': {
                'imdb': 'tt25274446',
                'plex': {'guid': '6330a59224aad53366643ac0',
                         'slug': 'physical-100-1'},
                'slug': 'physical-100',
                'tmdb': 210905,
                'tvdb': 424941,
                'trakt': 201203,
              },
              'year': 2023,
              'title': 'Physical: 100',
              'aired_episodes': 18,
            },
            'type': 'show',
            'score': 100,
          },
        ];

    test('① 真实响应 → traktId=201203（体能之巅）', () {
      expect(parseTraktSearchId(physical100()), 201203);
    });

    test('② ⚠️ search 响应**不含 status**（所以必须再查详情）', () {
      final arr = physical100();
      final show = (arr.first as Map)['show'] as Map;
      expect(show.containsKey('status'), isFalse,
          reason: '实测确认：search 不给 status ⇒ 代码里必须两次请求');
      expect(show['aired_episodes'], 18, reason: '但给了已播集数');
    });

    test('③ 空/异常形状 ⇒ null（不崩）', () {
      expect(parseTraktSearchId(null), isNull);
      expect(parseTraktSearchId([]), isNull, reason: '空数组 = 查不到');
      expect(parseTraktSearchId('not-a-list'), isNull);
      expect(parseTraktSearchId([{'show': 'not-a-map'}]), isNull);
      expect(parseTraktSearchId([{'show': {'ids': 'not-a-map'}}]), isNull);
      expect(parseTraktSearchId([{'no-show-key': 1}]), isNull);
    });

    test('④ trakt 为字符串形态也能取到', () {
      expect(parseTraktSearchId([
        {'show': {'ids': {'trakt': '201203'}}}
      ]), 201203);
    });
  });

  group('★ plausiblyMatches：错配校验（实测踩到过）', () {
    test('年号相同 ⇒ 通过（强信号）', () {
      const s = TraktShow(title: 'Physical: 100', year: 2023);
      expect(s.plausiblyMatches(cnTitle: '体能之巅：百人大挑战', expectYear: 2023),
          isTrue);
    });

    test('★ 错配必须被挡下（实测：仙逆 tmdb=229977 → 陸小鳳之鳳舞九天）', () {
      const s = TraktShow(title: '陸小鳳之鳳舞九天', year: 1979);
      expect(
        s.plausiblyMatches(cnTitle: '仙逆', expectYear: 2023),
        isFalse,
        reason: '年号不符且无共同拉丁片段 ⇒ **不采信**（宁可不用，也别盖错状态）',
      );
    });

    test('拉丁片段重合 ⇒ 通过（中文名里带拼音/英文时）', () {
      // ⚠️ 我第一版这个用例写错了：假设 `A Record of a Mortal` 含 `fan`，
      //    实际不含 ⇒ 报 Expected true / Actual false。
      //    **代码行为是对的**（确实没有共同片段），错的是我的期望。
      // ⇒ 改成真实会重合的形态：Trakt 的 slug/标题常含**音译拼音**。
      const s = TraktShow(title: 'Fanren Xiu Xian Zhuan', year: 2020);
      expect(
        s.plausiblyMatches(cnTitle: 'Fanren 修仙传', expectYear: 2026),
        isTrue,
        reason: '有共同拉丁片段 ⇒ 宽松通过',
      );
      // 反向：真没有共同片段时**不该**通过
      const s2 = TraktShow(title: 'A Record of a Mortal', year: 2020);
      expect(
        s2.plausiblyMatches(cnTitle: '凡人修仙传', expectYear: 2026),
        isFalse,
        reason: '⭐ 实测的真实情形：中文名与英文名常无共同拉丁片段 ⇒ '
            '这种校验**只能靠年号**，靠不住时保守判否（宁可不用 Trakt）',
      );
    });

    test('信息不足 ⇒ 不通过（保守）', () {
      const s = TraktShow(title: 'X');
      expect(s.plausiblyMatches(cnTitle: null, expectYear: null), isFalse);
      expect(s.plausiblyMatches(cnTitle: '仙逆', expectYear: null), isFalse,
          reason: '年号未知且无拉丁片段 ⇒ 保守判否');
    });
  });
}
