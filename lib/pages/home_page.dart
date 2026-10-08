/// 首页：精选轮播 / 继续观看 / 最近添加（全部真实数据）
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/router.dart';
import '../core/theme.dart';
import '../data/emby_provider.dart';
import '../data/models.dart';
import '../state/providers.dart';
import '../widgets/media_cards.dart';
import 'detail_page.dart';
import 'open_player_resolved.dart';

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final home = ref.watch(homeProvider);
    return Scaffold(
      body: home.when(
        loading: () => Center(
            child: CircularProgressIndicator(color: Cf.accent)),
        error: (e, _) => CfErrorView(
          message: e is MediaException ? e.message : '加载失败，请检查网络后重试',
          onRetry: () => ref.invalidate(homeProvider),
        ),
        data: (d) => d.fatalError != null
            // 全部区块都失败：显示错误页而不是"空首页"，否则用户会误以为媒体库是空的
            ? CfErrorView(
                message: d.fatalError is MediaException
                    ? (d.fatalError as MediaException).message
                    : '加载失败，请检查网络后重试',
                onRetry: () => ref.invalidate(homeProvider),
              )
            : RefreshIndicator(
          color: Cf.accent,
          backgroundColor: Cf.surface,
          onRefresh: () => ref.refresh(homeProvider.future),
          child: Stack(children: [
            SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              child: Column(children: [
                if (d.featured.isNotEmpty) _Carousel(items: d.featured),
                if (d.resume.isNotEmpty)
                  CfSection(
                    title: '继续观看',
                    trailing: '全部 ›',
                    // ★ 原为 showComingSoon('播放历史') —— 但 HistoryPage 早就实现好了
                    //（`lib/pages/history_page.dart`）。"做好了却没接上"比没做更糟：
                    //   用户以为这功能不存在。实测发现于 2026-10 的按钮审查。
                    onTrailing: () => context.push(Routes.history),
                    child: SizedBox(
                      // ⚠️ 必须跟着卡片宽度变（U9 测试抓到：写死 165 时
                      //    Medium 溢出 11.4、Expanded 溢出 28.3 —— 横屏直接报
                      //    `RenderFlex overflowed by 27 pixels`，
                      //    底部文字被裁 + 黄色溢出条纹）。
                      height: ContinueCard.heightFor(context),
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: d.resume.length,
                        separatorBuilder: (_, _) => SizedBox(width: 13),
                        itemBuilder: (_, i) => ContinueCard(
                            item: d.resume[i],
                            api: ref.read(embyApiProvider)!,
                            // ★ 改用 openPlayerResolved：剧集条目会先解析出分集列表再进播放器，
//     播放列表面板才有"第 N 集"与进度（用户反馈它缺失）。
//     直接 openPlayer 会把剧集当单条视频，列表为空。
                        onTap: () =>
                            openPlayerResolved(context, d.resume[i], ref)),
                      ),
                    ),
                  ),
                if (d.collections.isNotEmpty)
                  CfSection(
                    title: '合集',
                    trailing: '全部 ›',
                    onTrailing: () => showComingSoon(context, '合集库'),
                    child: SizedBox(
                      height: 190,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: d.collections.length,
                        separatorBuilder: (_, _) => SizedBox(width: 10),
                        itemBuilder: (_, i) => SizedBox(
                          width: 112,
                          child: PosterCard(
                              item: d.collections[i],
                              api: ref.read(embyApiProvider)!,
                              onTap: () =>
                                  openMediaItem(context, d.collections[i])),
                        ),
                      ),
                    ),
                  ),
                if (d.latest.isNotEmpty)
                  CfSection(
                    title: '最近添加',
                    // 不再挂「全部 ›」：媒体库页已移除（ADR 0003），
                    // 留一个点进去是"敬请期待"的入口比没有入口更糟。
                    child: PosterGrid(
                      items: d.latest,
                      api: ref.read(embyApiProvider)!,
                      onItemTap: (item) => openMediaItem(context, item),
                    ),
                  ),
                SizedBox(height: 28),
              ]),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: const _HomeTopBar(),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// 顶栏（悬浮于轮播之上）：Logo + 搜索 / 投屏
class _HomeTopBar extends ConsumerWidget {
  const _HomeTopBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xD90B1020), Color(0x000B1020)],
        ),
      ),
      child: Row(children: [
        const Spacer(),
        // ⚠️ 原先是裸 `GestureDetector` + 22px 图标 —— **可点区域只有图标本身**
        // （22×22，约为标准的 1/5），且没有任何按压反馈。
        // 这是实打实的可用性缺陷（LinPlayer 的已知陷阱表里就有
        // 「触摸目标点不中 → 必须 ≥48dp」这一条，Material 同要求）。
        // 改用 IconButton：theme 里已约束 minimumSize 48×48，
        // 并自带涟漪反馈，视觉尺寸仍是 22。
        IconButton(
          tooltip: '搜索',
          onPressed: () => context.push(Routes.search),
          icon: const Icon(Icons.search_rounded, size: 24),
          color: Cf.text2,
          visualDensity: VisualDensity.compact,
        ),
        IconButton(
          tooltip: '我的',
          // 图标按钮必须有无障碍名称（tooltip 即 semantics label）
          onPressed: () => ref.read(homeTabProvider.notifier).set(2),
          icon: const Icon(Icons.settings_rounded, size: 20),
          color: Cf.text2,
          visualDensity: VisualDensity.compact,
        ),
      ]),
    );
  }
}

