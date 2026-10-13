/// **平台集数 / 放送信息**（数据源：内置弹幕源 = 弹弹play 兼容 API）。
///
/// ## ★ 为什么走弹幕源而不是逐家对接平台
/// 用户明确："我接的不是 danmu_api 里面的嘛"。
/// 实测（2026-10-13）打**我们 App 内置的**公共实例
/// （`DanmakuClient.kPublicProxyBase`）：
/// ```
/// GET /api/v2/search/anime?keyword=吞噬星空
///   → { animes: [{ animeId, animeTitle, episodeCount, startDate, ... }] }
/// GET /api/v2/bangumi/15867
///   → { bangumi: {
///         episodes: [ { episodeId, episodeNumber, episodeTitle, airDate } × 26 ],
///         metadata: [ "话数: 26", "放送开始: 2020年11月29日",
///                     "放送星期: 星期日", "在线播放平台: 腾讯视频", ... ],
///         isOnAir: false, airDay: 0, rating: 6.2 } }
/// ```
/// ⇒ **周几 / 平台集数 / 每集播出日期 / 是否在播 / 播出平台**全都有，
///   而且 **20+ 平台已由上游统一**（腾讯/优酷/爱奇艺/B站/芒果/咪咕…）。
///
/// ## 为什么不再逐家对接（走过的弯路，记下来）
/// 我此前花大量精力逆各平台私有协议：
/// · 腾讯：需要 `H38`/`H42`/`Uk` 三个自定义头 + Cookie +
///   `vversion_name=8.2.96`（版本号不对就返回 18 字节空壳）
/// · 优酷：移动端链接形态变更、PC 页与移动页内容不同、UA 必须与页面成对
/// · 爱奇艺：字段 `desc` → `description` 变更
/// ⇒ 这些**都被上游聚合层解决了**。**先看已有依赖能做什么，再去逆协议。**
library;

/// 一次「平台侧」的番剧更新信息。
///
/// 全部字段都**可空**：上游数据不完整是常态（实测「一斩苍穹」没有「放送星期」），
/// UI 缺字段时**不显示**而不是编造。
class PlatformEpisodes {
  const PlatformEpisodes({
    required this.title,
    this.weekday,
    this.updated,
    this.platform,
    this.isOnAir,
    this.airDate,
    this.totalEpisodes,
    this.aired,
    this.airedWeekday,
  });

  /// 上游命中的标题（可能与订阅名不同，如「吞噬星空」→「吞噬星空 壮志凌云」）。
  final String title;

  /// **周几**（1=周一 … 7=周日；null = 上游没给）。
  ///
  /// 来源：`metadata` 里的 `"放送星期: 星期日"`。
  /// ⚠️ 实测**并非每部都有**（一斩苍穹/财神窦占龙 就没有）⇒ 缺时退回库内周历。
  final int? weekday;

  /// **平台已更新集数**（= `episodes[]` 的长度）。
  ///
  /// ## 与"库内集数"的分工（用户明确要求两者都显示）
  /// > "显示平台数和库内数，这样我知道我库内的集数，
  /// >  也就可以去获取没在库的数了。"
  /// ⇒ 这个数字回答"**平台更新到第几集**"，
  ///   与 `LibrarySummary.episodeCount`（**你库里有几集**）是两个不同的事实。
  final int? updated;

  /// **平台标注的总集数**（`metadata` 的 `"话数: N"`；null = 未标注）。
  ///
  /// ⚠️ 与 [updated] 不同：连载中时 `话数` 可能是"本季总集数"或过时值
  /// （实测「斗破苍穹」话数 12 但 episodes 14）⇒ **显示时以 [updated] 为准**。
  final int? totalEpisodes;

  /// 播出平台（`metadata` 的 `"在线播放平台: 腾讯视频"`）。
  ///
  /// ## 为什么这个字段重要
  /// 真机踩过：订阅表里的 `platform` 只有**一个**值，
  /// 而剧可能多平台（实测「财神窦占龙」是 B站+优酷双平台，
  /// Emby 的 `Studios` 也给了两个）⇒ 单值会漏。
  final String? platform;

  /// 是否在播（上游 `isOnAir`）。
  ///
  /// ## 用途：修「已完结却显示连载中」
  /// 实测「体能之巅：百人大挑战」上游 `isOnAir=false`（TMDB 也是 `Ended`），
  /// 而 **Emby 的 `Status` 是 `Continuing`**（服务器缓存的旧值）。
  /// ⇒ 这是**独立于 Emby 的第二判据**。
  final bool? isOnAir;

  /// 最近一集的播出日期（`yyyy-MM-dd`；null = 拿不到）。
  final String? airDate;

