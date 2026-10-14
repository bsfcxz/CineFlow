// ══════════════════════════════════════════════════════════════════════
//  **运行时**迁移回归测试（复现用户上报的崩溃）
// ══════════════════════════════════════════════════════════════════════
//
// ## 用户上报
// ```
// SqliteException(1): duplicate column name: status
// Causing statement: ALTER TABLE "calendar_subscriptions"
//                    ADD COLUMN "status" TEXT NOT NULL DEFAULT ''
// ```
//
// ## ★★ 为什么必须"真跑"（我为此踩了两次坑）
//
// ### 坑 1：修复可能是假的
// 修复靠 `_addColumnIfMissing` → `_columnNames` → `customSelect('PRAGMA …')`。
// 若那个 `customSelect` 在**迁移期**不可用，`catch` 会返回**空集**
// ⇒ 判定"列不存在" ⇒ **仍然 `addColumn`** ⇒ 崩溃照旧。
// ⇒ 那种情况下静态测试（`code(...).contains(...)`）**全绿**，线上照崩。
//
// ### 坑 2：**造场景的方式本身会制造 duplicate**（我第一版就栽在这）
// 第一版我这么造"结构新 + 版本旧"：
// ```dart
// final setup = AppDatabase(exec);
// await setup.customStatement(_v2Table);            // ← 第一次查询就触发 drift 打开！
// await setup.customStatement('ALTER TABLE … ADD COLUMN status …');
// ```
// `customStatement` 是**第一次查询** ⇒ drift 走完整打开流程：
// ```
// onCreate（version 0 → 5）⇒ createAll() **已建出带 status 的表**
//   ↓
// 我的 `CREATE TABLE IF NOT EXISTS` 什么都不做（表已存在）
//   ↓
// 我的 `ALTER TABLE … ADD COLUMN status` ⇒ **重复列**（测试自己造的）
// ```
// 栈里 `test\migration_runtime_test.dart 61:17` 就是铁证 ——
// **报错来自我的测试代码，不是生产代码**。
//
// ## ★ 正确做法：用**裸 sqlite3** 造老库（drift 还没接管）
// ```dart
// final raw = sqlite3.openInMemory();     // 裸库
// raw.execute('CREATE TABLE …(v2 的列)');  // 老结构
// raw.execute('ALTER TABLE … ADD COLUMN status …');  // 结构已升级
// raw.execute('PRAGMA user_version = 2');            // 版本没跟上
// final db = AppDatabase(NativeDatabase.opened(raw)); // 交给 drift
// ```
// ⇒ 这才精确复现用户那台手机的状态。
library;

import 'package:drift/native.dart';
// `debugPrint` 来自 foundation（flutter_test 不导出它）
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:cineflow/data/db/app_database.dart';

/// v2 的表结构（**没有** status / synced_to_server）。
const _v2Table = 'CREATE TABLE calendar_subscriptions ('
    'source TEXT NOT NULL,'
    'source_id TEXT NOT NULL,'
    "media_type TEXT NOT NULL DEFAULT 'tv',"
    'title TEXT NOT NULL,'
    "title_cn TEXT NOT NULL DEFAULT '',"
    "poster_url TEXT NOT NULL DEFAULT '',"
    "platform TEXT NOT NULL DEFAULT '',"
    "category TEXT NOT NULL DEFAULT 'series',"
    "last_air_date TEXT NOT NULL DEFAULT '',"
    'subscribed_at INTEGER NOT NULL DEFAULT 0,'
    'PRIMARY KEY (source, source_id, media_type))';

/// 取某表当前列名集合。
Future<Set<String>> _cols(AppDatabase db, String table) async {
  final rows = await db.customSelect('PRAGMA table_info($table)').get();
  return {for (final r in rows) r.read<String>('name')};
}

