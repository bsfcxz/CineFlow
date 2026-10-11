// 追剧日历：**按类别排列、无周条**（用户 2026-10-11 要求）。
//
// ## 用户原话
// > "在我的 cineflow 中的我的里面的追剧日历按类别排列去除周一-周日。"
//
// ## 为什么必须守（两类问题都不报错）
// ① **周条没真删干净**：删了 UI 但留着 `_selected` / `forWeekdayGrouped`
//    ⇒ 代码看起来"还在按天筛"，将来有人误用就退回旧行为
// ② **整周不去重**：同一部剧在一周内出现 3 次（如《你好，星期六》周一+周六）
//    ⇒ 用户看到一堆重复，但**不报错**
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/data/calendar_client.dart';

String code(String path) => File(path)
    .readAsStringSync()
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('///') && !t.startsWith('*');
    })
    .join('\n');

CalendarEntry e(
  String title, {
  String source = 'tmdb',
  String? sourceId,
  CalendarCategory cat = CalendarCategory.series,
  double? pop,
  int weekday = 3,
}) =>
    CalendarEntry(
      title: title,
      source: source,
      sourceId: sourceId,
      category: cat,
      popularity: pop,
      weekday: weekday,
    );

void main() {
  group('★★★ 日历页必须**没有周条**（用户要求"去除周一-周日"）', () {
    test('★★★ 页面不得再有 _WeekBar / _DayChip', () {
      final c = code('lib/pages/calendar_page.dart');
      expect(c.contains('_WeekBar'), isFalse,
          reason: '★★★ 用户要求"去除周一-周日" ⇒ 周条必须真删');
      expect(c.contains('_DayChip'), isFalse,
          reason: '★ 周条的子组件也要删（否则是死代码）');
    });

    test('★★★ 不得再有"当前选中天"状态（_selected）', () {
      final c = code('lib/pages/calendar_page.dart');
      expect(c.contains('_selected'), isFalse,
          reason: '★★★ 没有周条就没有"选中天" ⇒ 留着会误导后来的改动者');
      expect(c.contains('forWeekdayGrouped'), isFalse,
          reason: '★★ 按天分组的方法不该再被页面使用（改用 groupedByCategory）');
    });

    test('★★★ 必须用整周按类别分组', () {
      final c = code('lib/pages/calendar_page.dart');
      expect(c.contains('groupedByCategory()'), isTrue,
          reason: '★★★ 整周按类别（动漫/综艺/剧集）排列');
      // 类别小标题必须仍在（否则看不出分组）
      expect(c.contains('_CategoryHeader'), isTrue);
    });

    test('★★★ 必须显示"最近更新日"（去掉周条后的必要补偿）', () {
      final c = code('lib/pages/calendar_page.dart');
      // 去掉周条后用户看不到"哪天更新"了，而列表按"离今天多近"排序
      // ⇒ 必须把排序依据标出来，否则顺序显得莫名其妙。
      expect(c.contains('_UpdateDayTag'), isTrue,
          reason: '★★★ 无周条 ⇒ 必须在卡片上标"今天/明天/周三"');
    });
  });

  group('★★★ groupedByCategory：整周去重 + 排序', () {
    test('★★★ 同一部剧在多天出现 ⇒ 只保留一条（去重）', () {
      // 实测：整周 240 条，而同一部剧会在多天出现
      //（《你好，星期六》周一 + 周六）⇒ 不去重会看到重复
      final cal = WeekCalendar(sources: const [], entries: [
        e('你好，星期六', sourceId: '154770', weekday: 1),
        e('你好，星期六', sourceId: '154770', weekday: 6),
      ]);
      final g = cal.groupedByCategory()[CalendarCategory.series]!;
      expect(g.length, 1,
          reason: '★★★ 同源同 id 必须去重（否则用户看到重复条目）');
    });

    test('★★ 不同源的同名剧**不**去重（可能是不同作品）', () {
      final cal = WeekCalendar(sources: const [], entries: [
        e('某剧', source: 'tmdb', sourceId: '1', weekday: 1),
        e('某剧', source: 'bilibili', sourceId: '1', weekday: 2),
      ]);
      final g = cal.groupedByCategory()[CalendarCategory.series]!;
      expect(g.length, 2,
          reason: '★★ 去重键含 source —— 不同源的 id 是两套体系');
    });

    test('★★★ 去重时保留**离今天最近**的那次（不是随便留一条）', () {
      final today = DateTime.now().weekday;
      // 造两条：一条今天、一条今天+3 天
      final far = (today + 3 - 1) % 7 + 1;
      final cal = WeekCalendar(sources: const [], entries: [
        e('某剧', sourceId: '9', weekday: far),
        e('某剧', sourceId: '9', weekday: today),
      ]);
      final g = cal.groupedByCategory()[CalendarCategory.series]!;
      expect(g.length, 1);
      expect(g.first.weekdayResolved, today,
          reason: '★★★ 保留今天那条（用户最关心"今天更新"）');
    });

    test('★★★ 组内排序 = 先"离今天近"，再热度降序', () {
      final today = DateTime.now().weekday;
      final d2 = (today + 1 - 1) % 7 + 1; // 明天
      final cal = WeekCalendar(sources: const [], entries: [
        e('明天低热度', sourceId: 'a', weekday: d2, pop: 1),
        e('今天低热度', sourceId: 'b', weekday: today, pop: 1),
        e('今天高热度', sourceId: 'c', weekday: today, pop: 999),
      ]);
      final g = cal.groupedByCategory()[CalendarCategory.series]!;
      expect(g.map((x) => x.title).toList(),
          ['今天高热度', '今天低热度', '明天低热度'],
          reason: '★★★ 今天优先；同为今天则热度降序');
    });

    test('★★ 组间顺序 = 动漫 → 综艺 → 剧集', () {
      final cal = WeekCalendar(sources: const [], entries: [
        e('剧集', cat: CalendarCategory.series, sourceId: '1'),
        e('动漫', cat: CalendarCategory.anime, sourceId: '2'),
        e('综艺', cat: CalendarCategory.variety, sourceId: '3'),
      ]);
      final g = cal.groupedByCategory();
      expect(g.keys.toList(), [
        CalendarCategory.anime,
        CalendarCategory.variety,
        CalendarCategory.series,
      ]);
    });

    test('★ 无热度的排在同"距离"的有热度之后', () {
      final today = DateTime.now().weekday;
      final cal = WeekCalendar(sources: const [], entries: [
        e('无热度', sourceId: 'a', weekday: today),
        e('有热度', sourceId: 'b', weekday: today, pop: 5),
      ]);
      final g = cal.groupedByCategory()[CalendarCategory.series]!;
      expect(g.first.title, '有热度');
    });
  });
}
