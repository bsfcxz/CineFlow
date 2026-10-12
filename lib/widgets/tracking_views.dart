/// **追剧 Tab 的两个子视图**（按用户截图规格）：
/// · [FinishedGrid] —— 「已完结」**3 列海报网格**（不带日历）
/// · [ContinueList] —— 「继续观看」**横排卡片**（缩略图 + 进度条 + 百分比）
///
/// ## 为什么单独一个文件
/// `tracking_page.dart` 已 900+ 行。这两个视图与"追剧日历"（周历 + 列表）
/// **布局完全不同** —— 混在一个文件里会让那段越来越难读。
///
/// ## 规格来源（稿子 180b4d）
/// ```css
/// /* 已完结 */
/// .finished-grid { grid-template-columns:repeat(3,1fr); gap:12px; padding:16px 20px 30px }
/// .fg-poster { aspect-ratio:2/3; border-radius:10px }
/// .fg-poster::after { background:linear-gradient(to top, rgba(0,0,0,.85) 0%, transparent 55%) }
/// .fg-score { top:6px; left:6px; rgba(0,0,0,.6); #f5c518; 9.5px }
/// .fg-end-badge { top:6px; right:6px; 灰渐变; 9px }
/// .fg-ep .ep-count { bottom:6px; left:6px; rgba(0,0,0,.55); 10px }
/// .fg-ep .ep-check { bottom:6px; right:6px; var(--live) }
/// .fg-title { 11.5px w600 }  .fg-meta { 10px muted }
///
/// /* 继续观看 */
/// .cont-card { display:flex; gap:12px; border-radius:14px; padding:12px }
/// .cont-thumb { width:130px; height:74px; border-radius:9px }   /* 16:9 */
/// .cont-play { 36×36 圆形按钮居中 }
/// .cont-ep-badge { top:6px; left:6px; rgba(0,0,0,.65) }
/// .cont-bar { height:3px; 粉紫渐变 }  .cont-meta .pct { color:var(--brand) }
/// ```
library;

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/db/app_database.dart' show CalendarSubscription;
import '../data/media_provider.dart';
import '../data/models.dart';

/// 「已完结」视图：**3 列海报网格**（用户截图规格）。
///
/// ## 为什么不是"周历 + 列表"
/// 已完结的剧**不会再更新** ⇒ 周历（周一~周日）对它没有意义。
/// 用户原话："已完结的和继续观看的显示成图二这样，**不带日历**"。
class FinishedGrid extends StatelessWidget {
  const FinishedGrid({
    super.key,
    required this.items,
    required this.episodeCountOf,
    required this.onTap,
  });

  final List<CalendarSubscription> items;

  /// 取该剧的总集数（库内有 ⇒ 用库内的；没有 ⇒ null，**不编数字**）。
  final int? Function(String sourceId) episodeCountOf;

