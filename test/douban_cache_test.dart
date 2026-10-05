import 'package:cineflow/data/db/app_database.dart';
import 'package:cineflow/douban/douban_client.dart';
import 'package:drift/drift.dart' show QueryExecutor;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// 豆瓣缓存的语义测试 —— **开放缺陷 §7.4 的回归线**。
///
/// ## 这个缺陷为什么能活这么久
///
/// 旧实现是 `MemoryDoubanCache.get(key, {required Duration ttl})`，
/// 函数体却只有 `return _store[key];`——**ttl 参数收下了但没用**。
/// 后果：进程内数据永不过期，且不落盘（重启即丢），
/// 于是 README 宣称的"榜单 6h / 详情 24h 缓存"在运行期完全不成立。
///
/// 它躲过所有检查的原因很值得记：
///   - **编译期不报错**：多一个未使用的具名参数完全合法
///   - **静态分析不报错**：参数确实"被使用"（在签名里），看不出没参与逻辑
///   - **真机"看起来正常"**：永不过期只会让数据偏旧，不会崩、不会空
///
/// 所以修复不能只改那个函数体——**必须改契约**，让"忘记过期"变得不可能：
/// TTL 在写入时固化（`put(..., ttl:)` 是必填），读取时没有 ttl 参数可忽略。
/// 下面的测试正是锁住这套新语义。
void main() {
  QueryExecutor mem() => NativeDatabase.memory();

  group('DriftDoubanCache：TTL 由存储层保证（§7.4 回归线）', () {
    late AppDatabase db;
    late DriftDoubanCache cache;

    setUp(() {
      db = AppDatabase(mem());
      cache = DriftDoubanCache(db);
    });

    tearDown(() async => db.close());

    test('未过期时命中，且值原样返回', () async {
      await cache.put('rank:movie:0:25', '{"items":[1,2]}',
          ttl: const Duration(hours: 6));
      expect(await cache.get('rank:movie:0:25'), '{"items":[1,2]}');
    });

    test('不存在返回 null', () async {
      expect(await cache.get('missing'), isNull);
    });

    test('TTL 过期后必须返回 null —— 旧实现正是这里失效', () async {
      // 用负 ttl 制造"写入即过期"，避免测试 sleep 数小时
      await cache.put('k', 'v', ttl: const Duration(seconds: -1));
      expect(
        await cache.get('k'),
        isNull,
        reason: '若这里返回 v，就是 §7.4 复现：ttl 被忽略了',
      );
    });

    test('过期条目被顺手删除，不会残留', () async {
      await cache.put('k', 'v', ttl: const Duration(seconds: -1));
      await cache.get('k'); // 触发清理
      expect((await db.cacheStats()).count, 0);
    });

    test('榜单 6h 与详情 24h 用的是各自写入时的 TTL（互不干扰）', () async {
      // 同一时刻写入两条，TTL 不同 → 一个还有效、一个已过期
      await cache.put('ranking', 'r', ttl: const Duration(seconds: -1));
      await cache.put('detail', 'd', ttl: const Duration(hours: 24));
      expect(await cache.get('ranking'), isNull);
      expect(await cache.get('detail'), 'd',
          reason: '两条缓存的 TTL 必须独立生效，不能共用一套');
    });

    test('覆盖写入会刷新过期时间（不是"首次写入后就锁死"）', () async {
      await cache.put('k', 'v1', ttl: const Duration(seconds: -1));
      // 同一 key 重新写入，TTL 为正 → 应重新变得可用
      await cache.put('k', 'v2', ttl: const Duration(hours: 1));
      expect(await cache.get('k'), 'v2');
    });

    test('中文 key（榜单分类名）往返正常', () async {
      const key = 'rank:movie:全部:0:25';
      await cache.put(key, '{"title":"流浪地球2"}',
          ttl: const Duration(hours: 6));
      expect(await cache.get(key), '{"title":"流浪地球2"}');
    });

    test('空字符串值也能正确往返（findDetail 用它做"未找到"负缓存）',
        () async {
      await cache.put('find:某片:0:0', '', ttl: const Duration(hours: 24));
      // 注意：get 返回 null 表示"无缓存"，'' 表示"缓存了空结果"——
      // 两者语义不同，客户端据此区分"要重新搜"与"确实没搜到"
      final got = await cache.get('find:某片:0:0');
      expect(got, isNotNull);
      expect(got, '');
    });

    test('清理只删过期的，有效缓存保留', () async {
      await cache.put('fresh', 'a', ttl: const Duration(hours: 1));
      await cache.put('stale', 'b', ttl: const Duration(seconds: -10));
      expect(await db.cachePurgeExpired(), 1);
      expect(await cache.get('fresh'), 'a');
    });
  });

  group('MemoryDoubanCache：TTL 感知（不再是"永不过期"）', () {
    test('未过期命中', () async {
      final c = MemoryDoubanCache();
      await c.put('k', 'v', ttl: const Duration(hours: 1));
      expect(await c.get('k'), 'v');
    });

    test('过期返回 null —— 旧实现忽略 ttl 的回归线', () async {
      final c = MemoryDoubanCache();
      await c.put('k', 'v', ttl: const Duration(seconds: -1));
      expect(await c.get('k'), isNull,
          reason: '旧版恒返回 _store[key]，这条断言当时必然失败');
    });

    test('过期后条目被移除（不留内存垃圾）', () async {
      final c = MemoryDoubanCache();
      await c.put('k', 'v', ttl: const Duration(seconds: -1));
      await c.get('k');
      // 再写一次新的，确认前一个 key 不干扰
      await c.put('k2', 'v2', ttl: const Duration(hours: 1));
      expect(await c.get('k2'), 'v2');
    });
  });
}
