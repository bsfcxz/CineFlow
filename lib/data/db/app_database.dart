/// 本地数据库（drift / SQLite）—— 对应计划书「本地数据库 SQLite (drift)」选型。
///
/// ## 为什么现在引入（而不是继续用文件缓存）
///
/// 引入前本项目只有两种本地存储：
///   - `flutter_secure_storage`：会话、搜索历史、播放偏好（**小、需加密**）
///   - `FileDoubanCache`：豆瓣响应的 JSON 落文件（**无索引、无查询能力**）
///
/// 后者留在**开放缺陷 §7.4**：`MemoryDoubanCache` 忽略 ttl（永不过期），
/// `FileDoubanCache` 写好却零引用，于是 README 宣称的"6h/24h 缓存"不成立。
/// 用文件堆缓存还会带来三个真问题：
///   1. **无法按条件批量清理**（"只清榜单缓存，保留详情"做不到）
///   2. **无法原子过期**（要遍历目录逐个读 JSON 判断时间戳）
///   3. **无法记录播放历史**（需要按"最近播放时间"排序查询）
///
/// 换成 SQLite 后这三件事都是 SQL 一句话的事，且 ttl 由**存储层**保证
/// （查询时直接比对时间列），不再依赖调用方自觉。
///
/// ## 表设计说明
///
/// - `douban_cache`：键值缓存 + 过期时间列。**过期判断下沉到 SQL**
///   （`WHERE expires_at > now`），这是修复 §7.4 的关键——
///   原先 ttl 是"调用方传参、实现方希望自己记得用"，容易漏。
/// - `play_history`：本机播放记录（条目/进度/时长/时间）。
///   为未来的"离线继续观看""最近播放"准备；当前 Emby 服务端也有记录，
///   但本机记录在**未登录/换服务器**时仍可用，且不依赖网络。
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:drift/drift.dart';

part 'app_database.g.dart';

/// 豆瓣接口响应的缓存表。
///
/// 主键用 `key`（调用方给的业务键，如 `ranking:movie:全部`）。
/// 存 `expires_at` 而不是 `saved_at`：查询条件是"未过期"，
/// 直接比一个绝对时间列最直观，也便于建索引。
class DoubanCaches extends Table {
  /// 业务键（调用方保证唯一）
  TextColumn get key => text()();

  /// 原始 JSON 响应正文
  TextColumn get value => text()();

  /// 过期时刻（Unix 秒）。<= 当前时间即为过期。
  IntColumn get expiresAt => integer()();

  /// 写入时刻（Unix 秒）。仅用于诊断/统计，不参与过期判断。
  IntColumn get savedAt => integer()();

  @override
  Set<Column> get primaryKey => {key};
}

/// 本机播放历史。
///
/// `itemId` 是主键：同一部片反复播放只更新一行（保留最新进度），
/// 不做多行追加——因为用途是"继续观看"，不是审计日志。
/// 若将来要做"播放统计"，应另开一张追加型表，不要改这张的语义。
class PlayHistories extends Table {
  TextColumn get itemId => text()();

  /// 冗余存名称/类型/时长：列表渲染时无需回查 Emby，
  /// 断网也能显示"最近播放"。
  TextColumn get name => text().withDefault(const Constant(''))();
  TextColumn get type => text().withDefault(const Constant(''))();

  /// 播放位置与总时长（ticks，1 tick = 100ns，与 Emby 口径一致）
  IntColumn get positionTicks => integer().withDefault(const Constant(0))();
  IntColumn get runtimeTicks => integer().withDefault(const Constant(0))();

  /// 最后一次播放时刻（Unix 秒）
  IntColumn get playedAt => integer()();

  @override
  Set<Column> get primaryKey => {itemId};
}

/// **追剧订阅**（用户：「我的追剧」= 追剧日历里订阅的内容）。
///
/// ## 为什么是独立表而不是塞进 `PlayHistories`
/// · 播放历史是**看过什么**（Emby 的播放位置）
/// · 追剧订阅是**想看什么**（日历里关注的剧）
/// 两者语义无关，混在一张表会让查询要加 type 判别（易错）。
///
/// ## 为什么存这么多冗余字段（不只存 id）
/// 订阅条目来自 **TMDB / B站 / Bangumi**（外部源），Emby 库里**可能没有**。
/// ⇒ 断网或外部源不可用时，「我的追剧」必须仍能显示（剧名/海报/平台/类别）
/// ⇒ 必须**落库快照**，不能只存 id 再去查。
///
/// ## 主键为什么是 `(source, sourceId, mediaType)`
/// · `sourceId` 只在**同源内**唯一（TMDB id 与 B站 id 是两套体系）
/// · TMDB 的 movie/tv 又是**两个独立命名空间**（实测 165 组撞 id，
///   见 `crossServerIdentityKeys`）⇒ 必须带 `mediaType` 判别
class CalendarSubscriptions extends Table {
  /// 来源：`tmdb` / `bilibili` / `bangumi`。
  TextColumn get source => text()();

