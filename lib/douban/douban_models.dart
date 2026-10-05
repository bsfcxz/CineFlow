/// 豆瓣数据模型：榜单条目、搜索结果、条目详情。
///
/// 字段刻意做得少而稳：只映射 UI 真正要展示的内容。
/// 上游是 m.douban.com 的 rexxar JSON 接口，字段名以实测响应为准
/// （`subject_collection_items[]` / `subjects[].items[].target` / 条目详情）。
library;

/// 榜单里的一条。
final class DoubanEntry {
  const DoubanEntry({
    required this.id,
    required this.title,
    required this.rank,
    this.rate,
    this.rateCount,
    this.coverUrl,
    this.subtitle,
    this.comment,
    this.episodesInfo,
    this.year,
    this.isTv,
    this.isPlayable = false,
  });

  /// 豆瓣 subject id（`36576514`）。
  final String id;

  final String title;

  /// 榜内名次（从 1 开始，按返回顺序编）。
  final int rank;

  /// 豆瓣评分，形如 `"9.7"`。
  ///
  /// 保留**字符串的原样**而不转 double：豆瓣对未上映/评价人数不足的条目
  /// 返回空串或 0，转成数字会丢掉"没有评分"与"评分是 0"的区别。
  final String? rate;

  /// 评分人数（用于 UI 上"49537 人评过"这类副信息，可为 null）。
  final int? rateCount;

  /// 海报（2:3）。
  ///
  /// 豆瓣图床有防盗链：`img*.doubanio.com` 的裸链接必须带
  /// `Referer: https://m.douban.com/` 才返回 200（否则 418）。
  /// UI 加载图片时要带上这个头（core_ui 的 `RemoteImage(httpHeaders:)`）。
  final String? coverUrl;

  /// 一行副标题，上游 `card_subtitle`，形如
  /// `2026 / 中国大陆 / 剧情 悬疑 犯罪 / 刘海波 / 任嘉伦 秦俊杰`。
  final String? subtitle;

  /// 豆瓣精选短评（电视剧榜单条目才有）。放详情弹层里展示。
  final String? comment;

  /// 剧集的更新状态，例如 `16集全` / `更新至39集`。电影通常为空。
  final String? episodesInfo;

  /// 年份（`2026`）。
  final String? year;

  /// 条目类型（电影 false / 剧集 true）。旧版电影榜单条目没有该字段。
  final bool? isTv;

  /// 豆瓣标注的"可播放"（有正版片源）。仅作展示，与我们的播放能力无关。
  final bool isPlayable;

  /// 可用于展示的评分文本；无评分时返回 null（UI 据此不渲染评分角标）。
  String? get ratingText {
    final r = rate?.trim();
    if (r == null || r.isEmpty) return null;
    // 过滤掉 "0" 与 "0.0" 占位。
    if (r == '0' || r == '0.0') return null;
    return r;
  }

  /// 豆瓣网页版详情页链接（"在浏览器打开"用）。
  String get webUrl => 'https://movie.douban.com/subject/$id/';
}

/// 搜索结果里的一条（`search/subjects` 的 `subjects[].items[].target`）。
final class DoubanSearchHit {
  const DoubanSearchHit({
    required this.id,
    required this.title,
    required this.isTv,
    this.year,
    this.rate,
    this.coverUrl,
    this.subtitle,
  });

  final String id;
  final String title;

  /// `target_type`：`movie` / `tv`。
  final bool isTv;
  final String? year;
  final String? rate;
  final String? coverUrl;

  /// 上游 `card_subtitle`（地区 / 类型 / 导演 / 主演）。
  final String? subtitle;

  double? get rateValue {
    final v = double.tryParse(rate ?? '');
    return v == null || v <= 0 ? null : v;
  }
}

/// 条目详情（`/movie/<id>` 或 `/tv/<id>`）。
///
/// 这里的字段是给"豆瓣补充详情"用的：本地媒体源（网盘/本地文件）没有
/// 简介与集数信息时，按标题搜到这个条目再把 [intro]、[episodesInfo]
/// 等填回详情页。
final class DoubanDetail {
  const DoubanDetail({
    required this.id,
    required this.title,
    required this.isTv,
    this.originalTitle,
    this.intro,
    this.rate,
    this.rateCount,
    this.episodesCount,
    this.episodesInfo,
    this.year,
    this.genres = const <String>[],
    this.countries = const <String>[],
    this.languages = const <String>[],
    this.directors = const <String>[],
    this.actors = const <String>[],
    this.aka = const <String>[],
    this.coverUrl,
    this.cardSubtitle,
  });

  final String id;
  final String title;

  /// 详情接口按类型分路径（`/movie/<id>` vs `/tv/<id>`），取回来时已确定。
  final bool isTv;
  final String? originalTitle;

  /// 剧情简介（上游 `intro`，网页端"剧情简介"区块的全文）。
  final String? intro;

  /// 评分（10 分制）；无评分时为 null（区别于 0 分）。
  final double? rate;
  final int? rateCount;

  /// 总集数（剧集才有，如 16）。
  final int? episodesCount;

  /// 更新状态（`16集全` / `更新至39集`）。
  final String? episodesInfo;
  final String? year;
  final List<String> genres;
  final List<String> countries;
  final List<String> languages;
  final List<String> directors;
  final List<String> actors;

  /// 别名（`深渊 / 深渊游戏`）。
  final List<String> aka;
  final String? coverUrl;
  final String? cardSubtitle;

  String? get ratingText {
    final v = rate;
    if (v == null || v <= 0) return null;
    return v.toStringAsFixed(1);
  }

  String get webUrl => 'https://movie.douban.com/subject/$id/';
}
