/// 主框架：底部 Tab Bar（首页 / 排行榜 / 我的）
/// 对应原型 .tabbar —— 手机端一级导航；详情/播放器全屏推入（不走 Tab）。
///
/// 「媒体库」Tab 已移除：列表页 UI 需要全量重构，旧实现（服务端分页 + 筛选行）
/// 不再作为一级入口。首页的继续观看/最近添加/合集与各详情页仍可正常进入播放。
library;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show DeviceOrientation, SystemChrome, SystemUiMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';

import '../core/theme.dart';
import '../keys.dart';
import 'home_page.dart';
import 'profile_page.dart';
import 'rank_page.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  static final List<Widget> _pages = <Widget>[
    HomePage(),
    const RankPage(),
    ProfilePage(),
  ];

  @override
  void initState() {
    super.initState();
    // ---- 强制回到竖屏 + 恢复系统 UI（防御式兜底，真机 bug）----
    //
    // ## 为什么主页要自己做（2026-10-08 用户实测："退出后首页也是横的"）
    // 播放页会 `setPreferredOrientations(landscape)` + `immersiveSticky`。
    // 它的复位本应在其 `dispose()` 里做，但实测**不可靠**：
    //   · 手势返回退出（PopScope → maybePop）时复位调用可能被丢弃
    //   · App 被系统回收（或 force-stop）后再启动，方向**残留横屏**
    //     ——连 force-stop 重启都无法自愈，说明系统记住了方向偏好
    //
    // 把"正确的方向"挂在**接收页**而不是"退出页"，是防御式设计：
    // 无论哪个页面忘了清理、清理调用是否被平台丢弃，
    // 回到主页时方向与系统栏**必然**被纠正。
    //
    // ## 代价与边界
    // 幂等、无依赖（SystemChrome 是静态平台通道 API）。
    // 若将来加入需要横屏的一级页面，把这段挪进"竖屏页"的公共基类，
    // 而不是在这里做条件判断。
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }

  void _switchTab(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) {
    // 首页顶栏齿轮跳「我的」
    ref.listen(homeTabProvider, (_, i) {
      if (mounted && i != _index) setState(() => _index = i);
    });

    // ---- 响应式导航形态（审计 U9）----
    //
    // 真机实测：手机**横屏**时逻辑宽 = 2400px ÷ (440/160) = **872dp → Expanded**。
    // 所以"侧栏导航"不是纸上谈兵 —— 用户把手机横过来就会看到。
    //
    // 为什么 Expanded 切侧栏：底栏在 872dp 宽下把三个图标摊得极开，
    // 视觉上像"三个孤岛"；且横屏垂直空间本就紧张，底栏还要占掉 58dp。
    // 侧栏（72dp 图标栏）是原型既定设计，也是 M3 对 Expanded 的推荐。
    //
    // ⚠️ Medium **仍用底部 Tab** —— 审计明确要求"不切侧栏，
    //    避免本阶段引入导航重构"。
    final wc = CfBreakpoints.of(MediaQuery.sizeOf(context).width);
    final useRail = CfLayout.useSideRail(wc);

    return Scaffold(
      body: useRail
          ? Row(children: [
              _SideRail(index: _index, onTap: _switchTab),
              Expanded(
                child: IndexedStack(index: _index, children: _pages),
              ),
            ])
          : IndexedStack(index: _index, children: _pages),
      bottomNavigationBar:
          useRail ? null : _TabBar(index: _index, onTap: _switchTab),
    );
  }
}