/// 精选轮播：5s 自动翻页，真实背景图 + 渐变压暗
class _Carousel extends StatefulWidget {
  const _Carousel({required this.items});
  final List<MediaItem> items;

  @override
  State<_Carousel> createState() => _CarouselState();
}

class _CarouselState extends State<_Carousel> {
  final _controller = PageController();
  Timer? _timer;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _armTimer();
  }

  void _armTimer() {
    _timer?.cancel();
    if (widget.items.length > 1) {
      _timer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (!mounted) return;
        _page = (_page + 1) % widget.items.length;
        _controller.animateToPage(_page,
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeInOutCubic);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // ⚠️ 原先是写死的 `height: 270`。
    //
    // 问题：270 在 1080×2400 这类长屏上只占屏高 **11%** —— 主视觉被压成一条，
    // 海报细节看不清；而在矮屏/横屏上又偏大。
    //
    // 参考项目（Best-Flutter-UI-Templates 的 hero、LinPlayer 的 HomePage）
    // 都用**相对屏高的比例**，而不是固定像素。这里取 34%，并夹在
    // [230, 420] 之间：下限保证矮屏仍能看清标题与简介，
    // 上限避免大屏上主视觉占掉整屏、把下方内容全推出视野。
    final screenH = MediaQuery.sizeOf(context).height;
    final heroH = (screenH * 0.34).clamp(230.0, 420.0);
    // 断点类：Medium/Expanded 下主视觉给得更大方（屏宽富裕，标题与简介更从容）
    final wc = CfBreakpoints.of(MediaQuery.sizeOf(context).width);
    final heroH2 = wc == CfBreakpoints.compact
        ? heroH
        : (heroH * 1.15).clamp(230.0, 480.0);
    return SizedBox(
      height: heroH2,
      width: double.infinity,
      child: Stack(children: [
        Positioned.fill(
          child: PageView.builder(
            controller: _controller,
            itemCount: widget.items.length,
            onPageChanged: (i) {
              setState(() => _page = i);
              _armTimer(); // 手动滑动后重新计时
            },
            itemBuilder: (context, i) =>
                _Slide(item: widget.items[i], active: i == _page),
          ),
        ),

        // ---- 页码指示器（右下角）----
        //
        // ## 为什么必须加（此前**完全没有**）
        //
        // 轮播每 5 秒自动翻页，但界面上没有任何"共几张、现在第几张"的反馈 ——
        // 用户看到画面变了却不知道是自动播放还是自己碰到了什么，
        // 也判断不出"还有没有下一张"。
        //
        // 圆点**可点**：直接跳那一张（比等 5 秒或反复滑动都快）。
        // 每个点包 `CfTapTarget` —— 6px 的圆点裸放是点不中的
        // （审计实测本仓库最小可点元素仅 16×16，正是这类写法造成的）。
        if (widget.items.length > 1)
          Positioned(
            right: 18,
            bottom: 22,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < widget.items.length; i++)
                  CfTapTarget(
                    // 视觉仍是 6px 的圆点，命中区 32dp —— 视觉与命中分离
                    size: 32,
                    semanticLabel: '第 ${i + 1} 张，共 ${widget.items.length} 张',
                    onTap: () {
                      _controller.animateToPage(i,
                          duration: Cf.durBase, curve: Cf.curve);
                      setState(() => _page = i);
                      _armTimer();
                    },
                    child: AnimatedContainer(
                      duration: Cf.durBase,
                      curve: Cf.curve,
                      // 当前页拉长为短横条：比"只变色"更容易一眼定位
                      width: i == _page ? 16 : 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color:
                            i == _page ? Cf.accent : const Color(0x59FFFFFF),
                        // ⚠️ 用 `Cf.radiusXs`(4) 而不是裸 3。
                        //
                        //   本元素高只有 6px，Flutter 会把半径**收敛到 高度/2 = 3**
                        //   → 渲染结果与写 3 完全一致（都是胶囊头），但守住了
                        //   U1 的"圆角只用 4 档"纪律。
                        //
                        //   这条纪律不是形式主义：`test/design_tokens_test.dart`
                        //   正是靠它抓到了我在这里随手写的 3（**U3 开发中被 U1 的
                        //   测试拦下**，证明那批断言是真的在工作）。
                        borderRadius: BorderRadius.circular(Cf.radiusXs),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ]),
    );
  }
}

class _Slide extends ConsumerWidget {
  const _Slide({required this.item, required this.active});
  final MediaItem item;
  final bool active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(embyApiProvider)!;
    final url = item.backdropUrl(api);
    final tags = <String>[
      if (item.productionYear != null) '${item.productionYear}',
      if (item.communityRating != null)
        '⭐ ${item.communityRating!.toStringAsFixed(1)}',
      ...item.genres.take(2),
    ];
    return GestureDetector(
      onTap: () => openMediaItem(context, item),
      child: Stack(fit: StackFit.expand, children: [
        if (url != null)
          Image.network(url,
              fit: BoxFit.cover,
              alignment: const Alignment(0, .35),
              errorBuilder: (_, _, _) => Container(decoration: _gradient()))
        else
          Container(decoration: _gradient()),
        // 左右 + 上下双向渐变压暗（对齐原型 .carousel-slide::after）
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              stops: [0, .35, .65, 1],
              colors: [
                Color(0xEB0B1020),
                Color(0x990B1020),
                Color(0x000B1020),
                Color(0x000B1020),
              ],
            ),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              stops: [0, .4, 1],
              colors: [Color(0xF20B1020), Color(0x660B1020), Color(0x000B1020)],
            ),
          ),
        ),
        Positioned(
          left: 18,
          right: 18,
          bottom: 20,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ⚠️ 标题用 `CfText`（带字缩钳制）。
              //
              //   原先是裸 `fontSize: 24`：200% 系统字号下 → 48sp 单行，
              //   而轮播高度是屏高的 34%（夹 230–420）—— 48sp 会把简介与标签
              //   整段挤出可视区，且 `maxLines: 1 + ellipsis` 会**静默截断**标题
              //   （用户看到的是"片名被吃掉了"，而不是"字太大"）。
              //   24sp ≥ 14sp 属标题 → CfText 默认就会钳，无需显式传参。
              CfText(item.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1,
                      height: 1.15,
                      shadows: [
                        Shadow(blurRadius: 20, color: Colors.black54)
                      ])),
              if (tags.isNotEmpty) SizedBox(height: Cf.gap2),
              Wrap(spacing: 7, runSpacing: 5, children: [
                for (final t in tags)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 9, vertical: 2),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(Cf.radiusSm),
                      color: const Color(0x1FFFFFFF),
                      border:
                          Border.all(color: const Color(0x26FFFFFF)),
                    ),
                    child: Text(t, style: Cf.micro.copyWith(
                        fontWeight: FontWeight.w600, color: Cf.text)),
                  ),
              ]),
              if (item.overview case final ov? when ov.isNotEmpty) ...[
                SizedBox(height: Cf.gap2),
                Text(ov,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Cf.caption.copyWith(
                        height: 1.65,
                        color: Cf.text2,
                        shadows: [
                          Shadow(blurRadius: 8, color: Colors.black54)
                        ])),
              ],
            ],
          ),
        ),
      ]),
    );
  }

  BoxDecoration _gradient() {
    const sets = [
      [Color(0xFF1A3A5C), Color(0xFF0B1020)],
      [Color(0xFF3A1A4C), Color(0xFF0B1020)],
      [Color(0xFF1A4C3A), Color(0xFF0B1020)],
    ];
    final c = sets[item.id.hashCode.abs() % sets.length];
    return BoxDecoration(
        gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: c));
  }
}


