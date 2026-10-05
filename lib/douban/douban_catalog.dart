/// ★ 豆瓣排行榜分类清单。
///
/// ## 设计思路
///
/// 把「分类」做成纯数据（id / 分组 / 显示名 / 上游参数），
/// UI 只按这份清单渲染，**新增榜单不需要改界面代码**。
///
/// ## 与签名制数据源的差异：这里不需要密钥
///
/// 走 AppId/AppSecret 签名或 API Key 的数据源要求**编译期注入凭据**，
/// 必须处理「此构建没有凭据」这一分支。
///
/// 豆瓣移动网页版（m.douban.com）的 rexxar 接口是公开的，**不需要任何密钥**，
/// 只要求请求带上移动端的 `Referer` 与 UA（服务端按它路由到网页版本）。
/// 因此这里不存在「凭据没注入」这类失败模式 —— 少一大块复杂度。
/// 反过来，它的失败模式变成了「被限流 / 被风控」，所以
/// [DoubanEntry] 侧要如实把服务端的响应说出来。
///
/// ## 历史注记
///
/// 老的 `www.douban.com/j/search_subjects` 接口已经下线（实测 404），
/// 现在统一走 `m.douban.com/rexxar/api/v2/subject_collection/<id>/items`。
/// 下面每个 collection id 都在 2026-10 本机实测返回过非空榜单；
/// 豆瓣对不存在的 id 返回 404 而不是空数组，所以写错 id 会直接报错，
/// 不会出现"点进去一片空白还不知道为什么"。
library;

/// 榜单分组（UI 用它做顶部 tab）。
enum DoubanGroup {
  movie('movie', '电影'),
  tv('tv', '电视剧'),
  anime('anime', '动漫');

  const DoubanGroup(this.wire, this.label);

  final String wire;
  final String label;
}

/// 一个榜单分类。
final class DoubanCategory {
  const DoubanCategory({
    required this.id,
    required this.group,
    required this.label,
    required this.collection,
  })  : tag = null,
        sort = null;

  const DoubanCategory.recommend({
    required this.id,
    required this.group,
    required this.label,
    required this.tag,
    this.sort = 'T',
  }) : collection = null;

  /// 稳定 id（用于路由参数、缓存文件名）。
  final String id;

  final DoubanGroup group;

  /// 界面上显示的名字。
  final String label;

  /// 豆瓣 `subject_collection` 的 id（榜单标识，实测可用）。
  ///
  /// 与 [tag] 二选一：collection 模式走榜单接口；
  /// tag 模式走 recommend 接口（动漫的分类榜 —— 豆瓣没有独立的
  /// 动画榜单 collection，它的动画分类榜就是 tv/recommend 带动画标签）。
  final String? collection;

  /// recommend 接口的 `tags` 参数（collection 模式下为 null）。
  final String? tag;

  /// recommend 接口的排序：`T` 综合 / `U` 近期热度 / `R` 首映 / `S` 高分优先。
  final String? sort;
}