/// Expanded（≥840dp）下的**侧栏导航**（原型既定 72dp 图标栏）。
///
/// 与 [_TabBar] 共用同一份 [ShellKeys.tab] 键与命中区规范 ——
/// 两种导航形态对**测试与无障碍语义完全一致**，切换形态不会让测试失效。
///
/// 选中态用「左侧 3dp 强调色竖条 + 图标变色」双重表达：
/// 深色底上只靠变色不够醒目（与 §2.4 对比度问题同源）。
class _SideRail extends StatelessWidget {
  const _SideRail({required this.index, required this.onTap});
  final int index;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: CfLayout.sideRailWidth,
      decoration: BoxDecoration(
        color: const Color(0xF0111A33),
        border: Border(right: BorderSide(color: Cf.border)),
      ),
      child: SafeArea(
        right: false,
        child: Column(children: [
          const SizedBox(height: Cf.gap3),
          for (var i = 0; i < _tabItems.length; i++)
            Semantics(
              button: true,
              selected: i == index,
              label: _tabItems[i].label,
              child: CfTapTarget(
                // ⚠️ 与底栏用**同一份键**（`keys.shell.tab(i)`）——
                //    两种导航形态对测试与无障碍语义必须完全一致，
                //    否则"横屏时测试找不到 Tab"这种问题会在切换形态后冒出来。
                key: keys.shell.tab(i),
                // 语义由外层 Semantics 提供（button+selected+label），
                // 这里**不再**传 semanticLabel —— 否则会套出两层 Semantics 节点，
                // 读屏要念两遍，且 selected 状态可能与外层不同步。
                size: 56,
                onTap: () => onTap(i),
                child: Row(children: [
                  // 左侧竖条：选中态的主要信号（不靠颜色差异单独承担）
                  Container(
                    width: 3,
                    height: 26,
                    decoration: BoxDecoration(
                      color: i == index ? Cf.accent : Colors.transparent,
                      borderRadius: BorderRadius.circular(Cf.radiusXs),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: Icon(
                        i == index
                            ? _tabItems[i].activeIcon
                            : _tabItems[i].icon,
                        size: Cf.iconLg,
                        color: i == index ? Cf.accent : Cf.text3,
                      ),
                    ),
                  ),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}

class _TabItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  const _TabItem(this.icon, this.activeIcon, this.label);
}

const _tabItems = <_TabItem>[
  _TabItem(Icons.home_outlined, Icons.home_rounded, '首页'),
  _TabItem(Icons.leaderboard_outlined, Icons.leaderboard_rounded, '排行榜'),
  _TabItem(Icons.person_outline_rounded, Icons.person_rounded, '我的'),
];

class _TabBar extends StatelessWidget {
  const _TabBar({required this.index, required this.onTap});
  final int index;
  final ValueChanged<int> onTap;

  /// 标签栏内容高度（不含系统手势条内边距）。
  ///
  /// 定值而非按字号算：这是**固定高度的导航栏**，高度必须稳定
  /// （否则切换字号会让整页布局跳动）。为容纳大字号，配套做法是
  /// **钳制标签文字缩放**（见下面的 `CfText(clamp: true)`），
  /// 而不是把栏高撑开 —— 撑开会在 200% 下吃掉大量正文空间。
  static const double barHeight = 58;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xF0111A33),
        border: Border(top: BorderSide(color: Cf.border)),
      ),
      // SafeArea(top: false) 已把**系统手势条高度**作为底部内边距注入 ——
      // Android 15 强制 edge-to-edge 后，自绘 Tab 若不加这层会被手势条压住。
      // 故栏高是 `barHeight + 系统 inset`，不是写死的 58+58。
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: barHeight,
          child: Row(
            children: [
              for (var i = 0; i < _tabItems.length; i++)
                Expanded(
                  child: Semantics(
                    // 无障碍：自绘 Tab 必须显式给出"按钮 + 名称 + 是否选中"，
                    // 否则读屏只能念出一个无意义的"按钮"。
                    button: true,
                    selected: i == index,
                    label: _tabItems[i].label,
                    child: InkWell(
                      key: keys.shell.tab(i),
                      onTap: () => onTap(i),
                      // 命中区：Expanded 已保证整格可点（宽 ≈ 屏宽/3，高 58）
                      // —— 远高于 48dp 基线，无需额外 CfTapTarget。
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            i == index
                                ? _tabItems[i].activeIcon
                                : _tabItems[i].icon,
                            // 用刻度而不是 21：底部导航与 theme 的 navigationBarTheme
                            // （iconLg=24）保持一致，避免两个层级差 3px 的"抖动感"
                            size: Cf.iconLg,
                            color: i == index ? Cf.accent : Cf.text3,
                          ),
                          const SizedBox(height: 2),
                          // ⚠️ `clamp: true` 是**必须的**，这里正体现 CfText 的设计意图：
                          //
                          //   本栏高度固定 58dp（见上），标签在 200% 系统字号下
                          //   10sp → 20sp 会**溢出**（图标 24 + 间距 2 + 文字 20 > 58
                          //   减去垂直居中余量），现象是文字被裁或与图标重叠。
                          //
                          //   CfText 的默认规则是"≥14sp 才钳"（正文跟随系统），
                          //   而这里字号只有 10sp 属"正文档" —— 但**上下文是固定高度容器**，
                          //   所以必须显式钳制。这是 `clamp` 参数存在的意义。
                          CfText(
                            _tabItems[i].label,
                            clamp: true,
                            style: Cf.micro.copyWith(
                              height: 1,
                              fontWeight: i == index
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: i == index ? Cf.accent : Cf.text3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
