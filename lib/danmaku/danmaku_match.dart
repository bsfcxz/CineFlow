/// Emby 条目 → 弹弹play 弹幕库的匹配参数（**纯逻辑，可单测**）。
///
/// ## 为什么需要这一层
///
/// 弹弹play 的弹幕库按「番剧 + 集」组织，取弹幕前必须先拿到 `episodeId`。
/// 官方给的路径是 `/api/v2/search/episodes?anime=<标题>&episode=<集号>`，
/// 而 Emby 的条目名是**媒体服务器上的文件名派生**，形态极不统一：
///
///   我推的孩子 S01E01
///   【我推的孩子】 第01集
///   [字幕组] 我推的孩子 - 01 [1080p][简繁外挂]
///   我推的孩子 第一季 第1话
///
/// 直接把 `item.name` 丢给搜索接口，命中率会很低（字幕组前缀、画质后缀
/// 都会污染关键词）。所以这里要**提取干净的标题与集号**。
///
/// ## 两个真实踩过的坑（首次实现都错了，被测试抓出来）
///
/// 1. **`【我推的孩子】` 不是字幕组前缀**——全角括号里包的可能就是标题本身。
///    首版把开头的括号组一律剥掉，结果标题变成空串，搜索必然失败。
///    现在改为：剥完后若标题为空，**回退取第一个括号组的内容**。
/// 2. **画质后缀会残留 `[`**——用 `\b` 匹配 `[1080p]` 里的 `1080p` 时，
///    `[` 与空格之间不存在词边界，匹配失败，留下一个孤立的 `[`。
///    现在改为**循环剥离尾部括号组**，不依赖 `\b`。
library;

/// 从 Emby 条目名解析出的匹配参数。
class DanmakuQuery {
  const DanmakuQuery({
    required this.anime,
    this.episode,
    this.season,
    this.isMovie = false,
  });

  /// 用于搜索的番剧名（已清洗）
  final String anime;

  /// 集号。剧场版/电影为 null。
  final int? episode;

  /// 季号（仅用于诊断，官网搜索接口不吃这个参数）
  final int? season;

  /// 是否剧场版/电影
  final bool isMovie;

  bool get usable => anime.isNotEmpty;

  @override
  String toString() =>
      'DanmakuQuery(anime: $anime, episode: $episode, season: $season, movie: $isMovie)';
}

// ---------------------------------------------------------------------------
// 正则
// ---------------------------------------------------------------------------

/// 开头的方括号组（字幕组）或全角括号组
final _leadingGroup = RegExp(r'^\s*[\[【][^\]】]{1,32}[\]】]\s*');

/// 结尾的方括号组（画质/字幕说明）
final _trailingGroup = RegExp(r'\s*[\[【][^\]】]{1,32}[\]】]\s*$');

/// 第一个括号组的内容（用于"剥空了就回退"）
final _firstGroupContent = RegExp(r'[\[【]([^\]】]{1,32})[\]】]');

/// 季标记：第N季 / 第N部 / Season N / S2
final _seasonChinese = RegExp(r'第\s*([0-9一二三四五六七八九十]{1,3})\s*[季部]');
final _seasonEnglish = RegExp(r'\b[Ss]eason\s*(\d{1,2})\b');

/// SxxExx
final _sxxexx = RegExp(r'[Ss](\d{1,2})\s*[Ee](\d{1,3})');

/// 第N集/话/話/回 —— **必须同时收中文数字**（首版只收阿拉伯数字，
/// 导致「第十集」解析失败）
final _epChinese =
    RegExp(r'第\s*([0-9一二三四五六七八九十]{1,4})\s*(?:集|话|話|回)');

/// EP12 / Episode 12
final _epEnglish = RegExp(
  r'\b(?:EP?|Episode)\s*[-_.]?\s*(\d{1,4})\b',
  caseSensitive: false,
);

/// 裸集号：位于末尾的独立数字（「标题 - 01」）
final _epBare = RegExp(r'(?:^|[\s\-_.])(\d{1,4})\s*$');

/// 画质/编码/来源等噪音词（**不含方括号**——括号由循环剥离处理）
final _noiseWord = RegExp(
  r'\b(?:1080p?|720p?|2160p?|4k|8k|hevc|h\.?264|h\.?265|x264|x265|aac|flac|'
  r'web-?dl|blu-?ray|bd(?:rip)?|hdtv|remux|hdr|dv|10bit|8bit|raws?)\b.*$',
  caseSensitive: false,
);

/// 中文字幕说明（这些是词而非括号内容，需单独剥）
final _noiseChinese = RegExp(r'(简繁|简体|繁体|中字|内嵌|外挂|字幕组|合集).*$');

final _movieWords = RegExp(r'剧场版|劇場版|电影版|电影|movie|the\s*movie',
    caseSensitive: false);

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

/// 中文数字 → int（仅支持 1–99，覆盖季/集号的实际范围）。
int? cnNumber(String s) {
  const digits = {
    '零': 0, '〇': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4,
    '五': 5, '六': 6, '七': 7, '八': 8, '九': 9,
  };
  final t = s.trim();
  if (t.isEmpty) return null;
  final plain = int.tryParse(t);
  if (plain != null) return plain;
  if (t == '十') return 10;
  final idx = t.indexOf('十');
  if (idx >= 0) {
    final tens = idx == 0 ? 1 : (digits[t[0]] ?? 0);
    final ones = idx == t.length - 1 ? 0 : (digits[t[idx + 1]] ?? 0);
    final v = tens * 10 + ones;
    return v == 0 ? null : v;
  }
  return digits[t];
}