  /// **已播出的集数**（`airDate <= 今天` 的集数）—— 与 [updated] 不同。
  ///
  /// ## 为什么必须区分（用户实测报障）
  /// > "遮天周二是今天更新 **185** 集，不是你标注的平台更新 **190** 集"
  ///
  /// 实测 `GET /api/v2/bangumi/{遮天}`：
  /// ```
  /// episodes 总数 = 190
  /// 其中 airDate <= 今天 = **185**   ← 真值
  /// 未来 5 集：第186集 2026-10-20 / 第187集 2026-10-27 / …
  /// ```
  /// 上游 `episodes[]` **含未播出的预约集** ⇒ 直接数长度会**超前显示**。
  /// ⇒ [updated] 保留"上游总数"（供排查），UI 用 [aired]。
  final int? aired;

  /// **`airDate` 推出的周几**（1..7；null = 拿不到）。
  ///
  /// ## 与 [weekday] 的区别（**这是本项的关键**）
  /// | 来源 | 遮天实测 | 含义 |
  /// |---|---|---|
  /// | [weekday]（`metadata` 的「放送星期」）| **周三** | VIP 正式更新日 |
  /// | [airedWeekday]（`airDate`）| **周二** | **SVIP 提前更新日** |
  ///
  /// 用户要求"以**最新/最早**的更新时间为准"⇒ 取**更早**的那个。
  /// 实测两方向都出现过：
  /// · 遮天：`airDate`(周二) **早于** 「放送星期」(周三) ⇒ 取 airDate
  /// · 一斩苍穹：优酷文案说 SVIP 周一、`airDate` 却给周二 ⇒ 取文案（③）
  ///
  /// ## 算法
  /// 取**已播出**（`airDate <= 今天`）的**最晚一集**的周几 ——
  /// 那正是"当前更新周期"的周几。
  final int? airedWeekday;

  bool get isEmpty =>
      weekday == null && updated == null && platform == null && isOnAir == null;

  @override
  String toString() => 'PlatformEpisodes($title, 周$weekday, '
      '更新$updated, 总$totalEpisodes, $platform, 在播=$isOnAir, $airDate)';
}

/// **解析 `bangumi` 响应**（纯函数，便于单测 —— 不碰网络）。
///
/// ## 为什么提成纯函数
/// 本仓库的验证纪律（§8.1）："纯逻辑改动请补单元测试"。
/// 解析是本模块**唯一有分支**的地方，必须能被单测覆盖。
///
/// ## 容错（§5.3：不允许对服务器字段做非空断言）
/// 上游是**第三方免费实例**（可能限流/改字段）⇒ 每个字段都做类型判断，
/// 缺字段返回 null 而不是抛异常。
PlatformEpisodes? parseBangumi(Map<String, dynamic> raw) {
  final bg = raw['bangumi'];
  if (bg is! Map) return null;

  // ⚠️ **不要用 `as String?`** —— 上游（第三方免费实例）字段类型不可信：
  //    实测单测 ⑤ 用 `animeTitle: 123` 直接触发
  //    `type 'int' is not a subtype of type 'String?'`。
  //    §5.3 明确要求「模型解析必须防御式，不允许对服务器字段做非空断言」。
  final titleRaw = bg['animeTitle'];
  final title = titleRaw is String ? titleRaw : (titleRaw == null ? '' : '$titleRaw');

  int? weekday;
  String? platform;
  int? totalEpisodes;
  final meta = (bg['metadata'] as List?) ?? const [];
  for (final line in meta) {
    final s = '$line';
    if (weekday == null && s.startsWith('放送星期')) {
      weekday = weekdayFromCn(s.replaceFirst('放送星期', ''));
    }
    if (platform == null && s.startsWith('在线播放平台')) {
      // 形态：`在线播放平台: 腾讯视频`（冒号可能是全角/半角）
      final v = s
          .replaceFirst('在线播放平台', '')
          .replaceAll(':', '')
          .replaceAll('：', '')
          .trim();
      if (v.isNotEmpty) platform = v;
    }
    if (totalEpisodes == null && s.startsWith('话数')) {
      totalEpisodes = int.tryParse(
          RegExp(r'\d+').firstMatch(s.replaceFirst('话数', ''))?.group(0) ?? '');
    }
  }

  final eps = (bg['episodes'] as List?) ?? const [];
  final list = eps.whereType<Map<String, dynamic>>().toList();
  int? updated;
  String? airDate;
  int? aired;
  int? airedWeekday;
  if (list.isNotEmpty) {
    updated = list.length;
    // ⚠️ 只数 **airDate <= 今天** 的（上游含未播出的预约集）——
    //    实测遮天：episodes=190 但已播=185（用户："今天更新 185 集"）。
    final today = _ymd(DateTime.now());
    var airedCount = 0;
    for (final e in list) {
      final d = e['airDate'];
      if (d is! String || d.length < 10) continue;
      final ymd = d.substring(0, 10);
      if (ymd.compareTo(today) <= 0) airedCount++;
      // 取**最晚**的 airDate（上游顺序不一定按时间）
      if (airDate == null || ymd.compareTo(airDate) > 0) airDate = ymd;
    }
    aired = airedCount;
    // `airDate` 推出的周几 = SVIP 提前更新日（实测遮天 = 周二）
    if (airDate != null) airedWeekday = _weekdayOfYmd(airDate);
  }

  final isOnAir = bg['isOnAir'] is bool ? bg['isOnAir'] as bool : null;

  return PlatformEpisodes(
    title: title,
    weekday: weekday,
    updated: updated,
    totalEpisodes: totalEpisodes,
    platform: platform,
    isOnAir: isOnAir,
    airDate: airDate,
    aired: aired,
    airedWeekday: airedWeekday,
  );
}