  final void Function(CalendarSubscription) onTap;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Center(
        child: Text('没有已完结的订阅',
            style: Cf.caption.copyWith(color: Cf.text3)),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(Cf.gap5, Cf.gap4, Cf.gap5, 30),
      itemCount: items.length,
      // `.finished-grid { repeat(3,1fr); gap:12px }`；海报 2:3 + 标题两行
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 2 / 3.45,
      ),
      itemBuilder: (_, i) => _Card(
        sub: items[i],
        total: episodeCountOf(items[i].sourceId),
        onTap: () => onTap(items[i]),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.sub, required this.total, required this.onTap});

  final CalendarSubscription sub;
  final int? total;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(children: [
              // 海报（2:3）
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(Cf.radiusMd),
                  child: sub.posterUrl.isEmpty
                      ? _fallback()
                      : Image.network(sub.posterUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _fallback(),
                          loadingBuilder: (c, ch, p) =>
                              p == null ? ch : _fallback()),
                ),
              ),
              // `.fg-poster::after` 底部渐隐（保证角标与文字可读）
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(Cf.radiusMd),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          const Color(0xD9000000),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.55],
                      ),
                    ),
                  ),
                ),
              ),
              // ⚠️ 稿子这里有 `.fg-score`（左上评分）—— 但
              //    **`CalendarSubscription` 没有 `rating` 列**（订阅表只存
              //    展示必需的最小字段集，11 列里没有评分）
              //    ⇒ 这里**不显示评分**，而不是显示假数据 0.0。
              //    要显示得给订阅表加列 + 订阅时落库（另开一轮）。
              // `.fg-end-badge`（右上「已完结」，灰渐变）
              Positioned(
                top: 6,
                right: 6,
                child: _Chip(
                  text: '已完结',
                  color: const Color(0xFF475569),
                  textColor: Colors.white,
                ),
              ),
              // `.fg-ep`（左下「全 N 集」+ 右下 ✓）
              Positioned(
                left: 6,
                right: 6,
                bottom: 6,
                child: Row(children: [
                  if (total != null && total! > 0)
                    _Chip(
                      text: '全 $total 集',
                      color: const Color(0x8C000000),
                      textColor: Colors.white,
                    ),
                  const Spacer(),
                  // `.fg-ep .ep-check { color: var(--live) }`
                  const Icon(Icons.check_rounded,
                      size: 13, color: Color(0xFF22C55E)),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: 6),
          // `.fg-title`（11.5px w600，单行省略）
          Text(sub.titleCn.isEmpty ? sub.title : sub.titleCn,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Cf.caption.copyWith(
                   fontWeight: FontWeight.w600)),
          const SizedBox(height: 3),
          // `.fg-meta`（平台 · 年份）
          Text(
            [
              if (sub.platform.isNotEmpty) sub.platform,
              if (sub.lastAirDate.length >= 4) sub.lastAirDate.substring(0, 4),
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Cf.micro.copyWith(fontSize: 10, color: Cf.text3),
          ),
        ],
      ),
    );
  }

  Widget _fallback() => Container(
        color: Cf.surface2,
        alignment: Alignment.center,
        child: Icon(Icons.movie_outlined, color: Cf.text3),
      );
}

/// 小角标（`.fg-score` / `.fg-end-badge` / `.fg-ep .ep-count` 共用）。
class _Chip extends StatelessWidget {
  const _Chip({
    required this.text,
    required this.color,
    required this.textColor,
  });

  final String text;
  final Color color;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(Cf.radiusXs),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(text,
            style: Cf.micro.copyWith(
                 fontWeight: FontWeight.w700,
                color: textColor, height: 1.2)),
      ]),
    );
  }
}

/// 「继续观看」视图：**横排卡片**（用户截图规格）。
///
/// ## 与 `HistoryPage` 的区别
/// `HistoryPage` 是通用的"3 列海报网格"；本视图是**追剧 Tab 内**的
/// 横卡样式（缩略图 130×74 + 标题 + 进度条 + 百分比），
/// 来自稿子 `.cont-card`。两者用途不同，不合并。
class ContinueList extends StatelessWidget {
  const ContinueList({
    super.key,
    required this.items,
    required this.onTap,
    this.api,
  });

  final List<MediaItem> items;
  final void Function(MediaItem) onTap;

  /// 拼图片地址用（`MediaItem.posterUrl` 要 `api`）。
  /// null 时缩略图显示占位（**不崩**）。
  final MediaProvider? api;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Center(
        child: Text('没有正在观看的内容',
            style: Cf.caption.copyWith(color: Cf.text3)),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(Cf.gap4, Cf.gap3, Cf.gap4, 20),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (_, i) =>
          _ContCard(item: items[i], api: api, onTap: () => onTap(items[i])),
    );
  }
}

class _ContCard extends StatelessWidget {
  const _ContCard({
    required this.item,
    required this.onTap,
    this.api,
  });

  final MediaItem item;
  final VoidCallback onTap;
  final MediaProvider? api;

