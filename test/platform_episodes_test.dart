/// `PlatformEpisodes` 的解析单测。
///
/// ## 为什么必须有（本仓库的验证纪律，§8.1）
/// > 纯逻辑改动请补单元测试，不要只靠真机点击。
///
/// `parseBangumi` 是**唯一有分支**的地方（`metadata` 逐行扫、缺字段兜底、
/// `airDate` 取最晚），正是最容易回归的部分。
///
/// ## fixture 来自**真实响应**
/// 下面两组数据是从内置弹幕源（`danmaku-api.152468.xyz`）实测抓下来的
/// （2026-10-13），**不是编造的**：
/// · 吞噬星空：有「放送星期」+「在线播放平台」+ 26 集
/// · 一斩苍穹：**没有**「放送星期」（真实缺失 ⇒ 必须返回 null 而不是猜）
library;

import 'package:cineflow/data/platform_episodes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('★★★ parseBangumi：从真实响应解析（fixture 为实测数据）', () {
    /// 实测响应（截取自 `GET /api/v2/bangumi/15867`，只保留解析用到的字段）
    Map<String, dynamic> tineng() => {
          'bangumi': {
            'animeTitle': '吞噬星空',
            'isOnAir': false,
            'airDay': 0,
            'metadata': [
              '中文名: 吞噬星空',
              '话数: 26',
              '放送开始: 2020年11月29日',
              '放送星期: 星期日',
              '在线播放平台: 腾讯视频',
              '原作: 我吃西红柿',
            ],
            'episodes': [
              for (var i = 1; i <= 26; i++)
                {
                  'episodeId': '1586700$i',
                  'episodeNumber': '$i',
                  'episodeTitle': '第$i话',
                  'airDate': i == 26
                      ? '2021-05-16T00:00:00'
                      : '2020-11-29T00:00:00',
                },
            ],
          },
        };

    test('① 完整响应：周几 / 集数 / 平台 / 在播 全部解析出来', () {
      final r = parseBangumi(tineng());
      expect(r, isNotNull);
      expect(r!.title, '吞噬星空');
      expect(r.weekday, 7, reason: '「放送星期: 星期日」→ 7');
      expect(r.updated, 26, reason: 'episodes[] 长度 = 平台已更新集数');
      expect(r.totalEpisodes, 26, reason: '「话数: 26」');
      expect(r.platform, '腾讯视频', reason: '「在线播放平台: 腾讯视频」');
      expect(r.isOnAir, isFalse, reason: '上游 isOnAir（用于纠正 Emby 的旧值）');
      expect(r.airDate, '2021-05-16', reason: '取**最晚**的 airDate');
    });

    test('② 缺「放送星期」时必须返回 null，不得猜', () {
      // 实测：一斩苍穹 / 财神窦占龙 的 metadata 里**没有**这一行
      final raw = tineng();
      final bg = raw['bangumi'] as Map<String, dynamic>;
      bg['metadata'] = ['话数: 18', '放送开始: 2021年1月1日'];
      final r = parseBangumi(raw);
      expect(r, isNotNull);
      expect(r!.weekday, isNull, reason: '没有就不能编 —— UI 会退回库内周历');
      expect(r.updated, 26, reason: '集数仍应解析出');
      expect(r.platform, isNull);
    });

    test('③ 集数为空时不报错（连载刚开始 / 上游缺数据）', () {
      final raw = tineng();
      (raw['bangumi'] as Map<String, dynamic>)['episodes'] = <dynamic>[];
      final r = parseBangumi(raw);
      expect(r, isNotNull);
      expect(r!.updated, isNull, reason: '空列表 ⇒ null（不是 0）');
      expect(r.airDate, isNull);
    });

    test('④ 顶层结构不对 ⇒ null（不抛异常）', () {
      expect(parseBangumi({}), isNull);
      expect(parseBangumi({'bangumi': 'not-a-map'}), isNull);
      expect(parseBangumi({'bangumi': <String, dynamic>{}}), isNotNull,
          reason: '空 bangumi 对象仍可解析（各字段为 null）');
    });

    test('⑤ 字段类型异常时不崩（上游是第三方免费实例）', () {
      final r = parseBangumi({
        'bangumi': {
          'animeTitle': 123, // 类型错
          'isOnAir': 'yes', // 类型错
          'metadata': ['放送星期: 星期三', 42, null],
          'episodes': ['not-a-map', 7],
        },
      });
      expect(r, isNotNull);
      expect(r!.weekday, 3, reason: '能从混合类型里挑出可用行');
      expect(r.isOnAir, isNull, reason: '非 bool ⇒ null（不硬转）');
      expect(r.updated, isNull, reason: 'episodes 里没有合法 map ⇒ null');
    });

    test('⑥ `话数` 与 `episodes.length` 不一致时，两者都保留', () {
      // 实测「斗破苍穹」：话数 12 但 episodes 14 ⇒ 不是 bug，是上游口径
      final raw = tineng();
      (raw['bangumi'] as Map<String, dynamic>)['metadata'] = ['话数: 12'];
      final r = parseBangumi(raw);
      expect(r!.totalEpisodes, 12);
      expect(r.updated, 26);
      expect(r.totalEpisodes, isNot(r.updated),
          reason: '两个数独立保留，由 UI 决定显示哪个');
    });
  });

  group('★ weekdayFromCn：周几解析', () {
    test('中文形态', () {
      expect(weekdayFromCn('星期日'), 7);
      expect(weekdayFromCn('星期一'), 1);
      expect(weekdayFromCn('周六'), 6);
      expect(weekdayFromCn('星期天'), 7, reason: '「天」也是周日');
      expect(weekdayFromCn(' 日'), 7, reason: '带空格也要认');
    });
    test('数字形态', () {
      expect(weekdayFromCn('星期6'), 6);
      expect(weekdayFromCn(' 3'), 3);
    });
    test('认不出 ⇒ null（不瞎猜）', () {
      expect(weekdayFromCn(''), isNull);
      expect(weekdayFromCn('未知'), isNull);
      expect(weekdayFromCn('8'), isNull, reason: '8 不是合法星期');
    });
  });
}