  /// 该源内的 id。
  TextColumn get sourceId => text()();

  /// 类型：`tv` / `movie`（TMDB 两个命名空间的判别位）。
  TextColumn get mediaType => text().withDefault(const Constant('tv'))();

  /// 剧名（显示用）。
  TextColumn get title => text()();

  /// 中文名（有则优先显示）。
  TextColumn get titleCn => text().withDefault(const Constant(''))();

  /// 海报 URL（https；TMDB/B站都是 https，Bangumi 需升级）。
  TextColumn get posterUrl => text().withDefault(const Constant(''))();

  /// 播放平台（中文，如"腾讯视频"）。
  TextColumn get platform => text().withDefault(const Constant(''))();

  /// 类别：`anime` / `variety` / `series`。
  TextColumn get category => text().withDefault(const Constant('series'))();

  /// 最近一次已知的更新日（`yyyy-MM-dd`），用于排序与"还有几天"。
  TextColumn get lastAirDate => text().withDefault(const Constant(''))();

  /// **状态**（`连载中` / `已完结`；未知时为空串）。
  ///
  /// ## 为什么落库（用户要求"已完结的显示已完结，连载中的显示连载中"）
  /// 与剧名/海报同理：订阅必须能**断网显示**。
  /// 现查的话断网时状态空白 ⇒ 用户看到一张没有状态的怪卡片。
  ///
  /// ⚠️ 存的是**中文结果**而不是 TMDB 原始值（`Returning Series`）：
  ///    映射规则一变，老数据不会自动跟随 —— 但那样只需重订一次，
  ///    而存原始值会让 UI 每次都要做映射（多一处可能漏的地方）。
  TextColumn get status => text().withDefault(const Constant(''))();

  /// 「**是否在服务端收藏里出现过**」—— 双向同步的安全阀门。
  ///
  /// ## 用户要求
  /// > "emby 服务端中的我的收藏 = 我的追剧，我的追剧 = 收藏。**要互相同步**哇。"
  ///
  /// ## ⚠️ 为什么不能"服务端没有就删本地"
  /// 本地可能有"**库里没有**"的**外部订阅**（先订阅、等入库）——
  /// 那些在服务端**没有**对应收藏（订阅时库里没命中 ⇒ 按规则不写收藏）。
  /// 若按"服务端没有就删"，会把它们**全删掉**（正是上次 uninstall 的痛）。
  ///
  /// ## 判据
  /// | 服务端 | 本列 | 动作 |
  /// |---|---|---|
  /// | 有 | 任意 | upsert + 置 **true** |
  /// | 没有 | **true** | 用户在服务端**取消**了 ⇒ **删本地** |
  /// | 没有 | false | 外部订阅 ⇒ **保留** |
  BoolColumn get syncedToServer =>
      boolean().withDefault(const Constant(false))();

  /// 订阅时间（Unix 秒）。
  IntColumn get subscribedAt => integer()();

  Set<Column> get primaryKey => {source, sourceId, mediaType};
}

/// 应用数据库。
///
/// **动漫更新时刻表**（定期索引 B站时间表；见 `CalendarClient.indexAnimeTimeline`）。
///
/// ## ★ 为什么需要这张表（用户建议 + 实测驱动）
/// > "连载的动漫更新时间你从这儿获取，时间一般不会更改的，
/// >  你固定住就好，要么定期在这儿索引"
///
/// B站官方时间表给出**精确到分钟**的更新时刻
///（实测 `pub_time` = `10:00` / `09:00`），而 Emby 两台服务器的 `AirTime`
/// 都是空、分集时间部分只有零点 ⇒ 精确时刻**只能来自平台索引**，
/// 且时刻极少变（用户："时间一般不会更改的，你固定住就好"）。
///
/// ## 为什么只索引 B站（实测：其他三家拿不到）
/// | 源 | 有"周几+时刻"吗 |
/// |---|---|
/// | B站 PGC 时间表 | ✅ **115 部**（番剧 64 + 国创 51），有 `day_of_week`/`pub_time` |
/// | 爱奇艺 | ❌ 只有 `dq_updatestatus='更新至1180集'` |
/// | 腾讯 | ❌ SPA 壳，`PageServer` 要签名参数 |
/// | 优酷 | ❌ SPA + `FAIL_SYS_TOKEN_EMPTY`（要 mtop token）|
/// ⇒ 其余三家回落**平台常规时刻**（`platformAirTime`）。
class AnimeTimelines extends Table {
  /// 剧名（B站原文；匹配订阅时用）。
  TextColumn get title => text()();

