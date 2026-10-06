/// 公共媒体卡片组件：板块容器 / 海报卡 / 继续观看卡 / 错误视图
library;

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/media_provider.dart';
import '../data/models.dart';

/// 「敬请期待」轻提示（未接入功能统一入口）
void showComingSoon(BuildContext context, String feature) {
  ScaffoldMessenger.of(context).hideCurrentSnackBar();
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text('$feature 将在后续步骤接入'),
    behavior: SnackBarBehavior.floating,
    backgroundColor: Cf.surface,
    shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Cf.border)),
  ));
}

/// 板块容器：竖条标题 + 右侧「全部」
class CfSection extends StatelessWidget {
  const CfSection({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.onTrailing,
    this.padding = const EdgeInsets.only(top: 22),
  });
  final String title;
  final Widget child;
  final String? trailing;
  final VoidCallback? onTrailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(children: [
            Container(
              width: 4,
              height: 17,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                gradient: Cf.primaryGradient,
              ),
            ),
            SizedBox(width: 8),
            Text(title,
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.3)),
            const Spacer(),
            if (trailing != null)
              GestureDetector(
                onTap: onTrailing,
                child: Text(trailing!,
                    style: TextStyle(fontSize: 11, color: Cf.text3)),
              ),
          ]),
        ),
        child,
      ]),
    );
  }
}

/// 海报卡（2:3，评分角标 / 已看标记 / 标题浮层）
class PosterCard extends StatelessWidget {
  const PosterCard({
    super.key,
    required this.item,
    required this.api,
    this.onTap,
  });
  final MediaItem item;
  final MediaProvider api;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final url = item.posterUrl(api);
    return GestureDetector(
      onTap: onTap,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Cf.border),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(fit: StackFit.expand, children: [
                if (url != null)
                  Image.network(url,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => _ph())
                else
                  _ph(),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [.45, 1],
                      colors: [Colors.transparent, Color(0xD1000000)],
                    ),
                  ),
                ),
                if (item.communityRating case final r?)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        color: const Color(0xBF000000),
                      ),
                      child: Text('⭐ ${r.toStringAsFixed(1)}',
                          style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: Cf.warn)),
                    ),
                  ),
                if (item.played)
                  Positioned(
                    bottom: 26,
                    right: 7,
                    child: Container(
                      width: 17,
                      height: 17,
                      decoration: BoxDecoration(
                          color: Cf.accent, shape: BoxShape.circle),
                      child: Icon(Icons.check_rounded,
                          size: 12, color: Cf.ink),
                    ),
                  ),
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: 6,
                  child: Text(item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          height: 1.3,
                          color: Colors.white,
                          shadows: [
                            Shadow(blurRadius: 4, color: Colors.black87)
                          ])),
                ),
              ]),
            ),
          ),
        ),
        SizedBox(height: 5),
        Text(
          [
            if (item.productionYear != null) '${item.productionYear}',
            item.typeLabel,
          ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 10, color: Cf.text3),
        ),
      ]),
    );
  }

  Widget _ph() => Container(
        color: Cf.surface2,
        alignment: Alignment.center,
        child: Icon(Icons.movie_outlined, size: 24, color: Cf.text3),
      );
}

/// 海报网格（手机 3 列）
class PosterGrid extends StatelessWidget {
  const PosterGrid({
    super.key,
    required this.items,
    required this.api,
    this.onItemTap,
  });
  final List<MediaItem> items;
  final MediaProvider api;
  final void Function(MediaItem)? onItemTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      // ⚠️ 原先是写死的 `crossAxisCount: 3`。
      //
      // 问题：3 列只在"标准手机宽度"下好看。实测换算：
      //   · 1080px 宽 → 每张海报约 330px（偏大，一屏信息量少）
      //   · 720px 宽  → 约 220px（偏小，文字挤）
      //   · 平板/横屏 → 海报被拉得极大
      //
      // 参考项目（Best-Flutter-UI-Templates 的 grid）都用**按可用宽度算列数**。
      // 这里取"目标海报宽 112px，列数夹在 3–6 之间"：
      // 下限 3 保证手机上不会小到看不清，上限 6 避免超宽屏变得密密麻麻。
      const targetW = 112.0;
      final usable = box.maxWidth - 32; // 减去左右各 16 的 padding
      final cols = (usable / targetW).floor().clamp(3, 6);

      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: items.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 2 / 3.45,
          ),
          itemBuilder: (context, i) => PosterCard(
              item: items[i],
              api: api,
              onTap: onItemTap == null ? null : () => onItemTap!(items[i])),
        ),
      );
    });
  }
}

