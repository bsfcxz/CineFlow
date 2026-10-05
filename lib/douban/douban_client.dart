import '../data/db/app_database.dart';
import 'douban_http.dart';

import 'douban_catalog.dart';
import 'douban_models.dart';

/// ★ 豆瓣移动网页版（rexxar）公开接口客户端。
///
/// ## 接口与凭据
///
/// 基址 `https://m.douban.com/rexxar/api/v2`，**不需要 API Key**，
/// 但必须带移动端浏览器的两个请求头，否则被风控（400/418）：
///
/// ```
/// Referer: https://m.douban.com/
/// User-Agent: <iPhone Safari UA>
/// ```
///
/// 图片防盗链同理：`img*.doubanio.com` 的裸链接必须带同一个 Referer
/// 才返回 200（否则 418）。UI 加载榜单海报时用同一个 [imageHeaders]。
///
/// ## 缓存
///
/// 豆瓣对高频访问会限流，所以三类专业请求都落盘缓存（[DoubanCache]）：
/// 榜单 6 小时、详情 24 小时、按标题找条目 24 小时。
/// 命中缓存不发网络请求 —— 断网时排行榜与详情补充也还能用。
final class DoubanClient {
  DoubanClient({
    required DoubanHttp http,
    DoubanCache? cache,
    DoubanLogger logger = silentDoubanLogger,
  })  : _http = http,
        _cache = cache,
        _logger = logger;

  /// rexxar 接口基址（**只到域名**）。
  ///
  /// 为什么不能带 `/rexxar/api/v2` 前缀：客户端里所有请求路径都写的是
  /// `/rexxar/api/v2/...` 全路径，而 app 注入的 AppHttpClient 会把
  /// baseUrl 与 path 直接拼接 —— baseUrl 再带一遍前缀就会拼出
  /// `https://m.douban.com/rexxar/api/v2/rexxar/api/v2/...`（404）。
  /// 这正是 2026-10-02 版「排行榜拉不到数据」的根因：
  /// curl 直测接口都是通的，单元测试的 stub 又不做拼接，于是只有真机
  /// 上才炸。base 只写域名 + 路径写全路径，两种实现都不会再拼错。
  static const String kBase = 'https://m.douban.com';

  /// 移动端 UA（实测可用；桌面 UA 会被部分接口拒绝）。
  static const String kUserAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

  /// 豆瓣要求的 Referer。
  static const String kReferer = 'https://m.douban.com/';

  /// UI 加载豆瓣图床图片时需要的请求头（防盗链）。
  ///
  /// 实测（2026-10）图床的拦截规则比接口更严：
  /// - 缺 `Referer` → 418；
  /// - **UA 是 `Dart/x.x (dart:io)`（Flutter 图片加载器的默认 UA）→ 即使带
  ///   Referer 也是 418**。这是「排行榜所有条目都没有图片」的根因。
  /// 所以这里必须同时带 Referer 和一个浏览器 UA。
  static const Map<String, String> imageHeaders = <String, String>{
    'Referer': kReferer,
    'User-Agent': kUserAgent,
  };

  final DoubanHttp _http;
  final DoubanCache? _cache;
  final DoubanLogger _logger;

  /// 榜单缓存有效期（上游本身一天更新几次，6 小时足够新鲜）。
  static const _rankingTtl = Duration(hours: 6);

  /// 详情缓存有效期（评分/简介基本不变，缓存久一点省配额）。
  static const _detailTtl = Duration(hours: 24);

  // ------------------------------------------------------------------
  // 榜单
  // ------------------------------------------------------------------