/// 内置分类清单。
abstract final class DoubanCatalog {
  static const List<DoubanCategory> categories = <DoubanCategory>[
    // ---- 电影（2026-10 逐个实测非空）----
    DoubanCategory(
      id: 'movie_showing',
      group: DoubanGroup.movie,
      label: '影院热映',
      collection: 'movie_showing',
    ),
    DoubanCategory(
      id: 'movie_latest',
      group: DoubanGroup.movie,
      label: '近期热门',
      collection: 'movie_latest',
    ),
    DoubanCategory(
      id: 'movie_hot',
      group: DoubanGroup.movie,
      label: '新片榜',
      collection: 'movie_hot',
    ),
    DoubanCategory(
      id: 'movie_high_score',
      group: DoubanGroup.movie,
      label: '豆瓣高分',
      collection: 'movie_high_score',
    ),
    DoubanCategory(
      id: 'movie_weekly_best',
      group: DoubanGroup.movie,
      label: '一周口碑榜',
      collection: 'movie_weekly_best',
    ),
    DoubanCategory(
      id: 'movie_classic',
      group: DoubanGroup.movie,
      label: '经典',
      collection: 'movie_classic',
    ),
    DoubanCategory(
      id: 'movie_top250',
      group: DoubanGroup.movie,
      label: 'Top 250',
      collection: 'movie_top250',
    ),

    // ---- 电视剧 ----
    DoubanCategory(
      id: 'tv_hot',
      group: DoubanGroup.tv,
      label: '近期热门',
      collection: 'tv_hot',
    ),
    DoubanCategory(
      id: 'tv_chinese_best_weekly',
      group: DoubanGroup.tv,
      label: '华语口碑榜',
      collection: 'tv_chinese_best_weekly',
    ),
    DoubanCategory(
      id: 'tv_global_best_weekly',
      group: DoubanGroup.tv,
      label: '全球口碑榜',
      collection: 'tv_global_best_weekly',
    ),
    DoubanCategory(
      id: 'tv_domestic',
      group: DoubanGroup.tv,
      label: '国产剧',
      collection: 'tv_domestic',
    ),
    DoubanCategory(
      id: 'tv_american',
      group: DoubanGroup.tv,
      label: '美剧',
      collection: 'tv_american',
    ),
    DoubanCategory(
      id: 'tv_japanese',
      group: DoubanGroup.tv,
      label: '日剧',
      collection: 'tv_japanese',
    ),
    DoubanCategory(
      id: 'tv_korean',
      group: DoubanGroup.tv,
      label: '韩剧',
      collection: 'tv_korean',
    ),
    DoubanCategory(
      id: 'tv_variety_show',
      group: DoubanGroup.tv,
      label: '综艺',
      collection: 'tv_variety_show',
    ),
    DoubanCategory(
      id: 'tv_documentary',
      group: DoubanGroup.tv,
      label: '纪录片',
      collection: 'tv_documentary',
    ),

    // ---- 动漫 ----
    // 豆瓣没有"动画"专属的榜单 collection，所以分类榜走 recommend 接口：
    // tag=动画/日本动画/国产动画，sort=S 即"高分优先"（2026-10 实测非空）。
    DoubanCategory(
      id: 'tv_animation',
      group: DoubanGroup.anime,
      label: '热门动画',
      collection: 'tv_animation',
    ),
    DoubanCategory.recommend(
      id: 'anime_japan',
      group: DoubanGroup.anime,
      label: '日本动画',
      tag: '日本动画',
      sort: 'T',
    ),
    DoubanCategory.recommend(
      id: 'anime_japan_top',
      group: DoubanGroup.anime,
      label: '高分日本动画',
      tag: '日本动画',
      sort: 'S',
    ),
    DoubanCategory.recommend(
      id: 'anime_domestic',
      group: DoubanGroup.anime,
      label: '国产动画',
      tag: '国产动画',
      sort: 'T',
    ),
    DoubanCategory.recommend(
      id: 'anime_domestic_hot',
      group: DoubanGroup.anime,
      label: '热门国产动画',
      tag: '国产动画',
      sort: 'U',
    ),
    DoubanCategory.recommend(
      id: 'anime_domestic_latest',
      group: DoubanGroup.anime,
      label: '最新国产动画',
      tag: '国产动画',
      sort: 'R',
    ),
    DoubanCategory.recommend(
      id: 'anime_japan_latest',
      group: DoubanGroup.anime,
      label: '最新日本动画',
      tag: '日本动画',
      sort: 'R',
    ),
    DoubanCategory.recommend(
      id: 'anime_top',
      group: DoubanGroup.anime,
      label: '高分动画',
      tag: '动画',
      sort: 'S',
    ),
  ];

  /// 按 id 查分类。找不到返回 null（调用方要给用户提示，
  /// 而不是静默展示空榜）。
  static DoubanCategory? byId(String id) {
    for (final c in categories) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// 某个分组下的分类（UI 按 tab 过滤）。
  static List<DoubanCategory> inGroup(DoubanGroup group) =>
      categories.where((c) => c.group == group).toList(growable: false);

  /// 默认打开的分类（进「排行榜」页时的第一屏）。
  static DoubanCategory get defaultCategory => categories.first;
}
