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

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xF0111A33),
        border: Border(top: BorderSide(color: Cf.border)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 58,
          child: Row(
            children: [
              for (var i = 0; i < _tabItems.length; i++)
                Expanded(
                  child: InkWell(
                    onTap: () => onTap(i),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          i == index
                              ? _tabItems[i].activeIcon
                              : _tabItems[i].icon,
                          size: 21,
                          color: i == index ? Cf.accent : Cf.text3,
                        ),
                        SizedBox(height: 2),
                        Text(
                          _tabItems[i].label,
                          style: TextStyle(
                            fontSize: 10,
                            height: 1,
                            fontWeight:
                                i == index ? FontWeight.w700 : FontWeight.w500,
                            color: i == index ? Cf.accent : Cf.text3,
                          ),
                        ),
                      ],
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