/// `DateTime` → `yyyy-MM-dd`（本地日期，不做时区换算）。
String _ymd(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// `yyyy-MM-dd` → 周几（1..7；解析失败 = null）。
int? _weekdayOfYmd(String ymd) {
  final d = DateTime.tryParse(ymd);
  if (d == null) return null;
  final w = d.weekday;
  return (w >= 1 && w <= 7) ? w : null;
}

/// `"星期日"` / `"周6"` / `"星期一"` / `" 日"` → 1..7（null = 认不出）。
///
/// 实测上游形态是 `放送星期: 星期日`（中文），但**不排除**后续给数字
/// ⇒ 两种都认。
int? weekdayFromCn(String s) {
  for (final ch in s.split('')) {
    const cn = '一二三四五六日';
    final i = cn.indexOf(ch);
    if (i >= 0) return i + 1;
    if (ch == '天') return 7;
  }
  final n = int.tryParse(RegExp(r'[1-7]').firstMatch(s)?.group(0) ?? '');
  return n;
}

/// **平台名归一化键**（用于去重：`Youku` 与 `优酷` 是同一个平台）。
///
/// ## 为什么需要（真机踩到）
/// ```
/// 一斩苍穹 | Youku · 优酷            ← 去重失败，同一个平台显示两次
/// 遮天     | Tencent Video · 腾讯视频  ← 同上
/// ```
/// 两个来源命名习惯不同：
/// · **Emby `Studios`** 用品牌原名（`Youku` / `Tencent Video` / `iQiyi`）
/// · **平台源 `metadata`** 用中文官方名（`优酷` / `腾讯视频` / `爱奇艺`）
///
/// ## 设计原则
/// · **只归一已知别名**，表里没有的**原样保留**（宁可多显示，也不误并）
/// · 归一后的**显示名中文优先**（用户是中文界面）
///
/// ## 怎么维护
/// 遇到新的"同一平台两个名字"就补一行 —— 这是**数据表**不是逻辑，
/// 改动风险低、可测试（见 `platform_episodes_test.dart`）。
const Map<String, String> kPlatformAlias = {
  // key（小写去空格）: 规范显示名
  'youku': '优酷',
  '优酷': '优酷',
  'tengxun': '腾讯视频',
  'tencent': '腾讯视频',
  'tencentvideo': '腾讯视频',
  'qq': '腾讯视频',
  '腾讯': '腾讯视频',
  '腾讯视频': '腾讯视频',
  'iqiyi': '爱奇艺',
  '爱奇艺': '爱奇艺',
  'qiyi': '爱奇艺',
  'bilibili': '哔哩哔哩',
  'bili': '哔哩哔哩',
  '哔哩哔哩': '哔哩哔哩',
  'b站': '哔哩哔哩',
  'mgtv': '芒果TV',
  'mango': '芒果TV',
  '芒果tv': '芒果TV',
  '芒果': '芒果TV',
  'netflix': 'Netflix',
  'migu': '咪咕视频',
  '咪咕': '咪咕视频',
  '咪咕视频': '咪咕视频',
  'leshi': '乐视',
  '乐视': '乐视',
  'sohu': '搜狐视频',
  '搜狐视频': '搜狐视频',
  'pptv': 'PPTV',
  'acfun': 'AcFun',
  'a站': 'AcFun',
};

/// 把一个平台名归一（null = 空串）。
///
/// 归一失败（表里没有）⇒ **原样返回**（去掉首尾空白）。
String normalizePlatform(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return '';
  final key = t.toLowerCase().replaceAll(' ', '').replaceAll('_', '');
  return kPlatformAlias[key] ?? t;
}

/// **合并多个平台名并去重**（保留首次出现顺序）。
///
/// ## 为什么要"合并"而不是"取第一个"（用户明确要求）
/// > "多平台都显示（现在只显示第一个）"
///
/// ## 去重用**归一后的 key**（不是原串）
/// 否则 `Youku` 与 `优酷` 会被当成两个平台（真机实测踩到）。
List<String> mergePlatforms(Iterable<String?> raws) {
  final out = <String>[];
  final seen = <String>{};
  for (final r in raws) {
    if (r == null) continue;
    for (final seg in r.split(RegExp(r'[·,，/、|]'))) {
      final disp = normalizePlatform(seg);
      if (disp.isEmpty) continue;
      final key = normalizePlatform(seg).toLowerCase();
      if (seen.add(key)) out.add(disp);
    }
  }
  return out;
}