  /// 按分类拉榜单（UI 的唯一入口）。
  ///
  /// 分类有两种抓取模式（见 [DoubanCategory]）：
  /// - `collection != null`：subject_collection 榜单（电影/电视剧大部分分类）；
  /// - `tag != null`：recommend 接口按 tags 过滤（动漫的分类榜 —— 豆瓣
  ///   没有独立的动画榜单 collection，它的动画榜就是 tv/recommend 带
  ///   `日本动画`/`国产动画` 标签，sort=S 即"高分优先"）。
  Future<List<DoubanEntry>> categoryRankings(
    DoubanCategory category, {
    int start = 0,
    int count = 25,
  }) {
    final collection = category.collection;
    if (collection != null) {
      return rankings(collection, start: start, count: count);
    }
    final tag = category.tag;
    if (tag != null) {
      return recommend(
        tag,
        sort: category.sort ?? 'T',
        start: start,
        count: count,
      );
    }
    throw StateError('分类 ${category.id} 既没有 collection 也没有 tag');
  }

  /// 拉取一个 subject_collection 榜单。
  ///
  /// [collection] 是 `subject_collection` 的 id（见 [DoubanCatalog]）；
  /// [start]/[count] 分页（豆瓣默认每页 25）。
  ///
  /// 失败时抛 [DoubanException]（含豆瓣的原始错误信息），**不吞成空列表** ——
  /// 教训（真实事故语义）：「榜单没数据」根因被
  /// `return vec![]` 掩盖，用户只看到空页却无从排查。
  Future<List<DoubanEntry>> rankings(
    String collection, {
    int start = 0,
    int count = 25,
  }) async {
    final key = 'rank:$collection:$start:$count';
    final cached = await _cache?.get(key);
    if (cached != null) return _decodeRankings(cached, startOffset: start);

    final response = await _http.get(
      '/rexxar/api/v2/subject_collection/$collection/items',
      query: <String, Object?>{'start': '$start', 'count': '$count'},
      headers: _headers,
    );
    if (!response.isOk) {
      throw response.toFailure('豆瓣榜单($collection)');
    }
    final raw = response.asText;
    final entries = _decodeRankings(raw, startOffset: start);
    if (entries.isNotEmpty) await _cache?.put(key, raw, ttl: _rankingTtl);
    return entries;
  }

  /// recommend 接口：按 tags 过滤的分页列表（动漫分类榜用它）。
  ///
  /// [sort]：`T` 综合 / `U` 近期热度 / `R` 首映时间 / `S` 高分优先。
  /// 条目形状与榜单条目几乎一致（见 [_parseEntry]），只是 `comment`
  /// 是对象（内含精选短评文本）而不是纯字符串。
  Future<List<DoubanEntry>> recommend(
    String tags, {
    String sort = 'T',
    int start = 0,
    int count = 25,
  }) async {
    final key = 'rec:$tags:$sort:$start:$count';
    final cached = await _cache?.get(key);
    if (cached != null) return _decodeRankings(cached, startOffset: start);

    final response = await _http.get(
      '/rexxar/api/v2/tv/recommend',
      query: <String, Object?>{
        'refresh': '0',
        'start': '$start',
        'count': '$count',
        'sort': sort,
        'tags': tags,
      },
      headers: _headers,
    );
    if (!response.isOk) {
      throw response.toFailure('豆瓣分类榜($tags)');
    }
    final raw = response.asText;
    final entries = _decodeRankings(raw, startOffset: start);
    if (entries.isNotEmpty) await _cache?.put(key, raw, ttl: _rankingTtl);
    return entries;
  }