/// 循环剥离末尾的括号组（不依赖 `\b`，避免残留 `[`）。
///
/// ⚠️ 循环里**必须允许结果为空**：`[1080p]` 整个就是括号组，
/// 剥完应为空串。首版写成 `if (next.isEmpty) break;`——在赋值**之前**就跳出，
/// 于是一个都没剥掉，随后噪音正则吃掉 `1080p` 只留下孤立的 `[`。
String _stripTrailingGroups(String s) {
  var out = s;
  for (var i = 0; i < 6; i++) {
    final next = out.replaceFirst(_trailingGroup, '').trim();
    if (next == out) break; // 剥不动了才停
    out = next; // 允许变成空串
    if (out.isEmpty) break;
  }
  return out;
}

/// 循环剥离开头的括号组（字幕组前缀）。同样允许剥成空串。
String _stripLeadingGroups(String s) {
  var out = s;
  for (var i = 0; i < 6; i++) {
    final next = out.replaceFirst(_leadingGroup, '').trim();
    if (next == out) break;
    out = next;
    if (out.isEmpty) break;
  }
  return out;
}

String _tidy(String s) => s
    .replaceAll(RegExp(r'[\s\-_.·]+$'), '')
    .replaceAll(RegExp(r'^[\s\-_.·]+'), '')
    .replaceAll(RegExp(r'\s{2,}'), ' ')
    .trim();

// ---------------------------------------------------------------------------
// 主入口
// ---------------------------------------------------------------------------

/// 解析 Emby 条目名。
///
/// [seriesName] 是 Emby 给的剧名（比分集名干净），[indexNumber] 是分集号
/// （比从名字猜可靠）——两者**优先于**从名字解析的结果。
DanmakuQuery parseDanmakuQuery({
  required String name,
  String? seriesName,
  int? indexNumber,
  int? parentIndexNumber,
  String? itemType,
}) {
  final original = name.trim();
  var title = original;
  var episode = indexNumber;
  var season = parentIndexNumber;
  var isMovie = itemType == 'Movie';

  // ---- 1) 剥前缀与后缀括号组 ----
  title = _stripLeadingGroups(title);
  title = _stripTrailingGroups(title);

  // ---- 2) 剥画质/来源/字幕说明 ----
  title = title.replaceFirst(_noiseWord, '').trim();
  title = title.replaceFirst(_noiseChinese, '').trim();
  // 上一步可能又暴露了新的尾部括号
  title = _stripTrailingGroups(title);

  // ---- 3) 集号 ----
  if (episode == null) {
    final m = _sxxexx.firstMatch(title);
    if (m != null) {
      season ??= int.tryParse(m.group(1)!);
      episode = int.tryParse(m.group(2)!);
      title = _tidy(title.replaceRange(m.start, m.end, ' '));
    }
  }
  if (episode == null) {
    final m = _epChinese.firstMatch(title);
    if (m != null) {
      episode = cnNumber(m.group(1)!);
      title = _tidy(title.replaceRange(m.start, m.end, ' '));
    }
  }
  if (episode == null) {
    final m = _epEnglish.firstMatch(title);
    if (m != null) {
      episode = int.tryParse(m.group(1)!);
      title = _tidy(title.replaceRange(m.start, m.end, ' '));
    }
  }
  if (episode == null && !isMovie) {
    // 裸集号放最后：误判风险最高（年份等四位数会被吃掉）
    final m = _epBare.firstMatch(title);
    if (m != null) {
      episode = int.tryParse(m.group(1)!);
      title = _tidy(title.substring(0, m.start));
    }
  }

  // ---- 4) 季号：提取后**还要从标题里去掉**（首版漏了这步，
  //          「我推的孩子 第一季」会带着"第一季"去搜索）----
  if (season == null) {
    final m = _seasonChinese.firstMatch(title);
    if (m != null) {
      season = cnNumber(m.group(1)!);
      title = _tidy(title.replaceRange(m.start, m.end, ' '));
    }
  } else {
    // 已知季号时，仍要把标题里的季标记去掉
    title = _tidy(title.replaceFirst(_seasonChinese, ' '));
  }
  title = _tidy(title.replaceFirst(_seasonEnglish, ' '));

  // ---- 5) 剧场版判定 ----
  if (_movieWords.hasMatch(original) || itemType == 'Movie') {
    isMovie = true;
    if (itemType == 'Movie') episode = null;
  }

  title = _stripTrailingGroups(title);
  title = _tidy(title);

  // ---- 6) 剥空了就回退（关键修复）----
  // 「【我推的孩子】 第01集」剥完前缀+集号后标题为空，
  // 但括号内容其实就是标题——把它取回来。
  //
  // ⚠️ 必须在 **original** 上找，不能在"已剥过的中间态"上找：
  // 首版保存了 `afterLeading`（已经剥掉前缀的结果）再去找括号内容，
  // 那时括号已经不在了，永远回退不出东西。
  if (title.isEmpty) {
    final m = _firstGroupContent.firstMatch(original);
    if (m != null) {
      final inner = _tidy(m.group(1)!);
      // 排除明显是噪音的括号内容（画质/字幕说明）
      if (inner.isNotEmpty &&
          !_noiseWord.hasMatch(inner) &&
          !_noiseChinese.hasMatch(inner)) {
        title = inner;
      }
    }
  }

  // ---- 7) 剧集优先用 Emby 的剧名 ----
  if (seriesName != null && seriesName.trim().isNotEmpty) {
    final s = seriesName.trim();
    // 只在"清洗结果为空"或"明显含副标题（更长）"时替换，
    // 避免把正确的剧名换成别的。
    if (title.isEmpty || title.length > s.length + 4) {
      title = s;
    }
  }

  return DanmakuQuery(
    anime: title,
    episode: isMovie ? null : episode,
    season: season,
    isMovie: isMovie,
  );
}
