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
import '../state/providers.dart';

/// 打开日历条目的详情弹层。
///
/// [entry] 用于"详情还没到"时**立即**显示标题/海报/评分/平台
///（与豆瓣弹层同一个做法：先给即时信息，详情异步补上）。
void showCalendarDetail(BuildContext context, CalendarEntry entry) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Cf.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => SafeArea(
      child: _CalendarDetailSheet(entry: entry),
    ),
  );
}

class _CalendarDetailSheet extends ConsumerStatefulWidget {
  const _CalendarDetailSheet({required this.entry});

  final CalendarEntry entry;

  @override
  ConsumerState<_CalendarDetailSheet> createState() =>
      _CalendarDetailSheetState();
}

class _CalendarDetailSheetState extends ConsumerState<_CalendarDetailSheet> {
  /// 详情（null = 还在加载；`_failed` = 拉取失败）。
  CalendarDetail? _detail;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
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
  Widget build(BuildContext context) {
    final e = widget.entry;
    final d = _detail;
    // 海报优先用详情的（更清晰），否则用列表里的
    final cover = d?.posterUrl ?? e.posterUrl;
    final title = e.displayTitle;
    // 评分优先详情，否则列表里的（`vote_average`）
    final rating = d?.rating ?? e.rating;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
      maxChildSize: 0.92,
      builder: (context, scrollCtrl) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 头部：海报 + 标题 + 评分 + 副标题（对齐豆瓣弹层）──
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Poster(url: cover),
                SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title.isNotEmpty ? title : '暂无标题',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w800),
                      ),
                      // 类别 + 平台（豆瓣弹层这里是评分，我们先给归属信息）
                      SizedBox(height: 5),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          _Tag(text: e.category.label, color: Cf.accent),
                          if (d?.statusCn case final st?)
                            _Tag(text: st, color: Cf.text3),
                        ],
                      ),
                      if (rating != null) ...[
                        SizedBox(height: 5),
                        Row(children: [
                          const Icon(Icons.star_rounded,
                              size: 16, color: Cf.warn),
                          const SizedBox(width: 3),
                          Text(rating.toStringAsFixed(1),
                              style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w900,
                                  color: Cf.warn)),
                          if (d?.voteCount case final c? when c > 0)
                            Text('  $c 人评过',
                                style: TextStyle(
                                    fontSize: 10, color: Cf.text3)),
                        ]),
                      ],
                      // 副标题（"2023 / 中国大陆 / 动画 剧情"）
                      if (d?.subtitleLine case final sub? when sub.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Text(sub,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 10,
                                  color: Cf.text3,
                                  height: 1.5)),
                        ),                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // ── 正文（可滚动）──
            Expanded(
              child: _loading
                  ? Center(
                      child: Padding(
                        padding: EdgeInsets.all(20),
                        // ⚠️ 不能写 `CircularProgressIndicator(color: Cf.accent)`
                        //    —— 虽然 `Cf.accent` 本身是 `Color`，但放进
                        //    `const` 构造里 Dart 仍报 `invalid_constant`
                        //    （`Cf.accent` 是**静态成员**，不是字面量）。
                        //    这里用它的字面值并**加守卫测试**防漂移。
                        child: SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Cf.accent,
                          ),
                        ),
                      ),
                    )
                  : ListView(
                      controller: scrollCtrl,
                      children: [
                        if (d?.overview case final intro?
                            when intro.isNotEmpty) ...[
                          Text('简介',
                              style: TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w800)),
                          SizedBox(height: 6),
                          Text(intro,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Cf.text2,
                                  height: 1.7)),
                          SizedBox(height: 14),
                        ] else if (_failed)
                          Padding(
                            padding: EdgeInsets.only(bottom: 12),
                            child: Text(
                              e.source == 'tmdb'
                                  ? '详情加载失败（可能网络波动），可稍后重试'
                                  : '该来源暂不支持查看详情',
                              style: TextStyle(
                                  fontSize: 12, color: Cf.text3),
                            ),
                          ),
                        // 一行标语（TMDB 的 tagline，豆瓣没有对应物但很有味道）
                        if (d?.tagline case final tl? when tl.isNotEmpty) ...[
                          Text('「$tl」',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Cf.text3,
                                  fontStyle: FontStyle.italic)),
                          const SizedBox(height: 12),
                        ],
                        _infoRow('导演', d?.directors ?? const []),
                        _infoRow('主演', (d?.actors ?? []).take(8).toList()),
                        _infoRow('类型', d?.genres ?? []),
                        _infoRow('制片国家/地区', d?.countries ?? []),
                        _infoRow('播放平台', d?.platforms ?? [
                          if (e.platform case final p?) p
                        ]),
                        if (d?.episodeText case final ep?) _infoRow('集数', [ep]),
                        if (d?.firstAirDate case final fa?)
                          _infoRow('首播', [fa]),
                        _infoRow('更新', [
                          '${_weekdayCn(e.weekdayResolved)}'
                              '${e.episode == null ? '' : ' · ${e.episode}'}'
                        ]),
                        SizedBox(height: 8),
                      ],
                    ),
            ),
            SizedBox(height: 10),

            // ── 底部动作行（对齐豆瓣弹层：主按钮 + 两个图标）──
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => _jumpToPlatform(title, d, e),
                    child: Container(
                      height: 42,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        gradient: Cf.primaryGradient,
                        borderRadius: BorderRadius.circular(Cf.radiusSm),
                      ),
                      child: Text(
                        _actionLabel(d, e),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: Cf.ink),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 9),
                // TMDB 页面（相当于豆瓣弹层的 [↗豆瓣]）
                _IconBtn(
                  icon: Icons.open_in_new_rounded,
                  onTap: d?.tmdbId == null
                      ? null
                      : () => launchUrl(
                            Uri.parse('https://www.themoviedb.org/tv/'
                                '${d!.tmdbId}?language=zh-CN'),
                            mode: LaunchMode.externalApplication,
                          ),
                ),
                const SizedBox(width: 9),
                _IconBtn(
                  icon: Icons.close_rounded,
                  size: 20,
                  onTap: () => Navigator.pop(context),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 主按钮文案：有官方播放页 ⇒ "去 XX 观看"，否则"在平台搜索"。
  String _actionLabel(CalendarDetail? d, CalendarEntry e) {
    final t = e.displayTitle;
    final platforms = (d?.platforms.isNotEmpty ?? false)
        ? d!.platforms
        : [if (e.platform case final p?) p];
    final p = platforms.isEmpty ? null : platforms.first;
    final home = d?.homepage;
    if (home != null && home.isNotEmpty) {
      return '去 ${p ?? '平台'} 观看';
    }
    return p == null ? '搜索「$t」' : '在 $p 搜索「$t」';
  }

  /// 跳转：**优先官方播放页**（实测《仙逆》给了 `v.qq.com/x/cover/...`），
  /// 没有则退回平台搜索页。
  ///
  /// ## 为什么优先 homepage
  /// `homepage` 是**该剧的官方页面** ⇒ 点进去直接能看；
  /// 搜索页还要用户再点一次。实测《仙逆》/《你好，星期六》都有 homepage。
  Future<void> _jumpToPlatform(
      String title, CalendarDetail? d, CalendarEntry e) async {
    final home = d?.homepage;
    final url = (home != null && home.isNotEmpty)
        ? home
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

  String _weekdayCn(int w) =>
      const ['', '周一', '周二', '周三', '周四', '周五', '周六', '周日'][w.clamp(1, 7)];

  Widget _infoRow(String label, List<String> values) {
    final v = values.where((e) => e.trim().isNotEmpty).toList();
    if (v.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(label,
                style: TextStyle(fontSize: 11, color: Cf.text3)),
          ),
          Expanded(
            child: Text(v.join(' / '),
                style: TextStyle(fontSize: 11, color: Cf.text2)),
          ),
        ],
      ),
    );
  }
}

/// 海报（失败降级为占位，与列表页同一个做法）。
class _Poster extends StatelessWidget {
  const _Poster({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    const w = 84.0;
    const h = 120.0;
    final u = url;
    Widget fallback() => Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Cf.radiusSm),
            color: Cf.surface2,
          ),
          alignment: Alignment.center,
          child: Icon(Icons.movie_outlined, color: Cf.text3),
        );
    if (u == null || u.isEmpty) return fallback();
    return ClipRRect(
      borderRadius: BorderRadius.circular(Cf.radiusSm),
      child: Image.network(
        u,
        width: w,
        height: h,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => fallback(),
        loadingBuilder: (context, child, p) =>
            p == null ? child : fallback(),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Cf.radiusXs),
      ),
      child: Text(text,
          style: TextStyle(fontSize: 10, color: color, height: 1.3)),
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({required this.icon, this.onTap, this.size = 16});

  final IconData icon;
  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Cf.radiusSm),
          color: Cf.surface2,
          border: Border.all(color: Cf.border),
        ),
        child: Icon(icon,
            size: size, color: onTap == null ? Cf.text3 : Cf.text2),
      ),
    );
  }
}
