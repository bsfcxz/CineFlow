import 'package:cineflow/data/db/app_database.dart';
import 'package:drift/drift.dart' show QueryExecutor;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// 内存连接工厂——**只存在于测试**。
///
/// 不放进 `lib/` 的 `db_provider.dart`：`NativeDatabase` 来自
/// `drift/native.dart`（依赖 dart:ffi 直接开 sqlite），
/// 属于测试/桌面用途；生产构建应由 `drift_flutter` 按平台选择实现，
/// 把 native 实现混进 lib 会让 Android 上的 ABI 选择变复杂。
QueryExecutor openMemoryExecutor() => NativeDatabase.memory();

/// 本地数据库（drift）的单元测试。
///
/// ## 这些测试真正在守什么
///
/// **开放缺陷 §7.4**：豆瓣缓存 TTL 形同虚设——
/// `MemoryDoubanCache` 忽略 ttl（永不过期），`FileDoubanCache` 写好却零引用，
/// 于是 README 宣称的"6h/24h 缓存"不成立。
///
/// 这个缺陷之所以长期存在，是因为它在真机上**表现为"数据不是最新的"**，
/// 而不是报错——没有断言就发现不了。故此处逐条锁住过期语义。
///
/// 用 `NativeDatabase.memory()`：每个测试独立、不落盘、可并行。
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(openMemoryExecutor());
  });

  tearDown(() async {
    await db.close();
  });

  group('豆瓣缓存：TTL 由存储层保证（§7.4 回归线）', () {
    test('写入后可立即读出', () async {
      await db.cachePut('k1', '{"a":1}', ttl: const Duration(hours: 6));
      expect(await db.cacheGet('k1'), '{"a":1}');
    });

    test('不存在的键返回 null', () async {
      expect(await db.cacheGet('nope'), isNull);
    });

    test('未过期但显式传入更短 ttl → 视为过期（调用方可临时收紧）', () async {
      await db.cachePut('k1', 'v', ttl: const Duration(hours: 24));
      // 传入 0 秒 ttl：savedAt + 0 <= now → 必然过期
      expect(await db.cacheGet('k1', ttl: Duration.zero), isNull);
    });

    test('过期条目读取时返回 null 并被顺手删除（不留垃圾）', () async {
      // ttl 为负 → 写入即过期
      await db.cachePut('k1', 'v', ttl: const Duration(seconds: -1));
      expect(await db.cacheGet('k1'), isNull,
          reason: 'TTL 必须真的生效——这正是 §7.4 缺的能力');

      // 确认已被删掉（不是仅返回 null 却把数据留着）
      final stats = await db.cacheStats();
      expect(stats.count, 0);
    });

    test('cachePurgeExpired 只删过期的，保留有效的', () async {
      await db.cachePut('fresh', 'a', ttl: const Duration(hours: 1));
      await db.cachePut('stale1', 'b', ttl: const Duration(seconds: -10));
      await db.cachePut('stale2', 'c', ttl: const Duration(seconds: -5));

      final removed = await db.cachePurgeExpired();
      expect(removed, 2, reason: '应只删两条过期记录');

      // 有效的那条必须还在
      expect(await db.cacheGet('fresh'), 'a');
      final stats = await db.cacheStats();
      expect(stats.count, 1);
    });

    test('同键重写是覆盖而非追加（避免无限膨胀）', () async {
      await db.cachePut('k', 'v1', ttl: const Duration(hours: 1));
      await db.cachePut('k', 'v2', ttl: const Duration(hours: 1));
      expect(await db.cacheGet('k'), 'v2');
      final stats = await db.cacheStats();
      expect(stats.count, 1);
    });

    test('cacheClear 清空全部', () async {
      await db.cachePut('a', '1', ttl: const Duration(hours: 1));
      await db.cachePut('b', '2', ttl: const Duration(hours: 1));
      expect(await db.cacheClear(), 2);
      expect((await db.cacheStats()).count, 0);
    });

    test('cacheStats 统计条数与字节数', () async {
      await db.cachePut('a', '12345', ttl: const Duration(hours: 1));
      await db.cachePut('bb', '123', ttl: const Duration(hours: 1));
      final s = await db.cacheStats();
      expect(s.count, 2);
      // 注意：SQLite 的 length() 对 TEXT 返回**字符数**而非字节数，
      // 故中文键值下这个数字会小于 UTF-8 实际占用。此处按字符数断言，
      // 并在实现里注明它是"估算"——真要精确字节数需 length(CAST(v AS BLOB))。
      expect(s.bytes, 8, reason: '5 + 3 个字符');
    });

    test('中文与特殊字符的键值往返无损', () async {
      const key = 'ranking:movie:全部';
      const value = '{"title":"流浪地球2","note":"科幻·灾难"}';
      await db.cachePut(key, value, ttl: const Duration(hours: 6));
      expect(await db.cacheGet(key), value);
    });
  });

  group('播放历史', () {
    test('记录后可读回，字段完整', () async {
      await db.recordPlay(
        itemId: 'it1',
        name: '流浪地球2',
        type: 'Movie',
        positionTicks: 12345,
        runtimeTicks: 99999,
      );
      final h = await db.playOf('it1');
      expect(h, isNotNull);
      expect(h!.name, '流浪地球2');
      expect(h.type, 'Movie');
      expect(h.positionTicks, 12345);
      expect(h.runtimeTicks, 99999);
    });

    test('同一条目重复播放是更新而非新增（保留最新进度）', () async {
      await db.recordPlay(
          itemId: 'it1', name: 'A', type: 'Movie',
          positionTicks: 100, runtimeTicks: 1000);
      await db.recordPlay(
          itemId: 'it1', name: 'A', type: 'Movie',
          positionTicks: 500, runtimeTicks: 1000);

      final all = await db.recentPlays();
      expect(all.length, 1, reason: '这部片只该有一行，否则"继续观看"会重复');
      expect(all.first.positionTicks, 500);
    });

    test('recentPlays 按最后播放时间倒序', () async {
      // 依次写入三条；playedAt 用秒级时间戳，故这里靠 sleep 拉开
      await db.recordPlay(
          itemId: 'old', name: '旧', type: 'Movie',
          positionTicks: 0, runtimeTicks: 100);
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await db.recordPlay(
          itemId: 'new', name: '新', type: 'Movie',
          positionTicks: 0, runtimeTicks: 100);

      final list = await db.recentPlays();
      expect(list.first.itemId, 'new', reason: '最近播放的必须排最前');
    });

    test('limit 生效', () async {
      for (var i = 0; i < 5; i++) {
        await db.recordPlay(
            itemId: 'it$i', name: 'n$i', type: 'Movie',
            positionTicks: 0, runtimeTicks: 100);
      }
      expect((await db.recentPlays(limit: 3)).length, 3);
    });

    test('playOf 无记录返回 null', () async {
      expect(await db.playOf('none'), isNull);
    });

    test('deletePlay 删除单条，不影响其它', () async {
      await db.recordPlay(
          itemId: 'a', name: 'A', type: 'Movie',
          positionTicks: 0, runtimeTicks: 1);
      await db.recordPlay(
          itemId: 'b', name: 'B', type: 'Movie',
          positionTicks: 0, runtimeTicks: 1);
      expect(await db.deletePlay('a'), 1);
      expect(await db.playOf('a'), isNull);
      expect(await db.playOf('b'), isNotNull);
    });

    test('空库 recentPlays 返回空列表而非抛错', () async {
      expect(await db.recentPlays(), isEmpty);
    });
  });

  group('连接工厂', () {
    test('openMemoryExecutor 可用（每个测试独立、不落盘）', () async {
      // 复用 setUp 的实例即可——另行 new 一个会触发 drift 的
      // "multiple databases" 警告（同一进程内多实例共用 executor 有风险）
      await db.cachePut('t', 'v', ttl: const Duration(hours: 1));
      expect(await db.cacheGet('t'), 'v');
    });
  });
}