  List<DoubanEntry> _decodeRankings(String raw, {required int startOffset}) {
    final map = (tryDecodeJson(raw) as Map?)?.cast<String, Object?>();
    if (map == null) return const <DoubanEntry>[];
    // 两种响应的列表键不同（实测）：
    // - subject_collection 榜单 → `subject_collection_items`；
    // - tv/recommend 分类榜 → `items`。
    final items = (map['subject_collection_items'] as List?) ??
        (map['items'] as List?) ??
        const <Object?>[];
    final out = <DoubanEntry>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item is! Map) continue;
      out.add(_parseEntry(item.cast<String, Object?>(), rank: startOffset + i + 1));
    }
    return out;
  }

  /// 解析榜单条目。
  ///
  /// 电影与电视剧榜单条目**形状不同**（实测）：
  /// - 电视剧：`pic.large` 存海报、`comment` 是精选短评、有 `episodes_info`；
  /// - 电影：`cover.url` 存海报、没有 comment，多一个 `description`。
  /// 解析必须两种都兜住，否则一半榜单会没海报。
  DoubanEntry _parseEntry(Map<String, Object?> json, {required int rank}) {
    final rating = (json['rating'] as Map?)?.cast<String, Object?>();
    final pic = (json['pic'] as Map?)?.cast<String, Object?>();
    final cover = (json['cover'] as Map?)?.cast<String, Object?>();

    return DoubanEntry(
      id: '${json['id'] ?? ''}',
      title: '${json['title'] ?? ''}',
      rank: rank,
      rate: _rateString(rating?['value'], rating?['star_count']),
      rateCount: (rating?['count'] as num?)?.toInt(),
      coverUrl: _posterUrl(pic?['large'] ?? pic?['normal'] ?? cover?['url'] ?? cover),
      subtitle: _cleanText(json['card_subtitle'] as String?),
      comment: _commentText(json['comment'] ?? json['description']),
      episodesInfo: _cleanText(json['episodes_info'] as String?),
      year: json['year'] == null ? null : '${json['year']}',
      isTv: json['type'] == null ? null : json['type'] == 'tv',
      isPlayable: json['has_linewatch'] == true,
    );
  }

  // ------------------------------------------------------------------
  // 搜索（标题匹配用）
  // ------------------------------------------------------------------

  /// 按关键词搜索影视条目（豆瓣移动版搜索的 subjects 结果）。
  Future<List<DoubanSearchHit>> searchSubjects(String query, {int count = 8}) async {
    final key = 'search:$query:$count';
    final cached = await _cache?.get(key);
    if (cached != null) return _decodeSearch(cached);

    final response = await _http.get(
      '/rexxar/api/v2/search/subjects',
      query: <String, Object?>{'q': query, 'count': '$count'},
      headers: _headers,
    );
    if (!response.isOk) {
      throw response.toFailure('豆瓣搜索($query)');
    }
    final raw = response.asText;
    final hits = _decodeSearch(raw);
    await _cache?.put(key, raw, ttl: _detailTtl);
    return hits;
  }

  List<DoubanSearchHit> _decodeSearch(String raw) {
    final map = (tryDecodeJson(raw) as Map?)?.cast<String, Object?>();
    if (map == null) return const <DoubanSearchHit>[];
    // 实测（2026-10）响应形状：
    // {"subjects": {"items": [{layout, target, target_type, type_name}, ...]}}
    // —— subjects.items 的元素**本身就是命中条目**（带 target 字段），
    // 不存在再往下一层的分组。兼容 subjects 直接是数组的历史形状。
    final Object? subjectsRaw = map['subjects'];
    final List<Object?> elements;
    if (subjectsRaw is Map) {
      elements = (subjectsRaw['items'] as List?) ?? const <Object?>[];
    } else if (subjectsRaw is List) {
      elements = subjectsRaw;
    } else {
      elements = const <Object?>[];
    }
    final out = <DoubanSearchHit>[];
    void addHit(Object? item) {
      if (item is! Map) return;
      final target = (item['target'] as Map?)?.cast<String, Object?>();
      if (target == null) return;
      final type = '${item['target_type'] ?? target['type'] ?? ''}';
      final rating = (target['rating'] as Map?)?.cast<String, Object?>();
      out.add(
        DoubanSearchHit(
          id: '${target['id'] ?? ''}',
          title: '${target['title'] ?? ''}',
          isTv: type == 'tv',
          year: target['year'] == null ? null : '${target['year']}',
          rate: _rateString(rating?['value'], rating?['star_count']),
          coverUrl: _posterUrl(target['cover_url']),
          subtitle: _cleanText(target['card_subtitle'] as String?),
        ),
      );
    }

    for (final element in elements) {
      if (element is! Map) continue;
      // 元素带 items 字段 → 视为分组容器（历史形状）；否则视为命中条目。
      final nested = element['items'];
      if (nested is List) {
        for (final item in nested) {
          addHit(item);
        }
      } else {
        addHit(element);
      }
    }
    return out;
  }

  // ------------------------------------------------------------------
  // 详情（豆瓣补充数据用）
  // ------------------------------------------------------------------

  /// 拉一个条目的详情。
  ///
  /// 电影与剧集是两个接口（`/movie/<id>` vs `/tv/<id>`），拿错类型
  /// 会得到 404 或空壳响应，所以调用方必须给对 [isTv]。
  Future<DoubanDetail?> subjectDetail(String id, {required bool isTv}) async {
    if (id.isEmpty) return null;
    final kind = isTv ? 'tv' : 'movie';
    final key = 'subject:$kind:$id';
    final cached = await _cache?.get(key);
    if (cached != null) return _decodeDetail(cached);

    final response = await _http.get(
      '/rexxar/api/v2/$kind/$id',
      headers: _headers,
    );
    if (!response.isOk) {
      _logger('豆瓣详情 $kind/$id 失败：HTTP ${response.statusCode}');
      return null;
    }
    final raw = response.asText;
    final detail = _decodeDetail(raw);
    if (detail != null && (detail.intro != null || detail.rate != null)) {
      await _cache?.put(key, raw, ttl: _detailTtl);
    }
    return detail;
  }

  DoubanDetail? _decodeDetail(String raw) {
    final map = (tryDecodeJson(raw) as Map?)?.cast<String, Object?>();
    if (map == null) return null;
    final title = '${map['title'] ?? ''}';
    if (title.isEmpty) return null;
    final rating = (map['rating'] as Map?)?.cast<String, Object?>();

    return DoubanDetail(
      id: '${map['id'] ?? ''}',
      title: title,
      originalTitle: _cleanText(map['original_title'] as String?),
      // 详情接口路径本身就分 movie/tv；响应里没有稳定类型字段，
      // 以调用方传入的类型为准（这里统一由 [subjectDetail] 填）。
      isTv: false,
      intro: _cleanText(map['intro'] as String?),
      rate: double.tryParse('${rating?['value'] ?? ''}'),
      rateCount: (rating?['count'] as num?)?.toInt(),
      episodesCount: (map['episodes_count'] as num?)?.toInt(),
      episodesInfo: _cleanText(map['episodes_info'] as String?),
      year: map['year'] == null ? null : '${map['year']}',
      genres: _stringList(map['genres']),
      countries: _stringList(map['countries']),
      languages: _stringList(map['languages']),
      directors: _stringList(map['directors']),
      actors: _stringList(map['actors']),
      aka: _stringList(map['aka']),
      coverUrl: _posterUrl(
        ((map['pic'] as Map?)?.cast<String, Object?>())?['large'] ?? map['cover_url'],
      ),
      cardSubtitle: _cleanText(map['card_subtitle'] as String?),
    );
  }

  /// 「按标题找豆瓣条目并补全详情」的一步式入口（详情页补充用）。
  ///
  /// 匹配规则（按可信度递减）：
  /// 1. 归一化标题完全相等（优先同类型、同年份）；
  /// 2. 归一化标题互为前缀（处理《XX 第一季》vs《XX》这类差异）；
  /// 3. 兜底取第一条 —— 豆瓣搜索对完整标题的相关性排序已经不错。
  ///
  /// 找不到或请求失败都返回 null（调用方按"没有补充数据"处理）。
  Future<DoubanDetail?> findDetail(
    String title, {
    int? year,
    bool preferTv = false,
  }) async {
    final cleaned = cleanTitleForSearch(title);
    if (cleaned.isEmpty) return null;

    final key = 'find:$cleaned:${year ?? 0}:${preferTv ? 1 : 0}';
    final cached = await _cache?.get(key);
    if (cached != null) {
      final id = cached;
      return subjectDetail(id, isTv: preferTv);
    }

    final hits = await searchSubjects(cleaned);
    if (hits.isEmpty) {
      await _cache?.put(key, '', ttl: _detailTtl);
      return null;
    }

    DoubanSearchHit? best = _pickBest(hits, cleaned, year, preferTv);
    best ??= hits.first;

    // 缓存"标题 → subject id"的映射；详情本体有自己的缓存。
    if (best.id.isNotEmpty) await _cache?.put(key, best.id, ttl: _detailTtl);
    final detail = await subjectDetail(best.id, isTv: best.isTv);
    // rexxar 详情响应不带类型，这里把搜索拿到的类型补上。
    if (detail == null) return null;
    return DoubanDetail(
      id: detail.id,
      title: detail.title,
      isTv: best.isTv,
      originalTitle: detail.originalTitle,
      intro: detail.intro,
      rate: detail.rate,
      rateCount: detail.rateCount,
      episodesCount: detail.episodesCount,
      episodesInfo: detail.episodesInfo,
      year: detail.year,
      genres: detail.genres,
      countries: detail.countries,
      languages: detail.languages,
      directors: detail.directors,
      actors: detail.actors,
      aka: detail.aka,
      coverUrl: detail.coverUrl,
      cardSubtitle: detail.cardSubtitle,
    );
  }

  /// 从搜索结果里挑最匹配的条目。
  DoubanSearchHit? _pickBest(
    List<DoubanSearchHit> hits,
    String cleaned,
    int? year,
    bool preferTv,
  ) {
    int scoreOf(DoubanSearchHit hit) {
      var score = 0;
      final normalized = normalizeTitle(hit.title);
      if (normalized == cleaned) score += 100;
      if (normalized.startsWith(cleaned) || cleaned.startsWith(normalized)) score += 40;
      if (hit.year != null && year != null && hit.year == '$year') score += 30;
      if (hit.isTv == preferTv) score += 10;
      return score;
    }

    DoubanSearchHit? best;
    var bestScore = 0;
    for (final hit in hits) {
      final score = scoreOf(hit);
      if (score > bestScore) {
        best = hit;
        bestScore = score;
      }
    }
    return best;
  }

  // ------------------------------------------------------------------

  Map<String, String> get _headers => const <String, String>{
        'Referer': kReferer,
        'User-Agent': kUserAgent,
        'Accept': 'application/json',
      };

  /// 豆瓣的评分字段是 double（9.7）或 int；无评分时是 null/0。
  /// UI 需要保留"原样字符串"，这里统一转成 `"9.7"` / `"8"` 这种短文本。
  String? _rateString(Object? value, Object? starCount) {
    if (value == null) return null;
    final v = value is num ? value : double.tryParse('$value');
    if (v == null || v <= 0) return null;
    return v == v.roundToDouble() ? '${v.round()}' : '$v';
  }

  /// 从各种形状里抠出海报 URL。
  ///
  /// `cover` 在电影榜单条目里是 `{"url": ...}` 对象，在搜索结果里
  /// 是一个纯字符串 —— 两种都要接住。
  String? _posterUrl(Object? value) {
    if (value is Map) {
      final map = value.cast<String, Object?>();
      final url = map['url'] ?? map['large'] ?? map['normal'];
      return url == null || '$url'.isEmpty ? null : '$url';
    }
    if (value is String && value.isNotEmpty) return value;
    return null;
  }

  /// 清洗文本：去掉空白与"暂无评分"这类占位符。
  String? _cleanText(String? raw) {
    final t = raw?.trim();
    if (t == null || t.isEmpty) return null;
    return t;
  }

  /// 短评字段的三种形状（实测）：
  /// - 榜单条目：纯字符串；
  /// - recommend 条目：`{comment: "文本", user: {...}, id: ...}` 对象；
  /// - 电影榜单条目：没有该字段（用 description 字符串兜底）。
  String? _commentText(Object? raw) {
    if (raw is Map) {
      final map = raw.cast<String, Object?>();
      return _cleanText(map['comment'] as String?);
    }
    return _cleanText(raw as String?);
  }

  static List<String> _stringList(Object? raw) {
    if (raw is! List) return const <String>[];
    return raw
        .map((e) {
          // 元素可能是字符串，也可能是 {name: xx} 对象（实测详情接口两种都有）
          if (e is Map) {
            final name = e['name'] ?? e['Name'];
            return name == null ? '' : '$name'.trim();
          }
          return '$e'.trim();
        })
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
  }
}