void main() {
  test('★★★ 结构新 + 版本旧(v2) ⇒ 打开不得抛 duplicate column', () async {
    // ── ★ 用**裸 sqlite3** 造出"用户那台手机"的状态 ──
    //    ⚠️ 绝不能先 new AppDatabase 再 customStatement（那会触发 onCreate）
    final raw = sqlite3.openInMemory();
    raw.execute(_v2Table);
    // 手工把 status 列加上（模拟"结构已升级、版本号没跟上"）
    raw.execute("ALTER TABLE calendar_subscriptions "
        "ADD COLUMN status TEXT NOT NULL DEFAULT ''");
    // 版本号**回退**到 2 ⇒ 下次打开走 onUpgrade(from=2, to=5)
    raw.execute('PRAGMA user_version = 2');
    // 前置校验（裸库层）
    final before = <String>{
      for (final r in raw.select('PRAGMA table_info(calendar_subscriptions)'))
        r['name'] as String
    };
    debugPrint('[MIGRATION-TEST] 造出的老库列: $before');
    expect(before.contains('status'), isTrue,
        reason: '前置条件：库里的表必须已有 status（否则测不到这个 bug）');
    expect(raw.select('PRAGMA user_version').first['user_version'], 2);

    // ── ★ 交给 drift ⇒ 打开时触发 onUpgrade(from=2, to=5) ──
    //    修复前：这里抛 `duplicate column name: status`
    final db = AppDatabase(NativeDatabase.opened(raw));
    await expectLater(
      db.customSelect('SELECT 1').get(),
      completes,
      reason: '★★★ 这就是用户上报的崩溃 —— 修复前这里必抛 '
          '"duplicate column name: status"',
    );
    // 顺便确认结构收敛
    final after = await _cols(db, 'calendar_subscriptions');
    debugPrint('[MIGRATION-TEST] 打开后列: $after');
    expect(after.contains('status'), isTrue);
    expect(after.contains('synced_to_server'), isTrue,
        reason: 'v5 的列必须被补上（幂等或自愈任一）');
    await db.close();
  });

  test('★★ 全新库(v0) 不得走 onUpgrade（否则 createAll 后再加列必崩）', () async {
    final db = AppDatabase(NativeDatabase.memory());
    await expectLater(db.customSelect('SELECT 1').get(), completes);
    final names = await _cols(db, 'calendar_subscriptions');
    expect(names.contains('status'), isTrue,
        reason: 'v3 的列必须由 createAll 建出来');
    expect(names.contains('synced_to_server'), isTrue,
        reason: 'v5 的列必须由 createAll 建出来');
    await db.close();
  });

  test('★ 自愈：结构缺列 + 版本已是 5 ⇒ 靠 beforeOpen 补上', () async {
    // 裸库：老结构（缺 status / synced_to_server），但版本号设成 **5**
    // ⇒ onUpgrade 不会跑（from == to）⇒ 只能靠 beforeOpen 自愈
    final raw = sqlite3.openInMemory();
    raw.execute(_v2Table);
    raw.execute('PRAGMA user_version = 5');

    final db = AppDatabase(NativeDatabase.opened(raw));
    await db.customSelect('SELECT 1').get(); // 触发 beforeOpen 自愈
    final names = await _cols(db, 'calendar_subscriptions');
    debugPrint('[MIGRATION-TEST] 自愈后列: $names');
    expect(names.contains('status'), isTrue,
        reason: '★ 自愈必须补上 status（版本已是 5 ⇒ onUpgrade 不跑）');
    expect(names.contains('synced_to_server'), isTrue,
        reason: '★ 自愈必须补上 synced_to_server');
    expect(names.contains('subscribed_at'), isTrue);
    await db.close();
  });

  test('★ 幂等：结构 v2 + 版本 3 的库打开两次不崩', () async {
    // ⚠️ **每次都要新建裸库 + 独立 drift 实例**：
    //    同一个 `sqlite3.Database` 被 `NativeDatabase.opened` 包装**两次**
    //    会报 `SqliteException(21): bad parameter or other API misuse`
    //    （drift 在构造时注册自定义函数，第二次对同一 handle 注册即失败）。
    //    ⇒ 这是**测试写法**的限制，不是生产问题：
    //      生产里每次打开都是用**新的** `driftDatabase()` 连接。
    for (var i = 0; i < 2; i++) {
      final raw = sqlite3.openInMemory();
      raw.execute(_v2Table);
      raw.execute('PRAGMA user_version = 3'); // 结构是 v2，版本是 3
      final db = AppDatabase(NativeDatabase.opened(raw));
      await expectLater(db.customSelect('SELECT 1').get(), completes,
          reason: '第 ${i + 1} 次打开不得崩');
      final names = await _cols(db, 'calendar_subscriptions');
      expect(names.contains('status'), isTrue,
          reason: '第 ${i + 1} 次打开后 status 必须存在');
      await db.close();
    }
  });
}
