/// 日历条目**详情弹层** —— 与「豆瓣排行榜」的详情弹层同款信息结构。
///
/// ## 用户要求
/// > "增加点击可以查看到剧集、综艺、动漫等的简介和我们的豆瓣排行榜一样。"
///
/// ## 与 `douban_detail_sheet.dart` 的字段对照（刻意保持一致的信息层级）
/// | 豆瓣弹层 | 本弹层（TMDB） |
/// |---|---|
/// | 海报 + 标题 + ★评分 + 人数 | 同（`vote_average` / `vote_count`） |
/// | 副标题（年/国家/类型） | 同（`subtitleLine`） |
/// | 简介 | 同（`overview`） |
/// | 导演 | `created_by` + `crew[job=Director]` |
/// | 主演 | `credits.cast[]`（**带角色名**，比豆瓣更细） |
/// | 类型 / 制片国家/地区 | 同 |
/// | 集数 | `seasonCount / episodeCount` |
/// | [↗豆瓣] | [↗播放平台]（`homepage`，**点进去就能看**） |
///
/// ## 数据来源与缓存
/// `CalendarClient.fetchDetail`（`/tv/{id}?append_to_response=credits`，6h 缓存）。
/// 该端点**一次请求**返回上面全部字段（实测确认）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme.dart';
import '../data/calendar_client.dart';
import 'media_tags.dart';
import '../state/providers.dart';

/// 打开日历条目的**全屏详情页**。
///
/// ## ★ 为什么从"底部弹层"改成"全屏页"（用户 2026-10-12 要求）
/// > "详情页的设计也需要和我的 ui 一样"
/// 稿子（180b4d）里它是 **`position:absolute; inset:0` + `translateY(100%)`**
/// ⇒ **整屏从底部滑入**，而不是"占 60% 高度的弹层"。
///
/// 差异不只是高度：全屏页才能放下
/// 「52vh Hero + 操作按钮 + 下次更新 + 5 行信息 + 3 行简介 + 4 列选集网格」
/// —— 弹层里这些会挤成一片。
void showCalendarDetail(BuildContext context, CalendarEntry entry) {
  Navigator.push(
    context,
    PageRouteBuilder<void>(
      opaque: true,
      // 稿子的曲线：cubic-bezier(0.32, 0.72, 0, 1)，420ms
      transitionDuration: const Duration(milliseconds: 420),
      reverseTransitionDuration: const Duration(milliseconds: 320),
      pageBuilder: (_, __, ___) => CalendarDetailPage(entry: entry),
      transitionsBuilder: (_, anim, __, child) => SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 1), // 从底部滑入（稿子 translateY(100%)）
          end: Offset.zero,
        ).animate(CurvedAnimation(
          parent: anim,
          curve: const Cubic(0.32, 0.72, 0, 1),
        )),
        child: child,
      ),
    ),
  );
}

class CalendarDetailPage extends ConsumerStatefulWidget {
  const CalendarDetailPage({super.key, required this.entry});

  final CalendarEntry entry;

  @override
  ConsumerState<CalendarDetailPage> createState() =>
      _CalendarDetailPageState();
}

class _CalendarDetailPageState extends ConsumerState<CalendarDetailPage> {
  /// 详情（null = 还在加载；`_failed` = 拉取失败）。
  CalendarDetail? _detail;
  bool _loading = true;
  bool _failed = false;

  /// 简介是否已展开（稿子 180b4d："默认 3 行 + 展开全部"）。
  ///
  /// ## 为什么默认折叠
  /// TMDB 的 `overview` 实测可达 300+ 字，全展开会把「导演/主演/类型」
  /// 挤出首屏 —— 而用户点进来最想看的是**元信息**，简介属"想细看再展开"。
  bool _descExpanded = false;

  /// 选集是否已展开（用户 2026-10-12：选集也整成和简介一样只展示3行）。
  ///
  /// ## 为什么选集也要折叠
  /// 实测《爱·回家之开心速递》**2868 集** ⇒ 4 列网格要铺 700+ 行，
  /// 把后面的内容全部顶下去（用户永远滚不到底）。
  bool _epExpanded = false;

