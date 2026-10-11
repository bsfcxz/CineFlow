// 追剧订阅（用户：「我的追剧」= 追剧日历里**订阅**的内容）。
//
// ## 为什么必须守
// ① **订阅没落全字段** ⇒ 断网时「我的追剧」是空白（用户以为功能坏了）
// ② **键算法不一致** ⇒ 星标显示"已订阅"但列表里没有（或反之），
//    这类不一致**不报错**，只是"点了没反应"
// ③ **schemaVersion 没升就加表** ⇒ 老用户升级后启动即崩（硬约束）
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String code(String path) => File(path)
    .readAsStringSync()
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('///') && !t.startsWith('*');
    })
    .join('\n');

void main() {
  group('★★★ schema 迁移（老用户升级不能崩）', () {
    test('★★★ 加表必须同时升 schemaVersion', () {
      final c = code('lib/data/db/app_database.dart');
      // AGENTS §8.1 第 6 条：改表结构必须升版本 + 写 migration
      expect(c.contains('schemaVersion => 2'), isTrue,
          reason: '★★★ v1→v2 加了 CalendarSubscriptions 表');
      expect(c.contains('CalendarSubscriptions'), isTrue);
    });

    test('★★★ 必须写 v1→v2 的迁移（用 createTable，不是 createAll）', () {
      final c = code('lib/data/db/app_database.dart');
      expect(c.contains('if (from < 2)'), isTrue,
          reason: '★★★ 不写迁移 ⇒ 老用户升级后启动即崩');
      expect(c.contains('m.createTable(calendarSubscriptions)'), isTrue,
          reason: '★★ 只建新表 —— 用 createAll 会试图重建已有表');
    });

    test('★★ 新表必须注册进 @DriftDatabase', () {
      final c = code('lib/data/db/app_database.dart');
      expect(
          c.contains(
              'tables: [DoubanCaches, PlayHistories, CalendarSubscriptions]'),
          isTrue,
          reason: '★★ 不注册 ⇒ drift 不生成表 ⇒ 运行时 "no such table"');
    });
  });

  group('★★★ 订阅表必须落全字段（断网也能显示）', () {
    test('★★★ 必须有剧名/海报/平台/类别/更新日', () {
      final c = code('lib/data/db/app_database.dart');
      // 订阅条目来自 TMDB/B站（外部源），**用户 Emby 库里可能没有**
      // ⇒ 不能只存 id 再回查，必须落快照。
      for (final col in [
        'title',
        'posterUrl',
        'platform',
        'category',
        'lastAirDate',
      ]) {
        expect(c.contains('$col =>'), isTrue,
            reason: '★★★ 缺 $col ⇒ 断网时「我的追剧」显示不出来');
      }
    });

    test('★★★ 主键必须含 mediaType（movie/tv 是两个 id 空间）', () {
      final c = code('lib/data/db/app_database.dart');
      // 与 crossServerIdentityKeys 同一个坑：TMDB 的 movie/tv
      // 两个命名空间同数字各自有效（实测 165 组撞 id）
      expect(c.contains('primaryKey => {source, sourceId, mediaType}'), isTrue,
          reason: '★★★ 不带 mediaType 会让电影与剧集撞主键');
    });
  });

  group('★★★ 订阅写入口', () {
    test('★★★ 必须同时 invalidate 两个 provider（否则按钮状态不更新）', () {
      final c = code('lib/state/providers.dart');
      // 一个给"是否已订阅"（星标），一个给"订阅列表"（首页/日历）
      // 漏一个的现象：星标变了但列表没变（或反之）—— 不报错，只是不一致
      expect(c.contains('invalidate(subscribedKeysProvider)'), isTrue);
      expect(c.contains('invalidate(subscriptionsProvider)'), isTrue,
          reason: '★★★ 漏刷列表 ⇒ 用户以为"订阅没保存"');
    });

    test('★★★ 必须有"整周"的订阅数（首页角标用）', () {
      final c = code('lib/data/db/app_database.dart');
      expect(c.contains('subscriptionCount'), isTrue);
    });

    test('★★ 订阅按"最近更新日"倒序（不是订阅时间）', () {
      final c = code('lib/data/db/app_database.dart');
      // 用户看「我的追剧」想知道"哪个快更新了"
      expect(c.contains('orderBy'), isTrue);
      expect(c.contains('lastAirDate'), isTrue);
    });
  });

  group('★★★ UI 接入', () {
    test('★★★ 日历卡片必须有订阅按钮', () {
      final c = code('lib/pages/calendar_page.dart');
      expect(c.contains('_SubscribeButton'), isTrue,
          reason: '★★★ 用户要从追剧日历里订阅');
      expect(c.contains('toggleCalendarSubscription'), isTrue);
    });

    test('★★★ 首页必须有「我的追剧」区块', () {
      final c = code('lib/pages/home_page.dart');
      expect(c.contains('_MyTrackingSection'), isTrue,
          reason: '★★★ 用户："我的追剧"');
      expect(c.contains('subscriptionsProvider'), isTrue);
      // 没订阅时不占位（避免首页出空区块）
      expect(c.contains('if (list.isEmpty) return const SizedBox.shrink();'),
          isTrue);
    });

    test('★★★ 订阅必须落**已解析的平台**（真机 bug：显示未标注平台）', () {
      final c = code('lib/pages/calendar_page.dart');
      // ## 真机现象
      // 订阅后首页「我的追剧」显示未标注平台，但日历卡片上明明有
      // 「腾讯视频」标签。
      //
      // ## 根因（时序）
      // 平台是**懒加载**后到的（存在 State 的 _platforms）：
      // · 日历卡片：_EntryTile(platform: platforms[id] ?? entry.platform) ✅
      // · 订阅按钮：只读 entry.platform ❌ 那时还是空
      // ⇒ 落库 platform: ''
      //
      // ## 守卫
      // 订阅按钮必须收下**已解析的平台**并传给 toggle。
      expect(c.contains('_SubscribeButton(entry: entry, platform: platform)'),
          isTrue,
          reason: '★★★ 必须透传已解析平台，否则落库空串');
      expect(c.contains('entry.copyWith(platform: platform)'), isTrue,
          reason: '★★★ toggle 时必须用已解析值覆盖 entry.platform');
    });

    test('★★ 首页追剧卡不能用 Emby 的 PosterCard（类型不兼容）', () {
      final c = code('lib/pages/home_page.dart');
      // 订阅是本地表行（含 TMDB 条目），而 PosterCard 吃 MediaItem
      // ⇒ 强转会造出"假 MediaItem"（点进去播不了）
      expect(c.contains('_TrackingCard'), isTrue);
    });
  });
}
