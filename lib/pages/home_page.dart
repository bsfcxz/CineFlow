/// 首页：精选轮播 / 继续观看 / 最近添加（全部真实数据）
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../data/calendar_client.dart';
import '../widgets/media_tags.dart';
import 'browse_page.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/router.dart';
import '../core/theme.dart';
import '../data/emby_provider.dart';
import '../data/models.dart';
import '../data/db/app_database.dart' show CalendarSubscription;
import '../state/providers.dart';
import '../widgets/media_cards.dart';
import 'detail_page.dart';

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
                // ★ 我的追剧（用户："= 追剧日历中订阅的内容"）
                //
                // ## 为什么放在"继续观看"之前（对齐参考稿的区块顺序）
                // 参考稿首页顺序：hero → emby-bar → 我的追剧 → 合集。
                // 「我的追剧」是用户**主动订阅**的（意图最强），
                // 排在"系统推荐的继续观看"之前更符合心智。
                //
                // ## 为什么它不会因网络失败而消失
                // 数据来自 `subscriptionsProvider`（drift 本地表），
                // 且订阅时落了**完整快照**（剧名/海报/平台/更新日）
                // ⇒ 外部源（TMDB/B站）全挂也照样显示。
                // ★ 分类浏览（用户 2026-10-12："分类浏览应该按照我给你的 ui 设计，
              //   放在首页我的追剧上方"）
              //
              // ## 为什么放"我的追剧"**上方**
              // 用户明确指定。产品上也说得通：
              // · 分类浏览 = **探索**（发现新内容）
              // · 我的追剧 = **跟进**（继续看已订的）
              // 先探索再跟进，符合"打开 App 先看看有什么"的心智。
              const _CategoryBrowseSection(),
              const _MyTrackingSection(),
                // ★ 「继续观看」已**移除**（用户要求）
                //
                // ## 为什么移除
                // 它已移到「追剧」Tab 的第二个分页（与"追剧日历"并列）——
                // 用户明确："将我的追剧中的追剧日历和首页的继续观看放在这儿"。
                // 首页再放一份是**重复展示**：同一批内容在两处出现，
                // 用户会困惑"哪个才是我要看的"。
                //
                // ## 数据没白拉（别顺手删 `d.resume`）
                // `HomeData.resume` 仍被「追剧」Tab 复用（`HistoryPage`
                // 走的 `getResume` 是**另一次**调用，但语义相同）。
                // 保留字段可让"将来首页想恢复"变成一行代码的事。
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
                    // 稿子：`<h2>最近更新 <em>新入库 / 新集数</em></h2>`
                    //
                    // ⚠️ 原标题「最近添加」是 Emby `/Latest` 的直译。
                    //    改「最近更新」语义更准：实测 `/Latest` 会返回
                    //    **老剧新集**（如 2019 的剧出了第 5 季）——
                    //    那就是「新集数」，不只是「新入库」。
                    title: '最近更新',
                    trailing: '新入库 / 新集数',
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
    // ★★ 高度改为 **58% 屏高**（用户要求"占首页半屏"，对齐参考稿）
    //
    // ## 演进（每次都是被实际问题推动的）
    // · 最早：写死 `height: 270` ⇒ 长屏上只占 11%，主视觉被压成一条
    // · 上一版：34%（夹 230..420）⇒ 仍偏矮，用户要"占半屏"
    // · **本版：58%**（夹 300..620）
    //
    // ## 为什么取 58%（实测参考稿的真实值）
    // ```css
    // .hero { height: 58vh; min-height: 440px; max-height: 520px; }
    // ```
    // 参考稿的值是给**桌面浏览器**的（窗口高 700–900px ⇒ 58vh ≈ 440–520）。
    // 手机 393×873dp 时 58% = 506dp，**正好落在参考稿的 [440,520] 区间内**
    // ⇒ 视觉比例一致。
    //
    // ## 为什么仍要夹取（不照抄 min/max）
    // 参考稿的 440..520 是**绝对像素**，用在手机上会出问题：
    // · 矮屏（如横屏 393dp 高）⇒ 440 会把内容全顶出屏幕
    // · 大屏平板 ⇒ 520 又太小，主视觉显得局促
    // ⇒ 用比例 + 更宽的夹取区间（300..620），既守住"半屏"观感，
    //    又不会在极端尺寸下崩。
    final screenH = MediaQuery.sizeOf(context).height;
    final heroH = (screenH * 0.58).clamp(300.0, 620.0);
    // 断点类：Medium/Expanded 下主视觉给得更大方（屏宽富裕，标题与简介更从容）
    final wc = CfBreakpoints.of(MediaQuery.sizeOf(context).width);
    final heroH2 = wc == CfBreakpoints.compact
        ? heroH
        : (heroH * 1.15).clamp(300.0, 680.0);
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

        // ---- 页码指示器（**底部居中**，对齐参考稿）----
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
          // ★ 居中（用户要求"轮播图底栏的滑动模块应该在中间"）
          //
          // ## 参考稿的做法（我实测 CSS 得到的）
          // ```css
          // .hero-dots { position: absolute; bottom: 22px;
          //              left: 50%; transform: translateX(-50%); }
          // ```
          // 即**水平居中 + 距底 22px**。原先我放在右下角（`right: 18`），
          // 与参考稿不一致。
          //
          // ## 为什么用 `left/right: 0 + Center` 而不是 `left: width/2`
          // `Positioned(left: 0, right: 0)` 让子项获得整宽约束，
          // 再用 `Center` 居中 —— 这样**圆点数量变化时自动重新居中**
          //（写死 `left: 196` 那种会在圆点变多时偏掉）。
          Positioned(
            left: 0,
            right: 0,
            bottom: 22,
            child: Center(
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
    // ★ hero 的 meta 行（稿子 `.hero-meta`）
    //
    // ## 用户 2026-10-12："上面这些我给你的 ui 设计你没有遵守"
    // 我第一版这里只有三个**灰色 chip**（年份/⭐评分/类型）——
    // 而稿子是 `[status-tag] [plat-tag] [score] [年份] [类型]`：
    // · 状态标签**彩色**（连载中绿+闪烁 / 已完结灰）
    // · 平台标签**品牌色**（腾讯蓝/爱奇艺绿/优酷青/芒果橙/B站粉）
    // · 评分**金色 `★`** 且无边底
    //
    // ⇒ 全部复用 `media_tags.dart` 的公共组件（与详情页**同一套**）。
    //    这正是"两处样式必须一致"的关键 —— 各写一套必然漂移。
    final kind = statusKindFrom(item.status);
    // ⚠️ 平台**暂缺**：`MediaItem`（列表项）不带 `Studios`，
    //    它只在详情端点返回（`MediaItemDetail.studios`）。
    //    首页轮播若为每张图都发一次详情请求，代价是 5 次额外请求/次刷新。
    //
    // ⇒ 现在如实留空（**不编造**）；等"首页 hero 改用 TMDB 热播交集"落地后，
    //    TMDB 的 `networks` 会直接给出平台（那才是正解，且零额外请求）。
    //    见 docs/AI-MEMORY.md 的未完成清单。
    final String? platform = null;
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
              if (kind != null ||
                  platform != null ||
                  item.communityRating != null ||
                  item.productionYear != null)
                SizedBox(height: Cf.gap2),
              // 稿子 `.hero-meta { display:flex; gap:8px; align-items:center; flex-wrap:wrap }`
              Wrap(spacing: 8, runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center, children: [
                if (kind != null) CfStatusTag(kind: kind),
                if (platform != null) CfPlatformTag(name: platform),
                if (item.communityRating case final r? when r > 0)
                  CfScoreText(value: r),
                if (item.productionYear case final y?) CfGlassChip(text: '$y'),
                for (final g in item.genres.take(2)) CfGlassChip(text: g),
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

/// **分类浏览**（稿子的 `.category-grid`：3 列，每格 图标+名称+计数）。
///
/// ## 稿子规格
/// ```css
/// grid-template-columns: repeat(3, 1fr); gap: 10px
/// .cat-entry { padding: 14px 6px 12px; radius: 14px; bg: var(--card) }
/// .cat-entry-icon { 38×38; radius: 11px; 各自渐变 }
/// .cat-entry-text { 12px; w700; #fff }
/// .cat-entry-count { 10px; var(--text-mute) }
/// ```
///
/// ## ⚠️ 计数怎么来的（不能照抄稿子）
/// 稿子里的 count 是 `Object.values(CONTENT).filter(...)` —— 那是它**硬编码的
/// 17 条假数据**。真实计数要问 TMDB（每个类别一次 discover）。
/// ⇒ 这里**不显示计数**（显示 0 或假数字都比没有更糟），
///    改显示该类别的地区数（"5 个地区"这种真实且稳定的信息）。
///    真正的数量在点进去之后由列表本身呈现。
class _CategoryBrowseSection extends ConsumerWidget {
  const _CategoryBrowseSection();

  /// 稿子原文的 6 个渐变色（每类一对）。
  static const _gradients = <BrowseCategory, (Color, Color)>{
    BrowseCategory.series: (Color(0xFFFF4D8D), Color(0xFFA855F7)),
    BrowseCategory.movie: (Color(0xFFF59E0B), Color(0xFFDC2626)),
    BrowseCategory.anime: (Color(0xFF06B6D4), Color(0xFF3B82F6)),
    BrowseCategory.variety: (Color(0xFF22C55E), Color(0xFF16A34A)),
    BrowseCategory.documentary: (Color(0xFF0D9488), Color(0xFF0891B2)),
    BrowseCategory.kids: (Color(0xFFFACC15), Color(0xFFF97316)),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 复用 CfSection（'合集' 也用它）—— 保持页内标题样式一致
    return CfSection(
      title: '分类浏览',
      // 稿子：`<h2>分类浏览 <em>点击查看全部</em></h2>`
      trailing: '点击查看全部 ›',
      onTrailing: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const BrowsePage()),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Cf.gap4),
        child: GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: BrowseCategory.values.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: Cf.gap3,
            crossAxisSpacing: Cf.gap3,
            // 稿子的格子是"图标 38 + 文字"的近似正方形 ⇒ 宽高比 ~1.15
            childAspectRatio: 1.15,
          ),
          itemBuilder: (_, i) {
            final c = BrowseCategory.values[i];
            final g = _gradients[c]!;
            return GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => BrowsePage(initial: c),
                ),
              ),
              child: Container(
                decoration: BoxDecoration(
                  color: Cf.surface,
                  borderRadius: BorderRadius.circular(Cf.radiusMd),
                  border: Border.all(color: Cf.border),
                ),
                child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [g.$1, g.$2]),
                          borderRadius: BorderRadius.circular(Cf.radiusSm),
                        ),
                        child: Text(c.emoji,
                            style: const TextStyle(fontSize: Cf.iconMd)),
                      ),
                      const SizedBox(height: 6),
                      Text(c.label,
                          style: Cf.caption.copyWith(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Cf.text)),
                      const SizedBox(height: 1),
                      // 真实且稳定的信息（不编造数量，见类文档）
                      Text('${c.regions.length} 个地区',
                          style: Cf.micro.copyWith(
                              fontSize: 10, color: Cf.text3)),
                    ]),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// **我的追剧**（用户："我的追剧是从 cineflow 你做出来的追剧日历中订阅的东西"）。
