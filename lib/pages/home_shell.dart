/// 主框架：底部 Tab Bar（首页 / 排行榜 / 我的）
/// 对应原型 .tabbar —— 手机端一级导航；详情/播放器全屏推入（不走 Tab）。
///
/// 「媒体库」Tab 已移除：列表页 UI 需要全量重构，旧实现（服务端分页 + 筛选行）
/// 不再作为一级入口。首页的继续观看/最近添加/合集与各详情页仍可正常进入播放。
library;
import 'package:flutter/material.dart';
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

  void _switchTab(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) {
    // 首页顶栏齿轮跳「我的」
    ref.listen(homeTabProvider, (_, i) {
      if (mounted && i != _index) setState(() => _index = i);
    });
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: _TabBar(
        index: _index,
        onTap: _switchTab,
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