// --------------------------------------------------------------------

/// 标题清洗：把文件名/条目标题变成适合豆瓣搜索的关键词。
///
/// 本地文件名常常长这样：
/// `凡人修仙传.S01E05.2025.2160p.WEB-DL.x265.DualAudio.mkv`
/// 直接拿去搜是搜不到的。这里剥掉：
/// - 扩展名；
/// - 分隔符（`.` / `_` / `-`）与多余的空白；
/// - 技术词（2160p/1080p/WEB-DL/x265/HEVC/BluRay/HDR…）；
/// - 季集标记（S01E02 / 第 2 季 / EP3 / 第 3 集）；
/// - 方括号/圆括号里的发布组与字幕组信息。
String cleanTitleForSearch(String raw) {
  var s = raw.trim();
  // 去扩展名。
  final dot = s.lastIndexOf('.');
  if (dot > 0 && s.length - dot <= 5 && !s.substring(dot + 1).contains(RegExp(r'\d'))) {
    s = s.substring(0, dot);
  }
  // 去括号内容（发布组/字幕组/年份）。
  s = s.replaceAll(RegExp(r'[\[（(【].*?[\]）)】]'), ' ');
  // 去花括号里的资源站标记 —— 整理党目录名常带 {tmdb-1399} / {imdb-tt0944947}。
  s = s.replaceAll(RegExp(r'\{[^}]*\}'), ' ');
  // 去孤立的年份 token：年份已作为独立参数参与匹配（见 [findDetail] 的
  // [year] 参数），关键词里带着只会稀释相关性。
  // ☠ 整串就剩年份时保留原样 —— 片名就叫《2012》的极端情况不能清空。
  final beforeYear = s;
  s = s.replaceAll(RegExp(r'\b(?:19|20)\d{2}\b'), ' ');
  if (s.replaceAll(RegExp(r'\s+'), '').isEmpty) s = beforeYear;
  // 去季集标记。
  s = s.replaceAll(RegExp(r'[Ss]\d{1,2}[Ee]\d{1,3}'), ' ');
  s = s.replaceAll(RegExp(r'[Ee][Pp]?\d{1,3}'), ' ');
  s = s.replaceAll(RegExp(r'第\s*\d+\s*[季集话]'), ' ');
  s = s.replaceAll(RegExp(r'Season\s*\d+', caseSensitive: false), ' ');
  // 去技术词。
  s = s.replaceAll(
    RegExp(
      r'\b(2160p|1080p|720p|4320p|8K|4K|HDR10?|Dolby|Vision|WEB-?DL|WEBRip|BluRay|BDRip|HDTV|x26[45]|x264|HEVC|H\.?26[45]|AVC|AAC|FLAC|TrueHD|Atmos|DTS|DualAudio|10bit|SDR)\b',
      caseSensitive: false,
    ),
    ' ',
  );
  // 分隔符转空格后合并。
  s = s.replaceAll(RegExp(r'[._]+'), ' ');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  // 若清洗后为空（极端文件名），退回原串再试一次。
  if (s.isEmpty) s = raw.trim();
  // 媒体条目标题可能带 " 第x季 " 后缀但用户就想搜本剧 —— 保留它，
  // 豆瓣搜索能正确处理"凡人修仙传 年番"这类词。
  return s;
}