  /// 是否已追（用户规格：追剧按钮可切换「追剧 / 已追」）。
  ///
  /// ## 两个来源的并集（与 Emby 详情页同一个约定）
  /// · **本地订阅**（drift 表，追剧日历里点星标订的）
  /// · 任一为真 ⇒ 显示"已追"
  ///
  /// ⚠️ 本页条目来自 TMDB/B站等**外部源**，可能**不在 Emby 库内**
  /// ⇒ 不能假定有 Emby 的 `IsFavorite`，只查本地订阅。
  bool _following = false;

  @override
  void initState() {
    super.initState();
    _load();
    _syncFollowing();
  }

  Future<void> _load() async {
    final id = widget.entry.sourceId;
    // 只有 TMDB 条目有详情（B站/Bangumi 没有该端点）
    if (widget.entry.source != 'tmdb' || id == null || id.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    try {
      final key = await ref.read(sessionStoreProvider).loadTmdbKey();
      if (key == null || key.isEmpty) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final d =
          await ref.read(calendarClientProvider).fetchDetail(id, apiKey: key);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _loading = false;
        _failed = d == null;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  @override
  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final d = _detail;
    // 海报优先用详情的（更清晰），否则用列表里的
    final cover = d?.posterUrl ?? e.posterUrl;
    final title = e.displayTitle;
    final rating = d?.rating ?? e.rating;

    // ★ 稿子的类型判定：电影 = 无"下次更新"、无"选集"
    final isMovie = e.category == BrowseCategory.movie ||
        (_detail?.genres.contains('电影') ?? false);

    return Scaffold(
      backgroundColor: Cf.bg,
      body: _loading && d == null
          ? const Center(child: CircularProgressIndicator())
          : Stack(children: [
              // 内容整体可滚（稿子 `.detail-scroll { flex:1; overflow-y:auto }`）
              ListView(
                padding: EdgeInsets.zero,
                children: [
                  // ── ① Hero 大图（52vh）+ 底部渐隐 + 返回钮 + 标题 + meta ──
                  _Hero(
                    cover: d?.backdropUrl ?? cover,
                    title: title,
                    entry: e,
                    detail: d,
                    rating: rating,
                  ),
                  // ── ② 操作按钮行：播放（粉紫渐变）+ 追剧（半透明边框）──
                  _ActionRow(
                    entry: e,
                    detail: d,
                    onPlay: () => _jumpToPlatform(title, d, e),
                    following: _following,
                    onToggleFollow: _toggleFollow,
                  ),
                  // ── ③ 下次更新（**电影隐藏**，用户规格）──
                  if (!isMovie) _NextUpdate(entry: e, detail: d),
                  // ── ④ 信息栏（**全类型显示**，用户规格）──
                  _InfoSection(entry: e, detail: d),
                  // ── ⑤ 简介 3 行 + 展开全部 ──
                  if (d?.overview case final intro? when intro.isNotEmpty)
                    _Overview(
                      text: intro,
                      expanded: _descExpanded,
                      offerExpand: _shouldOfferExpand(intro),
                      onToggle: () =>
                          setState(() => _descExpanded = !_descExpanded),
                    )
                  else if (_failed)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(Cf.gap5, 0, Cf.gap5, 12),
                      child: Text(
                        e.source == 'tmdb'
                            ? '详情加载失败（可能网络波动），可稍后重试'
                            : '该来源暂不支持查看详情',
                        style: Cf.caption.copyWith(color: Cf.text3),
                      ),
                    ),
                  // ── ⑥ 选集 4 列网格（**电影隐藏**，用户规格）──
                  if (!isMovie)
                    _EpisodeGrid(
                      entry: e,
                      detail: d,
                      expanded: _epExpanded,
                      onToggle: () =>
                          setState(() => _epExpanded = !_epExpanded),
                    ),
                  const SizedBox(height: 40),
                ],
              ),
            ]),
    );
  }
  /// 切换「追剧」（用户规格：次操作按钮，可切换 追剧 / 已追）。
  ///
  /// 写**本地订阅表**（与追剧日历、首页「我的追剧」共用同一份数据）
  /// ⇒ 在这里追的剧会立刻出现在那两处。
  Future<void> _toggleFollow() async {
    final e = widget.entry;
    final wasFollowing = _following;
    setState(() => _following = !wasFollowing); // 乐观更新（立即反馈）
    try {
      // ★ 走**公共订阅函数**（用户 2026-10-12 要求三处统一）：
      //   先搜本地库 ⇒ 命中才写（Emby 收藏 + 本地订阅表）；
      //   未命中 ⇒ 什么都不写，提示"订阅暂未入库"。
      //
      // ⚠️ `unsubscribe: wasFollowing` —— 取消**不搜库**
      //    （已追的必须能取消，否则用户卡在"已追"出不来）。
      final r = await subscribeExternal(
        ref: ref,
        entry: e,
        title: e.displayTitle,
        // 外部源的条目：TMDB 的 sourceId 就是 tmdb id ⇒ mediaType 按其 kind
        mediaType: e.category == BrowseCategory.movie ? 'movie' : 'tv',
        status: _detail?.statusCn ?? '',
        unsubscribe: wasFollowing,
      );
      if (!mounted) return;
      switch (r.outcome) {
        case SubscribeOutcome.subscribed:
          setState(() => _following = true);
          _toast('已加入追剧：《${r.title}》');
        case SubscribeOutcome.unsubscribed:
          setState(() => _following = false);
          _toast('已取消追剧：《${r.title}》');
        case SubscribeOutcome.notInLibrary:
          // 回滚乐观更新（什么都没写，按钮不能显示"已追"）
          setState(() => _following = false);
          _toast('订阅暂未入库：媒体库里没有《${r.title}》');
        case SubscribeOutcome.failed:
          setState(() => _following = wasFollowing);
          _toast('操作失败：${r.error ?? '未知原因'}');
      }
    } catch (err) {
      // 失败回滚（不能让按钮显示"已追"而数据没落库）
      if (mounted) setState(() => _following = wasFollowing);
      debugPrint('[CalendarDetail] 追剧切换失败: $err');
      _toast('操作失败：$err');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(seconds: 3),
    ));
  }

