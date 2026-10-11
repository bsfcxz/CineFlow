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

  /// 订阅时间（Unix 秒）。
  IntColumn get subscribedAt => integer()();

  Set<Column> get primaryKey => {source, sourceId, mediaType};
}

/// 应用数据库。
///
/// 版本演进纪律：**新增表/列必须同时升 schemaVersion 并写 migration**，
/// 否则老用户升级后启动即崩（drift 会抛 schema 不匹配）。
/// 当前 `schemaVersion = 2`（v1→v2 新增 `CalendarSubscriptions`，
/// 迁移用 `createTable` 而非 `createAll`，不动既有数据）。
@DriftDatabase(tables: [DoubanCaches, PlayHistories, CalendarSubscriptions])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 2;

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
    ));
    return true;
  }

  /// 全部订阅（按"最近更新日"倒序；无日期的排最后）。
  ///
  /// ## 为什么按更新日而不是订阅时间
  /// 用户看「我的追剧」是想知道"**哪个快更新了**"，
  /// 而不是"我什么时候点的订阅"。
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