/// 继续观看横卡（16:9 + 集数徽标 + 进度条）
class ContinueCard extends StatelessWidget {
  const ContinueCard({
    super.key,
    required this.item,
    required this.api,
    this.onTap,
  });
  final MediaItem item;
  final MediaProvider api;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final url = item.thumbUrl(api);
    final remain = item.remainingMinutes;
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 200,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 200,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Cf.border),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(fit: StackFit.expand, children: [
                  if (url != null)
                    Image.network(url,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => _ph())
                  else
                    _ph(),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: [.5, 1],
                        colors: [Colors.transparent, Color(0xB3000000)],
                      ),
                    ),
                  ),
                  if (item.seasonEpisode case final se?)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          color: const Color(0xB3000000),
                          border:
                              // 原为硬编码 0x4D00D4FF：外观页切主题时此描边不变色（实测 bug）。
                              Border.all(
                                  color: Cf.accent.withValues(alpha: 0.30)),
                        ),
                        child: Text(se,
                            style: Cf.micro.copyWith(
                                fontWeight: FontWeight.w700,
                                color: Cf.accent)),
                      ),
                    ),
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      height: 3,
                      color: const Color(0x38FFFFFF),
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: item.progress,
                        child: Container(
                            decoration:
                                BoxDecoration(gradient: Cf.primaryGradient)),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          ),
          SizedBox(height: 9),
          Text(item.displayTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          SizedBox(height: 3),
          Text(
            remain != null ? '剩余 $remain 分钟' : '继续播放',
            style: TextStyle(fontSize: 10, color: Cf.text3),
          ),
        ]),
      ),
    );
  }

  Widget _ph() => Container(
        decoration: BoxDecoration(
          gradient:
              LinearGradient(colors: [Color(0x26111A33), Color(0x33111A33)]),
        ),
        alignment: Alignment.center,
        child: Icon(Icons.movie_creation_outlined,
            size: 24, color: Cf.text3),
      );
}

/// 加载失败视图。
///
/// 契约（缺陷 §7.8 的回归线）：**失败必须显示失败**，
/// 不允许把「加载失败」伪装成「暂无内容」。
class CfErrorView extends StatelessWidget {
  const CfErrorView({super.key, required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child:
            Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          // 错误用 danger 而非 text3：颜色承载语义（不能只用形状暗示）
          Icon(Icons.cloud_off_rounded, size: 40, color: Cf.danger.withValues(alpha: 0.85)),
          const SizedBox(height: Cf.gap4),
          Text(message,
              textAlign: TextAlign.center,
              style: Cf.label.copyWith(color: Cf.text2, height: 1.6)),
          const SizedBox(height: Cf.gap5),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 20),
            label: const Text('重试'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Cf.accent,
              side: BorderSide(color: Cf.accent.withValues(alpha: 0.6)),
              minimumSize: const Size(120, 44), // 触控目标 ≥44dp
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Cf.radiusMd)),
            ),
          ),
        ]),
      ),
    );
  }
}

/// 空态视图（统一出口）。
///
/// ## 为什么要有它
///
/// 改造前各页各写各的空态：`'该榜单暂无数据'`、`'暂无相似推荐'`、
/// `'暂无内容'`…… 文案与视觉都不统一，且**大多只有一行灰字**，
/// 没有引导用户"下一步能做什么"。
///
/// ui-ux-pro-max 的 `empty-states` 要求：空态要给**有用的说明 + 行动入口**，
/// 而不是一句冷冰冰的"暂无数据"。
///
/// 与 [CfErrorView] 的分工要严格区分（缺陷 §7.8）：
///   · 「真的没有内容」→ 本组件
///   · 「加载失败了」  → [CfErrorView]
///   **绝不能把失败画成空态**——那会让用户以为"这个库是空的"。
class CfEmptyView extends StatelessWidget {
  const CfEmptyView({
    super.key,
    required this.message,
    this.icon = Icons.inbox_rounded,
    this.hint,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final IconData icon;

  /// 补充说明（可选）：告诉用户为什么空、或下一步怎么做。
  final String? hint;

  /// 行动按钮（可选）：如「去登录」「换个筛选」。
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child:
            Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 40, color: Cf.text3.withValues(alpha: 0.7)),
          const SizedBox(height: Cf.gap4),
          Text(message,
              textAlign: TextAlign.center,
              style: Cf.label.copyWith(color: Cf.text2, height: 1.6)),
          if (hint case final h?) ...[
            const SizedBox(height: Cf.gap2),
            Text(h,
                textAlign: TextAlign.center,
                style: Cf.caption.copyWith(height: 1.5)),
          ],
          if (actionLabel case final a?) ...[
            const SizedBox(height: Cf.gap5),
            OutlinedButton(
              onPressed: onAction,
              style: OutlinedButton.styleFrom(
                foregroundColor: Cf.accent,
                side: BorderSide(color: Cf.accent.withValues(alpha: 0.6)),
                minimumSize: const Size(120, 44),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(Cf.radiusMd)),
              ),
              child: Text(a),
            ),
          ],
        ]),
      ),
    );
  }
}