  /// 初次查询"是否已追"（本地订阅表）。
  Future<void> _syncFollowing() async {
    try {
      final keys = await ref.read(subscribedKeysProvider.future);
      final id = widget.entry.sourceId;
      if (id == null) return;
      final hit = keys.any((k) => k.endsWith(':$id:tv') || k.endsWith(':$id:movie'));
      if (mounted && hit) setState(() => _following = true);
    } catch (e) {
      debugPrint('[CalendarDetail] 读订阅失败（非致命）: $e');
    }
  }

  /// 简介是否**真的**会被 3 行截断（决定要不要显示「展开全部」）。
  ///
  /// ## 为什么要判（而不是无脑显示）
  /// 短简介也放个「展开全部」⇒ 用户点了**没反应** ⇒ 那是**假按钮**，
  /// 比没有更糟（AGENTS §5.8：不留死按钮）。
  ///
  /// ## 判据
  /// 按 12px 字号 + 393dp 屏宽估算：约 22 字/行 ⇒ 3 行约 66 字。
  /// 阈值取 **60**（宁可多显示按钮 —— 点开多点一下无妨，
  /// 漏显示会让用户以为简介就这些）。
  bool _shouldOfferExpand(String intro) => intro.length > 60;
  /// 跳转：按**精确度**依次降级。
  ///
  /// ## 三级降级链（越靠前越准）
  /// ① **`entry.jumpUrl`** —— tgmeng 给的**该剧在平台的具体页面**
  ///    （实测形如 `v.youku.com/v_show/id_XX.html`）⇒ 点进去**直接能看**
  /// ② **`detail.homepage`** —— TMDB 的官方页面
  ///    （实测《仙逆》给了 `v.qq.com/x/cover/...`）
  /// ③ **平台搜索页** —— 只知道平台名时的兜底
  ///    （`platformSearchUrl`，用户还得再点一次）
  Future<void> _jumpToPlatform(
      String title, CalendarDetail? d, CalendarEntry e) async {
    // ① tgmeng 的精确播放页（最准）
    final jump = e.jumpUrl;
    if (jump != null && jump.isNotEmpty) {
      final ok = await launchUrl(Uri.parse(jump),
          mode: LaunchMode.externalApplication);
      if (ok) return;
      // 打不开就继续降级（有些 http 链接在 Android 上被拦）
    }
    // ② TMDB 的官方页面
    final home = d?.homepage;
    final url = (home != null && home.isNotEmpty)
        ? home
        // ③ 平台搜索页兜底
        : platformSearchUrl(
            (d?.platforms.isNotEmpty ?? false) ? d!.platforms.first : e.platform,
            title);
    if (url == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('没有可跳转的播放平台')),
      );
      return;
    }
    final ok =
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('无法打开链接')),
      );
    }
  }
}
// ══════════════════════════════════════════════════════════════
// ★ 用户规格：状态/平台**用颜色区分**（一眼认出）
// ══════════════════════════════════════════════════════════════
/// Hero 大图（**52vh**，稿子 `.detail-hero { height:52vh; min-height:380px }`）。
///
/// 用户逐条列出的五层结构（缺一不可）：
/// ① 大图（真实项目 = 海报/backdrop）
/// ② **底部渐隐遮罩** —— 从图过渡到页面底色，**让白字可读**
/// ③ 左上角半透明圆返回钮（36 + blur，避免遮挡大图）
/// ④ 剧名 **28px** 白字带阴影
/// ⑤ Meta 标签行 [状态][平台][评分][年份][类型]
class _Hero extends StatelessWidget {
  const _Hero({
    required this.cover,
    required this.title,
    required this.entry,
    required this.detail,
    required this.rating,
  });