///
/// ## 与「继续观看」的区别（两者都在首页，容易混淆）
/// · **继续观看** —— Emby 的 `Resume`：**看过一半**的（被动记录）
/// · **我的追剧** —— 本地订阅：**关注的日历条目**（主动订阅）
/// 前者一定在你库里；后者可能只在 TMDB 热播榜上（库里没有）。
///
/// ## 为什么是 ConsumerWidget 而不是跟着 HomeData 走
/// `HomeData` 是**外部源**的聚合（Emby），而订阅是**本地**数据。
/// 分开 watch 有两个好处：
/// ① 订阅变化（点星标）只重建这一区，不重拉整个首页
/// ② Emby 挂了（`fatalError`）时，这一区仍然显示
class _MyTrackingSection extends ConsumerWidget {
  const _MyTrackingSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subs = ref.watch(subscriptionsProvider);
    final list = subs.maybeWhen(data: (l) => l, orElse: () => const []);
    // 没订阅时不占位（避免首页出现一个空区块）
    if (list.isEmpty) return const SizedBox.shrink();
    return CfSection(
      title: '我的追剧',
      trailing: '${list.length} 部',
      child: SizedBox(
        height: 178,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: list.length,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: (_, i) => _TrackingCard(sub: list[i]),
        ),
      ),
    );
  }
}

