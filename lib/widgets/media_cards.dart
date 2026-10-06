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
            // ⚠️ 「更多」入口原为裸 `GestureDetector` + 11sp 文字：
            //   可点区域只有文字本身（约 40×16）—— **高 16dp，远低于 48dp 基线**，
            //   且没有任何按压反馈。审计实测本仓库"88 处可点元素 <40dp"，
            //   这一处正是典型（最小的一处仅 16×16）。
            //   改用 `CfTapTarget`：视觉仍是那行小字，命中区撑到 48dp。
            if (trailing != null)
              CfTapTarget(
                size: 48,
                onTap: onTrailing,
                semanticLabel: trailing!,
                child: Text(trailing!,
                    style: const TextStyle(fontSize: 11, color: Cf.text3)),
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

  /// 海报卡片的圆角。用令牌而不是就地写值（U1 的断言会拦裸数字）。
  static const double _radius = Cf.radiusMd;

  @override
  Widget build(BuildContext context) {
    final url = item.posterUrl(api);
    final card = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(_radius),
            border: Border.all(color: Cf.border),
          ),
          // ⚠️ ClipRRect 的圆角必须**略小于**外层 Container，
          //    否则裁切边与外框重合，会出现 1px 的亮边（描边被切掉一半）。
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Cf.radiusSm),
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(Cf.radiusXs),
                      color: const Color(0xBF000000),
                    ),
                    // ⚠️ 用 CfText 而非裸 Text：9sp 角标在 200% 字号下 → 18sp，
                    //    而角标容器只有 15px 高 → 文字会被裁掉。
                    //    角标属"固定小容器"，必须钳制（详见 CfText 的 clamp 说明）。
                    child: CfText('⭐ ${r.toStringAsFixed(1)}',
                        clamp: true,
                        style: const TextStyle(
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
                    child: Icon(Icons.check_rounded, size: 12, color: Cf.ink),
                  ),
                ),
              Positioned(
                left: 8,
                right: 8,
                bottom: 6,
                child: CfText(item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
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
      CfText(
        [
          if (item.productionYear != null) '${item.productionYear}',
          item.typeLabel,
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 10, color: Cf.text3),
      ),
    ]);

    // ⚠️ 从 `GestureDetector` 换成 `InkWell`（内含 Material）：
    //
    //   1. **按压反馈**：GestureDetector 点了毫无变化 —— 用户不确定有没有点上，
    //      尤其在海报这种"点了要等一下才跳页"的场景。这是本项目
    //      "按键没用"观感的主要来源之一（`UI-DESIGN.md` §3.3.2）。
    //   2. **无障碍语义**：`Semantics(button: true, label: …)` 让读屏能念出
    //      "《片名》，按钮"，而不是一个无名的可点区域。
    //      同时把年份/类型/评分并进 label —— 读屏用户靠它判断"要不要点进去"。
    return Semantics(
      button: true,
      label: [
        item.name,
        if (item.productionYear != null) '${item.productionYear} 年',
        item.typeLabel,
        if (item.communityRating case final r?) '评分 ${r.toStringAsFixed(1)}',
        if (item.played) '已看',
      ].join('，'),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(_radius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(_radius),
          child: card,
        ),
      ),
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

  /// 卡片宽度。
  ///
  /// ⚠️ 原是写死的 `200`（审计 §2.1 点名）：在 Compact(360dp) 上占 55% 宽、
  /// 在 Medium/Expanded 上却只有 25% —— 大屏上显得稀疏零落。
  /// 改为**按断点给宽度**：大屏给更大卡片，保持"一眼能看清缩略图"的密度。
  static double widthFor(BuildContext context) =>
      widthForClass(CfBreakpoints.of(MediaQuery.sizeOf(context).width));

  /// 纯函数版（供单测直接断言断点行为）。
  static double widthForClass(int windowClass) => switch (windowClass) {
        CfBreakpoints.expanded => 260.0,
        CfBreakpoints.medium => 230.0,
        _ => 200.0, // Compact
      };

  /// 容器应给的高度。
  ///
  /// ## ⚠️ 为什么必须跟着宽度一起变（U9 测试抓到的真 bug）
  ///
  /// U4 把宽度改成断点相关后，`home_page` 里的容器高度**仍是写死的 165**。
  /// 而缩略图是 16:9 —— **高度随宽度一起涨**。实测：
  ///
  /// | 窗口类 | 卡片宽 | 1.3x 字缩下的需求 | 165 够吗 |
  /// |---|---|---|---|
  /// | Compact | 200 | 159.5 | 够 |
  /// | Medium | 230 | 176.4 | **溢出 11.4** |
  /// | Expanded | 260 | 193.3 | **溢出 28.3** |
  ///
  /// 横屏（Expanded）时 Flutter 直接报
  /// `A RenderFlex overflowed by 27 pixels on the bottom`
  /// —— 黄色条纹 + 底部文字被裁。
  ///
  /// 公式 `max(165, 宽 × 9/16 + 52)`：
  ///   · **165 是下限** —— Compact 保持原值，竖屏观感不变
  ///   · `宽 × 9/16` 是 16:9 缩略图高度
  ///   · `+52` 是标题行 + 间距 + 副标题行（1.3x 钳制后的实测需求 + 约 5dp 余量）
  static double heightForClass(int windowClass) =>
      (widthForClass(windowClass) * 9 / 16 + 52).clamp(165.0, 400.0);

  /// 依据 BuildContext 给容器高度。
  static double heightFor(BuildContext context) =>
      heightForClass(CfBreakpoints.of(MediaQuery.sizeOf(context).width));

  @override
  Widget build(BuildContext context) {
    final url = item.thumbUrl(api);
    final remain = item.remainingMinutes;
    final cardW = widthFor(context);
    // ⚠️ 换成 InkWell + Semantics：与 PosterCard 同因 ——
    //   1. GestureDetector 无按压反馈（"点了没反应"的观感来源）
    //   2. 读屏需要知道"继续观看《片名》，剩余 N 分钟"
    return Semantics(
      button: true,
      label: [
        '继续观看 ${item.name}',
        ?item.seasonEpisode,
        // `remain` 是 int?（未看过时无剩余时长）—— 用空安全写法而不是裸 >
        if (remain != null && remain > 0) '剩余 $remain 分钟',
        if (item.progress > 0) '已看 ${(item.progress * 100).round()}%',
      ].join('，'),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(Cf.radiusMd),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Cf.radiusMd),
          child: SizedBox(
            width: cardW,
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: cardW,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(Cf.radiusMd),
                  border: Border.all(color: Cf.border),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(Cf.radiusSm),
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
                              borderRadius:
                                  BorderRadius.circular(Cf.radiusXs),
                              color: const Color(0xB3000000),
                              border:
                                  // 原为硬编码 0x4D00D4FF：外观页切主题时此描边不变色（实测 bug）。
                                  Border.all(
                                      color:
                                          Cf.accent.withValues(alpha: 0.30)),
                            ),
                            // 季集号在固定高容器里 → 必须钳制（同 PosterCard 角标）
                            child: CfText(se,
                                clamp: true,
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
                                decoration: BoxDecoration(
                                    gradient: Cf.primaryGradient)),
                          ),
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
              const SizedBox(height: 9),
              // 卡片标题：13sp < 14 → 属"正文语义"，但**它在固定高的卡片里**，
              // 所以必须显式钳制（否则 200% 下标题变两行、把副标题挤出卡片）
              CfText(item.displayTitle,
                  clamp: true,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              CfText(
                remain != null ? '剩余 $remain 分钟' : '继续播放',
                clamp: true,
                style: const TextStyle(fontSize: 10, color: Cf.text3),
              ),
            ]),
          ),
        ),
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