  final String? cover;
  final String title;
  final CalendarEntry entry;
  final CalendarDetail? detail;
  final double? rating;

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height * 0.52;
    return SizedBox(
      height: h < 380 ? 380 : h,
      child: Stack(fit: StackFit.expand, children: [
        // ① 大图
        if (cover != null && cover!.isNotEmpty)
          Image.network(cover!,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(color: Cf.surface2))
        else
          Container(color: Cf.surface2),
        // ② 底部渐隐（稿子原文：`linear-gradient(to top, var(--bg) 0%,
        //    rgba(11,13,18,.4) 55%, transparent 100%)`）
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Cf.bg, Color(0x660B0D12), Color(0x00000000)],
              stops: [0.0, 0.55, 1.0],
            ),
          ),
        ),
        // ③④⑤ 返回钮 + 标题 + meta（贴底）
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Cf.gap5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: Cf.gap2),
                const _BackBtn(),
                const Spacer(),
                Text(title.isNotEmpty ? title : '暂无标题',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: Cf.pageTitle.fontSize,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: -0.5,
                      shadows: [
                        Shadow(blurRadius: 12, color: Color(0xE6000000)),
                      ],
                    )),
                const SizedBox(height: Cf.gap2),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (statusKindFrom(detail?.status,
            isMovie: entry.category == BrowseCategory.movie) case final k?)
                      CfStatusTag(kind: k),
                    if (platformOf(entry, detail) case final pn?)
                      CfPlatformTag(name: pn),
                    if (rating != null && rating! > 0) ...[
                      const Icon(Icons.star_rounded,
                          size: 15, color: Color(0xFFF5C518)),
                      Text(rating!.toStringAsFixed(1),
                          style: TextStyle(
                              fontSize: Cf.title.fontSize,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFFF5C518))),
                    ],
                    if (yearOfDate(entry.airDate) case final y?)
                      CfGlassChip(text: y),
                    for (final g in (detail?.genres ?? const <String>[]).take(3))
                      CfGlassChip(text: g),
                  ],
                ),
                const SizedBox(height: Cf.gap4),
              ],
            ),
          ),
        ),
      ]),
    );
  }
}

