// 日历：类别分组 + 热度排序 + 平台跳转（用户 5 项需求）。
//
// ## 用户原话
// > "去重，按热度显示，也显示播放平台，点击能跳转到播放平台。
// >  日期下面按类别区分、综艺、动漫、剧集等。"
//
// ## 为什么这些需要测试
// · **类别判定**错了 ⇒ 综艺被归到剧集（用户看不出错，只是分组不对）
// · **排序**错了 ⇒ 用户以为"今天没什么好看的"（实际高热度剧被压到列表底）
// · **平台跳转**错了 ⇒ 点了 404（比不显示平台更糟）
// 以上都不报错，只能靠断言守。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/data/calendar_client.dart';

void main() {
  group('★★★ 类别判定（用户："按类别区分、综艺、动漫、剧集等"）', () {
    test('★★★ TMDB genre_ids → 类别（实测 id 对照）', () {
      // 实测数据：
      // · 你好，星期六  genre_ids=[10764]        → 综艺
      // · 仙逆         genre_ids=[16,18,10759]  → 动漫
      // · 死刑将至     genre_ids=[9648]           → 剧集
      expect(CalendarCategory.fromTmdbGenres([10764]),
          CalendarCategory.variety,
          reason: '★ 10764 = Reality（真人秀）');
      expect(CalendarCategory.fromTmdbGenres([16, 18, 10759]),
          CalendarCategory.anime,
          reason: '★ 16 = Animation');
      expect(CalendarCategory.fromTmdbGenres([9648]),
          CalendarCategory.series,
          reason: '★ 9648 = Mystery ⇒ 剧集（TMDB 无"剧集"这个 genre，靠排除）');
    });

    test('★★ 动漫优先于综艺（同含 16 与 10764 时）', () {
      // 一部片同时有 Animation 与 Reality 时，用户期望归"动漫"
      expect(CalendarCategory.fromTmdbGenres([16, 10764]),
          CalendarCategory.anime);
    });

    test('★★ 空 genre_ids ⇒ 剧集（兜底，不丢条目）', () {
      expect(CalendarCategory.fromTmdbGenres([]), CalendarCategory.series);
    });

    test('★★★ `withGenres` 必须用**竖线**（逗号是 AND，会静默漏数据）', () {
      // ## 实测取证（2026-10-11）
      // ```
      // with_genres=10764          → 8 条
      // with_genres=10764,10767    → 1 条   ← 逗号 = AND（要有全部类别）
      // with_genres=10764|10767    → 8 条   ← 竖线 = OR
      // ```
      // ⇒ 用逗号会让综艺从 8 条掉到 1 条，**不报错**。
      expect(CalendarCategory.variety.withGenres.contains('|'), isTrue,
          reason: '★★★ 多类别必须竖线分隔（逗号是 AND）');
      expect(CalendarCategory.variety.withGenres.contains(','), isFalse,
          reason: '★★★ 绝不能出现逗号');
      expect(CalendarCategory.anime.withGenres, '16');
      // 剧集没有正向筛选（TMDB 无该 genre）⇒ 用排除法
      expect(CalendarCategory.series.withGenres, isEmpty);
      expect(CalendarCategory.series.withoutGenres.contains('|'), isTrue,
          reason: '★★ 排除法也用竖线');
    });
  });

  group('★★★ 按类别分组 + 组内按热度排序', () {
    CalendarEntry e(String t,
            {CalendarCategory cat = CalendarCategory.series,
            double? pop,
            int weekday = 3}) =>
        CalendarEntry(
            title: t, source: 'tmdb', category: cat, popularity: pop,
            weekday: weekday);

    test('★★★ 组间顺序 = 动漫 → 综艺 → 剧集', () {
      final cal = WeekCalendar(sources: const [], entries: [
        e('剧集A', cat: CalendarCategory.series),
        e('动漫A', cat: CalendarCategory.anime),
        e('综艺A', cat: CalendarCategory.variety),
      ]);
      final g = cal.forWeekdayGrouped(3);
      // Map 的 key 顺序 = CalendarCategory.values 的顺序
      expect(g.keys.toList(), [
        CalendarCategory.anime,
        CalendarCategory.variety,
        CalendarCategory.series,
      ]);
    });

    test('★★★ 组内必须按热度**降序**（用户："按热度显示"）', () {
      final cal = WeekCalendar(sources: const [], entries: [
        e('低', pop: 1.0),
        e('高', pop: 158.0),
        e('中', pop: 20.0),
      ]);
      final list = cal.forWeekdayGrouped(3)[CalendarCategory.series]!;
      expect(list.map((x) => x.title).toList(), ['高', '中', '低'],
          reason: '★★★ 热度降序 —— 否则用户以为"今天没什么好看的"');
    });

    test('★★ 无热度的排在**最后**（且保持原顺序）', () {
      // B站/Bangumi 没有 popularity ⇒ 不该插到 TMDB 的高热度中间
      final cal = WeekCalendar(sources: const [], entries: [
        e('无热度1', pop: null),
        e('有热度', pop: 5.0),
        e('无热度2', pop: null),
      ]);
      final list = cal.forWeekdayGrouped(3)[CalendarCategory.series]!;
      expect(list.map((x) => x.title).toList(),
          ['有热度', '无热度1', '无热度2'],
          reason: '★★ 未知热度排最后 + 保持原序（不打乱 B站的时间序）');
    });

    test('★★ 只返回该天的条目（不串天）', () {
      final cal = WeekCalendar(sources: const [], entries: [
        e('周一剧', weekday: 1),
        e('周三剧', weekday: 3),
      ]);
      final g = cal.forWeekdayGrouped(3);
      final all = g.values.expand((x) => x).toList();
      expect(all.length, 1);
      expect(all.first.title, '周三剧');
    });

    test('★ 空组不出现在 Map 的**非空**值里', () {
      final cal = WeekCalendar(sources: const [], entries: [
        e('只有剧集'),
      ]);
      final g = cal.forWeekdayGrouped(3);
      expect(g[CalendarCategory.series]!.length, 1);
      expect(g[CalendarCategory.anime], isEmpty);
      expect(g[CalendarCategory.variety], isEmpty);
    });
  });

  group('★★★ 平台跳转（用户："点击能跳转到播放平台"）', () {
    test('★★★ 五家平台搜索页 URL（全部实测 HTTP 200）', () {
      const cases = {
        '腾讯视频': 'https://v.qq.com/x/search/?q=',
        '爱奇艺': 'https://so.iqiyi.com/so/q_',
        '优酷': 'https://so.youku.com/search_video/q_',
        '芒果TV': 'https://www.mgtv.com/search/?q=',
        'B站': 'https://search.bilibili.com/all?keyword=',
      };
      cases.forEach((platform, prefix) {
        final u = platformSearchUrl(platform, '仙逆');
        expect(u, isNotNull, reason: '★ $platform 必须有跳转 URL');
        expect(u!.startsWith(prefix), isTrue,
            reason: '★ $platform 的 URL 前缀应为 $prefix（实测）');
        expect(u.contains(Uri.encodeComponent('仙逆')), isTrue,
            reason: '★ 剧名必须 URL 编码（中文）');
      });
    });

    test('★★ 未知平台兜底到豆瓣搜索（一定能定位到剧）', () {
      final u = platformSearchUrl('某某卫视', '仙逆');
      expect(u, isNotNull);
      expect(u!.contains('douban.com'), isTrue,
          reason: '★★ 未识别平台用豆瓣搜索兜底，比"点了 404"好');
    });

    test('★★ 平台/剧名为空 ⇒ null（UI 不显示可点样式）', () {
      expect(platformSearchUrl(null, '仙逆'), isNull);
      expect(platformSearchUrl('', '仙逆'), isNull);
      expect(platformSearchUrl('腾讯视频', ''), isNull);
    });

    test('★ 大小写不敏感（TMDB 可能给 Bilibili/bilibili）', () {
      expect(platformSearchUrl('Bilibili', 'x')!.contains('bilibili.com'),
          isTrue);
      expect(platformSearchUrl('BILIBILI', 'x')!.contains('bilibili.com'),
          isTrue);
    });
  });

  group('★★ copyWith（平台是**后补**的，必须能改）', () {
    test('★★ copyWith 只改 platform，其余不变', () {
      const e = CalendarEntry(
        title: '仙逆',
        source: 'tmdb',
        sourceId: '123',
        airDate: '2026-10-11',
        popularity: 86.4,
        category: CalendarCategory.anime,
      );
      final e2 = e.copyWith(platform: '腾讯视频');
      expect(e2.platform, '腾讯视频');
      expect(e2.title, e.title);
      expect(e2.sourceId, e.sourceId);
      expect(e2.popularity, e.popularity);
      expect(e2.category, e.category);
      expect(e2.airDate, e.airDate);
      expect(e.platform, isNull, reason: '★ 原对象不可变');
    });
  });

  group('★★★ 去重必须带日期（跨类别查询会重复返回同一条）', () {
    test('★★★ 同源同 id + 同日期 ⇒ 合并', () {
      final out = mergeCalendarEntries([
        const CalendarEntry(
            title: '仙逆', source: 'tmdb', sourceId: '223911',
            airDate: '2026-10-11', category: CalendarCategory.anime),
        const CalendarEntry(
            title: '仙逆', source: 'tmdb', sourceId: '223911',
            airDate: '2026-10-11', category: CalendarCategory.series),
      ]);
      expect(out.length, 1,
          reason: '★★★ TMDB 允许一部剧同时属于多个类别 ⇒\n'
              '    按类别分别查询时会重复返回同一条，必须去重');
    });

    test('★★ 同源同 id 但**不同日期** ⇒ 不合并（不同更新事件）', () {
      final out = mergeCalendarEntries([
        const CalendarEntry(
            title: '仙逆', source: 'tmdb', sourceId: '223911',
            airDate: '2026-10-11'),
        const CalendarEntry(
            title: '仙逆', source: 'tmdb', sourceId: '223911',
            airDate: '2026-10-18'),
      ]);
      expect(out.length, 2,
          reason: '★★ 同一部剧不同天都更新 ⇒ 用户要看到每一天');
    });
  });
}