  @override
  Widget build(BuildContext context) {
    // `.cont-bar i` 的宽度 = 已看百分比
    final pct = ((item.playedPercentage ?? 0).clamp(0, 100)).toDouble();
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(Cf.gap3),
        decoration: BoxDecoration(
          color: Cf.surface,
          border: Border.all(color: Cf.border),
          borderRadius: BorderRadius.circular(Cf.radiusMd),
        ),
        child: Row(children: [
          // `.cont-thumb { width:130px; height:74px }`（16:9）
          SizedBox(
            width: 130,
            height: 74,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Cf.radiusSm),
              child: Stack(children: [
                Positioned.fill(child: _thumb(context, api)),
                // `.cont-play`：36×36 半透明圆 + 白描边
                Center(
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0x99000000),
                      border: Border.all(
                          color: const Color(0xB3FFFFFF), width: 1.5),
                    ),
                    child: const Icon(Icons.play_arrow_rounded,
                        size: 20, color: Colors.white),
                  ),
                ),
                // `.cont-ep-badge`（左上「第 N 集」）
                if (item.indexNumber != null)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xA6000000),
                        borderRadius: BorderRadius.circular(Cf.radiusXs),
                      ),
                      child: Text('第 ${item.indexNumber} 集',
                          style: Cf.micro.copyWith(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: Colors.white)),
                    ),
                  ),
              ]),
            ),
          ),
          const SizedBox(width: Cf.gap3),
          // `.cont-info`
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.seriesName ?? item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Cf.title.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                // `.cont-bar`（3px 粉紫渐变）
                ClipRRect(
                  borderRadius: BorderRadius.circular(Cf.radiusSm),
                  child: LinearProgressIndicator(
                    value: pct / 100,
                    minHeight: 3,
                    backgroundColor: const Color(0x1AFFFFFF),
                    valueColor: AlwaysStoppedAnimation<Color>(Cf.accent),
                  ),
                ),
                const SizedBox(height: 6),
                // `.cont-meta`（左：剩余；右：百分比粉色）
                Row(children: [
                  Expanded(
                    child: Text(_remaining(item),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Cf.micro.copyWith(
                             color: Cf.text3)),
                  ),
                  Text('${pct.round()}%',
                      style: Cf.micro.copyWith(
                          
                          fontWeight: FontWeight.w700,
                          color: Cf.accent)),
                ]),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  /// 缩略图。
  ///
  /// ⚠️ `MediaItem` **没有** `thumbnailUrl` / `posterUrl` **字段** ——
  /// `posterUrl` 是**方法**：`String? posterUrl(MediaProvider api, {int maxWidth})`
  /// （要传 `api` 才能拼出带 token 的地址）。这是我本轮第 3 次凭记忆写 API
  /// ⇒ 现在按 `MediaItem.posterUrl` 的真实签名调用。
  Widget _thumb(BuildContext context, MediaProvider? api) {
    if (api == null) return _ph();
    // 横图位置优先用父级缩略图（`ParentThumbImageTag` 存在时 imageUrl 会给横图）
    final url = item.posterUrl(api, maxWidth: 400);
    if (url == null || url.isEmpty) return _ph();
    return Image.network(url,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _ph(),
        loadingBuilder: (c, ch, p) => p == null ? ch : _ph());
  }

  Widget _ph() =>
      Container(color: Cf.surface2, alignment: Alignment.center,
          child: Icon(Icons.movie_outlined, color: Cf.text3));

  /// 「剩余 N 分钟」（与 `PosterCard` 同口径；时长缺就显示"继续观看"）。
  String _remaining(MediaItem it) {
    final ticks = it.runtimeTicks;
    final pos = it.positionTicks;
    if (ticks == null || pos == null || ticks <= pos) return '继续观看';
    // 1 tick = 100ns ⇒ 1 秒 = 10,000,000 ticks
    final mins = ((ticks - pos) / 10000000 / 60).round();
    if (mins <= 0) return '继续观看';
    return mins >= 60 ? '剩余 ${(mins / 60).toStringAsFixed(1)} 小时'
                      : '剩余 $mins 分钟';
  }
}