/// 平台名（详情优先，退回列表里的）。
String? platformOf(CalendarEntry e, CalendarDetail? d) {
  final p = d?.platforms;
  if (p != null && p.isNotEmpty) return p.first;
  return e.platform;
}
/// 星期几的中文（1=一 … 7=日）。
String weekdayCn(int w) => const ['', '一', '二', '三', '四', '五', '六', '日'][w.clamp(1, 7)];
/// 返回按钮（左上角**半透明圆**，稿子 `.detail-back`）。
class _BackBtn extends StatelessWidget {
  const _BackBtn();

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () => Navigator.pop(context),
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0x66000000), // rgba(0,0,0,.4)
            border: Border.all(color: const Color(0x26FFFFFF)),
          ),
          child: const Icon(Icons.arrow_back_rounded,
              size: 16, color: Colors.white),
        ),
      );
}

/// 操作按钮行（用户规格：播放 = **粉紫渐变**主操作；追剧 = **半透明边框**次操作）。
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.entry,
    required this.detail,
    required this.onPlay,
    required this.following,
    required this.onToggleFollow,
  });

  final CalendarEntry entry;
  final CalendarDetail? detail;
  final VoidCallback onPlay;
  final bool following;
  final VoidCallback onToggleFollow;

  @override
  Widget build(BuildContext context) {
    // 文案随进度变化（用户规格："文案随进度变化"）
    final isMovie = entry.category == BrowseCategory.movie;
    final total = detail?.episodeCount;
    final label = isMovie
        ? '立即播放'
        : (total != null && total > 0 ? '播放 · 全 $total 集' : '播放');

    // ★ 两个按钮**等宽**（稿子 `.btn-primary` 与 `.btn-secondary` 都是 `flex: 1`）
    //
    // ## 为什么必须等宽（用户反馈"很突兀"）
    // 我第一版让「播放」占满剩余宽度、「追剧」按内容挤成一小块
    // ⇒ 视觉上**一大一小**，左边的渐变块显得臃肿。
    // 稿子的做法是各占一半 —— 主次靠**视觉**（渐变 vs 半透明）区分，
    // 而不是靠**尺寸**。
    //
    // 稿子尺寸：height 46 / radius 12 / fontSize 14 / fw 700 / gap 6 / 图标 16
    const h = 46.0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Cf.gap5, Cf.gap4, Cf.gap5, Cf.gap2),
      child: Row(children: [
        // 主操作：粉紫渐变
        Expanded(
          child: GestureDetector(
            onTap: onPlay,
            child: Container(
              height: h,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Cf.accent, Cf.accent2]),
                borderRadius: BorderRadius.circular(Cf.radiusMd),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.play_arrow_rounded,
                    size: 16, color: Colors.white),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                ),
              ]),
            ),
          ),
        ),
        const SizedBox(width: 10), // 稿子 `.detail-actions { gap: 10px }`
        // 次操作：**等宽**半透明；已追 = 粉紫渐变（稿子 `.btn-secondary.on`）
        Expanded(
          child: GestureDetector(
            onTap: onToggleFollow,
            child: Container(
              height: h,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: following
                    ? LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Cf.accent, Cf.accent2])
                    : null,
                color: following ? null : const Color(0x0FFFFFFF),
                border: following
                    ? null
                    : Border.all(color: const Color(0x1FFFFFFF)),
                borderRadius: BorderRadius.circular(Cf.radiusMd),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(following ? Icons.star_rounded : Icons.star_border_rounded,
                    size: 16, color: Colors.white),
                const SizedBox(width: 6),
                Text(following ? '已追' : '追剧',
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

/// 「下次更新」横幅 —— **仅连载中显示**（用户规格：电影隐藏）。
class _NextUpdate extends StatelessWidget {
  const _NextUpdate({required this.entry, required this.detail});

  final CalendarEntry entry;
  final CalendarDetail? detail;

  @override
  Widget build(BuildContext context) {
    final st = statusKindFrom(detail?.status,
            isMovie: entry.category == BrowseCategory.movie);
    if (st != 'live') return const SizedBox.shrink();
    final wd = entry.weekday;
    final sub = detail?.episodeCount != null
        ? '共 ${detail!.episodeCount} 集'
        : '播出中';
    return Container(
      margin: const EdgeInsets.fromLTRB(Cf.gap5, Cf.gap2, Cf.gap5, Cf.gap2),
      padding: const EdgeInsets.all(Cf.gap4),
      decoration: BoxDecoration(
        color: Cf.surface,
        borderRadius: BorderRadius.circular(Cf.radiusMd),
        border: Border.all(color: Cf.border),
      ),
      child: Row(children: [
        Icon(Icons.schedule_rounded, size: 20, color: Cf.accent),
        const SizedBox(width: Cf.gap3),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(wd == null ? '下次更新：待定' : '下次更新：周${weekdayCn(wd)}',
                    style: Cf.caption.copyWith(
                        fontWeight: FontWeight.w700, color: Cf.text)),
                const SizedBox(height: 2),
                Text(sub,
                    style: Cf.micro.copyWith(fontSize: Cf.caption.fontSize, color: Cf.text3)),
              ]),
        ),
      ]),
    );
  }
}