  /// 平台（当前只有 `bilibili`）。
  TextColumn get platform => text().withDefault(const Constant('bilibili'))();

  /// 周几（1=周一 … 7=周日）。
  IntColumn get weekday => integer()();

  /// 更新时刻（`HH:mm`）。
  TextColumn get airTime => text().withDefault(const Constant(''))();

  /// 源内 id（B站 `season_id`，可用于跳转）。
  TextColumn get sourceId => text().withDefault(const Constant(''))();

  /// 索引时间（毫秒；用于 TTL 判断 —— 时刻极少变，可长缓存）。
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {title, platform};
}


/// 版本演进纪律：**新增表/列必须同时升 schemaVersion 并写 migration**，
/// 否则老用户升级后启动即崩（drift 会抛 schema 不匹配）。
/// 当前 `schemaVersion = 3`（v2→v3 订阅表加 `status` 列；v1→v2 新增 `CalendarSubscriptions`，
/// 迁移用 `createTable` 而非 `createAll`，不动既有数据）。
@DriftDatabase(tables: [
  DoubanCaches,
  PlayHistories,
  CalendarSubscriptions,
  AnimeTimelines,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  // v4 → v5：订阅表加 `syncedToServer`（**收藏 ⇄ 追剧 双向同步**的安全阀门）。
  // v3 → v4：新增 `anime_timelines`（动漫更新时刻索引表）。
  //
  // ⚠️ **升版本必须同时写迁移**（本仓库为此踩过坑：
  //    schemaVersion 升了但 addColumn 漏写 ⇒ 运行时崩溃）——
  //    见下方 `onUpgrade` 里的长注释。
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          // 过期扫描走这个索引：没有它，清理要全表扫
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_douban_expires '
            'ON douban_caches (expires_at)',
          );
        },
        onUpgrade: (m, from, to) async {
          // ⚠️ 必须逐版本写（AGENTS §8.1 第 6 条：
          //    老用户升级后启动即崩是硬约束）
          //
          // v1 → v2：新增追剧订阅表
          // · 用 `createTable`（不是 `createAll`）—— 只建新表，
          //   不动既有数据（douban_caches / play_histories 保持原样）
          if (from < 2) {
            await m.createTable(calendarSubscriptions);
          }
          // v2 → v3：订阅表加 `status` 列（用户要求区分"已完结/连载中"）
          //
          // ## ★ 用 `addColumn` 而不是重建表（保住用户已有订阅）
          // 重建表（drop + create）会**丢掉用户已订阅的剧** ——
          // 那是用户数据，不能因为加一列就清空。
          //
          // ## ★★ 真机踩过的坑：这段漏写会导致**运行时崩溃**
          // 修 status 那次我漏了这段（`addColumn` 没写进来），
          // 现象是：schemaVersion 已是 3，但表里没有 status 列
          // ⇒ `INSERT INTO calendar_subscriptions (... status ...)`
          //    报 `SqliteException(1): no such column: status`
          // ⇒ 订阅按钮点了没反应（异常被 Flutter 吞成 "Null check
          //    operator used on a null value" 显示在页面上）。
          //
          // ⇒ 教训：**schemaVersion 与迁移必须成对**。
          //    版本号升了但没写迁移，比两者都不动更糟 ——
          //    老库停在旧结构，而代码以为已经升级了。
          //
          // ⚠️⚠️ 条件必须是 `from < 3`，**不是** `from == 2`。
          //
          // ## 为什么（真实事故，两轮才修好）
          // 第一轮：我把 schemaVersion 升到 3，但这段 addColumn **漏写**了
          //   ⇒ 设备升到 v3 时什么都没做，表里没有 status 列。
          // 第二轮：我补上迁移，但条件写成 `from == 2` ——
          //   而设备**已经是 v3** ⇒ `from == 3` ⇒ 条件不成立
          //   ⇒ addColumn **又被跳过**，列永远补不上。
          //   （现象：`SqliteException(1): table calendar_subscriptions
          //     has no column named status`）
          //
          // ## 正确语义
          // drift 的 `from` = **打开时**库里的版本，`to` = 代码里的 schemaVersion。
          // "需不需要加这一列" = "是不是从 v3 **之前**升上来的"
          // ⇒ `from < 3`。
          //
          // ## 为什么不会重复加列
          // · 新装库（from == 0）走 `onCreate`（不经过 `onUpgrade`），
          //   `createAll` 建的表**已含** status 列
          // · 已是 v3 的老库再次启动时 `onUpgrade` **根本不会被调用**
          // ⇒ `from < 3` 只在"v1/v2 老库"上跑一次。
          // v3 → v4：新增 `anime_timelines`（动漫更新时刻索引表）
          // · 同样只 `createTable`，不动既有数据
          // · 这张表是**缓存性质**（可重建）⇒ 丢失也不影响用户数据，
          //   但仍按纪律写迁移（老用户升级不该崩）。
          if (from < 4) {
            await m.createTable(animeTimelines);
          }
          // v4 → v5：订阅表加 `syncedToServer`（双向同步用）。
          // ⚠️ 条件同样是 `from < 5`（不是 `== 4`）——
          //    "需不需要加这列" = "是不是从 v5 之前升上来的"。
          if (from < 5) {
            // ⚠️ 用 `customStatement` 而不是 `m.addColumn` ——
            //    drift 的 `addColumn` 要求 `GeneratedColumn<Object>`，
            //    而 `BoolColumn` 是 `GeneratedColumn<bool>`；
            //    Dart 泛型**不变** ⇒ 类型不匹配（编译错，实测）。
            //    SQLite 的 `ADD COLUMN ... DEFAULT 0` 是标准语法，直接发即可。
            //    （`0` 是常量默认值 —— SQLite 限制默认值必须是常量，正好满足。）
            // ⚠️ 同样要幂等：手写 SQL 也可能撞上"列已存在"
            //    （与上面 status 同一类风险）
            final have = await _columnNames('calendar_subscriptions');
            if (!have.contains('synced_to_server')) {
              await customStatement(
                'ALTER TABLE calendar_subscriptions '
                'ADD COLUMN synced_to_server INTEGER NOT NULL DEFAULT 0',
              );
            } else {
              debugPrint('[DB] 迁移跳过（列已存在）: '
                  'calendar_subscriptions.synced_to_server');
            }
          }
          if (from < 3) {
            // ⚠️ **必须走幂等版** —— 直接 `m.addColumn` 会在
            //    "库里已有该列但 user_version 落后"时**重复加列 ⇒ 崩溃**
            //    （用户上报的 `duplicate column name: status`）。
            //    详见 `_addColumnIfMissing` 的注释。
            await _addColumnIfMissing(
                m, calendarSubscriptions, calendarSubscriptions.status);
          }
          // ⚠️ 上面这条**不够**（真实事故）：`onUpgrade` 只在 from != to 时调用。
          //    若库的版本号已是 3 但列没建出来（开发期踩过），
          //    它永远不会再跑 ⇒ 列永远补不上。
          //    ⇒ 真正的兜底是下面的 `beforeOpen` 自愈。
        },

        // ══════════════════════════════════════════════════════════
        // ★★★ **schema 自愈**（幂等）：不依赖版本号，实查列是否存在
        // ══════════════════════════════════════════════════════════
        //
        // ## 为什么必须有（真实事故）
        // 我踩过一次：`schemaVersion` 已写进库（=3），但 `addColumn`
        // 漏写了 ⇒ `onUpgrade` 只在 `from != to` 时调用 ⇒ **再也不跑**
        // ⇒ `INSERT ... status ...` 报
        //    `SqliteException(1): has no column named status`
        // ⇒ 订阅按钮点了没反应。
        //
        // ## 为什么不用"清库"解决
        // `pm clear` 能修好，但会**清掉用户的登录态与订阅** ——
        // 那是用户数据，不能拿它换正确性。
        //
        // ## 为什么放 `beforeOpen`
        // 每次打开库都跑 ⇒ 无论库处于什么状态（新建/升级/被改坏）
        // 都收敛到目标结构。**必须幂等且快**（一次 PRAGMA 查询）。
        beforeOpen: (details) async {
          await _healSchema();
        },
      );

  // ---------- 豆瓣缓存（修复 §7.4：TTL 由存储层保证）----------

  /// 取未过期的缓存；不存在或已过期都返回 null。
  ///
  /// **过期判断在 SQL 里完成**（`expires_at > now`），不靠调用方自觉——
  /// 这是与原 `FileDoubanCache` 最关键的区别。
  Future<String?> cacheGet(String key, {Duration? ttl}) async {
    final row = await (select(doubanCaches)..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    if (row == null) return null;
    final now = _nowSeconds();
    // ttl 显式传入时以它为准（调用方可能想临时缩短），
    // 否则用写入时记录的绝对过期时刻。
    final effective = ttl == null ? row.expiresAt : row.savedAt + ttl.inSeconds;
    if (effective <= now) {
      // 顺手删掉：过期数据留着既占空间又会让下次查询白读一遍
      await (delete(doubanCaches)..where((t) => t.key.equals(key))).go();
      return null;
    }
    return row.value;
  }

  /// 写缓存。[ttl] 决定过期时刻。
  Future<void> cachePut(String key, String value, {required Duration ttl}) {
    final now = _nowSeconds();
    return into(doubanCaches).insertOnConflictUpdate(
      DoubanCachesCompanion.insert(
        key: key,
        value: value,
        expiresAt: now + ttl.inSeconds,
        savedAt: now,
      ),
    );
  }

  /// 清掉所有已过期条目，返回删除条数。
  ///
  /// 供启动时调用（比"读到时才发现过期"更主动，避免缓存无限膨胀）。
  Future<int> cachePurgeExpired() {
    final now = _nowSeconds();
    return (delete(doubanCaches)..where((t) => t.expiresAt.isSmallerOrEqualValue(now)))
        .go();
  }

  /// 清空全部缓存（供「我的 → 清除缓存」用）。
  Future<int> cacheClear() => delete(doubanCaches).go();

  /// 缓存统计（条数 / 内容字符数），供设置页显示。
  ///
  /// 两个细节：
  ///  1. 必须用 `SUM(LENGTH(value))` 而不是 `LENGTH(value)`——
  ///     与聚合函数 `COUNT` 同处一个 SELECT 时，裸 `LENGTH` 取的是
  ///     **任意一行**的值（实测拿到第一行的长度，导致统计恒等于首条长度）。
  ///  2. SQLite 的 `length()` 对 TEXT 返回**字符数**而非字节数，
  ///     故中文内容会低于实际占用。这里按"估算值"使用，不用于精确配额判断。
  Future<({int count, int bytes})> cacheStats() async {
    final cnt = doubanCaches.key.count();
    final lenSum = doubanCaches.value.length.sum();
    final row = await (selectOnly(doubanCaches)
          ..addColumns([cnt, lenSum]))
        .getSingle();
    return (count: row.read(cnt) ?? 0, bytes: row.read(lenSum) ?? 0);
  }

  // ---------- 播放历史 ----------

  /// 记录/更新一次播放进度。
  Future<void> recordPlay({
    required String itemId,
    required String name,
    required String type,
    required int positionTicks,
    required int runtimeTicks,
  }) =>
      into(playHistories).insertOnConflictUpdate(
        PlayHistoriesCompanion.insert(
          itemId: itemId,
          name: Value(name),
          type: Value(type),
          positionTicks: Value(positionTicks),
          runtimeTicks: Value(runtimeTicks),
          playedAt: _nowSeconds(),
        ),
      );

  /// 最近播放（按时间倒序）。[limit] 默认 20。
  Future<List<PlayHistory>> recentPlays({int limit = 20}) {
    final q = select(playHistories)
      ..orderBy([(t) => OrderingTerm.desc(t.playedAt)])
      ..limit(limit);
    return q.get();
  }

  /// 单条播放进度；没有记录返回 null。
  Future<PlayHistory?> playOf(String itemId) =>
      (select(playHistories)..where((t) => t.itemId.equals(itemId)))
          .getSingleOrNull();

  /// 删除一条播放记录。
  Future<int> deletePlay(String itemId) =>
      (delete(playHistories)..where((t) => t.itemId.equals(itemId))).go();

  int _nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
  /// **schema 自愈**：确保"代码期望的列"在库里真的存在（缺则补）。
  ///
  /// ## 设计
  /// · **幂等** —— 已存在就什么都不做（`beforeOpen` 每次启动都跑）
  /// · **按表分组** —— 每张表一次 `PRAGMA table_info`，不逐列查
  /// · **只加列，不改类型/不删列** —— 那需要真正的迁移（改类型会重建表）
  ///
  /// ## 为什么用 PRAGMA 而不是版本号
  /// 版本号是"我以为的状态"，`PRAGMA table_info` 是"**实际**的状态"。
  /// 两者不一致时（开发期踩过），只有后者能救。

  // ══════════════════════════════════════════════════════════════
  //  迁移辅助（**幂等**）
  // ══════════════════════════════════════════════════════════════

  /// 取某表已有的列名集合（表不存在时返回空集）。
  Future<Set<String>> _columnNames(String table) async {
    try {
      final rows =
          await customSelect('PRAGMA table_info($table)').get();
      return {for (final r in rows) r.read<String>('name')};
    } catch (e) {
      // ⚠️ 这里**不能静默吞**（本仓库踩过：`catch (_)` 让"查不到列"与
      //    "列不存在"变成同一件事 ⇒ 误判 ⇒ 重复加列 ⇒ 启动崩溃）。
      //    打日志便于定位；返回空集只作为最后兜底。
      debugPrint('[DB] 取列失败（$table）: $e');
      return const {};
    }
  }

  /// **加列（幂等）** —— 列已存在则跳过。
  ///
  /// ## ★ 为什么必须用它，不能直接 `m.addColumn`
  /// 真实崩溃（用户上报）：
  /// ```
  /// SqliteException(1): duplicate column name: status
  /// Causing statement: ALTER TABLE "calendar_subscriptions"
  ///                    ADD COLUMN "status" TEXT NOT NULL DEFAULT ''
  /// ```
  /// ### 根因（查 drift 源码确认）
  /// · `drift` 的 `Migrator.addColumn`（`migration.dart:473`）**直接 ALTER**，
  ///   **没有任何"列已存在"检查**
  /// · 而 `onUpgrade` 的 `from < 3` 这类条件**假设 `user_version` 一定准确**
  /// ⇒ 只要库的 `user_version` **落后于实际结构**（开发期反复改 schema、
  ///   从备份恢复、跨设备同步文件…），就会重复加列 ⇒ **启动即崩**。
  ///
  /// ### 为什么"先查再加"是**唯一稳妥**的做法
  /// 迁移的正确依据是**实际结构**，不是版本号 ——
  /// 版本号只是个**优化提示**（决定要不要进迁移流程），
  /// 不能用来判断"这一列到底有没有"。
  /// ⇒ 与本仓库 `_healSchema` 的既有思路一致（`beforeOpen` 里实查 `PRAGMA`）。
  Future<void> _addColumnIfMissing(
    Migrator m,
    TableInfo table,
    GeneratedColumn column,
  ) async {
    final have = await _columnNames(table.actualTableName);
    if (have.contains(column.name)) {
      debugPrint('[DB] 迁移跳过（列已存在）: '
          '${table.actualTableName}.${column.name}');
      return;
    }
    await m.addColumn(table, column);
  }

  Future<void> _healSchema() async {
    /// 代码期望的列（表名 → 列名集合）。
    /// ⚠️ 新增列时**两边都要加**：`Table` 定义 + 这里。
    // ⚠️ 每条是 `(列名, SQL 类型)` 而不是纯列名 ——
    //    因为**列类型不一样**：`synced_to_server` 是 INTEGER（bool），
    //    其余是 TEXT。原来统一按 `TEXT NOT NULL DEFAULT ''` 补，
    //    会把这一列补成 TEXT（SQLite 类型宽松、不报错，但语义错：
    //    drift 读它时按 bool 解析，`''` 与 `'0'` 的行为不一致）。
    const expected = <String, List<(String, String)>>{
      'calendar_subscriptions': [
        ('source', 'TEXT NOT NULL DEFAULT \'\''),
        ('source_id', 'TEXT NOT NULL DEFAULT \'\''),
        ('media_type', 'TEXT NOT NULL DEFAULT \'tv\''),
        ('title', 'TEXT NOT NULL DEFAULT \'\''),
        ('title_cn', 'TEXT NOT NULL DEFAULT \'\''),
        ('poster_url', 'TEXT NOT NULL DEFAULT \'\''),
        ('platform', 'TEXT NOT NULL DEFAULT \'\''),
        ('category', 'TEXT NOT NULL DEFAULT \'series\''),
        ('last_air_date', 'TEXT NOT NULL DEFAULT \'\''),
        ('subscribed_at', 'INTEGER NOT NULL DEFAULT 0'),
        // v3 新增（事故就是它）
        ('status', 'TEXT NOT NULL DEFAULT \'\''),
        // v5 新增 —— ⚠️ **原来漏了这列**：
        // 自愈表是"代码期望的列"的**唯一清单**，漏列 ⇒ 那列永远不会被自愈补上。
        // ⚠️ 它是 INTEGER（drift 的 BoolColumn），**不是** TEXT
        ('synced_to_server', 'INTEGER NOT NULL DEFAULT 0'),
      ],
    };

    for (final e in expected.entries) {
      try {
        final rows = await customSelect('PRAGMA table_info(${e.key})').get();
        if (rows.isEmpty) continue; // 表还不存在（新装库由 createAll 建）
        final have = {for (final r in rows) r.read<String>('name')};
        for (final (col, colType) in e.value) {
          if (have.contains(col)) continue;
          // 缺列 ⇒ 按**该列自己的类型**补（见上面 expected 的说明）
          await customStatement(
              'ALTER TABLE ${e.key} ADD COLUMN $col $colType');
          debugPrint('[DB] 自愈：${e.key}.$col 已补列（$colType）');
        }
      } catch (err) {
        // 自愈失败**不能让 App 起不来** —— 记录后继续
        debugPrint('[DB] 自愈 ${e.key} 失败（非致命）: $err');
      }
    }
  }

  // ══════════════════ 追剧订阅 ══════════════════
  //
  // 用户要求：「我的追剧」= 追剧日历里**订阅**的内容。
  // ⇒ 与 Emby 收藏无关（那是另一回事），纯本地持久化。

  /// **订阅/取消订阅**（唯一写入口）。
  ///
  /// ## 为什么用 toggle 而不是 add/remove 两个方法
  /// UI 上只有一个"追剧"按钮 ⇒ 调用方不需要先查状态再决定调哪个
  ///（那样会有"查完到写之间状态变了"的竞态）。
  ///
  /// ## 返回值
  /// `true` = 现在已订阅；`false` = 现在未订阅。
  /// 调用方据此更新按钮文案。
  Future<bool> toggleSubscription({
    required String source,
    required String sourceId,
    required String mediaType,
    required String title,
    String titleCn = '',
    String posterUrl = '',
    String platform = '',
    String category = 'series',
    String lastAirDate = '',
    String status = '',
  }) async {
    // ⚠️ 不用 record 做 key（drift 的 insert 需要各列独立传值），
    //    这里显式写三列条件，与下面的 delete 保持一致。
    final existing = await (select(calendarSubscriptions)
          ..where((t) =>
              t.source.equals(source) &
              t.sourceId.equals(sourceId) &
              t.mediaType.equals(mediaType)))
        .getSingleOrNull();
    if (existing != null) {
      await (delete(calendarSubscriptions)
            ..where((t) =>
                t.source.equals(source) &
                t.sourceId.equals(sourceId) &
                t.mediaType.equals(mediaType)))
          .go();
      return false;
    }
    await into(calendarSubscriptions).insert(CalendarSubscriptionsCompanion
        .insert(
      // ⚠️ drift 生成的 `insert` 签名：
      //   · **必填列**（无 `withDefault`）⇒ 直接传值，不要 `Value()`
      //   · **有默认值的列** ⇒ 才用 `Value()`
      // 传错会报 "The argument type 'Value<String>' can't be assigned to
      // the parameter type 'String'"。
      source: source,
      sourceId: sourceId,
      title: title,
      subscribedAt: _nowSeconds(),
      mediaType: Value(mediaType),
      titleCn: Value(titleCn),
      posterUrl: Value(posterUrl),
      platform: Value(platform),
      category: Value(category),
      lastAirDate: Value(lastAirDate),
      status: Value(status),
    ));
    return true;
  }

  /// **更新某条订阅的可变信息**（状态 / 最近更新日 / 平台）。
  ///
  /// ## 为什么需要（订阅是**快照**，而快照会过期）
  /// 订阅时落的是当刻快照。但剧的**状态会变**：
  /// 「连载中」→「已完结」是必然发生的事。
  /// ⇒ 每次打开追剧 Tab 拉到新数据后，回写一次（让下次断网也能看到新状态）。
  ///
  /// ## 为什么只更新这三列
  /// 剧名/海报/类别基本不变；而状态/更新日/平台会变。
  /// 只改必要的列，减少写放大（drift 是整行 UPDATE，但语义上更清晰）。
  Future<void> updateSubscriptionMeta({
    required String source,
    required String sourceId,
    required String mediaType,
    String? status,
    String? lastAirDate,
    String? platform,
  }) async {
    await (update(calendarSubscriptions)
          ..where((t) =>
              t.source.equals(source) &
              t.sourceId.equals(sourceId) &
              t.mediaType.equals(mediaType)))
        .write(CalendarSubscriptionsCompanion(
      status: status == null ? const Value.absent() : Value(status),
      lastAirDate:
          lastAirDate == null ? const Value.absent() : Value(lastAirDate),
      platform: platform == null ? const Value.absent() : Value(platform),
    ));
  }

  /// 全部订阅（按"最近更新日"倒序；无日期的排最后）。
  ///
  /// ## 为什么按更新日而不是订阅时间
  /// 用户看「我的追剧」是想知道"**哪个快更新了**"，
  /// 而不是"我什么时候点的订阅"。
  // ══════════════════════════════════════════════════════════
  // 动漫更新时刻表（`anime_timelines`）
  // ══════════════════════════════════════════════════════════

  /// **批量写入索引结果**（幂等：同 `(title, platform)` 覆盖）。
  ///
  /// 时刻极少变（用户："时间一般不会更改的，你固定住就好"）
  /// ⇒ 直接覆盖，不做增量比对。
  Future<void> upsertTimelines(List<AnimeTimeline> rows) async {
    if (rows.isEmpty) return;
    await batch((b) {
      b.insertAllOnConflictUpdate(animeTimelines, rows);
    });
  }

  /// 某平台的最后一次索引时间（毫秒；null = 从没索引过）。
  ///
  /// ## ★ 为什么必须**按平台**（真机踩到）
  /// 原来是"全表 max(updated_at)" ⇒ B站索引过一次后，
  /// 整个 `if (fresh) return` 会**把爱奇艺/优酷一起跳过**
  /// ⇒ 新加的平台**永远不索引**（真机 dump：只有 B站时刻生效）。
  Future<int?> timelineIndexedAt({String? platform}) async {
    final q = selectOnly(animeTimelines)
      ..addColumns([animeTimelines.updatedAt.max()]);
    if (platform != null) {
      q.where(animeTimelines.platform.equals(platform));
    }
    final row = await q.getSingleOrNull();
    return row?.read(animeTimelines.updatedAt.max());
  }

  /// **按剧名查更新时刻**（**只读本地表，0 网络**）。
  ///
  /// ## 两级匹配（B站标题常带副标题）
  /// 1. **精确**：`title = ?`
  /// 2. **包含**：`title LIKE %?%`（如订阅叫「小车队大救援」、
  ///    B站叫「小车队大救援：自然护卫队」）
  ///
  /// 返回 null = 没索引到（**不编时刻**，回落平台惯例）。
  Future<AnimeTimeline?> timelineFor(String title) async {
    final t = title.trim();
    if (t.isEmpty) return null;
    final exact = await (select(animeTimelines)
          ..where((x) => x.title.equals(t))
          ..limit(1))
        .getSingleOrNull();
    if (exact != null) return exact;
    // 退化：包含匹配（两边都可能带后缀，故双向都试）
    final like = await (select(animeTimelines)
          ..where((x) =>
              x.title.like('%$t%') | x.title.like('%${t.split(':').first}%'))
          ..limit(1))
        .getSingleOrNull();
    return like;
  }

  /// 清空该表（重新索引前用；失败时不该留半套数据）。
  Future<void> clearTimelines() => delete(animeTimelines).go();

  /// **批量标记「已在服务端出现过」**（双向同步用）。
  ///
  /// `keys` 是 `(source, sourceId, mediaType)` 三元组 —— 与主键同构。
  Future<void> markSubsSynced(Set<(String, String, String)> keys) async {
    if (keys.isEmpty) return;
    await batch((b) {
      for (final (src, sid, mt) in keys) {
        b.update(
          calendarSubscriptions,
          const CalendarSubscriptionsCompanion(syncedToServer: Value(true)),
          where: (t) =>
              t.source.equals(src) &
              t.sourceId.equals(sid) &
              t.mediaType.equals(mt),
        );
      }
    });
  }

  /// **批量删除订阅**（用户在服务端取消收藏时调用）。
  ///
  /// ⚠️ 只应删「`syncedToServer == true`」的那些（见 sync 的三条规则）——
  ///    外层负责筛选，这里只管删。
  Future<void> deleteSubscriptions(
      Set<(String, String, String)> keys) async {
    if (keys.isEmpty) return;
    await batch((b) {
      for (final (src, sid, mt) in keys) {
        // ⚠️ drift 的批量删除是 **`deleteWhere`**（实测 drift-2.31 源码：
        //    `void deleteWhere<T,D>(TableInfo<T,D> table,
        //     Expression<bool> Function(T) where)`）。
        //    `delete(table, row)` 是"按主键删一条"的另一个方法。
        b.deleteWhere<CalendarSubscriptions, CalendarSubscription>(
          calendarSubscriptions,
          (t) =>
              t.source.equals(src) &
              t.sourceId.equals(sid) &
              t.mediaType.equals(mt),
        );
      }
    });
  }

  Future<List<CalendarSubscription>> allSubscriptions() {
    return (select(calendarSubscriptions)
          ..orderBy([
            (t) => OrderingTerm(
                expression: t.lastAirDate, mode: OrderingMode.desc),
            (t) => OrderingTerm(
                expression: t.subscribedAt, mode: OrderingMode.desc),
          ]))
        .get();
  }

  /// 订阅键集合（形如 `tmdb:12345:tv`）—— 批量判断"是否已订阅"。
  ///
  /// ## 为什么不在 UI 里逐条 `isSubscribed`
  /// 日历一天 30 条 ⇒ 30 次查库/帧。一次查出 Set 后本地判断是 O(1)。
  Future<Set<String>> subscribedKeys() async {
    final rows = await select(calendarSubscriptions).get();
    return {
      for (final r in rows) '${r.source}:${r.sourceId}:${r.mediaType}'
    };
  }

  /// 订阅数量（「我的追剧」角标用）。
  Future<int> subscriptionCount() async {
    final c = calendarSubscriptions;
    final q = selectOnly(c)..addColumns([c.source.count()]);
    final row = await q.getSingle();
    return row.read(c.source.count()) ?? 0;
  }

}