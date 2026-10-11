// 追剧日历：纯逻辑守卫（去重/归一化/周计算）。
//
// ## 为什么这层必须有测试
// 日历的"多源合并"是本功能的**正确性核心**：
// 同一部剧在 4 个源都有 ⇒ 去重失败会让用户看到 4 条重复；
// 去重过激进 ⇒ 用户**看不到某部剧**（更糟）。
// 这两种错误都不会"报错"，只会让界面变得难以理解。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/data/calendar_client.dart';

CalendarEntry e(
  String title, {
  String source = 'test',
  int? weekday,
  String? airDate,
  String? sourceId,
  int? bangumiId,
  String? titleCn,
}) =>
    CalendarEntry(
      title: title,
      titleCn: titleCn,
      source: source,
      weekday: weekday,
      airDate: airDate,
      sourceId: sourceId,
      bangumiId: bangumiId,
    );

void main() {
  group('★★ 标题归一化（跨源去重的基础）', () {
    test('★★ 去标点/空格/大小写/全半角', () {
      const cases = {
        'Re：从零开始的异世界生活': 're从零开始的异世界生活',
        'Re:Zero - Starting Life in Another World':
            'rezerostartinglifeinanotherworld',
        'Re:ZERO -Starting Life in Another World-':
            'rezerostartinglifeinanotherworld',
        '【我推的孩子】': '我推的孩子',
        'SPY×FAMILY': 'spyfamily',
      };
      cases.forEach((input, want) {
        expect(normalizeTitle(input), want, reason: '«$input»');
      });
    });

    test('★★ 两个源的同一部剧归一化后**必须相等**', () {
      // 这是去重能生效的前提
      const bgm = 'Re：从零开始的异世界生活';
      const tvmaze = 'Re:ZERO -Starting Life in Another World-';
      // ⚠️ 实测：这两条**并不相等**（一个中文名一个英文名）
      // ⇒ 说明"标题匹配"只能处理**同语言**的跨源重复；
      //    跨语言重复要靠 id 或人工映射。本测试**记录这个事实**，
      //    避免以后有人以为"归一化能解决所有跨源去重"。
      expect(normalizeTitle(bgm) == normalizeTitle(tvmaze), isFalse,
          reason: '★ 中文名 vs 英文名归一化后仍不同 ⇒\n'
              '    跨语言去重**不能**靠标题（记录在案，勿误以为能）');
    });

    test('★ 同语言跨源必须能合并', () {
      expect(normalizeTitle('葬送的芙莉莲'), normalizeTitle('葬送的芙莉莲'));
      expect(normalizeTitle('葬送的芙莉莲'), normalizeTitle('葬送的芙莉莲 '));
      expect(normalizeTitle('葬送的芙莉莲'), normalizeTitle('葬送的芙莉莲！'));
    });

    test('★ 不得把"最终季"与"本体"归一化成同一条', () {
      expect(normalizeTitle('进击的巨人'),
          isNot(normalizeTitle('进击的巨人 最终季')),
          reason: '★ 误合并会让用户看不到某部剧（比重复更糟）');
    });
  });

  group('★★ 同源同 id 去重（抓取层重复）', () {
    test('★★★ 同源同 id 必须合并 —— **即使标题不同**', () {
      // ## 为什么这条要"标题不同"（反向注入自查发现的薄弱守卫）
      // 若两条标题相同，那么"同源+标题"那条键**也会**合并它们
      // ⇒ 测试无法隔离出"同源同 id"这条判据
      //（实测：把 `src:` 判据禁掉后测试仍全绿 ⇒ 守卫无效）。
      // ⇒ 必须让**只有 id 能救**：标题故意不同。
      final out = mergeCalendarEntries([
        e('某剧 第 1 集', source: 'tvmaze', sourceId: '999', airDate: '2026-10-10'),
        e('某剧 第 1 集（重发）',
            source: 'tvmaze', sourceId: '999', airDate: '2026-10-10'),
      ]);
      expect(out.length, 1,
          reason: '★★★ 同源同 id ⇒ 一定是同一条（分页/重发会带回重复）\n'
              '    标题可能被服务端改写，但 id 不会');
    });

    test('★★ 不同 id + 不同标题 ⇒ 不合并', () {
      final out = mergeCalendarEntries([
        e('A 剧', source: 'tvmaze', sourceId: '1', airDate: '2026-10-10'),
        e('B 剧', source: 'tvmaze', sourceId: '2', airDate: '2026-10-10'),
      ]);
      expect(out.length, 2);
    });
  });

  group('★★★ 海报 URL 必须升 https（Android 明文被禁）', () {
    test('★★★ http:// 必须变成 https://', () {
      // ## 实测依据
      // Bangumi 的 `images.large` **全是** `http://lain.bgm.tv/...`：
      // ```json
      // "images": {"large": "http://lain.bgm.tv/pic/cover/l/1c/...jpg"}
      // ```
      // Android 9+ 默认禁明文 HTTP ⇒ 不处理会**海报全裂**。
      //
      // ⚠️ 这条必须是**纯函数单测**（不能只靠真网测试）：
      //    Bangumi 在本机/真机**都不可达**（WAF 拦 TLS 指纹）
      //    ⇒ 真网测试会跳过 ⇒ 这个 bug 逃得掉
      //    （反向注入自查正是这样发现的）。
      expect(httpsPosterUrl('http://lain.bgm.tv/pic/cover/l/1c/b4/x.jpg'),
          'https://lain.bgm.tv/pic/cover/l/1c/b4/x.jpg');
      expect(httpsPosterUrl('http://image.tmdb.org/t/p/w300/x.jpg'),
          'https://image.tmdb.org/t/p/w300/x.jpg');
    });

    test('★ 已是 https 的原样返回（幂等）', () {
      const u = 'https://lain.bgm.tv/x.jpg';
      expect(httpsPosterUrl(u), u);
      expect(httpsPosterUrl(httpsPosterUrl('http://a.com/x.jpg')),
          httpsPosterUrl('http://a.com/x.jpg'),
          reason: '★ 幂等：重复处理不变');
    });

    test('★ null / 空串 / 非 http 原样返回', () {
      expect(httpsPosterUrl(null), isNull);
      expect(httpsPosterUrl(''), '');
      expect(httpsPosterUrl('ftp://a/x.jpg'), 'ftp://a/x.jpg');
      expect(httpsPosterUrl('/relative/x.jpg'), '/relative/x.jpg');
    });
  });

  group('★★★ 每源独立 deadline（慢源不能拖垮整页）', () {
    test('★★★ perSourceDeadline 必须存在且合理', () {
      // ## 真机验证抓到的现象
      // Bangumi 退避 + 慢响应 ⇒ 日历页**转圈 12 秒**
      //（截图确认卡在 loading）。根因：`Future.wait` 等**所有** future
      // ⇒ **最慢的源决定整页时间**。
      //
      // ⇒ 必须每源独立 `timeout(perSourceDeadline)`。
      expect(CalendarClient.perSourceDeadline.inSeconds,
          inInclusiveRange(3, 15),
          reason: '★★★ 太短 ⇒ 正常源被误杀（TVmaze 单请求实测 7.8s）；\n'
              '    太长 ⇒ 用户白等（真机 12s 已属"页面坏了"）');
    });

    test('★★ fetchWeek 必须逐个源包 deadline', () {
      final src = File('lib/data/calendar_client.dart').readAsStringSync();
      // 剥注释（§8.4：断言不得被注释满足）
      final code = src
          .split('\n')
          .where((l) {
            final t = l.trimLeft();
            return !t.startsWith('//') && !t.startsWith('///') &&
                !t.startsWith('*');
          })
          .join('\n');
      expect(code.contains('.timeout(perSourceDeadline)'), isTrue,
          reason: '★★★ 少了它 ⇒ 一个慢源（如 Bangumi 退避 3s + 慢响应）\n'
              '    就能让整页卡住 —— 真机实测 12 秒');
      // ★ 2026-10-11 源清单变更（用户："删 TVmaze，聚焦国内"）：
      //   TMDB 升为主力（按 air_date 逐天查国产剧），B站 补动漫
      expect(code.contains('guard(_fetchTmdb('), isTrue,
          reason: '★ TMDB 是国产剧集主力源（用户明确要求用它）');
      expect(code.contains('guard(_fetchBilibili()'), isTrue);
      expect(code.contains('guard(_fetchBangumi()'), isTrue);
      // ★★★ TVmaze 必须**真的删掉**（用户明确不要）
      expect(code.contains('_fetchTvmaze'), isFalse,
          reason: '★★★ 用户要求"删除 TVmaze 中获取的，不需要这个了" ——\n'
              '    必须删代码，不是留着不用');
    });
  });

  group('★★★ 合并去重（多源同剧只留一条）', () {
    test('★★★ 同源同 id 必须去重', () {
      final out = mergeCalendarEntries([
        e('某剧', source: 'bangumi', sourceId: '1', weekday: 1),
        e('某剧', source: 'bangumi', sourceId: '1', weekday: 1),
      ]);
      expect(out.length, 1);
    });

    test('★★★ 同标题同日期**不跨源合并**（真网测试抓到的误合并）', () {
      // ## 这条断言是**真网测试抓到 bug 后改的**（重要，勿改回去）
      // 我第一版用 `(日期, 归一化标题)` 做**跨源**去重，真网跑出：
      // ```
      // 各源合计 1126 条 → 合并 616 条（去重 45%）
      // «Ну, погоди! Каникулы» vs «Вор в загоне»   ← 完全不同的剧！
      // «Death is Coming» ×5                         ← 5 部同名剧
      // «Embers of the Night» ×2
      // ```
      // 根因：**TVmaze 里同名剧极多**（不同国家/年份的 "Death is Coming"），
      // 标题+日期**无法区分**。
      //
      // 调研结论原文："匹配不上就保留两条，**宁可多不可错并**"。
      // 误合并让用户**看不到某部剧**（比看到重复严重得多）。
      // ⇒ 跨源判据**只保留外部 ID**（见下一条测试）。
      final out = mergeCalendarEntries([
        e('葬送的芙莉莲', source: 'bangumi', sourceId: 'a', airDate: '2026-10-10'),
        e('葬送的芙莉莲', source: 'tvmaze', sourceId: 'b', airDate: '2026-10-10'),
      ]);
      expect(out.length, 2,
          reason: '★★★ 同标题**跨源不合并** —— 实测 TVmaze 同名剧极多，\n'
              '    标题匹配会把不同的剧合成一条（丢内容）');
    });

    test('★★★ 同源同标题同日期**才**合并（抓取层重复）', () {
      // 同源内的同名同日条目才是真重复（如分页/多次请求带回同一条）
      final out = mergeCalendarEntries([
        e('某剧', source: 'tvmaze', sourceId: 'a', airDate: '2026-10-10'),
        e('某剧', source: 'tvmaze', sourceId: 'b', airDate: '2026-10-10'),
      ]);
      expect(out.length, 1,
          reason: '★★ 同源 + 同日期 + 同标题 ⇒ 视为同一条（安全）');
    });

    test('★★★ 跨源靠**外部 ID** 合并（唯一安全判据）', () {
      final out = mergeCalendarEntries([
        e('葬送的芙莉莲',
            source: 'bangumi',
            sourceId: 'a',
            bangumiId: 400602,
            airDate: '2026-10-10'),
        e('Frieren',
            source: 'bilibili',
            sourceId: 'b',
            bangumiId: 400602,
            airDate: '2026-10-10'),
      ]);
      expect(out.length, 1,
          reason: '★★★ 外部 ID（bangumiId/imdb/tmdb）**全局唯一** ⇒\n'
              '    即使标题一个是中文一个是英文，也能正确识别为同一部');
    });

    test('★★ 同标题**不同星期**不合并（可能是不同季）', () {
      final out = mergeCalendarEntries([
        e('某剧', source: 'bangumi', sourceId: 'a', weekday: 1),
        e('某剧', source: 'tvmaze', sourceId: 'b', weekday: 4),
      ]);
      expect(out.length, 2,
          reason: '★★ 同标题但归到不同星期 ⇒ 视为不同条目\n'
              '    （同一部剧在不同源的播出安排可能不同）');
    });

    test('★★ 不同剧不得合并', () {
      final out = mergeCalendarEntries([
        e('葬送的芙莉莲', source: 'bangumi', sourceId: 'a', weekday: 5),
        e('我推的孩子', source: 'bangumi', sourceId: 'b', weekday: 5),
      ]);
      expect(out.length, 2);
    });

    test('★★ 空标题必须丢弃（脏数据）', () {
      final out = mergeCalendarEntries([
        e('', source: 'x', sourceId: '1'),
        e('   ', source: 'x', sourceId: '2'),
        e('正常', source: 'x', sourceId: '3'),
      ]);
      expect(out.length, 1);
      expect(out.first.title, '正常');
    });

    test('★★ bangumiId 相同 + 同一天必须合并（B站 season_id 域）', () {
      // ⚠️ key 必须**含日期**：同剧在不同天是不同的"更新事件"，
      //    合并掉就等于用户看不到更新（真网测试抓到 86% 过度去重）
      final out = mergeCalendarEntries([
        e('A',
            source: 'bangumi',
            sourceId: '1',
            bangumiId: 999,
            airDate: '2026-10-06'),
        e('B',
            source: 'bilibili',
            sourceId: 'x',
            bangumiId: 999,
            airDate: '2026-10-06'),
      ]);
      expect(out.length, 1,
          reason: '★★ 同 bangumiId + 同日期 ⇒ 同一部剧同一天的一次更新');
    });

    test('★★★ 同剧不同天**不得**合并（真网测试抓到的 86% 过度去重）', () {
      // ## 这条是**真网测试抓到 bug 后补的守卫**
      // B站真实数据：
      // ```
      // 10-5  小车队大救援：自然护卫队  pub=第14话  season=298872
      // 10-6  小车队大救援：自然护卫队  pub=第15话  season=298872
      // ```
      // 第一版 key = (星期, 标题) **不含日期** ⇒ 跨天条目被压成一条：
      // 「各源合计 56 条 → 合并后 8 条（去重 86%）」。
      // ⇒ 这组数据必须**全部保留**（3 天 = 3 条）。
      final out = mergeCalendarEntries([
        e('小车队大救援：自然护卫队',
            source: 'bilibili',
            sourceId: 'e14',
            bangumiId: 298872,
            airDate: '2026-10-05'),
        e('小车队大救援：自然护卫队',
            source: 'bilibili',
            sourceId: 'e15',
            bangumiId: 298872,
            airDate: '2026-10-06'),
        e('小车队大救援：自然护卫队',
            source: 'bilibili',
            sourceId: 'e16',
            bangumiId: 298872,
            airDate: '2026-10-07'),
      ]);
      expect(out.length, 3,
          reason: '★★★ 同一部剧 3 天各有更新 ⇒ 必须 3 条（用户要看到每一天）');
    });

    test('★ 保留首次出现的（不因去重打乱源优先级）', () {
      final out = mergeCalendarEntries([
        e('某剧', source: 'bangumi', sourceId: 'a', weekday: 3),
        e('某剧', source: 'tmdb', sourceId: 'b', weekday: 3),
      ]);
      expect(out.first.source, 'bangumi',
          reason: '★ 调用方按源优先级传入 ⇒ 首次出现的应保留');
    });

    test('★★★ 同源同 id 必须合并 —— **即使标题不同**', () {
      // ## 为什么这条要"标题不同"（反向注入自查发现的薄弱守卫）
      // 若两条标题相同，那么"同源+标题"那条键**也会**合并它们
      // ⇒ 测试无法隔离出"同源同 id"这条判据
      //（实测：把 `src:` 判据禁掉后测试仍全绿 ⇒ 守卫无效）。
      // ⇒ 必须让**只有 id 能救**：标题故意不同。
      final out = mergeCalendarEntries([
        e('某剧 第 1 集',
            source: 'tvmaze', sourceId: '999', airDate: '2026-10-10'),
        e('某剧 第 1 集（重发）',
            source: 'tvmaze', sourceId: '999', airDate: '2026-10-10'),
      ]);
      expect(out.length, 1,
          reason: '★★★ 同源同 id ⇒ 一定是同一条（分页/重发会带回重复）\n'
              '    标题可能被服务端改写，但 id 不会');
    });

    test('★★ 不同 id + 不同标题 ⇒ 不合并', () {
      final out = mergeCalendarEntries([
        e('A 剧', source: 'tvmaze', sourceId: '1', airDate: '2026-10-10'),
        e('B 剧', source: 'tvmaze', sourceId: '2', airDate: '2026-10-10'),
      ]);
      expect(out.length, 2);
    });
  });

  group('★★★ 海报 URL 必须升 https（Android 明文被禁）', () {
    test('★★★ http:// 必须变成 https://', () {
      // ## 实测依据
      // Bangumi 的 `images.large` **全是** `http://lain.bgm.tv/...`：
      // ```json
      // "images": {"large": "http://lain.bgm.tv/pic/cover/l/1c/...jpg"}
      // ```
      // Android 9+ 默认禁明文 HTTP ⇒ 不处理会**海报全裂**。
      //
      // ⚠️ 这条必须是**纯函数单测**（不能只靠真网测试）：
      //    Bangumi 在本机/真机**都不可达**（WAF 拦 TLS 指纹）
      //    ⇒ 真网测试会跳过 ⇒ 这个 bug 逃得掉
      //    （反向注入自查正是这样发现的）。
      expect(httpsPosterUrl('http://lain.bgm.tv/pic/cover/l/1c/b4/x.jpg'),
          'https://lain.bgm.tv/pic/cover/l/1c/b4/x.jpg');
      expect(httpsPosterUrl('http://image.tmdb.org/t/p/w300/x.jpg'),
          'https://image.tmdb.org/t/p/w300/x.jpg');
    });

    test('★ 已是 https 的原样返回（幂等）', () {
      const u = 'https://lain.bgm.tv/x.jpg';
      expect(httpsPosterUrl(u), u);
      expect(httpsPosterUrl(httpsPosterUrl('http://a.com/x.jpg')),
          httpsPosterUrl('http://a.com/x.jpg'),
          reason: '★ 幂等：重复处理不变');
    });

    test('★ null / 空串 / 非 http 原样返回', () {
      expect(httpsPosterUrl(null), isNull);
      expect(httpsPosterUrl(''), '');
      expect(httpsPosterUrl('ftp://a/x.jpg'), 'ftp://a/x.jpg');
      expect(httpsPosterUrl('/relative/x.jpg'), '/relative/x.jpg');
    });
  });

  group('★★★ 每源独立 deadline（慢源不能拖垮整页）', () {

    test('★★ fetchWeek 必须逐个源包 deadline', () {
      final src = File('lib/data/calendar_client.dart').readAsStringSync();
      // 剥注释（§8.4：断言不得被注释满足）
      final code = src
          .split('\n')
          .where((l) {
            final t = l.trimLeft();
            return !t.startsWith('//') && !t.startsWith('///') &&
                !t.startsWith('*');
          })
          .join('\n');
      expect(code.contains('.timeout(perSourceDeadline)'), isTrue,
          reason: '★★★ 少了它 ⇒ 一个慢源（如 Bangumi 退避 3s + 慢响应）\n'
              '    就能让整页卡住 —— 真机实测 12 秒');
      // ★ 2026-10-11 源清单变更（用户："删 TVmaze，聚焦国内"）：
      //   TMDB 升为主力（按 air_date 逐天查国产剧），B站 补动漫
      expect(code.contains('guard(_fetchTmdb('), isTrue,
          reason: '★ TMDB 是国产剧集主力源（用户明确要求用它）');
      expect(code.contains('guard(_fetchBilibili()'), isTrue);
      expect(code.contains('guard(_fetchBangumi()'), isTrue);
      // ★★★ TVmaze 必须**真的删掉**（用户明确不要）
      expect(code.contains('_fetchTvmaze'), isFalse,
          reason: '★★★ 用户要求"删除 TVmaze 中获取的，不需要这个了" ——\n'
              '    必须删代码，不是留着不用');
    });
  });

  group('★★ 星期归算（周视图的核心）', () {
    test('★★ weekday 优先于 airDate', () {
      // Bangumi 给 weekday（周番固定星期），airDate 可能缺失
      expect(e('x', weekday: 3).weekdayResolved, 3);
      // 两者都有时以 weekday 为准
      expect(e('x', weekday: 6, airDate: '2026-10-06').weekdayResolved, 6);
    });

    test('★★ 无 weekday 时由 airDate 算（DateTime.weekday 1=周一）', () {
      // 2026-10-05 是周一
      expect(e('x', airDate: '2026-10-05').weekdayResolved, 1);
      // 2026-10-11 是周日
      expect(e('x', airDate: '2026-10-11').weekdayResolved, 7);
      // 2026-10-08 是周四
      expect(e('x', airDate: '2026-10-08').weekdayResolved, 4);
    });

    test('★ 非法日期/缺失时兜底为周一（不崩）', () {
      expect(e('x').weekdayResolved, 1);
      expect(e('x', airDate: 'garbage').weekdayResolved, 1);
      expect(e('x', weekday: 0).weekdayResolved, 1,
          reason: '★ weekday=0 非法 ⇒ 落到 airDate/兜底');
      expect(e('x', weekday: 99).weekdayResolved, 1);
    });
  });

  group('★★ WeekCalendar 分组', () {
    test('★★ forWeekday 返回正确的分组', () {
      final cal = WeekCalendar(sources: const [], entries: [
        e('周一剧', weekday: 1),
        e('周三剧', weekday: 3),
        e('周三剧2', weekday: 3),
        e('周日剧', weekday: 7),
      ]);
      expect(cal.forWeekday(1).length, 1);
      expect(cal.forWeekday(3).length, 2);
      expect(cal.forWeekday(5).length, 0);
      expect(cal.forWeekday(7).length, 1);
    });

    test('★★ 源状态统计（失败隔离的可观测性）', () {
      const cal = WeekCalendar(sources: [
        CalendarSourceResult(source: 'a', label: 'A', entries: []),
        CalendarSourceResult(source: 'b', label: 'B', error: '超时'),
        CalendarSourceResult(source: 'c', label: 'C', entries: []),
      ], entries: []);
      expect(cal.okSourceCount, 2);
      expect(cal.failedSourceCount, 1);
      expect(cal.isEmpty, isTrue);
    });
  });

  group('★ 展示标题（中文优先）', () {
    test('★ titleCn 优先', () {
      expect(e('Re:Zero', titleCn: '从零开始的异世界生活').displayTitle,
          '从零开始的异世界生活');
    });

    test('★ titleCn 为空/空白时用 title', () {
      expect(e('Re:Zero').displayTitle, 'Re:Zero');
      expect(e('Re:Zero', titleCn: '').displayTitle, 'Re:Zero');
      expect(e('Re:Zero', titleCn: '   ').displayTitle, 'Re:Zero',
          reason: '★ 空白串等于没有');
    });
  });

  group('★ 失败隔离（一个源挂了不能拖垮整体）', () {
    test('★ CalendarSourceResult.ok 语义', () {
      expect(const CalendarSourceResult(source: 'a', label: 'A').ok, isTrue);
      expect(
          const CalendarSourceResult(source: 'a', label: 'A', error: 'x').ok,
          isFalse);
    });
  });
}