/// 信息栏（**全类型显示**，用户规格）：播出平台/地区/播出/状态/进度。
class _InfoSection extends StatelessWidget {
  const _InfoSection({required this.entry, required this.detail});

  final CalendarEntry entry;
  final CalendarDetail? detail;

  @override
  Widget build(BuildContext context) {
    final d = detail;
    final rows = <(String, String)>[
      ('播出平台', platformOf(entry, d) ?? '—'),
      ('地区', (d?.countries.isNotEmpty ?? false) ? d!.countries.first : '—'),
      ('播出',
          entry.weekday == null ? '已全部上线' : '每周${weekdayCn(entry.weekday!)}'),
      ('状态', statusTextOf(statusKindFrom(d?.status) ?? 'end')),
      ('进度', d?.episodeCount != null ? '共 ${d!.episodeCount} 集' : '—'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(Cf.gap5, Cf.gap3, Cf.gap5, Cf.gap3),
      child: Column(children: [
        for (final (k, v) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child:
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: 72,
                child: Text(k, style: Cf.caption.copyWith(color: Cf.text3)),
              ),
              Expanded(
                child: Text(v,
                    style: Cf.caption.copyWith(
                        color: v == '—' ? Cf.text3 : Cf.text,
                        fontWeight:
                            v == '—' ? FontWeight.w400 : FontWeight.w600)),
              ),
            ]),
          ),
      ]),
    );
  }
}

/// 简介（默认 3 行 + 展开全部）。
class _Overview extends StatelessWidget {
  const _Overview({
    required this.text,
    required this.expanded,
    required this.offerExpand,
    required this.onToggle,
  });

  final String text;
  final bool expanded;
  final bool offerExpand;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(Cf.gap5, 0, Cf.gap5, Cf.gap3),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(text,
              maxLines: expanded ? null : 3,
              overflow:
                  expanded ? TextOverflow.visible : TextOverflow.ellipsis,
              style: Cf.caption.copyWith(
                  fontSize: Cf.label.fontSize, color: Cf.text2, height: 1.7)),
          // ⚠️ 只在**确实被截断**时才显示（短简介也放按钮 = 假按钮）
          if (offerExpand)
            GestureDetector(
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(expanded ? '收起' : '展开全部',
                      style: Cf.caption.copyWith(
                          fontSize: Cf.label.fontSize,
                          fontWeight: FontWeight.w600,
                          color: Cf.accent)),
                  Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 15,
                      color: Cf.accent),
                ]),
              ),
            ),
        ]),
      );
}