/// 追剧卡（海报 + 更新日角标 + 剧名 + 平台）。
///
/// ## 为什么不用 `PosterCard`
/// `PosterCard` 吃 `MediaItem`（Emby 的中立模型），而订阅是
/// `CalendarSubscription`（本地表行，含 TMDB 条目）⇒ 类型不兼容。
/// 强行转换会造出一个"假的 MediaItem"（id 是 tmdb id，点进去播不了）。
class _TrackingCard extends StatelessWidget {
  const _TrackingCard({required this.sub});

  final CalendarSubscription sub;

  @override
  Widget build(BuildContext context) {
    final poster = sub.posterUrl;
    return SizedBox(
      width: 112,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(Cf.radiusSm),
            child: SizedBox(
              width: 112,
              height: 134,
              child: poster.isEmpty
                  ? _fallback()
                  : Image.network(
                      poster,
                      fit: BoxFit.cover,
                      // 失败降级为占位（§6.4.1：不留破图）
                      errorBuilder: (_, __, ___) => _fallback(),
                      loadingBuilder: (context, child, p) =>
                          p == null ? child : _fallback(),
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            sub.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Cf.caption.copyWith(color: Cf.text),
          ),
          const SizedBox(height: 2),
          Text(
            sub.platform.isEmpty ? '未标注平台' : sub.platform,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Cf.micro,
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