/// 宽松归一化：用于标题匹配比较（去空格/标点/大小写/冠词）。
String normalizeTitle(String input) {
  var s = input.toLowerCase();
  for (final junk in const ['the ', 'a ', 'an ', ' ']) {
    s = s.replaceAll(junk, '');
  }
  return s.replaceAll(RegExp(r'[^\w\u4e00-\u9fa5]'), '');
}

// --------------------------------------------------------------------

/// 豆瓣数据的缓存接口。
///
/// ## TTL 在**写入时**确定（这是修复 §7.4 的关键改动）
///
/// 旧契约是 `get(key, ttl:)` + `put(key, value)`——TTL 只在**读**的时候传。
/// 这留下一个结构性漏洞：实现方可以**直接忽略那个参数**，
/// 而且编译期与静态分析都发现不了。实测正是如此：
/// `MemoryDoubanCache.get` 就是 `return _store[key]`，参数签名收下了、
/// 逻辑里没用，于是"6h/24h 缓存"名存实亡（开放缺陷 §7.4）。
///
/// 新契约把过期时刻**在写入时**固化进存储：
///   - `put` 必须给 ttl（不给就编译不过）
///   - `get` 没有 ttl 参数 → **没有可忽略的东西**
///
/// 这样"忘记过期"从"实现方自觉"变成"类型系统强制"。
abstract interface class DoubanCache {
  /// 取未过期的缓存；不存在或已过期返回 null。
  Future<String?> get(String key);