/// 选集（**4 列 16:9 网格**，用户规格；电影隐藏）。
class _EpisodeGrid extends StatelessWidget {
  const _EpisodeGrid({
    required this.entry,
    required this.detail,
    required this.expanded,
    required this.onToggle,
  });

  final CalendarEntry entry;
  final CalendarDetail? detail;
  final bool expanded;
  final VoidCallback onToggle;

  /// 折叠时显示的行数（**用户要求 3 行**，与简介一致）。
  static const _collapsedRows = 3;

  /// 展开后最多显示多少集。
  ///
  /// ## 为什么展开也要有上限
  /// 实测《爱·回家之开心速递》**2868 集** ⇒ 4 列要铺 **717 行**，
  /// 即使"展开"也不该真铺 717 行（滚动会明显卡，且用户永远滚不到底）。
  /// 120 集（30 行）足够覆盖绝大多数国产剧的完整季度。
  static const _expandedMax = 120;

  @override
  Widget build(BuildContext context) {
    final total = detail?.episodeCount;
    if (total == null || total <= 0) return const SizedBox.shrink();

    // 折叠 = 3 行 × 4 列 = 12 个；展开 = 最多 120 个
    const collapsedCount = _collapsedRows * 4;
    final n = expanded
        ? (total > _expandedMax ? _expandedMax : total)
        : (total > collapsedCount ? collapsedCount : total);
    // 只有总数超过折叠容量时才给"展开全部"（否则就是**假按钮**）
    final offerExpand = total > collapsedCount;

    return Padding(
      padding: const EdgeInsets.fromLTRB(Cf.gap5, Cf.gap2, Cf.gap5, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('选集', style: Cf.section.copyWith(fontSize: 14)),
          const SizedBox(width: 6),
          Text('共 $total 集',
              style: Cf.micro.copyWith(
                  fontSize: Cf.caption.fontSize, color: Cf.text3)),
          if (expanded && total > _expandedMax) ...[
            const SizedBox(width: 6),
            // ⚠️ 展开后只显示前 120 集，必须**如实说明**（不能假装全显示了）
            Text('（仅显示前 $_expandedMax 集）',
                style: Cf.micro.copyWith(
                    fontSize: Cf.caption.fontSize, color: Cf.text3)),
          ],
        ]),
        const SizedBox(height: Cf.gap3),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: n,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 16 / 9,
          ),
          itemBuilder: (_, i) => _EpTile(num: i + 1),
        ),
        // ★ 展开全部 / 收起（与简介同一交互 —— 用户："和简介一样"）
        if (offerExpand)
          GestureDetector(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.only(top: Cf.gap2),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(
                    expanded ? '收起' : '展开全部（共 $total 集）',
                    style: Cf.caption.copyWith(
                        fontSize: Cf.label.fontSize,
                        fontWeight: FontWeight.w600,
                        color: Cf.accent)),
                Icon(
                    expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 15,
                    color: Cf.accent),
              ]),
            ),
          ),
      ]),
    );
  }
}

/// 单集格子（16:9，稿子 `.ep-item`）。
///
/// ⚠️ **不臆造观看状态**：本页条目来自 TMDB/B站等**外部源**，
/// 本地没有"看到第几集"（那是 Emby 的 `UserData`）。
/// ⇒ 统一"未看"样式；真实进度请进 Emby 详情页。
class _EpTile extends StatelessWidget {
  const _EpTile({required this.num});

  final int num;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: const Color(0x0DFFFFFF),
          border: Border.all(color: const Color(0x14FFFFFF)),
          borderRadius: BorderRadius.circular(Cf.radiusSm),
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text('$num',
              style: TextStyle(
                  fontSize: Cf.label.fontSize,
                  fontWeight: FontWeight.w700,
                  color: Colors.white)),
          const SizedBox(height: 1),
          Text('第 $num 集',
              style: TextStyle(
                  fontSize: Cf.micro.fontSize, color: Color(0xFF5D6675))),
        ]),
      );
}