  /// 写缓存。[ttl] 决定该条目的有效期。
  Future<void> put(String key, String value, {required Duration ttl});
}

/// 基于 drift/SQLite 的 [DoubanCache]（生产实现）。
///
/// 相比原来的 `FileDoubanCache`（JSON 落文件）：
///   - **过期判断在 SQL 里**（`expires_at <= now`），不依赖调用方传参
///   - 可按条件批量清理（`cachePurgeExpired` / 按前缀清榜单）
///   - 跨进程持久：重启后仍命中缓存，而不是重新请求豆瓣
final class DriftDoubanCache implements DoubanCache {
  DriftDoubanCache(this._db);

  final AppDatabase _db;

  @override
  Future<String?> get(String key) => _db.cacheGet(key);

  @override
  Future<void> put(String key, String value, {required Duration ttl}) =>
      _db.cachePut(key, value, ttl: ttl);
}

/// 进程内缓存（**仅测试/降级用**）。
///
/// 它是 TTL 感知的——这是与旧版 `MemoryDoubanCache` 的本质区别：
/// 旧版忽略 ttl，导致单测里也测不出过期问题（因为"永不过期"
/// 在测试里看起来总是命中，反而是"更稳"的表现）。
/// 保留它是因为有些场景（如 widget 测试）不该拉真实数据库。
final class MemoryDoubanCache implements DoubanCache {
  final _store = <String, ({String value, DateTime expiresAt})>{};

  @override
  Future<String?> get(String key) async {
    final e = _store[key];
    if (e == null) return null;
    if (!DateTime.now().isBefore(e.expiresAt)) {
      _store.remove(key); // 过期即删，与 SQL 实现语义一致
      return null;
    }
    return e.value;
  }

  @override
  Future<void> put(String key, String value, {required Duration ttl}) async {
    _store[key] = (value: value, expiresAt: DateTime.now().add(ttl));
  }
}

/// `FileDoubanCache` 已删除（2026-10）。
///
/// 它曾是"JSON 落文件"的缓存实现，但**写好之后从未被引用**，
/// 同时 `MemoryDoubanCache` 忽略了 ttl —— 两者共同构成开放缺陷 §7.4
/// （README 宣称"6h/24h 缓存"，实际既不落盘也不过期）。
///
/// 现由 `DriftDoubanCache`（SQLite，过期判断在 SQL 里）取代：
/// 可按条件清理、跨进程持久、TTL 由写入时的 `expires_at` 固化。
/// 保留此注释是为了让 `git blame` 能追溯到"文件缓存为什么消失"。
